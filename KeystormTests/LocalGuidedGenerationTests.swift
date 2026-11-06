import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon
import MLXNN
import Testing
@testable import Keystorm

/// Real xgrammar, deterministic stateful model, and actual KVCacheSimple storage.
/// No downloaded weights, production mode switch, or diagnostic-sink interception.
@Suite(.serialized)
struct LocalGuidedGenerationTests {
    @Test("Corrected fast-forward includes sampled tokens and carries model state",
          arguments: [false, true])
    func exactHistory(fastForward: Bool) throws {
        let fixture = try GuidedLoopFixture(fastForward: fastForward)
        let result = try fixture.run()
        #expect(fixture.trace.output == fixture.expected)
        #expect(fixture.trace.forwarded == fixture.prompt + fixture.tokenizer.encode(text: fixture.expected, addSpecialTokens: false))
        #expect(fixture.trace.stateErrors.isEmpty)
        #expect(fixture.trace.cacheErrors.isEmpty)
        #expect(result.generatedTokens == fixture.expected.utf8.count)
        #expect(result.acceptedTokens == result.generatedTokens + 1)
        #expect(result.metrics?.sampledTokens == fixture.trace.origins.filter { $0 == .sampled }.count)
        #expect(result.metrics?.forcedTokens == fixture.trace.origins.filter { $0 == .forced }.count)
        #expect(((result.metrics?.forcedTokens ?? 0) > 0) == fastForward)
        #expect(result.metrics?.stopTokens == 1)
        #expect(fixture.constraint.fastForwardDisagreementCount == 0)
    }

    @Test("Forced blocks preserve history, cache and output across batch sizes",
          arguments: [2, 4, 16])
    func batchedParity(batchSize: Int) throws {
        let sequential = try GuidedLoopFixture(fastForward: true)
        let serial = try sequential.run()
        let batched = try GuidedLoopFixture(fastForward: true)
        let result = try batched.run(forwarding: .batched(maximumTokens: batchSize))
        #expect(batched.trace.output == sequential.trace.output)
        #expect(batched.trace.forwarded == sequential.trace.forwarded)
        #expect(batched.trace.recordedTokens == sequential.trace.recordedTokens)
        #expect(batched.trace.stateErrors.isEmpty)
        #expect(batched.trace.cacheErrors.isEmpty)
        #expect(result.generatedTokens == serial.generatedTokens)
        #expect(result.acceptedTokens == serial.acceptedTokens)
        #expect(result.metrics!.modelForwardCalls < serial.metrics!.modelForwardCalls)
        #expect(result.metrics!.modelForwardTokens == serial.metrics!.modelForwardTokens)
        #expect(batched.trace.batchLengths.dropFirst().contains { $0 > 1 })
    }

    @Test("Precomputed logits retain their returned state and a seeded cache")
    func preparedLogitsAndPrefix() throws {
        let fixture = try GuidedLoopFixture(fastForward: true, preparedLogits: true, prefixCount: 3)
        let result = try fixture.run(forwarding: .batched(maximumTokens: 4))
        #expect(fixture.trace.output == fixture.expected)
        #expect(fixture.trace.stateErrors.isEmpty)
        #expect(fixture.trace.cacheErrors.isEmpty)
        #expect(fixture.trace.cache?.offset == 3 + fixture.prompt.count + result.generatedTokens)
        #expect(fixture.trace.originalPrefixOffset == 3)
        #expect(fixture.trace.originalPrefix?.offset == 3)
    }

    @Test("Token caps inside sampled or forced output fail without exceeding the limit",
          arguments: [1, 2, 5, 13, 14])
    func tokenBudget(limit: Int) throws {
        let fixture = try GuidedLoopFixture(fastForward: true)
        #expect(throws: LocalGuidedGeneration.Failure.incompleteOutput) {
            try fixture.run(limit: limit)
        }
        #expect(fixture.trace.recordedTokens.count <= limit)
        #expect(fixture.trace.stateErrors.isEmpty)
        #expect(fixture.trace.cacheErrors.isEmpty)
    }

    @Test("Consumer stop during sampled or forced emission throws and prevents further forwarding",
          arguments: [LocalGuidedGeneration.TokenOrigin.sampled, .forced])
    func consumerStop(origin: LocalGuidedGeneration.TokenOrigin) throws {
        let fixture = try GuidedLoopFixture(fastForward: true)
        var forwardsAtStop: Int?
        #expect(throws: LocalGuidedGeneration.Failure.consumerStopped) {
            try fixture.run(emit: { _ in
                if fixture.trace.origins.last == origin {
                    forwardsAtStop = fixture.trace.forwarded.count
                    return false
                }
                return true
            })
        }
        #expect(forwardsAtStop != nil)
        #expect(fixture.trace.forwarded.count == forwardsAtStop)
    }

    @Test("A cancelled task does no model or grammar work")
    func cancellation() async throws {
        let task = Task {
            let fixture = try GuidedLoopFixture(fastForward: true)
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try fixture.run()
                return false
            } catch is CancellationError {
                return fixture.trace.forwarded.isEmpty && fixture.trace.recordedTokens.isEmpty
            }
        }
        #expect(try await task.value)
    }

    @Test("Accepted count rewinds the entire grammar including terminal EOS")
    func matcherRollback() throws {
        let fixture = try GuidedLoopFixture(fastForward: true)
        let initial = try fixture.constraint.computeMask()
        let result = try fixture.run()
        // The pinned matcher rejects computeMask after EOS; successful return
        // already required commitToken(EOS).isTerminated in the adapter.
        #expect(result.metrics?.stopTokens == 1)
        try fixture.constraint.rollback(Int32(result.acceptedTokens))
        let reset = try fixture.constraint.computeMask()
        #expect(reset.mask == initial.mask)
        #expect(reset.needsApply == initial.needsApply)
        #expect(reset.isTerminated == initial.isTerminated)
    }

    @Test("Padded logits and high premature EOS cannot escape the grammar")
    func vocabularyAndEOS() throws {
        let fixture = try GuidedLoopFixture(fastForward: true, paddedVocabulary: 3)
        let result = try fixture.run()
        #expect(fixture.trace.output == fixture.expected)
        #expect(result.metrics?.stopTokens == 1)
        #expect(fixture.trace.recordedTokens.allSatisfy { $0 < fixture.tokenizer.vocabulary.count })
    }

    @Test("Profiling and token collection are optional")
    func optionalInstrumentation() throws {
        let fixture = try GuidedLoopFixture(fastForward: true)
        let result = try LocalGuidedGeneration.run(input: LMInput(tokens: MLXArray(fixture.prompt)),
            context: fixture.context, constraint: fixture.constraint, maxTokens: 64,
            vocabSize: fixture.tokenizer.vocabulary.count) { fixture.trace.output += $0; return true }
        #expect(fixture.trace.output == fixture.expected)
        #expect(result.metrics == nil)
        #expect(fixture.trace.recordedTokens.isEmpty)
    }
}

private final class GuidedLoopFixture {
    let tokenizer = GuidedLoopTokenizer()
    let expected = #"{"value":true}"#
    let prompt: [Int]
    let trace = GuidedLoopTrace()
    let constraint: GrammarConstraint
    let context: ModelContext

    init(fastForward: Bool, preparedLogits: Bool = false, prefixCount: Int = 0,
         paddedVocabulary: Int = 0) throws {
        prompt = tokenizer.encode(text: " ", addSpecialTokens: false)
        let grammar = try GrammarTokenizer(vocab: tokenizer.vocabulary, vocabType: .raw,
                                          eosTokenId: Int32(tokenizer.endID))
        constraint = try GrammarConstraint(tokenizer: grammar,
            jsonSchema: #"{"type":"object","properties":{"value":{"type":"boolean"}},"required":["value"],"additionalProperties":false}"#,
            fastForward: fastForward, hostTokenizer: tokenizer)
        let model = GuidedLoopModel(tokenizer: tokenizer, expected: expected, promptLength: prompt.count,
            trace: trace, preparedLogits: preparedLogits, prefixCount: prefixCount,
            paddedVocabulary: paddedVocabulary)
        context = ModelContext(configuration: ModelConfiguration(id: "local-corrected-guided-loop"),
            model: model, processor: StandInUserInputProcessor(), tokenizer: tokenizer)
    }

    func run(limit: Int = 64, forwarding: LocalGuidedGeneration.Forwarding = .sequential,
             emit: ((String) -> Bool)? = nil) throws -> LocalGuidedGeneration.Result {
        try LocalGuidedGeneration.run(input: LMInput(tokens: MLXArray(prompt)), context: context,
            constraint: constraint, maxTokens: limit, vocabSize: tokenizer.vocabulary.count,
            forwarding: forwarding, measurePhases: true,
            recordToken: { id, origin in self.trace.recordedTokens.append(id); self.trace.origins.append(origin) }) {
                self.trace.output += $0
                return emit?($0) ?? true
            }
    }
}

private struct GuidedLoopTokenizer: MLXLMCommon.Tokenizer {
    let vocabulary = (32...126).map { String(UnicodeScalar($0)!) } + ["<eos>"]
    var endID: Int { vocabulary.count - 1 }
    var bosToken: String? { nil }
    var eosToken: String? { "<eos>" }
    var unknownToken: String? { nil }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.utf8.map { Int($0) - 32 } }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.filter { !(skipSpecialTokens && $0 == endID) }.map {
            vocabulary.indices.contains($0) ? vocabulary[$0] : ""
        }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { vocabulary.firstIndex(of: token) }
    func convertIdToToken(_ id: Int) -> String? { vocabulary.indices.contains(id) ? vocabulary[id] : nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw TokenizerError.missingChatTemplate
    }
}

private final class GuidedLoopTrace {
    var output = ""
    var forwarded: [Int] = []
    var recordedTokens: [Int] = []
    var origins: [LocalGuidedGeneration.TokenOrigin] = []
    var batchLengths: [Int] = []
    var stateErrors: [Int] = []
    var cacheErrors: [Int] = []
    var cache: KVCacheSimple?
    var originalPrefix: KVCacheSimple?
    var originalPrefixOffset = 0
}

private final class GuidedLoopModel: Module, LanguageModel {
    private let tokenizer: GuidedLoopTokenizer
    private let expectedTokens: [Int]
    private let promptLength: Int
    private let trace: GuidedLoopTrace
    private let preparedLogits: Bool
    private let prefixCount: Int
    private let paddedVocabulary: Int
    private let stateKey = LMOutput.Key<Int>("guided-test.forwarded")

    init(tokenizer: GuidedLoopTokenizer, expected: String, promptLength: Int, trace: GuidedLoopTrace,
         preparedLogits: Bool, prefixCount: Int, paddedVocabulary: Int) {
        self.tokenizer = tokenizer
        expectedTokens = tokenizer.encode(text: expected, addSpecialTokens: false)
        self.promptLength = promptLength
        self.trace = trace
        self.preparedLogits = preparedLogits
        self.prefixCount = prefixCount
        self.paddedVocabulary = paddedVocabulary
        super.init()
    }

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] {
        let original = KVCacheSimple()
        if prefixCount > 0 {
            let prefix = MLXArray.zeros([1, 1, prefixCount, 1])
            _ = original.update(keys: prefix, values: prefix)
        }
        trace.originalPrefix = original
        trace.originalPrefixOffset = original.offset
        let copy = original.copy() as! KVCacheSimple
        trace.cache = copy
        return [copy]
    }

    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?,
                 prefill: PrefillParameters) throws -> PrepareResult {
        if preparedLogits { return .logits(callAsFunction(input.text[text: .newAxis], cache: cache, state: state)) }
        return .tokens(input.text)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        let incoming = input.tokens.asArray(Int32.self).map(Int.init)
        let prior = trace.forwarded.count
        if prior == 0 ? state != nil : state?[stateKey] != prior { trace.stateErrors.append(prior) }
        if cache?.first?.offset != prefixCount + prior { trace.cacheErrors.append(prior) }
        let keys = MLXArray(incoming.map(Float.init)).reshaped(1, 1, incoming.count, 1)
        _ = cache?.first?.update(keys: keys, values: keys)
        trace.forwarded += incoming
        trace.batchLengths.append(incoming.count)
        let width = tokenizer.vocabulary.count + paddedVocabulary
        var allLogits: [Float] = []
        for offset in incoming.indices {
            let outputOffset = prior + offset + 1 - promptLength
            let next = outputOffset >= 0 && outputOffset < expectedTokens.count ? expectedTokens[outputOffset] : tokenizer.endID
            var scores = [Float](repeating: -100, count: width)
            scores[tokenizer.endID] = 50 // A premature EOS must remain masked.
            scores[next] = 100
            for id in tokenizer.vocabulary.count..<width { scores[id] = 1_000 }
            allLogits += scores
        }
        var nextState = LMOutput.State()
        nextState[stateKey] = trace.forwarded.count
        return LMOutput(logits: MLXArray(allLogits).reshaped(1, incoming.count, width), state: nextState)
    }
}
