import CryptoKit
import Foundation
import SQLite3

/// Borrowed access to SessionStore's existing catalog connection. This helper never
/// opens a database, owns audio, or establishes another writer. SessionStore serializes
/// every use, validates newly committed audio, and remains the publication authority.
struct IncrementalSessionJournal {
    static let catalogVersion: Int32 = 2
    static let maximumSegmentsPerDelta = 256
    static let maximumDeltaBytes = 128 * 1_024
    static let maximumPageSize = 256

    struct CaptureDelta: Codable, Equatable, Sendable {
        var version = 1
        var sessionID: UUID
        var revision: Int64
        var segments: [AudioSegment]
        var updatedAt: Date
    }

    struct HistoryCursor: Equatable, Sendable {
        var updatedAt: Date
        var id: UUID
    }

    struct HistoryHeader: Equatable, Sendable {
        var id: UUID
        var revision: Int64
        var title: String
        var updatedAt: Date
        var trashedAt: Date?
        var status: SessionStatus
        var segmentCount: Int
        var recordedDuration: Double
        var cursor: HistoryCursor { HistoryCursor(updatedAt: updatedAt, id: id) }
    }

    enum FaultPoint { case migrationBeforeCommit, appendAfterInsert, appendBeforeCommit, checkpointAfterPrune }

    private let connection: OpaquePointer
    private let fault: ((FaultPoint) throws -> Void)?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(connection: OpaquePointer, fault: ((FaultPoint) throws -> Void)? = nil) {
        self.connection = connection
        self.fault = fault
    }

    /// Run after the original sessions/metadata tables exist. Version 2 is necessary:
    /// older applications must reject the catalog instead of ignoring its durable tail.
    func migrate() throws {
        let version = try integer("PRAGMA user_version") ?? 0
        guard version == 1 || version == Int64(Self.catalogVersion) || version == 3 || version == Int64(DictationHistoryRepository.catalogVersion) else { throw failure("Unsupported catalog version.") }
        guard version == 1 else {
            try execute("CREATE INDEX IF NOT EXISTS capture_source_end ON session_capture_sources(session_id, end_time, start_time)")
            return
        }
        try transaction {
            try execute("""
                CREATE TABLE IF NOT EXISTS session_capture_journal (
                    session_id TEXT NOT NULL, revision INTEGER NOT NULL,
                    updated_at REAL NOT NULL, payload BLOB NOT NULL, sha256 TEXT NOT NULL,
                    PRIMARY KEY(session_id, revision))
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS session_capture_sources (
                    session_id TEXT NOT NULL, segment_id TEXT NOT NULL,
                    start_time REAL NOT NULL, end_time REAL NOT NULL, payload BLOB NOT NULL,
                    PRIMARY KEY(session_id, segment_id))
                """)
            try execute("CREATE INDEX IF NOT EXISTS capture_source_time ON session_capture_sources(session_id, start_time, end_time)")
            try execute("CREATE INDEX IF NOT EXISTS capture_source_end ON session_capture_sources(session_id, end_time, start_time)")
            try execute("""
                CREATE TABLE IF NOT EXISTS session_history_headers (
                    session_id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL,
                    title TEXT NOT NULL, updated_at REAL NOT NULL, trashed_at REAL,
                    status TEXT NOT NULL, segment_count INTEGER NOT NULL, recorded_duration REAL NOT NULL)
                """)
            try execute("CREATE INDEX IF NOT EXISTS history_updated ON session_history_headers(updated_at DESC, session_id DESC)")
            // This one-time migration reads old full payloads without changing them.
            let statement = try prepare("""
                SELECT id,revision,
                       CASE WHEN typeof(payload)='blob' THEN
                           CASE WHEN length(payload) BETWEEN 1 AND 67108864 THEN payload ELSE NULL END
                       ELSE NULL END
                FROM sessions ORDER BY id
                """)
            defer { sqlite3_finalize(statement) }
            while try row(statement) {
                try Task.checkCancellation()
                try autoreleasepool {
                    let id = try uuid(statement, 0)
                    let revision = sqlite3_column_int64(statement, 1)
                    // A corrupt catalog copy can still have a valid synchronized JSON
                    // checkpoint. Leave its bytes untouched for SessionStore's existing
                    // snapshot recovery; it receives an index on the next full save.
                    guard let data = try? blob(statement, 2, maximum: 64 * 1_024 * 1_024),
                          let session = try? JSONDecoder().decode(VoiceSession.self, from: data),
                          session.id == id else { return }
                    try recordCheckpoint(session, revision: revision)
                }
            }
            try execute("PRAGMA user_version=2")
            try fault?(.migrationBeforeCommit)
        }
    }

    /// Appends a small capture delta in one WAL/FULL transaction. Exact retries return
    /// the existing delta. A changed source, stale revision or overlap fails closed.
    func append(sessionID: UUID, expectedRevision: Int64, segments: [AudioSegment],
                updatedAt: Date) throws -> CaptureDelta {
        guard expectedRevision > 0, expectedRevision < Int64.max else { throw failure("Invalid capture revision.") }
        let delta = CaptureDelta(sessionID: sessionID, revision: expectedRevision + 1,
            segments: segments.sorted { $0.startTime < $1.startTime }, updatedAt: updatedAt)
        try validate(delta)
        let payload = try encoded(delta)
        guard payload.count <= Self.maximumDeltaBytes else { throw failure("Capture delta exceeds its metadata bound.") }
        return try transaction {
            if let existing = try storedDelta(sessionID: sessionID, revision: delta.revision) {
                guard existing == delta, try encoded(existing) == payload else {
                    throw failure("An acknowledged capture revision cannot be replaced.")
                }
                return existing
            }
            guard try latestRevision(sessionID: sessionID) == expectedRevision else {
                throw failure("The capture checkpoint changed. Reload before appending.")
            }
            let header = try requireHeader(sessionID)
            guard header.revision == expectedRevision else { throw failure("The capture header no longer matches its durable tail.") }
            for segment in delta.segments {
                guard try sourcePayload(sessionID: sessionID, segmentID: segment.id) == nil else {
                    throw failure("A source identity is already owned by this session.")
                }
                let overlap = try integer("""
                    SELECT 1 FROM session_capture_sources WHERE session_id=?
                    AND start_time < ? AND end_time > ? LIMIT 1
                    """, [.text(sessionID.uuidString), .real(segment.endTime - 0.001), .real(segment.startTime + 0.001)])
                guard overlap == nil else { throw failure("Capture ranges overlap an existing source.") }
                try insertSource(segment, sessionID: sessionID)
            }
            try execute("""
                INSERT INTO session_capture_journal(session_id,revision,updated_at,payload,sha256)
                VALUES(?,?,?,?,?)
                """, [.text(sessionID.uuidString), .integer(delta.revision),
                      .real(updatedAt.timeIntervalSinceReferenceDate), .data(payload), .text(digest(payload))])
            try fault?(.appendAfterInsert)
            let duration = max(header.recordedDuration, delta.segments.map(\.endTime).max() ?? 0)
            try execute("""
                UPDATE session_history_headers SET revision=?,updated_at=?,segment_count=?,recorded_duration=?
                WHERE session_id=?
                """, [.integer(delta.revision), .real(updatedAt.timeIntervalSinceReferenceDate),
                      .integer(Int64(header.segmentCount + delta.segments.count)), .real(duration), .text(sessionID.uuidString)])
            if let version = try integer("PRAGMA user_version"), (3...Int64(DictationHistoryRepository.catalogVersion)).contains(version) {
                try DictationHistoryRepository(connection: connection).captureDidAppend()
            }
            try fault?(.appendBeforeCommit)
            return delta
        }
    }

    /// Bounded keyset pages; callers fold one page at a time over the selected legacy
    /// checkpoint. A missing revision must be treated as corruption, never skipped.
    func deltas(sessionID: UUID, afterRevision: Int64, limit: Int = 128) throws -> [CaptureDelta] {
        guard afterRevision >= 0, (1...Self.maximumPageSize).contains(limit) else { throw failure("Invalid capture page.") }
        let statement = try prepare("""
            SELECT revision,payload,sha256 FROM session_capture_journal
            WHERE session_id=? AND revision>? ORDER BY revision LIMIT ?
            """, [.text(sessionID.uuidString), .integer(afterRevision), .integer(Int64(limit))])
        defer { sqlite3_finalize(statement) }
        var result: [CaptureDelta] = []
        var expected = afterRevision
        while try row(statement) {
            let revision = sqlite3_column_int64(statement, 0)
            let data = try blob(statement, 1, maximum: Self.maximumDeltaBytes)
            guard expected < Int64.max, revision == expected + 1,
                  digest(data) == text(statement, 2) else { throw failure("Capture journal continuity or checksum failed.") }
            let delta = try JSONDecoder().decode(CaptureDelta.self, from: data)
            try validate(delta)
            guard delta.sessionID == sessionID, delta.revision == revision else { throw failure("Capture journal identity mismatch.") }
            result.append(delta)
            expected = revision
        }
        return result
    }

    func latestRevision(sessionID: UUID) throws -> Int64? {
        let checkpoint = try integer("SELECT revision FROM sessions WHERE id=?", [.text(sessionID.uuidString)])
        guard let checkpoint else { return nil }
        return max(checkpoint, try integer("SELECT MAX(revision) FROM session_capture_journal WHERE session_id=?",
            [.text(sessionID.uuidString)]) ?? checkpoint)
    }

    /// Called INSIDE SQLiteCatalog.putSession's existing transaction after its row
    /// replacement. The legacy synchronized JSON checkpoint remains recoverable.
    /// No method here commits an independently advanced metadata authority.
    func recordCheckpoint(_ session: VoiceSession, revision: Int64) throws {
        guard sqlite3_get_autocommit(connection) == 0, revision > 0, session.schemaVersion == 1,
              session.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              session.trashedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              Set(session.segments.map(\.id)).count == session.segments.count else {
            throw failure("Invalid checkpoint or missing owner transaction.")
        }
        guard try integer("SELECT revision FROM sessions WHERE id=?", [.text(session.id.uuidString)]) == revision else {
            throw failure("Checkpoint indexing must share the owner row's transaction and revision.")
        }
        if let latest = try integer("SELECT MAX(revision) FROM session_capture_journal WHERE session_id=?",
                                   [.text(session.id.uuidString)]), latest > revision {
            throw failure("A checkpoint cannot discard a newer capture tail.")
        }
        for segment in session.segments {
            try validate(segment)
            let data = try encoded(segment)
            if let existing = try sourcePayload(sessionID: session.id, segmentID: segment.id) {
                guard existing == data else { throw failure("Original source metadata cannot be rewritten.") }
            } else { try insertSource(segment, sessionID: session.id) }
        }
        try execute("DELETE FROM session_capture_journal WHERE session_id=? AND revision<=?",
                    [.text(session.id.uuidString), .integer(revision)])
        try fault?(.checkpointAfterPrune)
        try execute("""
            INSERT INTO session_history_headers(session_id,revision,title,updated_at,trashed_at,status,segment_count,recorded_duration)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,
            updated_at=excluded.updated_at,trashed_at=excluded.trashed_at,status=excluded.status,
            segment_count=excluded.segment_count,recorded_duration=excluded.recorded_duration
            """, [.text(session.id.uuidString), .integer(revision), .text(String(session.title.prefix(4_096))),
                  .real(session.updatedAt.timeIntervalSinceReferenceDate),
                  session.trashedAt.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null,
                  .text(session.status.rawValue), .integer(Int64(session.segments.count)), .real(session.recordedDuration)])
    }

    static func apply(_ delta: CaptureDelta, to session: inout VoiceSession, afterRevision: Int64) throws {
        guard delta.version == 1, delta.sessionID == session.id, afterRevision < Int64.max,
              delta.revision == afterRevision + 1,
              !delta.segments.isEmpty, delta.segments.count <= maximumSegmentsPerDelta,
              delta.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw KeystormError.message("Capture journal cannot be folded over this checkpoint.")
        }
        let known = Set(session.segments.map(\.id))
        let intervals = Set(session.intervals.map(\.id))
        guard Set(delta.segments.map(\.id)).count == delta.segments.count,
              delta.segments.allSatisfy({
                  Self.hasValidMetadata($0) && !known.contains($0.id) && intervals.contains($0.intervalID)
              }) else {
            throw KeystormError.message("Capture journal source ownership changed.")
        }
        var next = session
        let appendIsOrdered = zip(delta.segments, delta.segments.dropFirst()).allSatisfy { $0.startTime <= $1.startTime } &&
            (next.segments.last.map { $0.startTime <= (delta.segments.first?.startTime ?? 0) } ?? true)
        next.segments.append(contentsOf: delta.segments)
        if !appendIsOrdered { next.segments.sort { $0.startTime < $1.startTime } }
        next.invalidateDerivedWork()
        next.updatedAt = delta.updatedAt
        session = next
    }

    func history(limit: Int = 100, before: HistoryCursor? = nil) throws -> [HistoryHeader] {
        guard (1...Self.maximumPageSize).contains(limit),
              before?.updatedAt.timeIntervalSinceReferenceDate.isFinite ?? true else { throw failure("Invalid history page.") }
        let predicate = before == nil ? "" : "WHERE updated_at<? OR (updated_at=? AND session_id<?)"
        var values: [Value] = []
        if let before {
            values = [.real(before.updatedAt.timeIntervalSinceReferenceDate),
                      .real(before.updatedAt.timeIntervalSinceReferenceDate), .text(before.id.uuidString)]
        }
        values.append(.integer(Int64(limit)))
        let statement = try prepare("""
            SELECT session_id,revision,title,updated_at,trashed_at,status,segment_count,recorded_duration
            FROM session_history_headers \(predicate) ORDER BY updated_at DESC,session_id DESC LIMIT ?
            """, values)
        defer { sqlite3_finalize(statement) }
        var result: [HistoryHeader] = []
        while try row(statement) { result.append(try header(statement)) }
        return result
    }

    private func requireHeader(_ id: UUID) throws -> HistoryHeader {
        let statement = try prepare("""
            SELECT session_id,revision,title,updated_at,trashed_at,status,segment_count,recorded_duration
            FROM session_history_headers WHERE session_id=?
            """, [.text(id.uuidString)])
        defer { sqlite3_finalize(statement) }
        guard try row(statement) else { throw failure("The capture checkpoint has no indexed header.") }
        return try header(statement)
    }

    private func header(_ statement: OpaquePointer) throws -> HistoryHeader {
        guard let status = SessionStatus(rawValue: text(statement, 5)) else { throw failure("Invalid indexed session status.") }
        let revision = sqlite3_column_int64(statement, 1)
        let count = sqlite3_column_int64(statement, 6)
        let duration = sqlite3_column_double(statement, 7)
        guard revision > 0, count >= 0, count <= Int64(Int.max),
              sqlite3_column_double(statement, 3).isFinite, duration.isFinite, duration >= 0,
              sqlite3_column_type(statement, 4) == SQLITE_NULL || sqlite3_column_double(statement, 4).isFinite else {
            throw failure("Invalid bounded session header.")
        }
        return HistoryHeader(id: try uuid(statement, 0), revision: revision,
            title: text(statement, 2), updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3)),
            trashedAt: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil :
                Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)),
            status: status, segmentCount: Int(sqlite3_column_int64(statement, 6)),
            recordedDuration: sqlite3_column_double(statement, 7))
    }

    private func storedDelta(sessionID: UUID, revision: Int64) throws -> CaptureDelta? {
        let statement = try prepare("SELECT payload,sha256 FROM session_capture_journal WHERE session_id=? AND revision=?",
                                    [.text(sessionID.uuidString), .integer(revision)])
        defer { sqlite3_finalize(statement) }
        guard try row(statement) else { return nil }
        let data = try blob(statement, 0, maximum: Self.maximumDeltaBytes)
        guard digest(data) == text(statement, 1) else { throw failure("Capture delta checksum failed.") }
        let value = try JSONDecoder().decode(CaptureDelta.self, from: data)
        try validate(value)
        return value
    }

    private func sourcePayload(sessionID: UUID, segmentID: UUID) throws -> Data? {
        let statement = try prepare("SELECT payload FROM session_capture_sources WHERE session_id=? AND segment_id=?",
                                    [.text(sessionID.uuidString), .text(segmentID.uuidString)])
        defer { sqlite3_finalize(statement) }
        guard try row(statement) else { return nil }
        return try blob(statement, 0, maximum: 8_192)
    }

    private func insertSource(_ segment: AudioSegment, sessionID: UUID) throws {
        try execute("INSERT INTO session_capture_sources(session_id,segment_id,start_time,end_time,payload) VALUES(?,?,?,?,?)",
            [.text(sessionID.uuidString), .text(segment.id.uuidString), .real(segment.startTime),
             .real(segment.endTime), .data(try encoded(segment))])
    }

    private func validate(_ delta: CaptureDelta) throws {
        guard delta.version == 1, delta.revision > 1,
              delta.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              (1...Self.maximumSegmentsPerDelta).contains(delta.segments.count),
              Set(delta.segments.map(\.id)).count == delta.segments.count else { throw failure("Invalid bounded capture delta.") }
        for segment in delta.segments { try validate(segment) }
    }

    private func validate(_ segment: AudioSegment) throws {
        guard Self.hasValidMetadata(segment) else { throw failure("Invalid immutable capture source metadata.") }
    }

    private static func hasValidMetadata(_ segment: AudioSegment) -> Bool {
        segment.fileName.lowercased() == segment.id.uuidString.lowercased() + ".caf" &&
        segment.startTime.isFinite && segment.startTime >= 0 && segment.endTime.isFinite &&
        segment.sampleRate.isFinite && segment.sampleRate > 0 && segment.frameCount > 0 &&
        (1...64).contains(segment.channelCount) && segment.sha256.utf8.count == 64 &&
        segment.sha256.allSatisfy(\.isHexDigit) && segment.committedAt.timeIntervalSinceReferenceDate.isFinite
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum Value { case text(String), integer(Int64), real(Double), data(Data), null }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw failure("SQLite statement failed.") }
    }

    private func prepare(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &result, nil) == SQLITE_OK, let result else {
            throw failure("SQLite preparation failed.")
        }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let status: Int32
                switch value {
                case .text(let value): status = sqlite3_bind_text(result, index, value, -1, transient)
                case .integer(let value): status = sqlite3_bind_int64(result, index, value)
                case .real(let value): status = sqlite3_bind_double(result, index, value)
                case .data(let value):
                    status = value.withUnsafeBytes { sqlite3_bind_blob(result, index, $0.baseAddress, Int32($0.count), transient) }
                case .null: status = sqlite3_bind_null(result, index)
                }
                guard status == SQLITE_OK else { throw failure("SQLite binding failed.") }
            }
            return result
        } catch { sqlite3_finalize(result); throw error }
    }

    private func row(_ statement: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return false }
        guard status == SQLITE_ROW else { throw failure("SQLite read failed.") }
        return true
    }

    private func integer(_ sql: String, _ values: [Value] = []) throws -> Int64? {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard try row(statement), sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private func uuid(_ statement: OpaquePointer, _ column: Int32) throws -> UUID {
        guard let value = UUID(uuidString: text(statement, column)) else { throw failure("Invalid indexed identity.") }
        return value
    }

    private func blob(_ statement: OpaquePointer, _ column: Int32, maximum: Int) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= maximum, let bytes = sqlite3_column_blob(statement, column) else {
            throw failure("Invalid bounded metadata blob.")
        }
        return Data(bytes: bytes, count: count)
    }

    private func transaction<T>(_ action: () throws -> T) throws -> T {
        guard sqlite3_get_autocommit(connection) != 0 else { throw failure("Capture append requires its own owner transaction boundary.") }
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try action()
            try execute("COMMIT")
            return value
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func failure(_ message: String) -> KeystormError {
        .message(message + " " + String(cString: sqlite3_errmsg(connection)))
    }
}
