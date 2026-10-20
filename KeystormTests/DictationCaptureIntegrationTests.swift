import AVFoundation
import Foundation
import Testing
@testable import Keystorm

@MainActor
@Suite(.serialized)
struct DictationCaptureIntegrationTests {
    /// Captures ambient samples without playing speech or asking a person to speak.
    /// Existing permission is required; the test never requests a permission prompt.
    @Test("The real microphone tap resumes one durable dictation take",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_DICTATION_CAPTURE"] == "1"),
          .timeLimit(.minutes(3)))
    func authorizedMicrophonePauseResume() async throws {
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authorization == .authorized else {
            try Test.cancel("Microphone capture was not run: existing authorization is \(authorization.rawValue). No permission prompt was requested.")
        }
        let models = try installedModels()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-DictationCapture-\(UUID().uuidString)")
        let model = WorkspaceModel(root: root, modelDirectory: models)
        var reopened: WorkspaceModel?
        do {
            await model.initialize(loadLibrary: true)
            try #require(model.error == nil, "\(model.error ?? "")")
            try #require(model.installedModelIDs.contains(ModelCatalog.primarySpeech.id),
                "The pinned local speech model must already be installed.")
            let handle = try await model.dictationBegin()
            #expect(model.isRecording)
            #expect(model.openTake?.id == handle.takeID)
            #expect(model.dictationMetadata(handle)?.state == .recording)
            try await Task.sleep(for: .milliseconds(800))
            try await model.dictationPause(handle)
            #expect(!model.isRecording)
            #expect(!model.isCaptureTransitioning)
            #expect(model.canResumeTake)
            #expect(model.dictationMetadata(handle)?.state == .paused)
            let first = try snapshot(model, handle: handle)
            let firstTake = try #require(first.brief?.takes.first { $0.id == handle.takeID })
            let firstAudio = first.takeSegments(firstTake)
            try #require(!firstAudio.isEmpty, "The authorized microphone tap must commit real sample frames.")
            #expect(firstTake.captureIntervalIDs.count == 1)
            #expect(firstAudio.allSatisfy { $0.frameCount > 0 && $0.sampleRate > 0 })
            let elapsedWhilePaused = model.takeElapsed
            try await Task.sleep(for: .milliseconds(800))
            #expect(abs(model.takeElapsed - elapsedWhilePaused) < 0.000_001)
            #expect(!model.isRecording)

            try await model.dictationResume(handle)
            #expect(model.isRecording)
            #expect(model.openTake?.id == handle.takeID)
            #expect(model.dictationMetadata(handle)?.state == .recording)
            try await Task.sleep(for: .milliseconds(800))
            try await model.dictationPause(handle)
            let saved = try snapshot(model, handle: handle)
            let take = try #require(saved.brief?.takes.first { $0.id == handle.takeID })
            let audio = saved.takeSegments(take)
            let intervals = take.captureIntervalIDs
            try #require(intervals.count == 2)
            #expect(Set(intervals).count == 2)
            #expect(Set(audio.map(\.intervalID)) == Set(intervals))
            #expect(saved.brief?.takes.filter { $0.trashedAt == nil && [.recording, .paused].contains($0.status) }.count == 1)
            #expect(saved.brief?.takes.count == 1)
            #expect(audio.filter { $0.intervalID == intervals[0] } == firstAudio)
            #expect(model.openTake?.id == handle.takeID)
            #expect(!model.isRecording)
            #expect(model.canResumeTake)
            let totalSeconds = audio.reduce(0) { $0 + $1.duration }
            #expect(abs(model.takeElapsed - totalSeconds) < 0.000_001)
            let leftEnd = try #require(audio.last(where: { $0.intervalID == intervals[0] })?.endTime)
            let rightStart = try #require(audio.first(where: { $0.intervalID == intervals[1] })?.startTime)
            #expect(abs(leftEnd - rightStart) < 0.000_001)
            let firstEnded = try #require(saved.intervals.first(where: { $0.id == intervals[0] })?.endedAt)
            let resumedAt = try #require(saved.intervals.first(where: { $0.id == intervals[1] })?.startedAt)
            #expect(resumedAt.timeIntervalSince(firstEnded) >= 0.7)
            let store = try #require(model.store)
            for segment in audio {
                let url = try await store.audioURL(for: segment, in: saved.id)
                #expect(try CaptureDurability.sha256(url) == segment.sha256)
                #expect(try AVAudioFile(forReading: url).length == segment.frameCount)
            }

            await model.stopForTermination()
            let recovered = WorkspaceModel(root: root, modelDirectory: models)
            reopened = recovered
            await recovered.initialize(loadLibrary: true)
            #expect(!recovered.isRecording)
            #expect(recovered.openTake?.id == handle.takeID)
            #expect(recovered.openTake?.status == .paused)
            #expect(recovered.canResumeTake)
            let restored = try snapshot(recovered, handle: handle)
            #expect(restored.segments == saved.segments)
            #expect(restored.brief?.takes.first?.captureIntervalIDs == intervals)
            #expect(recovered.dictationMetadata(handle)?.state == .paused)
            // Close the source take before deleting this test's private, temporary store.
            await recovered.finishTake()
            #expect(!recovered.hasOpenTake)
            await recovered.stopForTermination()
            let report = CaptureIntegrationReport(handle: handle, authorization: authorization.rawValue,
                intervalIDs: intervals, sourceFrames: audio.map(\.frameCount), sampleRates: audio.map(\.sampleRate),
                sourceHashes: audio.map(\.sha256), logicalAudioSeconds: totalSeconds,
                pausedWallSeconds: resumedAt.timeIntervalSince(firstEnded), recoveredSameTake: restored.brief?.takes.first?.id == handle.takeID)
            try attach(report, named: "dictation-microphone-pause-resume.json")
            try FileManager.default.removeItem(at: root)
        } catch {
            // Writer/catalog drains always precede removal, including failed assertions
            // that throw and cancellation during either real capture interval.
            await model.stopForTermination()
            await reopened?.stopForTermination()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test("Production dictation completion reconciles saved bilingual writer audio and persists its result",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_DICTATION_BACKEND_ASR"] == "1"),
          .timeLimit(.minutes(10)))
    func savedBilingualAudioCompletesThroughWorkspaceBackend() async throws {
        let reportURL = try fixtureReportURL()
        let source = try JSONDecoder().decode(SavedBilingualReport.self, from: Data(contentsOf: reportURL))
        let fixtures = source.cases.filter { $0.id == "english-base" || $0.id == "paused-intervals" }
        try #require(fixtures.count == 2, "Run the bilingual ASR fixture first and retain its report and source files.")
        let models = try installedModels()
        var results: [BackendIntegrationResult] = []
        for fixture in fixtures {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-DictationBackend-\(UUID().uuidString)")
            let seedStore = try SessionStore(root: root)
            let session = try await seed(fixture, sourceDirectory: reportURL.deletingLastPathComponent(), store: seedStore)
            let take = try #require(session.brief?.takes.first)
            let handle = DictationRecordingHandle(sessionID: session.id, takeID: take.id)
            let model = WorkspaceModel(root: root, modelDirectory: models)
            var reopened: WorkspaceModel?
            do {
                await model.initialize(loadLibrary: true)
                try #require(model.error == nil, "\(model.error ?? "")")
                try #require(model.installedModelIDs.contains(ModelCatalog.primarySpeech.id),
                    "The pinned Ultra model must already be installed; this test never downloads it.")
                #expect(model.sessions.first(where: { $0.id == session.id })?.transcripts.isEmpty == true)
                var revision = try await model.dictationComplete(handle)
                let completed = try snapshot(model, handle: handle)
                #expect(!revision.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(revision.rawText == revision.text)
                #expect(model.dictationMetadata(handle)?.state == .ready)
                #expect(model.dictationMetadata(handle)?.textRevision == revision)
                #expect(Set(revision.sourceTranscriptIDs) == Set(completed.currentTranscripts.map(\.id)))
                #expect(completed.currentTranscripts.count == session.segments.count)
                #expect(completed.currentTranscripts.allSatisfy { $0.isComplete })
                #expect(completed.jobs.filter { $0.stage == .transcription }.allSatisfy { $0.status == .completed })
                #expect(completed.segments == session.segments)
                #expect(completed.currentTranscripts.allSatisfy { $0.segmentIDs.count == 1 })
                for segment in session.segments {
                    #expect(completed.currentTranscripts.filter { $0.segmentIDs == [segment.id] }.count == 1)
                }
                #expect(revision.text.range(of: #"\b(?:münchen|größe|löschen)\b"#,
                    options: [.regularExpression, .caseInsensitive]) != nil)
                #expect(revision.text.range(of: #"\b(?:not|please|keep|send)\b"#,
                    options: [.regularExpression, .caseInsensitive]) != nil)
                var edited = revision
                edited.id = UUID()
                edited.text += " Manual correction survives."
                edited.createdAt = Date()
                try await model.dictationSave(handle, state: .ready, revision: edited,
                    delivery: DictationDelivery(requestID: UUID(), textRevisionID: edited.id,
                        targetLabel: "Synthetic receipt fixture", state: .inserted), failure: nil)
                revision = try await model.dictationComplete(handle)
                #expect(model.dictationMetadata(handle)?.outputHistory?.contains { $0.textRevision == edited } == true)
                #expect(model.dictationMetadata(handle)?.delivery == nil)
                #expect(revision.rawText != edited.text)
                await model.stopForTermination()
                let recovered = WorkspaceModel(root: root, modelDirectory: models)
                reopened = recovered
                await recovered.initialize(loadLibrary: true)
                #expect(recovered.dictationMetadata(handle)?.textRevision == revision)
                #expect(recovered.dictationMetadata(handle)?.state == .ready)
                #expect(!recovered.hasOpenTake)
                #expect(!recovered.isRecording)
                await recovered.stopForTermination()
                results.append(BackendIntegrationResult(fixtureID: fixture.id, revision: revision,
                    intervalIDs: take.captureIntervalIDs, sourceSegments: session.segments,
                    transcripts: completed.currentTranscripts, jobs: completed.jobs))
                try FileManager.default.removeItem(at: root)
            } catch {
                await model.stopForTermination()
                await reopened?.stopForTermination()
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }
        try attach(results, named: "dictation-workspace-bilingual-completion.json")
    }

    private func seed(_ fixture: SavedBilingualCase, sourceDirectory: URL, store: SessionStore) async throws -> VoiceSession {
        var session = VoiceSession()
        session.title = "Synthetic bilingual backend fixture"
        let brief = BriefDocument()
        session.brief = brief
        let firstID = try #require(fixture.intervals.first?.intervalID)
        var take = BriefTake(intervalID: firstID, expectedRevision: brief.revisionID, status: .pending)
        take.intervalIDs.append(contentsOf: fixture.intervals.dropFirst().map(\.intervalID))
        session.brief?.takes = [take]
        session.dictation = DictationSession(recordings: [DictationRecordingMetadata(id: take.id, state: .captured)])
        let destination = try await store.audioDirectory(session.id)
        for (index, interval) in fixture.intervals.enumerated() {
            let seconds = interval.segments.reduce(0) { $0 + $1.duration }
            let start = Date(timeIntervalSince1970: 1_000 + Double(index * 3_600))
            session.intervals.append(CaptureInterval(id: interval.intervalID, startedAt: start,
                endedAt: start.addingTimeInterval(seconds), sampleRate: 16_000, channelCount: 1))
            for segment in interval.segments {
                try #require(segment.fileName.lowercased() == "\(segment.id.uuidString).caf".lowercased())
                let original = sourceDirectory.appendingPathComponent(fixture.id).appendingPathComponent(segment.fileName)
                try #require(try CaptureDurability.sha256(original) == segment.sha256)
                let copied = destination.appendingPathComponent(segment.fileName)
                try FileManager.default.copyItem(at: original, to: copied)
                try JSONEncoder().encode(segment).write(to: destination.appendingPathComponent("\(segment.id.uuidString).json"))
                session.segments.append(segment)
            }
        }
        // No transcript fixture is injected: the backend must run actual local inference.
        try await store.save(session)
        return session
    }

    private func snapshot(_ model: WorkspaceModel, handle: DictationRecordingHandle) throws -> VoiceSession {
        try #require(model.sessions.first { $0.id == handle.sessionID })
    }

    private func installedModels() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
    }

    private func fixtureReportURL() throws -> URL {
        if let explicit = ProcessInfo.processInfo.environment["KEYSTORM_DICTATION_ASR_FIXTURE"] {
            return URL(fileURLWithPath: explicit)
        }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let parents = [
            sourceRoot.appendingPathComponent("Validation/DictationCore/ASR"),
            FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-DictationASR")
        ]
        var reports: [URL] = []
        for parent in parents {
            guard let children = try? FileManager.default.contentsOfDirectory(at: parent,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            reports.append(contentsOf: children.map { $0.appendingPathComponent("report.json") }
                .filter { FileManager.default.fileExists(atPath: $0.path) })
        }
        guard let latest = reports.sorted(by: {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }).first else {
            try Test.cancel("Backend ASR was not run: first run DictationASRTests and retain its report, or provide KEYSTORM_DICTATION_ASR_FIXTURE.")
        }
        return latest
    }

    private func attach<T: Encodable>(_ value: T, named name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        Attachment.record(data, named: name)
        if let parent = ProcessInfo.processInfo.environment["KEYSTORM_DICTATION_REPORT_DIRECTORY"] {
            let directory = URL(fileURLWithPath: parent, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }
}

private struct CaptureIntegrationReport: Encodable {
    let purpose = "Real authorized microphone capture and durable pause/resume/recovery only; no natural-speaker accuracy assertion and no microphone audio retained."
    let handle: CaptureReportHandle
    let authorization: Int
    let intervalIDs: [UUID]
    let sourceFrames: [Int64]
    let sampleRates: [Double]
    let sourceHashes: [String]
    let logicalAudioSeconds: Double
    let pausedWallSeconds: Double
    let recoveredSameTake: Bool

    init(handle: DictationRecordingHandle, authorization: Int, intervalIDs: [UUID], sourceFrames: [Int64],
         sampleRates: [Double], sourceHashes: [String], logicalAudioSeconds: Double,
         pausedWallSeconds: Double, recoveredSameTake: Bool) {
        self.handle = CaptureReportHandle(sessionID: handle.sessionID, takeID: handle.takeID)
        self.authorization = authorization
        self.intervalIDs = intervalIDs
        self.sourceFrames = sourceFrames
        self.sampleRates = sampleRates
        self.sourceHashes = sourceHashes
        self.logicalAudioSeconds = logicalAudioSeconds
        self.pausedWallSeconds = pausedWallSeconds
        self.recoveredSameTake = recoveredSameTake
    }
}
private struct CaptureReportHandle: Encodable { let sessionID: UUID; let takeID: UUID }
private struct SavedBilingualReport: Decodable { let cases: [SavedBilingualCase] }
private struct SavedBilingualCase: Decodable { let id: String; let intervals: [SavedBilingualInterval] }
private struct SavedBilingualInterval: Decodable { let intervalID: UUID; let segments: [AudioSegment] }
private struct BackendIntegrationResult: Encodable {
    let fixtureID: String
    let revision: DictationTextRevision
    let intervalIDs: [UUID]
    let sourceSegments: [AudioSegment]
    let transcripts: [TranscriptRevision]
    let jobs: [ProcessingJob]
}
