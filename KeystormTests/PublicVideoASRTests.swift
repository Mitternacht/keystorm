import AVFoundation
import Foundation
import Testing
import os
@testable import Keystorm

/// Opt-in publisher-caption evaluation input. No microphone, speech synthesis,
/// reference-text injection, or download is performed by this test.
@MainActor
@Suite(.serialized)
struct PublicVideoASRTests {
    @Test("Public human video audio completes through the production local dictation backend",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_PUBLIC_VIDEO_ASR"] == "1"),
          .timeLimit(.minutes(15)))
    func publicVideoAudioCompletesThroughWorkspaceBackend() async throws {
        let manifestURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYSTORM_PUBLIC_VIDEO_ASR_MANIFEST"]
            ?? "/tmp/Keystorm-PublicVideo-ASR-manifest.json")
        let manifest = try JSONDecoder().decode(PublicVideoManifest.self, from: Data(contentsOf: manifestURL))
        try #require(manifest.schemaVersion == 1)
        try #require(!manifest.fixtures.isEmpty)
        try #require(Set(manifest.fixtures.map(\.id)).count == manifest.fixtures.count)
        let reportDirectory = URL(fileURLWithPath: manifest.reportDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let manifestHash = try CaptureDurability.sha256(manifestURL)
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        var results: [PublicVideoReceipt] = []
        for fixture in manifest.fixtures {
            let result = await run(fixture, models: models)
            results.append(result)
            // Persist the complete result before correctness assertions, including any
            // partial transcripts and jobs from a failed production completion.
            try persist(PublicVideoRun(manifestSHA256: manifestHash, cases: results), directory: reportDirectory)
            #expect(result.failure == nil, "\(fixture.id): \(result.failure ?? "")")
            #expect(result.sourceSHA256 == fixture.expectedSHA256)
            #expect(result.sourceFrames == fixture.expectedFrameCount)
            #expect(result.writerFailures.isEmpty)
            #expect(result.segmentHashesVerified)
            #expect(result.segmentSidecarsVerified)
            #expect(result.exactWriterFrameCoverage)
            #expect(result.exactCompleteTranscriptCoverage)
            #expect(result.allTranscriptionJobsCompleted)
            #expect(result.gaps.isEmpty)
            #expect(result.revision?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            #expect(result.revision?.rawText == result.revision?.text)
            #expect(result.ready)
            #expect(result.persistedAfterReopen)
            #expect(result.privateStoreRemoved)
            #expect(!result.windowCoverage.isEmpty && result.windowCoverage.allSatisfy { $0.endTime - $0.startTime <= 15.001 })
        }
    }

    private func run(_ fixture: PublicVideoFixture, models: URL) async -> PublicVideoReceipt {
        var receipt = PublicVideoReceipt(fixture: fixture)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-PublicVideo-Store-\(UUID().uuidString)")
        var model: WorkspaceModel?
        var reopened: WorkspaceModel?
        var writer: SegmentedAudioWriter?
        let commits = PublicVideoWriterReceipts()
        var handle: DictationRecordingHandle?
        do {
            let source = URL(fileURLWithPath: fixture.audioPath)
            receipt.sourceSHA256 = try CaptureDurability.sha256(source)
            guard receipt.sourceSHA256 == fixture.expectedSHA256 else {
                throw KeystormError.message("Public video source hash does not match the frozen manifest.")
            }
            receipt.referenceSHA256 = try CaptureDurability.sha256(URL(fileURLWithPath: fixture.referencePath))
            let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
            receipt.sourceFrames = input.length
            receipt.sourceSampleRate = input.processingFormat.sampleRate
            receipt.sourceChannels = Int(input.processingFormat.channelCount)
            guard input.length == fixture.expectedFrameCount, input.length > 0,
                  input.processingFormat.sampleRate == fixture.sampleRate,
                  fixture.sampleRate == 16_000, input.processingFormat.channelCount == 1 else {
                throw KeystormError.message("Public video WAV must match its frozen mono 16 kHz frame count.")
            }
            let store = try SessionStore(root: root)
            var session = VoiceSession()
            session.title = "Public human video fixture: \(fixture.id)"
            let brief = BriefDocument()
            let intervalID = UUID()
            let take = BriefTake(intervalID: intervalID, expectedRevision: brief.revisionID, status: .pending)
            session.brief = brief
            session.brief?.takes = [take]
            session.dictation = DictationSession(recordings: [DictationRecordingMetadata(id: take.id, state: .captured)])
            let audioDirectory = try await store.audioDirectory(session.id)
            // Retain the exact production defaults: five-second segments, at most ten
            // seconds queued. A short paced file feed permits disk drain without
            // playing audio or pretending to exercise the live microphone clock.
            let activeWriter = try SegmentedAudioWriter(directory: audioDirectory, format: input.processingFormat,
                intervalID: intervalID, startTime: 0,
                onCommit: { commits.commit($0) }, onFailure: { commits.fail($0) })
            writer = activeWriter
            let block = try #require(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 1_600))
            var cursor: Int64 = 0
            while cursor < input.length {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(1_600, input.length - cursor))
                try input.read(into: block, frameCount: count)
                guard block.frameLength == count else {
                    throw KeystormError.message("Unexpected end of the frozen public-video WAV.")
                }
                activeWriter.enqueue(AVReadOnlyAudioPCMBuffer(copying: block), timestamp: CaptureTimestamp(
                    sampleTime: cursor, hostTime: AVAudioTime.hostTime(forSeconds: 100 + Double(cursor) / fixture.sampleRate)))
                cursor += Int64(count)
                try await Task.sleep(for: .milliseconds(12))
            }
            try await activeWriter.finish()
            writer = nil
            receipt.writerFramesFed = cursor
            receipt.writerFailures = commits.failures
            session.segments = commits.segments.sorted { $0.startTime < $1.startTime }
            receipt.segments = session.segments
            session.intervals = [CaptureInterval(id: intervalID, startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_000 + Double(cursor) / fixture.sampleRate),
                sampleRate: fixture.sampleRate, channelCount: 1)]
            receipt.segmentHashesVerified = try session.segments.allSatisfy {
                try CaptureDurability.sha256(audioDirectory.appendingPathComponent($0.fileName)) == $0.sha256
            }
            receipt.segmentSidecarsVerified = try session.segments.allSatisfy {
                try JSONDecoder().decode(AudioSegment.self,
                    from: Data(contentsOf: audioDirectory.appendingPathComponent("\($0.id.uuidString).json"))) == $0
            }
            var nextFrame: Int64 = 0
            receipt.exactWriterFrameCoverage = !session.segments.isEmpty
            for segment in session.segments {
                let startFrame = Int64((segment.startTime * fixture.sampleRate).rounded())
                receipt.frameCoverage.append(PublicVideoFrameSpan(segmentID: segment.id,
                    firstFrame: startFrame, frameCount: segment.frameCount))
                if segment.intervalID != intervalID || startFrame != nextFrame || segment.frameCount <= 0 {
                    receipt.exactWriterFrameCoverage = false
                }
                nextFrame += segment.frameCount
            }
            receipt.exactWriterFrameCoverage = receipt.exactWriterFrameCoverage && nextFrame == input.length
            guard commits.failures.isEmpty, receipt.exactWriterFrameCoverage,
                  receipt.segmentHashesVerified, receipt.segmentSidecarsVerified else {
                throw KeystormError.message("The production segmented writer did not preserve the complete source.")
            }
            try await store.save(session)
            let recording = DictationRecordingHandle(sessionID: session.id, takeID: take.id)
            handle = recording
            let workspace = WorkspaceModel(root: root, modelDirectory: models)
            model = workspace
            await workspace.initialize(loadLibrary: true)
            if let error = workspace.error { throw KeystormError.message(error) }
            guard workspace.installedModelIDs.contains(ModelCatalog.primarySpeech.id) else {
                throw KeystormError.message("The pinned local Parakeet Ultra model must already be installed.")
            }
            let began = ContinuousClock.now
            do {
                receipt.revision = try await workspace.dictationComplete(recording)
            } catch {
                receipt.transcriptionMilliseconds = milliseconds(began.duration(to: .now))
                throw error
            }
            receipt.transcriptionMilliseconds = milliseconds(began.duration(to: .now))
            capture(workspace, handle: recording, into: &receipt)
            await workspace.stopForTermination()
            model = nil
            let recovered = WorkspaceModel(root: root, modelDirectory: models)
            reopened = recovered
            await recovered.initialize(loadLibrary: true)
            let restored = recovered.sessions.first { $0.id == recording.sessionID }
            receipt.persistedAfterReopen = recovered.error == nil
                && recovered.dictationMetadata(recording)?.textRevision == receipt.revision
                && recovered.dictationMetadata(recording)?.state == .ready
                && restored?.segments == receipt.segments
                && restored?.currentTranscripts == receipt.transcripts
                && !recovered.isRecording && !recovered.hasOpenTake
            await recovered.stopForTermination()
            reopened = nil
        } catch {
            receipt.failure = error.localizedDescription
            if let model, let handle { capture(model, handle: handle, into: &receipt) }
        }
        // Shutdown and writer drain always precede removal of this test's private store.
        if let writer { try? await writer.finish() }
        await model?.stopForTermination()
        await reopened?.stopForTermination()
        receipt.writerFailures = commits.failures
        if receipt.segments.isEmpty { receipt.segments = commits.segments }
        do {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            receipt.privateStoreRemoved = true
        } catch {
            receipt.failure = [receipt.failure, "Temporary store cleanup failed: \(error.localizedDescription)"]
                .compactMap { $0 }.joined(separator: "; ")
        }
        return receipt
    }

    private func capture(_ model: WorkspaceModel, handle: DictationRecordingHandle, into receipt: inout PublicVideoReceipt) {
        guard let session = model.sessions.first(where: { $0.id == handle.sessionID }) else { return }
        receipt.transcripts = session.currentTranscripts
        receipt.jobs = session.jobs
        receipt.configurations = session.configurations
        receipt.gaps = session.gaps
        receipt.ready = model.dictationMetadata(handle)?.state == .ready
        receipt.windowCoverage = session.segments.compactMap { core in
            guard let context = WorkspaceModel.transcriptionWindow(for: core, in: session.segments) else { return nil }
            return PublicVideoWindow(coreSegmentID: core.id, contextSegmentIDs: context.segments.map(\.id),
                startTime: context.segments.first?.startTime ?? 0, endTime: context.segments.last?.endTime ?? 0)
        }
        receipt.exactCompleteTranscriptCoverage = !session.segments.isEmpty
            && receipt.transcripts.count == session.segments.count
            && receipt.transcripts.allSatisfy { $0.isComplete }
            && session.segments.allSatisfy { core in
                receipt.transcripts.filter {
                    $0.segmentIDs == [core.id] && $0.startTime == core.startTime && $0.endTime == core.endTime
                }.count == 1
            }
        let jobs = session.jobs.filter { $0.stage == .transcription }
        receipt.allTranscriptionJobsCompleted = !jobs.isEmpty && jobs.allSatisfy { $0.status == .completed }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private func persist(_ run: PublicVideoRun, directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        try data.write(to: directory.appendingPathComponent("public-video-asr.json"), options: .atomic)
        Attachment.record(data, named: "public-video-asr.json")
        print("PUBLIC_VIDEO_ASR_REPORT \(directory.appendingPathComponent("public-video-asr.json").path)")
    }
}

private struct PublicVideoManifest: Decodable {
    let schemaVersion: Int
    let fixtures: [PublicVideoFixture]
    let reportDirectory: String
}
private struct PublicVideoFixture: Codable {
    let id: String
    let audioPath: String
    let expectedSHA256: String
    let expectedFrameCount: Int64
    let sampleRate: Double
    let sourceURL: String
    let sourceStartSeconds: Double
    let sourceEndSeconds: Double
    let referencePath: String
}
private struct PublicVideoRun: Encodable {
    let purpose = "Actual local Parakeet Ultra production dictation completion on publisher-captioned human video excerpts. No captions are supplied to inference. Caption agreement is scored independently; this does not exercise live microphone capture, hardware pause/resume, global shortcuts, or insertion."
    let createdAt = Date()
    let manifestSHA256: String
    let cases: [PublicVideoReceipt]
}
private struct PublicVideoReceipt: Encodable {
    let fixture: PublicVideoFixture
    var sourceSHA256: String?
    var referenceSHA256: String?
    var sourceFrames: Int64?
    var sourceSampleRate: Double?
    var sourceChannels: Int?
    let writerSegmentSeconds = 5
    let writerMaximumBufferedSeconds = 10
    let fileFeedBlockFrames = 1_600
    let fileFeedYieldMilliseconds = 12
    var writerFramesFed: Int64 = 0
    var writerFailures: [String] = []
    var segmentHashesVerified = false
    var segmentSidecarsVerified = false
    var exactWriterFrameCoverage = false
    var exactCompleteTranscriptCoverage = false
    var allTranscriptionJobsCompleted = false
    var ready = false
    var persistedAfterReopen = false
    var privateStoreRemoved = false
    var transcriptionMilliseconds: Double?
    var frameCoverage: [PublicVideoFrameSpan] = []
    var windowCoverage: [PublicVideoWindow] = []
    var segments: [AudioSegment] = []
    var transcripts: [TranscriptRevision] = []
    var configurations: [ProcessingConfiguration] = []
    var jobs: [ProcessingJob] = []
    var gaps: [SessionGap] = []
    var revision: DictationTextRevision?
    var failure: String?
}
private struct PublicVideoFrameSpan: Encodable {
    let segmentID: UUID
    let firstFrame: Int64
    let frameCount: Int64
}
private struct PublicVideoWindow: Encodable {
    let coreSegmentID: UUID
    let contextSegmentIDs: [UUID]
    let startTime: Double
    let endTime: Double
}
private final class PublicVideoWriterReceipts: Sendable {
    private struct State { var segments: [AudioSegment] = []; var failures: [String] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var segments: [AudioSegment] { state.withLock { $0.segments } }
    var failures: [String] { state.withLock { $0.failures } }
    func commit(_ segment: AudioSegment) { state.withLock { $0.segments.append(segment) } }
    func fail(_ message: String) { state.withLock { $0.failures.append(message) } }
}
