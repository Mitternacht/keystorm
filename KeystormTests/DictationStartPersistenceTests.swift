import Foundation
import Testing
@testable import Keystorm

/// Dictation Start writes its mode and Recording state in the same durable save as the capture
/// interval, instead of in separate saves around the microphone opening. A private store in a
/// temporary directory stands in for Application Support; no microphone or model is involved.
@MainActor
struct DictationStartPersistenceTests {
    private func startedSession(mode: DictationQuickMode) throws -> (session: VoiceSession, take: BriefTake) {
        var session = VoiceSession()
        session.brief = BriefDocument()
        session.dictation = DictationSession()
        let take = try WorkspaceModel.beginCaptureInterval(in: &session, resuming: nil, intervalID: UUID(),
            intent: .addMaterial, targetSection: .changes, selectedBlockIDs: [])
        try WorkspaceModel.recordDictationStart(in: &session, takeID: take.id, mode: mode)
        return (session, take)
    }

    @Test("The interval's own save already carries the mode and the Recording state",
          arguments: DictationQuickMode.allCases)
    func metadataRidesWithInterval(mode: DictationQuickMode) throws {
        let (session, take) = try startedSession(mode: mode)
        let metadata = try #require(session.dictation?.recordings.first { $0.id == take.id })
        #expect(metadata.state == .recording)
        #expect(metadata.captureMode == mode)
        #expect(metadata.failureMessage == nil)
        #expect(session.dictation?.recordings.count == 1)
        try session.validateDictationMetadata()
    }

    @Test("Applying it twice leaves one record for the take")
    func idempotent() throws {
        var (session, take) = try startedSession(mode: .clean)
        try WorkspaceModel.recordDictationStart(in: &session, takeID: take.id, mode: .email)
        #expect(session.dictation?.recordings.count == 1)
        #expect(session.dictation?.recordings.first?.captureMode == .email)
    }

    @Test("A take that does not exist is refused instead of silently dropping the mode")
    func unknownTakeIsRefused() throws {
        var session = VoiceSession()
        session.brief = BriefDocument()
        #expect(throws: (any Error).self) {
            try WorkspaceModel.recordDictationStart(in: &session, takeID: UUID(), mode: .verbatim)
        }
    }

    @Test("What Start saves survives a restart: the store returns the same mode and state")
    func survivesReload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-StartPersistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, take) = try startedSession(mode: .email)
        let store = try SessionStore(root: root)
        try await store.save(session)
        let reopened = try SessionStore(root: root)
        let loaded = try #require(try await reopened.loadSessions().first { $0.id == session.id })
        let metadata = try #require(loaded.dictation?.recordings.first { $0.id == take.id })
        #expect(metadata.state == .recording)
        #expect(metadata.captureMode == .email)
        #expect(loaded.brief?.takes.first?.status == .recording)
    }
}
