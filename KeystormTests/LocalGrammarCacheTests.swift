import Foundation
import MLXGuidedGeneration
import Testing
@testable import Keystorm

struct LocalGrammarCacheTests {
    @Test("Cached vocabulary always supplies an untouched matcher")
    func freshMatchers() throws {
        let tokenizer = try GrammarTokenizer(
            vocab: ["{", "}", "\"", ":", ",", "true", "false", "[", "]", "<eos>"],
            vocabType: .raw, eosTokenId: 9)
        let cache = LocalGrammarCache(tokenizer: tokenizer)
        let first = try cache.constraint(for: .extraction)
        let initialMask = try first.computeMask().mask
        _ = try first.commitToken(0)
        let advancedMask = try first.computeMask().mask
        let second = try cache.constraint(for: .extraction)
        #expect(try second.computeMask().mask == initialMask)
        #expect(advancedMask != initialMask)
        #expect(cache.statistics()["grammarSchemaCompilations"] == 2)
        #expect(cache.statistics()["grammarMatchersCreated"] == 2)
        _ = try cache.constraint(for: .edit)
        #expect(cache.statistics()["grammarSchemaCompilations"] == 3)
        #expect(cache.statistics()["grammarMatchersCreated"] == 3)
        let replacementCache = LocalGrammarCache(tokenizer: tokenizer)
        #expect(replacementCache.statistics()["grammarSchemaCompilations"] == 0)
        #expect(replacementCache.statistics()["grammarMatchersCreated"] == 0)
    }

    @Test("Priming compiles ahead, hands out nothing, and the next job reuses that work")
    func primingCompilesAhead() throws {
        let tokenizer = try GrammarTokenizer(
            vocab: ["{", "}", "\"", ":", ",", "true", "false", "[", "]", "<eos>"],
            vocabType: .raw, eosTokenId: 9)
        let cache = LocalGrammarCache(tokenizer: tokenizer)
        try cache.prime(.dictationTransform)
        try cache.prime(.dictationTransform)
        #expect(cache.statistics()["grammarSchemaCompilations"] == 1)
        #expect(cache.statistics()["grammarMatchersCreated"] == 0)
        let initial = try LocalGrammarCache(tokenizer: tokenizer).constraint(for: .dictationTransform).computeMask().mask
        let first = try cache.constraint(for: .dictationTransform)
        #expect(try first.computeMask().mask == initial)
        #expect(cache.statistics()["grammarSchemaCompilations"] == 1)
        #expect(cache.statistics()["grammarMatchersCreated"] == 1)
    }
}


struct LocalGrammarReuseTests {
    private func makeCache() throws -> LocalGrammarCache {
        let tokenizer = try GrammarTokenizer(
            vocab: ["{", "}", "\"", ":", ",", "true", "false", "[", "]", "<eos>"],
            vocabType: .raw, eosTokenId: 9)
        return LocalGrammarCache(tokenizer: tokenizer)
    }

    @Test("Completed scoped matchers reuse compilation and restore the original token mask")
    func completedMatchersReuseCompilation() throws {
        let cache = try makeCache()
        let initialMask = try makeCache().constraint(for: .dictationTransform).computeMask().mask
        for index in 0..<4 {
            let result = try cache.withConstraint(for: .dictationTransform) { matcher in
                let untouched = try matcher.computeMask().mask
                #expect(untouched == initialMask)
                _ = try matcher.commitToken(0)
                #expect(try matcher.computeMask().mask != initialMask)
                return (value: index, acceptedTokens: 1)
            }
            #expect(result == index)
        }
        #expect(cache.statistics()["grammarSchemaCompilations"] == 1)
        #expect(cache.statistics()["grammarMatchersCreated"] == 4)
    }

    @Test("A fully terminated JSON matcher rewinds and can complete a different job")
    func terminatedMatcherCanBeReused() throws {
        let tokenizer = try GrammarTokenizer(
            vocab: ["{", "\"complete\"", ":", "true", ",", "\"text\"", "\"\"", "}", "<eos>"],
            vocabType: .raw, eosTokenId: 8)
        let cache = LocalGrammarCache(tokenizer: tokenizer)
        let tokens: [Int32] = [0, 1, 2, 3, 4, 5, 2, 6, 7, 8]
        for _ in 0..<2 {
            let terminated = try cache.withConstraint(for: .dictationTransform) { matcher in
                #expect(try !matcher.computeMask().isTerminated)
                var finished = false
                for token in tokens { finished = try matcher.commitToken(token).isTerminated }
                #expect(finished)
                return (value: finished, acceptedTokens: tokens.count)
            }
            #expect(terminated)
        }
        #expect(cache.statistics()["grammarSchemaCompilations"] == 1)
    }

    @Test("An interrupted matcher is discarded instead of leaking its state to the next job")
    func failedLeaseIsDiscarded() throws {
        enum Interrupted: Error { case generation }
        let cache = try makeCache()
        let initialMask = try makeCache().constraint(for: .dictationTransform).computeMask().mask
        #expect(throws: Interrupted.self) {
            let _: Int = try cache.withConstraint(for: .dictationTransform) { matcher in
                _ = try matcher.commitToken(0)
                throw Interrupted.generation
            }
        }
        let result = try cache.withConstraint(for: .dictationTransform) { matcher in
            let untouched = try matcher.computeMask().mask
            #expect(untouched == initialMask)
            return (value: 42, acceptedTokens: 0)
        }
        #expect(result == 42)
        #expect(cache.statistics()["grammarSchemaCompilations"] == 2)
    }

    @Test("A failed reset discards the matcher while preserving the completed result")
    func mismatchedResetIsDiscarded() throws {
        let cache = try makeCache()
        let initialMask = try makeCache().constraint(for: .dictationTransform).computeMask().mask
        let first = try cache.withConstraint(for: .dictationTransform) { matcher in
            _ = try matcher.commitToken(0)
            return (value: 42, acceptedTokens: 0)
        }
        #expect(first == 42)
        _ = try cache.withConstraint(for: .dictationTransform) { matcher in
            let untouched = try matcher.computeMask().mask
            #expect(untouched == initialMask)
            return (value: (), acceptedTokens: 0)
        }
        #expect(cache.statistics()["grammarSchemaCompilations"] == 2)
    }

    @Test("Overlapping scoped matchers never share mutable state")
    func overlappingLeasesAreIsolated() throws {
        let cache = try makeCache()
        let initialMask = try makeCache().constraint(for: .extraction).computeMask().mask
        _ = try cache.withConstraint(for: .extraction) { outer in
            _ = try outer.commitToken(0)
            let advancedMask = try outer.computeMask().mask
            _ = try cache.withConstraint(for: .extraction) { inner in
                let innerMask = try inner.computeMask().mask
                #expect(innerMask == initialMask)
                let outerMask = try outer.computeMask().mask
                #expect(outerMask == advancedMask)
                return (value: (), acceptedTokens: 0)
            }
            let outerMask = try outer.computeMask().mask
            #expect(outerMask == advancedMask)
            return (value: (), acceptedTokens: 1)
        }
        _ = try cache.withConstraint(for: .extraction) { matcher in
            let untouched = try matcher.computeMask().mask
            #expect(untouched == initialMask)
            return (value: (), acceptedTokens: 0)
        }
        #expect(cache.statistics()["grammarSchemaCompilations"] == 2)
    }

    @Test("Cancellation discards even a matcher whose closure returns normally")
    func cancelledLeaseIsDiscarded() async throws {
        let cache = try makeCache()
        let task = Task {
            try cache.withConstraint(for: .dictationTransform) { matcher in
                _ = try matcher.commitToken(0)
                withUnsafeCurrentTask { $0?.cancel() }
                return (value: 42, acceptedTokens: 1)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        _ = try cache.withConstraint(for: .dictationTransform) { matcher in
            _ = try matcher.commitToken(0)
            return (value: (), acceptedTokens: 1)
        }
        #expect(cache.statistics()["grammarSchemaCompilations"] == 2)
    }
}
