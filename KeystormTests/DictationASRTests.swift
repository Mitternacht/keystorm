import AVFoundation
import Foundation
import Testing
import os
@testable import Keystorm

/// Real local ASR with synthetic speech, deliberately opt-in. This is a reproducible
/// code-switch regression fixture, not evidence of natural-speaker accuracy.
@MainActor
@Suite(.serialized)
struct DictationASRTests {
    @Test("Local dictation preserves English/German code switches and resumed intervals",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_DICTATION_ASR"] == "1"),
          .timeLimit(.minutes(10)))
    func installedBilingualDictation() async throws {
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let inference = InferenceWorkerClient(modelDirectory: models)
        try #require(await inference.isInstalled(ModelCatalog.primarySpeech),
            "Install the pinned Ultra model explicitly before this offline test.")
        let directory = reportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("DICTATION_ASR_ARTIFACTS \(directory.path)")
        let english = try installedVoice(language: "en-GB", preferredName: "Daniel")
        let german = try installedVoice(language: "de-DE", preferredName: "Anna")
        let configuration = try #require(try await inference.verifiedConfiguration(for: ModelCatalog.primarySpeech))
        let fixtures = [
            BilingualCase(id: "english-base", intervals: [[
                .init(language: "en", text: "Please send Julia the update,"),
                .init(language: "de", text: "aber nicht vor dem Termin in München,"),
                .init(language: "en", text: "and use twenty four items, not forty two.")
            ]], checks: [
                .init(label: "English base", pattern: #"\bsend\b"#),
                .init(label: "German interpolation", pattern: #"\btermin\b"#),
                .init(label: "German negation", pattern: #"\bnicht\b"#),
                .init(label: "English negation", pattern: #"\bnot\b"#),
                .init(label: "Proper name", pattern: #"\bjulia\b"#),
                .init(label: "German Unicode place name", pattern: #"\bmünchen\b"#),
                .init(label: "24", pattern: #"\b(?:24|twenty[\s-]*four|vierundzwanzig)\b"#),
                .init(label: "42", pattern: #"\b(?:42|forty[\s-]*two|zweiundvierzig)\b"#)
            ]),
            BilingualCase(id: "german-base", intervals: [[
                .init(language: "de", text: "Bitte schicke Julia die Notizen,"),
                .init(language: "en", text: "but do not upload the recording,"),
                .init(language: "de", text: "und behalte vierundzwanzig Einträge für München.")
            ]], checks: [
                .init(label: "German base", pattern: #"\bbitte\b"#),
                .init(label: "English interpolation", pattern: #"\bupload\b"#),
                .init(label: "English negation", pattern: #"\b(?:not|don't|don’t)\b"#),
                .init(label: "Proper name", pattern: #"\bjulia\b"#),
                .init(label: "German Unicode place name", pattern: #"\bmünchen\b"#),
                .init(label: "24", pattern: #"\b(?:24|twenty[\s-]*four|vierundzwanzig)\b"#)
            ]),
            BilingualCase(id: "paused-intervals", intervals: [
                [.init(language: "en", text: "Please keep Julia's message,"),
                 .init(language: "de", text: "aber nicht löschen.")],
                [.init(language: "de", text: "Die Größe bleibt vierundzwanzig,"),
                 .init(language: "en", text: "not forty two.")]
            ], checks: [
                .init(label: "English before pause", pattern: #"\bkeep\b"#),
                .init(label: "German before pause", pattern: #"\bnicht\b"#),
                .init(label: "German Unicode after resume", pattern: #"\bgröße\b"#),
                .init(label: "English after resume", pattern: #"\bnot\b"#),
                .init(label: "24", pattern: #"\b(?:24|twenty[\s-]*four|vierundzwanzig)\b"#),
                .init(label: "42", pattern: #"\b(?:42|forty[\s-]*two|zweiundvierzig)\b"#)
            ])
        ]
        var report = BilingualReport(configuration: configuration, englishVoice: english.identifier,
            germanVoice: german.identifier, artifactDirectory: directory.path)
        do {
            for fixture in fixtures {
                let result = try await run(fixture, directory: directory, english: english, german: german,
                    inference: inference)
                report.cases.append(result)
                try persist(report, directory: directory)
                for check in result.checks {
                    #expect(check.passed, "\(fixture.id): \(check.label); actual ASR: \(result.transcript)")
                }
            }
            await inference.shutdown()
        } catch {
            report.failure = error.localizedDescription
            try? persist(report, directory: directory)
            await inference.shutdown()
            throw error
        }
    }

    @Test("Local ASR preserves German words inside a real human English utterance",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_DICTATION_HUMAN_ASR"] == "1"),
          .timeLimit(.minutes(5)))
    func humanEnglishGermanCodeSwitch() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sourceDirectory = repository.appendingPathComponent("Validation/DictationCore/Human")
        let source = sourceDirectory.appendingPathComponent("feli-en-de-258890-272820.wav")
        guard FileManager.default.fileExists(atPath: source.path) else {
            try Test.cancel("The locally retained human mixed-language evaluation clip is unavailable. No media was downloaded.")
        }
        let sourceHash = try CaptureDurability.sha256(source)
        try #require(sourceHash == "1a15877a710e200c4387d18b2a20cae3ffa43413f8d6af54950279f7a2d254fe")
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let inference = InferenceWorkerClient(modelDirectory: models)
        try #require(await inference.isInstalled(ModelCatalog.primarySpeech), "The pinned Ultra model must already be installed.")
        let configuration = try #require(try await inference.verifiedConfiguration(for: ModelCatalog.primarySpeech))
        let directory = reportDirectory().appendingPathComponent("human-en-de")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("DICTATION_HUMAN_ASR_ARTIFACTS \(directory.path)")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let samples = try normalize(source, to: format)
        let channel = try #require(samples.floatChannelData?[0])
        let interval = UUID()
        let receipts = BilingualCaptureReceipts()
        let writer = try SegmentedAudioWriter(directory: directory, format: format, intervalID: interval,
            startTime: 0, segmentSeconds: 5, maximumBufferedSeconds: 30,
            onCommit: { receipts.commit($0) }, onFailure: { receipts.fail($0) })
        do {
            var cursor = 0
            while cursor < Int(samples.frameLength) {
                let count = min(1_600, Int(samples.frameLength) - cursor)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                buffer.frameLength = AVAudioFrameCount(count)
                let destination = try #require(buffer.floatChannelData?[0])
                destination.update(from: channel.advanced(by: cursor), count: count)
                writer.enqueue(AVReadOnlyAudioPCMBuffer(copying: buffer), timestamp: CaptureTimestamp(
                    sampleTime: Int64(cursor),
                    hostTime: AVAudioTime.hostTime(forSeconds: 100 + Double(cursor) / 16_000)))
                cursor += count
            }
            try await writer.finish()
            try #require(receipts.failures.isEmpty, "\(receipts.failures)")
            let segments = receipts.segments
            #expect(segments.map(\.frameCount).reduce(0, +) == Int64(samples.frameLength))
            #expect(segments.allSatisfy { $0.intervalID == interval })
            for segment in segments {
                #expect(try CaptureDurability.sha256(directory.appendingPathComponent(segment.fileName)) == segment.sha256)
            }
            let began = ContinuousClock.now
            let result = try await inference.transcribeWindow(segments: segments, directory: directory,
                model: ModelCatalog.primarySpeech)
            let elapsed = began.duration(to: .now).components
            let checks = [
                BilingualCheck(label: "German stimmhaft remains German", pattern: #"\bstimmhaft\b"#),
                BilingualCheck(label: "German stimmlos remains German", pattern: #"\bstimmlos\b"#),
                BilingualCheck(label: "English voiced anchor", pattern: #"\bvoiced\b"#),
                BilingualCheck(label: "English softer anchor", pattern: #"\bsofter\b"#),
                BilingualCheck(label: "English voiceless anchor", pattern: #"\bvoiceless\b"#)
            ].map {
                BilingualCheckResult(label: $0.label, pattern: $0.pattern,
                    passed: result.transcript.text.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil)
            }
            let reference = try String(contentsOf: sourceDirectory.appendingPathComponent("target-reference.txt"), encoding: .utf8)
            let report = HumanBilingualReport(configuration: configuration, sourceSHA256: sourceHash,
                referenceExcerpt: reference, segments: segments, result: result, checks: checks,
                transcriptionMilliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            Attachment.record(data, named: "human-bilingual-dictation-asr.json")
            print("DICTATION_HUMAN_ASR_TRANSCRIPT \(result.transcript.text)")
            #expect(result.transcript.isComplete)
            #expect(result.transcript.segmentIDs == segments.map(\.id))
            #expect(!result.words.isEmpty)
            for check in checks { #expect(check.passed, "\(check.label); actual ASR: \(result.transcript.text)") }
            await inference.shutdown()
        } catch {
            try? await writer.finish()
            await inference.shutdown()
            throw error
        }
    }

    private func run(_ fixture: BilingualCase, directory: URL, english: AVSpeechSynthesisVoice,
                     german: AVSpeechSynthesisVoice, inference: InferenceWorkerClient) async throws -> BilingualCaseResult {
        let caseDirectory = directory.appendingPathComponent(fixture.id)
        try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        var logicalTime = 0.0
        var results: [BilingualIntervalResult] = []
        for (index, spans) in fixture.intervals.enumerated() {
            let intervalID = UUID()
            let receipts = BilingualCaptureReceipts()
            let writer = try SegmentedAudioWriter(directory: caseDirectory, format: format,
                intervalID: intervalID, startTime: logicalTime, segmentSeconds: 5, maximumBufferedSeconds: 30,
                onCommit: { receipts.commit($0) }, onFailure: { receipts.fail($0) })
            var frame: Int64 = 0
            // A resumed capture gets a fresh microphone clock; one hour of paused wall
            // time must not appear in the durable logical audio timeline.
            let hostStart = 100 + Double(index * 3_600)
            do {
                for (spanIndex, span) in spans.enumerated() {
                    let voice = span.language == "de" ? german : english
                    let source = caseDirectory.appendingPathComponent("interval-\(index)-span-\(spanIndex).caf")
                    try await synthesize(span.text, voice: voice, url: source)
                    let normalized = try normalize(source, to: format)
                    let samples = try #require(normalized.floatChannelData?[0])
                    var cursor = 0
                    while cursor < Int(normalized.frameLength) {
                        let count = min(1_600, Int(normalized.frameLength) - cursor)
                        let slice = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                        slice.frameLength = AVAudioFrameCount(count)
                        let destination = try #require(slice.floatChannelData?[0])
                        destination.update(from: samples.advanced(by: cursor), count: count)
                        writer.enqueue(AVReadOnlyAudioPCMBuffer(copying: slice), timestamp: CaptureTimestamp(
                            sampleTime: frame, hostTime: AVAudioTime.hostTime(forSeconds: hostStart + Double(frame) / 16_000)))
                        cursor += count
                        frame += Int64(count)
                    }
                }
                try await writer.finish()
            } catch {
                try? await writer.finish()
                throw error
            }
            let segments = receipts.segments
            try #require(receipts.failures.isEmpty, "\(receipts.failures)")
            try #require(!segments.isEmpty)
            #expect(segments.allSatisfy { $0.intervalID == intervalID })
            #expect(segments.map(\.frameCount).reduce(0, +) == frame)
            let intervalDuration = Double(frame) / 16_000
            try #require(intervalDuration > 0 && intervalDuration <= 15,
                "Keep every synthetic interval within the production bounded speech window.")
            for segment in segments {
                #expect(try CaptureDurability.sha256(caseDirectory.appendingPathComponent(segment.fileName)) == segment.sha256)
                let sidecar = caseDirectory.appendingPathComponent("\(segment.id.uuidString).json")
                #expect(try JSONDecoder().decode(AudioSegment.self, from: Data(contentsOf: sidecar)) == segment)
            }
            let began = ContinuousClock.now
            let result = try await inference.transcribeWindow(segments: segments, directory: caseDirectory,
                model: ModelCatalog.primarySpeech)
            let duration = began.duration(to: .now).components
            let milliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000
            #expect(result.transcript.isComplete)
            #expect(result.transcript.segmentIDs == segments.map(\.id))
            #expect(!result.transcript.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!result.words.isEmpty)
            #expect(result.words.allSatisfy {
                $0.startTime >= logicalTime && $0.endTime >= $0.startTime && $0.endTime <= logicalTime + intervalDuration + 0.5
            })
            results.append(BilingualIntervalResult(intervalID: intervalID, wallClockOffsetSeconds: Double(index * 3_600),
                reference: spans.map(\.text).joined(separator: " "), segments: segments,
                result: result, transcriptionMilliseconds: milliseconds))
            logicalTime += intervalDuration
        }
        for (left, right) in zip(results, results.dropFirst()) {
            let end = try #require(left.segments.last?.endTime)
            let start = try #require(right.segments.first?.startTime)
            #expect(abs(end - start) < 0.000_001)
            #expect(left.intervalID != right.intervalID)
        }
        let transcript = results.map(\.result.transcript.text).joined(separator: "\n\n")
        let checks = fixture.checks.map {
            BilingualCheckResult(label: $0.label, pattern: $0.pattern,
                passed: transcript.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil)
        }
        return BilingualCaseResult(id: fixture.id, transcript: transcript, intervals: results, checks: checks)
    }

    private func installedVoice(language: String, preferredName: String) throws -> AVSpeechSynthesisVoice {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == language && $0.identifier.hasPrefix("com.apple")
        }
        return try #require(voices.first(where: { $0.name == preferredName }) ??
            voices.first(where: { $0.quality == .default }) ?? voices.first,
            "An installed Apple \(language) voice is required; this test never downloads assets.")
    }

    private func synthesize(_ text: String, voice: AVSpeechSynthesisVoice, url: URL) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        let synthesizer = AVSpeechSynthesizer()
        let sink = BilingualSpeechSink(url: url)
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            sink.fail(KeystormError.message("Local bilingual fixture synthesis timed out."))
            synthesizer.stopSpeaking(at: .immediate)
        }
        defer { timeout.cancel(); synthesizer.stopSpeaking(at: .immediate) }
        try await withCheckedThrowingContinuation { continuation in
            sink.setContinuation(continuation)
            // No speak(), audio-device output, microphone, or remote service.
            synthesizer.write(utterance) { sink.receive($0) }
        }
    }

    private func normalize(_ url: URL, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        try #require(file.length > 0 && file.length <= Int64(file.processingFormat.sampleRate * 15))
        let input = AVAudioPCMBuffer(copying: try file.read(frameCount: AVAudioFrameCount(file.length)))
        let converter = try #require(AVAudioConverter(from: input.format, to: format))
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 4_096
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            guard !supplied else { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        try #require(status != .error && output.frameLength > 0)
        return output
    }

    private func reportDirectory() -> URL {
        let parent = ProcessInfo.processInfo.environment["KEYSTORM_DICTATION_REPORT_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-DictationASR", isDirectory: true)
        return parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func persist(_ report: BilingualReport, directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        Attachment.record(data, named: "bilingual-dictation-asr.json")
        print("DICTATION_ASR_REPORT \(directory.appendingPathComponent("report.json").path)")
    }
}

private struct HumanBilingualReport: Encodable {
    let purpose = "Actual local ASR on a locally retained 13.93-second human English utterance with German technical words. Publisher subtitle excerpt is not independently audited gold; no whole-clip WER or broad accuracy claim."
    let sourceURL = "https://www.youtube.com/watch?v=lHCex5L-0Jc"
    let sourceStartSeconds = 258.89
    let sourceEndSeconds = 272.82
    let configuration: ProcessingConfiguration
    let sourceSHA256: String
    let referenceExcerpt: String
    let segments: [AudioSegment]
    let result: SpeechWindowResult
    let checks: [BilingualCheckResult]
    let transcriptionMilliseconds: Double
}

private struct BilingualSpan { let language: String; let text: String }
private struct BilingualCheck { let label: String; let pattern: String }
private struct BilingualCase { let id: String; let intervals: [[BilingualSpan]]; let checks: [BilingualCheck] }
private struct BilingualCheckResult: Codable { let label: String; let pattern: String; let passed: Bool }
private struct BilingualIntervalResult: Codable {
    let intervalID: UUID
    let wallClockOffsetSeconds: Double
    let reference: String
    let segments: [AudioSegment]
    let result: SpeechWindowResult
    let transcriptionMilliseconds: Double
}
private struct BilingualCaseResult: Codable {
    let id: String
    let transcript: String
    let intervals: [BilingualIntervalResult]
    let checks: [BilingualCheckResult]
}
private struct BilingualReport: Encodable {
    let purpose = "Actual pinned local Ultra ASR on synthetic Apple EN/DE voice spans, including a simulated pause/resume seam. Not a natural-speaker, microphone, insertion, or long-recording qualification."
    let createdAt = Date()
    let configuration: ProcessingConfiguration
    let englishVoice: String
    let germanVoice: String
    let artifactDirectory: String
    var cases: [BilingualCaseResult] = []
    var failure: String?
}

private final class BilingualCaptureReceipts: Sendable {
    private struct State { var segments: [AudioSegment] = []; var failures: [String] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var segments: [AudioSegment] { state.withLock { $0.segments } }
    var failures: [String] { state.withLock { $0.failures } }
    func commit(_ segment: AudioSegment) { state.withLock { $0.segments.append(segment) } }
    func fail(_ message: String) { state.withLock { $0.failures.append(message) } }
}

/// The synthesizer callback owns its thread. Mutable file state stays lock confined.
private final class BilingualSpeechSink: @unchecked Sendable {
    private struct State {
        var file: AVAudioFile?
        var continuation: CheckedContinuation<Void, any Error>?
        var frames: Int64 = 0
        var finished = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let url: URL
    init(url: URL) { self.url = url }
    func setContinuation(_ continuation: CheckedContinuation<Void, any Error>) {
        state.withLock { $0.continuation = continuation }
    }
    func receive(_ buffer: AVAudioBuffer) {
        state.withLock { value in
            guard !value.finished else { return }
            do {
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    throw KeystormError.message("Local speech synthesis returned non-PCM audio.")
                }
                if pcm.frameLength == 0 {
                    guard value.frames > 0 else { throw KeystormError.message("Local speech fixture was empty.") }
                    value.file?.close()
                    value.file = nil
                    try CaptureDurability.synchronize(url)
                    value.finished = true
                    value.continuation?.resume()
                    value.continuation = nil
                    return
                }
                if value.file == nil {
                    value.file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                        commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                }
                guard Double(value.frames + Int64(pcm.frameLength)) / pcm.format.sampleRate <= 15 else {
                    throw KeystormError.message("Local speech fixture exceeded its bounded duration.")
                }
                try value.file?.write(from: pcm)
                value.frames += Int64(pcm.frameLength)
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
