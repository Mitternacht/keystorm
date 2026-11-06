import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import Keystorm

@Suite(.serialized)
struct LocalTextPrefixCacheTests {
    private func model(seed: UInt64 = 11) throws -> Qwen35TextModel {
        let data = Data("""
            {"model_type":"qwen3_5","hidden_size":32,"num_hidden_layers":2,
             "intermediate_size":64,"num_attention_heads":2,"num_key_value_heads":1,
             "head_dim":16,"vocab_size":128,"full_attention_interval":2,
             "linear_num_value_heads":2,"linear_num_key_heads":1,
             "linear_key_head_dim":16,"linear_value_head_dim":16,
             "linear_conv_kernel_dim":4,"tie_word_embeddings":true}
            """.utf8)
        let configuration = try JSONDecoder().decode(Qwen35TextConfiguration.self, from: data)
        return withRandomState(MLXRandom.RandomState(seed: seed)) {
            let model = Qwen35TextModel(configuration)
            model.train(false)
            eval(model.parameters())
            return model
        }
    }

    private func logits(model: any LanguageModel, input: LMInput) throws -> MLXArray {
        let state = try model.newCache(parameters: nil)
        let prepared = try model.prepare(input, cache: state, state: nil, prefill: .init())
        let result: LMOutput
        switch prepared {
        case .tokens(let tokens): result = model(tokens[text: .newAxis], cache: state, state: nil)
        case .logits(let output): result = output
        }
        let last = result.logits[0, -1]
        eval(last)
        return last
    }

    private func greedyTokens(model: any LanguageModel, input: LMInput, count: Int = 8) throws -> [Int] {
        let caches = try model.newCache(parameters: nil)
        let prepared = try model.prepare(input, cache: caches, state: nil, prefill: .init())
        var output: LMOutput
        switch prepared {
        case .tokens(let tokens): output = model(tokens[text: .newAxis], cache: caches, state: nil)
        case .logits(let result): output = result
        }
        var tokens: [Int] = []
        for index in 0..<count {
            let token = argMax(output.logits[0, -1]).item(Int.self)
            tokens.append(token)
            if index + 1 < count {
                output = model(LMInput(tokens: MLXArray([token])).text[text: .newAxis],
                    cache: caches, state: output.state)
            }
        }
        return tokens
    }

    private func assertSameContinuation(model: any LanguageModel, input: LMInput,
                                        prepared: LocalTextPrefixCache.Prepared) throws {
        let expected = try greedyTokens(model: model, input: input)
        let actual = try greedyTokens(model: prepared.model, input: prepared.input)
        #expect(actual == expected)
    }

    @Test("A cached hybrid prefix preserves logits and does not retain the preceding source")
    func hybridPrefixIsIsolated() throws {
        let model = try model()
        let cache = LocalTextPrefixCache()
        let system = Array(1...40)
        for source in [[41, 42, 43], [51, 52, 53, 54], [41, 42, 43]] {
            let input = LMInput(tokens: MLXArray(system + source))
            let expected = try logits(model: model, input: input)
            let prepared = try #require(try cache.prepare(input, systemTokens: system, model: model))
            #expect(prepared.input.text.tokens.size == source.count)
            let actual = try logits(model: prepared.model, input: prepared.input)
            #expect(MLX.max(MLX.abs(expected - actual)).item(Float.self) < 0.001)
            #expect(argMax(actual).item(Int.self) == argMax(expected).item(Int.self))
            try assertSameContinuation(model: model, input: input, prepared: prepared)
        }
        #expect(cache.statistics()["textModelPrefixBuilds"] == 1)
        #expect(cache.statistics()["textModelPrefixHits"] == 2)
        #expect(cache.statistics()["textModelPrefixRetainedBytes", default: 0] > 0)
    }

    @Test("Changing the model or the fixed token prefix invalidates cached state")
    func cacheIdentityIncludesModelAndTokens() throws {
        let cache = LocalTextPrefixCache()
        let first = try model()
        let second = try model(seed: 22)
        let system = Array(1...40)
        _ = try #require(try cache.prepare(LMInput(tokens: MLXArray(system + [41, 42])), systemTokens: system, model: first))
        let input = LMInput(tokens: MLXArray(system + [42, 43]))
        let next = try #require(try cache.prepare(input, systemTokens: system, model: second))
        let expected = try logits(model: second, input: input)
        let actual = try logits(model: next.model, input: next.input)
        let difference = MLX.max(MLX.abs(expected - actual)).item(Float.self)
        let maximumLogit = MLX.max(MLX.abs(expected)).item(Float.self)
        print("PREFIX_MODEL_REPLACEMENT max_absolute_difference=\(difference) max_logit=\(maximumLogit)")
        #expect(difference < 0.001)
        #expect(argMax(actual).item(Int.self) == argMax(expected).item(Int.self))
        try assertSameContinuation(model: second, input: input, prepared: next)
        let changed = Array(11...50)
        _ = try #require(try cache.prepare(LMInput(tokens: MLXArray(changed + [51, 52])), systemTokens: changed, model: second))
        #expect(cache.statistics()["textModelPrefixBuilds"] == 3)
        #expect(cache.statistics()["textModelPrefixHits"] == 0)
        cache.clear()
        #expect(cache.statistics()["textModelPrefixRetainedBytes"] == 0)
    }

    @Test("Only a bounded exact prefix is eligible; short, mismatched or one-token-suffix prompts bypass caching")
    func prefixBounds() throws {
        #expect(LocalTextPrefixCache.commonPrefixCount(systemTokens: Array(0..<2_000),
            inputTokens: Array(0..<2_001)) == LocalTextPrefixCache.maximumPrefixTokens)
        let model = try model()
        let cache = LocalTextPrefixCache()
        #expect(try cache.prepare(LMInput(tokens: MLXArray([1, 2, 3])), systemTokens: [1, 2], model: model) == nil)
        #expect(try cache.prepare(LMInput(tokens: MLXArray(Array(50...95))),
            systemTokens: Array(1...40), model: model) == nil)
        let system = Array(1...40)
        #expect(try cache.prepare(LMInput(tokens: MLXArray(system + [41])),
            systemTokens: system, model: model) == nil)
        #expect(cache.statistics()["textModelPrefixBuilds"] == 0)
    }
}
