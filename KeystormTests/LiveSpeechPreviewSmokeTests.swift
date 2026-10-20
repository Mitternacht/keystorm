import AVFoundation
import Darwin
import FluidAudio
import Foundation
import Testing
import os
@testable import Keystorm

/// Installed-model compatibility/latency smoke, using synthesized buffers only.
/// Prefixes are independent snapshots, not a microphone/long-form acceptance test.
@MainActor
@Suite(.serialized)
struct LiveSpeechPreviewSmokeTests {
    @Test("Installed Ultra supplies bounded early previews through the production worker",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_PREVIEW_SMOKE"] == "1"),
          .timeLimit(.minutes(5)))
    func installedPreviewRuntime() async throws {
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let inference = InferenceWorkerClient(modelDirectory: models)
        try #require(await inference.isInstalled(ModelCatalog.primarySpeech), "Install Ultra explicitly in Keystorm first.")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-PreviewSmoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let text = "Keep all processing local. Use two hundred fifty six, not five hundred twelve. Never upload audio."
        let fixture = try await makeFixture(text: text, at: directory.appendingPathComponent("fixture.caf"))
        let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(fixture.url)
        try #require(samples.count >= 48_000 && samples.count <= LiveSpeechPreviewPCM.maximumSamples)
        let initial = await inference.memorySnapshot()
        let started = ContinuousClock.now
        try await inference.prepareSpeech(model: ModelCatalog.primarySpeech)
        let preparationMilliseconds = milliseconds(started.duration(to: .now))
        let prepared = await inference.memorySnapshot()
        let pid = try #require(prepared["workerPID"])
        let verificationCount = await inference.integrityVerificationCount
        #expect(pid > 0 && pid != UInt64(getpid()))
        #expect(verificationCount == 1)
        let configuration = try await inference.configuration(for: ModelCatalog.primarySpeech)
        var prefixes: [PreviewPrefixMeasurement] = []
        var firstTextSourceSeconds: Double?
        var firstTextInferenceMilliseconds: Double?
        // Early target prefixes, then longer evidence containing the number/negation.
        let durations = Array(Set([0.8, 1.2, 2.0, 3.0, 4.5, 6.0, Double(samples.count) / 16_000]
            .map { min($0, Double(samples.count) / 16_000) })).sorted()
        for duration in durations {
            let count = min(samples.count, Int((duration * 16_000).rounded()))
            let prefix = Array(samples.prefix(count))
            let prefixStarted = ContinuousClock.now
            let result = try await inference.transcribePreview(samples: prefix, model: ModelCatalog.primarySpeech)
            let inferenceMilliseconds = milliseconds(prefixStarted.duration(to: .now))
            try result.validate(sampleCount: count)
            prefixes.append(PreviewPrefixMeasurement(sourcePrefixSeconds: Double(count) / 16_000,
                inferenceMilliseconds: inferenceMilliseconds, result: result))
            if firstTextSourceSeconds == nil, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                firstTextSourceSeconds = Double(count) / 16_000
                firstTextInferenceMilliseconds = inferenceMilliseconds
            }
        }
        let full = try #require(prefixes.last).result.text.lowercased()
        #expect(firstTextSourceSeconds != nil)
        #expect(full.contains("not") && full.contains("never"))
        #expect(full.contains("256") || full.contains("two hundred"))
        #expect(full.contains("512") || full.contains("five hundred"))
        let repeatedStarted = ContinuousClock.now
        let repeated = try await inference.transcribePreview(samples: Array(samples.prefix(12_800)), model: ModelCatalog.primarySpeech)
        let repeatedMilliseconds = milliseconds(repeatedStarted.duration(to: .now))
        // A fresh decoder must not accumulate words/state from preceding full-window calls.
        #expect(repeated == prefixes.first?.result)
        let silenceStarted = ContinuousClock.now
        let silence = try await inference.transcribePreview(samples: [Float](repeating: 0, count: 48_000), model: ModelCatalog.primarySpeech)
        let silenceMilliseconds = milliseconds(silenceStarted.duration(to: .now))
        #expect(silence.text.isEmpty && silence.words.isEmpty)
        let short = try await inference.transcribePreview(samples: [Float](repeating: 0.01, count: 1_600), model: ModelCatalog.primarySpeech)
        #expect(short.text.isEmpty && short.words.isEmpty)
        await #expect(throws: (any Error).self) {
            try await inference.sendPreviewPCMForTesting(Data(repeating: 0, count: 6_401), model: ModelCatalog.primarySpeech)
        }
        var nonfinite = Data(repeating: 0, count: 6_400)
        var nan = Float.nan.bitPattern.littleEndian
        withUnsafeBytes(of: &nan) { nonfinite.replaceSubrange(0..<4, with: $0) }
        await #expect(throws: (any Error).self) {
            try await inference.sendPreviewPCMForTesting(nonfinite, model: ModelCatalog.primarySpeech)
        }
        try LocalInference.validateSpeechTokenCount(149)
        #expect(throws: (any Error).self) { try LocalInference.validateSpeechTokenCount(150) }
        #expect(throws: (any Error).self) { try LocalInference.validateSpeechTokenCount(151) }
        let after = await inference.memorySnapshot()
        #expect(after["workerPID"] == pid)
        #expect(await inference.integrityVerificationCount == verificationCount)
        await inference.releaseSpeech()
        let unloaded = await inference.memorySnapshot()
        #expect(unloaded["workerPID"] == 0)
        #expect(kill(Int32(pid), 0) == -1 && errno == ESRCH)
        await inference.shutdown()

        let sourceMilliseconds = firstTextSourceSeconds.map { $0 * 1_000 }
        let report = PreviewSmokeReport(hardware: hardwareModel(), physicalRAM: ProcessInfo.processInfo.physicalMemory,
            os: ProcessInfo.processInfo.operatingSystemVersionString, voiceIdentifier: fixture.voiceIdentifier,
            syntheticText: text, audioSHA256: try CaptureDurability.sha256(fixture.url),
            configuration: configuration, preparationMilliseconds: preparationMilliseconds, prefixes: prefixes,
            firstTextSourceSeconds: firstTextSourceSeconds,
            firstTextWarmSourcePlusInferenceMilliseconds: sourceMilliseconds.map { $0 + (firstTextInferenceMilliseconds ?? 0) },
            firstTextIfCaptureAndPrewarmStartTogetherMilliseconds: sourceMilliseconds.map {
                max($0, preparationMilliseconds) + (firstTextInferenceMilliseconds ?? 0)
            }, repeatedPrefixMilliseconds: repeatedMilliseconds, silenceMilliseconds: silenceMilliseconds,
            memory: ["initial": initial, "prepared": prepared, "afterPreviews": after, "unloaded": unloaded])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        Attachment.record(data, named: "live-speech-preview-smoke.json")
        print(String(decoding: data, as: UTF8.self))
    }

    @Test("Paced synthetic mirror and HUD display early worker previews",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_PREVIEW_SMOKE"] == "1"),
          .timeLimit(.minutes(5)))
    func pacedMirrorToHUD() async throws {
        try await runPacedMirrorToHUD(inputSampleRate: 16_000, attachmentName: "paced-live-speech-preview-smoke.json")
    }

    @Test("Paced 48 kHz input displays early worker previews after production resampling",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_PREVIEW_SMOKE"] == "1"),
          .timeLimit(.minutes(5)))
    func paced48kMirrorToHUD() async throws {
        try await runPacedMirrorToHUD(inputSampleRate: 48_000, attachmentName: "paced-48k-live-speech-preview-smoke.json")
    }

    private func runPacedMirrorToHUD(inputSampleRate: Double, attachmentName: String) async throws {
        let packetFrames = Int(inputSampleRate / 10)
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let inference = InferenceWorkerClient(modelDirectory: models)
        try #require(await inference.isInstalled(ModelCatalog.primarySpeech))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-PacedPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureText = "Keep all processing local. Use two hundred fifty six, not five hundred twelve. Never upload audio."
        let fixture = try await makeFixture(text: fixtureText, at: directory.appendingPathComponent("paced.caf"))
        var samples = try AudioConverter(sampleRate: inputSampleRate).resampleAudioFile(fixture.url)
        let originalSampleCount = samples.count
        // Exercise the 12-second ring bound; trailing digital silence is declared synthetic input.
        let minimumFeedSamples = Int((inputSampleRate * 13.2).rounded())
        samples.append(contentsOf: repeatElement(Float.zero, count: max(0, minimumFeedSamples - samples.count)))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: inputSampleRate, channels: 1))
        var packets: [AVReadOnlyAudioPCMBuffer] = []
        for offset in stride(from: 0, to: samples.count, by: packetFrames) {
            let count = min(packetFrames, samples.count - offset)
            let packet = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            packet.frameLength = AVAudioFrameCount(count)
            let destination = try #require(packet.floatChannelData?[0])
            samples.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress!.advanced(by: offset), count: count)
            }
            packets.append(AVReadOnlyAudioPCMBuffer(copying: packet))
        }
        let intervalID = UUID()
        let mirror = LiveAudioBuffer(format: format, intervalID: intervalID)
        defer { mirror.close() }
        var hud = RecordingHUDSession(sessionID: UUID(), intervalID: intervalID,
            title: "Synthetic harness · no microphone", hasSpeechModel: true)
        let start = ContinuousClock.now
        let prepared = Task {
            let began = ContinuousClock.now
            try await inference.prepareSpeech(model: ModelCatalog.primarySpeech)
            return milliseconds(began.duration(to: .now))
        }
        let immutablePackets = packets
        let feed = Task.detached(priority: .userInitiated) {
            var frame: Int64 = 0
            var arrivalLagMilliseconds: [Double] = []
            for packet in immutablePackets {
                let endFrame = frame + Int64(packet.frameLength)
                let endNanoseconds = Int64((Double(endFrame) / inputSampleRate * 1_000_000_000).rounded())
                let due = start.advanced(by: .nanoseconds(endNanoseconds))
                let remaining = ContinuousClock.now.duration(to: due)
                if remaining > .zero { try await Task.sleep(for: remaining) }
                let lag = due.duration(to: .now).components
                arrivalLagMilliseconds.append(Double(lag.seconds) * 1_000 + Double(lag.attoseconds) / 1_000_000_000_000_000)
                mirror.enqueue(packet, timestamp: CaptureTimestamp(sampleTime: frame,
                    hostTime: AVAudioTime.hostTime(forSeconds: 100 + Double(frame) / inputSampleRate)))
                frame = endFrame
            }
            return arrivalLagMilliseconds
        }
        defer { feed.cancel(); prepared.cancel() }
        let preparationMilliseconds = try await prepared.value
        var sequence: Int64 = 0
        var previousDiscontinuities: Int64 = 0
        var displays: [PacedPreviewDisplay] = []
        var failures: [String] = []
        var firstDisplayedMilliseconds: Double?
        let deadline = start.advanced(by: .seconds(40))
        while ContinuousClock.now < deadline {
            let cycleStarted = ContinuousClock.now
            if let window = await mirror.snapshot(after: sequence) {
                sequence = window.sequence
                if window.discontinuityCount != previousDiscontinuities {
                    previousDiscontinuities = window.discontinuityCount
                    hud.clearPreview()
                }
                do {
                    let inferenceStarted = ContinuousClock.now
                    let result = try await inference.transcribePreview(samples: window.samples, model: ModelCatalog.primarySpeech)
                    hud.receivedPreview(text: result.text, words: result.words, startTime: window.startTime, endTime: window.endTime)
                    let displayedMilliseconds = milliseconds(start.duration(to: .now))
                    if firstDisplayedMilliseconds == nil, !hud.snapshot.transcript.isEmpty {
                        firstDisplayedMilliseconds = displayedMilliseconds
                    }
                    displays.append(PacedPreviewDisplay(callStartedMilliseconds: milliseconds(start.duration(to: inferenceStarted)),
                        displayedMilliseconds: displayedMilliseconds, sourceStartSeconds: window.startTime,
                        sourceEndSeconds: window.endTime, sampleCount: window.samples.count,
                        inferenceMilliseconds: milliseconds(inferenceStarted.duration(to: .now)),
                        transcript: hud.snapshot.transcript, status: hud.snapshot.status))
                    #expect(window.samples.count <= 192_000)
                    #expect(hud.snapshot.transcript.count <= 2_400)
                } catch {
                    failures.append(error.localizedDescription)
                    hud.previewUnavailable(error.localizedDescription)
                    try await Task.sleep(for: .seconds(2))
                }
            }
            if sequence >= Int64(packets.count) { break }
            let next = cycleStarted.advanced(by: .milliseconds(sequence == 0 ? 100 : 500))
            try await Task.sleep(for: max(.milliseconds(20), ContinuousClock.now.duration(to: next)))
        }
        let packetArrivalLag = try await feed.value
        let diagnostics = await mirror.diagnostics()
        #expect(firstDisplayedMilliseconds != nil)
        #expect(displays.count >= 3)
        #expect(failures.isEmpty)
        #expect(sequence == Int64(packets.count))
        #expect(displays.first.map { $0.sourceEndSeconds >= 0.8 } == true)
        #expect(diagnostics.retainedSamples == 192_000)
        #expect(diagnostics.peakPendingFrames <= diagnostics.maximumPendingFrames)
        #expect(diagnostics.pendingFrames == 0)
        #expect(diagnostics.droppedBuffers == 0 && diagnostics.discontinuityCount == 0)
        let beforeTeardown = await inference.memorySnapshot()
        await inference.shutdown()
        let report = PacedPreviewReport(hardware: hardwareModel(), physicalRAM: ProcessInfo.processInfo.physicalMemory,
            os: ProcessInfo.processInfo.operatingSystemVersionString, voiceIdentifier: fixture.voiceIdentifier,
            syntheticText: fixtureText, audioSHA256: try CaptureDurability.sha256(fixture.url),
            inputSampleRate: inputSampleRate, inputPacketFrames: packetFrames,
            feedSeconds: Double(samples.count) / inputSampleRate,
            trailingDigitalSilenceSeconds: Double(samples.count - originalSampleCount) / inputSampleRate,
            configuration: try await inference.configuration(for: ModelCatalog.primarySpeech),
            preparationMilliseconds: preparationMilliseconds, firstDisplayedMilliseconds: firstDisplayedMilliseconds,
            displays: displays, failures: failures, packetArrivalLagMilliseconds: packetArrivalLag,
            retainedSamples: diagnostics.retainedSamples, peakPendingFrames: diagnostics.peakPendingFrames,
            maximumPendingFrames: diagnostics.maximumPendingFrames, droppedBuffers: diagnostics.droppedBuffers,
            memoryBeforeTeardown: beforeTeardown, memoryAfterTeardown: await inference.memorySnapshot())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        Attachment.record(data, named: attachmentName)
        print(String(decoding: data, as: UTF8.self))
    }

    private func makeFixture(text: String, at url: URL) async throws -> PreviewSpeechFixture {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en") && $0.identifier.hasPrefix("com.apple")
        }
        let voice = try #require(voices.first(where: { $0.language == "en-US" && $0.quality == .default }) ?? voices.first,
            "An installed Apple English speech voice is needed for the offline synthetic fixture.")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let synthesizer = AVSpeechSynthesizer()
        let sink = PreviewSpeechFixtureSink(url: url, voiceIdentifier: voice.identifier)
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

private struct PacedPreviewDisplay: Codable {
    let callStartedMilliseconds: Double
    let displayedMilliseconds: Double
    let sourceStartSeconds: Double
    let sourceEndSeconds: Double
    let sampleCount: Int
    let inferenceMilliseconds: Double
    let transcript: String
    let status: String
}

private struct PacedPreviewReport: Codable {
    var purpose = "Paced synthetic 100ms PCM feed through production LiveAudioBuffer, inference worker, and HUD reducer. Uses equivalent newest-only 500ms policy, not the complete WorkspaceModel, an actual HUD panel, microphone, or durable recorder."
    var qualification = "First display is observed reducer-update wall time after paced feeding/prewarming begin together. Feed includes generated speech followed by exact synthetic silence to fill the bounded ring. No long-form, thermal, battery, UI rendering, or microphone latency qualification."
    var hardware: String
    var physicalRAM: UInt64
    var os: String
    var voiceIdentifier: String
    var syntheticText: String
    var audioSHA256: String
    var inputSampleRate: Double
    var inputPacketFrames: Int
    var outputSampleRate = 16_000
    var feedSeconds: Double
    var trailingDigitalSilenceSeconds: Double
    var configuration: ProcessingConfiguration
    var preparationMilliseconds: Double
    var firstDisplayedMilliseconds: Double?
    var displays: [PacedPreviewDisplay]
    var failures: [String]
    var packetArrivalLagMilliseconds: [Double]
    var retainedSamples: Int
    var peakPendingFrames: Int64
    var maximumPendingFrames: Int64
    var droppedBuffers: Int64
    var memoryBeforeTeardown: [String: UInt64]
    var memoryAfterTeardown: [String: UInt64]
}

private struct PreviewPrefixMeasurement: Codable {
    let sourcePrefixSeconds: Double
    let inferenceMilliseconds: Double
    let result: LiveSpeechPreviewResult
    let sourcePlusInferenceMilliseconds: Double

    init(sourcePrefixSeconds: Double, inferenceMilliseconds: Double, result: LiveSpeechPreviewResult) {
        self.sourcePrefixSeconds = sourcePrefixSeconds
        self.inferenceMilliseconds = inferenceMilliseconds
        self.result = result
        sourcePlusInferenceMilliseconds = sourcePrefixSeconds * 1_000 + inferenceMilliseconds
    }
}

private struct PreviewSmokeReport: Codable {
    var purpose = "Synthetic offline compatibility and prefix latency smoke; not real microphone, long-form, thermal, or semantic acceptance qualification."
    var timingInterpretation = "Prefixes were supplied immediately, without pacing. Source-plus-inference values are arithmetic availability estimates, not observed microphone latency. Prewarm overlap estimate assumes both start together. Token-cap boundary is injected in the pure guard; the model fixture is not claimed to exhaust its decoder."
    var silenceInterpretation = "Only exact digital-zero audio bypasses the model. No amplitude or VAD cutoff is applied to quiet speech."
    var hardware: String
    var physicalRAM: UInt64
    var os: String
    var voiceIdentifier: String
    var syntheticText: String
    var audioSHA256: String
    var configuration: ProcessingConfiguration
    var preparationMilliseconds: Double
    var prefixes: [PreviewPrefixMeasurement]
    var firstTextSourceSeconds: Double?
    var firstTextWarmSourcePlusInferenceMilliseconds: Double?
    var firstTextIfCaptureAndPrewarmStartTogetherMilliseconds: Double?
    var repeatedPrefixMilliseconds: Double
    var silenceMilliseconds: Double
    var memory: [String: [String: UInt64]]
}

private struct PreviewSpeechFixture: Sendable {
    let url: URL
    let frames: Int64
    let sampleRate: Double
    let channels: Int
    let voiceIdentifier: String
}

/// AVSpeechSynthesizer owns the callback thread. All mutable writer state is lock confined.
private final class PreviewSpeechFixtureSink: @unchecked Sendable {
    private struct State {
        var file: AVAudioFile?
        var continuation: CheckedContinuation<PreviewSpeechFixture, any Error>?
        var finished = false
        var frames: Int64 = 0
        var sampleRate: Double = 0
        var channels = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let url: URL
    private let voiceIdentifier: String

    init(url: URL, voiceIdentifier: String) { self.url = url; self.voiceIdentifier = voiceIdentifier }

    func setContinuation(_ continuation: CheckedContinuation<PreviewSpeechFixture, any Error>) {
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
                    value.continuation?.resume(returning: PreviewSpeechFixture(url: url, frames: value.frames,
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

