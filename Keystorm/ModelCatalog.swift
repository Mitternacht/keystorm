import Foundation

nonisolated enum ModelPurpose: String, Codable, Sendable { case speech, text }

nonisolated struct ModelArtifact: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
    let bytes: Int64
}

nonisolated struct ModelDescriptor: Identifiable, Sendable {
    let id: String
    let displayName: String
    let purpose: ModelPurpose
    let role: String
    let runtime: String
    let quantization: String
    let licenseURL: URL
    let modelCardURL: URL
    let runtimeURL: URL
    let installable: Bool
    var repository: String?
    var revision: String?
    var artifacts: [ModelArtifact] = []
    var downloadBytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
    var availability: String { installable ? "Available to install" : "Evaluation candidate — runtime not integrated" }
}

/// Only qualified adapters can be installed. Evaluation candidates are never silently substituted.
nonisolated enum ModelCatalog {
    static let fluidRevision = "2d6c42ca5f3accc0faf9fee9e0fff5b9b2cf6042"
    static let mlxRevision = "48114eedf3c3d4a682a6b1d644cc5af5c2945d10"

    static let primarySpeech = ModelDescriptor(
        id: "parakeet-ultra", displayName: "Parakeet Ultra", purpose: .speech,
        role: "Provisional progressive engine", runtime: "FluidAudio",
        quantization: "INT8 encoder; remaining components per pinned Core ML export",
        licenseURL: URL(string: "https://huggingface.co/moondream/parakeet-ultra")!,
        modelCardURL: URL(string: "https://huggingface.co/moondream/parakeet-ultra")!,
        runtimeURL: URL(string: "https://github.com/FluidInference/FluidAudio")!,
        installable: true, repository: "FluidInference/parakeet-ultra-coreml",
        revision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6", artifacts: [
        ModelArtifact(path: "Decoder.mlmodelc/analytics/coremldata.bin", sha256: "fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5", bytes: 243),
        ModelArtifact(path: "Decoder.mlmodelc/coremldata.bin", sha256: "3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497", bytes: 560),
        ModelArtifact(path: "Decoder.mlmodelc/model.mil", sha256: "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955", bytes: 13110),
        ModelArtifact(path: "Decoder.mlmodelc/weights/weight.bin", sha256: "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4", bytes: 23604992),
        ModelArtifact(path: "Encoder.mlmodelc/analytics/coremldata.bin", sha256: "d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d", bytes: 243),
        ModelArtifact(path: "Encoder.mlmodelc/coremldata.bin", sha256: "397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe", bytes: 514),
        ModelArtifact(path: "Encoder.mlmodelc/model.mil", sha256: "f5d601568a4171d99a314c0fe3f6bc67715da2623732a3fb566e050ea83e5848", bytes: 1002653),
        ModelArtifact(path: "Encoder.mlmodelc/weights/weight.bin", sha256: "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b", bytes: 594211328),
        ModelArtifact(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", sha256: "68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4", bytes: 243),
        ModelArtifact(path: "JointDecisionv3.mlmodelc/coremldata.bin", sha256: "5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4", bytes: 592),
        ModelArtifact(path: "JointDecisionv3.mlmodelc/model.mil", sha256: "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0", bytes: 11777),
        ModelArtifact(path: "JointDecisionv3.mlmodelc/weights/weight.bin", sha256: "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25", bytes: 12642764),
        ModelArtifact(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d", bytes: 243),
        ModelArtifact(path: "Preprocessor.mlmodelc/coremldata.bin", sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d", bytes: 486),
        ModelArtifact(path: "Preprocessor.mlmodelc/metadata.json", sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf", bytes: 2841),
        ModelArtifact(path: "Preprocessor.mlmodelc/model.mil", sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93", bytes: 28181),
        ModelArtifact(path: "Preprocessor.mlmodelc/weights/weight.bin", sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea", bytes: 491072),
        ModelArtifact(path: "parakeet_vocab.json", sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735", bytes: 151122),
    ])

    static let englishBaseline = ModelDescriptor(
        id: "parakeet-v2", displayName: "Parakeet TDT 0.6B v2", purpose: .speech,
        role: "English comparison baseline", runtime: "FluidAudio",
        quantization: "Pinned Core ML export",
        licenseURL: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2")!,
        modelCardURL: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2")!,
        runtimeURL: URL(string: "https://github.com/FluidInference/FluidAudio")!,
        installable: true, repository: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
        revision: "ee09c569f73759e6d44c9bd16766f477b2b36d39", artifacts: [
        ModelArtifact(path: "Decoder.mlmodelc/analytics/coremldata.bin", sha256: "46de1a6fe2e49d19a2125bc91acf020df7f2aea84ba821532aade8427a440b05", bytes: 243),
        ModelArtifact(path: "Decoder.mlmodelc/coremldata.bin", sha256: "d200ca07694a347f6d02a3886a062ae839831e094e443222f2e48a14945966a8", bytes: 554),
        ModelArtifact(path: "Decoder.mlmodelc/metadata.json", sha256: "90a279b822496316458febc0ce761ab05954fadd9d66aa97bea077a35fc8f2b2", bytes: 3427),
        ModelArtifact(path: "Decoder.mlmodelc/model.mil", sha256: "7b95a5a6b672c652000348a67b6d4d92bb8e176b978c6666fe73c28a4d7ec579", bytes: 13106),
        ModelArtifact(path: "Decoder.mlmodelc/weights/weight.bin", sha256: "27d26890221d82322c1092fd99d7b40578e435d5cf4b83c887c42603caf97aba", bytes: 14429952),
        ModelArtifact(path: "Encoder.mlmodelc/analytics/coremldata.bin", sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105", bytes: 243),
        ModelArtifact(path: "Encoder.mlmodelc/coremldata.bin", sha256: "4def7aa848599ad0e17a8b9a982edcdbf33cf92e1f4b798de32e2ca0bc74b030", bytes: 485),
        ModelArtifact(path: "Encoder.mlmodelc/metadata.json", sha256: "58222fbc48c13c49d9715567803cd50cb9c23e4360462e0f8ffcea59a2c73c63", bytes: 2926),
        ModelArtifact(path: "Encoder.mlmodelc/model.mil", sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808", bytes: 959769),
        ModelArtifact(path: "Encoder.mlmodelc/weights/weight.bin", sha256: "4adc7ad44f9d05e1bffeb2b06d3bb02861a5c7602dff63a6b494aed3bf8a6c3e", bytes: 445187200),
        ModelArtifact(path: "JointDecision.mlmodelc/analytics/coremldata.bin", sha256: "f1183ba213bb94a918c8d2cad19ab045320618f97f6ca662245b3936d7b090f7", bytes: 243),
        ModelArtifact(path: "JointDecision.mlmodelc/coremldata.bin", sha256: "e2c6752f1c8cf2d3f6f26ec93195c9bfa759ad59edf9f806696a138154f96f11", bytes: 534),
        ModelArtifact(path: "JointDecision.mlmodelc/metadata.json", sha256: "ba8d309417b9acd4a175fdb15687de6a941db2f5b06666a60e7cf3cc8e2d3c3c", bytes: 2936),
        ModelArtifact(path: "JointDecision.mlmodelc/model.mil", sha256: "93bf82042235127cb81ab537dcae47a1c2e7e242ce4ffdaf772981b45eedc4f0", bytes: 9722),
        ModelArtifact(path: "JointDecision.mlmodelc/weights/weight.bin", sha256: "ca22a65903a05e64137677da608077578a8606090a598abf4875fa6199aaa19d", bytes: 3453388),
        ModelArtifact(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", sha256: "03ab3c1327a054c54c07a40325db967ec574f2c91dcc8192bfa44aa561bcf2d8", bytes: 243),
        ModelArtifact(path: "Preprocessor.mlmodelc/coremldata.bin", sha256: "d88ea1fc349459c9e100d6a96688c5b29a1f0d865f544be103001724b986b6d6", bytes: 494),
        ModelArtifact(path: "Preprocessor.mlmodelc/metadata.json", sha256: "fb16c581ff5e1b962e7cb2181ed892cd32f9f84c12b6e80ff3e089f28e35bcbb", bytes: 2974),
        ModelArtifact(path: "Preprocessor.mlmodelc/model.mil", sha256: "3e06d16fd061294c8a75be68c43a3b1ed1f593d4a9c35249e9cdbccadc59721e", bytes: 27166),
        ModelArtifact(path: "Preprocessor.mlmodelc/weights/weight.bin", sha256: "a5f7df6c7f47147ae9486fe18cc7792f9a44d093ec3c6a11e91ef2dc363c48dc", bytes: 298880),
        ModelArtifact(path: "parakeet_vocab.json", sha256: "57019fe3c745772ca83a1b048a4bb951cd51329504ea33d4d83316b96e279a97", bytes: 18762),
    ])

    static let primaryText = ModelDescriptor(
        id: "qwen35-4b-4bit", displayName: "Qwen3.5-4B · 4-bit", purpose: .text,
        role: "Provisional extraction model", runtime: "MLX Swift LM",
        quantization: "Uniform 4-bit text linear/embedding weights; BF16 norms and convolution; text-only inference",
        // The conversion publisher declares the Qwen base, Apache 2.0 and recipe in
        // this pinned card. It does not identify original checkpoint/converter commits.
        // Full card, license and modification attribution are bundled in ThirdPartyNotices.
        licenseURL: URL(string: "https://huggingface.co/Qwen/Qwen3.5-4B/blob/851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a/LICENSE")!,
        modelCardURL: URL(string: "https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit/blob/32f3e8ecf65426fc3306969496342d504bfa13f3/README.md")!,
        runtimeURL: URL(string: "https://github.com/ml-explore/mlx-swift-lm")!,
        installable: true, repository: "mlx-community/Qwen3.5-4B-MLX-4bit",
        revision: "32f3e8ecf65426fc3306969496342d504bfa13f3", artifacts: [
        ModelArtifact(path: "README.md", sha256: "49c0a725bdd22705d2d34b93cfe20463b673e3339ce4de8b81a340c05cfef5bc", bytes: 2273),
        ModelArtifact(path: "chat_template.jinja", sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715", bytes: 7756),
        ModelArtifact(path: "config.json", sha256: "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa", bytes: 3366),
        ModelArtifact(path: "model.safetensors", sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db", bytes: 3034300695),
        ModelArtifact(path: "model.safetensors.index.json", sha256: "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a", bytes: 101944),
        ModelArtifact(path: "tokenizer.json", sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4", bytes: 19989343),
        ModelArtifact(path: "tokenizer_config.json", sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182", bytes: 1139),
    ])

    static let models: [ModelDescriptor] = [
        primarySpeech, englishBaseline,
        candidate("granite5-q8", "Granite Speech 5.0 470M TurboCTC · Q8", .speech,
                  "Compact English challenger", "transcribe.cpp", "Q8_0",
                  "ibm-granite/granite-speech-5.0-470m-turboctc", "https://github.com/handy-computer/transcribe.cpp"),
        candidate("granite41-q8", "Granite Speech 4.1 2B · Q8", .speech,
                  "Keyword prompting challenger", "llama.cpp", "Q8",
                  "ibm-granite/granite-speech-4.1-2b", "https://github.com/ggml-org/llama.cpp"),
        candidate("cohere-8bit", "Cohere Transcribe · 8-bit", .speech,
                  "Accuracy challenger; window timing only", "MLX Audio Swift", "8-bit",
                  "CohereLabs/cohere-transcribe-03-2026", "https://github.com/Blaizzy/mlx-audio-swift"),
        candidate("qwen3-asr", "Qwen3-ASR", .speech,
                  "Secondary challenger", "Not integrated", "Pending evaluation",
                  "Qwen/Qwen3-ASR-0.6B", "https://github.com/QwenLM/Qwen3-ASR"),
        candidate("whisperkit-turbo", "WhisperKit · compressed Large v3 Turbo", .speech,
                  "Optional independent fallback · large-v3-v20240930_626MB", "WhisperKit", "Compressed",
                  "openai/whisper-large-v3-turbo", "https://github.com/argmaxinc/argmax-oss-swift"),
        primaryText,
        candidate("qwen35-4b-6bit", "Qwen3.5-4B · 6-bit", .text,
                  "Precision comparison", "MLX Swift LM", "Uniform 6-bit",
                  "Qwen/Qwen3.5-4B", "https://github.com/ml-explore/mlx-swift-lm"),
        candidate("qwen3-4b", "Qwen3-4B-Instruct-2507", .text,
                  "Previous-model baseline", "MLX Swift LM", "4-bit; non-thinking",
                  "Qwen/Qwen3-4B-Instruct-2507", "https://github.com/ml-explore/mlx-swift-lm"),
        candidate("granite42", "Granite 4.2-3B", .text,
                  "Independent challenger", "MLX Swift LM", "4-bit; non-thinking",
                  "ibm-granite/granite-4.2-3b", "https://github.com/ml-explore/mlx-swift-lm"),
        candidate("qwen35-2b-phone", "Qwen3.5-2B · 4-bit", .text,
                  "Later 8 GB iPhone candidate", "MLX Swift LM", "Uniform 4-bit; non-thinking",
                  "Qwen/Qwen3.5-2B", "https://github.com/ml-explore/mlx-swift-lm")
    ]

    private static func candidate(_ id: String, _ name: String, _ purpose: ModelPurpose,
                                  _ role: String, _ runtime: String, _ quantization: String,
                                  _ card: String, _ documentation: String) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: name, purpose: purpose, role: role,
                        runtime: runtime, quantization: quantization,
                        licenseURL: URL(string: "https://huggingface.co/\(card)")!,
                        modelCardURL: URL(string: "https://huggingface.co/\(card)")!,
                        runtimeURL: URL(string: documentation)!, installable: false)
    }
}
