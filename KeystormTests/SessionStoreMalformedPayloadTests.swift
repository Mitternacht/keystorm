import Foundation
import SQLite3
import Testing
@testable import Keystorm

struct SessionStoreMalformedPayloadTests {
    @Test("Malformed catalog copies use bounded JSON fallback without copying their source BLOB",
          arguments: ["empty", "oversized", "text"])
    func selectedFallbackDoesNotCopyMalformedPayload(kind: String) async throws {
        let fixture = try MalformedCatalogFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let old = fixture.session(date: 100)
        let fresh = fixture.session(date: 200)
        try await store.save(old)
        try await store.save(fresh)
        try fixture.damage(old.id, kind: kind)
        let unchangedShape = try fixture.shape(old.id)
        let reopened = try SessionStore(root: fixture.root)
        let page = try await reopened.prepareLazyStartup(limit: 1)
        #expect(page.page.entries.first?.sessionID == fresh.id)
        #expect(await reopened.historyQueryDiagnostics().fullPayloadDecodes == 0)

        // A plain selected read reconciles in memory only. Rejected source bytes
        // stay in place until explicit recovery publishes a valid checkpoint.
        let fallback = try await reopened.loadSession(old.id)
        #expect(fallback == old)
        let reads = await reopened.historyQueryDiagnostics()
        #expect(reads.rejectedCatalogPayloads == 1)
        #expect(reads.largestCatalogPayloadBytesCopied == 0)
        #expect(reads.fullPayloadDecodes == 1)
        #expect(reads.decodedSessionIDs == [old.id])
        #expect(try fixture.shape(old.id) == unchangedShape)

        let recovered = try await reopened.hydrateSession(old.id)
        #expect(recovered.session == old)
        #expect(recovered.reports.contains { $0.contains("bounded non-empty BLOB") })
        #expect(try await reopened.loadSession(fresh.id) == fresh)
        #expect(try fixture.shape(old.id).type == "blob")
        #expect(try fixture.shape(old.id).length > 0)
        #expect(try fixture.shape(old.id).length <= 64 * 1_024 * 1_024)
    }

    @Test("A rejected catalog copy without JSON fallback fails without deleting or rewriting it",
          arguments: ["empty", "oversized", "text"])
    func missingFallbackPreservesRejectedCopy(kind: String) async throws {
        let fixture = try MalformedCatalogFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session(date: 100)
        try await store.save(session)
        let snapshot = try await store.sessionDirectory(session.id).appendingPathComponent("session.json")
        try FileManager.default.removeItem(at: snapshot)
        try fixture.damage(session.id, kind: kind)
        let unchangedShape = try fixture.shape(session.id)
        let reopened = try SessionStore(root: fixture.root)

        await #expect(throws: (any Error).self) { try await reopened.loadSession(session.id) }
        let reads = await reopened.historyQueryDiagnostics()
        #expect(reads.rejectedCatalogPayloads == 1)
        #expect(reads.largestCatalogPayloadBytesCopied == 0 && reads.fullPayloadDecodes == 0)
        #expect(try fixture.shape(session.id) == unchangedShape)
        #expect(try await reopened.containsSession(session.id))
        #expect(try await reopened.prepareLazyStartup().totalSessionCount == 1)
    }

    @Test("A genuine catalog query failure cannot masquerade as a successful snapshot-only archive")
    func catalogQueryFailureRemainsFatal() async throws {
        let fixture = try MalformedCatalogFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session(date: 100)
        try await store.save(session)
        let snapshot = try await store.sessionDirectory(session.id).appendingPathComponent("session.json")
        try fixture.sql("ALTER TABLE sessions RENAME TO preserved_sessions")
        await #expect(throws: (any Error).self) { try await store.loadSession(session.id) }
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
        #expect(try fixture.integer("SELECT count(*) FROM preserved_sessions") == 1)
    }

    @Test("Schema migrations retain malformed source rows and report a bounded snapshot repair",
          arguments: [1, 2], ["empty", "oversized", "text"])
    func migrationPreservesMalformedSources(version: Int, kind: String) async throws {
        let fixture = try MalformedCatalogFixture()
        defer { fixture.remove() }
        let old = fixture.session(date: 100)
        let fresh = fixture.session(date: 200)
        try fixture.seedLegacy([old, fresh], version: version)
        try fixture.writeSnapshot(old)
        try fixture.damage(old.id, kind: kind)
        let unchangedShape = try fixture.shape(old.id)

        let migrated = try SessionStore(root: fixture.root)
        #expect(try fixture.integer("PRAGMA user_version") == 4)
        #expect(try fixture.shape(old.id) == unchangedShape)
        let startup = try await migrated.prepareLazyStartup()
        #expect(startup.totalSessionCount == 2)
        #expect(startup.pendingRepairCount == 1)
        #expect(startup.page.entries.map(\.sessionID) == [fresh.id])
        #expect(startup.reports.contains { $0.contains("synchronized snapshot check") })
        #expect(await migrated.historyQueryDiagnostics().fullPayloadDecodes == 0)

        let repair = try await migrated.maintainHistory()
        #expect(repair.repairedCount == 1 && repair.reports.isEmpty)
        #expect(try await migrated.historyPage().entries.count == 2)
        #expect(try await migrated.loadSession(old.id) == old)
        #expect(try await migrated.loadSession(fresh.id) == fresh)
    }
}

private struct MalformedCatalogCheckpoint: Codable {
    var version = 1
    var revision = Int64(1)
    var session: VoiceSession
}

private struct MalformedCatalogFixture {
    struct Shape: Equatable {
        let revision: Int64
        let type: String
        let length: Int64
    }
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-MalformedCatalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func session(date: Double) -> VoiceSession {
        let created = Date(timeIntervalSinceReferenceDate: date)
        var session = VoiceSession()
        session.title = "Archive \(date)"
        session.createdAt = created
        session.updatedAt = created
        let interval = CaptureInterval(startedAt: created, endedAt: created,
            sampleRate: 16_000, channelCount: 1)
        session.intervals = [interval]
        var brief = BriefDocument()
        let take = BriefTake(intervalID: interval.id, expectedRevision: brief.revisionID, createdAt: created)
        brief.takes = [take]
        session.brief = brief
        let text = "Keep the original. Grüße aus Berlin."
        session.dictation = DictationSession(recordings: [
            DictationRecordingMetadata(id: take.id, state: .ready,
                textRevision: DictationTextRevision(rawText: text, text: text,
                    sourceTranscriptIDs: [], createdAt: created),
                createdAt: created, updatedAt: created)])
        return session
    }
    func withConnection<T>(_ action: (OpaquePointer) throws -> T) throws -> T {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite").path, &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else { throw KeystormError.message("Could not open malformed catalog fixture.") }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5_000)
        return try action(connection)
    }
    func sql(_ value: String) throws {
        try withConnection { connection in
            guard sqlite3_exec(connection, value, nil, nil, nil) == SQLITE_OK else {
                throw KeystormError.message(String(cString: sqlite3_errmsg(connection)))
            }
        }
    }
    func damage(_ id: UUID, kind: String) throws {
        let expression: String
        switch kind {
        case "empty": expression = "X''"
        case "oversized": expression = "zeroblob(67108865)"
        case "text": expression = "'invalid catalog text'"
        default: throw KeystormError.message("Unknown malformed payload fixture.")
        }
        // SQLite's zero BLOB fixture avoids creating a giant Swift Data value.
        try sql("UPDATE sessions SET payload=\(expression) WHERE id='\(id.uuidString)'")
    }
    func integer(_ sql: String) throws -> Int64 {
        try withConnection { connection in
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &query, nil) == SQLITE_OK, let query else {
                throw KeystormError.message("Invalid fixture query.")
            }
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { throw KeystormError.message("Missing fixture row.") }
            return sqlite3_column_int64(query, 0)
        }
    }
    func shape(_ id: UUID) throws -> Shape {
        try withConnection { connection in
            var query: OpaquePointer?
            let sql = "SELECT revision,typeof(payload),length(payload) FROM sessions WHERE id=?"
            guard sqlite3_prepare_v2(connection, sql, -1, &query, nil) == SQLITE_OK, let query else {
                throw KeystormError.message("Invalid fixture shape query.")
            }
            defer { sqlite3_finalize(query) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = sqlite3_bind_text(query, 1, id.uuidString, -1, transient)
            guard sqlite3_step(query) == SQLITE_ROW, let type = sqlite3_column_text(query, 1) else {
                throw KeystormError.message("Missing fixture shape row.")
            }
            return Shape(revision: sqlite3_column_int64(query, 0), type: String(cString: type),
                length: sqlite3_column_int64(query, 2))
        }
    }
    func writeSnapshot(_ session: VoiceSession) throws {
        let directory = root.appendingPathComponent("Sessions").appendingPathComponent(session.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(MalformedCatalogCheckpoint(session: session))
            .write(to: directory.appendingPathComponent("session.json"))
    }
    func seedLegacy(_ sessions: [VoiceSession], version: Int) throws {
        try sql("""
            CREATE TABLE sessions(id TEXT PRIMARY KEY NOT NULL,revision INTEGER NOT NULL,payload BLOB NOT NULL);
            CREATE TABLE metadata(key TEXT PRIMARY KEY NOT NULL,payload BLOB NOT NULL);
            PRAGMA user_version=1;
            """)
        try withConnection { connection in
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for session in sessions {
                var query: OpaquePointer?
                guard sqlite3_prepare_v2(connection, "INSERT INTO sessions VALUES(?,1,?)", -1, &query, nil) == SQLITE_OK,
                      let query else { throw KeystormError.message("Invalid fixture insert.") }
                defer { sqlite3_finalize(query) }
                _ = sqlite3_bind_text(query, 1, session.id.uuidString, -1, transient)
                let payload = try JSONEncoder().encode(session)
                _ = payload.withUnsafeBytes { sqlite3_bind_blob(query, 2, $0.baseAddress, Int32($0.count), transient) }
                guard sqlite3_step(query) == SQLITE_DONE else { throw KeystormError.message("Fixture insert failed.") }
            }
            if version == 2 { try IncrementalSessionJournal(connection: connection).migrate() }
        }
    }
}
