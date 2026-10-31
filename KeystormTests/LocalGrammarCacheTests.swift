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
