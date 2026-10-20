import AVFoundation
import Foundation
import Observation
import Testing
@testable import Keystorm

@MainActor
struct RecordingLibraryTests {
    @Test func briefTrashAndRestorePersistAcrossRestartsWithoutDeletingAudio() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = WorkspaceModel(root: fixture.root)
        await model.initialize(loadLibrary: true)
        await model.renameSession(id: fixture.session.id, title: "Renamed local brief")
        await model.trashSession(id: fixture.session.id)
        #expect(model.error == nil)
        #expect(!model.activeSessions.contains { $0.id == fixture.session.id })
        #expect(model.trashedSessions.first { $0.id == fixture.session.id }?.title == "Renamed local brief")
        try verifyOriginals(fixture)
        await model.stopForTermination()

        let reopened = WorkspaceModel(root: fixture.root)
        await reopened.initialize(loadLibrary: true)
        #expect(reopened.selectedSessionID != fixture.session.id)
        #expect(reopened.trashedSessions.contains { $0.id == fixture.session.id })
        await reopened.restoreSession(id: fixture.session.id)
        #expect(reopened.error == nil)
        #expect(reopened.selectedSessionID == fixture.session.id)
        #expect(reopened.selectedSession?.title == "Renamed local brief")
        #expect(reopened.recordings.map(\.id) == [fixture.takeID])
        #expect(reopened.selectedSession?.currentTranscripts.map(\.id) == fixture.session.currentTranscripts.map(\.id))
        try verifyOriginals(fixture)
        await reopened.stopForTermination()

        let restored = WorkspaceModel(root: fixture.root)
        await restored.initialize(loadLibrary: true)
        #expect(restored.activeSessions.first { $0.id == fixture.session.id }?.title == "Renamed local brief")
        #expect(!restored.trashedSessions.contains { $0.id == fixture.session.id })
        await restored.stopForTermination()
    }

    @Test func recordingRenameTrashRestoreAndWholeTakeCorrectionRetainAllSources() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = WorkspaceModel(root: fixture.root)
        await model.initialize(loadLibrary: true)
        await model.renameTake(id: fixture.takeID, title: "Named recording")
        await model.trashTake(id: fixture.takeID)
        #expect(model.error == nil)
        #expect(model.recordings.isEmpty)
        #expect(model.trashedRecordings.first { $0.id == fixture.takeID }?.take.displayName == "Named recording")
        #expect(model.selectedSession?.availableSegments.isEmpty == true)
        #expect(model.selectedSession?.currentTranscripts.isEmpty == true)
        #expect(model.selectedSession?.segments.count == 2)
        #expect(model.selectedSession?.transcripts.count == 2)
        try verifyOriginals(fixture)
        await model.stopForTermination()

        let reopened = WorkspaceModel(root: fixture.root)
        await reopened.initialize(loadLibrary: true)
        #expect(reopened.trashedRecordings.contains { $0.id == fixture.takeID })
        await reopened.restoreTake(sessionID: fixture.session.id, takeID: fixture.takeID)
        #expect(reopened.error == nil)
        #expect(reopened.recordings.first?.take.displayName == "Named recording")
        #expect(reopened.selectedSession?.currentTranscripts.count == 2)
        let correction = "Use 256, not 512. Do not upload audio."
        await reopened.correctTakeTranscript(id: fixture.takeID, text: correction)
        #expect(reopened.error == nil)
        let snapshot = try #require(reopened.selectedSession)
        let corrected = try #require(snapshot.currentTranscripts.first)
        #expect(snapshot.currentTranscripts.count == 1)
        #expect(corrected.text == correction)
        #expect(Set(corrected.segmentIDs) == Set(fixture.session.segments.map(\.id)))
        #expect(corrected.isComplete)
        for original in fixture.session.transcripts { #expect(snapshot.transcripts.contains(original)) }
        #expect(snapshot.brief?.takes.first?.id == fixture.takeID)
        #expect(snapshot.brief?.takes.first?.status == .pending)
        try verifyOriginals(fixture)
        await reopened.undoLastCorrection()
        #expect(reopened.error == nil)
        let undone = try #require(reopened.selectedSession)
        #expect(undone.currentTranscripts.count == 2)
        #expect(!undone.currentTranscripts.contains { $0.id == corrected.id })
        #expect(undone.transcripts.contains(corrected))
        for original in fixture.session.transcripts {
            let restored = try #require(undone.currentTranscripts.first { $0.segmentIDs == original.segmentIDs })
            #expect(restored.id != original.id)
            #expect(restored.text == original.text)
            #expect(restored.rawText == original.rawText)
            #expect(restored.replacesID == corrected.id)
            #expect(restored.isComplete == original.isComplete)
        }
        await reopened.correctTakeTranscript(id: fixture.takeID, text: correction)
        #expect(reopened.error == nil)
        let redone = try #require(reopened.selectedSession?.currentTranscripts.first)
        #expect(reopened.selectedSession?.currentTranscripts.count == 1)
        #expect(redone.id != corrected.id)
        #expect(redone.text == correction)
        #expect(Set(redone.segmentIDs) == Set(fixture.session.segments.map(\.id)))
        try verifyOriginals(fixture)
        await reopened.stopForTermination()

        let correctedModel = WorkspaceModel(root: fixture.root)
        await correctedModel.initialize(loadLibrary: true)
        #expect(correctedModel.selectedSession?.currentTranscripts.map(\.id) == [redone.id])
        #expect(correctedModel.recordings.first?.transcriptText == correction)
        try verifyOriginals(fixture)
        await correctedModel.stopForTermination()
    }

    @Test func trimAndReplacementVersionsPublishAndRestoreWithoutDestroyingOriginals() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = WorkspaceModel(root: fixture.root)
        await model.initialize(loadLibrary: true)
        await model.trimTake(id: fixture.takeID, start: 0.05, end: 0.15)
        #expect(model.error == nil)
        let trimmed = try #require(model.currentBrief?.takes.first)
        let trimID = try #require(trimmed.activeAudioRevisionID)
        let trimSegments = try #require(model.selectedSession).takeSegments(trimmed)
        #expect(trimSegments.map(\.frameCount) == [800, 800])
        #expect(trimSegments.reduce(0) { $0 + $1.duration } == 0.1)
        #expect(model.selectedSession?.segments.count == 4)
        #expect(model.selectedSession?.currentTranscripts.isEmpty == true)
        #expect(model.currentBrief?.takes.first?.id == fixture.takeID)
        try verifyOriginals(fixture)

        await model.restoreTakeAudioVersion(id: fixture.takeID, revisionID: nil)
        #expect(model.error == nil)
        #expect(model.recordings.first?.segments.map(\.id) == fixture.session.segments.map(\.id))
        #expect(model.selectedSession?.currentTranscripts.count == 2)
        let replacement = try writeSource(in: fixture.root, interval: UUID(), start: 0, frames: 4_000)
        let replacementURL = fixture.root.appendingPathComponent(replacement.fileName)
        await model.replaceTake(id: fixture.takeID, from: replacementURL)
        #expect(model.error == nil)
        #expect(model.currentBrief?.takes.first?.audioRevisions?.count == 2)
        #expect(model.recordings.first?.segments.map(\.frameCount) == [4_000])
        #expect(model.recordings.first?.duration == 0.25)
        let replacementHash = try CaptureDurability.sha256(replacementURL)
        #expect(replacementHash == replacement.sha256)
        try verifyOriginals(fixture)

        await model.restoreTakeAudioVersion(id: fixture.takeID, revisionID: trimID)
        #expect(model.error == nil)
        #expect(model.recordings.first?.segments.map(\.id) == trimSegments.map(\.id))
        #expect(model.selectedSession?.segments.count == 5)
        #expect(model.currentBrief?.takes.first?.audioRevisions?.count == 2)
        await model.stopForTermination()

        let reopened = WorkspaceModel(root: fixture.root)
        await reopened.initialize(loadLibrary: true)
        #expect(reopened.currentBrief?.takes.first?.id == fixture.takeID)
        #expect(reopened.currentBrief?.takes.first?.activeAudioRevisionID == trimID)
        #expect(reopened.recordings.first?.segments.map(\.id) == trimSegments.map(\.id))
        #expect(reopened.selectedSession?.unavailableSegmentIDs.isEmpty == true)
        await reopened.restoreTakeAudioVersion(id: fixture.takeID, revisionID: nil)
        #expect(reopened.error == nil)
        #expect(reopened.selectedSession?.currentTranscripts.count == 2)
        #expect(reopened.recordings.first?.segments.map(\.id) == fixture.session.segments.map(\.id))
        try verifyOriginals(fixture)
        await reopened.stopForTermination()
    }

    @Test func failedAudioEditsAndCurrentVersionNoOpPreservePausedTakeAndAssets() async throws {
        let fixture = try await makeFixture(takeStatus: .paused)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = WorkspaceModel(root: fixture.root)
        await model.initialize(loadLibrary: true)
        #expect(model.canResumeTake)
        let initial = try #require(model.selectedSession)
        let sessionDirectory = fixture.audio.deletingLastPathComponent()
        let metadataURL = sessionDirectory.appendingPathComponent("session.json")
        let originalMetadata = try Data(contentsOf: metadataURL)
        let originalFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.audio.path).sorted()
        let unsupported = fixture.root.appendingPathComponent("not-audio.txt")
        try Data("This is not a replacement recording.".utf8).write(to: unsupported)
        await model.replaceTake(id: fixture.takeID, from: unsupported)
        #expect(model.error != nil)
        #expect(model.openTake?.id == fixture.takeID)
        #expect(model.openTake?.status == .paused)
        #expect(model.canResumeTake)
        #expect(model.selectedSession == initial)
        #expect(try Data(contentsOf: metadataURL) == originalMetadata)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.audio.path).sorted() == originalFiles)
        model.error = nil
        await model.restoreTakeAudioVersion(id: fixture.takeID, revisionID: UUID())
        #expect(model.error != nil)
        #expect(model.openTake?.status == .paused)
        #expect(model.canResumeTake)
        #expect(model.selectedSession == initial)
        #expect(try Data(contentsOf: metadataURL) == originalMetadata)
        await model.restoreTakeAudioVersion(id: fixture.takeID, revisionID: nil)
        #expect(model.error == nil)
        #expect(model.canResumeTake)
        #expect(model.selectedSession == initial)
        #expect(try Data(contentsOf: metadataURL) == originalMetadata)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.audio.path).sorted() == originalFiles)
        let children = try FileManager.default.contentsOfDirectory(atPath: sessionDirectory.path)
        #expect(!children.contains { $0.hasPrefix(".recording-edit-") })
        await model.trimTake(id: fixture.takeID, start: 0.05, end: 0.15)
        #expect(model.error == nil)
        #expect(!model.canResumeTake)
        #expect(model.currentBrief?.takes.first?.id == fixture.takeID)
        #expect(model.currentBrief?.takes.first?.status == .pending)
        #expect(model.currentBrief?.takes.first?.audioRevisions?.count == 1)
        try verifyOriginals(fixture)
        await model.stopForTermination()
    }

    @Test func finishingPausedTakePublishesTransitionCompletionAfterPendingSession() async throws {
        let fixture = try await makeFixture(takeStatus: .paused)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = WorkspaceModel(root: fixture.root)
        await model.initialize(loadLibrary: true)
        let observation = FinishTransitionObservation()
        observation.armAtPersistencePublication(of: model)
        await model.finishTake()
        #expect(model.error == nil)
        #expect(observation.armedWithPendingTake)
        #expect(observation.completionNotified)
        #expect(!model.isCaptureTransitioning)
        #expect(model.currentBrief?.takes.first?.status == .pending)
        #expect(!model.hasOpenTake)
        await model.stopForTermination()
    }

    @MainActor
    private final class FinishTransitionObservation {
        private(set) var armedWithPendingTake = false
        private(set) var completionNotified = false

        func armAtPersistencePublication(of model: WorkspaceModel) {
            withObservationTracking {
                _ = model.performanceMeasurements
            } onChange: { [weak self, weak model] in
                // Workspace mutations and these synchronous will-set notifications
                // run on MainActor. At this acknowledgment the session is pending,
                // while finishTake's final transition-clearing defer has not run.
                MainActor.assumeIsolated {
                    guard let self, let model, model.isCaptureTransitioning,
                          model.currentBrief?.takes.first?.status == .pending else { return }
                    self.armedWithPendingTake = true
                    withObservationTracking {
                        _ = model.isCaptureTransitioning
                    } onChange: { [weak self] in
                        MainActor.assumeIsolated { self?.completionNotified = true }
                    }
                }
            }
        }
    }

    private struct Fixture {
        let root: URL
        let audio: URL
        let session: VoiceSession
        let takeID: UUID
    }

    private func makeFixture(takeStatus: BriefTakeStatus = .pending) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Library-\(UUID().uuidString)")
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.title = "Local recording fixture"
        session.status = takeStatus == .paused ? .paused : .ready
        let audio = try await store.audioDirectory(session.id)
        let first = try writeSource(in: audio, interval: UUID(), start: 0)
        let second = try writeSource(in: audio, interval: UUID(), start: 0.1)
        session.segments = [first, second]
        session.intervals = session.segments.map {
            CaptureInterval(id: $0.intervalID, endedAt: Date(), sampleRate: $0.sampleRate, channelCount: $0.channelCount)
        }
        session.transcripts = zip(session.segments, ["Use 512.", "Do not upload audio."]).map { segment, text in
            TranscriptRevision(rawText: text, text: text, segmentIDs: [segment.id],
                startTime: segment.startTime, endTime: segment.endTime, timingPrecision: .window)
        }
        var brief = BriefDocument()
        var take = BriefTake(intervalID: first.intervalID, intent: .addMaterial, targetSection: .changes,
            expectedRevision: brief.revisionID, status: takeStatus, transcriptIDs: session.transcripts.map(\.id))
        take.intervalIDs.append(second.intervalID)
        brief.takes = [take]
        session.brief = brief
        try await store.save(session)
        return Fixture(root: root, audio: audio, session: session, takeID: take.id)
    }

    private func writeSource(in directory: URL, interval: UUID, start: Double, frames: Int64 = 1_600) throws -> AudioSegment {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        let pointer = try #require(buffer.floatChannelData?[0])
        for index in 0..<4_096 { pointer[index] = Float(index % 31) / 100 }
        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString).caf")
        let output = try AVAudioFile(forWriting: url, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        var written: Int64 = 0
        while written < frames {
            buffer.frameLength = AVAudioFrameCount(min(4_096, frames - written))
            try output.write(from: buffer)
            written += Int64(buffer.frameLength)
        }
        output.close()
        let segment = AudioSegment(id: id, intervalID: interval, fileName: url.lastPathComponent,
            startTime: start, frameCount: frames, sampleRate: 16_000, channelCount: 1,
            sha256: try CaptureDurability.sha256(url))
        try JSONEncoder().encode(segment).write(to: directory.appendingPathComponent("\(id.uuidString).json"))
        return segment
    }

    private func verifyOriginals(_ fixture: Fixture) throws {
        for segment in fixture.session.segments {
            let url = fixture.audio.appendingPathComponent(segment.fileName)
            let hash = try CaptureDurability.sha256(url)
            #expect(hash == segment.sha256)
        }
    }
}
