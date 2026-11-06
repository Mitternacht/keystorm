import AVFoundation
import Foundation
import SQLite3
import Testing
@testable import Keystorm

/// Accelerated storage fixtures exercise real tiny CAF files and the production
/// catalog. They do not qualify eight hours of microphone capture or device thermals.
struct SessionStoreIncrementalTests {

    @Test("Progressive capture and transcription replay across pages without rewriting full checkpoints")
    func mixedProgressiveReplay() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session()
        try await store.save(session)
        let snapshotURL = try await store.sessionDirectory(session.id).appendingPathComponent("session.json")
        let checkpoint = try Data(contentsOf: snapshotURL)
        let catalogPayload = try fixture.blob("SELECT payload FROM sessions")
        for index in 0..<45 {
            let audio = try await fixture.audio(store: store, session: session, start: Double(index) * 0.01)
            session = try await store.appendCapturedSegments(sessionID: session.id, segments: [audio],
                updatedAt: session.updatedAt.addingTimeInterval(1))
            session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
                inputIDs: [audio.id], totalUnits: 1))
            session.updatedAt = session.updatedAt.addingTimeInterval(1)
            try await store.saveTranscriptionUpdate(session)
            finishTranscript(&session, audio: audio, text: "Recorded passage \(index).")
            try await store.saveTranscriptionUpdate(session)
        }
        #expect(try Data(contentsOf: snapshotURL) == checkpoint)
        #expect(try fixture.blob("SELECT payload FROM sessions") == catalogPayload)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 135)
        let reopened = try SessionStore(root: fixture.root)
        #expect(try await reopened.loadSession(session.id) == session)
        session.status = .paused
        session.intervals[0].endedAt = Date()
        try await reopened.save(session)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 0)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == session)
    }

    @Test("A transcription retry is idempotent and preserves its running job after reopening")
    func transcriptionRetry() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session()
        try await store.save(session)
        let audio = try await fixture.audio(store: store, session: session)
        session = try await store.appendCapturedSegments(sessionID: session.id, segments: [audio], updatedAt: Date())
        session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [audio.id], totalUnits: 1))
        session.updatedAt = Date()
        try await store.saveTranscriptionUpdate(session)
        try await store.saveTranscriptionUpdate(session)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 2)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == session)
        finishTranscript(&session, audio: audio, text: "Preserve the original words.")
        try await store.saveTranscriptionUpdate(session)
        try await store.saveTranscriptionUpdate(session)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 3)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == session)
    }

    @Test("Incremental transcription rejects changed original text, unrelated metadata and foreign sources",
          arguments: ["source", "title", "original", "unicode", "foreign"])
    func transcriptionCannotRewriteAuthority(kind: String) async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session()
        try await store.save(session)
        let audio = try await fixture.audio(store: store, session: session)
        session = try await store.appendCapturedSegments(sessionID: session.id, segments: [audio], updatedAt: Date())
        session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [audio.id], totalUnits: 1))
        try await store.saveTranscriptionUpdate(session)
        finishTranscript(&session, audio: audio, text: "Never discard this café source.")
        try await store.saveTranscriptionUpdate(session)
        let original = session
        session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [kind == "foreign" ? UUID() : audio.id], totalUnits: 1))
        if kind == "source" { session.segments[0].sha256 = String(repeating: "a", count: 64) }
        if kind == "title" { session.title = "An unrelated edit" }
        if kind == "original" { session.transcripts[0].rawText = "Rewritten original" }
        if kind == "unicode" { session.transcripts[0].rawText = "Never discard this cafe\u{301} source." }
        await #expect(throws: (any Error).self) { try await store.saveTranscriptionUpdate(session) }
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == original)
    }

    @Test("A newer full checkpoint rejects stale transcription without discarding the newer title")
    func transcriptionCacheSeesNewCheckpoint() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session()
        try await store.save(session)
        let audio = try await fixture.audio(store: store, session: session)
        session = try await store.appendCapturedSegments(sessionID: session.id, segments: [audio], updatedAt: Date())
        session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [audio.id], totalUnits: 1))
        try await store.saveTranscriptionUpdate(session)
        let second = try SessionStore(root: fixture.root)
        var changed = session
        changed.title = "Renamed from another catalog connection"
        changed.updatedAt = Date()
        try await second.save(changed)
        finishTranscript(&session, audio: audio, text: "A stale result")
        await #expect(throws: (any Error).self) { try await store.saveTranscriptionUpdate(session) }
        #expect(try await second.loadSession(session.id) == changed)
        finishTranscript(&changed, audio: audio, text: "A fresh result")
        try await store.saveTranscriptionUpdate(changed)
        #expect(try await second.loadSession(session.id) == changed)
    }

    @Test("A damaged or deleted acknowledged transcription tail is never silently ignored",
          arguments: ["checksum", "middle", "final"])
    func damagedTranscriptionTail(kind: String) async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session()
        try await store.save(session)
        let audio = try await fixture.audio(store: store, session: session)
        session = try await store.appendCapturedSegments(sessionID: session.id, segments: [audio], updatedAt: Date())
        session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [audio.id], totalUnits: 1))
        try await store.saveTranscriptionUpdate(session)
        finishTranscript(&session, audio: audio, text: "Acknowledged words must survive.")
        try await store.saveTranscriptionUpdate(session)
        if kind == "checksum" { try fixture.sql("UPDATE session_capture_journal SET sha256='damaged' WHERE revision=4") }
        if kind == "middle" { try fixture.sql("DELETE FROM session_capture_journal WHERE revision=3") }
        if kind == "final" { try fixture.sql("DELETE FROM session_capture_journal WHERE revision=4") }
        let reopened = try SessionStore(root: fixture.root)
        await #expect(throws: (any Error).self) { try await reopened.loadSession(session.id) }
        #expect(FileManager.default.fileExists(atPath: try await store.audioURL(for: audio, in: session.id).path))
    }

    @Test("An oversized valid transcription update uses a full checkpoint and remains recoverable")
    func oversizedTranscriptionCheckpoint() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session()
        try await store.save(session)
        let audio = try await fixture.audio(store: store, session: session)
        session = try await store.appendCapturedSegments(sessionID: session.id, segments: [audio], updatedAt: Date())
        session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [audio.id], totalUnits: 1))
        try await store.saveTranscriptionUpdate(session)
        finishTranscript(&session, audio: audio, text: String(repeating: "word ", count: 30_000))
        try await store.saveTranscriptionUpdate(session)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 0)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == session)
    }


    @Test("Transcription deltas preserve take ownership and approved correction chains after restart")
    func transcriptionBriefCorrectionReplay() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session()
        var brief = BriefDocument()
        brief.takes = [BriefTake(intervalID: session.intervals[0].id, expectedRevision: brief.revisionID, status: .recording)]
        brief.reviewedRevisionID = brief.revisionID
        session.brief = brief
        try await store.save(session)
        let audio = try await fixture.audio(store: store, session: session)
        session = try await store.appendCapturedSegments(sessionID: session.id, segments: [audio], updatedAt: Date())
        session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [audio.id], totalUnits: 1))
        try await store.saveTranscriptionUpdate(session)
        let original = TranscriptRevision(rawText: "Use key storm.", text: "Use key storm.",
            segmentIDs: [audio.id], startTime: audio.startTime, endTime: audio.endTime)
        var corrected = original
        corrected.id = UUID()
        corrected.replacesID = original.id
        corrected.text = "Use Keystorm."
        session.transcripts.append(contentsOf: [original, corrected])
        session.corrections.append(CorrectionPatch(originalRevisionID: original.id,
            correctedRevisionID: corrected.id, before: original.text, after: corrected.text))
        session.jobs[0].status = .completed
        session.jobs[0].completedUnits = 1
        session.brief?.takes[0].transcriptIDs.append(corrected.id)
        session.brief?.reviewedRevisionID = nil
        session.invalidateDerivedWork()
        try await store.saveTranscriptionUpdate(session)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == session)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 3)
    }


    @Test("Paired progressive storage benchmark compares checkpoints with transcription deltas",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_RESIDENCY"] == "1"),
          .timeLimit(.minutes(5)))
    func pairedTranscriptionPersistenceBenchmark() async throws {
        let fullFixture = try IncrementalStoreFixture()
        let deltaFixture = try IncrementalStoreFixture()
        defer { fullFixture.remove(); deltaFixture.remove() }
        let full = try SessionStore(root: fullFixture.root)
        let incremental = try SessionStore(root: deltaFixture.root)
        var session = fullFixture.session()
        try await full.save(session)
        try await incremental.save(session)
        let audio = try await fullFixture.audio(store: full, session: session)
        let sourceDirectory = try await full.audioDirectory(session.id)
        let destinationDirectory = try await incremental.audioDirectory(session.id)
        for name in [audio.fileName, audio.id.uuidString + ".json"] {
            try FileManager.default.copyItem(at: sourceDirectory.appendingPathComponent(name),
                to: destinationDirectory.appendingPathComponent(name))
        }
        session.segments = [audio]
        try await full.save(session)
        try await incremental.save(session)
        let fullURL = try await full.sessionDirectory(session.id).appendingPathComponent("session.json")
        let deltaURL = try await incremental.sessionDirectory(session.id).appendingPathComponent("session.json")
        let checkpoint = try Data(contentsOf: deltaURL)
        let catalog = try deltaFixture.blob("SELECT payload FROM sessions")
        var fullMilliseconds: [Double] = []
        var deltaMilliseconds: [Double] = []
        var fullMetadataBytes = 0

        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let value = start.duration(to: .now).components
            return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
        }
        // Both stores receive the same 200 snapshots. Alternating order limits
        // consistent first-run bias; source creation and result validation are untimed.
        for index in 0..<100 {
            session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
                inputIDs: [audio.id], totalUnits: 1))
            session.updatedAt = Date()
            for phase in 0..<2 {
                if phase == 1 {
                    finishTranscript(&session, audio: audio,
                        text: "Passage \(index). " + String(repeating: "Keep the saved source and measured result. ", count: 5))
                }
                if index.isMultiple(of: 2) {
                    let fullStart = ContinuousClock.now
                    try await full.save(session)
                    fullMilliseconds.append(milliseconds(fullStart))
                    let deltaStart = ContinuousClock.now
                    try await incremental.saveTranscriptionUpdate(session)
                    deltaMilliseconds.append(milliseconds(deltaStart))
                } else {
                    let deltaStart = ContinuousClock.now
                    try await incremental.saveTranscriptionUpdate(session)
                    deltaMilliseconds.append(milliseconds(deltaStart))
                    let fullStart = ContinuousClock.now
                    try await full.save(session)
                    fullMilliseconds.append(milliseconds(fullStart))
                }
                fullMetadataBytes += try Data(contentsOf: fullURL).count
                fullMetadataBytes += try fullFixture.blob("SELECT payload FROM sessions").count
            }
        }
        let deltaMetadataBytes = try deltaFixture.integer("SELECT SUM(length(payload)) FROM session_capture_journal")
        #expect(try Data(contentsOf: deltaURL) == checkpoint)
        #expect(try deltaFixture.blob("SELECT payload FROM sessions") == catalog)
        #expect(deltaMetadataBytes < Int64(fullMetadataBytes))
        #expect(try await SessionStore(root: fullFixture.root).loadSession(session.id) == session)
        #expect(try await SessionStore(root: deltaFixture.root).loadSession(session.id) == session)
        func mean(_ values: ArraySlice<Double>) -> Double {
            values.reduce(0, +) / Double(values.count)
        }
        let report: [String: String] = [
            "updatesPerStore": "200",
            "fullTotalMilliseconds": String(fullMilliseconds.reduce(0, +)),
            "incrementalTotalMilliseconds": String(deltaMilliseconds.reduce(0, +)),
            "fullFirst50MeanMilliseconds": String(mean(fullMilliseconds.prefix(50))),
            "fullLast50MeanMilliseconds": String(mean(fullMilliseconds.suffix(50))),
            "incrementalFirst50MeanMilliseconds": String(mean(deltaMilliseconds.prefix(50))),
            "incrementalLast50MeanMilliseconds": String(mean(deltaMilliseconds.suffix(50))),
            "fullEncodedMetadataBytes": String(fullMetadataBytes),
            "incrementalEncodedMetadataBytes": String(deltaMetadataBytes),
            "exactReopen": "true",
            "limitations": "Paired synthetic storage-only snapshots on fresh stores. Alternating call order; no microphone or inference. Bytes count encoded snapshot/catalog/journal payloads, not physical SSD writes or SQLite WAL amplification. Timing is observational and not a machine-independent speed assertion."
        ]
        let data = try JSONEncoder().encode(report)
        Attachment.record(data, named: "storage-persistence-benchmark.json")
        print("STORAGE_PERSISTENCE_BENCHMARK " + String(decoding: data, as: UTF8.self))
    }


    @MainActor
    @Test("A failed incremental job save can retry through the workspace without losing pending work")
    func workspaceRetriesFailedTranscriptionSave() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session()
        session.status = .paused
        session.intervals[0].endedAt = Date()
        try await store.save(session)
        let audio = try await fixture.audio(store: store, session: session)
        session.segments = [audio]
        try await store.save(session)
        let workspace = WorkspaceModel(root: fixture.root)
        await workspace.initialize(loadLibrary: true)
        try #require(workspace.error == nil)
        let first = ProcessingJob(stage: .transcription, status: .running, inputIDs: [audio.id], totalUnits: 1)
        try fixture.sql("""
            CREATE TRIGGER fail_transcription BEFORE INSERT ON session_capture_journal
            BEGIN SELECT RAISE(ABORT, 'Injected transcription write failure'); END;
            """)
        await #expect(throws: (any Error).self) {
            try await workspace.recordTranscriptionJob(first, sessionID: session.id)
        }
        #expect(try await store.loadSession(session.id)?.jobs.isEmpty == true)
        try fixture.sql("DROP TRIGGER fail_transcription")
        let retry = ProcessingJob(stage: .transcription, status: .running, inputIDs: [audio.id], totalUnits: 1)
        try await workspace.recordTranscriptionJob(retry, sessionID: session.id)
        #expect(try await store.loadSession(session.id)?.jobs == [first, retry])
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 0)
        let next = ProcessingJob(stage: .transcription, status: .running, inputIDs: [audio.id], totalUnits: 1)
        try await workspace.recordTranscriptionJob(next, sessionID: session.id)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id)?.jobs == [first, retry, next])
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 1)
        await workspace.stopForTermination()
    }

    private func finishTranscript(_ session: inout VoiceSession, audio: AudioSegment, text: String) {
        session.transcripts.append(TranscriptRevision(rawText: text, text: text,
            segmentIDs: [audio.id], startTime: audio.startTime, endTime: audio.endTime))
        session.jobs[session.jobs.count - 1].status = .completed
        session.jobs[session.jobs.count - 1].completedUnits = 1
        session.invalidateDerivedWork()
    }

    @Test("Legacy catalog migration preserves checkpoint payload and reopens at schema 5")
    func legacyMigration() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let session = fixture.session()
        let payload = try JSONEncoder().encode(session)
        try fixture.sql("""
            CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
            PRAGMA user_version=1;
            """)
        try fixture.storePayload(payload, sessionID: session.id, revision: 1)
        let store = try SessionStore(root: fixture.root)
        #expect(try fixture.integer("PRAGMA user_version") == 5)
        #expect(try fixture.blob("SELECT payload FROM sessions") == payload)
        #expect(try await store.loadSessions() == [session])
        let reopened = try SessionStore(root: fixture.root)
        #expect(try await reopened.loadSessions() == [session])
    }

    @Test("Capture appends replay beyond one bounded page without rewriting full checkpoints")
    func pagedReplayAndCheckpoint() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let original = fixture.session()
        try await store.save(original)
        let snapshotURL = try await store.sessionDirectory(original.id).appendingPathComponent("session.json")
        let originalSnapshot = try Data(contentsOf: snapshotURL)
        let originalPayload = try fixture.blob("SELECT payload FROM sessions")
        var expected = original
        for index in 0..<130 {
            let segment = try await fixture.audio(store: store, session: original, start: Double(index) * 0.01)
            expected = try await store.appendCapturedSegments(sessionID: original.id, segments: [segment],
                updatedAt: original.updatedAt.addingTimeInterval(Double(index + 1)))
        }
        #expect(expected.segments.count == 130)
        #expect(try Data(contentsOf: snapshotURL) == originalSnapshot)
        #expect(try fixture.blob("SELECT payload FROM sessions") == originalPayload)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 130)
        let reopened = try SessionStore(root: fixture.root)
        #expect(try await reopened.loadSessions() == [expected])
        expected.title = "Checkpoint after capture"
        expected.status = .paused
        expected.intervals[0].endedAt = Date()
        expected.updatedAt = expected.updatedAt.addingTimeInterval(1)
        try await reopened.save(expected)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 0)
        #expect(try fixture.integer("SELECT revision FROM sessions") == 132)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_sources") == 130)
        let afterCheckpoint = try SessionStore(root: fixture.root)
        #expect(try await afterCheckpoint.loadSessions() == [expected])
    }

    @Test("Capture retries are idempotent and changed source identities are rejected")
    func retryAndConflict() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        let segment = try await fixture.audio(store: store, session: session)
        let first = try await store.appendCapturedSegments(sessionID: session.id, segments: [segment], updatedAt: Date())
        let retried = try await store.appendCapturedSegments(sessionID: session.id, segments: [segment], updatedAt: Date())
        #expect(retried == first)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 1)
        var changed = segment
        changed.startTime = 1
        await #expect(throws: (any Error).self) {
            try await store.appendCapturedSegments(sessionID: session.id, segments: [changed], updatedAt: Date())
        }
        await #expect(throws: (any Error).self) { try await store.save(session) }
        #expect(try await store.loadSessions() == [first])
    }

    @Test("Only durable matching audio and owned capture intervals can be acknowledged",
          arguments: ["missing", "sidecar", "foreign", "overlap"])
    func invalidCapture(kind: String) async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        var segment = try await fixture.audio(store: store, session: session)
        let directory = try await store.audioDirectory(session.id)
        if kind == "missing" { try FileManager.default.removeItem(at: directory.appendingPathComponent(segment.fileName)) }
        if kind == "sidecar" {
            var other = segment
            other.intervalID = UUID()
            try JSONEncoder().encode(other).write(to: directory.appendingPathComponent(segment.id.uuidString + ".json"))
        }
        if kind == "foreign" { segment.intervalID = UUID() }
        if kind == "overlap" {
            _ = try await store.appendCapturedSegments(sessionID: session.id, segments: [segment], updatedAt: Date())
            segment = try await fixture.audio(store: store, session: session, start: 0)
        }
        await #expect(throws: (any Error).self) {
            try await store.appendCapturedSegments(sessionID: session.id, segments: [segment], updatedAt: Date())
        }
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == (kind == "overlap" ? 1 : 0))
    }

    @Test("A newer checkpoint invalidates the capture cache without overwriting unrelated metadata")
    func cacheObservesNewCheckpoint() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        let first = try await fixture.audio(store: store, session: session)
        var updated = try await store.appendCapturedSegments(sessionID: session.id, segments: [first], updatedAt: Date())
        let other = try SessionStore(root: fixture.root)
        updated.title = "Metadata changed through the same catalog"
        updated.updatedAt = Date()
        try await other.save(updated)
        let second = try await fixture.audio(store: store, session: session, start: 0.01)
        let appended = try await store.appendCapturedSegments(sessionID: session.id, segments: [second], updatedAt: Date())
        #expect(appended.title == updated.title)
        #expect(appended.segments == [first, second])
        #expect(try await other.loadSessions() == [appended])
    }

    @Test("Corrupt, missing middle, and deleted final acknowledged tails fail closed",
          arguments: ["checksum", "middle", "final"])
    func corruptTail(kind: String) async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        for index in 0..<3 {
            let segment = try await fixture.audio(store: store, session: session, start: Double(index) * 0.01)
            _ = try await store.appendCapturedSegments(sessionID: session.id, segments: [segment], updatedAt: Date())
        }
        if kind == "checksum" { try fixture.sql("UPDATE session_capture_journal SET sha256='invalid' WHERE revision=3") }
        if kind == "middle" { try fixture.sql("DELETE FROM session_capture_journal WHERE revision=3") }
        if kind == "final" { try fixture.sql("DELETE FROM session_capture_journal WHERE revision=4") }
        let reopened = try SessionStore(root: fixture.root)
        await #expect(throws: (any Error).self) { try await reopened.loadSessions() }
        await #expect(throws: (any Error).self) { try await store.loadSessions() }
        #expect(try fixture.integer("SELECT revision FROM session_history_headers") == 4)
        let audio = try await store.audioDirectory(session.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: audio.path).filter { $0.hasSuffix(".caf") }.count == 3)
    }

    @Test("A missing acknowledged audio file remains referenced and becomes an explicit recovery gap")
    func missingAudioAfterAcknowledgment() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        let segment = try await fixture.audio(store: store, session: session)
        _ = try await store.appendCapturedSegments(sessionID: session.id, segments: [segment], updatedAt: Date())
        let audioURL = try await store.audioURL(for: segment, in: session.id)
        try FileManager.default.removeItem(at: audioURL)
        let reopened = try SessionStore(root: fixture.root)
        #expect(try await reopened.loadSessions().first?.segments == [segment])
        let report = try await reopened.recover()
        let restored = try #require(try await reopened.loadSessions().first)
        #expect(restored.segments == [segment])
        #expect(restored.unavailableSegmentIDs.contains(segment.id))
        #expect(report.contains { $0.contains("unavailable") })
        #expect(!restored.gaps.isEmpty)
    }

    @Test("Newer synchronized checkpoints cover old tails and restore an interrupted SQL checkpoint")
    func snapshotAheadOfCatalog() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        let segment = try await fixture.audio(store: store, session: session)
        var latest = try await store.appendCapturedSegments(sessionID: session.id, segments: [segment], updatedAt: Date())
        latest.title = "Synchronized before SQL commit"
        let snapshotURL = try await store.sessionDirectory(session.id).appendingPathComponent("session.json")
        try JSONEncoder().encode(Checkpoint(revision: 3, session: latest)).write(to: snapshotURL, options: .atomic)
        // The old covered tail is damaged; its newer full checkpoint is the authority.
        try fixture.sql("UPDATE session_capture_journal SET sha256='covered-invalid'")
        let second = try await fixture.audio(store: store, session: latest, start: 0.01)
        let result = try await store.appendCapturedSegments(sessionID: session.id, segments: [second], updatedAt: Date())
        #expect(result.title == latest.title)
        #expect(result.segments == [segment, second])
        #expect(try fixture.integer("SELECT revision FROM sessions") == 3)
        #expect(try fixture.integer("SELECT MIN(revision) FROM session_capture_journal") == 4)
        let reopened = try SessionStore(root: fixture.root)
        #expect(try await reopened.loadSessions() == [result])
    }

    @Test("Equal revision checkpoint conflicts cannot silently select either payload")
    func equalRevisionConflict() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session()
        try await store.save(session)
        session.title = "Conflicting same revision"
        let snapshotURL = try await store.sessionDirectory(session.id).appendingPathComponent("session.json")
        try JSONEncoder().encode(Checkpoint(revision: 1, session: session)).write(to: snapshotURL, options: .atomic)
        await #expect(throws: (any Error).self) { try await store.loadSessions() }
        await #expect(throws: (any Error).self) { try await store.save(session) }
    }

    @Test("A corrupt catalog payload can recover its synchronized checkpoint and durable capture tail")
    func corruptCatalogFallback() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        let segment = try await fixture.audio(store: store, session: session)
        let expected = try await store.appendCapturedSegments(sessionID: session.id, segments: [segment], updatedAt: Date())
        try fixture.sql("UPDATE sessions SET payload=X'00'")
        let reopened = try SessionStore(root: fixture.root)
        #expect(try await reopened.loadSessions() == [expected])
    }


    @Test("Incremental metadata stays checkpointable at the aggregate limit and reserves Pause bookkeeping",
          .timeLimit(.minutes(5)))
    func aggregateMetadataCapacity() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session()
        let first = try await fixture.audio(store: store, session: session)
        session.segments = [first]
        let emptyBytes = try JSONEncoder().encode(Checkpoint(revision: 1, session: session)).count
        session.taskDescription = String(repeating: "x",
            count: SessionStore.maximumIncrementalMetadataBytes - emptyBytes - 8_000)
        try await store.save(session)
        session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [first.id], totalUnits: 1))
        session.updatedAt = session.updatedAt.addingTimeInterval(1)
        try await store.saveTranscriptionUpdate(session)
        finishTranscript(&session, audio: first, text: "These accepted words remain recoverable.")
        try await store.saveTranscriptionUpdate(session)
        let second = try await fixture.audio(store: store, session: session, start: 0.01)
        session = try await store.appendCapturedSegments(sessionID: session.id,
            segments: [second], updatedAt: session.updatedAt.addingTimeInterval(1))
        session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [second.id], totalUnits: 1))
        session.updatedAt = session.updatedAt.addingTimeInterval(1)
        try await store.saveTranscriptionUpdate(session)
        let acceptedRevision = try fixture.integer("SELECT revision FROM session_history_headers")
        var rejected = session
        finishTranscript(&rejected, audio: second, text: String(repeating: "y", count: 12_000))
        // Each output fits the 128KiB delta bound, but the full recoverable session
        // would exceed its aggregate bound. The transaction must not acknowledge it.
        await #expect(throws: (any Error).self) { try await store.saveTranscriptionUpdate(rejected) }
        #expect(try fixture.integer("SELECT revision FROM session_history_headers") == acceptedRevision)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == session)

        // A legitimate full metadata save can approach the incremental limit.
        // The next capture must reject before publishing its source/header.
        let currentBytes = try JSONEncoder().encode(Checkpoint(revision: acceptedRevision + 1, session: session)).count
        session.taskDescription += String(repeating: "z",
            count: SessionStore.maximumIncrementalMetadataBytes - currentBytes - 10)
        try await store.save(session)
        // The conservative charge exceeds ten spare bytes, but this replacement
        // actually shrinks the job. Exact rebasing must admit it.
        session.jobs[session.jobs.count - 1].status = .failed
        try await store.saveTranscriptionUpdate(session)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == session)
        let third = try await fixture.audio(store: store, session: session, start: 0.02)
        let captureRevision = try fixture.integer("SELECT revision FROM session_history_headers")
        await #expect(throws: (any Error).self) {
            try await store.appendCapturedSegments(sessionID: session.id,
                segments: [third], updatedAt: session.updatedAt.addingTimeInterval(1))
        }
        #expect(try fixture.integer("SELECT revision FROM session_history_headers") == captureRevision)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_sources") == 2)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == session)
        session.status = .paused
        session.intervals[0].endedAt = Date()
        session.jobs[session.jobs.count - 1].status = .failed
        session.updatedAt = Date()
        try await store.save(session)
        let snapshotURL = try await store.sessionDirectory(session.id).appendingPathComponent("session.json")
        #expect(try Data(contentsOf: snapshotURL).count <= SessionStore.maximumSnapshotBytes)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 0)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == session)
    }


    @Test("Many open intervals reserve enough aggregate metadata for ordinary Pause",
          .timeLimit(.minutes(5)))
    func metadataCapacityReservesEveryOpenInterval() async throws {
        let fixture = try IncrementalStoreFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session()
        session.intervals = (0..<200).map { _ in CaptureInterval(sampleRate: 16_000, channelCount: 1) }
        let audio = try await fixture.audio(store: store, session: session)
        session.segments = [audio]
        let emptyBytes = try JSONEncoder().encode(Checkpoint(revision: 1, session: session)).count
        session.taskDescription = String(repeating: "x",
            count: SessionStore.maximumIncrementalMetadataBytes - emptyBytes - 1_000)
        try await store.save(session)
        var rejected = session
        rejected.jobs.append(ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [audio.id], totalUnits: 1))
        await #expect(throws: SessionMetadataCapacityError.incrementalLimitReached) {
            try await store.saveTranscriptionUpdate(rejected)
        }
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == 0)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == session)

        let safeLimit = SessionStore.incrementalMetadataLimit(for: session)
        #expect(safeLimit < SessionStore.maximumIncrementalMetadataBytes)
        let currentBytes = try JSONEncoder().encode(Checkpoint(revision: 2, session: session)).count
        session.taskDescription.removeLast(currentBytes - (safeLimit - 2_000))
        try await store.save(session)
        session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
            inputIDs: [audio.id], totalUnits: 1))
        try await store.saveTranscriptionUpdate(session)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == session)
        session.status = .paused
        for index in session.intervals.indices {
            session.intervals[index].endedAt = Date()
            session.intervals[index].hostTime = UInt64.max
        }
        session.updatedAt = Date()
        try await store.save(session)
        let url = try await store.sessionDirectory(session.id).appendingPathComponent("session.json")
        #expect(try Data(contentsOf: url).count <= SessionStore.maximumSnapshotBytes)
        #expect(try await SessionStore(root: fixture.root).loadSession(session.id) == session)
    }

    private struct Checkpoint: Codable {
        var version = 1
        var revision: Int64
        var session: VoiceSession
    }
}

private struct IncrementalStoreFixture {
    let root: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-IncrementalStore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func session() -> VoiceSession {
        var result = VoiceSession()
        result.title = "Capture journal fixture"
        result.status = .recording
        result.intervals = [CaptureInterval(sampleRate: 16_000, channelCount: 1)]
        return result
    }

    func audio(store: SessionStore, session: VoiceSession, start: Double = 0) async throws -> AudioSegment {
        let id = UUID()
        let directory = try await store.audioDirectory(session.id)
        let url = directory.appendingPathComponent(id.uuidString + ".caf")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 160)
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        try audio.write(from: buffer)
        audio.close()
        let segment = AudioSegment(id: id, intervalID: session.intervals[0].id, fileName: url.lastPathComponent,
            startTime: start, frameCount: 160, sampleRate: 16_000, channelCount: 1,
            sha256: try SessionStore.checksum(url))
        try JSONEncoder().encode(segment).write(to: directory.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
        return segment
    }

    func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite").path, &database,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw KeystormError.message("Cannot open test catalog.") }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        return try body(database)
    }

    func sql(_ value: String) throws {
        try withConnection { database in
            guard sqlite3_exec(database, value, nil, nil, nil) == SQLITE_OK else {
                throw KeystormError.message(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    func integer(_ sql: String) throws -> Int64 {
        try withConnection { database in
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK, let query else {
                throw KeystormError.message("Cannot prepare test query.")
            }
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { throw KeystormError.message("Missing test row.") }
            return sqlite3_column_int64(query, 0)
        }
    }

    func blob(_ sql: String) throws -> Data {
        try withConnection { database in
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK, let query else {
                throw KeystormError.message("Cannot prepare test query.")
            }
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else {
                throw KeystormError.message("Missing test payload.")
            }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
        }
    }

    func storePayload(_ data: Data, sessionID: UUID, revision: Int64) throws {
        try withConnection { database in
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO sessions(id,revision,payload) VALUES(?,?,?)",
                                     -1, &query, nil) == SQLITE_OK, let query else {
                throw KeystormError.message("Cannot prepare test checkpoint.")
            }
            defer { sqlite3_finalize(query) }
            guard sqlite3_bind_text(query, 1, sessionID.uuidString, -1, transient) == SQLITE_OK,
                  sqlite3_bind_int64(query, 2, revision) == SQLITE_OK,
                  data.withUnsafeBytes({ sqlite3_bind_blob(query, 3, $0.baseAddress, Int32($0.count), transient) }) == SQLITE_OK,
                  sqlite3_step(query) == SQLITE_DONE else {
                throw KeystormError.message("Cannot seed test checkpoint.")
            }
        }
    }
}
