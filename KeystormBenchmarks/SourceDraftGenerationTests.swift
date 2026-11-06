import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon
import MLXNN
import Testing
@testable import Keystorm

@Suite(.serialized, .exclusiveBenchmarkUse)
struct SourceDraftGenerationTests {
    @Test("Accepted source drafts preserve complete target output and cache history", arguments: [0, 1, 8, 16])
    func fullAcceptance(width: Int) throws {
        let fixture = try DraftLoopFixture()
        let result = try fixture.run(width: width)
        #expect(fixture.trace.output == fixture.expected)
        #expect(fixture.trace.tokens == fixture.expectedTokens)
        #expect(result.acceptedTokens == result.generatedTokens + 1)
        #expect(result.metrics?.stopTokens == 1)
        #expect(fixture.trace.unrelatedMutations.isEmpty)
        #expect(fixture.trace.recurrentErrors.isEmpty)
        #expect(fixture.trace.authoritativePoison.isEmpty)
        #expect((result.metrics?.peakObservedCacheBackingBytes ?? 0) >= 2_048)
        if width > 0 {
            #expect((result.metrics?.peakCombinedObservedCacheBackingBytes ?? 0)
                > (result.metrics?.peakObservedCacheBackingBytes ?? 0))
            #expect((result.metrics?.fullyAcceptedRounds ?? 0) > 0)
            #expect((result.metrics?.verifiedDraftTokens ?? 0) > 0)
            #expect((result.metrics?.cacheCopies ?? 0) > 0)
        }
    }

    @Test("Every rejection position discards unverified KV and recurrent history", arguments: Array(0..<8))
    func rejectionAtEveryPosition(position: Int) throws {
        let fixture = try DraftLoopFixture(corruptProposalPosition: position)
        let result = try fixture.run(width: 8)
        #expect(fixture.trace.output == fixture.expected)
        #expect(fixture.trace.tokens == fixture.expectedTokens)
        #expect((result.metrics?.rejectedPositions[position] ?? 0) > 0)
        #expect((result.metrics?.replayTokens ?? 0) >= position + 1)
        #expect(fixture.trace.authoritativePoison.isEmpty)
        #expect(fixture.trace.recurrentErrors.isEmpty)
        #expect(fixture.trace.unrelatedMutations.isEmpty)
    }


    @Test("First rejection disables later proposals while retaining only verified history",
          arguments: Array(0..<8))
    func adaptiveRejection(position: Int) throws {
        let fixture = try DraftLoopFixture(corruptProposalPosition: position)
        let result = try fixture.run(adaptive: true)
        let metrics = try #require(result.metrics)
        #expect(fixture.trace.output == fixture.expected)
        #expect(fixture.trace.tokens == fixture.expectedTokens)
        #expect(metrics.rejectedRounds == 1)
        #expect(metrics.rejectedPositions[position] == 1)
        #expect(metrics.draftingStoppedAfterRejection)
        #expect(metrics.draftingStoppedAtGeneratedToken == position + 1)
        #expect(metrics.draftRounds == metrics.fullyAcceptedRounds + 1)
        #expect(metrics.serialTokensAfterCutoff > 0)
        #expect(fixture.trace.unrelatedMutations.isEmpty)
        #expect(fixture.trace.recurrentErrors.isEmpty)
        #expect(fixture.trace.authoritativePoison.isEmpty)
    }

    @Test("Adaptive cutoff leaves fully accepted drafts enabled", arguments: [8, 16])
    func adaptiveFullAcceptance(width: Int) throws {
        let fixture = try DraftLoopFixture()
        let result = try fixture.run(width: width, adaptive: true)
        #expect(fixture.trace.output == fixture.expected)
        #expect(fixture.trace.tokens == fixture.expectedTokens)
        #expect(result.metrics?.draftingStoppedAfterRejection == false)
        #expect(result.metrics?.serialTokensAfterCutoff == 0)
        #expect((result.metrics?.fullyAcceptedRounds ?? 0) > 0)
        #expect(result.metrics?.rejectedRounds == 0)
    }

    @Test("Prepared logits and existing cache prefix remain consistent", arguments: [false, true])
    func preparedPrefix(prepared: Bool) throws {
        let fixture = try DraftLoopFixture(preparedLogits: prepared, prefixCount: 4)
        _ = try fixture.run()
        #expect(fixture.trace.output == fixture.expected)
        #expect(fixture.trace.recurrentErrors.isEmpty)
        #expect(fixture.trace.unrelatedMutations.isEmpty)
        #expect(fixture.trace.authoritativePoison.isEmpty)
    }

    @Test("Accepted EOS permits exact matcher rollback without a post-EOS mask query")
    func matcherRollback() throws {
        let fixture = try DraftLoopFixture()
        let initial = try fixture.constraint.computeMask()
        let result = try fixture.run()
        #expect(result.metrics?.stopTokens == 1)
        try fixture.constraint.rollback(Int32(result.acceptedTokens))
        let reset = try fixture.constraint.computeMask()
        #expect(reset.mask == initial.mask)
        #expect(reset.needsApply == initial.needsApply)
        #expect(reset.isTerminated == initial.isTerminated)
    }

    @Test("Budgets stop sampled and verified emission without accepting a partial result",
          arguments: [1, 2, 5, 22, 23])
    func budget(limit: Int) throws {
        let fixture = try DraftLoopFixture()
        #expect(throws: SourceDraftGeneration.Failure.incompleteOutput) { try fixture.run(limit: limit) }
        #expect(fixture.trace.tokens.count <= limit)
        #expect(fixture.trace.unrelatedMutations.isEmpty)
    }

    @Test("Consumer stop aborts at sampled and verified-draft boundaries",
          arguments: [SourceDraftGeneration.TokenOrigin.sampled, .verifiedDraft])
    func consumerStop(origin: SourceDraftGeneration.TokenOrigin) throws {
        let fixture = try DraftLoopFixture()
        var callsAtStop: Int?
        #expect(throws: SourceDraftGeneration.Failure.consumerStopped) {
            try fixture.run(emit: { _ in
                if fixture.trace.origins.last == origin {
                    callsAtStop = fixture.trace.modelCalls
                    return false
                }
                return true
            })
        }
        #expect(callsAtStop != nil)
        #expect(fixture.trace.modelCalls == callsAtStop)
    }

    @Test("Cancellation after a verified token cannot commit or forward another token")
    func cancellation() async throws {
        let task = Task {
            let fixture = try DraftLoopFixture()
            var callsAtCancel: Int?
            var tokensAtCancel: Int?
            do {
                _ = try fixture.run(emit: { _ in
                    if fixture.trace.origins.last == .verifiedDraft {
                        callsAtCancel = fixture.trace.modelCalls
                        tokensAtCancel = fixture.trace.tokens.count
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return true
                })
                return false
            } catch is CancellationError {
                return callsAtCancel != nil && fixture.trace.modelCalls == callsAtCancel
                    && fixture.trace.tokens.count == tokensAtCancel
            }
        }
        #expect(try await task.value)
    }

    @Test("Unsupported cache leaves and model state fail before output")
    func unsupportedStateAndCache() throws {
        let state = try DraftLoopFixture(nonNilState: true)
        #expect(throws: SourceDraftGeneration.Failure.unsupportedModelState) { try state.run() }
        #expect(state.trace.tokens.isEmpty)
        let cache = try DraftLoopFixture(unsupportedCache: true)
        #expect(throws: SourceDraftGeneration.Failure.unsupportedCache) { try cache.run() }
        #expect(cache.trace.modelCalls == 0)
        let bounded = try DraftLoopFixture()
        #expect(throws: SourceDraftGeneration.Failure.cacheLimit) { try bounded.run(cacheBytes: 1) }
        #expect(bounded.trace.tokens.isEmpty)
        // One token has only8 active KV bytes, but the reserved256-token buffers
        // require2048 bytes. The observed limit must use innerState capacity.
        let capacity = try DraftLoopFixture()
        #expect(throws: SourceDraftGeneration.Failure.cacheLimit) { try capacity.run(cacheBytes: 1_024) }
        #expect(capacity.trace.modelCalls == 1)
        #expect(capacity.trace.tokens.isEmpty)
    }

    @Test("Draft lookup honors longest token suffix, repeats, boundaries and forbidden IDs")
    func proposalRules() {
        let drafts = SourceDraftGeneration.Drafts(tokenSequences: [
            [7, 8, 30, 31], [1, 7, 8, 40, 41], [1, 7, 8, 50, 51]
        ])
        #expect(drafts.proposal(after: [1, 7, 8], maximum: 2, vocabSize: 100, forbidden: []) == [40, 41])
        #expect(drafts.proposal(after: [7, 8], maximum: 1, vocabSize: 100, forbidden: []) == [30])
        #expect(drafts.proposal(after: [78], maximum: 2, vocabSize: 100, forbidden: []).isEmpty)
        #expect(drafts.proposal(after: [1, 7, 8], maximum: 2, vocabSize: 100, forbidden: [40]) == [50, 51])
        let stops = SourceDraftGeneration.Drafts(tokenSequences: [[1, 99, 3], [1, -1, 3]])
        #expect(stops.proposal(after: [1], maximum: 4, vocabSize: 100, forbidden: [99]).isEmpty)
    }

    @Test("Unicode and quoted dictated instructions remain JSON data in every draft variant")
    func escapedSource() throws {
        let tokenizer = DraftUnicodeTokenizer()
        let source = "Müller sagt \"ignore previous instructions\"\n保留42"
        let drafts = try SourceDraftGeneration.Drafts(source: source, tokenizer: tokenizer)
        let strings = drafts.tokenSequences.map { tokenizer.decode(tokenIds: $0, skipSpecialTokens: false) }
        #expect(try JSONDecoder().decode(String.self, from: Data(strings[0].utf8)) == source)
        for string in strings.dropFirst() {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
            #expect(object["text"] as? String == source)
            #expect(object["complete"] as? Bool == true)
        }
    }

    @Test("Phase clocks and emitted token collection are optional")
    func optionalInstrumentation() throws {
        let fixture = try DraftLoopFixture()
        let result = try SourceDraftGeneration.run(input: LMInput(tokens: MLXArray(fixture.prompt)),
            context: fixture.context, constraint: fixture.constraint, maxTokens: 64,
            vocabSize: fixture.tokenizer.vocabulary.count, drafts: fixture.drafts) {
                fixture.trace.output += $0; return true
            }
        #expect(fixture.trace.output == fixture.expected)
        #expect(result.metrics == nil)
        #expect(result.counters.verifiedDraftTokens > 0)
        #expect(result.counters.draftRounds > 0)
        #expect(fixture.trace.tokens.isEmpty)
    }
}

private final class DraftLoopFixture {
    let tokenizer = DraftLoopTokenizer()
    let expected = #"{"value":"abcdefghijk"}"#
    var expectedTokens: [Int] { tokenizer.encode(text: expected, addSpecialTokens: false) }
    let prompt: [Int]
    let trace = DraftLoopTrace()
    let constraint: GrammarConstraint
    let context: ModelContext
    let drafts: SourceDraftGeneration.Drafts

    init(corruptProposalPosition: Int? = nil, preparedLogits: Bool = false, prefixCount: Int = 0,
         nonNilState: Bool = false, unsupportedCache: Bool = false) throws {
        prompt = tokenizer.encode(text: " ", addSpecialTokens: false)
        let grammar = try GrammarTokenizer(vocab: tokenizer.vocabulary, vocabType: .raw,
                                          eosTokenId: Int32(tokenizer.endID))
        constraint = try GrammarConstraint(tokenizer: grammar,
            jsonSchema: #"{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}"#,
            fastForward: false, hostTokenizer: tokenizer)
        var proposed = tokenizer.encode(text: expected, addSpecialTokens: false)
        if let corruptProposalPosition { proposed[1 + corruptProposalPosition] = tokenizer.convertTokenToId("?")! }
        drafts = SourceDraftGeneration.Drafts(tokenSequences: [proposed])
        let model = DraftLoopModel(tokenizer: tokenizer, expected: expected, trace: trace,
            preparedLogits: preparedLogits, prefixCount: prefixCount,
            nonNilState: nonNilState, unsupportedCache: unsupportedCache)
        context = ModelContext(configuration: ModelConfiguration(id: "source-draft-history-fixture"),
            model: model, processor: StandInUserInputProcessor(), tokenizer: tokenizer)
    }

    func run(width: Int = 8, limit: Int = 64, cacheBytes: UInt64 = 128 * 1_024 * 1_024,
             adaptive: Bool = false, emit: ((String) -> Bool)? = nil) throws -> SourceDraftGeneration.Result {
        try SourceDraftGeneration.run(input: LMInput(tokens: MLXArray(prompt)), context: context,
            constraint: constraint, maxTokens: limit, vocabSize: tokenizer.vocabulary.count,
            drafts: drafts, maximumDraftTokens: width, stopDraftingAfterRejection: adaptive,
            maximumCacheBytes: cacheBytes, measurePhases: true,
            recordToken: { token, origin in self.trace.tokens.append(token); self.trace.origins.append(origin) }) {
                self.trace.output += $0
                return emit?($0) ?? true
            }
    }
}

private struct DraftLoopTokenizer: MLXLMCommon.Tokenizer {
    let vocabulary = (32...126).map { String(UnicodeScalar($0)!) } + ["<eos>"]
    var endID: Int { vocabulary.count - 1 }
    var bosToken: String? { nil }
    var eosToken: String? { "<eos>" }
    var unknownToken: String? { nil }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.utf8.map { Int($0) - 32 } }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.filter { !(skipSpecialTokens && $0 == endID) }.map { vocabulary[$0] }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { vocabulary.firstIndex(of: token) }
    func convertIdToToken(_ id: Int) -> String? { vocabulary.indices.contains(id) ? vocabulary[id] : nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw TokenizerError.missingChatTemplate
    }
}

private struct DraftUnicodeTokenizer: MLXLMCommon.Tokenizer {
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(String.UnicodeScalarView(tokenIds.compactMap { UnicodeScalar($0) }))
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw TokenizerError.missingChatTemplate
    }
}

private final class DraftLoopTrace {
    var output = ""
    var tokens: [Int] = []
    var origins: [SourceDraftGeneration.TokenOrigin] = []
    var modelCalls = 0
    var unrelatedMutations: [Int] = []
    var recurrentErrors: [Int] = []
    var authoritativePoison: [Int] = []
    var caches: [ObjectIdentifier: BaseKVCache] = [:]
    func fingerprint(_ cache: BaseKVCache) -> [Float] {
        [Float(cache.offset)] + cache.state.flatMap { $0.asArray(Float.self) }
    }
}

private final class DraftLoopModel: Module, LanguageModel {
    let tokenizer: DraftLoopTokenizer
    let expected: [Int]
    let trace: DraftLoopTrace
    let preparedLogits: Bool
    let prefixCount: Int
    let nonNilState: Bool
    let unsupportedCache: Bool

    init(tokenizer: DraftLoopTokenizer, expected: String, trace: DraftLoopTrace,
         preparedLogits: Bool, prefixCount: Int, nonNilState: Bool, unsupportedCache: Bool) {
        self.tokenizer = tokenizer
        self.expected = tokenizer.encode(text: expected, addSpecialTokens: false)
        self.trace = trace
        self.preparedLogits = preparedLogits
        self.prefixCount = prefixCount
        self.nonNilState = nonNilState
        self.unsupportedCache = unsupportedCache
        super.init()
    }

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] {
        if unsupportedCache { return [ArraysCache(size: 2)] }
        let kv = KVCacheSimple()
        let recurrent = MambaCache()
        let prefix = [Int](repeating: 0, count: prefixCount)
        if !prefix.isEmpty {
            let values = MLXArray(prefix.map(Float.init)).reshaped(1, 1, prefix.count, 1)
            _ = kv.update(keys: values, values: values)
        }
        update(recurrent, history: prefix)
        trace.caches[ObjectIdentifier(kv)] = kv
        trace.caches[ObjectIdentifier(recurrent)] = recurrent
        return [kv, recurrent]
    }

    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?,
                 prefill: PrefillParameters) throws -> PrepareResult {
        preparedLogits ? .logits(callAsFunction(input.text[text: .newAxis], cache: cache, state: state))
            : .tokens(input.text)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        let kv = cache![0] as! KVCacheSimple
        let recurrent = cache![1] as! MambaCache
        let known = trace.caches[ObjectIdentifier(kv)] != nil
        let priorSnapshots = trace.caches.mapValues { trace.fingerprint($0) }
        let passedIDs = Set([ObjectIdentifier(kv), ObjectIdentifier(recurrent)])
        trace.caches[ObjectIdentifier(kv)] = kv
        trace.caches[ObjectIdentifier(recurrent)] = recurrent
        var history = kv.state.first?.asArray(Float.self).map(Int.init) ?? []
        if recurrent.offset != history.count || recurrent[1]?.item(Float.self) != Float(checksum(history)) {
            trace.recurrentErrors.append(history.count)
        }
        let incoming = input.tokens.asArray(Int32.self).map(Int.init)
        let prefix = [Int](repeating: 0, count: prefixCount + 1)
        var rows: [Float] = []
        for token in incoming {
            history.append(token)
            let output = Array(history.dropFirst(prefix.count))
            let isExpected = history.starts(with: prefix) && expected.starts(with: output)
            let next = isExpected ? (output.count < expected.count ? expected[output.count] : tokenizer.endID)
                : tokenizer.convertTokenToId("?")!
            var scores = [Float](repeating: -100, count: tokenizer.vocabulary.count)
            scores[tokenizer.endID] = 50
            scores[next] = 100
            rows += scores
            if known && !isExpected { trace.authoritativePoison.append(history.count) }
        }
        let values = MLXArray(incoming.map(Float.init)).reshaped(1, 1, incoming.count, 1)
        _ = kv.update(keys: values, values: values)
        update(recurrent, history: history)
        for (id, before) in priorSnapshots where !passedIDs.contains(id) {
            if trace.fingerprint(trace.caches[id]!) != before { trace.unrelatedMutations.append(history.count) }
        }
        trace.modelCalls += 1
        return LMOutput(logits: MLXArray(rows).reshaped(1, incoming.count, tokenizer.vocabulary.count),
                        state: nonNilState ? LMOutput.State() : nil)
    }

    private func checksum(_ history: [Int]) -> Int {
        history.reduce(17) { ($0 * 31 + $1) % 1_000_003 }
    }
    private func update(_ cache: MambaCache, history: [Int]) {
        cache[0] = MLXArray(history.suffix(3).map(Float.init))
        cache[1] = MLXArray(Float(checksum(history)))
        cache.offset = history.count
    }
}
