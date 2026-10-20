import AVFoundation
import Foundation
import Testing
@testable import Keystorm

struct RecordingLifecycleTests {
    @Test func legacyTakeDecodesWithoutTrashNamesOrAudioVersions() throws {
        let intervalID = UUID()
        let take = BriefTake(intervalID: intervalID, expectedRevision: UUID(), status: .applied)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(take)) as? [String: Any])
        for key in ["intervalIDs", "name", "trashedAt", "audioRevisions", "activeAudioRevisionID"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(BriefTake.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.id == take.id)
        #expect(decoded.captureIntervalIDs == [intervalID])
        #expect(decoded.activeIntervalIDs == [intervalID])
        #expect(decoded.allIntervalIDs == [intervalID])
        #expect(decoded.displayName == "Recording")
        #expect(decoded.trashedAt == nil && decoded.audioRevisions == nil)
        var sessionObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(VoiceSession())) as? [String: Any])
        sessionObject.removeValue(forKey: "trashedAt")
        #expect(try JSONDecoder().decode(VoiceSession.self, from: JSONSerialization.data(withJSONObject: sessionObject)).trashedAt == nil)
    }

    @Test func trashExcludesCorrectionDescendantsAndRestoreKeepsExactSources() throws {
        var session = VoiceSession()
        let original = TranscriptRevision(rawText: "Do not upload 256 records.", text: "Do not upload 256 records.", origin: .imported)
        let correction = TranscriptRevision(replacesID: original.id, rawText: original.rawText,
            text: "Do not upload 256 records.", origin: .imported)
        session.transcripts = [correction, original] // Descendants need not be stored after their parent.
        var brief = BriefDocument()
        let quote = SourceReference(transcriptID: correction.id, startUTF8: 0,
            endUTF8: correction.text.utf8.count, quote: correction.text)
        try brief.apply([.append(section: .constraints, block: BriefBlock(text: correction.text, origin: .speech, sources: [quote]))],
            expectedRevision: brief.revisionID, label: "Source")
        brief.takes = [BriefTake(expectedRevision: brief.revisionID, status: .applied, transcriptIDs: [original.id])]
        session.brief = brief
        #expect(session.currentTranscripts.map(\.id) == [correction.id])
        session.brief?.takes[0].trashedAt = Date()
        let trashedBrief = try #require(session.brief)
        #expect(session.currentTranscripts.isEmpty)
        #expect(session.transcripts == [correction, original])
        #expect(trashedBrief.reviewIssues(session: session).contains { $0.message.contains("recording in Trash") && $0.severity == .blocker })
        session.brief?.takes[0].trashedAt = nil
        #expect(session.currentTranscripts.map(\.id) == [correction.id])
        #expect(!session.brief!.reviewIssues(session: session).contains { $0.kind == .staleSource })
    }

    @Test func versionSelectionChangesEffectiveCoverageWithoutRewritingHistoricalProgress() throws {
        var session = VoiceSession()
        let base = CaptureInterval(endedAt: Date())
        let resumed = CaptureInterval(endedAt: Date())
        let edited = CaptureInterval(endedAt: Date())
        session.intervals = [base, resumed, edited]
        let segments = [base, resumed, edited].enumerated().map { index, interval in
            AudioSegment(intervalID: interval.id, fileName: "fixture-\(index).caf", startTime: Double(index),
                frameCount: 16_000, sampleRate: 16_000, channelCount: 1, sha256: String(repeating: "0", count: 64))
        }
        session.segments = segments
        session.transcripts = segments.map {
            TranscriptRevision(rawText: "Source", text: "Source", segmentIDs: [$0.id], startTime: $0.startTime, endTime: $0.endTime)
        }
        let revision = RecordingAudioRevision(label: "Trimmed", intervalIDs: [edited.id])
        var take = BriefTake(intervalID: base.id, intervalIDs: [resumed.id], expectedRevision: UUID(), status: .applied,
            audioRevisions: [revision], activeAudioRevisionID: revision.id)
        var brief = BriefDocument()
        brief.takes = [take]
        session.brief = brief
        #expect(take.captureIntervalIDs == [base.id, resumed.id])
        #expect(take.allIntervalIDs == [base.id, resumed.id, edited.id])
        #expect(session.availableSegments.map(\.id) == [segments[2].id])
        #expect(session.activeRecordedDuration == 1 && session.activeTranscribedDuration == 1)
        #expect(session.transcribedThrough == 3)
        take.activeAudioRevisionID = nil
        session.brief?.takes = [take]
        #expect(session.activeRecordedDuration == 2)
        #expect(session.currentTranscripts.count == 2)
        #expect(session.transcribedThrough == 3)
        session.brief?.takes[0].trashedAt = Date()
        #expect(session.activeSegments.isEmpty && session.currentTranscripts.isEmpty)
        #expect(session.activeRecordedDuration == 0 && session.activeTranscribedDuration == 0)
        #expect(session.segments == segments && session.transcribedThrough == 3)
    }

    @Test(arguments: [0, 1, 2, 3])
    func invalidRecordingVersionMetadataIsRejected(variant: Int) throws {
        var session = VoiceSession()
        let base = CaptureInterval(endedAt: Date()), derived = CaptureInterval(endedAt: Date())
        session.intervals = [base, derived]
        let revision = RecordingAudioRevision(label: "Trim", intervalIDs: [derived.id])
        var brief = BriefDocument()
        brief.takes = [BriefTake(intervalID: base.id, expectedRevision: brief.revisionID,
            audioRevisions: [revision], activeAudioRevisionID: revision.id)]
        switch variant {
        case 0: brief.takes[0].activeAudioRevisionID = UUID()
        case 1: brief.takes[0].audioRevisions?[0].intervalIDs = [base.id]
        case 2: brief.takes.append(BriefTake(intervalID: derived.id, expectedRevision: brief.revisionID))
        default: brief.takes[0].audioRevisions?.append(revision)
        }
        #expect(throws: (any Error).self) { try brief.validateRecordingMetadata(session: session) }
    }

    @Test func briefAndRecordingTrashSurviveReopenAndFullArchiveWithOriginalAssets() async throws {
        let (root, store, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let edit = try await render(store: store, baseline: baseline)
        try await store.commitRecordingEdit(edit.session, stagedDirectory: edit.directory, expectedUpdatedAt: baseline.updatedAt)
        var trashed = edit.session
        trashed.trashedAt = Date()
        trashed.brief?.takes[0].name = "Exact source recording"
        trashed.brief?.takes[0].trashedAt = trashed.trashedAt
        try await store.save(trashed)
        let reopened = try SessionStore(root: root)
        let persisted = try #require(try await reopened.loadSessions().first)
        #expect(persisted == trashed)
        #expect(persisted.activeSegments.isEmpty)
        let archive = root.appendingPathComponent("Trash.keystorm")
        try SessionTransfer.exportArchive(session: persisted, audioDirectory: await reopened.audioDirectory(persisted.id), to: archive)
        let imported = try await SessionTransfer.importArchive(from: archive, store: reopened)
        #expect(imported.id != persisted.id)
        #expect(imported.trashedAt == persisted.trashedAt)
        #expect(imported.brief?.takes == persisted.brief?.takes)
        #expect(imported.segments == persisted.segments)
        for segment in persisted.segments {
            #expect(try SessionStore.checksum(await reopened.audioURL(for: segment, in: imported.id)) == segment.sha256)
        }
        var restored = persisted
        restored.trashedAt = nil
        restored.brief?.takes[0].trashedAt = nil
        try await reopened.save(restored)
        #expect(try await reopened.loadSessions().first { $0.id == restored.id }?.activeSegments.map(\.id) == [edit.segment.id])
    }

    @Test func recordingPublicationIsAtomicAndRejectsStaleBaseline() async throws {
        let (root, store, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let edit = try await render(store: store, baseline: baseline)
        await #expect(throws: (any Error).self) {
            try await store.commitRecordingEdit(edit.session, stagedDirectory: edit.directory, expectedUpdatedAt: baseline.updatedAt.addingTimeInterval(-1))
        }
        #expect(!FileManager.default.fileExists(atPath: edit.directory.appendingPathComponent("publication.json").path))
        #expect(try await store.loadSessions().first == baseline)
        try await store.commitRecordingEdit(edit.session, stagedDirectory: edit.directory, expectedUpdatedAt: baseline.updatedAt)
        #expect(!FileManager.default.fileExists(atPath: edit.directory.path))
        let committed = try #require(try await store.loadSessions().first)
        #expect(committed == edit.session)
        #expect(committed.segments.first == baseline.segments.first)
        #expect(committed.availableSegments.map(\.id) == [edit.segment.id])
        #expect(try SessionStore.checksum(await store.audioURL(for: edit.segment, in: committed.id)) == edit.segment.sha256)
        var invalid = committed
        invalid.brief?.takes.removeAll()
        await #expect(throws: (any Error).self) { try await store.save(invalid) }
        invalid = committed
        invalid.brief?.takes[0].audioRevisions?[0].label = "Rewritten original generation"
        await #expect(throws: (any Error).self) { try await store.save(invalid) }
    }

    @Test(arguments: [0, 1, 2])
    func recoveryCompletesEachPartialPublicationBeforeOrphanAdoption(movedFiles: Int) async throws {
        let (root, store, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let edit = try await render(store: store, baseline: baseline)
        try writeJournal(edit, baseline: baseline)
        try await movePublishedFiles(edit, count: movedFiles, store: store)
        let reopened = try SessionStore(root: root)
        let reports = try await reopened.recover()
        let recovered = try #require(try await reopened.loadSessions().first)
        #expect(recovered.brief?.takes[0].activeAudioRevisionID == edit.session.brief?.takes[0].activeAudioRevisionID)
        #expect(recovered.segments == edit.session.segments)
        #expect(recovered.availableSegments.map(\.id) == [edit.segment.id])
        #expect(!FileManager.default.fileExists(atPath: edit.directory.path))
        #expect(reports.contains { $0.contains("Recovered interrupted recording edit") })
        #expect(!reports.contains { $0.contains("durable orphan") })
        _ = try await reopened.recover()
        #expect(try await reopened.loadSessions().first?.segments == recovered.segments)
    }

    @Test func cleanupOfCommittedPublicationPreservesNewerDocumentChanges() async throws {
        let (root, store, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let edit = try await render(store: store, baseline: baseline)
        try writeJournal(edit, baseline: baseline)
        try await movePublishedFiles(edit, count: 2, store: store)
        try await store.save(edit.session) // Crash point: metadata committed, private journal remains.
        var newer = edit.session
        newer.title = "A later title must survive cleanup"
        newer.updatedAt = newer.updatedAt.addingTimeInterval(1)
        try await store.save(newer)
        let reopened = try SessionStore(root: root)
        let reports = try await reopened.recover()
        #expect(try await reopened.loadSessions().first?.title == newer.title)
        #expect(reports.contains { $0.contains("publication cleanup") })
        #expect(!FileManager.default.fileExists(atPath: edit.directory.path))
    }

    @Test func conflictingPublicationQuarantinesOnlyGeneratedAssetsWithoutAdoptingThem() async throws {
        let (root, store, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let edit = try await render(store: store, baseline: baseline)
        try writeJournal(edit, baseline: baseline)
        try await movePublishedFiles(edit, count: 2, store: store)
        var newer = baseline
        newer.title = "Changed while private render was pending"
        newer.updatedAt = newer.updatedAt.addingTimeInterval(2)
        try await store.save(newer)
        let reports = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.title == newer.title && recovered.segments == baseline.segments)
        #expect(!FileManager.default.fileExists(atPath: try await store.audioURL(for: edit.segment, in: baseline.id).path))
        #expect(try SessionStore.checksum(await store.audioURL(for: baseline.segments[0], in: baseline.id)) == baseline.segments[0].sha256)
        let sessionDirectory = try await store.sessionDirectory(baseline.id)
        let quarantines = try FileManager.default.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".recording-conflict-") }
        #expect(quarantines.count == 1)
        #expect(FileManager.default.fileExists(atPath: try #require(quarantines.first).appendingPathComponent(edit.segment.fileName).path))
        #expect(reports.contains { $0.contains("conflicted with newer brief changes") })
        #expect(!reports.contains { $0.contains("durable orphan") })
    }

    @Test func corruptPublicationBlocksOrphanAdoptionAndRetainsAllFiles() async throws {
        let (root, store, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let edit = try await render(store: store, baseline: baseline)
        try Data("incomplete or corrupt journal".utf8).write(to: edit.directory.appendingPathComponent("publication.json"))
        try await movePublishedFiles(edit, count: 2, store: store)
        let reports = try await store.recover()
        #expect(try await store.loadSessions().first?.segments == baseline.segments)
        #expect(FileManager.default.fileExists(atPath: try await store.audioURL(for: edit.segment, in: baseline.id).path))
        #expect(reports.contains { $0.contains("before orphan audio can be adopted") })
    }

    @Test func wholeRecordingCorrectionRetainsMultipleParentsAcrossArchiveAndTrash() async throws {
        let (root, store, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var session = baseline
        let audio = try await store.audioDirectory(session.id)
        let secondSegment = try writeAudio(in: audio, intervalID: session.intervals[0].id, start: session.recordedDuration)
        session.segments.append(secondSegment)
        let first = TranscriptRevision(rawText: "Use 256.", text: "Use 256.", segmentIDs: [session.segments[0].id],
            startTime: 0, endTime: session.segments[0].endTime)
        let second = TranscriptRevision(rawText: "Do not upload.", text: "Do not upload.", segmentIDs: [secondSegment.id],
            startTime: secondSegment.startTime, endTime: secondSegment.endTime)
        let corrected = TranscriptRevision(replacesIDs: [first.id, second.id], rawText: first.rawText + " " + second.rawText,
            text: "Use 256 records and do not upload.", segmentIDs: session.segments.map(\.id),
            startTime: 0, endTime: secondSegment.endTime, timingPrecision: .window)
        session.transcripts = [corrected, second, first]
        session.corrections = [first, second].map {
            CorrectionPatch(originalRevisionID: $0.id, correctedRevisionID: corrected.id, before: $0.text, after: corrected.text)
        }
        session.brief?.takes[0].transcriptIDs = [first.id, second.id, corrected.id]
        #expect(session.currentTranscripts == [corrected])
        #expect(session.transcribedThrough == secondSegment.endTime)
        try await store.save(session)
        let archive = root.appendingPathComponent("Whole-correction.keystorm")
        try SessionTransfer.exportArchive(session: session, audioDirectory: audio, to: archive)
        let imported = try await SessionTransfer.importArchive(from: archive, store: store)
        #expect(imported.currentTranscripts == [corrected])
        #expect(imported.corrections == session.corrections)
        var restored = imported
        restored.brief?.takes[0].trashedAt = Date()
        #expect(restored.currentTranscripts.isEmpty)
        #expect(restored.inactiveTranscriptIDs == Set([first.id, second.id, corrected.id]))
        restored.brief?.takes[0].trashedAt = nil
        #expect(restored.currentTranscripts == [corrected])
        var cyclic = session
        cyclic.transcripts[2].replacesIDs = [corrected.id]
        #expect(throws: (any Error).self) {
            try SessionTransfer.exportArchive(session: cyclic, audioDirectory: audio, to: root.appendingPathComponent("Cycle.keystorm"))
        }
    }

    @Test(arguments: [false, true])
    func legacyRecordingWrappersPersistOnceWithoutInventedResumeGrouping(occupiedTakeID: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Legacy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        let firstInterval = CaptureInterval(endedAt: Date()), secondInterval = CaptureInterval(endedAt: Date())
        session.intervals = [firstInterval, secondInterval]
        let audio = try await store.audioDirectory(session.id)
        session.segments = [try writeAudio(in: audio, intervalID: firstInterval.id, start: 0),
                            try writeAudio(in: audio, intervalID: secondInterval.id, start: 0.05)]
        let transcript = TranscriptRevision(rawText: "Keep all processing local.", text: "Keep all processing local.",
            segmentIDs: [session.segments[0].id], startTime: 0, endTime: 0.05)
        session.transcripts = [transcript]
        let source = SourceReference(transcriptID: transcript.id, startUTF8: 0, endUTF8: transcript.text.utf8.count, quote: transcript.text)
        session.facts = [Fact(kind: .constraint, status: .confirmed, text: transcript.text, sources: [source])]
        if occupiedTakeID {
            var existing = BriefDocument()
            existing.takes = [BriefTake(id: firstInterval.id, expectedRevision: existing.revisionID, status: .dismissed)]
            session.brief = existing
        }
        try await store.save(session)
        let original = session
        let materialized = session.materializeLegacyRecordings()
        #expect(materialized)
        #expect(session.segments == original.segments && session.transcripts == original.transcripts && session.facts == original.facts)
        #expect(session.updatedAt == original.updatedAt)
        let first = try #require(session.brief?.takes.first { $0.intervalID == firstInterval.id })
        let second = try #require(session.brief?.takes.first { $0.intervalID == secondInterval.id })
        #expect(first.id == firstInterval.id ? !occupiedTakeID : occupiedTakeID)
        #expect(second.id == secondInterval.id)
        #expect(first.captureIntervalIDs == [firstInterval.id] && second.captureIntervalIDs == [secondInterval.id])
        #expect(first.status == (occupiedTakeID ? .pending : .applied))
        #expect(second.status == .pending)
        try await store.save(session)
        let reopened = try SessionStore(root: root)
        var persisted = try #require(try await reopened.loadSessions().first)
        let materializedAgain = persisted.materializeLegacyRecordings()
        #expect(!materializedAgain)
        #expect(persisted.brief?.takes.map(\.id) == session.brief?.takes.map(\.id))
        #expect(persisted.segments == original.segments && persisted.transcripts == original.transcripts)
    }

    @Test func restartPreservesPausedRecordingIdentityAndTrash() async throws {
        let (root, store, baseline) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var recording = baseline
        recording.status = .recording
        recording.brief?.takes[0].status = .recording
        recording.brief?.takes[0].name = "One logical recording"
        try await store.save(recording)
        _ = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.brief?.takes[0].id == baseline.brief?.takes[0].id)
        #expect(recovered.brief?.takes[0].status == .paused)
        #expect(recovered.brief?.takes[0].name == "One logical recording")
    }

    private struct EditFixture {
        var session: VoiceSession
        var directory: URL
        var segment: AudioSegment
    }
    private struct PublicationFixture: Encodable {
        var version = 1
        var expectedRevision: Int64 = 1
        var expectedUpdatedAt: Date
        var nextSession: VoiceSession
        var newSegmentIDs: [UUID]
    }
    private func fixture() async throws -> (URL, SessionStore, VoiceSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Lifecycle-" + UUID().uuidString)
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.status = .paused
        let interval = CaptureInterval(endedAt: Date())
        session.intervals = [interval]
        let audio = try await store.audioDirectory(session.id)
        session.segments = [try writeAudio(in: audio, intervalID: interval.id, start: 0)]
        var brief = BriefDocument()
        brief.takes = [BriefTake(intervalID: interval.id, expectedRevision: brief.revisionID, status: .applied)]
        session.brief = brief
        try await store.save(session)
        return (root, store, session)
    }
    private func render(store: SessionStore, baseline: VoiceSession) async throws -> EditFixture {
        let directory = try await store.sessionDirectory(baseline.id).appendingPathComponent(".recording-edit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let interval = CaptureInterval(endedAt: Date())
        let segment = try writeAudio(in: directory, intervalID: interval.id, start: baseline.recordedDuration)
        var next = baseline
        next.updatedAt = baseline.updatedAt.addingTimeInterval(1)
        next.intervals.append(interval)
        next.segments.append(segment)
        let revision = RecordingAudioRevision(label: "Trimmed recording", intervalIDs: [interval.id])
        next.brief?.takes[0].audioRevisions = [revision]
        next.brief?.takes[0].activeAudioRevisionID = revision.id
        next.brief?.reviewedRevisionID = nil
        return EditFixture(session: next, directory: directory, segment: segment)
    }
    private func writeAudio(in directory: URL, intervalID: UUID, start: Double) throws -> AudioSegment {
        let id = UUID(), frames: AVAudioFrameCount = 800
        let url = directory.appendingPathComponent(id.uuidString + ".caf")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData?[0].initialize(repeating: 0.125, count: Int(frames))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        let segment = AudioSegment(id: id, intervalID: intervalID, fileName: url.lastPathComponent, startTime: start,
            frameCount: Int64(frames), sampleRate: 16_000, channelCount: 1, sha256: try SessionStore.checksum(url))
        try JSONEncoder().encode(segment).write(to: directory.appendingPathComponent(id.uuidString + ".json"))
        return segment
    }
    private func writeJournal(_ edit: EditFixture, baseline: VoiceSession) throws {
        let journal = PublicationFixture(expectedUpdatedAt: baseline.updatedAt, nextSession: edit.session, newSegmentIDs: [edit.segment.id])
        try JSONEncoder().encode(journal).write(to: edit.directory.appendingPathComponent("publication.json"), options: .atomic)
    }
    private func movePublishedFiles(_ edit: EditFixture, count: Int, store: SessionStore) async throws {
        let audio = try await store.audioDirectory(edit.session.id)
        let names = [edit.segment.fileName, edit.segment.id.uuidString + ".json"]
        for name in names.prefix(count) {
            try FileManager.default.moveItem(at: edit.directory.appendingPathComponent(name), to: audio.appendingPathComponent(name))
        }
    }
}
