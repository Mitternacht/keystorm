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
}
