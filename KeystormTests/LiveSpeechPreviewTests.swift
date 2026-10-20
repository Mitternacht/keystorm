import Foundation
import Testing
@testable import Keystorm

struct LiveSpeechPreviewTests {
    @Test("Preview PCM uses bounded little-endian Float32 without lossy JSON numbers")
    func pcmRoundTrip() throws {
        var samples = [Float](repeating: 0, count: LiveSpeechPreviewPCM.minimumSamples)
        samples[0] = 1
        samples[1] = -0.125
        samples[2] = Float.leastNonzeroMagnitude
        samples[3] = -0.0
        let data = try LiveSpeechPreviewPCM.encode(samples)
        #expect(Array(data.prefix(4)) == [0, 0, 128, 63])
        #expect(data.count == samples.count * 4)
        let decoded = try LiveSpeechPreviewPCM.decode(data)
        #expect(decoded.map(\.bitPattern) == samples.map(\.bitPattern))
        let request = InferenceWorkerRequest(operation: .speechPreview, modelID: ModelCatalog.primarySpeech.id, previewPCM: data)
        let frame = try InferenceWorkerCodec.frame(request)
        let copy = try InferenceWorkerCodec.decode(InferenceWorkerRequest.self, from: Data(frame.dropLast()))
        #expect(copy.previewPCM == data)
        #expect(try LiveSpeechPreviewPCM.decode(try #require(copy.previewPCM)) == decoded)
    }

    @Test("Both PCM endpoints reject bad lengths and nonfinite samples")
    func invalidPCM() throws {
        #expect(throws: (any Error).self) { try LiveSpeechPreviewPCM.encode([Float](repeating: 0, count: 1_599)) }
        #expect(throws: (any Error).self) { try LiveSpeechPreviewPCM.encode([Float](repeating: 0, count: 240_001)) }
        for invalid in [Float.nan, Float.infinity, -Float.infinity] {
            var samples = [Float](repeating: 0, count: 1_600)
            samples[42] = invalid
            #expect(throws: (any Error).self) { try LiveSpeechPreviewPCM.encode(samples) }
            var bytes = Data(repeating: 0, count: 1_600 * 4)
            var bits = invalid.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.replaceSubrange(168..<172, with: $0) }
            #expect(throws: (any Error).self) { try LiveSpeechPreviewPCM.decode(bytes) }
        }
        #expect(throws: (any Error).self) { try LiveSpeechPreviewPCM.decode(Data(repeating: 0, count: 6_401)) }
        #expect(throws: (any Error).self) { try LiveSpeechPreviewPCM.decode(Data(repeating: 0, count: 6_396)) }
        #expect(throws: (any Error).self) { try LiveSpeechPreviewPCM.decode(Data(repeating: 0, count: 960_004)) }
        #expect(try LiveSpeechPreviewPCM.decode(Data(repeating: 0, count: 960_000)).count == 240_000)
    }

    @Test("Preview output retains only bounded honest relative model timing")
    func outputValidation() throws {
        let valid = LiveSpeechPreviewResult(text: "local", words: [
            TimedSpeechWord(word: "local", startTime: 0.08, endTime: 0.56)
        ])
        try valid.validate(sampleCount: 16_000)
        try LiveSpeechPreviewResult(text: "", words: []).validate(sampleCount: 1_600)
        for word in [
            TimedSpeechWord(word: "bad", startTime: -.infinity, endTime: 0.5),
            TimedSpeechWord(word: "bad", startTime: 0.5, endTime: 0.2),
            TimedSpeechWord(word: "bad", startTime: 0, endTime: 12),
            TimedSpeechWord(word: "", startTime: 0, endTime: 0.1)
        ] {
            #expect(throws: (any Error).self) {
                try LiveSpeechPreviewResult(text: "bad", words: [word]).validate(sampleCount: 16_000)
            }
        }
        #expect(throws: (any Error).self) {
            try LiveSpeechPreviewResult(text: String(repeating: "x", count: 16_385), words: []).validate(sampleCount: 16_000)
        }
    }

    @Test("The pinned decoder's token boundary is never labeled a complete preview")
    func tokenCap() throws {
        try LocalInference.validateSpeechTokenCount(149)
        #expect(throws: (any Error).self) { try LocalInference.validateSpeechTokenCount(150) }
        #expect(throws: (any Error).self) { try LocalInference.validateSpeechTokenCount(151) }
        #expect(throws: (any Error).self) { try LocalInference.validateSpeechTokenCount(-1) }
    }

    @Test("Invalid samples never launch an inference process")
    func malformedClientInput() async {
        let client = InferenceWorkerClient(modelDirectory: FileManager.default.temporaryDirectory,
            executableURL: URL(fileURLWithPath: "/unavailable/Keystorm"))
        await #expect(throws: (any Error).self) {
            try await client.transcribePreview(samples: [Float](repeating: .nan, count: 16_000), model: ModelCatalog.primarySpeech)
        }
        #expect(await client.memorySnapshot()["workerPID"] == 0)
        await client.shutdown()
    }
}
