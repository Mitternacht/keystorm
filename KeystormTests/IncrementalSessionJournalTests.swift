import Foundation
import SQLite3
import Testing
@testable import Keystorm

struct IncrementalSessionJournalTests {
    @Test("Version 1 checkpoints migrate atomically without rewriting original session payloads")
    func legacyMigrationPreservesPayload() throws {
        let fixture = try JournalFixture()
        var session = fixtureSession()
        session.segments = [segment(intervalID: session.intervals[0].id, start: 0)]
        try fixture.seed(session)
        let original = try fixture.data("SELECT payload FROM sessions")
        let journal = IncrementalSessionJournal(connection: fixture.connection)
        try journal.migrate()
        try journal.migrate()
        #expect(try fixture.integer("PRAGMA user_version") == 2)
        #expect(try fixture.data("SELECT payload FROM sessions") == original)
        #expect(try JSONDecoder().decode(VoiceSession.self, from: original) == session)
        let header = try #require(try journal.history().first)
        #expect(header.id == session.id && header.revision == 1)
        #expect(header.segmentCount == 1 && header.recordedDuration == 5)
        #expect(try journal.deltas(sessionID: session.id, afterRevision: 1).isEmpty)
    }

    @Test("A corrupt legacy catalog payload remains available to synchronized snapshot recovery")
    func corruptLegacyRowDoesNotBlockSnapshotRecovery() throws {
        let fixture = try JournalFixture()
        let session = fixtureSession()
        try fixture.seed(session)
        try fixture.execute("UPDATE sessions SET payload=X'00'")
        let original = try fixture.data("SELECT payload FROM sessions")
        let journal = IncrementalSessionJournal(connection: fixture.connection)
        try journal.migrate()
        #expect(try fixture.data("SELECT payload FROM sessions") == original)
        #expect(try journal.history().isEmpty)
        try fixture.checkpoint(session, revision: 2, journal: journal)
        #expect(try journal.history().first?.id == session.id)
    }

    @Test("Interrupted schema migration rolls back the version, index and all backfilled rows")
    func migrationRollback() throws {
        let fixture = try JournalFixture()
        let session = fixtureSession()
        try fixture.seed(session)
        let journal = IncrementalSessionJournal(connection: fixture.connection) { point in
            if case .migrationBeforeCommit = point { throw InjectedJournalFailure.interrupted }
        }
        #expect(throws: InjectedJournalFailure.interrupted) { try journal.migrate() }
        #expect(try fixture.integer("PRAGMA user_version") == 1)
        #expect(try fixture.integer("SELECT count(*) FROM sqlite_master WHERE name='session_capture_journal'") == 0)
        #expect(try JSONDecoder().decode(VoiceSession.self, from: fixture.data("SELECT payload FROM sessions")) == session)
        try IncrementalSessionJournal(connection: fixture.connection).migrate()
        #expect(try fixture.integer("PRAGMA user_version") == 2)
    }

    @Test("Capture-only deltas preserve source identities and deterministic metadata after reopening")
    func appendAndRecover() throws {
        let fixture = try JournalFixture()
        let original = fixtureSession()
        try fixture.seed(original)
        let journal = IncrementalSessionJournal(connection: fixture.connection)
        try journal.migrate()
        let first = segment(intervalID: original.intervals[0].id, start: 0)
        let second = segment(intervalID: original.intervals[0].id, start: 5)
        let date = original.updatedAt.addingTimeInterval(10)
        let delta = try journal.append(sessionID: original.id, expectedRevision: 1,
            segments: [second, first], updatedAt: date)
        #expect(delta.segments.map(\.id) == [first.id, second.id])
        #expect(try journal.latestRevision(sessionID: original.id) == 2)
        try fixture.withReopenedConnection { connection in
            let reopened = IncrementalSessionJournal(connection: connection)
            let pages = try reopened.deltas(sessionID: original.id, afterRevision: 1)
            #expect(pages == [delta])
            var restored = original
            try IncrementalSessionJournal.apply(delta, to: &restored, afterRevision: 1)
            #expect(restored.segments == [first, second])
            #expect(restored.updatedAt == date)
            #expect(restored.intervals == original.intervals)
            #expect(restored.transcripts == original.transcripts)
            #expect(restored.dictation == original.dictation)
            #expect(restored.brief == original.brief)
            #expect(restored.trashedAt == original.trashedAt)
            #expect(try fixture.integer("SELECT length(payload) FROM sessions") ==
                Int64(try fixture.data("SELECT payload FROM sessions").count))
        }
    }

    @Test("A failed capture commit publishes neither source rows nor an advanced header", arguments: [0, 1])
    func appendRollback(boundary: Int) throws {
        let fixture = try JournalFixture()
        let session = fixtureSession()
        try fixture.seed(session)
        let baseline = IncrementalSessionJournal(connection: fixture.connection)
        try baseline.migrate()
        let journal = IncrementalSessionJournal(connection: fixture.connection) { point in
            switch (boundary, point) {
            case (0, .appendAfterInsert), (1, .appendBeforeCommit): throw InjectedJournalFailure.interrupted
            default: break
            }
        }
        let source = segment(intervalID: session.intervals[0].id, start: 0)
        #expect(throws: InjectedJournalFailure.interrupted) {
            try journal.append(sessionID: session.id, expectedRevision: 1, segments: [source], updatedAt: Date())
        }
        #expect(try baseline.latestRevision(sessionID: session.id) == 1)
        #expect(try baseline.deltas(sessionID: session.id, afterRevision: 1).isEmpty)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_sources") == 0)
        #expect(try baseline.history().first?.segmentCount == 0)
        _ = try baseline.append(sessionID: session.id, expectedRevision: 1, segments: [source], updatedAt: Date())
        #expect(try baseline.history().first?.segmentCount == 1)
    }

    @Test("A failed full checkpoint leaves the old payload and committed capture tail recoverable")
    func checkpointRollbackAndPrune() throws {
        let fixture = try JournalFixture()
        var session = fixtureSession()
        try fixture.seed(session)
        let journal = IncrementalSessionJournal(connection: fixture.connection)
        try journal.migrate()
        let delta = try journal.append(sessionID: session.id, expectedRevision: 1,
            segments: [segment(intervalID: session.intervals[0].id, start: 0)], updatedAt: Date())
        try IncrementalSessionJournal.apply(delta, to: &session, afterRevision: 1)
        session.title = "A full metadata checkpoint"
        let broken = IncrementalSessionJournal(connection: fixture.connection) { point in
            if case .checkpointAfterPrune = point { throw InjectedJournalFailure.interrupted }
        }
        #expect(throws: InjectedJournalFailure.interrupted) {
            try fixture.checkpoint(session, revision: 3, journal: broken)
        }
        #expect(try fixture.integer("SELECT revision FROM sessions") == 1)
        #expect(try journal.deltas(sessionID: session.id, afterRevision: 1) == [delta])
        #expect(try journal.latestRevision(sessionID: session.id) == 2)
        try fixture.checkpoint(session, revision: 3, journal: journal)
        #expect(try journal.deltas(sessionID: session.id, afterRevision: 3).isEmpty)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_sources") == 1)
        #expect(try journal.history().first?.title == session.title)
        #expect(try JSONDecoder().decode(VoiceSession.self, from: fixture.data("SELECT payload FROM sessions")) == session)
    }

    @Test("Exact append retries are idempotent while changed, duplicate, stale and overlapping sources fail")
    func immutableSourceAndRetry() throws {
        let fixture = try JournalFixture()
        let session = fixtureSession()
        try fixture.seed(session)
        let journal = IncrementalSessionJournal(connection: fixture.connection)
        try journal.migrate()
        let source = segment(intervalID: session.intervals[0].id, start: 0)
        let date = Date()
        let first = try journal.append(sessionID: session.id, expectedRevision: 1, segments: [source], updatedAt: date)
        #expect(try journal.append(sessionID: session.id, expectedRevision: 1, segments: [source], updatedAt: date) == first)
        var changed = source
        changed.sha256 = String(repeating: "b", count: 64)
        #expect(throws: (any Error).self) {
            try journal.append(sessionID: session.id, expectedRevision: 1, segments: [changed], updatedAt: date)
        }
        #expect(throws: (any Error).self) {
            try journal.append(sessionID: session.id, expectedRevision: 2, segments: [source], updatedAt: date)
        }
        #expect(throws: (any Error).self) {
            try journal.append(sessionID: session.id, expectedRevision: 1,
                segments: [segment(intervalID: source.intervalID, start: 5)], updatedAt: date)
        }
        #expect(throws: (any Error).self) {
            try journal.append(sessionID: session.id, expectedRevision: 2,
                segments: [segment(intervalID: source.intervalID, start: 4.5)], updatedAt: date)
        }
        #expect(try journal.latestRevision(sessionID: session.id) == 2)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_sources") == 1)
    }

    @Test("Corrupt payloads, missing revisions and unsupported page sizes fail without discarding source rows")
    func corruptTailFailsClosed() throws {
        let fixture = try JournalFixture()
        let session = fixtureSession()
        try fixture.seed(session)
        let journal = IncrementalSessionJournal(connection: fixture.connection)
        try journal.migrate()
        for index in 0..<2 {
            _ = try journal.append(sessionID: session.id, expectedRevision: Int64(index + 1),
                segments: [segment(intervalID: session.intervals[0].id, start: Double(index * 5))], updatedAt: Date())
        }
        #expect(throws: (any Error).self) { try journal.deltas(sessionID: session.id, afterRevision: 1, limit: 257) }
        try fixture.execute("UPDATE session_capture_journal SET sha256='changed' WHERE revision=2")
        #expect(throws: (any Error).self) { try journal.deltas(sessionID: session.id, afterRevision: 1) }
        try fixture.execute("DELETE FROM session_capture_journal WHERE revision=2")
        #expect(throws: (any Error).self) { try journal.deltas(sessionID: session.id, afterRevision: 1) }
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_sources") == 2)
        var copy = session
        var invalid = IncrementalSessionJournal.CaptureDelta(sessionID: session.id, revision: 2,
            segments: [segment(intervalID: UUID(), start: 0)], updatedAt: Date())
        #expect(throws: (any Error).self) { try IncrementalSessionJournal.apply(invalid, to: &copy, afterRevision: 1) }
        #expect(copy == session)
        invalid.segments[0].intervalID = session.intervals[0].id
        invalid.segments[0].sha256 = ""
        #expect(throws: (any Error).self) { try IncrementalSessionJournal.apply(invalid, to: &copy, afterRevision: 1) }
        #expect(copy == session)
    }

    @Test("Indexed history pages avoid decoding old payloads and have stable tie-breaking cursors")
    func lazyHistoryPagination() throws {
        let fixture = try JournalFixture()
        let date = Date()
        var expected = Set<UUID>()
        for index in 0..<7 {
            var session = fixtureSession()
            session.title = "Session \(index)"
            session.updatedAt = date
            try fixture.seed(session)
            expected.insert(session.id)
        }
        let journal = IncrementalSessionJournal(connection: fixture.connection)
        try journal.migrate()
        try fixture.execute("UPDATE sessions SET payload=X'00'")
        var found: [UUID] = []
        var cursor: IncrementalSessionJournal.HistoryCursor?
        repeat {
            let page = try journal.history(limit: 3, before: cursor)
            if page.isEmpty { break }
            found.append(contentsOf: page.map(\.id))
            cursor = page.last?.cursor
        } while true
        #expect(found.count == 7 && Set(found) == expected)
        #expect(found.map(\.uuidString) == found.map(\.uuidString).sorted(by: >))
        #expect(throws: (any Error).self) { try journal.history(limit: 257) }
    }

    @Test("Eight hours of five-second source metadata append without rewriting the full checkpoint",
          .timeLimit(.minutes(5)))
    func acceleratedEightHourMetadata() throws {
        let fixture = try JournalFixture()
        let session = fixtureSession()
        try fixture.seed(session)
        let checkpoint = try fixture.data("SELECT payload FROM sessions")
        let journal = IncrementalSessionJournal(connection: fixture.connection)
        try journal.migrate()
        let began = ContinuousClock.now
        let count = 8 * 60 * 60 / 5
        for index in 0..<count {
            _ = try journal.append(sessionID: session.id, expectedRevision: Int64(index + 1),
                segments: [segment(intervalID: session.intervals[0].id, start: Double(index * 5))],
                updatedAt: session.updatedAt.addingTimeInterval(Double(index * 5)))
        }
        let appendMilliseconds = milliseconds(began)
        #expect(try fixture.data("SELECT payload FROM sessions") == checkpoint)
        #expect(try fixture.integer("SELECT count(*) FROM session_capture_journal") == Int64(count))
        let replayBegan = ContinuousClock.now
        var restored = session
        var revision: Int64 = 1
        var maximumPage = 0
        while true {
            let page = try journal.deltas(sessionID: session.id, afterRevision: revision, limit: 128)
            if page.isEmpty { break }
            maximumPage = max(maximumPage, page.count)
            for delta in page {
                try IncrementalSessionJournal.apply(delta, to: &restored, afterRevision: revision)
                revision = delta.revision
            }
        }
        #expect(restored.segments.count == count)
        #expect(restored.recordedDuration == 8 * 60 * 60)
        #expect(Set(restored.segments.map(\.id)).count == count)
        #expect(maximumPage <= 128)
        #expect(try journal.history().first?.segmentCount == count)
        let deltaBytes = try fixture.integer("SELECT SUM(length(payload)) FROM session_capture_journal")
        #expect(deltaBytes < 8 * 1_024 * 1_024)
        let report: [String: String] = [
            "scope": "Accelerated metadata-only SQLite WAL/FULL workload: 5760 five-second records representing eight hours. No audio allocation, real-time microphone, thermal, battery, transcript growth or whole-app qualification.",
            "segments": String(count), "appendMilliseconds": String(appendMilliseconds),
            "replayMilliseconds": String(milliseconds(replayBegan)), "deltaPayloadBytes": String(deltaBytes),
            "unchangedCheckpointBytes": String(checkpoint.count), "maximumRecoveryPage": String(maximumPage)
        ]
        Attachment.record(try JSONEncoder().encode(report), named: "incremental-eight-hour-metadata.json")
    }
}

private enum InjectedJournalFailure: Error, Equatable { case interrupted }

private func fixtureSession() -> VoiceSession {
    var session = VoiceSession()
    session.status = .recording
    session.intervals = [CaptureInterval(sampleRate: 16_000, channelCount: 1)]
    var brief = BriefDocument()
    brief.takes = [BriefTake(intervalID: session.intervals[0].id,
        expectedRevision: brief.revisionID, status: .recording)]
    session.brief = brief
    session.dictation = DictationSession(recordings: [
        DictationRecordingMetadata(id: brief.takes[0].id, state: .recording)
    ])
    return session
}

private func segment(intervalID: UUID, start: Double) -> AudioSegment {
    let id = UUID()
    return AudioSegment(id: id, intervalID: intervalID, fileName: id.uuidString + ".caf",
        startTime: start, frameCount: 80_000, sampleRate: 16_000, channelCount: 1,
        sha256: String(repeating: "a", count: 64))
}

private func milliseconds(_ start: ContinuousClock.Instant) -> Double {
    let value = start.duration(to: .now).components
    return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1_000_000_000_000_000
}

private final class JournalFixture {
    let root: URL
    let connection: OpaquePointer

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite").path, &pointer,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let pointer else { throw InjectedJournalFailure.interrupted }
        connection = pointer
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA fullfsync=ON")
        try execute("CREATE TABLE sessions(id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload BLOB NOT NULL)")
        try execute("CREATE TABLE metadata(key TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try execute("PRAGMA user_version=1")
    }

    deinit {
        sqlite3_close(connection)
        try? FileManager.default.removeItem(at: root)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw InjectedJournalFailure.interrupted }
    }

    func seed(_ session: VoiceSession, revision: Int64 = 1) throws {
        let data = try JSONEncoder().encode(session)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        try execute("INSERT OR REPLACE INTO sessions(id,revision,payload) VALUES('\(session.id.uuidString)',\(revision),X'\(hex)')")
    }

    func checkpoint(_ session: VoiceSession, revision: Int64, journal: IncrementalSessionJournal) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try seed(session, revision: revision)
            try journal.recordCheckpoint(session, revision: revision)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func integer(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw InjectedJournalFailure.interrupted
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw InjectedJournalFailure.interrupted }
        return sqlite3_column_int64(statement, 0)
    }

    func data(_ sql: String) throws -> Data {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw InjectedJournalFailure.interrupted
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
            throw InjectedJournalFailure.interrupted
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    func withReopenedConnection(_ action: (OpaquePointer) throws -> Void) throws {
        var reader: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite").path, &reader,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let reader else {
            throw InjectedJournalFailure.interrupted
        }
        defer { sqlite3_close(reader) }
        try action(reader)
    }
}
