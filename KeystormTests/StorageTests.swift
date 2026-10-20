import Foundation
import Testing
import SQLite3
import AVFoundation
@testable import Keystorm

struct StorageTests {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixtureSegment(store: SessionStore, sessionID: UUID, start: Double = 0) async throws -> AudioSegment {
        let id = UUID()
        let directory = try await store.audioDirectory(sessionID)
        let url = directory.appendingPathComponent("\(id.uuidString).caf")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000))
        buffer.frameLength = 80_000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 80_000)
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        try audio.write(from: buffer)
        audio.close()
        let segment = AudioSegment(id: id, intervalID: UUID(), fileName: url.lastPathComponent, startTime: start, frameCount: 80_000, sampleRate: 16_000, channelCount: 1, sha256: try SessionStore.checksum(url))
        try JSONEncoder().encode(segment).write(to: directory.appendingPathComponent("\(id.uuidString).json"))
        return segment
    }

    @Test func `Session and dictionary survive reopening`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.title = "Technical dictation"
        let segment = try await fixtureSegment(store: store, sessionID: session.id)
        session.segments = [segment]
        session.transcripts = [TranscriptRevision(rawText: "Use 256, not 512.", text: "Use 256, not 512.", segmentIDs: [segment.id])]
        try await store.save(session)
        let dictionary = [DictionaryEntry(canonical: "Keystorm", aliases: ["key storm"], automatic: true)]
        try await store.saveDictionary(dictionary)
        let reopened = try SessionStore(root: root)
        #expect(try await reopened.loadSessions() == [session])
        #expect(try await reopened.loadDictionary() == dictionary)
    }

    @Test func `Newer synchronized snapshot wins over stale catalog and is reconciled`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let session = VoiceSession()
        try await store.save(session)
        let snapshotURL = try await store.sessionDirectory(session.id).appendingPathComponent("session.json")
        var snapshot = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any])
        snapshot["revision"] = 2
        var payload = try #require(snapshot["session"] as? [String: Any])
        payload["title"] = "Saved before SQLite commit"
        snapshot["session"] = payload
        try JSONSerialization.data(withJSONObject: snapshot).write(to: snapshotURL, options: .atomic)
        _ = try await store.recover()
        // Remove snapshot to prove reconciliation reached SQLite, rather than just reading JSON again.
        try FileManager.default.removeItem(at: snapshotURL)
        let reopened = try SessionStore(root: root)
        #expect(try await reopened.loadSessions().first?.title == "Saved before SQLite commit")
    }

    @Test func `Newer catalog wins over stale or corrupt snapshot`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        try await store.save(session)
        let url = try await store.sessionDirectory(session.id).appendingPathComponent("session.json")
        let older = try Data(contentsOf: url)
        session.title = "Latest committed title"
        try await store.save(session)
        try older.write(to: url)
        #expect(try await store.loadSessions().first?.title == session.title)
        try Data("interrupted JSON write".utf8).write(to: url)
        let reports = try await store.recover()
        #expect(reports.contains { $0.contains("could not be read") })
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(restored != nil)
        #expect(try await store.loadSessions().first?.title == session.title)
    }

    @Test func `Snapshot-only backup rebuilds a missing catalog`() async throws {
        let root = try temporaryRoot()
        let restoredRoot = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: restoredRoot) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.segments = [try await fixtureSegment(store: store, sessionID: session.id)]
        try await store.save(session)
        try FileManager.default.copyItem(at: root.appendingPathComponent("Sessions"), to: restoredRoot.appendingPathComponent("Sessions"))
        let restored = try SessionStore(root: restoredRoot)
        _ = try await restored.recover()
        let recovered = try #require(try await restored.loadSessions().first)
        #expect(recovered.segments == session.segments)
        #expect(recovered.title == session.title)
        #expect(recovered.intervals.count == 1)
        #expect(recovered.intervals[0].endedAt! >= recovered.intervals[0].startedAt)
    }

    @Test func `Interrupted recording and jobs remain visibly incomplete`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.status = .recording
        session.intervals = [CaptureInterval()]
        session.jobs = [ProcessingJob(stage: .transcription, status: .running, completedUnits: 2, totalUnits: 5)]
        try await store.save(session)
        let reports = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.status == .interrupted)
        #expect(recovered.intervals.first?.endedAt != nil)
        #expect(recovered.jobs.first?.status == .incomplete)
        #expect(recovered.jobs.first?.completedUnits == 2)
        #expect(!recovered.gaps.isEmpty)
        #expect(reports.contains { $0.contains("needs retry") })
        _ = try await store.recover()
        #expect(try await store.loadSessions().first?.gaps.count == recovered.gaps.count)
    }

    @Test(arguments: [false, true]) func `Missing and corrupted audio are retained as explicit gaps`(corrupt: Bool) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        let segment = try await fixtureSegment(store: store, sessionID: session.id)
        session.segments = [segment]
        session.transcripts = [TranscriptRevision(rawText: "Audio source", text: "Audio source", segmentIDs: [segment.id], endTime: 5)]
        try await store.save(session)
        let url = try await store.audioURL(for: segment, in: session.id)
        if corrupt { try Data("modified audio".utf8).write(to: url) }
        else { try FileManager.default.removeItem(at: url) }
        _ = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.segments == [segment])
        #expect(recovered.unavailableSegmentIDs == [segment.id])
        #expect(recovered.savedThrough == 0)
        #expect(recovered.transcribedThrough == 0)
        #expect(recovered.gaps.contains { $0.reason.contains(corrupt ? "checksum mismatch" : "File is missing") })
    }

    @Test func `Durable audio sidecar closes the file versus catalog crash window`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let session = VoiceSession()
        try await store.save(session)
        let segment = try await fixtureSegment(store: store, sessionID: session.id)
        let reports = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.segments == [segment])
        #expect(recovered.savedThrough == 5)
        #expect(reports.contains { $0.contains("durable orphan") })
        _ = try await store.recover()
        #expect(try await store.loadSessions().first?.segments.count == 1)
    }

    @Test func `Unfinished tails remain visible and are never acknowledged`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let session = VoiceSession()
        try await store.save(session)
        let directory = try await store.audioDirectory(session.id)
        let partial = directory.appendingPathComponent("\(UUID().uuidString).partial.caf")
        try Data("unfinished bytes".utf8).write(to: partial)
        _ = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.segments.isEmpty)
        #expect(recovered.savedThrough == 0)
        #expect(recovered.gaps.contains { $0.reason.contains("Incomplete audio tail") })
        #expect(FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func `Audio traversal and symlink escapes are rejected`() async throws {
        let root = try temporaryRoot()
        let outside = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let store = try SessionStore(root: root)
        let id = UUID()
        var segment = AudioSegment(intervalID: UUID(), fileName: "../outside.caf", startTime: 0, frameCount: 1, sampleRate: 1, channelCount: 1, sha256: String(repeating: "0", count: 64))
        await #expect(throws: (any Error).self) { try await store.audioURL(for: segment, in: id) }
        segment.fileName = "\(segment.id.uuidString).caf"
        let audio = try await store.audioDirectory(id)
        try FileManager.default.createSymbolicLink(at: audio.appendingPathComponent(segment.fileName), withDestinationURL: outside.appendingPathComponent("outside.caf"))
        // Reject both dangling and live symlinks; Foundation canonicalization may leave a dangling link unchanged.
        await #expect(throws: (any Error).self) { try await store.audioURL(for: segment, in: id) }
        try Data("external file".utf8).write(to: outside.appendingPathComponent("outside.caf"))
        await #expect(throws: (any Error).self) { try await store.audioURL(for: segment, in: id) }
    }

    @Test func `Original transcript revisions cannot be rewritten`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.transcripts = [TranscriptRevision(rawText: "Do not use 512.", text: "Do not use 512.")]
        try await store.save(session)
        session.transcripts[0].rawText = "Use 512."
        await #expect(throws: (any Error).self) { try await store.save(session) }
        #expect(try await store.loadSessions().first?.transcripts.first?.rawText == "Do not use 512.")
    }

    @Test func `Orphan metadata cannot invent duration or overlapping coverage`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.segments = [try await fixtureSegment(store: store, sessionID: session.id)]
        try await store.save(session)
        let overlap = try await fixtureSegment(store: store, sessionID: session.id, start: 2)
        var wrongHeader = try await fixtureSegment(store: store, sessionID: session.id, start: 10)
        wrongHeader.frameCount = 160_000
        let sidecar = try await store.audioDirectory(session.id).appendingPathComponent("\(wrongHeader.id.uuidString).json")
        try JSONEncoder().encode(wrongHeader).write(to: sidecar)
        let reports = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.segments == session.segments)
        #expect(!recovered.segments.contains { $0.id == overlap.id || $0.id == wrongHeader.id })
        #expect(reports.contains { $0.contains("overlaps") })
        #expect(reports.contains { $0.contains("header does not match") })
    }

    @Test func `Recovered open interval uses its own orphan coverage`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.status = .recording
        let interval = CaptureInterval(startedAt: Date().addingTimeInterval(-10))
        session.intervals = [interval]
        try await store.save(session)
        var segment = try await fixtureSegment(store: store, sessionID: session.id)
        segment.intervalID = interval.id
        let sidecar = try await store.audioDirectory(session.id).appendingPathComponent("\(segment.id.uuidString).json")
        try JSONEncoder().encode(segment).write(to: sidecar)
        _ = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.intervals.first?.endedAt == segment.committedAt)
        #expect(recovered.intervals.first?.startedAt == interval.startedAt)
    }

    @Test func `Unknown catalog schema is refused without downgrading`() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var connection: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &connection) == SQLITE_OK)
        #expect(sqlite3_exec(connection, "PRAGMA user_version=999", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(connection)
        #expect(throws: (any Error).self) { try SessionStore(root: root) }
    }
}
