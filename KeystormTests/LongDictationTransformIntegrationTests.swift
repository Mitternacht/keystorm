import Foundation
import Testing
@testable import Keystorm

@MainActor @Suite(.serialized)
struct LongDictationTransformIntegrationTests {
    @Test("Actual Qwen long summary previews all source sections and persists a reversible output",
        .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_LONG_TRANSFORM"] == "1"),
        .timeLimit(.minutes(10)))
    func installedLongSummaryApplyReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-LongTransform-\(UUID().uuidString)")
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let sentence = "Please send die Rechnung to Müller tomorrow. Keep 42 Dateien local. We discussed typography yesterday. We discussed typography yesterday. "
        let text = String(repeating: sentence, count: 100)
        try #require(text.utf8.count > DictationTransformPolicy.maxSourceUTF8)
        let imported = TranscriptRevision(rawText: text, text: text, origin: .imported, timingPrecision: .unavailable)
        let source = DictationTextRevision(rawText: text, text: text, sourceTranscriptIDs: [imported.id])
        var session = VoiceSession()
        var brief = BriefDocument()
        let take = BriefTake(expectedRevision: brief.revisionID, status: .pending, transcriptIDs: [imported.id])
        brief.takes = [take]; session.brief = brief; session.transcripts = [imported]
        session.dictation = DictationSession(recordings: [
            DictationRecordingMetadata(id: take.id, state: .ready, textRevision: source)])
        let handle = DictationRecordingHandle(sessionID: session.id, takeID: take.id)
        var workspace: WorkspaceModel?
        var coordinator: DictationCoordinator?
        do {
            let store = try SessionStore(root: root)
            try await store.save(session)
            let model = WorkspaceModel(root: root, modelDirectory: models)
            workspace = model
            await model.initialize(loadLibrary: true)
            try #require(model.error == nil, "\(model.error ?? "")")
            try #require(model.installedModelIDs.contains(ModelCatalog.primaryText.id))
            let flow = DictationCoordinator(backend: model)
            coordinator = flow
            flow.restore(handle)
            let started = ContinuousClock.now
            flow.prepareTransform(.summarize)
            await flow.waitUntilSettled()
            let preview = try #require(flow.longTransformPreview, "\(flow.message); \(model.error ?? "")")
            let elapsed = started.duration(to: .now).components
            print("LONG_SUMMARY_MILLISECONDS", Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            #expect(flow.transformPreview == nil)
            #expect(flow.hasTransformPreview)
            #expect(model.dictationMetadata(handle)?.textRevision == source)
            #expect(preview.plan.chunks.count >= 2)
            #expect(preview.plan.chunks.last?.endUTF8 == text.utf8.count)
            #expect(preview.outputs.count == preview.plan.chunks.count)
            #expect(preview.outputs.allSatisfy { $0.generatedTokens > 0 })
            #expect(preview.text.utf8.count < text.utf8.count)
            #expect(preview.text.contains("Rechnung"))
            #expect(preview.text.contains("Müller"))
            #expect(preview.text.contains("Dateien"))
            Attachment.record(try JSONEncoder().encode(preview), named: "actual-long-summary-sections.json")
            flow.applyTransformPreview()
            await flow.waitUntilSettled()
            let applied = try #require(model.dictationMetadata(handle))
            let history = try #require(applied.outputHistory)
            #expect(applied.textRevision?.id == preview.jobID)
            #expect(applied.textRevision?.text == preview.text)
            #expect(applied.textRevision?.rawText == text)
            #expect(applied.delivery == nil)
            #expect(history.last?.longTransform == preview)
            try applied.validateOutputHistory()
            let original = try #require(history.first { $0.textRevision == source })
            flow.cancelForShutdown()
            await model.stopForTermination()
            let reopenedStore = try SessionStore(root: root)
            let reopened = try #require(try await reopenedStore.loadSessions().first { $0.id == session.id })
            let saved = try #require(reopened.dictation?.recordings.first)
            #expect(saved == applied)
            var restored = saved
            try restored.selectOutput(id: original.id)
            #expect(restored.textRevision == source)
            #expect(restored.outputHistory == history)
            #expect(reopened.transcripts == [imported])
            try FileManager.default.removeItem(at: root)
        } catch {
            coordinator?.cancelForShutdown()
            await workspace?.stopForTermination()
            await coordinator?.waitUntilSettled()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
