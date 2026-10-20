import Foundation
import Testing
@testable import Keystorm

/// Exercises the shipping default startup path. These fixtures contain no models,
/// microphone input, Accessibility objects, or audio files.
@MainActor
struct LazyHistoryWorkspaceTests {
    @Test("Default workspace startup and older pages read headers without hydrating archives")
    func defaultStartupAndPagingStayLazy() async throws {
        try await withWorkspace(recordings: 53) { _, model, sessions, store in
            #expect(model.error == nil && model.historyError == nil)
            #expect(model.sessions.isEmpty && model.selectedSessionID == nil)
            #expect(model.dictationHistoryEntries.count == 50 && model.historyHasMore)
            #expect(model.dictationHistoryEntries.allSatisfy { $0.preview.count <= 100 })
            let initial = await store.historyQueryDiagnostics()
            #expect(initial.fullPayloadDecodes == 0 && initial.decodedSessionIDs.isEmpty)

            await model.loadMoreDictationHistory()
            #expect(model.dictationHistoryEntries.count == 53 && !model.historyHasMore)
            #expect(Set(model.dictationHistoryEntries.map(\.sessionID)) == Set(sessions.map(\.id)))
            #expect(Set(model.dictationHistoryEntries.map(\.stableID)).count == 53)
            #expect(model.sessions.isEmpty)
            #expect(await store.historyQueryDiagnostics().fullPayloadDecodes == 0)

            // A refresh preserves the amount of history the person requested.
            await model.refreshDictationHistory()
            #expect(model.dictationHistoryEntries.count == 53)
            #expect(await store.historyQueryDiagnostics().fullPayloadDecodes == 0)

            let chosen = try #require(model.dictationHistoryEntries.last)
            try await model.selectHistoryRecording(chosen.handle)
            #expect(model.selectedSessionID == chosen.sessionID)
            #expect(model.sessions.map(\.id) == [chosen.sessionID])
            #expect(model.dictationMetadata(chosen.handle)?.textRevision?.text ==
                sessions.first(where: { $0.id == chosen.sessionID })?.dictation?.recordings.first?.textRevision?.text)
            let selected = await store.historyQueryDiagnostics()
            #expect(selected.fullPayloadDecodes > 0)
            #expect(selected.decodedSessionIDs == [chosen.sessionID])
        }
    }

    @Test("Successive history selection retains at most two clean archives and reuses cached selections")
    func hydratedCacheStaysBounded() async throws {
        try await withWorkspace(recordings: 4) { _, model, sessions, store in
            for (index, session) in sessions.enumerated() {
                _ = await store.historyQueryDiagnostics(reset: true)
                try await model.selectHistoryRecording(handle(session))
                #expect(model.selectedSessionID == session.id)
                #expect(model.sessions.count <= 2)
                let expected = Set(sessions.prefix(index + 1).suffix(2).map(\.id))
                #expect(Set(model.sessions.map(\.id)) == expected)
                #expect(await store.historyQueryDiagnostics().decodedSessionIDs == [session.id])
            }
            let cached = sessions[sessions.count - 2]
            _ = await store.historyQueryDiagnostics(reset: true)
            try await model.selectHistoryRecording(handle(cached))
            #expect(model.selectedSessionID == cached.id)
            #expect(model.sessions.count == 2)
            #expect(await store.historyQueryDiagnostics().fullPayloadDecodes == 0)
        }
    }

    @Test("A caller cancelled before selection reads no payload and preserves the current recording")
    func cancelledCallerDoesNotReadOrSelect() async throws {
        try await withWorkspace(recordings: 2) { _, model, sessions, store in
            try await model.selectHistoryRecording(handle(sessions[0]))
            _ = await store.historyQueryDiagnostics(reset: true)
            let cancelled = Task { @MainActor in
                try await model.selectHistoryRecording(handle(sessions[1]))
            }
            // The MainActor cannot enter the new task before this cancellation.
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(model.selectedSessionID == sessions[0].id)
            #expect(model.sessions.map(\.id) == [sessions[0].id])
            #expect(!model.isLoadingHistorySelection)
            #expect(await store.historyQueryDiagnostics().fullPayloadDecodes == 0)
        }
    }

    @Test("An invalid requested take does not cache its hydrated owner or change selection")
    func invalidTakeCannotPopulateCache() async throws {
        try await withWorkspace(recordings: 2) { _, model, sessions, store in
            let selected = sessions[0]
            let rejected = sessions[1]
            try await model.selectHistoryRecording(handle(selected))
            let cachedIDs = model.sessions.map(\.id)
            _ = await store.historyQueryDiagnostics(reset: true)
            let invalid = DictationRecordingHandle(sessionID: rejected.id, takeID: UUID())
            await #expect(throws: (any Error).self) {
                try await model.selectHistoryRecording(invalid)
            }
            #expect(model.selectedSessionID == selected.id)
            #expect(model.sessions.map(\.id) == cachedIDs)
            #expect(!model.sessions.contains { $0.id == rejected.id })
            #expect(model.dictationMetadata(invalid) == nil)
            #expect(!model.isLoadingHistorySelection)
            #expect(await store.historyQueryDiagnostics().decodedSessionIDs == [rejected.id])
        }
    }

    @Test("A delayed editor save rehydrates its evicted owner without changing the current selection")
    func delayedSaveRehydratesEvictedOwner() async throws {
        try await withWorkspace(recordings: 3) { _, model, sessions, store in
            let oldOwner = sessions[0]
            let oldHandle = handle(oldOwner)
            let original = try #require(oldOwner.dictation?.recordings.first?.textRevision)
            var edited = original
            edited.id = UUID()
            edited.text = "Keep the local workflow. Grüße aus München."
            for session in sessions { try await model.selectHistoryRecording(handle(session)) }
            let current = sessions[2]
            #expect(!model.sessions.contains { $0.id == oldOwner.id })
            #expect(model.selectedSessionID == current.id)

            _ = await store.historyQueryDiagnostics(reset: true)
            // This is the saved callback from the older editor, after eviction.
            try await model.dictationSave(oldHandle, state: .ready,
                revision: edited, delivery: nil, failure: nil)
            #expect(model.selectedSessionID == current.id)
            #expect(model.sessions.count <= 2)
            #expect(model.dictationMetadata(oldHandle)?.textRevision == edited)
            #expect(await store.historyQueryDiagnostics().decodedSessionIDs == [oldOwner.id])
            let durable = try #require(try await store.loadSession(oldOwner.id))
            let saved = try #require(durable.dictation?.recordings.first?.textRevision)
            #expect(saved == edited)
            #expect(saved.rawText == original.rawText && saved.sourceTranscriptIDs == original.sourceTranscriptIDs)
            #expect(durable.intervals == oldOwner.intervals)
            #expect(durable.brief?.takes.map(\.id) == oldOwner.brief?.takes.map(\.id))
            #expect(try await store.loadSession(current.id) == current)
            await model.refreshDictationHistory()
            #expect(model.dictationHistoryEntries.first(where: { $0.sessionID == oldOwner.id })?.preview ==
                String(edited.text.prefix(100)))
        }
    }

    @Test("Concurrent history selection and a delayed save retain one owner with the latest manual text")
    func overlappingSelectionAndDelayedSaveKeepLatestResident() async throws {
        try await withWorkspace(recordings: 3) { _, model, sessions, store in
            let owner = sessions[0]
            let ownerHandle = handle(owner)
            for iteration in 0..<8 {
                // Both callbacks below must hydrate this evicted owner. Repeating
                // the overlap covers either actor arrival order without relying
                // on a sleep or requiring a particular scheduler winner.
                for session in sessions { try await model.selectHistoryRecording(handle(session)) }
                #expect(!model.sessions.contains { $0.id == owner.id })
                let baseline = try #require(try await store.loadSession(owner.id))
                var edited = try #require(baseline.dictation?.recordings.first?.textRevision)
                edited.id = UUID()
                edited.text = "Latest manual correction \(iteration). Grüße aus Köln."
                let selection = Task { @MainActor in
                    try await model.selectHistoryRecording(ownerHandle)
                }
                let delayedSave = Task { @MainActor in
                    try await model.dictationSave(ownerHandle, state: .ready,
                        revision: edited, delivery: nil, failure: nil)
                }
                do {
                    try await selection.value
                    try await delayedSave.value
                } catch {
                    selection.cancel()
                    delayedSave.cancel()
                    _ = try? await selection.value
                    _ = try? await delayedSave.value
                    throw error
                }
                #expect(Set(model.sessions.map(\.id)).count == model.sessions.count)
                #expect(model.sessions.filter { $0.id == owner.id }.count == 1)
                #expect(model.sessions.count <= 2)
                #expect(model.selectedSessionID == owner.id)
                #expect(model.dictationMetadata(ownerHandle)?.textRevision == edited)
                #expect(try await store.loadSession(owner.id)?.dictation?.recordings.first?.textRevision == edited)
            }
        }
    }

    @Test("Import collision checks reject an existing evicted archive without decoding or overwriting it")
    func duplicateImportOfEvictedArchiveIsRejected() async throws {
        try await withWorkspace(recordings: 3) { _, model, sessions, store in
            for session in sessions { try await model.selectHistoryRecording(handle(session)) }
            var duplicate = sessions[0]
            #expect(!model.sessions.contains { $0.id == duplicate.id })
            duplicate.title = "This must never replace the original"
            let cachedIDs = model.sessions.map(\.id)
            _ = await store.historyQueryDiagnostics(reset: true)
            await #expect(throws: (any Error).self) {
                try await model.registerImportedSession(duplicate)
            }
            #expect(await store.historyQueryDiagnostics().fullPayloadDecodes == 0)
            #expect(model.sessions.map(\.id) == cachedIDs)
            #expect(model.selectedSessionID == sessions[2].id)
            #expect(try await store.loadSession(duplicate.id) == sessions[0])
        }
    }

    @Test("Legacy-only libraries stay lazy until the person explicitly opens Developer briefs")
    func legacyOnlyLibraryDoesNotCreateAnotherBlankSession() async throws {
        try await withWorkspace(recordings: 1, legacyOnly: true) { _, model, sessions, store in
            #expect(model.error == nil && model.historyError == nil)
            #expect(model.sessions.isEmpty && model.dictationHistoryEntries.isEmpty)
            #expect(model.selectedSessionID == nil)
            let indexed = try await store.prepareLazyStartup()
            #expect(indexed.totalSessionCount == 1)
            #expect(await store.historyQueryDiagnostics().fullPayloadDecodes == 0)
            #expect(await model.loadLegacyLibrary())
            #expect(model.sessions.count == 1)
            #expect(model.selectedSessionID == sessions[0].id)
            #expect(model.selectedSession?.title == sessions[0].title)
            #expect(model.selectedSession?.brief?.takes.map(\.id) == sessions[0].brief?.takes.map(\.id))
            #expect(await store.historyQueryDiagnostics().decodedSessionIDs == [sessions[0].id])
        }
    }

    private func handle(_ session: VoiceSession) -> DictationRecordingHandle {
        .init(sessionID: session.id, takeID: session.brief!.takes[0].id)
    }

    private func withWorkspace(recordings count: Int, legacyOnly: Bool = false,
        body: @MainActor (LazyWorkspaceFixture, WorkspaceModel, [VoiceSession], SessionStore) async throws -> Void) async throws {
        let fixture = try LazyWorkspaceFixture()
        defer { fixture.remove() }
        let seedStore = try SessionStore(root: fixture.root)
        var sessions = (0..<count).map { fixture.session(index: $0) }
        if legacyOnly {
            for index in sessions.indices { sessions[index].dictation = nil }
        }
        for session in sessions { try await seedStore.save(session) }
        let model = WorkspaceModel(root: fixture.root)
        // Intentionally omit loadLibrary: this is the production default.
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

private struct LazyWorkspaceFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-LazyWorkspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func session(index: Int) -> VoiceSession {
        let date = Date(timeIntervalSinceReferenceDate: 10_000 + Double(index))
        var session = VoiceSession()
        session.title = "Local recording \(index)"
        session.createdAt = date
        session.updatedAt = date
        let interval = CaptureInterval(startedAt: date, endedAt: date,
            sampleRate: 16_000, channelCount: 1)
        session.intervals = [interval]
        var brief = BriefDocument()
        let take = BriefTake(intervalID: interval.id, expectedRevision: brief.revisionID, createdAt: date)
        brief.takes = [take]
        session.brief = brief
        let text = "Local recording \(index). Bitte die Änderungen prüfen und keep every word."
        session.dictation = DictationSession(recordings: [
            DictationRecordingMetadata(id: take.id, state: .ready,
                textRevision: DictationTextRevision(rawText: text, text: text,
                    sourceTranscriptIDs: [], createdAt: date),
                createdAt: date, updatedAt: date)])
        return session
    }
}
