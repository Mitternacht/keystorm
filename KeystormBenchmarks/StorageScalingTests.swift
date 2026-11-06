import Foundation
import SQLite3
import Testing
@testable import Keystorm

/// Opt-in Release metadata workloads. Run each duration separately for isolated timings.
@MainActor
@Suite(.serialized, .exclusiveBenchmarkUse)
struct StorageScalingTests {
    @Test("Ninety-minute transcript storage and restart scaling",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_STORAGE_SCALING"] == "1"),
          .timeLimit(.minutes(5)))
    func ninetyMinuteTranscriptStorageScaling() async throws {
        try await measureLongTranscriptStorage(minutes: 90)
    }

    @Test("Two-hour transcript storage and restart scaling",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_STORAGE_SCALING"] == "1"),
          .timeLimit(.minutes(5)))
    func twoHourTranscriptStorageScaling() async throws {
        try await measureLongTranscriptStorage(minutes: 120)
    }

    @Test("Eight-hour transcript storage and restart scaling",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_STORAGE_SCALING"] == "1"),
          .timeLimit(.minutes(5)))
    func eightHourTranscriptStorageScaling() async throws {
        try await measureLongTranscriptStorage(minutes: 480)
    }

    private func measureLongTranscriptStorage(minutes: Int) async throws {
        #if DEBUG
        let buildConfiguration = "Debug"
        #else
        let buildConfiguration = "Release"
        #endif
        try #require(buildConfiguration == "Release", "Storage timings require a true Release build.")
        try #require(AppLifecycle.bootstrap?.isReady != true,
            "The global app workspace must not initialize inside the benchmark host.")
        let began = ContinuousClock.now
        let runID = UUID().uuidString
        let outputDirectory = ProcessInfo.processInfo.environment["KEYSTORM_STORAGE_SCALING_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-StorageScalingReports", isDirectory: true)
        let outputURL = outputDirectory.appendingPathComponent("long-transcript-\(minutes)-minutes-\(runID).json")
        var progress: [String: String] = [
            "schemaVersion": "1", "runID": runID, "buildConfiguration": buildConfiguration,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "simulatedMinutes": String(minutes), "completedJobUpdates": "0", "complete": "false",
            "reportPath": outputURL.path
        ]
        func persistProgress(_ phase: String) throws {
            progress["phase"] = phase
            progress["elapsedWorkMilliseconds"] = String(storageScalingMilliseconds(began))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try encoder.encode(progress).write(to: outputURL, options: .atomic)
        }
        try persistProgress("preparingCheckpoint")
        print("LONG_TRANSCRIPT_SCALING_REPORT " + outputURL.path)
        let fixture = try StorageScalingFixture()
        var session = storageScalingSession()
        let count = minutes * 60 / 5
        session.segments = (0..<count).map {
            storageScalingSegment(intervalID: session.intervals[0].id, start: Double($0 * 5))
        }
        // Metadata-only backlog: each five-second source is already checkpointed.
        // No CAF allocation or microphone/inference is included in these timings.
        try fixture.seed(session)
        let checkpoint = try fixture.data("SELECT payload FROM sessions")
        let store = try SessionStore(root: fixture.root)
        let memoryBefore = LocalInference.processFootprint()
        var memoryPeak = memoryBefore
        var writes: [Double] = []
        try persistProgress("writingTranscription")
        let writeStart = ContinuousClock.now
        for index in 0..<count {
            let audio = session.segments[index]
            session.jobs.append(ProcessingJob(stage: .transcription, status: .running,
                inputIDs: [audio.id], totalUnits: 1))
            session.updatedAt = session.createdAt.addingTimeInterval(Double(index * 5))
            let startJob = ContinuousClock.now
            try await store.saveTranscriptionUpdate(session)
            writes.append(storageScalingMilliseconds(startJob))
            let words = "Passage \(index): keep every original word and its source recording."
            let transcript = TranscriptRevision(rawText: words, text: words,
                segmentIDs: [audio.id], startTime: audio.startTime, endTime: audio.endTime)
            session.transcripts.append(transcript)
            session.jobs[index].status = .completed
            session.jobs[index].completedUnits = 1
            session.brief?.takes[0].transcriptIDs.append(transcript.id)
            session.brief?.reviewedRevisionID = nil
            session.invalidateDerivedWork()
            session.updatedAt = session.createdAt.addingTimeInterval(Double(index * 5 + 1))
            let finishJob = ContinuousClock.now
            try await store.saveTranscriptionUpdate(session)
            writes.append(storageScalingMilliseconds(finishJob))
            if index.isMultiple(of: 128) {
                memoryPeak = max(memoryPeak, LocalInference.processFootprint())
                progress["completedJobUpdates"] = String(writes.count)
                progress["writeElapsedMilliseconds"] = String(storageScalingMilliseconds(writeStart))
                try persistProgress("writingTranscription")
            }
        }
        let writeMilliseconds = storageScalingMilliseconds(writeStart)
        try #require(try fixture.data("SELECT payload FROM sessions") == checkpoint)
        try #require(try fixture.integer("SELECT count(*) FROM session_capture_journal") == Int64(count * 2))
        try #require(session.transcripts.count == count)
        try #require(session.recordedDuration == Double(minutes * 60))
        progress["completedJobUpdates"] = String(writes.count)
        progress["writeTotalMilliseconds"] = String(writeMilliseconds)
        try persistProgress("reopening")
        var reopens: [Double] = []
        for _ in 0..<3 {
            let reopened = try SessionStore(root: fixture.root)
            let start = ContinuousClock.now
            let recovered = try await reopened.loadSession(session.id)
            reopens.append(storageScalingMilliseconds(start))
            try #require(recovered == session)
            progress["completedReopens"] = String(reopens.count)
            progress["indexedReopenMilliseconds"] = reopens.map { String($0) }.joined(separator: ",")
            try persistProgress("reopening")
        }
        // Same durable journal, rebuilding validation indexes for every record:
        // a correctness reference and explicit comparison for the removed hot path.
        let journal = IncrementalSessionJournal(connection: fixture.connection)
        var reference = try JSONDecoder().decode(VoiceSession.self, from: checkpoint)
        var revision: Int64 = 1
        try persistProgress("referenceReplay")
        let referenceStart = ContinuousClock.now
        while true {
            let page = try journal.deltas(sessionID: session.id, afterRevision: revision)
            if page.isEmpty { break }
            for delta in page {
                try IncrementalSessionJournal.apply(delta, to: &reference, afterRevision: revision)
                revision = delta.revision
            }
            progress["referenceRevision"] = String(revision)
            try persistProgress("referenceReplay")
        }
        let referenceMilliseconds = storageScalingMilliseconds(referenceStart)
        try #require(reference == session)
        try #require(revision == Int64(count * 2 + 1))
        memoryPeak = max(memoryPeak, LocalInference.processFootprint())
        func mean(_ values: ArraySlice<Double>) -> Double { values.reduce(0, +) / Double(values.count) }
        let report: [String: String] = [
            "buildConfiguration": buildConfiguration,
            "simulatedMinutes": String(minutes), "segments": String(count),
            "transcripts": String(session.transcripts.count), "jobUpdates": String(writes.count),
            "writeTotalMilliseconds": String(writeMilliseconds),
            "first100WriteMeanMilliseconds": String(mean(writes.prefix(100))),
            "last100WriteMeanMilliseconds": String(mean(writes.suffix(100))),
            "indexedReopenMilliseconds": reopens.map(String.init(describing:)).joined(separator: ","),
            "rebuildIndexesPerDeltaReplayMilliseconds": String(referenceMilliseconds),
            "journalPayloadBytes": String(try fixture.integer("SELECT SUM(length(payload)) FROM session_capture_journal")),
            "processFootprintBeforeBytes": String(memoryBefore), "sampledProcessFootprintPeakBytes": String(memoryPeak),
            "exactReopen": "true",
            "scope": "Synthetic metadata-only transcription backlog; checkpointed five-second sources, real SessionStore writes and SQLite WAL/FULL recovery, growing jobs/transcripts/brief references. No audio allocation, live microphone, UI, model inference, thermal or battery qualification. Process footprint includes the test host and retained comparison fixtures; not isolated app memory. Timing is observational. Periodic progress-report writes are included in aggregate wall times but excluded from individual production write/reopen timings."
        ]
        progress.merge(report) { _, newest in newest }
        progress["complete"] = "true"
        try persistProgress("complete")
        let data = try Data(contentsOf: outputURL)
        Attachment.record(data, named: "long-transcript-\(minutes)-minutes.json")
        print("LONG_TRANSCRIPT_SCALING " + String(decoding: data, as: UTF8.self))
    }

}

private func storageScalingSession() -> VoiceSession {
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

private func storageScalingSegment(intervalID: UUID, start: Double) -> AudioSegment {
    let id = UUID()
    return AudioSegment(id: id, intervalID: intervalID, fileName: id.uuidString + ".caf",
        startTime: start, frameCount: 80_000, sampleRate: 16_000, channelCount: 1,
        sha256: String(repeating: "a", count: 64))
}

private func storageScalingMilliseconds(_ start: ContinuousClock.Instant) -> Double {
    let value = start.duration(to: .now).components
    return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
}

private final class StorageScalingFixture {
    let root: URL
    let connection: OpaquePointer

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-StorageScaling-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite").path, &pointer,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let pointer else { throw StorageScalingFailure.database }
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

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw StorageScalingFailure.database
        }
    }

    func seed(_ session: VoiceSession) throws {
        let data = try JSONEncoder().encode(session)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "INSERT INTO sessions(id,revision,payload) VALUES(?,1,?)",
                                -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StorageScalingFailure.database
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, session.id.uuidString, -1, transient) == SQLITE_OK,
              data.withUnsafeBytes({ sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw StorageScalingFailure.database }
    }

    func integer(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StorageScalingFailure.database
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StorageScalingFailure.database }
        return sqlite3_column_int64(statement, 0)
    }

    func data(_ sql: String) throws -> Data {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StorageScalingFailure.database
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
            throw StorageScalingFailure.database
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }
}

private enum StorageScalingFailure: Error { case database }
