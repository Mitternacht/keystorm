import AVFoundation
import Foundation
import SQLite3
import Testing
@testable import Keystorm

@MainActor
struct WorkspaceCaptureCapacityTests {
    #if DEBUG
    @Test("A rejected capture backlog preserves acknowledged sources and remains checkpointable",
          .timeLimit(.minutes(3)))
    func rejectedBacklogCanPauseAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-CaptureCapacity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.status = .paused
        session.intervals = [CaptureInterval(endedAt: Date(), sampleRate: 16_000, channelCount: 1)]
        let acknowledged = try await audio(store: store, session: session, start: 0)
        session.segments = [acknowledged]
        let transcript = TranscriptRevision(rawText: "Keep the acknowledged original.",
            text: "Keep the acknowledged original.", segmentIDs: [acknowledged.id],
            startTime: 0, endTime: 0.01)
        session.transcripts = [transcript]
        var brief = BriefDocument()
        brief.takes = [BriefTake(intervalID: session.intervals[0].id,
            expectedRevision: brief.revisionID, status: .paused, transcriptIDs: [transcript.id])]
        session.brief = brief
        let initialSize = try JSONEncoder().encode(Checkpoint(revision: 1, session: session)).count
        session.taskDescription = String(repeating: "x",
            count: SessionStore.maximumIncrementalMetadataBytes - initialSize - 128)
        try await store.save(session)
        let workspace = WorkspaceModel(root: root, modelDirectory: root.appendingPathComponent("EmptyModels"))
        await workspace.initialize(loadLibrary: true)
        try #require(workspace.error == nil)
        await workspace.renameSession(id: session.id, title: "Preserve this unrelated title")
        try #require(workspace.error == nil)
        var pending: [AudioSegment] = []
        for index in 1...40 {
            pending.append(try await audio(store: store, session: session, start: Double(index) * 0.01))
        }
        var oversized = session
        oversized.segments += pending
        #expect(try JSONEncoder().encode(Checkpoint(revision: 3, session: oversized)).count
            > SessionStore.maximumSnapshotBytes,
            "The rejected backlog must exceed the reserved bookkeeping space.")
        await workspace.commitCapturedAudioForTesting(pending, sessionID: session.id)
        await workspace.pauseRecording()
        await workspace.stopForTermination()

        let reopenedStore = try SessionStore(root: root)
        let reopened = try #require(try await reopenedStore.loadSession(session.id))
        #expect(reopened.segments == [acknowledged])
        #expect(reopened.transcripts == [transcript])
        #expect(reopened.title == "Preserve this unrelated title")
        #expect(reopened.status == .interrupted)
        #expect(reopened.gaps.contains { $0.reason.contains("metadata is full") })
        let snapshot = try await reopenedStore.sessionDirectory(session.id).appendingPathComponent("session.json")
        #expect(try Data(contentsOf: snapshot).count <= SessionStore.maximumSnapshotBytes)
        let directory = try await reopenedStore.audioDirectory(session.id)
        for source in [acknowledged] + pending {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(source.fileName).path))
            #expect(FileManager.default.fileExists(atPath:
                directory.appendingPathComponent(source.id.uuidString + ".json").path))
        }
    }

    @Test("Capacity-rejected speech output cannot reappear through a queued checkpoint or Pause",
          .timeLimit(.minutes(3)))
    func rejectedTranscriptCanPauseAndReopen() async throws {
        try await verifyRejectedTranscript(pendingBriefEdit: false, exceedsHardCap: true)
    }

    @Test("A dirty brief cannot bypass rollback of a transcription rejected by the full snapshot cap",
          .timeLimit(.minutes(3)))
    func rejectedTranscriptWithDirtyBriefCanPauseAndReopen() async throws {
        try await verifyRejectedTranscript(pendingBriefEdit: true, exceedsHardCap: true)
    }

    @Test("A dirty transcription checkpoint preserves the reserved space for Pause",
          .timeLimit(.minutes(3)))
    func rejectedTranscriptWithDirtyBriefPreservesPauseReserve() async throws {
        try await verifyRejectedTranscript(pendingBriefEdit: true, exceedsHardCap: false)
    }

    private func verifyRejectedTranscript(pendingBriefEdit: Bool, exceedsHardCap: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-TranscriptCapacity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.status = .paused
        session.intervals = [CaptureInterval(endedAt: Date(), sampleRate: 16_000, channelCount: 1)]
        let source = try await audio(store: store, session: session, start: 0)
        session.segments = [source]
        let original = TranscriptRevision(rawText: "Keep these original words.",
            text: "Keep these original words.", segmentIDs: [source.id], startTime: 0, endTime: 0.01)
        session.transcripts = [original]
        var brief = BriefDocument()
        let block = BriefBlock(text: "Keep this saved brief text.")
        brief.sections[0].blocks = [block]
        brief.takes = [BriefTake(intervalID: session.intervals[0].id,
            expectedRevision: brief.revisionID, status: .paused, transcriptIDs: [original.id])]
        session.brief = brief
        try await store.save(session)
        let workspace = WorkspaceModel(root: root, modelDirectory: root.appendingPathComponent("EmptyModels"))
        await workspace.initialize(loadLibrary: true)
        try #require(workspace.error == nil)
        let running = ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [source.id], totalUnits: 1)
        try await workspace.recordTranscriptionJob(running, sessionID: session.id)
        let beforePadding = try #require(try await store.loadSession(session.id))
        let initialSize = try JSONEncoder().encode(Checkpoint(revision: 999, session: beforePadding)).count
        await workspace.updateSession(title: "Keep this independent edit",
            task: String(repeating: "x", count: SessionStore.maximumIncrementalMetadataBytes - initialSize - 256))
        try #require(workspace.error == nil)
        let durableBefore = try #require(try await store.loadSession(session.id))
        var completed = running
        completed.status = .completed
        completed.completedUnits = 1
        let outputBytes = exceedsHardCap ? 12_000 : 64
        let output = TranscriptRevision(rawText: String(repeating: "y", count: outputBytes),
            text: String(repeating: "y", count: outputBytes), segmentIDs: [source.id], startTime: 0, endTime: 0.01)
        var corrected = output
        corrected.id = UUID()
        corrected.replacesID = output.id
        corrected.text = String(repeating: "z", count: outputBytes)
        let patch = CorrectionPatch(originalRevisionID: output.id, correctedRevisionID: corrected.id,
            before: output.text, after: corrected.text)
        let expectedBlockText = pendingBriefEdit ? "Keep this unsaved independent edit." : block.text
        if pendingBriefEdit {
            // No suspension between the real typing mutation and the speech completion:
            // this forces the full-save branch while the 300 ms debounce is pending.
            workspace.updateBriefBlock(id: block.id, text: expectedBlockText)
        }
        let pendingBefore = try #require(workspace.sessions.first { $0.id == session.id })
        let expectedFailure: SessionMetadataCapacityError =
            pendingBriefEdit && exceedsHardCap ? .snapshotLimitReached : .incrementalLimitReached
        await #expect(throws: expectedFailure) {
            try await workspace.recordTranscriptionResult(output, source: source, job: completed,
                sessionID: session.id, automaticRevisions: [corrected], automaticPatches: [patch])
        }
        let inMemory = try #require(workspace.sessions.first { $0.id == session.id })
        #expect(inMemory.transcripts == [original])
        #expect(inMemory.corrections.isEmpty)
        #expect(inMemory.jobs == [running])
        #expect(inMemory.title == durableBefore.title)
        #expect(inMemory.brief?.takes[0].transcriptIDs == [original.id])
        #expect(inMemory.brief?.block(block.id)?.text == expectedBlockText)
        let durableAfterRejection = try #require(try await store.loadSession(session.id))
        #expect(durableAfterRejection.transcripts == [original])
        #expect(durableAfterRejection.corrections.isEmpty)
        #expect(durableAfterRejection.jobs == [running])

        // This is the exact stale shape a full save queued before the rejected
        // completion would carry. The production write filter must remove it again.
        var queued = pendingBefore
        queued.transcripts += [output, corrected]
        queued.corrections = [patch]
        queued.jobs = [completed]
        queued.brief?.takes[0].transcriptIDs.append(corrected.id)
        queued.brief?.reviewedRevisionID = nil
        queued.invalidateDerivedWork()
        let rejectedBytes = try JSONEncoder().encode(Checkpoint(revision: 999, session: queued)).count
        if exceedsHardCap {
            #expect(rejectedBytes > SessionStore.maximumSnapshotBytes)
        } else {
            #expect(rejectedBytes <= SessionStore.maximumSnapshotBytes)
            #expect(rejectedBytes > SessionStore.incrementalMetadataLimit(for: queued),
                    "This case must fail solely because it would consume the Pause reserve.")
        }
        try await workspace.persistQueuedSnapshotForTesting(queued)
        await workspace.commitCapturedAudioForTesting([], sessionID: session.id)
        await workspace.pauseRecording()
        await workspace.stopForTermination()
        let reopenedStore = try SessionStore(root: root)
        let reopened = try #require(try await reopenedStore.loadSession(session.id))
        #expect(reopened.transcripts == [original])
        #expect(reopened.corrections.isEmpty)
        #expect(reopened.jobs == [running])
        #expect(reopened.segments == [source])
        #expect(reopened.title == durableBefore.title)
        #expect(reopened.brief?.takes[0].transcriptIDs == [original.id])
        #expect(reopened.brief?.block(block.id)?.text == expectedBlockText)
        #expect(reopened.status == .paused)
        let snapshot = try await reopenedStore.sessionDirectory(session.id).appendingPathComponent("session.json")
        #expect(try Data(contentsOf: snapshot).count <= SessionStore.maximumSnapshotBytes)
        let directory = try await reopenedStore.audioDirectory(session.id)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(source.fileName).path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(source.id.uuidString + ".json").path))
    }
    @Test("A rejected speech completion preserves a previously unsaved user correction",
          .timeLimit(.minutes(3)))
    func capacityRejectionPreservesPendingUserCorrection() async throws {
        try await verifyEarlierPendingWorkSurvives(userCorrection: true)
    }

    @Test("A rejected speech completion restores its previously retryable job transition",
          .timeLimit(.minutes(3)))
    func capacityRejectionPreservesRetryableJob() async throws {
        try await verifyEarlierPendingWorkSurvives(userCorrection: false)
    }

    private func verifyEarlierPendingWorkSurvives(userCorrection: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-PendingCapacity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.status = .paused
        session.intervals = [CaptureInterval(endedAt: Date(), sampleRate: 16_000, channelCount: 1)]
        let source = try await audio(store: store, session: session, start: 0)
        session.segments = [source]
        let original = TranscriptRevision(rawText: "Original words.", text: "Original words.",
            segmentIDs: [source.id], startTime: 0, endTime: 0.01)
        session.transcripts = [original]
        var brief = BriefDocument()
        brief.takes = [BriefTake(intervalID: session.intervals[0].id,
            expectedRevision: brief.revisionID, status: .paused, transcriptIDs: [original.id])]
        session.brief = brief
        let running = ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [source.id], totalUnits: 1)
        let initialBytes = try JSONEncoder().encode(Checkpoint(revision: 999, session: session)).count
        session.taskDescription = String(repeating: "x",
            count: SessionStore.maximumIncrementalMetadataBytes - initialBytes - 1_024)
        try await store.save(session)
        let workspace = WorkspaceModel(root: root, modelDirectory: root.appendingPathComponent("EmptyModels"))
        await workspace.initialize(loadLibrary: true)
        try #require(workspace.error == nil)
        if userCorrection {
            try await workspace.recordTranscriptionJob(running, sessionID: session.id)
            // An ordinary user edit remains pending when it cannot fit. It is not
            // generated by, and must not be discarded with, the following speech work.
            await workspace.correctTranscript(id: original.id, text: String(repeating: "User edit. ", count: 1_200))
            try #require(workspace.error != nil)
            let pending = try #require(workspace.sessions.first { $0.id == session.id })
            try #require(pending.transcripts.count == 2 && pending.corrections.count == 1)
        } else {
            try executeSQL("""
                CREATE TRIGGER fail_pending_speech BEFORE INSERT ON session_capture_journal
                BEGIN SELECT RAISE(ABORT, 'Injected pending speech failure'); END;
                """, root: root)
            do {
                try await workspace.recordTranscriptionJob(running, sessionID: session.id)
                Issue.record("The injected journal failure did not run.")
            } catch {
                #expect(error.localizedDescription.contains("Injected pending speech failure"))
            }
            try executeSQL("DROP TRIGGER fail_pending_speech", root: root)
            #expect(try await store.loadSession(session.id)?.jobs.isEmpty == true)
        }
        let prior = try #require(workspace.sessions.first { $0.id == session.id })
        try #require(prior.jobs == [running])
        var completed = running
        completed.status = .completed
        completed.completedUnits = 1
        let output = TranscriptRevision(rawText: String(repeating: "y", count: 12_000),
            text: String(repeating: "y", count: 12_000), segmentIDs: [source.id],
            startTime: 0, endTime: 0.01)
        await #expect(throws: SessionMetadataCapacityError.snapshotLimitReached) {
            try await workspace.recordTranscriptionResult(output, source: source, job: completed,
                sessionID: session.id)
        }
        let after = try #require(workspace.sessions.first { $0.id == session.id })
        #expect(after.transcripts == prior.transcripts)
        #expect(after.corrections == prior.corrections)
        #expect(after.jobs == prior.jobs)
        #expect(after.brief?.takes[0].transcriptIDs == prior.brief?.takes[0].transcriptIDs)

        var queued = prior
        queued.transcripts.append(output)
        queued.jobs = [completed]
        queued.brief?.takes[0].transcriptIDs.append(output.id)
        queued.invalidateDerivedWork()
        if userCorrection {
            // The user's oversized edit still needs explicit action; filtering the
            // rejected speech result must neither discard it nor claim it was saved.
            await #expect(throws: SessionMetadataCapacityError.snapshotLimitReached) {
                try await workspace.persistQueuedSnapshotForTesting(queued)
            }
        } else {
            try await workspace.persistQueuedSnapshotForTesting(queued)
            await workspace.commitCapturedAudioForTesting([], sessionID: session.id)
        }
        await workspace.stopForTermination()
        let retained = try #require(workspace.sessions.first { $0.id == session.id })
        #expect(retained.transcripts == prior.transcripts)
        #expect(retained.corrections == prior.corrections)
        #expect(retained.jobs == prior.jobs)
        let reopened = try #require(try await SessionStore(root: root).loadSession(session.id))
        #expect(reopened.transcripts == [original])
        #expect(reopened.corrections.isEmpty)
        #expect(reopened.jobs == [running])
        #expect(reopened.segments == [source])
    }

    @Test("An unsaved brief edit cannot prevent durable Pause of acknowledged capture",
          .timeLimit(.minutes(3)))
    func oversizedPendingBriefCanPauseAcknowledgedCapture() async throws {
        try await verifyCaptureClosurePreservesPendingDraft(failing: false)
    }

    @Test("A capture failure durably closes acknowledged audio while retaining an oversized pending draft",
          .timeLimit(.minutes(3)))
    func oversizedPendingBriefCanCloseFailedCapture() async throws {
        try await verifyCaptureClosurePreservesPendingDraft(failing: true)
    }

    private func verifyCaptureClosurePreservesPendingDraft(failing: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-PendingCaptureClosure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        var brief = BriefDocument()
        let block = BriefBlock(text: "Saved brief text.")
        brief.sections[0].blocks = [block]
        session.brief = brief
        try await store.save(session)
        let workspace = WorkspaceModel(root: root, modelDirectory: root.appendingPathComponent("EmptyModels"))
        await workspace.initialize(loadLibrary: true)
        try #require(workspace.error == nil)
        let take = try await workspace.persistCaptureStartForTesting(sessionID: session.id)
        let recording = try #require(workspace.sessions.first { $0.id == session.id })
        let source = try await audio(store: store, session: recording, start: 0)
        await workspace.commitCapturedAudioForTesting([source], sessionID: session.id, pauseAfter: false)
        try #require(workspace.error == nil)
        let beforePadding = try #require(workspace.sessions.first { $0.id == session.id })
        let initialBytes = try JSONEncoder().encode(Checkpoint(revision: 999, session: beforePadding)).count
        await workspace.updateSession(task: String(repeating: "x",
            count: SessionStore.incrementalMetadataLimit(for: beforePadding) - initialBytes - 128))
        try #require(workspace.error == nil)
        let acknowledged = try #require(try await store.loadSession(session.id))
        try #require(acknowledged.intervals.contains { $0.endedAt == nil })
        try #require(acknowledged.segments == [source])

        // A small typing edit fits the hard cap but cannot consume capture's reserve.
        workspace.updateBriefBlock(id: block.id, text: String(repeating: "Pending text. ", count: 5))
        let reserveCandidate = try #require(workspace.sessions.first { $0.id == session.id })
        let reserveBytes = try JSONEncoder().encode(Checkpoint(revision: 999, session: reserveCandidate)).count
        try #require(reserveBytes <= SessionStore.maximumSnapshotBytes)
        try #require(reserveBytes > SessionStore.incrementalMetadataLimit(for: reserveCandidate))
        await workspace.flushBriefEdits()
        #expect(workspace.error?.contains("metadata is full") == true)
        #expect(try await store.loadSession(session.id)?.brief?.block(block.id)?.text == block.text)

        // The pending user text can itself exceed the hard cap. Closing capture must
        // preserve it in memory while checkpointing only acknowledged capture data.
        let pendingText = String(repeating: "Do not discard this user edit. ", count: 600)
        workspace.updateBriefBlock(id: block.id, text: pendingText)
        let oversized = try #require(workspace.sessions.first { $0.id == session.id })
        try #require(try JSONEncoder().encode(Checkpoint(revision: 999, session: oversized)).count
            > SessionStore.maximumSnapshotBytes)
        await workspace.flushBriefEdits()
        let message = "Injected capture failure: " + String(repeating: "diagnostic detail ", count: 200)
        if failing {
            await workspace.failCaptureForTesting(sessionID: session.id, message: message)
            // A duplicate callback reuses the existing gap identity in the draft.
            await workspace.failCaptureForTesting(sessionID: session.id, message: message)
        } else {
            await workspace.pauseRecording()
        }
        let pending = try #require(workspace.sessions.first { $0.id == session.id })
        #expect(pending.brief?.block(block.id)?.text == pendingText)
        #expect(pending.segments == [source])
        #expect(pending.intervals.allSatisfy { $0.endedAt != nil })
        #expect(pending.brief?.takes.first { $0.id == take.id }?.status == .paused)
        #expect(workspace.error?.contains("Pending edits remain unsaved") == true)
        if failing { #expect(pending.gaps.first?.reason == message) }
        await workspace.stopForTermination()

        let reopenedStore = try SessionStore(root: root)
        let reopened = try #require(try await reopenedStore.loadSession(session.id))
        #expect(reopened.brief?.block(block.id)?.text == block.text)
        #expect(reopened.segments == [source])
        #expect(reopened.intervals.allSatisfy { $0.endedAt != nil })
        #expect(reopened.status == (failing ? .interrupted : .paused))
        #expect(reopened.brief?.takes.first { $0.id == take.id }?.status == .paused)
        #expect(workspace.sessions.first { $0.id == session.id }?.brief?.block(block.id)?.text == pendingText)
        if failing {
            try #require(reopened.gaps.count == 1)
            #expect(reopened.gaps[0].id == pending.gaps[0].id)
            #expect(reopened.gaps[0].startedAt == pending.gaps[0].startedAt)
            #expect(try JSONEncoder().encode(reopened.gaps[0]).count < 220)
        } else { #expect(reopened.gaps.isEmpty) }
        let snapshot = try await reopenedStore.sessionDirectory(session.id).appendingPathComponent("session.json")
        #expect(try Data(contentsOf: snapshot).count <= SessionStore.maximumSnapshotBytes)
        let directory = try await reopenedStore.audioDirectory(session.id)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(source.fileName).path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(source.id.uuidString + ".json").path))
    }

    @Test("The pre-microphone checkpoint cannot acknowledge an interval without Pause headroom",
          .timeLimit(.minutes(3)))
    func captureStartRequiresPauseReserveBeforeAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-StartCapacity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.brief = BriefDocument()
        let initialBytes = try JSONEncoder().encode(Checkpoint(revision: 999, session: session)).count
        session.taskDescription = String(repeating: "x",
            count: SessionStore.maximumSnapshotBytes - initialBytes - 2_200)
        try await store.save(session)
        let workspace = WorkspaceModel(root: root, modelDirectory: root.appendingPathComponent("EmptyModels"))
        await workspace.initialize(loadLibrary: true)
        try #require(workspace.error == nil)
        await #expect(throws: SessionMetadataCapacityError.incrementalLimitReached) {
            _ = try await workspace.persistCaptureStartForTesting(sessionID: session.id)
        }
        let attempted = try #require(workspace.sessions.first { $0.id == session.id })
        let attemptedBytes = try JSONEncoder().encode(Checkpoint(revision: 999, session: attempted)).count
        #expect(attemptedBytes <= SessionStore.maximumSnapshotBytes)
        #expect(attemptedBytes > SessionStore.incrementalMetadataLimit(for: attempted))
        #expect(!workspace.isRecording)
        await workspace.stopForTermination()
        let reopened = try #require(try await SessionStore(root: root).loadSession(session.id))
        #expect(reopened.intervals.isEmpty)
        #expect(reopened.brief?.takes.isEmpty == true)
        #expect(reopened.status == session.status)
    }

    private func executeSQL(_ sql: String, root: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite").path, &database,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw KeystormError.message("Cannot open the test catalog.") }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw KeystormError.message(String(cString: sqlite3_errmsg(database)))
        }
    }
    #endif

    @Test("Queued snapshots retain unrelated edits while excluding only rejected source metadata")
    func queuedSnapshotKeepsUnrelatedChanges() throws {
        let interval = UUID()
        let accepted = AudioSegment(intervalID: interval, fileName: "accepted.caf",
            startTime: 0, frameCount: 160, sampleRate: 16_000, channelCount: 1, sha256: "")
        let rejected = AudioSegment(intervalID: interval, fileName: "rejected.caf",
            startTime: 0.01, frameCount: 160, sampleRate: 16_000, channelCount: 1, sha256: "")
        var snapshot = VoiceSession()
        snapshot.title = "Unrelated pending rename"
        snapshot.segments = [accepted, rejected]
        snapshot.transcripts = [TranscriptRevision(rawText: "Saved original", text: "Saved original",
            segmentIDs: [accepted.id], startTime: 0, endTime: 0.01)]
        let result = try WorkspaceModel.excludingUnacknowledgedCapture([rejected.id], from: snapshot)
        #expect(result.segments == [accepted])
        #expect(result.title == snapshot.title)
        #expect(result.transcripts == snapshot.transcripts)
        snapshot.jobs = [ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [rejected.id], totalUnits: 1)]
        #expect(throws: (any Error).self) {
            try WorkspaceModel.excludingUnacknowledgedCapture([rejected.id], from: snapshot)
        }
    }

    private struct Checkpoint: Codable {
        var version = 1
        let revision: Int64
        let session: VoiceSession
    }

    private func audio(store: SessionStore, session: VoiceSession, start: Double) async throws -> AudioSegment {
        let id = UUID()
        let directory = try await store.audioDirectory(session.id)
        let url = directory.appendingPathComponent(id.uuidString + ".caf")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 160)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        let source = AudioSegment(id: id, intervalID: session.intervals[0].id,
            fileName: url.lastPathComponent, startTime: start, frameCount: 160,
            sampleRate: 16_000, channelCount: 1, sha256: try SessionStore.checksum(url))
        try JSONEncoder().encode(source).write(to: directory.appendingPathComponent(id.uuidString + ".json"),
            options: .atomic)
        return source
    }
}
