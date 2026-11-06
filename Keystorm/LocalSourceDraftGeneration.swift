import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon

/// Greedy source-draft verification for bounded, eligible Clean requests.
/// Eligibility and typed fallback are owned by LocalCleanGeneration.
/// Every emitted draft token must equal the target model's grammar-masked argmax.
/// Rejected trials never mutate the authoritative cache; only verified tokens are replayed.
nonisolated enum SourceDraftGeneration {
    enum TokenOrigin: String, Codable, Sendable { case sampled, verifiedDraft }
    enum Failure: Error, Equatable {
        case invalidInput, unsupportedCache, cacheLimit, unsupportedModelState
        case invalidModelOutput, invalidMask, invalidSample, unexpectedFastForward
        case consumerStopped, incompleteOutput
    }
    struct Metrics: Codable, Sendable {
        var prefillMicroseconds: UInt64 = 0
        var lookupMicroseconds: UInt64 = 0
        var copyMicroseconds: UInt64 = 0
        var verificationForwardMicroseconds: UInt64 = 0
        var replayMicroseconds: UInt64 = 0
        var serialForwardMicroseconds: UInt64 = 0
        var grammarMicroseconds: UInt64 = 0
        var samplingMicroseconds: UInt64 = 0
        var modelForwardCalls = 0
        var modelForwardTokens = 0
        var sampledTokens = 0
        var verifiedDraftTokens = 0
        var proposedTokens = 0
        var stopTokens = 0
        var draftRounds = 0
        var fullyAcceptedRounds = 0
        var rejectedRounds = 0
        var rejectedPositions: [Int: Int] = [:]
        var replayTokens = 0
        var draftingStoppedAfterRejection = false
        var draftingStoppedAtGeneratedToken: Int?
        var serialTokensAfterCutoff = 0
        var cacheCopies = 0
        /// Active logical state passed through public copy(), not physical bytes allocated.
        var copiedLogicalCacheStateBytes: UInt64 = 0
        /// innerState array-shape bytes include KV reserved capacity; maximumCacheBytes
        /// is an observed per-set limit, checked before copy and after forward/evaluation.
        /// A model allocation can exceed that limit before the post-forward check throws.
        var peakObservedCacheBackingBytes: UInt64 = 0
        /// Original plus trial innerState array-shape bytes while both are alive. Shared
        /// backing can be counted twice; retained prefix resources and allocator scratch
        /// are excluded. This is neither an allocator cap nor process-resident memory.
        var peakCombinedObservedCacheBackingBytes: UInt64 = 0
    }
    /// Cheap per-run evidence remains available when phase clocks are disabled.
    struct Counters: Codable, Sendable {
        let draftRounds: Int
        let proposedTokens: Int
        let verifiedDraftTokens: Int
        let rejectedRounds: Int
        let draftingStoppedAfterRejection: Bool
        let serialTokensAfterCutoff: Int
        let peakObservedCacheBackingBytes: UInt64
        let peakCombinedObservedCacheBackingBytes: UInt64
    }
    struct Result: Codable, Sendable {
        let counters: Counters
        let generatedTokens: Int
        /// Includes terminal EOS when the matcher accepted it; excludes rejected proposals.
        let acceptedTokens: Int
        let metrics: Metrics?
    }

    struct Drafts: Sendable {
        let tokenSequences: [[Int]]

        init(source: String, tokenizer: any MLXLMCommon.Tokenizer) throws {
            let quoted = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
            let variants = [
                quoted,
                "{\"complete\":true,\"text\":" + quoted + "}",
                "{\"complete\": true, \"text\": " + quoted + "}"
            ]
            tokenSequences = variants.map { tokenizer.encode(text: $0, addSpecialTokens: false) }
        }

        /// Explicit token fixtures let tests cover token boundaries and ambiguous repeated text.
        init(tokenSequences: [[Int]]) { self.tokenSequences = tokenSequences }

        func proposal(after history: [Int], maximum: Int, vocabSize: Int, forbidden: Set<Int>) -> [Int] {
            guard maximum > 0, !history.isEmpty else { return [] }
            // Token-space matching, never substring splicing or decode/re-encode across a boundary.
            for width in stride(from: min(8, history.count), through: 1, by: -1) {
                let suffix = history.suffix(width)
                for sequence in tokenSequences where sequence.count > width {
                    for end in width..<sequence.count {
                        guard sequence[(end - width)..<end].elementsEqual(suffix) else { continue }
                        let proposed = sequence[end..<min(sequence.count, end + maximum)]
                            .prefix { $0 >= 0 && $0 < vocabSize && !forbidden.contains($0) }
                        if !proposed.isEmpty { return Array(proposed) }
                    }
                }
            }
            return []
        }
    }

    static func run(
        input: LMInput, context: ModelContext, constraint: GrammarConstraint,
        maxTokens: Int, vocabSize: Int, drafts: Drafts, maximumDraftTokens: Int = 8,
        stopDraftingAfterRejection: Bool = false,
        maximumCacheBytes: UInt64 = 128 * 1_024 * 1_024,
        measurePhases: Bool = false,
        recordToken: ((Int, TokenOrigin) -> Void)? = nil,
        emit: (String) -> Bool
    ) throws -> Result {
        guard maxTokens > 0, vocabSize > 0, (0...16).contains(maximumDraftTokens),
              maximumCacheBytes > 0, maximumCacheBytes <= 128 * 1_024 * 1_024,
              input.text.tokens.ndim == 1, (1...4096).contains(input.text.tokens.size),
              input.text.mask == nil, input.image == nil, input.video == nil, input.audio == nil else {
            throw Failure.invalidInput
        }
        try Task.checkCancellation()
        let model = context.model
        var caches = try model.newCache(parameters: nil)
        var metrics = Metrics()
        func cacheBytes(_ entries: [KVCache]) throws -> UInt64 {
            guard !entries.isEmpty else { throw Failure.unsupportedCache }
            var identities = Set<ObjectIdentifier>()
            var bytes: UInt64 = 0
            for entry in entries {
                guard let concrete = entry as? BaseKVCache,
                      type(of: concrete) == KVCacheSimple.self || type(of: concrete) == MambaCache.self,
                      entry.maxSize == nil, entry.evictedTokenCount == 0,
                      entry.offset >= 0, entry.offset <= 8192,
                      identities.insert(ObjectIdentifier(concrete)).inserted else { throw Failure.unsupportedCache }
                bytes += entry.innerState().reduce(UInt64(0)) { $0 + UInt64($1.nbytes) }
            }
            guard bytes <= maximumCacheBytes else { throw Failure.cacheLimit }
            metrics.peakObservedCacheBackingBytes = max(metrics.peakObservedCacheBackingBytes, bytes)
            metrics.peakCombinedObservedCacheBackingBytes = max(metrics.peakCombinedObservedCacheBackingBytes, bytes)
            return bytes
        }
        _ = try cacheBytes(caches)
        let prefillStart: ContinuousClock.Instant? = measurePhases ? .now : nil
        var logits: MLXArray
        switch try model.prepare(input, cache: caches, state: nil,
                                 prefill: .init(stepSize: PrefillParameters.defaultStepSize)) {
        case .tokens(let remaining):
            guard remaining.tokens.ndim == 1, remaining.tokens.size > 0,
                  remaining.tokens.size <= input.text.tokens.size else { throw Failure.invalidModelOutput }
            let output = model(remaining[text: .newAxis], cache: caches, state: nil)
            guard output.state == nil else { throw Failure.unsupportedModelState }
            logits = output.logits
        case .logits(let output):
            guard output.state == nil else { throw Failure.unsupportedModelState }
            logits = output.logits
        }
        eval(logits)
        if let prefillStart { metrics.prefillMicroseconds = micros(prefillStart.duration(to: .now)) }
        guard logits.ndim == 3, logits.dim(0) == 1, logits.dim(1) > 0, logits.dim(2) >= vocabSize else {
            throw Failure.invalidModelOutput
        }
        let logitCount = logits.dim(2)
        _ = try cacheBytes(caches)
        var stopIDs = Set(context.configuration.eosTokenIds)
        if let eos = context.tokenizer.eosTokenId { stopIDs.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { stopIDs.insert(id) }
        }
        var forbidden = stopIDs
        if let unknown = context.tokenizer.unknownTokenId { forbidden.insert(unknown) }
        var detokenizer = context.tokenizer.makeStreamingDetokenizer()
        var recent: [Int] = []
        var generated = 0
        var accepted = 0
        var finished = false
        var draftingEnabled = true

        func sample(_ values: MLXArray, position: Int) throws -> Int {
            try Task.checkCancellation()
            let maskStart: ContinuousClock.Instant? = measurePhases ? .now : nil
            let mask = try constraint.computeMask()
            guard !mask.isTerminated else { throw Failure.invalidMask }
            var scores = values[0..., position, 0...]
            if mask.needsApply {
                guard mask.mask.count >= (vocabSize + 31) / 32 else { throw Failure.invalidMask }
                var additive = [Float](repeating: -.infinity, count: logitCount)
                var anyAllowed = false
                for id in 0..<vocabSize {
                    if UInt32(bitPattern: mask.mask[id / 32]) >> UInt32(id % 32) & 1 == 1 {
                        additive[id] = 0
                        anyAllowed = true
                    }
                }
                guard anyAllowed else { throw Failure.invalidMask }
                scores = scores + MLXArray(additive)
            }
            if let maskStart { metrics.grammarMicroseconds += micros(maskStart.duration(to: .now)) }
            let sampleStart: ContinuousClock.Instant? = measurePhases ? .now : nil
            let token = Int(argMax(scores, axis: -1).item(UInt32.self))
            if let sampleStart { metrics.samplingMicroseconds += micros(sampleStart.duration(to: .now)) }
            guard token < vocabSize, token != context.tokenizer.unknownTokenId else { throw Failure.invalidSample }
            return token
        }

        func commit(_ token: Int, origin: TokenOrigin) throws -> Bool {
            try Task.checkCancellation()
            let start: ContinuousClock.Instant? = measurePhases ? .now : nil
            let result = try constraint.commitToken(Int32(token))
            if let start { metrics.grammarMicroseconds += micros(start.duration(to: .now)) }
            guard result.tokens.isEmpty else { throw Failure.unexpectedFastForward }
            accepted += 1
            if stopIDs.contains(token) {
                guard result.isTerminated else { throw Failure.invalidSample }
                metrics.stopTokens += 1
                return true
            }
            guard generated < maxTokens else { throw Failure.incompleteOutput }
            generated += 1
            if origin == .sampled { metrics.sampledTokens += 1 } else { metrics.verifiedDraftTokens += 1 }
            recent.append(token)
            if recent.count > 8 { recent.removeFirst() }
            detokenizer.append(token: token)
            recordToken?(token, origin)
            if let text = detokenizer.next(), !emit(text) { throw Failure.consumerStopped }
            return result.isTerminated
        }

        func forward(_ tokens: [Int], into entries: [KVCache]) throws -> MLXArray {
            try Task.checkCancellation()
            let output = model(LMInput.Text(tokens: MLXArray(tokens.map(Int32.init)))[text: .newAxis],
                               cache: entries, state: nil)
            guard output.state == nil else { throw Failure.unsupportedModelState }
            eval(output.logits)
            try Task.checkCancellation()
            guard output.logits.ndim == 3, output.logits.dim(0) == 1,
                  output.logits.dim(1) == tokens.count, output.logits.dim(2) == logitCount else {
                throw Failure.invalidModelOutput
            }
            metrics.modelForwardCalls += 1
            metrics.modelForwardTokens += tokens.count
            _ = try cacheBytes(entries)
            return output.logits
        }

        while generated < maxTokens {
            let first = try sample(logits, position: -1)
            if try commit(first, origin: .sampled) { finished = true; break }
            guard generated < maxTokens else { throw Failure.incompleteOutput }
            let lookupStart: ContinuousClock.Instant? = measurePhases ? .now : nil
            let proposed = drafts.proposal(after: recent,
                maximum: draftingEnabled ? min(maximumDraftTokens, maxTokens - generated) : 0,
                vocabSize: vocabSize, forbidden: forbidden)
            if let lookupStart { metrics.lookupMicroseconds += micros(lookupStart.duration(to: .now)) }
            guard !proposed.isEmpty else {
                let start: ContinuousClock.Instant? = measurePhases ? .now : nil
                logits = try forward([first], into: caches)
                if !draftingEnabled { metrics.serialTokensAfterCutoff += 1 }
                if let start { metrics.serialForwardMicroseconds += micros(start.duration(to: .now)) }
                continue
            }
            let copyStart: ContinuousClock.Instant? = measurePhases ? .now : nil
            let originalBytes = try cacheBytes(caches)
            let originalOffsets = caches.map(\.offset)
            let trial = caches.map { $0.copy() }
            let trialBytes = try cacheBytes(trial)
            metrics.peakCombinedObservedCacheBackingBytes = max(metrics.peakCombinedObservedCacheBackingBytes, originalBytes + trialBytes)
            for (original, copy) in zip(caches, trial) {
                guard ObjectIdentifier(original as AnyObject) != ObjectIdentifier(copy as AnyObject),
                      original.offset == copy.offset,
                      original.state.map(\.shape) == copy.state.map(\.shape) else { throw Failure.unsupportedCache }
            }
            metrics.cacheCopies += trial.count
            metrics.copiedLogicalCacheStateBytes += caches.reduce(UInt64(0)) { sum, cache in
                sum + cache.state.reduce(UInt64(0)) { $0 + UInt64($1.nbytes) }
            }
            if let copyStart { metrics.copyMicroseconds += micros(copyStart.duration(to: .now)) }
            metrics.draftRounds += 1
            metrics.proposedTokens += proposed.count
            let verificationStart: ContinuousClock.Instant? = measurePhases ? .now : nil
            let trialLogits = try forward([first] + proposed, into: trial)
            if let verificationStart {
                metrics.verificationForwardMicroseconds += micros(verificationStart.duration(to: .now))
            }
            metrics.peakCombinedObservedCacheBackingBytes = max(metrics.peakCombinedObservedCacheBackingBytes,
                originalBytes + (try cacheBytes(trial)))
            guard caches.map(\.offset) == originalOffsets else { throw Failure.unsupportedCache }
            var verified = 0
            for (position, candidate) in proposed.enumerated() {
                // Never emit the mismatching speculative argmax. Replay first, then sample again.
                let actual = try sample(trialLogits, position: position)
                guard actual == candidate else {
                    metrics.rejectedRounds += 1
                    metrics.rejectedPositions[position, default: 0] += 1
                    if stopDraftingAfterRejection {
                        draftingEnabled = false
                        metrics.draftingStoppedAfterRejection = true
                        metrics.draftingStoppedAtGeneratedToken = generated
                    }
                    break
                }
                verified += 1
                if try commit(candidate, origin: .verifiedDraft) { finished = true; break }
            }
            if finished { break }
            if verified == proposed.count {
                metrics.fullyAcceptedRounds += 1
                caches = trial
                logits = trialLogits
            } else {
                let replay = [first] + proposed.prefix(verified)
                let replayStart: ContinuousClock.Instant? = measurePhases ? .now : nil
                logits = try forward(Array(replay), into: caches)
                metrics.replayTokens += replay.count
                if let replayStart { metrics.replayMicroseconds += micros(replayStart.duration(to: .now)) }
            }
        }
        try Task.checkCancellation()
        guard finished else { throw Failure.incompleteOutput }
        if let tail = detokenizer.finish(), !tail.isEmpty, !emit(tail) { throw Failure.consumerStopped }
        let counters = Counters(draftRounds: metrics.draftRounds, proposedTokens: metrics.proposedTokens,
            verifiedDraftTokens: metrics.verifiedDraftTokens, rejectedRounds: metrics.rejectedRounds,
            draftingStoppedAfterRejection: metrics.draftingStoppedAfterRejection,
            serialTokensAfterCutoff: metrics.serialTokensAfterCutoff,
            peakObservedCacheBackingBytes: metrics.peakObservedCacheBackingBytes,
            peakCombinedObservedCacheBackingBytes: metrics.peakCombinedObservedCacheBackingBytes)
        return Result(counters: counters, generatedTokens: generated, acceptedTokens: accepted,
                      metrics: measurePhases ? metrics : nil)
    }

    private static func micros(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        return UInt64(max(0, parts.seconds)) * 1_000_000 + UInt64(max(0, parts.attoseconds)) / 1_000_000_000_000
    }
}
