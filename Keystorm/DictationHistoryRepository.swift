import Foundation
import SQLite3

/// Small indexed values used by the primary dictation library. Audio, transcripts,
/// and output histories remain exclusively in SessionStore's checkpoint and journal.
struct DictationHistoryHeader: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let title: String
    let preview: String
    let createdAt: Date
    let state: DictationRecordingState
    let revision: Int64
    var stableID: String { sessionID.uuidString + "/" + id.uuidString }
    var handle: DictationRecordingHandle { .init(sessionID: sessionID, takeID: id) }
}

struct DictationHistoryCursor: Equatable, Sendable {
    let createdAt: Date
    let takeID: UUID
    let sessionID: UUID
    let generation: Int64
}

struct DictationHistoryPage: Equatable, Sendable {
    let entries: [DictationHistoryHeader]
    let nextCursor: DictationHistoryCursor?
    let generation: Int64
    let invalidated: Bool
}

struct DictationHistoryStartup: Sendable {
    let page: DictationHistoryPage
    let reports: [String]
    let pendingRepairCount: Int
    let totalSessionCount: Int
    /// Filesystem discovery is deliberately explicit and bounded. Selecting any
    /// indexed recording performs its full source recovery before editing it.
    let maintenanceAvailable: Bool
}

struct DictationSessionHydration: Sendable {
    let session: VoiceSession
    let reports: [String]
}

struct DictationHistoryMaintenance: Sendable {
    let inspectedCount: Int
    let repairedCount: Int
    let nextDirectory: String?
    let reports: [String]
}

/// Borrows the single catalog connection owned by SessionStore. Version 3 adds
/// disposable take headers, not another source of recording or audio authority.
/// Version 4 upgrades early version 3 catalogs whose headers lacked a source count.
struct DictationHistoryRepository {
    static let catalogVersion: Int32 = 4
    static let maximumPageSize = 100
    private static let validTakeIdentity = "length(d.take_id)=36 AND substr(d.take_id,9,1)='-' AND substr(d.take_id,14,1)='-' AND substr(d.take_id,19,1)='-' AND substr(d.take_id,24,1)='-' AND length(replace(d.take_id,'-',''))=32 AND replace(d.take_id,'-','') NOT GLOB '*[^0-9A-Fa-f]*'"
    enum FaultPoint { case migrationBeforeCommit }
    private let connection: OpaquePointer
    private let fault: ((FaultPoint) throws -> Void)?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(connection: OpaquePointer, fault: ((FaultPoint) throws -> Void)? = nil) {
        self.connection = connection
        self.fault = fault
    }

    func migrate() throws {
        let version = try scalar("PRAGMA user_version") ?? 0
        guard (2...Int64(Self.catalogVersion)).contains(version) else { throw failure("Unsupported history schema.") }
        guard version < Int64(Self.catalogVersion) else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            if version == 2 {
                try execute("""
                    CREATE TABLE dictation_history (
                        session_id TEXT NOT NULL, take_id TEXT NOT NULL,
                        revision INTEGER NOT NULL, title TEXT NOT NULL, preview TEXT NOT NULL,
                        created_at REAL NOT NULL, state TEXT NOT NULL, trashed INTEGER NOT NULL,
                        PRIMARY KEY(session_id,take_id))
                    """)
                try execute("CREATE INDEX dictation_history_created ON dictation_history(trashed,created_at DESC,take_id DESC,session_id DESC)")
                try execute("""
                    CREATE TABLE dictation_history_checkpoints (
                        session_id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL,
                        snapshot_stamp TEXT, status TEXT NOT NULL, recording_count INTEGER NOT NULL)
                    """)
                try execute("CREATE TABLE dictation_history_repairs (session_id TEXT PRIMARY KEY NOT NULL, reason TEXT NOT NULL)")
                try execute("CREATE TABLE dictation_history_generation (singleton INTEGER PRIMARY KEY CHECK(singleton=1), value INTEGER NOT NULL)")
                try execute("INSERT INTO dictation_history_generation VALUES(1,1)")
                let query = try prepare("""
                    SELECT id,revision,
                           CASE WHEN typeof(payload)='blob' THEN
                               CASE WHEN length(payload) BETWEEN 1 AND 67108864 THEN payload ELSE NULL END
                           ELSE NULL END
                    FROM sessions ORDER BY id
                    """)
                defer { sqlite3_finalize(query) }
                while try row(query) {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        guard let id = UUID(uuidString: text(query, 0)) else { throw failure("Invalid session identity in history migration.") }
                        let revision = sqlite3_column_int64(query, 1)
                        let count = Int(sqlite3_column_bytes(query, 2))
                        guard count > 0, count <= 64 * 1_024 * 1_024,
                              let pointer = sqlite3_column_blob(query, 2),
                              let session = try? JSONDecoder().decode(VoiceSession.self, from: Data(bytes: pointer, count: count)),
                              session.id == id, session.schemaVersion == 1 else {
                            try markRepair(id, reason: "The catalog checkpoint needs its synchronized snapshot checked.")
                            return
                        }
                        try recordCheckpoint(session, revision: revision, snapshotStamp: nil)
                    }
                }
            } else if try scalar("SELECT count(*) FROM pragma_table_info('dictation_history_checkpoints') WHERE name='recording_count'") == 0 {
                // The old disposable index cannot establish how many recordings its
                // source checkpoint owns. Keep an unknown sentinel until selected
                // source recovery or explicit bounded maintenance checks that source.
                try execute("ALTER TABLE dictation_history_checkpoints ADD COLUMN recording_count INTEGER NOT NULL DEFAULT -1")
                try execute("""
                    INSERT OR IGNORE INTO dictation_history_repairs(session_id,reason)
                    SELECT session_id,'An earlier history index needs its source checkpoint checked.'
                    FROM dictation_history_checkpoints
                    """)
                try bumpGeneration()
            }
            try execute("PRAGMA user_version=4")
            try fault?(.migrationBeforeCommit)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Must share the original catalog publication transaction. Rebuilding this
    /// bounded display index can never publish a source revision independently.
    func recordCheckpoint(_ session: VoiceSession, revision: Int64, snapshotStamp: String?) throws {
        guard sqlite3_get_autocommit(connection) == 0, revision > 0,
              session.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw failure("History indexing requires its checkpoint transaction.")
        }
        try execute("DELETE FROM dictation_history WHERE session_id=?", [.text(session.id.uuidString)])
        if session.dictation != nil {
            for recording in session.recordings {
                guard recording.createdAt.timeIntervalSinceReferenceDate.isFinite else { throw failure("Invalid history creation date.") }
                let title = recording.name == "Recording" ? session.title : recording.name
                try execute("""
                    INSERT INTO dictation_history(session_id,take_id,revision,title,preview,created_at,state,trashed)
                    VALUES(?,?,?,?,?,?,?,?)
                    """, [.text(session.id.uuidString), .text(recording.id.uuidString), .integer(revision),
                          .text(Self.boundedDisplayText(title, characters: 160, bytes: 2_048)),
                          .text(Self.boundedDisplayText(recording.dictation?.textRevision?.text ?? "", characters: 100, bytes: 1_024)),
                          .real(recording.createdAt.timeIntervalSinceReferenceDate), .text(recording.state.rawValue),
                          .integer(recording.trashedAt == nil && session.trashedAt == nil ? 0 : 1)])
            }
        }
        try execute("""
            INSERT INTO dictation_history_checkpoints(session_id,revision,snapshot_stamp,status,recording_count) VALUES(?,?,?,?,?)
            ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision,snapshot_stamp=excluded.snapshot_stamp,status=excluded.status,recording_count=excluded.recording_count
            """, [.text(session.id.uuidString), .integer(revision), snapshotStamp.map(Value.text) ?? .null, .text(session.status.rawValue),
                  .integer(Int64(session.dictation == nil ? 0 : session.recordings.count))])
        try execute("DELETE FROM dictation_history_repairs WHERE session_id=?", [.text(session.id.uuidString)])
        try bumpGeneration()
    }

    /// Called after a capture tail commits. The live journal header supplies its
    /// revision; text and source metadata are never reconstructed to refresh a row.
    func captureDidAppend() throws { try bumpGeneration() }

    func page(limit: Int, before: DictationHistoryCursor?) throws -> DictationHistoryPage {
        guard (1...Self.maximumPageSize).contains(limit),
              before?.createdAt.timeIntervalSinceReferenceDate.isFinite ?? true else { throw failure("Invalid history page.") }
        let generation = try scalar("SELECT value FROM dictation_history_generation WHERE singleton=1") ?? 1
        if let before, before.generation != generation {
            return .init(entries: [], nextCursor: nil, generation: generation, invalidated: true)
        }
        var values: [Value] = []
        var predicate = "d.trashed=0 AND (\(Self.validTakeIdentity))"
        if let before {
            predicate += " AND (d.created_at<? OR (d.created_at=? AND (d.take_id<? OR (d.take_id=? AND d.session_id<?))))"
            values += [.real(before.createdAt.timeIntervalSinceReferenceDate), .real(before.createdAt.timeIntervalSinceReferenceDate),
                       .text(before.takeID.uuidString), .text(before.takeID.uuidString), .text(before.sessionID.uuidString)]
        }
        values.append(.integer(Int64(limit + 1)))
        let query = try prepare("""
            SELECT d.session_id,d.take_id,d.title,d.preview,d.created_at,d.state,
                   CASE WHEN h.revision>d.revision THEN h.revision ELSE d.revision END
            FROM dictation_history d JOIN dictation_history_checkpoints c ON c.session_id=d.session_id
            LEFT JOIN session_history_headers h ON h.session_id=d.session_id
            WHERE \(predicate) ORDER BY d.created_at DESC,d.take_id DESC,d.session_id DESC LIMIT ?
            """, values)
        defer { sqlite3_finalize(query) }
        var headers: [DictationHistoryHeader] = []
        while try row(query) {
            guard let sessionID = UUID(uuidString: text(query, 0)), let takeID = UUID(uuidString: text(query, 1)) else {
                throw failure("An indexed recording identity needs history maintenance.")
            }
            let date = sqlite3_column_double(query, 4)
            let revision = sqlite3_column_int64(query, 6)
            let state = DictationRecordingState(rawValue: text(query, 5))
            let invalid = state == nil || !date.isFinite || revision <= 0 ||
                text(query, 2).count > 160 || text(query, 3).count > 100 ||
                sqlite3_column_bytes(query, 2) > 2_048 || sqlite3_column_bytes(query, 3) > 1_024
            if invalid {
                try markRepair(sessionID, reason: "An indexed recording row needs its source checkpoint checked.")
            }
            headers.append(.init(id: takeID, sessionID: sessionID,
                title: Self.boundedDisplayText(text(query, 2), characters: 160, bytes: 2_048),
                preview: invalid ? "Check library to repair this entry." : text(query, 3),
                createdAt: Date(timeIntervalSinceReferenceDate: date.isFinite ? date : 0),
                state: invalid ? .failed : state!, revision: max(1, revision)))
        }
        let more = headers.count > limit
        if more { headers.removeLast() }
        let next = more ? headers.last.map {
            DictationHistoryCursor(createdAt: $0.createdAt, takeID: $0.id, sessionID: $0.sessionID, generation: generation)
        } : nil
        return .init(entries: headers, nextCursor: next, generation: generation, invalidated: false)
    }

    func pendingRepairCount() throws -> Int {
        Int(try scalar("""
            SELECT count(*) FROM (
                SELECT session_id FROM dictation_history_repairs
                UNION SELECT s.id FROM sessions s LEFT JOIN dictation_history_checkpoints c ON c.session_id=s.id WHERE c.session_id IS NULL
                UNION SELECT c.session_id FROM dictation_history_checkpoints c WHERE
                    c.recording_count<>(SELECT count(*) FROM dictation_history d WHERE d.session_id=c.session_id)
                    OR EXISTS(SELECT 1 FROM dictation_history d WHERE d.session_id=c.session_id AND
                        (NOT (\(Self.validTakeIdentity)) OR d.revision<>c.revision OR d.created_at>1e20 OR d.created_at< -1e20 OR length(d.title)>160 OR length(d.preview)>100 OR length(CAST(d.title AS BLOB))>2048 OR length(CAST(d.preview AS BLOB))>1024 OR
                         d.state NOT IN ('recording','paused','captured','processing','ready','failed','cancelled') OR
                         d.trashed NOT IN (0,1))))
            """) ?? 0)
    }

    func totalSessionCount() throws -> Int {
        Int(try scalar("SELECT count(*) FROM sessions") ?? 0)
    }

    func interruptedCount() throws -> Int {
        Int(try scalar("SELECT count(*) FROM dictation_history_checkpoints WHERE status='recording'") ?? 0)
    }

    func needsRepair(_ id: UUID, snapshotStamp: String?) throws -> Bool {
        let query = try prepare("""
            SELECT c.snapshot_stamp,c.recording_count,
                   (SELECT count(*) FROM dictation_history d WHERE d.session_id=c.session_id),
                   (SELECT count(*) FROM dictation_history_repairs r WHERE r.session_id=c.session_id),
                   (SELECT count(*) FROM dictation_history d WHERE d.session_id=c.session_id AND
                       (NOT (\(Self.validTakeIdentity)) OR d.revision<>c.revision OR d.created_at>1e20 OR d.created_at< -1e20 OR length(d.title)>160 OR length(d.preview)>100 OR length(CAST(d.title AS BLOB))>2048 OR length(CAST(d.preview AS BLOB))>1024 OR
                        d.state NOT IN ('recording','paused','captured','processing','ready','failed','cancelled') OR
                        d.trashed NOT IN (0,1)))
            FROM dictation_history_checkpoints c WHERE c.session_id=?
            """, [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        guard try row(query) else { return true }
        if sqlite3_column_int64(query, 1) != sqlite3_column_int64(query, 2) ||
            sqlite3_column_int64(query, 3) != 0 || sqlite3_column_int64(query, 4) != 0 { return true }
        guard let snapshotStamp else { return false }
        return sqlite3_column_type(query, 0) == SQLITE_NULL || text(query, 0) != snapshotStamp
    }

    func markRepair(_ id: UUID, reason: String) throws {
        try execute("""
            INSERT INTO dictation_history_repairs(session_id,reason) VALUES(?,?)
            ON CONFLICT(session_id) DO UPDATE SET reason=excluded.reason
            """, [.text(id.uuidString), .text(String(reason.prefix(512)))])
    }

    private static func boundedDisplayText(_ value: String, characters: Int, bytes: Int) -> String {
        var result = ""
        var usedBytes = 0
        var usedCharacters = 0
        for character in value {
            guard usedCharacters < characters else { break }
            let characterBytes = String(character).utf8.count
            guard characterBytes <= bytes - usedBytes else { break }
            result.append(character)
            usedCharacters += 1
            usedBytes += characterBytes
        }
        return result
    }

    private func bumpGeneration() throws {
        try execute("UPDATE dictation_history_generation SET value=CASE WHEN value=9223372036854775807 THEN 1 ELSE value+1 END WHERE singleton=1")
    }

    private enum Value { case text(String), integer(Int64), real(Double), null }
    private func prepare(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &query, nil) == SQLITE_OK, let query else { throw failure("History SQL preparation failed.") }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .text(let string): result = sqlite3_bind_text(query, index, string, -1, transient)
                case .integer(let number): result = sqlite3_bind_int64(query, index, number)
                case .real(let number): result = sqlite3_bind_double(query, index, number)
                case .null: result = sqlite3_bind_null(query, index)
                }
                guard result == SQLITE_OK else { throw failure("History SQL binding failed.") }
            }
            return query
        } catch { sqlite3_finalize(query); throw error }
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let query = try prepare(sql, values)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw failure("History SQL write failed.") }
    }
    private func row(_ query: OpaquePointer) throws -> Bool {
        switch sqlite3_step(query) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure("History SQL read failed.")
        }
    }
    private func scalar(_ sql: String) throws -> Int64? {
        let query = try prepare(sql)
        defer { sqlite3_finalize(query) }
        guard try row(query), sqlite3_column_type(query, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(query, 0)
    }
    private func text(_ query: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(query, column).map { String(cString: $0) } ?? ""
    }
    private func failure(_ message: String) -> KeystormError {
        .message(message + " " + String(cString: sqlite3_errmsg(connection)))
    }
}
