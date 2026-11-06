import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// One fixed-system-prefix snapshot for the currently loaded Qwen3.5 text model.
/// All attention, convolution and recurrent cache entries are copied for each job.
/// Dictated text and generated continuations never enter the retained snapshot.
final class LocalTextPrefixCache: @unchecked Sendable {
    static let maximumPrefixTokens = 1_024
    static let maximumRetainedBytes: UInt64 = 128 * 1_024 * 1_024
    private static let minimumPrefixTokens = 32

    struct Prepared {
        let input: LMInput
        let model: any LanguageModel
    }

    private struct Snapshot {
        let model: any LanguageModel
        let tokens: [Int]
        let caches: [KVCache]
        let bytes: UInt64
    }

    private let lock = NSLock()
    private var snapshot: Snapshot?
    private var builds: UInt64 = 0
    private var hits: UInt64 = 0
    private var reusedTokens: UInt64 = 0
    private var buildMicroseconds: UInt64 = 0
    private var preparationAttempts: UInt64 = 0
    private var preparationFailures: UInt64 = 0
    private var modelKind: UInt64 = 0
    private var candidateTokens: UInt64 = 0
    private var candidateBytes: UInt64 = 0
    private var lastBypass: Bypass = .none
    private enum Bypass: UInt64 {
        case none, unsupportedModel, unsupportedInput, shortPrefix, shortSuffix
        case noMemoryHeadroom, extraModelState, oversizedSnapshot
    }

    static func commonPrefixCount(systemTokens: [Int], inputTokens: [Int]) -> Int {
        var count = 0
        for (fixed, actual) in zip(systemTokens, inputTokens).prefix(maximumPrefixTokens) {
            guard fixed == actual else { break }
            count += 1
        }
        return count
    }

    /// Supports only the pinned text-only Qwen models. Their ordinary forward pass puts
    /// every state component in KVCache/MambaCache and returns no separate LMOutput.State.
    func prepare(_ input: LMInput, systemTokens: [Int], model: any LanguageModel,
                 maximumBytes: UInt64 = maximumRetainedBytes) throws -> Prepared? {
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        preparationAttempts += 1
        modelKind = model is Qwen35Model ? 1 : (model is Qwen35TextModel ? 2 : 0)
        candidateTokens = 0
        candidateBytes = 0
        lastBypass = .none
        guard modelKind != 0 else { lastBypass = .unsupportedModel; return nil }
        guard input.text.tokens.ndim == 1, input.text.mask == nil,
              input.image == nil, input.video == nil, input.audio == nil else {
            lastBypass = .unsupportedInput
            return nil
        }
        let allTokens = input.text.tokens.asArray(Int32.self).map(Int.init)
        let count = Self.commonPrefixCount(systemTokens: systemTokens, inputTokens: allTokens)
        candidateTokens = UInt64(count)
        guard count >= Self.minimumPrefixTokens else { lastBypass = .shortPrefix; return nil }
        // A single-token suffix enters Qwen's compiled decodeStep instead of its general
        // prefill path. Preserve full prefill there: split and unsplit logits differ beyond
        // our equivalence bound, even when the sampled continuation happens to match.
        guard allTokens.count - count >= 2 else { lastBypass = .shortSuffix; return nil }
        guard maximumBytes > 0 else {
            snapshot = nil
            lastBypass = .noMemoryHeadroom
            return nil
        }
        let prefix = Array(allTokens.prefix(count))
        let retained: Snapshot
        if let cached = snapshot, cached.model === model, cached.tokens == prefix,
           cached.bytes <= maximumBytes {
            retained = cached
            candidateBytes = cached.bytes
            hits += 1
            reusedTokens += UInt64(count)
        } else {
            snapshot = nil
            let started = ContinuousClock.now
            let caches = try model.newCache(parameters: nil)
            let prepared = try model.prepare(LMInput(tokens: MLXArray(prefix)),
                cache: caches, state: nil, prefill: .init())
            let state: LMOutput.State?
            switch prepared {
            case .tokens(let remaining):
                state = model(remaining[text: .newAxis], cache: caches, state: nil).state
            case .logits(let output):
                state = output.state
            }
            // Fail closed if a future model needs extra state that this snapshot cannot copy.
            guard state == nil else { lastBypass = .extraModelState; return nil }
            eval(caches)
            try Task.checkCancellation()
            let bytes = caches.flatMap { $0.innerState() }.reduce(UInt64(0)) { $0 + UInt64($1.nbytes) }
            candidateBytes = bytes
            guard bytes <= min(maximumBytes, Self.maximumRetainedBytes) else {
                lastBypass = .oversizedSnapshot
                return nil
            }
            retained = Snapshot(model: model, tokens: prefix, caches: caches, bytes: bytes)
            snapshot = retained
            builds += 1
            let elapsed = started.duration(to: .now).components
            buildMicroseconds += UInt64(max(0, elapsed.seconds)) * 1_000_000
                + UInt64(max(0, elapsed.attoseconds)) / 1_000_000_000_000
        }
        return Prepared(input: LMInput(tokens: input.text.tokens[count...]),
            model: PrefixContinuationModel(base: model, prefix: retained.caches))
    }

    func recordPreparationFailure() {
        lock.lock()
        preparationFailures += 1
        lock.unlock()
    }

    func clear() {
        lock.lock()
        snapshot = nil
        lock.unlock()
    }

    func statistics() -> [String: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return ["textModelPrefixBuilds": builds, "textModelPrefixHits": hits,
                "textModelPrefixReusedTokens": reusedTokens,
                "textModelPrefixBuildMicroseconds": buildMicroseconds,
                "textModelPrefixRetainedBytes": snapshot?.bytes ?? 0,
                "textModelPrefixPreparationAttempts": preparationAttempts,
                "textModelPrefixPreparationFailures": preparationFailures,
                "textModelPrefixModelKind": modelKind,
                "textModelPrefixCandidateTokens": candidateTokens,
                "textModelPrefixCandidateBytes": candidateBytes,
                "textModelPrefixLastBypassReason": lastBypass.rawValue]
    }
}

/// Supplies isolated populated caches to the existing guided loop without forking that loop.
/// It receives only the uncached suffix; KVCacheStorage infers the preceding token count
/// from the seeded cache offsets. The pinned guided loop samples with grammar-masked
/// argmax and has no prompt-history/repetition processor. Revisit this adapter if a runtime
/// upgrade adds one: such a processor must still receive the complete original prompt.
private final class PrefixContinuationModel: Module, LanguageModel {
    private let base: any LanguageModel
    private let prefix: [KVCache]

    init(base: any LanguageModel, prefix: [KVCache]) {
        self.base = base
        self.prefix = prefix
    }

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] {
        guard parameters?.maxKVSize == nil, parameters?.kvCache == nil,
              parameters?.kvBits == nil, parameters?.kvScheme == nil else {
            throw KeystormError.message("This generation cache configuration cannot reuse the prepared prefix.")
        }
        return prefix.map { $0.copy() }
    }

    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?,
                 prefill: PrefillParameters) throws -> PrepareResult {
        try base.prepare(input, cache: cache, state: state, prefill: prefill)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        base(input, cache: cache, state: state)
    }

    func nextTokenLogits(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        base.nextTokenLogits(input, cache: cache, state: state)
    }
}
