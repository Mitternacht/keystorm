import AVFoundation
import Foundation
import SQLite3
import Testing
@testable import Keystorm

/// Every store and workspace here uses a temporary root: no microphone, models, Accessibility objects,
/// shared pasteboard or the real Application Support folder.
@MainActor
struct DictationHistoryDeletionTests {
    // MARK: Store deletion

    @Test("Deleting a session removes its folder, audio, catalog rows and index rows, and nothing else")
    func deleteRemovesOneSessionCompletely() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var doomed = fixture.session(text: "The doomed dictation.", date: Date(timeIntervalSinceReferenceDate: 100))
        let segment = try await fixture.addAudio(to: &doomed, store: store)
        try await store.save(doomed)
        var kept = fixture.session(text: "The kept dictation.", date: Date(timeIntervalSinceReferenceDate: 200))
        let keptSegment = try await fixture.addAudio(to: &kept, store: store)
        try await store.save(kept)
        let doomedAudio = try await store.audioDirectory(doomed.id).appendingPathComponent(segment.fileName)
        #expect(FileManager.default.fileExists(atPath: doomedAudio.path))
        #expect(try await store.historyPage(limit: 10).entries.count == 2)

        try await store.deleteSession(doomed.id)

        #expect(!FileManager.default.fileExists(atPath: fixture.sessionFolder(doomed.id).path))
        #expect(!FileManager.default.fileExists(atPath: doomedAudio.path))
        #expect(try fixture.count("SELECT count(*) FROM sessions WHERE id='\(doomed.id.uuidString)'") == 0)
        for table in ["dictation_history", "dictation_history_search", "dictation_history_checkpoints", "session_history_headers"] {
            #expect(try fixture.count("SELECT count(*) FROM \(table) WHERE session_id='\(doomed.id.uuidString)'") == 0)
        }
        #expect(try fixture.count("SELECT count(*) FROM session_capture_journal WHERE session_id='\(doomed.id.uuidString)'") == 0)
        // Nothing was left in the graveyard either.
        let graveyard = fixture.root.appendingPathComponent(".pending-deletion")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: graveyard.path))?.isEmpty ?? true)

        let page = try await store.historyPage(limit: 10)
        #expect(page.entries.map(\.sessionID) == [kept.id])
        #expect(try await store.containsSession(doomed.id) == false)
        #expect(try await store.loadSession(kept.id)?.dictation?.recordings.first?.textRevision?.text ==
            kept.dictation?.recordings.first?.textRevision?.text)
        let keptAudio = try await store.audioDirectory(kept.id).appendingPathComponent(keptSegment.fileName)
        #expect(FileManager.default.fileExists(atPath: keptAudio.path))
    }

    @Test("A deleted session is not revived by library maintenance, recovery or a reopened store")
    func deletedSessionStaysDeleted() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var doomed = fixture.session(text: "Gone for good.")
        _ = try await fixture.addAudio(to: &doomed, store: store)
        try await store.save(doomed)
        let survivor = fixture.session(text: "Still here.")
        try await store.save(survivor)

        try await store.deleteSession(doomed.id)
        let maintenance = try await store.maintainHistory(limit: 16)
        #expect(maintenance.repairedCount == 0 && maintenance.reports.isEmpty)
        _ = try await store.recover()
        // Reading a session creates its folder, so these checks come before any load by identity.
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionFolder(doomed.id).path))
        #expect(try await store.containsSession(doomed.id) == false)

        let reopened = try SessionStore(root: fixture.root)
        for candidate in [store, reopened] {
            #expect(try await candidate.historyPage(limit: 10).entries.map(\.sessionID) == [survivor.id])
            #expect(try await candidate.prepareLazyStartup().totalSessionCount == 1)
        }
        #expect(try await reopened.containsSession(doomed.id) == false)
    }

    @Test("Deleting a session that does not exist, or twice, is harmless")
    func deleteIsIdempotent() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let session = fixture.session(text: "Only one.")
        try await store.save(session)
        try await store.deleteSession(UUID())
        try await store.deleteSession(session.id)
        try await store.deleteSession(session.id)
        #expect(try await store.historyPage(limit: 10).entries.isEmpty)
    }

    @Test("Deleting invalidates an open history cursor so a stale page is never served")
    func deleteInvalidatesCursors() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let first = fixture.session(text: "One", date: Date(timeIntervalSinceReferenceDate: 300))
        let second = fixture.session(text: "Two", date: Date(timeIntervalSinceReferenceDate: 200))
        try await store.save(first)
        try await store.save(second)
        let page = try await store.historyPage(limit: 1)
        let cursor = try #require(page.nextCursor)
        try await store.deleteSession(second.id)
        #expect(try await store.historyPage(limit: 1, before: cursor).invalidated)
    }

    // MARK: Search

    @Test("Search finds titles and full transcripts, ignoring case and diacritics")
    func searchFoldsCaseAndDiacritics() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let late = String(repeating: "Filler words go here. ", count: 40) + "Der Übergang ist wichtig."
        let german = fixture.session(text: late, title: "Besprechung", date: Date(timeIntervalSinceReferenceDate: 100))
        let english = fixture.session(text: "Send the quarterly report.", title: "Dictation · Oct 3", date: Date(timeIntervalSinceReferenceDate: 200))
        try await store.save(german)
        try await store.save(english)

        // The match sits far beyond the 100-character preview.
        #expect(german.dictation?.recordings.first?.textRevision?.text.count ?? 0 > 100)
        #expect(try await store.searchHistory("ubergang").map(\.sessionID) == [german.id])
        #expect(try await store.searchHistory("ÜBERGANG").map(\.sessionID) == [german.id])
        #expect(try await store.searchHistory("  QUARTERLY ").map(\.sessionID) == [english.id])
        #expect(try await store.searchHistory("besprechung").map(\.sessionID) == [german.id])
        #expect(try await store.searchHistory("oct 3").map(\.sessionID) == [english.id])
        #expect(try await store.searchHistory("nothing like this").isEmpty)
        #expect(try await store.searchHistory("   ").isEmpty)
        // A one-letter query matches both sessions, newest first.
        #expect(try await store.searchHistory("e").map(\.sessionID) == [english.id, german.id])
    }

    @Test("Search treats percent and underscore literally and drops deleted sessions")
    func searchEscapesWildcardsAndForgetsDeleted() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let percent = fixture.session(text: "Revenue grew 100% this year.", date: Date(timeIntervalSinceReferenceDate: 100))
        let plain = fixture.session(text: "Revenue grew 1000 this year.", date: Date(timeIntervalSinceReferenceDate: 200))
        let underscore = fixture.session(text: "Call snake_case names.", date: Date(timeIntervalSinceReferenceDate: 300))
        let other = fixture.session(text: "Call snakeXcase names.", date: Date(timeIntervalSinceReferenceDate: 400))
        for session in [percent, plain, underscore, other] { try await store.save(session) }
        #expect(try await store.searchHistory("100%").map(\.sessionID) == [percent.id])
        #expect(try await store.searchHistory("snake_case").map(\.sessionID) == [underscore.id])

        try await store.deleteSession(percent.id)
        #expect(try await store.searchHistory("100%").isEmpty)
        #expect(try await store.searchHistory("revenue").map(\.sessionID) == [plain.id])
    }

    // MARK: Audio discard

    @Test("Discarding audio keeps the transcript and history entry, and recovery then changes nothing")
    func discardAudioKeepsText() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session(text: "Keep these words.")
        let segment = try await fixture.addAudio(to: &session, store: store)
        try await store.save(session)
        let audioURL = try await store.audioDirectory(session.id).appendingPathComponent(segment.fileName)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))

        let updated = try #require(try await store.discardAudio(sessionID: session.id))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: audioURL.deletingLastPathComponent().path)
        #expect(remaining.isEmpty)
        #expect(updated.unavailableSegmentIDs == [segment.id])
        #expect(updated.segments == [segment])
        #expect(updated.dictation?.recordings.first?.textRevision?.text == "Keep these words.")
        #expect(try await store.historyPage(limit: 10).entries.first?.preview == "Keep these words.")

        // Opening the recording later re-checks the audio. It finds exactly what was recorded.
        let hydrated = try await store.hydrateSession(session.id)
        #expect(hydrated.session.unavailableSegmentIDs == [segment.id])
        #expect(hydrated.session.gaps.count == updated.gaps.count)
        #expect(hydrated.session.dictation?.recordings.first?.textRevision?.text == "Keep these words.")
        let again = try await store.hydrateSession(session.id)
        #expect(again.session.gaps.count == updated.gaps.count)

        // Nothing is left to discard.
        #expect(try await store.discardAudio(sessionID: session.id) == nil)
    }

    @Test("Audio of a recording that is not finished is never discarded")
    func discardRefusesUnfinishedDictations() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var session = fixture.session(text: "Still going.", state: .paused)
        let segment = try await fixture.addAudio(to: &session, store: store)
        try await store.save(session)
        #expect(try await store.discardAudio(sessionID: session.id) == nil)
        let audioURL = try await store.audioDirectory(session.id).appendingPathComponent(segment.fileName)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(try await store.discardAudio(sessionID: UUID()) == nil)
    }

    // MARK: Retention queries

    @Test("Retention lists only finished sessions older than the cutoff")
    func retentionQueries() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        let now = Date()
        let day: TimeInterval = 86_400
        let oldReady = fixture.session(text: "Old and ready.", date: now.addingTimeInterval(-40 * day))
        let oldFailed = fixture.session(text: "Old and failed.", date: now.addingTimeInterval(-41 * day), state: .failed)
        let oldPaused = fixture.session(text: "Old and paused.", date: now.addingTimeInterval(-42 * day), state: .paused)
        let oldProcessing = fixture.session(text: "Old and processing.", date: now.addingTimeInterval(-43 * day), state: .processing)
        let recent = fixture.session(text: "Recent.", date: now.addingTimeInterval(-1 * day))
        for session in [oldReady, oldFailed, oldPaused, oldProcessing, recent] { try await store.save(session) }

        let cutoff = now.addingTimeInterval(-30 * day)
        let deletable = try await store.finishedDictationSessionIDs(newestBefore: cutoff)
        #expect(Set(deletable) == [oldReady.id, oldFailed.id])
        let audioOnly = try await store.finishedDictationSessionIDs(newestBefore: cutoff, readyOnly: true)
        #expect(audioOnly == [oldReady.id])
        #expect(try await store.finishedDictationSessionIDs(newestBefore: now.addingTimeInterval(-60 * day)).isEmpty)
        #expect(Set(try await store.dictationSessionIDs()) == [oldReady.id, oldFailed.id, oldPaused.id, oldProcessing.id, recent.id])
    }

    @Test("Developer briefs are never listed as dictations")
    func dictationListIgnoresBriefs() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let store = try SessionStore(root: fixture.root)
        var brief = fixture.session(text: "A developer brief.")
        brief.dictation = nil
        let dictation = fixture.session(text: "A dictation.")
        try await store.save(brief)
        try await store.save(dictation)
        #expect(try await store.dictationSessionIDs() == [dictation.id])
        #expect(try await store.finishedDictationSessionIDs(newestBefore: Date().addingTimeInterval(86_400)) == [dictation.id])
    }

    // MARK: Workspace

    @Test("Workspace deletion skips what is in use, forgets what it deleted and keeps everything else")
    func workspaceDeletionIsSafe() async throws {
        try await withWorkspace(sessions: { fixture in
            [fixture.session(text: "Zero", date: Date(timeIntervalSinceReferenceDate: 300)),
             fixture.session(text: "One", date: Date(timeIntervalSinceReferenceDate: 200)),
             fixture.session(text: "Two", date: Date(timeIntervalSinceReferenceDate: 100))]
        }) { fixture, model, sessions, store in
            #expect(model.dictationHistoryEntries.count == 3)
            let busy = handle(sessions[0])
            try await model.selectHistoryRecording(busy)
            #expect(model.selectedSessionID == sessions[0].id)

            // A dictation that is finishing or delivering keeps its session.
            model.dictationSetForegroundProcessing(busy, active: true)
            let skipped = await model.deleteDictationSessions([sessions[0].id, sessions[1].id])
            #expect(skipped.deleted == 1 && skipped.skippedInUse == 1 && skipped.failed == 0)
            #expect(model.dictationHistoryEntries.map(\.sessionID) == [sessions[0].id, sessions[2].id])
            #expect(try await store.containsSession(sessions[0].id))
            #expect(try await store.containsSession(sessions[1].id) == false)
            #expect(!FileManager.default.fileExists(atPath: fixture.sessionFolder(sessions[1].id).path))
            #expect(model.sessions.map(\.id) == [sessions[0].id])
            #expect(model.selectedSessionID == sessions[0].id)

            // Once it is done, the open recording can go, and the selection goes with it.
            model.dictationSetForegroundProcessing(busy, active: false)
            let removed = await model.deleteDictationSessions([sessions[0].id])
            #expect(removed.deleted == 1 && removed.skippedInUse == 0)
            #expect(model.sessions.isEmpty)
            #expect(model.selectedSessionID == nil)
            let labels = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($1.id, "sessions[\($0)]") })
            let present = model.dictationHistoryEntries.map { labels[$0.sessionID] ?? "UNKNOWN \($0.sessionID)" }
            #expect(model.dictationHistoryEntries.map(\.sessionID) == [sessions[2].id], "present: \(present)")
            #expect(!model.isDeletingDictationHistory)

            let all = await model.deleteAllDictationHistory()
            #expect(all.deleted == 1)
            #expect(model.dictationHistoryEntries.isEmpty)
            #expect(try await store.dictationSessionIDs().isEmpty)
            #expect(try await store.prepareLazyStartup().totalSessionCount == 0)
        }
    }

    @Test("A history refresh that a newer refresh overtakes still returns current entries")
    func overlappingRefreshesBothReturnCurrentEntries() async throws {
        try await withWorkspace(sessions: { fixture in
            [fixture.session(text: "Zero", date: Date(timeIntervalSinceReferenceDate: 300)),
             fixture.session(text: "One", date: Date(timeIntervalSinceReferenceDate: 200))]
        }) { _, model, sessions, store in
            #expect(model.dictationHistoryEntries.count == 2)
            try await store.deleteSession(sessions[1].id)
            // The second call supersedes the first one's page token while the first is still reading. The first
            // must wait for the winner instead of returning with the list as it was.
            async let first: Void = model.refreshDictationHistory()
            async let second: Void = model.refreshDictationHistory()
            await first
            #expect(model.dictationHistoryEntries.map(\.sessionID) == [sessions[0].id],
                    "the first refresh returned before the newest one published")
            await second
            #expect(model.dictationHistoryEntries.map(\.sessionID) == [sessions[0].id])
        }
    }

    @Test("A paused recording that is open is never deleted out from under its editor")
    func workspaceKeepsOpenPausedRecording() async throws {
        try await withWorkspace(sessions: { fixture in
            [fixture.session(text: "Paused", state: .paused)]
        }) { _, model, sessions, store in
            try await model.selectHistoryRecording(handle(sessions[0]))
            let result = await model.deleteDictationSessions([sessions[0].id])
            #expect(result.deleted == 0 && result.skippedInUse == 1)
            #expect(try await store.containsSession(sessions[0].id))
            let all = await model.deleteAllDictationHistory()
            #expect(all.deleted == 0 && all.skippedInUse == 1)
            #expect(model.dictationHistoryEntries.count == 1)
        }
    }

    @Test("Retention by age deletes old finished dictations and leaves recent and unfinished ones")
    func workspaceRetentionByAge() async throws {
        let now = Date()
        let day: TimeInterval = 86_400
        try await withWorkspace(sessions: { fixture in
            [fixture.session(text: "Recent", date: now.addingTimeInterval(-1 * day)),
             fixture.session(text: "Old", date: now.addingTimeInterval(-40 * day)),
             fixture.session(text: "Old paused", date: now.addingTimeInterval(-50 * day), state: .paused)]
        }) { _, model, sessions, store in
            #expect(model.dictationHistoryEntries.count == 3)
            let untouched = await model.applyDictationRetention(.forever, now: now)
            #expect(untouched.isEmpty && model.dictationHistoryEntries.count == 3)

            let result = await model.applyDictationRetention(.days30, now: now)
            #expect(result.deleted == 1 && result.failed == 0)
            #expect(Set(model.dictationHistoryEntries.map(\.sessionID)) == [sessions[0].id, sessions[2].id])
            let stillThere = try await store.containsSession(sessions[1].id)
            #expect(!stillThere)

            let week = await model.applyDictationRetention(.days7, now: now.addingTimeInterval(10 * day))
            #expect(week.deleted == 1)
            #expect(model.dictationHistoryEntries.map(\.sessionID) == [sessions[2].id])
        }
    }

    @Test("Don't keep audio removes finished audio but keeps every transcript in the history")
    func workspaceRetentionWithoutAudio() async throws {
        let now = Date()
        var audioURLs: [UUID: URL] = [:]
        try await withWorkspace(sessions: { fixture in
            [fixture.session(text: "Just finished", date: now.addingTimeInterval(-10)),
             fixture.session(text: "Earlier today", date: now.addingTimeInterval(-3_600))]
        }, audio: true) { fixture, model, sessions, store in
            for session in sessions {
                let segment = try #require(session.segments.first)
                audioURLs[session.id] = try await store.audioDirectory(session.id).appendingPathComponent(segment.fileName)
            }
            let newestAudio = try #require(audioURLs[sessions[0].id])
            let olderAudio = try #require(audioURLs[sessions[1].id])
            let result = await model.applyDictationRetention(.noAudio, now: now)
            #expect(result.deleted == 1 && result.failed == 0)
            // The dictation from seconds ago keeps its audio for Retry; the older one loses it.
            #expect(FileManager.default.fileExists(atPath: newestAudio.path))
            #expect(!FileManager.default.fileExists(atPath: olderAudio.path))
            #expect(model.dictationHistoryEntries.map(\.preview) == ["Just finished", "Earlier today"])
            let stored = try #require(try await store.loadSession(sessions[1].id))
            #expect(stored.unavailableSegmentIDs == sessions[1].segments.map(\.id))
            #expect(stored.dictation?.recordings.first?.textRevision?.text == "Earlier today")

            // Later, when the grace period has passed, the newest goes too.
            let later = await model.applyDictationRetention(.noAudio, now: now.addingTimeInterval(DictationRetention.audioGraceSeconds + 60))
            #expect(later.deleted == 1)
            #expect(!FileManager.default.fileExists(atPath: newestAudio.path))
            #expect(model.dictationHistoryEntries.count == 2)
            _ = fixture
        }
    }

    // MARK: Retention setting

    @Test("The retention setting defaults to keeping everything and persists through the injected store")
    func retentionSettingPersists() throws {
        let suiteName = "Keystorm.DictationHistoryDeletionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(DictationRetention.load(from: defaults) == .forever)
        #expect(defaults.object(forKey: DictationRetention.storageKey) == nil)
        DictationRetention.days30.save(to: defaults)
        #expect(defaults.string(forKey: DictationRetention.storageKey) == "days30")
        #expect(DictationRetention.load(from: defaults) == .days30)
        defaults.set("someFutureValue", forKey: DictationRetention.storageKey)
        #expect(DictationRetention.load(from: defaults) == .forever)
        #expect(DictationRetention.allCases.map(\.rawValue) == ["forever", "days90", "days30", "days7", "noAudio"])
    }

    @Test("Each retention choice describes what it removes and when")
    func retentionCutoffs() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(DictationRetention.forever.deletionCutoff(now: now) == nil)
        #expect(DictationRetention.forever.audioCutoff(now: now) == nil)
        #expect(!DictationRetention.forever.removesData)
        #expect(DictationRetention.days90.deletionCutoff(now: now) == now.addingTimeInterval(-90 * 86_400))
        #expect(DictationRetention.days30.deletionCutoff(now: now) == now.addingTimeInterval(-30 * 86_400))
        #expect(DictationRetention.days7.deletionCutoff(now: now) == now.addingTimeInterval(-7 * 86_400))
        #expect(DictationRetention.days7.audioCutoff(now: now) == nil)
        #expect(DictationRetention.noAudio.deletionCutoff(now: now) == nil)
        #expect(DictationRetention.noAudio.audioCutoff(now: now) == now.addingTimeInterval(-DictationRetention.audioGraceSeconds))
        #expect([DictationRetention.days90, .days30, .days7, .noAudio].allSatisfy { $0.removesData })
    }

    // MARK: Helpers

    private func handle(_ session: VoiceSession) -> DictationRecordingHandle {
        .init(sessionID: session.id, takeID: session.brief!.takes[0].id)
    }

    private func withWorkspace(sessions make: (DeletionFixture) -> [VoiceSession], audio: Bool = false,
        body: @MainActor (DeletionFixture, WorkspaceModel, [VoiceSession], SessionStore) async throws -> Void) async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let seedStore = try SessionStore(root: fixture.root)
        var sessions = make(fixture)
        for index in sessions.indices {
            if audio { _ = try await fixture.addAudio(to: &sessions[index], store: seedStore) }
            try await seedStore.save(sessions[index])
        }
        let model = WorkspaceModel(root: fixture.root)
        await model.initialize()
        do {
            let store = try #require(model.store)
            try await body(fixture, model, sessions, store)
        } catch {
            await model.stopForTermination()
            throw error
        }
        await model.stopForTermination()
    }
}

private struct DeletionFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-HistoryDeletion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func sessionFolder(_ id: UUID) -> URL {
        root.appendingPathComponent("Sessions").appendingPathComponent(id.uuidString)
    }

    func session(text: String, title: String = "Saved local dictation", date: Date = Date(),
                 state: DictationRecordingState = .ready) -> VoiceSession {
        var session = VoiceSession()
        session.title = title
        session.createdAt = date
        session.updatedAt = date
        let interval = CaptureInterval(startedAt: date, endedAt: date, sampleRate: 16_000, channelCount: 1)
        session.intervals = [interval]
        var brief = BriefDocument()
        let takeID = UUID()
        brief.takes = [BriefTake(id: takeID, intervalID: interval.id, expectedRevision: brief.revisionID, createdAt: date)]
        session.brief = brief
        session.dictation = DictationSession(recordings: [
            DictationRecordingMetadata(id: takeID, state: state,
                textRevision: DictationTextRevision(rawText: text, text: text, sourceTranscriptIDs: []),
                createdAt: date, updatedAt: date)])
        return session
    }

    /// Writes a real 160-frame audio file and its sidecar, and attaches the segment to the session.
    @discardableResult
    func addAudio(to session: inout VoiceSession, store: SessionStore) async throws -> AudioSegment {
        let directory = try await store.audioDirectory(session.id)
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString + ".caf")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160) else {
            throw KeystormError.message("The test audio format is unavailable.")
        }
        buffer.frameLength = 160
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 160)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        let segment = AudioSegment(id: id, intervalID: session.intervals[0].id, fileName: url.lastPathComponent,
            startTime: 0, frameCount: 160, sampleRate: 16_000, channelCount: 1, sha256: try SessionStore.checksum(url))
        try JSONEncoder().encode(segment).write(to: directory.appendingPathComponent(id.uuidString + ".json"))
        session.segments = [segment]
        return segment
    }

    func count(_ sql: String) throws -> Int64 {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite").path, &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let connection else {
            throw KeystormError.message("Could not open the test catalog.")
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5_000)
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &query, nil) == SQLITE_OK, let query else {
            throw KeystormError.message("Invalid test SQL: " + String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw KeystormError.message("The test query returned no row.") }
        return sqlite3_column_int64(query, 0)
    }
}
