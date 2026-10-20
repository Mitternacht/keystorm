import Foundation
import Testing
@testable import Keystorm

@MainActor
struct PauseResumeTests {
    @Test func resumeKeepsTakeIdentityAndPinnedEditSelectionAcrossIntervals() throws {
        var session = VoiceSession()
        session.brief = BriefDocument()
        let selected = [UUID()]
        let firstInterval = UUID()
        let original = try WorkspaceModel.beginCaptureInterval(in: &session, resuming: nil, intervalID: firstInterval,
            intent: .editBrief, targetSection: .constraints, selectedBlockIDs: selected)
        session.brief?.revisionID = UUID() // Editing the document while paused must not silently repin the command.
        var intervalIDs = [firstInterval]
        for _ in 0..<3 {
            session.brief?.takes[0].status = .paused
            let next = UUID()
            intervalIDs.append(next)
            let resumed = try WorkspaceModel.beginCaptureInterval(in: &session, resuming: original.id, intervalID: next,
                intent: .addMaterial, targetSection: .changes, selectedBlockIDs: [])
            #expect(resumed.id == original.id)
            #expect(resumed.intent == .editBrief)
            #expect(resumed.targetSection == .constraints)
            #expect(resumed.selectedBlockIDs == selected)
            #expect(resumed.expectedRevision == original.expectedRevision)
            #expect(resumed.status == .recording)
        }
        #expect(session.brief?.takes.count == 1)
        #expect(session.brief?.takes.first?.captureIntervalIDs == intervalIDs)
        #expect(session.intervals.map(\.id) == intervalIDs)
    }

    @Test func aNewTakeRequiresExplicitFinishAndFinishedOrTrashedTakeCannotResume() throws {
        var session = VoiceSession()
        let take = try WorkspaceModel.beginCaptureInterval(in: &session, resuming: nil, intervalID: UUID(),
            intent: .addMaterial, targetSection: .changes, selectedBlockIDs: [])
        session.brief?.takes[0].status = .paused
        #expect(throws: (any Error).self) {
            try WorkspaceModel.beginCaptureInterval(in: &session, resuming: nil, intervalID: UUID(),
                intent: .addMaterial, targetSection: .changes, selectedBlockIDs: [])
        }
        session.brief?.takes[0].status = .pending
        #expect(throws: (any Error).self) {
            try WorkspaceModel.beginCaptureInterval(in: &session, resuming: take.id, intervalID: UUID(),
                intent: .addMaterial, targetSection: .changes, selectedBlockIDs: [])
        }
        session.brief?.takes[0].status = .paused
        session.brief?.takes[0].trashedAt = Date()
        #expect(throws: (any Error).self) {
            try WorkspaceModel.beginCaptureInterval(in: &session, resuming: take.id, intervalID: UUID(),
                intent: .addMaterial, targetSection: .changes, selectedBlockIDs: [])
        }
        #expect(session.intervals.count == 1)
    }

    @Test func pausedDowntimeIsExcludedAndSpeechContextNeverCrossesResumeBoundary() throws {
        let first = UUID(), resumed = UUID(), unrelated = UUID()
        var session = VoiceSession()
        var take = BriefTake(intervalID: first, intent: .addMaterial, targetSection: .changes,
            expectedRevision: UUID(), status: .paused)
        take.intervalIDs.append(resumed)
        session.intervals = [CaptureInterval(id: first, startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 2)),
            CaptureInterval(id: resumed, startedAt: Date(timeIntervalSince1970: 3_602),
                endedAt: Date(timeIntervalSince1970: 3_605.5))]
        let left = segment(interval: first, start: 0, seconds: 2)
        let right = segment(interval: resumed, start: 2, seconds: 1.5)
        let neighbor = segment(interval: resumed, start: 3.5, seconds: 2)
        session.segments = [left, right, neighbor, segment(interval: unrelated, start: 5.5, seconds: 4)]
        #expect(WorkspaceModel.recordedDuration(of: take, in: session) == 5.5)
        let oldTail = try #require(WorkspaceModel.transcriptionWindow(for: left, in: session.segments))
        #expect(oldTail.segments.map(\.id) == [left.id])
        #expect(!oldTail.hasRightContext)
        let resumedHead = try #require(WorkspaceModel.transcriptionWindow(for: right, in: session.segments))
        #expect(resumedHead.segments.map(\.id) == [right.id, neighbor.id])
        #expect(resumedHead.hasRightContext)
    }

    @Test func interruptedTakeReopensPausedAndFinishesWithoutMicrophoneOrNewIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        let take = try WorkspaceModel.beginCaptureInterval(in: &session, resuming: nil, intervalID: UUID(),
            intent: .editBrief, targetSection: .constraints, selectedBlockIDs: [UUID()])
        try await store.save(session)
        let model = WorkspaceModel(root: root)
        await model.initialize(loadLibrary: true)
        #expect(!model.isRecording)
        #expect(model.canResumeTake)
        #expect(model.openTake?.id == take.id)
        #expect(model.openTake?.status == .paused)
        #expect(model.openTake?.intent == take.intent)
        #expect(model.openTake?.expectedRevision == take.expectedRevision)
        #expect(model.takeElapsed == 0)
        await model.finishTake()
        #expect(model.error == nil)
        #expect(!model.hasOpenTake)
        #expect(model.currentBrief?.takes.first?.id == take.id)
        #expect(model.currentBrief?.takes.first?.status == .pending)
        await model.stopForTermination()
        let reopened = WorkspaceModel(root: root)
        await reopened.initialize(loadLibrary: true)
        #expect(!reopened.canResumeTake)
        #expect(reopened.currentBrief?.takes.first?.id == take.id)
        #expect(reopened.currentBrief?.takes.first?.status == .pending)
        await reopened.stopForTermination()
    }

    @Test func resumedHUDUsesLogicalTakeTimeAndDoesNotSkipAnUnprocessedEarlierTail() throws {
        let oldInterval = UUID(), resumedInterval = UUID()
        var session = VoiceSession()
        let head = segment(interval: oldInterval, start: 10, seconds: 2)
        let oldTail = segment(interval: oldInterval, start: 12, seconds: 2)
        let resumed = segment(interval: resumedInterval, start: 90, seconds: 1)
        var take = BriefTake(intervalID: oldInterval, intent: .addMaterial, targetSection: .changes,
            expectedRevision: UUID(), status: .recording)
        take.intervalIDs.append(resumedInterval)
        session.segments = [head, oldTail, resumed]
        session.transcripts = [head, resumed].map {
            TranscriptRevision(rawText: "Saved words", text: "Saved words", segmentIDs: [$0.id],
                startTime: $0.startTime, endTime: $0.endTime, timingPrecision: .window)
        }
        let coverage = WorkspaceModel.recordingHUDCoverage(for: take, in: session, segmentID: resumed.id)
        #expect(coverage.saved == 5)
        #expect(coverage.transcribed == 2)
        #expect(coverage.segmentStart == 4)
        #expect(coverage.segmentEnd == 5)
        var hud = RecordingHUDSession(sessionID: session.id, intervalID: resumedInterval,
            title: "Resumed take", hasSpeechModel: true, takeID: take.id)
        hud.synchronizeCoverage(saved: 4, transcribed: 2)
        hud.receivedPreview(text: "New live words", words: [], startTime: 4, endTime: 5)
        #expect(hud.snapshot.status.contains("Saved through 0:04"))
        hud.receivedTranscript(segmentID: resumed.id, startTime: 4, endTime: 5, text: "New saved words", isComplete: true)
        hud.clearPreview()
        hud.synchronizeCoverage(saved: coverage.saved, transcribed: coverage.transcribed)
        #expect(hud.snapshot.status.contains("Saved through 0:05"))
        #expect(hud.snapshot.status.contains("catching up"))
        session.transcripts.append(TranscriptRevision(rawText: "Older tail", text: "Older tail", segmentIDs: [oldTail.id],
            startTime: oldTail.startTime, endTime: oldTail.endTime, timingPrecision: .window))
        let finished = WorkspaceModel.recordingHUDCoverage(for: take, in: session, segmentID: oldTail.id)
        #expect(finished.segmentStart == 2)
        #expect(finished.segmentEnd == 4)
        #expect(finished.transcribed == 5)
        hud.receivedTranscript(segmentID: oldTail.id, startTime: 2, endTime: 4, text: "Older tail", isComplete: true)
        hud.synchronizeCoverage(saved: finished.saved, transcribed: finished.transcribed)
        #expect(hud.snapshot.status.contains("Live transcript"))
        #expect(hud.snapshot.transcript == "Older tail\n\nNew saved words")
        session.unavailableSegmentIDs = [head.id]
        let unavailable = WorkspaceModel.recordingHUDCoverage(for: take, in: session)
        #expect(unavailable.saved == 0)
        #expect(unavailable.transcribed == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentPauseAndTerminationAwaitBothWriterAndCatalogDrain() async {
        let model = WorkspaceModel()
        let drain = ControlledPauseDrain()
        let owner = Task { await model.withCapturePause { await drain.run() } }
        await drain.waitForStage(1)
        let pause = Task {
            drain.callerEntered()
            await model.pauseRecording()
            drain.pauseReturned = true
        }
        let termination = Task {
            drain.callerEntered()
            await model.stopForTermination()
            drain.terminationReturned = true
        }
        await drain.waitForCallers()
        pause.cancel() // Cancellation must not let acknowledged audio outrun its durable catalog.
        #expect(!drain.pauseReturned)
        #expect(!drain.terminationReturned)
        #expect(drain.startedCount == 1)
        drain.finishWriter()
        await drain.waitForStage(2)
        #expect(!drain.pauseReturned)
        #expect(!drain.terminationReturned)
        drain.finishCatalog()
        await owner.value
        await pause.value
        await termination.value
        #expect(drain.pauseReturned)
        #expect(drain.terminationReturned)
        #expect(drain.stage == 3)
        #expect(drain.startedCount == 1)
    }

    @MainActor
    private final class ControlledPauseDrain {
        private(set) var stage = 0
        private(set) var startedCount = 0
        var pauseReturned = false
        var terminationReturned = false
        private var writer: CheckedContinuation<Void, Never>?
        private var catalog: CheckedContinuation<Void, Never>?
        private var stageWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var callerCount = 0
        private var callersReady: CheckedContinuation<Void, Never>?

        func run() async {
            startedCount += 1
            advance(to: 1)
            await withCheckedContinuation { writer = $0 }
            advance(to: 2)
            await withCheckedContinuation { catalog = $0 }
            advance(to: 3)
        }
        func waitForStage(_ required: Int) async {
            guard stage < required else { return }
            await withCheckedContinuation { stageWaiters.append((required, $0)) }
        }
        func callerEntered() {
            callerCount += 1
            if callerCount >= 2 { callersReady?.resume(); callersReady = nil }
        }
        func waitForCallers() async {
            guard callerCount < 2 else { return }
            await withCheckedContinuation { callersReady = $0 }
        }
        func finishWriter() { writer?.resume(); writer = nil }
        func finishCatalog() { catalog?.resume(); catalog = nil }
        private func advance(to value: Int) {
            stage = value
            let ready = stageWaiters.filter { $0.0 <= value }
            stageWaiters.removeAll { $0.0 <= value }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    private func segment(interval: UUID, start: Double, seconds: Double) -> AudioSegment {
        AudioSegment(intervalID: interval, fileName: "fixture.caf", startTime: start,
            frameCount: Int64(seconds * 16_000), sampleRate: 16_000, channelCount: 1, sha256: "fixture")
    }
}
