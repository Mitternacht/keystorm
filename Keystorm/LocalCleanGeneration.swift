import Foundation
import MLX
import MLXGuidedGeneration

/// Bounds the optional Clean optimization and owns its private-output transaction.
/// A typed resource incompatibility may retry once with a fresh grammar matcher.
/// Invalid generation, cancellation and quality failures never trigger that retry.
nonisolated enum LocalCleanGeneration {
    struct EligibilityInput {
        var enabled = true
        var mode: DictationOutputMode = .clean
        var hasContext = false
        var pinnedQwen = true
        var fullPromptTokens: Int
        var sourceUTF8Bytes: Int
        var prefixReused: Bool
        var uncachedTokens: Int
        var memoryCeiling: UInt64
        var processFootprint: UInt64
        var mlxBytes: UInt64
    }
    enum Eligibility: UInt64 {
        case eligible, disabled, mode, context, model, promptLimit, sourceLimit
        case prefixMissing, suffixLimit, headroom
    }
    static func eligibility(_ input: EligibilityInput) -> Eligibility {
        guard input.enabled else { return .disabled }
        guard input.mode == .clean else { return .mode }
        guard !input.hasContext else { return .context }
        guard input.pinnedQwen else { return .model }
        guard (1...1024).contains(input.fullPromptTokens) else { return .promptLimit }
        guard (1...1024).contains(input.sourceUTF8Bytes) else { return .sourceLimit }
        guard input.prefixReused else { return .prefixMissing }
        guard (1...128).contains(input.uncachedTokens) else { return .suffixLimit }
        // The fresh measurements include the retained prefix. This conservative allowance
        // covers two observed128MiB cache sets plus prefill/logit/scratch work; it is not
        // an allocator guarantee. Aggregate parent/worker memory remains a qualification gate.
        let ceiling = min(input.memoryCeiling, 4 * 1_024 * 1_024 * 1_024)
        let reserve: UInt64 = 1_024 * 1_024 * 1_024
        guard ceiling >= reserve, input.processFootprint > 0,
              input.processFootprint <= ceiling - reserve, input.mlxBytes <= ceiling - reserve else {
            return .headroom
        }
        return .eligible
    }

    enum FallbackReason: UInt64 { case none, unsupportedCache, cacheLimit, unsupportedModelState }
    struct LoopResult {
        let generatedTokens: Int
        let acceptedTokens: Int
        var counters: SourceDraftGeneration.Counters? = nil
    }
    struct Result {
        let envelope: String
        let generatedTokens: Int
        let counters: SourceDraftGeneration.Counters?
        let usedCandidate: Bool
        let attemptCount: Int
        let fallbackReason: FallbackReason
        let generationMicroseconds: UInt64
        let firstDeltaMicroseconds: UInt64?
    }

    final class Attempt {
        private let started: ContinuousClock.Instant
        private let maximumBytes: Int
        fileprivate var envelope = ""
        fileprivate var byteCount = 0
        fileprivate var recordedTokens = 0
        fileprivate var exceededEnvelopeLimit = false
        fileprivate var firstDeltaMicroseconds: UInt64?

        fileprivate init(started: ContinuousClock.Instant, maximumBytes: Int) {
            self.started = started
            self.maximumBytes = maximumBytes
        }
        func recordGeneratedToken() { recordedTokens += 1 }
        func emit(_ delta: String) -> Bool {
            guard !Task.isCancelled else { return false }
            let bytes = delta.utf8.count
            guard bytes <= maximumBytes - byteCount else {
                exceededEnvelopeLimit = true
                return false
            }
            if firstDeltaMicroseconds == nil {
                firstDeltaMicroseconds = LocalCleanGeneration.microseconds(started.duration(to: .now))
            }
            byteCount += bytes
            envelope += delta
            return true
        }
    }
    typealias Operation = (GrammarConstraint, Attempt) throws -> LoopResult

    static func run(grammar: LocalGrammarCache, outputLimit: Int, maximumEnvelopeBytes: Int,
                    candidate: Operation?, baseline: Operation) throws -> Result {
        guard outputLimit > 0, maximumEnvelopeBytes > 0 else { throw SourceDraftGeneration.Failure.invalidInput }
        try Task.checkCancellation()
        let started = ContinuousClock.now
        var attempts = 0
        func attempt(_ operation: Operation, candidate: Bool, reason: FallbackReason) throws -> Result {
            attempts += 1
            let progress = Attempt(started: started, maximumBytes: maximumEnvelopeBytes)
            let loop: LoopResult
            do {
                loop = try grammar.withConstraint(for: .dictationTransform) { matcher in
                    let value = try operation(matcher, progress)
                    try Task.checkCancellation()
                    guard !progress.exceededEnvelopeLimit, value.generatedTokens >= 0,
                          value.generatedTokens < outputLimit,
                          value.acceptedTokens >= value.generatedTokens,
                          value.acceptedTokens <= value.generatedTokens + 1 else {
                        throw DictationTransformGenerationFailure(
                            message: "The transform reached its output limit. No partial rewrite was applied; the original is saved.",
                            generatedEnvelope: progress.envelope,
                            generatedTokens: max(value.generatedTokens, progress.recordedTokens))
                    }
                    return (value: value, acceptedTokens: value.acceptedTokens)
                }
            } catch {
                // Preserve the original cancellation type, including a consumer stop caused
                // by cancellation between two emitted deltas.
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if error is DictationTransformGenerationFailure { throw error }
                if progress.exceededEnvelopeLimit || (error as? SourceDraftGeneration.Failure) == .incompleteOutput {
                    throw DictationTransformGenerationFailure(
                        message: "The transform reached its output limit. No partial rewrite was applied; the original is saved.",
                        generatedEnvelope: progress.envelope, generatedTokens: progress.recordedTokens)
                }
                if (error as? SourceDraftGeneration.Failure) == .consumerStopped {
                    throw DictationTransformGenerationFailure(
                        message: "The transform stopped before completion. No partial rewrite was applied; the original is saved.",
                        generatedEnvelope: progress.envelope, generatedTokens: progress.recordedTokens)
                }
                throw error
            }
            return Result(envelope: progress.envelope, generatedTokens: loop.generatedTokens,
                counters: loop.counters, usedCandidate: candidate, attemptCount: attempts,
                fallbackReason: reason, generationMicroseconds: microseconds(started.duration(to: .now)),
                firstDeltaMicroseconds: progress.firstDeltaMicroseconds)
        }
        guard let candidate else { return try attempt(baseline, candidate: false, reason: .none) }
        do {
            return try attempt(candidate, candidate: true, reason: .none)
        } catch {
            try Task.checkCancellation()
            let reason: FallbackReason
            switch error as? SourceDraftGeneration.Failure {
            case .unsupportedCache: reason = .unsupportedCache
            case .cacheLimit: reason = .cacheLimit
            case .unsupportedModelState: reason = .unsupportedModelState
            default: throw error
            }
            // The first operation has unwound: its matcher and private output are discarded.
            // Each loop creates a new model cache; clear released scratch before the sole retry.
            MLX.Memory.clearCache()
            return try attempt(baseline, candidate: false, reason: reason)
        }
    }

    private static func microseconds(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        return UInt64(max(0, parts.seconds)) * 1_000_000 + UInt64(max(0, parts.attoseconds)) / 1_000_000_000_000
    }
}
