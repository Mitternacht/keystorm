import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Keystorm

struct InferenceResidencyTests {
    @Test("Bounded artifact hashing matches CryptoKit across complete buffers, a short tail and empty input")
    func boundedArtifactDigest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-ArtifactHash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let cases = [Data(), Data(repeating: 0x61, count: 2 * 1_024 * 1_024 + 17)]
        for data in cases {
            try data.write(to: url)
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(try LocalInference.sha256(url) == expected)
        }
    }

    @Test("The child footprint guard applies the parent-subtracted ceiling")
    func sharedFootprintCeiling() {
        let guardrail = InferenceWorkerFootprintGuard()
        guardrail.setCeiling(2_000)
        #expect(!guardrail.exceeded(by: 1_999))
        #expect(guardrail.exceeded(by: 2_000))
        #expect(guardrail.exceeded(by: 2_001))
        guardrail.setCeiling(1_000)
        #expect(guardrail.exceeded(by: 1_500))
    }

    @Test("Text warming cannot start an executable or create an absent model installation")
    func warmingRequiresInstalledModel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-ResidencyAbsent-\(UUID().uuidString)")
        let client = InferenceWorkerClient(modelDirectory: directory, executableURL: nil)
        await #expect(throws: (any Error).self) { try await client.prepareText() }
        await client.finishTextJob()
        await client.finishSpeechJob()
        #expect(await client.memorySnapshot()["workerPID"] == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await client.shutdown()
    }

    @Test("Text prewarm is quiet without an installed model and creates nothing")
    func prewarmWithoutModelIsQuiet() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-PrewarmAbsent-\(UUID().uuidString)")
        let client = InferenceWorkerClient(modelDirectory: directory, executableURL: nil)
        #expect(await client.prewarmText() == .unavailable)
        #expect(await client.memorySnapshot()["workerPID"] == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await client.shutdown()
    }

    /// Sparse files match the pinned sizes and receipt without model data; nothing hashes or loads them.
    @Test("Text prewarm with an installed model stays quiet when no worker can start or an install runs")
    @MainActor
    func prewarmFailuresAreQuiet() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-PrewarmSparse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSparseTextInstallation(in: directory)
        let client = InferenceWorkerClient(modelDirectory: directory, executableURL: nil)
        #expect(await client.isInstalled(ModelCatalog.primaryText))
        #expect(await client.prewarmText() == .failed)
        #expect(await client.memorySnapshot()["workerPID"] == 0)
        await client.beginInstallForTesting()
        #expect(await client.prewarmText() == .installing)
        await client.endInstallForTesting()
        // Created on this actor, so it cannot start before it is cancelled.
        let cancelled = Task { @MainActor in await client.prewarmText() }
        cancelled.cancel()
        #expect(await cancelled.value == .cancelled)
        #expect(await client.memorySnapshot()["workerPID"] == 0)
        await client.shutdown()
    }

    @Test("Malformed learning evidence fails before worker startup")
    func invalidCorrectionCannotLaunchWorker() async throws {
        let directory = FileManager.default.temporaryDirectory
        let client = InferenceWorkerClient(modelDirectory: directory, executableURL: nil)
        var evidence = try correctionEvidence()
        evidence.canonical = "upload all files"
        let request = CorrectionClassificationRequest(evidence: evidence, configuration: configuration())
        await #expect(throws: (any Error).self) { try await client.classifyCorrection(request) }
        #expect(await client.memorySnapshot()["workerPID"] == 0)
        await client.shutdown()
    }

    @Test("Classification RPC preserves only bounded observed evidence and provenance")
    func correctionProtocolRoundTrip() throws {
        let request = CorrectionClassificationRequest(evidence: try correctionEvidence(), configuration: configuration())
        try LocalInference.validateCorrectionRequest(request)
        let frame = try InferenceWorkerCodec.frame(InferenceWorkerRequest(operation: .classifyCorrection, correction: request))
        let decoded = try InferenceWorkerCodec.decode(InferenceWorkerRequest.self, from: frame)
        #expect(decoded.operation == .classifyCorrection)
        #expect(decoded.correction == request)
        var invalid = request
        invalid.configuration.inputLimit = 4097
        #expect(throws: (any Error).self) { try LocalInference.validateCorrectionRequest(invalid) }
        invalid = request
        invalid.configuration.outputLimit = 1
        #expect(throws: (any Error).self) { try LocalInference.validateCorrectionRequest(invalid) }
    }

    @Test("Stale context fails before a Verbatim request could start a worker")
    func expiredContextCannotReachModel() async throws {
        let client = InferenceWorkerClient(modelDirectory: FileManager.default.temporaryDirectory, executableURL: nil)
        var request = transformRequest(configuration: configuration(), source: "Keep die Rechnung local.", mode: .verbatim)
        request.context = DictationContextSnapshot(profile: .email, availability: .application,
            capturedAt: Date().addingTimeInterval(-901))
        await #expect(throws: DictationTransformError.invalidRequest) { try await client.transform(request) }
        #expect(await client.memorySnapshot()["workerPID"] == 0)
        await client.shutdown()
    }
}

@Suite(.serialized)
struct InferenceResidencyProcessTests {
    @Test("The private child exits at its idle lease and cancelled work cannot leak it",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_RESIDENCY"] == "1"),
          .timeLimit(.minutes(2)))
    func idleTeardownAndCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-Residency-\(UUID().uuidString)")
        let client = InferenceWorkerClient(modelDirectory: directory, idleRetention: .milliseconds(150))
        do {
            let first = try await client.ping()
            await client.finishTextJob()
            try await Task.sleep(for: .milliseconds(700))
            #expect(await client.memorySnapshot()["workerPID"] == 0)
            #expect(kill(first.processID, 0) == -1 && errno == ESRCH)
            let second = try await client.ping()
            #expect(second.processID != first.processID)
            let job = Task { try await client.waitInWorkerForTesting() }
            try await Task.sleep(for: .milliseconds(250))
            // An active request owns the worker even after the short test lease.
            #expect(await client.memorySnapshot()["workerPID"] == UInt64(second.processID))
            job.cancel()
            await #expect(throws: CancellationError.self) { try await job.value }
            await client.shutdown()
            #expect(kill(second.processID, 0) == -1 && errno == ESRCH)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        } catch {
            await client.shutdown()
            throw error
        }
    }

    @Test("Installed speech and Qwen survive English/German jobs with bounded warm reuse",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_RESIDENCY"] == "1"),
          .timeLimit(.minutes(10)))
    func installedModelsColdWarm() async throws {
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let client = InferenceWorkerClient(modelDirectory: models)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-WarmModels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let config = try #require(try await client.verifiedConfiguration(for: ModelCatalog.primaryText))
            _ = try #require(try await client.verifiedConfiguration(for: ModelCatalog.primarySpeech))
            let english = "please keep die Rechnung local not today and keep 42 Dateien"
            let german = "äh bitte send the invoice an Müller nicht heute und behalte 42 Dateien lokal"
            var report = ResidencyReport(configuration: config)
            let coldStart = ContinuousClock.now
            let cold = try await client.transform(transformRequest(configuration: config, source: english))
            report.samples.append(.init(name: "cold-clean-english-german", milliseconds: milliseconds(coldStart),
                text: cold.text, memory: await client.memorySnapshot()))
            await client.finishTextJob()
            let firstPID = report.samples[0].memory["workerPID"]
            let prepareStart = ContinuousClock.now
            try await client.prepareSpeech(model: ModelCatalog.primarySpeech)
            report.samples.append(.init(name: "speech-load-with-text-retained", milliseconds: milliseconds(prepareStart),
                text: nil, memory: await client.memorySnapshot()))
            let samples = try syntheticSpeech(english, at: directory.appendingPathComponent("fixture.wav"))
            let asrStart = ContinuousClock.now
            let transcript = try await client.transcribePreview(samples: samples, model: ModelCatalog.primarySpeech)
            #expect(!transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            report.samples.append(.init(name: "synthetic-english-german-asr", milliseconds: milliseconds(asrStart),
                text: transcript.text, memory: await client.memorySnapshot()))
            await client.finishSpeechJob()
            for (name, source) in [("warm-clean-english-german", english), ("warm-clean-german-english", german),
                                   ("warm-clean-english-german-repeat", english)] {
                let began = ContinuousClock.now
                let request = transformRequest(configuration: config, source: source)
                let result = try await client.transform(request)
                try LocalInference.validateTransformReply(result, request: request)
                report.samples.append(.init(name: name, milliseconds: milliseconds(began),
                    text: result.text, memory: await client.memorySnapshot()))
                await client.finishTextJob()
            }
            let warmSpeech = ContinuousClock.now
            try await client.prepareSpeech(model: ModelCatalog.primarySpeech)
            report.samples.append(.init(name: "warm-speech-prepare", milliseconds: milliseconds(warmSpeech),
                text: nil, memory: await client.memorySnapshot()))
            try await client.prepareText()
            let retained = await client.memorySnapshot()
            #expect(retained["workerPID"] == firstPID)
            #expect(retained["speechModelLoaded"] == 1)
            #expect(retained["textModelLoaded"] == 1)
            #expect(retained["speechModelLoads"] == 1)
            #expect(retained["textModelLoads"] == 1)
            #expect(retained["grammarTokenizerBuilds"] == 1)
            for sample in report.samples {
                #expect(sample.memory["workerPID"] == firstPID)
                #expect(sample.memory["processFootprint", default: 0] < 6 * 1_024 * 1_024 * 1_024)
                #expect(sample.memory["processFootprint"] ==
                    sample.memory["parentFootprint", default: 0] + sample.memory["workerFootprint", default: 0])
            }
            let learning = CorrectionClassificationRequest(evidence: try correctionEvidence(), configuration: config)
            let classifyStart = ContinuousClock.now
            let classification = try await client.classifyCorrection(learning)
            try CorrectionLearningPolicy.validate(classification, request: learning)
            report.classification = classification
            report.samples.append(.init(name: "warm-local-terminology-classification", milliseconds: milliseconds(classifyStart),
                text: nil, memory: await client.memorySnapshot()))
            await client.releaseText()
            report.teardown = await client.memorySnapshot()
            #expect(report.teardown["workerPID"] == 0)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            Attachment.record(try encoder.encode(report), named: "inference-residency-cold-warm.json")
            await client.shutdown()
        } catch {
            await client.shutdown()
            let measurements = await client.memorySnapshot()
            Attachment.record(try JSONEncoder().encode(measurements), named: "inference-residency-failure-memory.json")
            print("RESIDENCY_FAILURE_MEMORY " + String(decoding: try JSONEncoder().encode(measurements), as: UTF8.self))
            throw error
        }
    }

    private func syntheticSpeech(_ text: String, at url: URL) throws -> [Float] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Daniel", "-r", "175", "-o", url.path, "--data-format=LEF32@16000", text]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "The installed offline Daniel voice is required.")
        let file = try AVAudioFile(forReading: url)
        try #require(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
        try #require(file.length >= 4_800 && file.length <= 240_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let pointer = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
    }
}

private func configuration() -> ProcessingConfiguration {
    ProcessingConfiguration(modelID: ModelCatalog.primaryText.id, revision: ModelCatalog.primaryText.revision ?? "",
        runtime: "Residency fixture", quantization: "4-bit", inputLimit: 4096, outputLimit: 2048)
}

/// An installation receipt plus sparse files of the pinned sizes: it passes the cheap
/// installed check, but holds no model data and is never hashed or loaded here.
private func writeSparseTextInstallation(in directory: URL) throws {
    let model = ModelCatalog.primaryText
    let root = directory.appendingPathComponent(model.id, isDirectory: true)
    for artifact in model.artifacts {
        let url = root.appendingPathComponent(artifact.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(artifact.bytes))
        try handle.close()
    }
    let receipt = ProcessingConfiguration(modelID: model.id, revision: model.revision ?? "", runtime: model.runtime,
        quantization: model.quantization,
        artifactHashes: Dictionary(uniqueKeysWithValues: model.artifacts.map { ($0.path, $0.sha256) }))
    try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("installation.json"))
}

private func transformRequest(configuration: ProcessingConfiguration, source: String,
                              mode: DictationOutputMode = .clean) -> DictationTransformRequest {
    DictationTransformRequest(sourceRevisionID: UUID(), sourceSHA256: DictationTransformPolicy.sourceDigest(source),
        mode: mode, sourceText: source, configuration: configuration)
}

private func correctionEvidence() throws -> CorrectionEvidence {
    let source = DictationTextRevision(rawText: "Send die Rechnung an Muler.", text: "Send die Rechnung an Muler.",
        sourceTranscriptIDs: [UUID()])
    let edited = DictationTextRevision(rawText: source.rawText, text: "Send die Rechnung an Müller.",
        sourceTranscriptIDs: source.sourceTranscriptIDs)
    return try #require(CorrectionLearningPolicy.evidence(source: source, edited: edited,
        sessionID: UUID(), takeID: UUID(), appBundleID: nil))
}

private func milliseconds(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1_000_000_000_000_000
}

private struct ResidencySample: Codable {
    let name: String
    let milliseconds: Double
    let text: String?
    let memory: [String: UInt64]
}

private struct ResidencyReport: Codable {
    let purpose = "One installed local worker retaining both serialized models, actual synthetic mixed-language speech and Clean output. Cold and warm samples are reported separately; this is not whole-app Finish, microphone, broad accuracy, thermal or battery qualification."
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let physicalRAM = ProcessInfo.processInfo.physicalMemory
    let configuration: ProcessingConfiguration
    var samples: [ResidencySample] = []
    var classification: CorrectionClassificationResult?
    var teardown: [String: UInt64] = [:]
}
