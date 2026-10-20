import AVFoundation
import Foundation
import SQLite3
import Testing
@testable import Keystorm

struct LazyDictationHistoryTests {
    @Test("Steady indexed startup and all header pages decode zero full archives")
    func startupAndPagesAreLazy() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let date = Date(timeIntervalSinceReferenceDate: 123_456)
        var expected: [String] = []
        for index in 0..<9 {
            var session = fixture.session(date: date)
            session.title = "Dictation \(index)"
            session.taskDescription = String(repeating: "a", count: index == 0 ? 4 * 1_024 * 1_024 : 8)
            try await store.save(session)
            expected.append(session.id.uuidString + "/" + session.recordings[0].id.uuidString)
        }
        let reopened = try SessionStore(root: fixture.root)
        let startup = try await reopened.prepareLazyStartup(limit: 3)
        #expect(startup.totalSessionCount == 9)
        #expect(startup.pendingRepairCount == 0)
        var entries = startup.page.entries
        var cursor = startup.page.nextCursor
        while let next = cursor {
            let page = try await reopened.historyPage(limit: 3, before: next)
            #expect(!page.invalidated)
            entries.append(contentsOf: page.entries)
            cursor = page.nextCursor
        }
        #expect(Set(entries.map(\.stableID)) == Set(expected))
        #expect(entries.count == expected.count)
        #expect(entries.allSatisfy { $0.preview.count <= 100 && $0.title.count <= 160 })
        let metrics = await reopened.historyQueryDiagnostics()
        #expect(metrics.fullPayloadDecodes == 0)
        #expect(metrics.decodedSessionIDs.isEmpty)
        #expect(metrics.historyPageQueries == 3)
        let selected = try #require(entries.last)
        let hydrated = try await reopened.hydrateSession(selected.sessionID)
        #expect(hydrated.session.id == selected.sessionID)
        let after = await reopened.historyQueryDiagnostics()
        #expect(after.fullPayloadDecodes > 0)
        #expect(after.decodedSessionIDs == [selected.sessionID])
    }

    @Test("A thousand-record indexed library pages without loading archived payloads")
    func thousandRecordIndexBenchmark() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSinceReferenceDate: 900)
        var sessions = (0..<1_000).map { index in
            fixture.session(date: date.addingTimeInterval(Double(index)))
        }
        sessions[0].taskDescription = String(repeating: "large archived body ", count: 220_000)
        try fixture.seedVersionTwo(sessions)
        // First open performs the explicitly separate one-time migration.
        _ = try SessionStore(root: fixture.root)
        let store = try SessionStore(root: fixture.root)
        let start = ContinuousClock.now
        let startup = try await store.prepareLazyStartup(limit: 50)
        let startupMilliseconds = start.duration(to: .now).components
        var count = startup.page.entries.count
        var cursor = startup.page.nextCursor
        var pages = 1
        while let next = cursor {
            let page = try await store.historyPage(limit: 50, before: next)
            #expect(page.entries.count <= 50 && !page.invalidated)
            count += page.entries.count
            pages += 1
            cursor = page.nextCursor
        }
        let totalDuration = start.duration(to: .now).components
        let diagnostics = await store.historyQueryDiagnostics()
        #expect(count == 1_000 && pages == 20 && startup.page.entries.count == 50)
        #expect(diagnostics.fullPayloadDecodes == 0 && diagnostics.decodedSessionIDs.isEmpty)
        let report = HistoryBenchmarkReport(recordings: count, pageSize: 50, pages: pages,
            startupMilliseconds: Double(startupMilliseconds.seconds) * 1_000 + Double(startupMilliseconds.attoseconds) / 1e15,
            allPagesMilliseconds: Double(totalDuration.seconds) * 1_000 + Double(totalDuration.attoseconds) / 1e15,
            sourcePayloadDecodes: diagnostics.fullPayloadDecodes)
        Attachment.record(try JSONEncoder().encode(report), named: "lazy-history-thousand-recordings.json")
    }

    @Test("Opening an unchanged valid recording preserves history generation and paging")
    func unchangedSelectionPreservesGeneration() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session(date: Date(timeIntervalSinceReferenceDate: 200))
        try await store.save(session)
        try await store.save(fixture.session(date: Date(timeIntervalSinceReferenceDate: 100)))
        let page = try await store.historyPage(limit: 1)
        let cursor = try #require(page.nextCursor)
        _ = try await store.hydrateSession(session.id)
        let next = try await store.historyPage(limit: 1, before: cursor)
        #expect(!next.invalidated)
        #expect(next.generation == page.generation)
        #expect(next.entries.count == 1)
    }

    @Test("Equal creation dates and duplicate take UUIDs remain stable across keyset pages")
    func stableTiesAndIdentity() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let sameTake = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 456)
        var sessions: [VoiceSession] = []
        for _ in 0..<5 {
            let session = fixture.session(date: date, takeID: sameTake)
            sessions.append(session)
            try await store.save(session)
        }
        var all: [DictationHistoryHeader] = []
        var cursor: DictationHistoryCursor?
        repeat {
            let page = try await store.historyPage(limit: 2, before: cursor)
            all += page.entries
            cursor = page.nextCursor
        } while cursor != nil
        #expect(all.map(\.sessionID) == sessions.map(\.id).sorted { $0.uuidString > $1.uuidString })
        #expect(Set(all.map(\.stableID)).count == 5)
        #expect(Set(all.map(\.id)).count == 1)
    }

    @Test("Title, state and Trash publications invalidate old pages atomically")
    func mutationsInvalidateCursor() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var first = fixture.session(date: Date(timeIntervalSinceReferenceDate: 200))
        let second = fixture.session(date: Date(timeIntervalSinceReferenceDate: 100))
        try await store.save(first)
        try await store.save(second)
        let before = try await store.historyPage(limit: 1)
        let cursor = try #require(before.nextCursor)
        first.title = "Renamed safely"
        first.brief?.takes[0].status = .paused
        first.dictation?.recordings[0].state = .paused
        first.updatedAt = Date()
        try await store.save(first)
        let invalid = try await store.historyPage(limit: 1, before: cursor)
        #expect(invalid.invalidated && invalid.entries.isEmpty && invalid.nextCursor == nil)
        let renamed = try #require(try await store.historyPage(limit: 1).entries.first)
        #expect(renamed.title == "Renamed safely" && renamed.state == .paused)
        first.brief?.takes[0].trashedAt = Date()
        first.updatedAt = Date()
        try await store.save(first)
        let active = try await store.historyPage()
        #expect(active.entries.map(\.sessionID) == [second.id])
    }

    @Test("Header previews remain byte bounded without splitting Unicode graphemes")
    func unicodeHeaderBounds() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session()
        session.title = String(repeating: "👨‍👩‍👧‍👦", count: 160)
        session.dictation?.recordings[0].textRevision?.text = "Safe " + "a" + String(repeating: "\u{301}", count: 2_000)
        try await store.save(session)
        let header = try #require(try await store.historyPage().entries.first)
        #expect(header.title.utf8.count <= 2_048 && header.title.count <= 160)
        #expect(header.title.allSatisfy { $0 == "👨‍👩‍👧‍👦" })
        #expect(header.preview == "Safe " && header.preview.utf8.count <= 1_024)
    }

    @Test("Corrupt old full payloads cannot block new header pages and recover on selection")
    func corruptOldPayloadIsIsolated() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let old = fixture.session(date: Date(timeIntervalSinceReferenceDate: 10))
        let fresh = fixture.session(date: Date(timeIntervalSinceReferenceDate: 20))
        try await store.save(old)
        try await store.save(fresh)
        try fixture.sql("UPDATE sessions SET payload=X'00' WHERE id='\(old.id.uuidString)'")
        let reopened = try SessionStore(root: fixture.root)
        let page = try await reopened.prepareLazyStartup(limit: 1)
        #expect(page.page.entries.first?.sessionID == fresh.id)
        #expect(await reopened.historyQueryDiagnostics().fullPayloadDecodes == 0)
        let hydration = try await reopened.hydrateSession(old.id)
        #expect(hydration.session == old)
        #expect(await reopened.historyQueryDiagnostics().decodedSessionIDs == [old.id])
    }

    @Test("Version 2 migration is atomic and preserves payloads while indexing only dictations")
    func migrationRollbackAndRetry() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        var legacy = VoiceSession()
        legacy.title = "Legacy brief"
        let session = fixture.session()
        try fixture.seedVersionTwo([legacy, session])
        let original = try fixture.blob("SELECT payload FROM sessions WHERE id='\(session.id.uuidString)'")
        try fixture.withConnection { connection in
            let broken = DictationHistoryRepository(connection: connection) { _ in throw HistoryInjectedFailure.interrupted }
            #expect(throws: HistoryInjectedFailure.interrupted) { try broken.migrate() }
            #expect(try fixture.integer("PRAGMA user_version") == 2)
            #expect(try fixture.integer("SELECT count(*) FROM sqlite_master WHERE name='dictation_history'") == 0)
            try DictationHistoryRepository(connection: connection).migrate()
            try DictationHistoryRepository(connection: connection).migrate()
            #expect(try fixture.integer("PRAGMA user_version") == 4)
            let page = try DictationHistoryRepository(connection: connection).page(limit: 50, before: nil)
            #expect(page.entries.map(\.sessionID) == [session.id])
        }
        #expect(try fixture.blob("SELECT payload FROM sessions WHERE id='\(session.id.uuidString)'") == original)
    }

    @Test("Early schema 3 catalogs migrate lazily without trusting incomplete display rows",
          arguments: [false, true])
    func earlyVersionThreeStartup(missingHeader: Bool) async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let session = fixture.session()
        var empty = fixture.session()
        empty.dictation?.recordings = []
        empty.brief?.takes = []
        let store = try SessionStore(root: fixture.root)
        try await store.save(session)
        try await store.save(empty)
        let snapshotURL = try await store.sessionDirectory(session.id).appendingPathComponent("session.json")
        let snapshot = try Data(contentsOf: snapshotURL)
        let payload = try fixture.blob("SELECT payload FROM sessions WHERE id='\(session.id.uuidString)'")
        try fixture.sql("""
            ALTER TABLE dictation_history_checkpoints DROP COLUMN recording_count;
            PRAGMA user_version=3;
            """)
        if missingHeader { try fixture.sql("DELETE FROM dictation_history WHERE session_id='\(session.id.uuidString)'") }
        try fixture.withConnection { connection in
            do {
                _ = try DictationHistoryRepository(connection: connection).pendingRepairCount()
                Issue.record("The historical fixture should reproduce the launch query failure.")
            } catch {
                #expect(error.localizedDescription.contains("no such column: c.recording_count"))
            }
        }

        let reopened = try SessionStore(root: fixture.root)
        let startup = try await reopened.prepareLazyStartup()
        #expect(try fixture.integer("PRAGMA user_version") == 4)
        #expect(startup.totalSessionCount == 2 && startup.pendingRepairCount == 2)
        #expect(startup.page.entries.count == (missingHeader ? 0 : 1))
        #expect(await reopened.historyQueryDiagnostics().fullPayloadDecodes == 0)
        #expect(try fixture.integer("SELECT count(*) FROM dictation_history_checkpoints WHERE recording_count=-1") == 2)
        #expect(try fixture.blob("SELECT payload FROM sessions WHERE id='\(session.id.uuidString)'") == payload)
        #expect(try Data(contentsOf: snapshotURL) == snapshot)

        var expectedMaintenanceRepairs = 2
        if !missingHeader {
            let selected = try await reopened.hydrateSession(session.id)
            #expect(selected.session == session)
            #expect(try await reopened.prepareLazyStartup().pendingRepairCount == 1)
            #expect(await reopened.historyQueryDiagnostics().decodedSessionIDs == [session.id])
            expectedMaintenanceRepairs = 1
        }
        let repaired = try await reopened.maintainHistory()
        #expect(repaired.repairedCount == expectedMaintenanceRepairs && repaired.reports.isEmpty)
        #expect(try await reopened.historyPage().entries.map(\.sessionID) == [session.id])
        #expect(try await reopened.loadSession(session.id) == session)
        #expect(try await reopened.loadSession(empty.id) == empty)
        #expect(try fixture.integer("SELECT recording_count FROM dictation_history_checkpoints WHERE session_id='\(empty.id.uuidString)'") == 0)
        let repeated = try SessionStore(root: fixture.root)
        #expect(try await repeated.prepareLazyStartup().pendingRepairCount == 0)
        #expect(await repeated.historyQueryDiagnostics().fullPayloadDecodes == 0)
    }

    @Test("Early schema 3 count migration rolls back every index change and retries safely")
    func earlyVersionThreeMigrationRollback() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        let payload = try fixture.blob("SELECT payload FROM sessions")
        let generation = try fixture.integer("SELECT value FROM dictation_history_generation")
        try fixture.sql("""
            ALTER TABLE dictation_history_checkpoints DROP COLUMN recording_count;
            INSERT INTO dictation_history_repairs VALUES('\(session.id.uuidString)','Retain this existing repair reason.');
            PRAGMA user_version=3;
            """)
        try fixture.withConnection { connection in
            let interrupted = DictationHistoryRepository(connection: connection) { _ in
                throw HistoryInjectedFailure.interrupted
            }
            #expect(throws: HistoryInjectedFailure.interrupted) { try interrupted.migrate() }
            #expect(try fixture.integer("PRAGMA user_version") == 3)
            #expect(try fixture.integer("SELECT count(*) FROM pragma_table_info('dictation_history_checkpoints') WHERE name='recording_count'") == 0)
            #expect(try fixture.integer("SELECT value FROM dictation_history_generation") == generation)
            let repository = DictationHistoryRepository(connection: connection)
            try repository.migrate()
            #expect(try repository.pendingRepairCount() == 1)
            #expect(try fixture.integer("SELECT count(*) FROM dictation_history_repairs WHERE reason='Retain this existing repair reason.'") == 1)
            #expect(try fixture.integer("SELECT value FROM dictation_history_generation") == generation + 1)
            try repository.migrate()
            #expect(try fixture.integer("SELECT value FROM dictation_history_generation") == generation + 1)
        }
        #expect(try fixture.integer("PRAGMA user_version") == 4)
        #expect(try fixture.blob("SELECT payload FROM sessions") == payload)
    }

    @Test("Schema 3 catalogs that already contain source counts retain their valid index")
    func completeVersionThreeMigration() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        let payload = try fixture.blob("SELECT payload FROM sessions")
        let generation = try fixture.integer("SELECT value FROM dictation_history_generation")
        try fixture.sql("PRAGMA user_version=3")
        let reopened = try SessionStore(root: fixture.root)
        let startup = try await reopened.prepareLazyStartup()
        #expect(try fixture.integer("PRAGMA user_version") == 4)
        #expect(startup.pendingRepairCount == 0 && startup.page.entries.map(\.sessionID) == [session.id])
        #expect(try fixture.integer("SELECT value FROM dictation_history_generation") == generation)
        #expect(try fixture.integer("SELECT recording_count FROM dictation_history_checkpoints") == 1)
        #expect(try fixture.blob("SELECT payload FROM sessions") == payload)
        #expect(await reopened.historyQueryDiagnostics().fullPayloadDecodes == 0)
    }

    @Test("Bounded maintenance exposes and repairs unindexed synchronized snapshots")
    func boundedSnapshotFallbackRepair() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let damaged = fixture.session()
        let jsonOnly = fixture.session()
        try fixture.seedVersionTwo([damaged])
        try fixture.sql("UPDATE sessions SET payload=X'00'")
        for session in [damaged, jsonOnly] {
            let directory = fixture.root.appendingPathComponent("Sessions").appendingPathComponent(session.id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(HistoryCheckpoint(revision: 1, session: session))
                .write(to: directory.appendingPathComponent("session.json"))
        }
        let store = try SessionStore(root: fixture.root)
        let startup = try await store.prepareLazyStartup()
        #expect(startup.page.entries.isEmpty)
        #expect(startup.pendingRepairCount == 1)
        #expect(!startup.reports.isEmpty && startup.maintenanceAvailable)
        #expect(await store.historyQueryDiagnostics().fullPayloadDecodes == 0)
        let first = try await store.maintainHistory(limit: 1)
        #expect(first.inspectedCount == 1 && first.repairedCount == 1)
        let cursor = try #require(first.nextDirectory)
        let second = try await store.maintainHistory(limit: 1, afterDirectory: cursor)
        #expect(second.inspectedCount == 1 && second.repairedCount == 1 && second.nextDirectory == nil)
        #expect(try await store.historyPage().entries.count == 2)
        #expect(try await store.prepareLazyStartup().pendingRepairCount == 0)
        _ = await store.historyQueryDiagnostics(reset: true)
        let unchanged = try await store.maintainHistory()
        #expect(unchanged.repairedCount == 0)
        #expect(await store.historyQueryDiagnostics().fullPayloadDecodes == 0)
    }

    @Test("Capture tails advance live indexed revisions without payload decoding")
    func captureTailUpdatesHeaderAndGeneration() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session(date: Date(timeIntervalSinceReferenceDate: 200))
        session.status = .recording
        session.intervals[0].endedAt = nil
        session.brief?.takes[0].status = .recording
        session.dictation?.recordings[0].state = .recording
        try await store.save(session)
        try await store.save(fixture.session(date: Date(timeIntervalSinceReferenceDate: 100)))
        let first = try await store.historyPage(limit: 1)
        let cursor = try #require(first.nextCursor)
        let segment = try await fixture.audio(store: store, session: session)
        _ = try await store.appendCapturedSegments(sessionID: session.id, segments: [segment], updatedAt: Date())
        _ = await store.historyQueryDiagnostics(reset: true)
        let after = try #require(try await store.historyPage(limit: 1).entries.first)
        #expect(after.revision == 2 && after.state == .recording)
        #expect(try await store.historyPage(limit: 1, before: cursor).invalidated)
        #expect(await store.historyQueryDiagnostics().fullPayloadDecodes == 0)
        let hydrated = try await store.hydrateSession(session.id)
        #expect(hydrated.session.segments == [segment])
        #expect(hydrated.session.status == .interrupted)
        #expect(hydrated.session.dictation?.recordings.first?.state == .paused)
    }

    @Test("Maintenance rebuilds missing or malformed rows even when the snapshot stamp matches",
          arguments: ["missing", "state", "takeIdentity"])
    func malformedIndexRepair(kind: String) async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        if kind == "missing" { try fixture.sql("DELETE FROM dictation_history") }
        else if kind == "takeIdentity" { try fixture.sql("UPDATE dictation_history SET take_id='corrupt'") }
        else { try fixture.sql("UPDATE dictation_history SET state='corrupt'") }
        #expect(try await store.prepareLazyStartup().pendingRepairCount == 1)
        let result = try await store.maintainHistory()
        #expect(result.repairedCount == 1)
        #expect(try await store.historyPage().entries.first?.sessionID == session.id)
    }

    @Test("Blocked audio publication cannot hydrate an editable recording")
    func blockedPublicationDeniesHydration() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        let stage = try await store.sessionDirectory(session.id).appendingPathComponent(".recording-edit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let journal = stage.appendingPathComponent("publication.json")
        try Data("corrupt publication".utf8).write(to: journal)
        await #expect(throws: (any Error).self) { try await store.hydrateSession(session.id) }
        #expect(FileManager.default.fileExists(atPath: journal.path))
        #expect(try await store.loadSessions() == [session])
    }

    @Test("Archive collision checks do not hydrate evicted sessions or ignore orphan folders")
    func collisionChecksAreLazy() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        let orphan = UUID()
        _ = try await store.sessionDirectory(orphan)
        _ = await store.historyQueryDiagnostics(reset: true)
        #expect(try await store.containsSession(session.id))
        #expect(try await store.containsSession(orphan))
        #expect(try await store.containsSession(UUID()) == false)
        #expect(await store.historyQueryDiagnostics().fullPayloadDecodes == 0)
        #expect(try await store.loadSession(session.id) == session)
        #expect(await store.historyQueryDiagnostics().decodedSessionIDs == [session.id])
    }

    @Test("Cancelled selection preserves checkpoints and never creates missing-audio gaps")
    func cancelledHydrationIsNotRecoveryFailure() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session()
        try await store.save(session)
        let before = try fixture.blob("SELECT payload FROM sessions")
        let stream = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream.stream {}
            return try await store.hydrateSession(session.id)
        }
        task.cancel()
        stream.continuation.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.blob("SELECT payload FROM sessions") == before)
    }
}

private struct HistoryBenchmarkReport: Codable {
    let recordings: Int
    let pageSize: Int
    let pages: Int
    let startupMilliseconds: Double
    let allPagesMilliseconds: Double
    let sourcePayloadDecodes: Int
}

private enum HistoryInjectedFailure: Error { case interrupted }
private struct HistoryCheckpoint: Codable {
    var version = 1
    var revision: Int64
    var session: VoiceSession
}

private struct HistoryFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-LazyHistory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func session(date: Date = Date(), takeID: UUID = UUID()) -> VoiceSession {
        var session = VoiceSession()
        session.title = "Saved local dictation"
        let interval = CaptureInterval(startedAt: date, endedAt: date, sampleRate: 16_000, channelCount: 1)
        session.intervals = [interval]
        var brief = BriefDocument()
        brief.takes = [BriefTake(id: takeID, intervalID: interval.id, expectedRevision: brief.revisionID, createdAt: date)]
        session.brief = brief
        session.dictation = DictationSession(recordings: [
            DictationRecordingMetadata(id: takeID, state: .ready,
                textRevision: DictationTextRevision(rawText: "A local recording.", text: String(repeating: "A local recording. ", count: 10),
                    sourceTranscriptIDs: []), createdAt: date, updatedAt: date)])
        return session
    }
    func audio(store: SessionStore, session: VoiceSession) async throws -> AudioSegment {
        let directory = try await store.audioDirectory(session.id)
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString + ".caf")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 160)
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        try audio.write(from: buffer)
        audio.close()
        let segment = AudioSegment(id: id, intervalID: session.intervals[0].id, fileName: url.lastPathComponent,
            startTime: 0, frameCount: 160, sampleRate: 16_000, channelCount: 1, sha256: try SessionStore.checksum(url))
        try JSONEncoder().encode(segment).write(to: directory.appendingPathComponent(id.uuidString + ".json"))
        return segment
    }
    func withConnection<T>(_ action: (OpaquePointer) throws -> T) throws -> T {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite").path, &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let connection else {
            throw KeystormError.message("Could not open history fixture.")
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5_000)
        return try action(connection)
    }
    func sql(_ sql: String) throws {
        try withConnection { connection in
            guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw KeystormError.message(String(cString: sqlite3_errmsg(connection))) }
        }
    }
    func integer(_ sql: String) throws -> Int64 {
        try withConnection { connection in
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &query, nil) == SQLITE_OK, let query else { throw KeystormError.message("Invalid test SQL.") }
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { throw KeystormError.message("Missing history test row.") }
            return sqlite3_column_int64(query, 0)
        }
    }
    func blob(_ sql: String) throws -> Data {
        try withConnection { connection in
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &query, nil) == SQLITE_OK, let query else { throw KeystormError.message("Invalid test SQL.") }
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW, let pointer = sqlite3_column_blob(query, 0) else { throw KeystormError.message("Missing test payload.") }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(query, 0)))
        }
    }
    func seedVersionTwo(_ sessions: [VoiceSession]) throws {
        try sql("""
            CREATE TABLE sessions(id TEXT PRIMARY KEY NOT NULL,revision INTEGER NOT NULL,payload BLOB NOT NULL);
            CREATE TABLE metadata(key TEXT PRIMARY KEY NOT NULL,payload BLOB NOT NULL);
            PRAGMA user_version=1;
            """)
        try withConnection { connection in
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for session in sessions {
                var query: OpaquePointer?
                guard sqlite3_prepare_v2(connection, "INSERT INTO sessions VALUES(?,1,?)", -1, &query, nil) == SQLITE_OK, let query else {
                    throw KeystormError.message("Invalid fixture insert.")
                }
                defer { sqlite3_finalize(query) }
                _ = sqlite3_bind_text(query, 1, session.id.uuidString, -1, transient)
                let payload = try JSONEncoder().encode(session)
                _ = payload.withUnsafeBytes { sqlite3_bind_blob(query, 2, $0.baseAddress, Int32($0.count), transient) }
                guard sqlite3_step(query) == SQLITE_DONE else { throw KeystormError.message("Fixture insert failed.") }
            }
            try IncrementalSessionJournal(connection: connection).migrate()
        }
    }
}
