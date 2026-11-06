import Foundation
import MLXGuidedGeneration
import Testing
@testable import Keystorm

/// Exercises the production admission and retry boundary with real grammar state.
/// Model forwarding and cache-isolation behavior have separate SourceDraftGeneration tests.
@Suite(.serialized)
struct LocalCleanGenerationTests {
    @Test("Clean admission includes exact byte, full-prompt, suffix and memory boundaries")
    func eligibleBoundaries() {
        var input = CleanEligibilityCase.input()
        #expect(LocalCleanGeneration.eligibility(input) == .eligible)
        input.fullPromptTokens = 1
        input.sourceUTF8Bytes = 1
        input.uncachedTokens = 1
        #expect(LocalCleanGeneration.eligibility(input) == .eligible)
        input.memoryCeiling = UInt64.max
        #expect(LocalCleanGeneration.eligibility(input) == .eligible)
        input.processFootprint += 1
        #expect(LocalCleanGeneration.eligibility(input) == .headroom,
                "A very large configured ceiling must not bypass the conservative 4 GiB admission ceiling.")
    }

    @Test("Each unsupported admission condition keeps generation on the baseline",
          arguments: CleanEligibilityCase.allCases)
    func rejectedEligibility(reason: CleanEligibilityCase) {
        let (input, expected) = reason.fixture()
        #expect(LocalCleanGeneration.eligibility(input) == expected)
    }

    @Test("Source admission counts UTF-8 bytes rather than visible characters")
    func unicodeByteBoundary() {
        var input = CleanEligibilityCase.input()
        let source = String(repeating: "ü", count: 512)
        #expect(source.count == 512 && source.utf8.count == 1_024)
        input.sourceUTF8Bytes = source.utf8.count
        #expect(LocalCleanGeneration.eligibility(input) == .eligible)
        input.sourceUTF8Bytes = (source + "a").utf8.count
        #expect(LocalCleanGeneration.eligibility(input) == .sourceLimit)
    }

    @Test("A successful candidate returns only its complete envelope and restores the matcher")
    func successfulCandidateAndNextRequest() throws {
        let fixture = try CleanRetryFixture()
        var baselineCalls = 0
        for textToken in [Int32(6), 7] {
            let result = try LocalCleanGeneration.run(grammar: fixture.grammar,
                outputLimit: 64, maximumEnvelopeBytes: 512, candidate: { matcher, attempt in
                    try fixture.requirePristine(matcher)
                    return try fixture.complete(matcher, attempt: attempt, textToken: textToken)
                }, baseline: { _, _ in
                    baselineCalls += 1
                    throw CleanRetryError.unexpectedBaseline
                })
            #expect(result.envelope == fixture.envelope(textToken: textToken))
            #expect(result.generatedTokens == 9)
            #expect(result.usedCandidate)
            #expect(result.attemptCount == 1 && result.fallbackReason == .none)
            #expect(result.firstDeltaMicroseconds != nil)
            if let first = result.firstDeltaMicroseconds {
                #expect(first <= result.generationMicroseconds)
            }
        }
        #expect(baselineCalls == 0)
        #expect(fixture.grammar.statistics()["grammarSchemaCompilations"] == 1,
                "Accepted terminal EOS must be included when rewinding the reusable matcher.")
    }

    @Test("A nil candidate executes exactly one pristine baseline attempt")
    func ineligibleUsesBaselineOnly() throws {
        let fixture = try CleanRetryFixture()
        var baselineCalls = 0
        let result = try LocalCleanGeneration.run(grammar: fixture.grammar,
            outputLimit: 64, maximumEnvelopeBytes: 512, candidate: nil,
            baseline: { matcher, attempt in
                baselineCalls += 1
                try fixture.requirePristine(matcher)
                return try fixture.complete(matcher, attempt: attempt, textToken: 7)
            })
        #expect(baselineCalls == 1)
        #expect(!result.usedCandidate && result.attemptCount == 1)
        #expect(result.fallbackReason == .none)
        #expect(result.envelope == fixture.envelope(textToken: 7))
    }

    @Test("Typed unsupported and capacity failures discard partial output before one fresh retry",
          arguments: [SourceDraftGeneration.Failure.unsupportedCache, .cacheLimit, .unsupportedModelState],
          [0, 4])
    func typedFallback(error: SourceDraftGeneration.Failure, prefixCount: Int) throws {
        let fixture = try CleanRetryFixture()
        var candidateCalls = 0
        var baselineCalls = 0
        var abandonedMatcher: GrammarConstraint?
        let result = try LocalCleanGeneration.run(grammar: fixture.grammar,
            outputLimit: 64, maximumEnvelopeBytes: 512,
            candidate: { matcher, attempt in
                candidateCalls += 1
                abandonedMatcher = matcher
                try fixture.requirePristine(matcher)
                try fixture.partial(matcher, attempt: attempt, count: prefixCount)
                throw error
            }, baseline: { matcher, attempt in
                baselineCalls += 1
                #expect(abandonedMatcher !== matcher)
                try fixture.requirePristine(matcher)
                return try fixture.complete(matcher, attempt: attempt, textToken: 7)
            })
        #expect(candidateCalls == 1 && baselineCalls == 1)
        #expect(result.attemptCount == 2 && !result.usedCandidate)
        #expect(result.fallbackReason == CleanRetryFixture.reason(for: error))
        #expect(result.envelope == fixture.envelope(textToken: 7),
                "Discarded prefix bytes must not be prepended to the baseline's envelope.")
        #expect(result.generatedTokens == 9)
        #expect(result.firstDeltaMicroseconds != nil)
        let next = try LocalCleanGeneration.run(grammar: fixture.grammar,
            outputLimit: 64, maximumEnvelopeBytes: 512, candidate: nil,
            baseline: { matcher, attempt in
                try fixture.requirePristine(matcher)
                return try fixture.complete(matcher, attempt: attempt, textToken: 6)
            })
        #expect(next.envelope == fixture.envelope(textToken: 6))
        #expect(next.fallbackReason == .none && next.attemptCount == 1)
    }

    @Test("A failed baseline retry cannot return either attempt's partial envelope")
    func failedFallbackIsNotPublished() throws {
        let fixture = try CleanRetryFixture()
        var candidateCalls = 0
        var baselineCalls = 0
        var returned: LocalCleanGeneration.Result?
        #expect(throws: CleanRetryError.baselineUnavailable) {
            returned = try LocalCleanGeneration.run(grammar: fixture.grammar,
                outputLimit: 64, maximumEnvelopeBytes: 512,
                candidate: { matcher, attempt in
                    candidateCalls += 1
                    try fixture.partial(matcher, attempt: attempt, count: 4)
                    throw SourceDraftGeneration.Failure.cacheLimit
                }, baseline: { matcher, attempt in
                    baselineCalls += 1
                    try fixture.requirePristine(matcher)
                    try fixture.partial(matcher, attempt: attempt, count: 3)
                    throw CleanRetryError.baselineUnavailable
                })
        }
        #expect(candidateCalls == 1 && baselineCalls == 1)
        #expect(returned == nil)
        let next = try LocalCleanGeneration.run(grammar: fixture.grammar,
            outputLimit: 64, maximumEnvelopeBytes: 512, candidate: nil,
            baseline: { matcher, attempt in
                try fixture.requirePristine(matcher)
                return try fixture.complete(matcher, attempt: attempt, textToken: 6)
            })
        #expect(next.envelope == fixture.envelope(textToken: 6))
    }

    @Test("Generation invariant failures never silently invoke the baseline",
          arguments: [SourceDraftGeneration.Failure.invalidInput, .invalidModelOutput,
                      .invalidMask, .invalidSample, .unexpectedFastForward])
    func invariantFailureDoesNotRetry(error: SourceDraftGeneration.Failure) throws {
        let fixture = try CleanRetryFixture()
        var baselineCalls = 0
        #expect(throws: error) {
            _ = try LocalCleanGeneration.run(grammar: fixture.grammar,
                outputLimit: 64, maximumEnvelopeBytes: 512,
                candidate: { matcher, attempt in
                    try fixture.partial(matcher, attempt: attempt, count: 4)
                    throw error
                }, baseline: { _, _ in
                    baselineCalls += 1
                    throw CleanRetryError.unexpectedBaseline
                })
        }
        #expect(baselineCalls == 0)
    }

    @Test("Consumer stop and incomplete output remain terminal failures",
          arguments: [SourceDraftGeneration.Failure.consumerStopped, .incompleteOutput])
    func incompleteAttemptDoesNotRetry(error: SourceDraftGeneration.Failure) throws {
        let fixture = try CleanRetryFixture()
        var baselineCalls = 0
        var returned: LocalCleanGeneration.Result?
        #expect(throws: DictationTransformGenerationFailure.self) {
            returned = try LocalCleanGeneration.run(grammar: fixture.grammar,
                outputLimit: 64, maximumEnvelopeBytes: 512,
                candidate: { matcher, attempt in
                    try fixture.partial(matcher, attempt: attempt, count: 4)
                    throw error
                }, baseline: { _, _ in
                    baselineCalls += 1
                    throw CleanRetryError.unexpectedBaseline
                })
        }
        #expect(returned == nil && baselineCalls == 0)
    }

    @Test("Envelope and token bounds cannot be bypassed by retrying",
          arguments: [true, false])
    func outputBoundsDoNotRetry(byteLimit: Bool) throws {
        let fixture = try CleanRetryFixture()
        var baselineCalls = 0
        var returned: LocalCleanGeneration.Result?
        #expect(throws: DictationTransformGenerationFailure.self) {
            returned = try LocalCleanGeneration.run(grammar: fixture.grammar,
                outputLimit: byteLimit ? 64 : 9, maximumEnvelopeBytes: byteLimit ? 5 : 512,
                candidate: { matcher, attempt in
                    try fixture.complete(matcher, attempt: attempt, textToken: 6)
                }, baseline: { _, _ in
                    baselineCalls += 1
                    throw CleanRetryError.unexpectedBaseline
                })
        }
        #expect(returned == nil && baselineCalls == 0)
    }

    @Test("Baseline overflow preserves returned token counts when no per-token sink is bound")
    func baselineOverflowPreservesReturnedCount() throws {
        let fixture = try CleanRetryFixture()
        var baselineCalls = 0
        do {
            _ = try LocalCleanGeneration.run(grammar: fixture.grammar,
                outputLimit: 64, maximumEnvelopeBytes: 5, candidate: nil,
                baseline: { matcher, attempt in
                    baselineCalls += 1
                    let tokens: [Int32] = [0, 1, 2, 3, 4, 5, 2, 6, 8]
                    for token in tokens { _ = try matcher.commitToken(token) }
                    // Production's upstream path returns its count without binding the
                    // optional per-token diagnostic sink used by the local adapter.
                    let admitted = attempt.emit(fixture.envelope(textToken: 6))
                    #expect(!admitted)
                    return .init(generatedTokens: 9, acceptedTokens: 9)
                })
            Issue.record("An overflowing baseline must not publish a result.")
        } catch let failure as DictationTransformGenerationFailure {
            #expect(failure.generatedTokens == 9,
                    "Wrapping an already-typed failure must not replace its count with zero.")
            #expect(failure.generatedEnvelope.isEmpty)
        }
        #expect(baselineCalls == 1)
    }

    @Test("Cancellation after a private delta discards the matcher without retrying")
    func cancellationDoesNotRetry() async throws {
        let fixture = try CleanRetryFixture()
        let task = Task {
            var baselineCalls = 0
            do {
                _ = try LocalCleanGeneration.run(grammar: fixture.grammar,
                    outputLimit: 64, maximumEnvelopeBytes: 512,
                    candidate: { matcher, attempt in
                        try fixture.partial(matcher, attempt: attempt, count: 4)
                        withUnsafeCurrentTask { $0?.cancel() }
                        throw SourceDraftGeneration.Failure.cacheLimit
                    }, baseline: { _, _ in
                        baselineCalls += 1
                        throw CleanRetryError.unexpectedBaseline
                    })
                return false
            } catch is CancellationError {
                return baselineCalls == 0
            }
        }
        #expect(try await task.value)
        let next = try LocalCleanGeneration.run(grammar: fixture.grammar,
            outputLimit: 64, maximumEnvelopeBytes: 512, candidate: nil,
            baseline: { matcher, attempt in
                try fixture.requirePristine(matcher)
                return try fixture.complete(matcher, attempt: attempt, textToken: 7)
            })
        #expect(next.envelope == fixture.envelope(textToken: 7))
    }
}

nonisolated enum CleanEligibilityCase: CaseIterable {
    case disabled, otherMode, context, wrongModel
    case emptyPrompt, oversizedPrompt, emptySource, oversizedSource
    case prefixMissing, emptySuffix, oversizedSuffix
    case missingFootprint, processHeadroom, mlxHeadroom, tinyCeiling, hugeFootprint, hugeMLX

    static let gib: UInt64 = 1_024 * 1_024 * 1_024

    static func input() -> LocalCleanGeneration.EligibilityInput {
        .init(fullPromptTokens: 1_024, sourceUTF8Bytes: 1_024,
              prefixReused: true, uncachedTokens: 128,
              memoryCeiling: 6 * gib, processFootprint: 3 * gib, mlxBytes: 3 * gib)
    }

    func fixture() -> (LocalCleanGeneration.EligibilityInput, LocalCleanGeneration.Eligibility) {
        var value = Self.input()
        switch self {
        case .disabled: value.enabled = false; return (value, .disabled)
        case .otherMode: value.mode = .email; return (value, .mode)
        case .context: value.hasContext = true; return (value, .context)
        case .wrongModel: value.pinnedQwen = false; return (value, .model)
        case .emptyPrompt: value.fullPromptTokens = 0; return (value, .promptLimit)
        case .oversizedPrompt: value.fullPromptTokens = 1_025; return (value, .promptLimit)
        case .emptySource: value.sourceUTF8Bytes = 0; return (value, .sourceLimit)
        case .oversizedSource: value.sourceUTF8Bytes = 1_025; return (value, .sourceLimit)
        case .prefixMissing: value.prefixReused = false; return (value, .prefixMissing)
        case .emptySuffix: value.uncachedTokens = 0; return (value, .suffixLimit)
        case .oversizedSuffix: value.uncachedTokens = 129; return (value, .suffixLimit)
        case .missingFootprint: value.processFootprint = 0; return (value, .headroom)
        case .processHeadroom: value.processFootprint = 3 * Self.gib + 1; return (value, .headroom)
        case .mlxHeadroom: value.mlxBytes = 3 * Self.gib + 1; return (value, .headroom)
        case .tinyCeiling: value.memoryCeiling = Self.gib - 1; return (value, .headroom)
        case .hugeFootprint: value.processFootprint = UInt64.max; return (value, .headroom)
        case .hugeMLX: value.mlxBytes = UInt64.max; return (value, .headroom)
        }
    }
}

nonisolated private enum CleanRetryError: Error, Equatable {
    case unexpectedBaseline, baselineUnavailable
}

nonisolated private final class CleanRetryFixture: @unchecked Sendable {
    let grammar: LocalGrammarCache
    let initialMask: [Int32]
    private let pieces = ["{", "\"complete\"", ":", "true", ",", "\"text\"",
                          "\"alpha\"", "\"beta\"", "}", "<eos>"]

    init() throws {
        let tokenizer = try GrammarTokenizer(
            vocab: ["{", "\"complete\"", ":", "true", ",", "\"text\"",
                    "\"alpha\"", "\"beta\"", "}", "<eos>"], vocabType: .raw, eosTokenId: 9)
        let probe = LocalGrammarCache(tokenizer: tokenizer)
        initialMask = try probe.constraint(for: .dictationTransform).computeMask().mask
        // A separate probe keeps compilation-count assertions scoped to production attempts.
        grammar = LocalGrammarCache(tokenizer: tokenizer)
    }

    func requirePristine(_ matcher: GrammarConstraint) throws {
        let mask = try matcher.computeMask()
        try #require(mask.mask == initialMask && !mask.isTerminated)
    }

    func envelope(textToken: Int32) -> String {
        "{\"complete\":true,\"text\":" + pieces[Int(textToken)] + "}"
    }

    func partial(_ matcher: GrammarConstraint, attempt: LocalCleanGeneration.Attempt,
                 count: Int) throws {
        let prefix: [Int32] = [0, 1, 2, 3]
        for token in prefix.prefix(count) {
            _ = try matcher.commitToken(token)
            attempt.recordGeneratedToken()
            guard attempt.emit(pieces[Int(token)]) else {
                throw SourceDraftGeneration.Failure.consumerStopped
            }
        }
    }

    func complete(_ matcher: GrammarConstraint, attempt: LocalCleanGeneration.Attempt,
                  textToken: Int32) throws -> LocalCleanGeneration.LoopResult {
        try requirePristine(matcher)
        var terminated = false
        let tokens: [Int32] = [0, 1, 2, 3, 4, 5, 2, textToken, 8, 9]
        for token in tokens {
            let committed = try matcher.commitToken(token)
            try #require(committed.tokens.isEmpty)
            terminated = committed.isTerminated
            if token != 9 {
                attempt.recordGeneratedToken()
                guard attempt.emit(pieces[Int(token)]) else {
                    throw SourceDraftGeneration.Failure.consumerStopped
                }
            }
        }
        try #require(terminated)
        return .init(generatedTokens: 9, acceptedTokens: 10)
    }

    static func reason(for failure: SourceDraftGeneration.Failure) -> LocalCleanGeneration.FallbackReason {
        switch failure {
        case .unsupportedCache: .unsupportedCache
        case .cacheLimit: .cacheLimit
        case .unsupportedModelState: .unsupportedModelState
        default: .none
        }
    }
}
