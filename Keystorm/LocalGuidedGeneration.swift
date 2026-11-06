import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon

/// Experimental, unquantized, greedy text-only control. Production keeps using the
/// pinned loop with fast-forward disabled until model-output and timing parity pass.
/// No package-private cache APIs or diagnostic-sink hooks are used.
nonisolated enum LocalGuidedGeneration {
    enum Forwarding: Sendable {
        case sequential
        /// Explicit experiment: some models cannot attend over a populated cache
        /// with multiple new tokens. Only enable after that model's parity checks.
        case batched(maximumTokens: Int)
    }

    enum TokenOrigin: String, Codable, Sendable { case sampled, forced }

    struct Metrics: Codable, Sendable {
        var prefillMicroseconds: UInt64 = 0
        /// Includes evaluation and any overlapped grammar work. Do not sum this
        /// with grammarMicroseconds to estimate the total wall time.
        var modelForwardMicroseconds: UInt64 = 0
        var grammarMicroseconds: UInt64 = 0
        var samplingMicroseconds: UInt64 = 0
        var modelForwardCalls = 0
        var modelForwardTokens = 0
        var sampledTokens = 0
        var forcedTokens = 0
        var stopTokens = 0
    }

    struct Result: Codable, Sendable {
        let generatedTokens: Int
        /// Includes an accepted terminal EOS, which is not emitted. Use this
        /// count, not generatedTokens, when rolling a matcher back for reuse.
        let acceptedTokens: Int
        let metrics: Metrics?
    }

    enum Failure: Error, Equatable {
        case invalidInput
        case unsupportedCache
        case invalidModelOutput
        case invalidMask
        case invalidSample
        case consumerStopped
        case incompleteOutput
    }

    static func run(
        input: LMInput,
        context: ModelContext,
        constraint: GrammarConstraint,
        maxTokens: Int,
        vocabSize: Int,
        forwarding: Forwarding = .sequential,
        measurePhases: Bool = false,
        recordToken: ((Int, TokenOrigin) -> Void)? = nil,
        emit: (String) -> Bool
    ) throws -> Result {
        guard maxTokens > 0, vocabSize > 0, input.text.tokens.ndim == 1,
              input.text.tokens.size > 0, input.text.mask == nil,
              input.image == nil, input.video == nil, input.audio == nil else { throw Failure.invalidInput }
        let batchSize: Int
        switch forwarding {
        case .sequential: batchSize = 1
        case .batched(let maximum):
            guard (2...64).contains(maximum) else { throw Failure.invalidInput }
            batchSize = maximum
        }
        try Task.checkCancellation()
        let model = context.model
        let cache = try model.newCache(parameters: nil)
        guard cache.allSatisfy({ !($0 is any QuantizedKVCacheProtocol) && $0.maxSize == nil }) else {
            throw Failure.unsupportedCache
        }
        var metrics = Metrics()
        let prefillStart: ContinuousClock.Instant? = measurePhases ? .now : nil
        var state: LMOutput.State?
        var logits: MLXArray
        switch try model.prepare(input, cache: cache, state: nil,
                                 prefill: .init(stepSize: PrefillParameters.defaultStepSize)) {
        case .tokens(let remaining):
            guard remaining.tokens.ndim == 1, remaining.tokens.size > 0,
                  remaining.tokens.size <= input.text.tokens.size else { throw Failure.invalidModelOutput }
            let result = model(remaining[text: .newAxis], cache: cache.isEmpty ? nil : cache, state: nil)
            state = result.state
            logits = result.logits
        case .logits(let result):
            state = result.state
            logits = result.logits
        }
        eval(logits)
        if let prefillStart { metrics.prefillMicroseconds = microseconds(prefillStart.duration(to: .now)) }
        try Task.checkCancellation()
        guard logits.ndim == 3, logits.dim(0) == 1, logits.dim(1) > 0, logits.dim(2) > 0 else {
            throw Failure.invalidModelOutput
        }
        let logitCount = logits.dim(2)
        var stops = Set(context.configuration.eosTokenIds)
        if let eos = context.tokenizer.eosTokenId { stops.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { stops.insert(id) }
        }
        var detokenizer = context.tokenizer.makeStreamingDetokenizer()
        var generated = 0
        var accepted = 0
        var grammarStopped = false
        var mask: MaskResult
        var maskArray: MLXArray?
        func nextMask() throws -> (MaskResult, MLXArray?) {
            let start: ContinuousClock.Instant? = measurePhases ? .now : nil
            let result = try constraint.computeMask()
            let array = try additiveMask(result, vocabSize: vocabSize, logitCount: logitCount)
            if let start { metrics.grammarMicroseconds += microseconds(start.duration(to: .now)) }
            return (result, array)
        }
        (mask, maskArray) = try nextMask()
        while generated < maxTokens {
            try Task.checkCancellation()
            if mask.isTerminated { grammarStopped = true; break }
            let sampleStart: ContinuousClock.Instant? = measurePhases ? .now : nil
            var scores = logits[0..., -1, 0...]
            if let maskArray { scores = scores + maskArray }
            let sampled = Int(argMax(scores, axis: -1).item(UInt32.self))
            if let sampleStart { metrics.samplingMicroseconds += microseconds(sampleStart.duration(to: .now)) }
            guard sampled < vocabSize, sampled < logitCount,
                  sampled != context.tokenizer.unknownTokenId else { throw Failure.invalidSample }
            let commitStart: ContinuousClock.Instant? = measurePhases ? .now : nil
            let committed = try constraint.commitToken(Int32(sampled))
            if let commitStart { metrics.grammarMicroseconds += microseconds(commitStart.duration(to: .now)) }
            accepted += 1 + committed.tokens.count
            if stops.contains(sampled) {
                guard committed.isTerminated, committed.tokens.isEmpty else { throw Failure.invalidSample }
                metrics.stopTokens += 1
                grammarStopped = true
                break
            }
            // The bridge already accepted the entire forced suffix. Any partial
            // emission or token limit therefore throws and the matcher is discarded.
            let block = [Int32(sampled)] + committed.tokens
            for (offset, token) in block.enumerated() {
                try Task.checkCancellation()
                guard generated < maxTokens else { throw Failure.incompleteOutput }
                let id = Int(token)
                guard id >= 0, id < vocabSize, !stops.contains(id) else { throw Failure.invalidSample }
                let origin: TokenOrigin = offset == 0 ? .sampled : .forced
                detokenizer.append(token: id)
                generated += 1
                if origin == .sampled { metrics.sampledTokens += 1 } else { metrics.forcedTokens += 1 }
                recordToken?(id, origin)
                if let text = detokenizer.next(), !emit(text) { throw Failure.consumerStopped }
            }
            if committed.isTerminated { grammarStopped = true; break }
            guard generated < maxTokens else { throw Failure.incompleteOutput }
            try Task.checkCancellation()
            let forwardStart: ContinuousClock.Instant? = measurePhases ? .now : nil
            // Always include the sampled token before its forced suffix. Forward
            // each exactly once; only the final block logits feed the next sample.
            for offset in stride(from: 0, to: block.count, by: batchSize) {
                try Task.checkCancellation()
                let end = min(offset + batchSize, block.count)
                let tokens = MLXArray(Array(block[offset..<end]))
                let result = model(LMInput.Text(tokens: tokens)[text: .newAxis],
                                   cache: cache.isEmpty ? nil : cache, state: state)
                state = result.state
                logits = result.logits
                metrics.modelForwardCalls += 1
                metrics.modelForwardTokens += end - offset
            }
            asyncEval(logits)
            (mask, maskArray) = try nextMask()
            eval(logits)
            if let forwardStart { metrics.modelForwardMicroseconds += microseconds(forwardStart.duration(to: .now)) }
            guard logits.ndim == 3, logits.dim(0) == 1, logits.dim(1) > 0, logits.dim(2) == logitCount else {
                throw Failure.invalidModelOutput
            }
        }
        try Task.checkCancellation()
        guard grammarStopped else { throw Failure.incompleteOutput }
        if let tail = detokenizer.finish(), !tail.isEmpty, !emit(tail) { throw Failure.consumerStopped }
        return Result(generatedTokens: generated, acceptedTokens: accepted, metrics: measurePhases ? metrics : nil)
    }

    private static func additiveMask(_ mask: MaskResult, vocabSize: Int, logitCount: Int) throws -> MLXArray? {
        guard mask.needsApply else { return nil }
        guard mask.mask.count >= (vocabSize + 31) / 32 else { throw Failure.invalidMask }
        var values = [Float](repeating: -.infinity, count: logitCount)
        var allowed = false
        for id in 0..<min(vocabSize, logitCount) {
            let word = UInt32(bitPattern: mask.mask[id / 32])
            if (word >> UInt32(id % 32)) & 1 == 1 { values[id] = 0; allowed = true }
        }
        guard allowed || mask.isTerminated else { throw Failure.invalidMask }
        return MLXArray(values)
    }

    private static func microseconds(_ duration: Duration) -> UInt64 {
        let value = duration.components
        return UInt64(max(0, value.seconds)) * 1_000_000 + UInt64(max(0, value.attoseconds)) / 1_000_000_000_000
    }
}
