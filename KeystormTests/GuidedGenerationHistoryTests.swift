import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon
import MLXNN
import Testing
@testable import Keystorm

/// Uses the pinned xgrammar bridge and public generation loop, without model weights.
/// The fake model records exactly the token history a real model would receive.
struct GuidedGenerationHistoryTests {
    @Test("Ordinary guided generation forwards every emitted token to the model")
    func sampledTokensReachModel() throws {
        let result = try generate(fastForward: false)
        #expect(result.fastForwardTokens.isEmpty)
        #expect(result.forwarded == result.expectedHistory)
    }

    @Test("Production grammar policy preserves exact model history with a capable host tokenizer")
    func productionPolicyPreservesModelHistory() throws {
        let result = try generate(fastForward: LocalGrammarCache.fastForwardEnabled)
        #expect(result.fastForwardTokens.isEmpty)
        #expect(result.forwarded == result.expectedHistory)
    }

    @Test("Pinned upstream fast-forward omits sampled tokens; production policy bypasses that path")
    func fastForwardPreservesSampledToken() throws {
        let result = try generate(fastForward: true)
        try #require(!result.fastForwardTokens.isEmpty,
            "This regression must exercise the pinned FindJumpForwardString bridge path.")
        // Strict: an upstream fix becomes an unexpected pass, prompting removal of
        // the production workaround only after the history and quality checks pass.
        // Fixture completion and actual FF activity are required outside this block.
        withKnownIssue("Pinned GuidedGenerationLoop skips sampled tokens before FF; productionPolicyPreservesModelHistory verifies the mitigation.") {
            #expect(result.forwarded == result.expectedHistory,
                "Forced grammar tokens must follow, rather than replace, the preceding sampled token.")
        }
    }

    private func generate(fastForward: Bool) throws -> HistoryResult {
        let tokenizer = HistoryTokenizer()
        let grammarTokenizer = try GrammarTokenizer(vocab: tokenizer.vocabulary,
            vocabType: .raw, eosTokenId: Int32(tokenizer.endID))
        let schema = #"""
            {"type":"object","properties":{"value":{"type":"boolean"}},"required":["value"],"additionalProperties":false}
            """#
        let constraint = try GrammarConstraint(tokenizer: grammarTokenizer, jsonSchema: schema,
            fastForward: fastForward, hostTokenizer: tokenizer)
        let expectedText = #"{"value":true}"#
        let prompt = tokenizer.encode(text: " ", addSpecialTokens: false)
        let trace = HistoryTrace()
        let model = HistoryModel(tokenizer: tokenizer, expectedText: expectedText, trace: trace)
        let context = ModelContext(configuration: ModelConfiguration(id: "local-history-fixture"),
            model: model, processor: StandInUserInputProcessor(), tokenizer: tokenizer)
        let diagnostics = GuidedGenerationDiagnosticSink()
        let generated = try GuidedGenerationDiagnosticSink.$current.withValue(diagnostics) {
            try GuidedGenerationLoop.run(input: LMInput(tokens: MLXArray(prompt)), context: context,
                constraint: constraint, maxTokens: 64, vocabSize: tokenizer.vocabulary.count,
                completionReserve: 0) { delta in
                    trace.emitted += delta
                    return true
                }
        }
        let expectedHistory = prompt + tokenizer.encode(text: expectedText, addSpecialTokens: false)
        print("GUIDED_HISTORY fast_forward=\(fastForward) sampled=\(diagnostics.sampledTokenIDs) forced=\(diagnostics.fastForwardTokenIDs) forwarded=\(trace.forwarded) expected=\(expectedHistory)")
        let evidence: [String: [Int]] = [
            "sampled": diagnostics.sampledTokenIDs, "forced": diagnostics.fastForwardTokenIDs,
            "forwarded": trace.forwarded, "expected": expectedHistory
        ]
        Attachment.record(try JSONEncoder().encode(evidence),
            named: fastForward ? "guided-history-fast-forward.json" : "guided-history-control.json")
        try #require(trace.emitted == expectedText, "Both paths must produce the identical complete JSON fixture.")
        try #require(diagnostics.grammarTerminated)
        #expect(generated == expectedText.utf8.count)
        #expect(constraint.fastForwardDisagreementCount == 0)
        return HistoryResult(forwarded: trace.forwarded, expectedHistory: expectedHistory,
            fastForwardTokens: diagnostics.fastForwardTokenIDs)
    }
}

private struct HistoryResult {
    let forwarded: [Int]
    let expectedHistory: [Int]
    let fastForwardTokens: [Int]
}

/// All printable ASCII characters are individual tokens, so the bridge's
/// re-encoding of forced JSON syntax is exact and cannot merge token boundaries.
private struct HistoryTokenizer: MLXLMCommon.Tokenizer {
    let vocabulary = (32...126).map { String(UnicodeScalar($0)!) } + ["<eos>"]
    var endID: Int { vocabulary.count - 1 }
    var bosToken: String? { nil }
    var eosToken: String? { "<eos>" }
    var unknownToken: String? { nil }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        text.utf8.map { Int($0) - 32 }
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.filter { !(skipSpecialTokens && $0 == endID) }.map {
            vocabulary.indices.contains($0) ? vocabulary[$0] : ""
        }.joined()
    }

    func convertTokenToId(_ token: String) -> Int? { vocabulary.firstIndex(of: token) }
    func convertIdToToken(_ id: Int) -> String? {
        vocabulary.indices.contains(id) ? vocabulary[id] : nil
    }

    func applyChatTemplate(messages: [[String: any Sendable]],
                           tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw TokenizerError.missingChatTemplate
    }
}

private final class HistoryTrace {
    var emitted = ""
    var forwarded: [Int] = []
}

private final class HistoryModel: Module, LanguageModel {
    private let tokenizer: HistoryTokenizer
    private let expectedTokens: [Int]
    private let trace: HistoryTrace

    init(tokenizer: HistoryTokenizer, expectedText: String, trace: HistoryTrace) {
        self.tokenizer = tokenizer
        self.expectedTokens = tokenizer.encode(text: expectedText, addSpecialTokens: false)
        self.trace = trace
        super.init()
    }

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] { [] }

    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?,
                 prefill: PrefillParameters) throws -> PrepareResult {
        .tokens(input.text)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        trace.forwarded += input.tokens.asArray(Int32.self).map(Int.init)
        // Drive the fixture from emitted output, independently of the model-history bug.
        // A faulty loop therefore still finishes, leaving a precise history mismatch.
        let offset = trace.emitted.utf8.count
        let next = offset < expectedTokens.count ? expectedTokens[offset] : tokenizer.endID
        var logits = [Float](repeating: -100, count: tokenizer.vocabulary.count)
        logits[next] = 100
        return LMOutput(logits: MLXArray(logits).reshaped(1, 1, logits.count))
    }
}
