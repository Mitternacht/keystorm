import AVFoundation
import Darwin
import Foundation
import Testing
import os
@testable import Keystorm

/// Opt-in compatibility smoke only. No microphone, speaker output, downloads, or benchmark claims.
@MainActor
@Suite(.serialized)
struct LocalModelSmokeTests {
    @Test("Installed Ultra and Qwen run locally with bounded jobs",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_MODEL_SMOKE"] == "1"),
          .timeLimit(.minutes(10)))
    func installedLocalRuntime() async throws {
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let inference = InferenceWorkerClient(modelDirectory: models)
        try #require(await inference.isInstalled(ModelCatalog.primarySpeech), "Install Ultra explicitly in Keystorm first.")
        try #require(await inference.isInstalled(ModelCatalog.primaryText), "Install Qwen3.5-4B 4-bit explicitly in Keystorm first.")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-ModelSmoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixtureText = "Keep all processing local. Use two hundred fifty six, not five hundred twelve."
        let fixture = try await makeFixture(text: fixtureText, at: directory.appendingPathComponent("fixture.caf"))
        let audioID = UUID()
        let audioURL = directory.appendingPathComponent("\(audioID.uuidString).caf")
        try FileManager.default.moveItem(at: fixture.url, to: audioURL)
        let segment = AudioSegment(id: audioID, intervalID: UUID(), fileName: audioURL.lastPathComponent,
            startTime: 0, frameCount: fixture.frames, sampleRate: fixture.sampleRate,
            channelCount: fixture.channels, sha256: try CaptureDurability.sha256(audioURL))
        try #require(segment.duration > 0 && segment.duration <= 15)
        var timings: [String: Double] = [:]
        var memory: [String: [String: UInt64]] = ["initial": await inference.memorySnapshot()]
        let verificationStarted = ContinuousClock.now
        let speechConfig = try #require(try await inference.verifiedConfiguration(for: ModelCatalog.primarySpeech))
        timings["speechIntegrityMilliseconds"] = milliseconds(verificationStarted.duration(to: .now))
        let coldStarted = ContinuousClock.now
        let cold = try await inference.transcribeWindow(segments: [segment], directory: directory, model: ModelCatalog.primarySpeech)
        timings["speechColdMilliseconds"] = milliseconds(coldStarted.duration(to: .now))
        #expect(cold.transcript.isComplete)
        #expect(!cold.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(cold.transcript.segmentIDs == [segment.id])
        #expect(!cold.words.isEmpty)
        #expect(cold.words.allSatisfy { $0.startTime >= 0 && $0.endTime >= $0.startTime && $0.endTime <= segment.duration + 0.5 })
        memory["speechLoaded"] = await inference.memorySnapshot()
        let speechPID = try #require(memory["speechLoaded"]?["workerPID"])
        #expect(speechPID > 0 && speechPID != UInt64(getpid()))
        let hashCount = await inference.integrityVerificationCount
        let warmStarted = ContinuousClock.now
        let warm = try await inference.transcribeWindow(segments: [segment], directory: directory, model: ModelCatalog.primarySpeech)
        timings["speechWarmMilliseconds"] = milliseconds(warmStarted.duration(to: .now))
        #expect(!warm.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(await inference.integrityVerificationCount == hashCount)
        let teardownStarted = ContinuousClock.now
        await inference.releaseSpeech()
        timings["speechTeardownMilliseconds"] = milliseconds(teardownStarted.duration(to: .now))
        memory["afterSpeechTeardown"] = await inference.memorySnapshot()
        #expect(memory["afterSpeechTeardown"]?["workerPID"] == 0)
        #expect(kill(Int32(speechPID), 0) == -1 && errno == ESRCH)

        let textConfig = try #require(try await inference.verifiedConfiguration(for: ModelCatalog.primaryText))
        #expect(!textConfig.thinking)
        let reference = "Use 256, not 512. Never upload audio."
        let transcript = TranscriptRevision(rawText: reference, text: reference, origin: .imported, timingPrecision: .unavailable)
        let extractionStarted = ContinuousClock.now
        let facts = try await inference.extract(transcripts: [transcript], contexts: [], config: textConfig)
        timings["textColdExtractionMilliseconds"] = milliseconds(extractionStarted.duration(to: .now))
        memory["textLoaded"] = await inference.memorySnapshot()
        let textPID = try #require(memory["textLoaded"]?["workerPID"])
        #expect(textPID > 0 && textPID != speechPID)
        #expect(!facts.isEmpty)
        try LedgerValidation.validate(facts, transcripts: [transcript])
        let evidence = facts.flatMap(\.sources).map(\.quote).joined(separator: " ")
        #expect(evidence.contains("256") && evidence.contains("512"))
        #expect(evidence.contains("Never upload audio"))
        for fact in facts where fact.status == .confirmed {
            #expect(!LocalInference.hasCriticalLiteralMismatch(statement: fact.text,
                evidence: fact.sources.map(\.quote).joined(separator: " ")))
        }
        var brief = BriefDocument()
        let passage = BriefBlock(text: "Use 256, not 512. Never upload audio. Keep the worker separate.")
        let literal = BriefBlock(text: "Sources/Recorder.swift", exact: true)
        try brief.apply([.append(section: .changes, block: passage), .append(section: .constraints, block: literal)],
            expectedRevision: brief.revisionID, label: "Synthetic typed fixture")
        let commandText = "Please make the selected passage more concise. Keep 256, not 512, the ban on uploading audio, and the separate worker."
        let commandTranscript = TranscriptRevision(rawText: commandText, text: commandText, origin: .imported, timingPrecision: .unavailable)
        let commandSource = SourceReference(transcriptID: commandTranscript.id, startUTF8: 0,
            endUTF8: commandText.utf8.count, quote: commandText)
        let originalBrief = brief
        let editStarted = ContinuousClock.now
        let edits = try await inference.proposeBriefEdits(command: commandText, document: brief, targetSection: .changes,
            selectedBlockIDs: [passage.id], sources: [commandSource], config: textConfig)
        timings["textWarmEditProposalMilliseconds"] = milliseconds(editStarted.duration(to: .now))
        try brief.apply(edits, expectedRevision: brief.revisionID, label: "Accept synthetic voice edit")
        let edited = try #require(brief.block(passage.id))
        #expect(!LocalInference.hasCriticalLiteralMismatch(statement: edited.text, evidence: passage.text))
        #expect(edited.text.lowercased().contains("worker"))
        #expect(edited.text.range(of: #"(?:never|not|no)\W+(?:\w+\W+){0,2}upload|without\s+upload"#, options: [.regularExpression, .caseInsensitive]) != nil)
        #expect(brief.block(literal.id) == literal)
        #expect(edited.sources.contains(commandSource))
        var reviewSession = VoiceSession()
        reviewSession.transcripts = [commandTranscript]
        reviewSession.brief = brief
        try brief.markReviewed(session: reviewSession)
        #expect(brief.isReviewed)
        memory["afterWarmEdit"] = await inference.memorySnapshot()
        #expect(memory["afterWarmEdit"]?["grammarTokenizerBuilds"] == 1)
        #expect(memory["afterWarmEdit"]?["grammarSchemaCompilations"] == 2)
        let repeatedStarted = ContinuousClock.now
        let repeatedEdits = try await inference.proposeBriefEdits(command: commandText, document: originalBrief, targetSection: .changes,
            selectedBlockIDs: [passage.id], sources: [commandSource], config: textConfig)
        timings["textWarmCachedEditProposalMilliseconds"] = milliseconds(repeatedStarted.duration(to: .now))
        #expect(repeatedEdits == edits)
        memory["afterCachedEdit"] = await inference.memorySnapshot()
        #expect(memory["afterCachedEdit"]?["grammarTokenizerBuilds"] == 1)
        #expect(memory["afterCachedEdit"]?["grammarSchemaCompilations"] == 3)
        #expect(memory["afterCachedEdit"]?["grammarMatchersCreated"] == 3)
        await inference.releaseText()
        memory["afterTextTeardown"] = await inference.memorySnapshot()
        #expect(memory["afterTextTeardown"]?["workerPID"] == 0)
        #expect(kill(Int32(textPID), 0) == -1 && errno == ESRCH)
        await inference.shutdown()
        let report = LocalSmokeReport(hardware: hardwareModel(),
            physicalRAM: ProcessInfo.processInfo.physicalMemory,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            voiceIdentifier: fixture.voiceIdentifier, fixtureText: fixtureText,
            audioSeconds: segment.duration, audioSHA256: segment.sha256,
            speechConfiguration: speechConfig, textConfiguration: textConfig,
            coldTranscript: cold.transcript.text, warmTranscript: warm.transcript.text,
            referenceTranscript: transcript, facts: facts, voiceCommand: commandTranscript,
            editProposal: edits, editedDocument: brief, timingsMilliseconds: timings, memory: memory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportData = try encoder.encode(report)
        Attachment.record(reportData, named: "local-model-smoke.json")
        print(String(decoding: reportData, as: UTF8.self))
    }

    private func makeFixture(text: String, at url: URL) async throws -> SpeechFixture {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en") && $0.identifier.hasPrefix("com.apple")
        }
        let voice = try #require(voices.first(where: { $0.language == "en-US" && $0.quality == .default }) ?? voices.first,
            "An installed Apple English speech voice is needed for the offline synthetic fixture.")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let synthesizer = AVSpeechSynthesizer()
        let sink = SpeechFixtureSink(url: url, voiceIdentifier: voice.identifier)
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            sink.fail(KeystormError.message("Offline speech fixture generation timed out."))
            synthesizer.stopSpeaking(at: .immediate)
        }
        defer { timeout.cancel(); synthesizer.stopSpeaking(at: .immediate) }
        return try await withCheckedThrowingContinuation { continuation in
            sink.setContinuation(continuation)
            // write retrieves buffers; speak() is intentionally never called.
            synthesizer.write(utterance) { buffer in sink.receive(buffer) }
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1_000_000_000_000_000
    }

    private func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }
}

private struct LocalSmokeReport: Codable {
    var purpose = "Compatibility smoke using synthetic speech, not long-form or semantic acceptance qualification."
    var hardware: String
    var physicalRAM: UInt64
    var os: String
    var voiceIdentifier: String
    var fixtureText: String
    var audioSeconds: Double
    var audioSHA256: String
    var speechConfiguration: ProcessingConfiguration
    var textConfiguration: ProcessingConfiguration
    var coldTranscript: String
    var warmTranscript: String
    var referenceTranscript: TranscriptRevision
    var facts: [Fact]
    var voiceCommand: TranscriptRevision
    var editProposal: [BriefEdit]
    var editedDocument: BriefDocument
    var timingsMilliseconds: [String: Double]
    var memory: [String: [String: UInt64]]
}

private struct SpeechFixture: Sendable {
    let url: URL
    let frames: Int64
    let sampleRate: Double
    let channels: Int
    let voiceIdentifier: String
}

/// AVSpeechSynthesizer owns the callback thread. All mutable writer state is lock confined.
private final class SpeechFixtureSink: @unchecked Sendable {
    private struct State {
        var file: AVAudioFile?
        var continuation: CheckedContinuation<SpeechFixture, any Error>?
        var finished = false
        var frames: Int64 = 0
        var sampleRate: Double = 0
        var channels = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let url: URL
    private let voiceIdentifier: String

    init(url: URL, voiceIdentifier: String) { self.url = url; self.voiceIdentifier = voiceIdentifier }

    func setContinuation(_ continuation: CheckedContinuation<SpeechFixture, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func receive(_ buffer: AVAudioBuffer) {
        state.withLock { value in
            guard !value.finished else { return }
            do {
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    throw KeystormError.message("Speech fixture returned a non-PCM buffer.")
                }
                if pcm.frameLength == 0 {
                    guard value.frames > 0 else { throw KeystormError.message("Speech fixture was empty.") }
                    value.file?.close()
                    value.file = nil
                    try CaptureDurability.synchronize(url)
                    value.finished = true
                    value.continuation?.resume(returning: SpeechFixture(url: url, frames: value.frames,
                        sampleRate: value.sampleRate, channels: value.channels, voiceIdentifier: voiceIdentifier))
                    value.continuation = nil
                } else {
                    if value.file == nil {
                        value.file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                            commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                        value.sampleRate = pcm.format.sampleRate
                        value.channels = Int(pcm.format.channelCount)
                    }
                    guard pcm.format.sampleRate == value.sampleRate,
                          Int(pcm.format.channelCount) == value.channels,
                          Double(value.frames + Int64(pcm.frameLength)) / value.sampleRate <= 15 else {
                        throw KeystormError.message("The synthetic fixture exceeded the bounded window or changed format.")
                    }
                    try value.file?.write(from: pcm)
                    value.frames += Int64(pcm.frameLength)
                }
            } catch {
                value.file?.close()
                value.file = nil
                value.finished = true
                value.continuation?.resume(throwing: error)
                value.continuation = nil
            }
        }
    }

    func fail(_ error: any Error) {
        state.withLock { value in
            guard !value.finished else { return }
            value.file?.close()
            value.file = nil
            value.finished = true
            value.continuation?.resume(throwing: error)
            value.continuation = nil
        }
    }
}
