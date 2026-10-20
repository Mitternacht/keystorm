import AVFoundation
import Foundation
import SQLite3
import Testing
@testable import Keystorm

/// Accelerated storage fixtures exercise real tiny CAF files and the production
/// catalog. They do not qualify eight hours of microphone capture or device thermals.
struct SessionStoreIncrementalTests {
    @Test("Legacy catalog migration preserves checkpoint payload and reopens at schema 4")
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
        #expect(try fixture.integer("PRAGMA user_version") == 4)
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
