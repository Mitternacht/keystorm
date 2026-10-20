import Foundation
import Testing
@testable import Keystorm

struct DictationOutputHistoryTests {
    @Test func `Legacy metadata keeps absent history keys and round trips unchanged`() throws {
        let metadata = fixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(metadata)
        let object = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
        #expect(object["outputHistory"] == nil)
        #expect(object["activeOutputID"] == nil)
        let reopened = try JSONDecoder().decode(DictationRecordingMetadata.self, from: before)
        #expect(reopened == metadata)
        #expect(reopened.outputHistory == nil)
        #expect(try encoder.encode(reopened) == before)
    }

    @Test func `First transform preserves raw ASR current manual source and result separately`() throws {
        var metadata = fixture()
        let source = try #require(metadata.textRevision)
        let result = transform(source: source, text: "Bitte nicht senden.\nGrüße an die Straße.")
        try metadata.stageTransform(source: source, result: result)
        let history = try #require(metadata.outputHistory)
        #expect(history.count == 3)
        #expect(history[0].mode == .verbatim)
        #expect(history[0].textRevision.text.utf8.elementsEqual(source.rawText.utf8))
        #expect(history[0].textRevision.rawText.utf8.elementsEqual(source.rawText.utf8))
        #expect(history[1].id == source.id)
        #expect(history[1].textRevision == source)
        #expect(history[1].parentOutputID == history[0].id)
        #expect(history[2].id == result.jobID)
        #expect(history[2].textRevision.id == history[2].id)
        #expect(history[2].sourceRevisionID == source.id)
        #expect(history[2].parentOutputID == source.id)
        #expect(history[2].sourceSHA256 == DictationTransformPolicy.sourceDigest(source.text))
        #expect(history[2].configurationID == result.configurationID)
        #expect(metadata.activeOutputID == result.jobID)
        #expect(metadata.textRevision?.text == result.text)
        #expect(metadata.textRevision?.rawText.utf8.elementsEqual(source.rawText.utf8) == true)
        try metadata.validateOutputHistory()
    }

    @Test func `Identical delivery of one transform job is idempotent and retains immutable parents`() throws {
        var metadata = fixture()
        let source = try #require(metadata.textRevision)
        let first = transform(source: source, text: "Bitte nicht senden.\nGrüße an die Straße.")
        try metadata.stageTransform(source: source, result: first)
        let once = metadata
        try metadata.stageTransform(source: source, result: first)
        #expect(metadata == once)
        let firstHistory = try #require(metadata.outputHistory)
        let secondSource = try #require(metadata.textRevision)
        let second = transform(source: secondSource, text: "- Bitte nicht senden.\n- Grüße an die Straße.", mode: .organize)
        try metadata.stageTransform(source: secondSource, result: second)
        #expect(Array(try #require(metadata.outputHistory).prefix(firstHistory.count)) == firstHistory)
        #expect(metadata.outputHistory?.last?.parentOutputID == first.jobID)
        #expect(metadata.outputHistory?.last?.sourceRevisionID == first.jobID)
        #expect(metadata.outputHistory?.last?.sourceSHA256 == DictationTransformPolicy.sourceDigest(secondSource.text))
    }

    @Test func `Restoring raw or generated output checkpoints unsaved manual edits without losing versions`() throws {
        var metadata = fixture()
        let source = try #require(metadata.textRevision)
        let result = transform(source: source, text: "Bitte nicht senden.\nGrüße an die Straße.")
        try metadata.stageTransform(source: source, result: result)
        let priorHistory = try #require(metadata.outputHistory)
        var edited = try #require(metadata.textRevision)
        edited.id = UUID()
        edited.text = "Bitte nie senden. Grüße an die Straße."
        metadata.textRevision = edited
        metadata.activeOutputID = nil
        metadata.delivery = DictationDelivery(requestID: UUID(), targetLabel: "Clipboard", state: .copied)
        try metadata.selectOutput(id: priorHistory[0].id)
        #expect(metadata.outputHistory?.count == priorHistory.count + 1)
        #expect(Array(try #require(metadata.outputHistory).prefix(priorHistory.count)) == priorHistory)
        #expect(metadata.outputHistory?.last?.textRevision == edited)
        #expect(metadata.textRevision?.text.utf8.elementsEqual(source.rawText.utf8) == true)
        #expect(metadata.delivery == nil)
        #expect(metadata.outputMode == .verbatim)
        let checkpointed = metadata.outputHistory
        try metadata.selectOutput(id: result.jobID)
        #expect(metadata.outputHistory == checkpointed)
        #expect(metadata.activeOutputID == result.jobID)
        #expect(metadata.outputMode == .clean)
        let restored = metadata
        try metadata.selectOutput(id: result.jobID)
        #expect(metadata == restored)
    }

    @Test func `Stale source text identity and Unicode bytes cannot overwrite current text`() throws {
        let source = try #require(fixture().textRevision)
        let result = transform(source: source, text: "Bitte nicht senden. Grüße an die Straße.")
        var changed = fixture()
        changed.textRevision = source
        changed.textRevision?.text += " This was edited."
        let before = changed
        #expect(throws: DictationTransformError.staleSource) { try changed.stageTransform(source: source, result: result) }
        #expect(changed == before)
        changed.textRevision = source
        changed.textRevision?.id = UUID()
        let changedIdentity = changed
        #expect(throws: DictationTransformError.staleSource) { try changed.stageTransform(source: source, result: result) }
        #expect(changed == changedIdentity)

        var decomposed = DictationTextRevision(rawText: "é", text: "e\u{301}", sourceTranscriptIDs: [])
        var unicode = DictationRecordingMetadata(id: UUID(), state: .ready, textRevision: decomposed)
        let transformed = transform(source: decomposed, text: decomposed.text)
        decomposed.text = "é"
        unicode.textRevision = decomposed
        let exact = unicode
        #expect(throws: DictationTransformError.staleSource) {
            var originalSource = decomposed
            originalSource.text = "e\u{301}"
            try unicode.stageTransform(source: originalSource, result: transformed)
        }
        #expect(unicode == exact)
    }

    @Test func `History count and byte budgets fail atomically with original text retained`() throws {
        var metadata = fixture()
        let entries = (0..<DictationRecordingMetadata.maximumOutputHistoryCount).map { _ in
            DictationOutputRevision(textRevision: DictationTextRevision(rawText: "Keep this local.",
                text: "Keep this local.", sourceTranscriptIDs: []), mode: .verbatim)
        }
        metadata.outputHistory = entries
        metadata.textRevision = entries.last?.textRevision
        let source = try #require(metadata.textRevision)
        let result = transform(source: source, text: source.text)
        let before = metadata
        #expect(throws: DictationTransformError.historyLimit) { try metadata.stageTransform(source: source, result: result) }
        #expect(metadata == before)
        try metadata.validateOutputHistory()

        let raw = String(repeating: "x", count: 1_100_000)
        let large = DictationTextRevision(rawText: raw, text: "Keep this local.", sourceTranscriptIDs: [])
        var bounded = DictationRecordingMetadata(id: UUID(), state: .ready, textRevision: large)
        let original = bounded
        #expect(throws: DictationTransformError.historyLimit) {
            try bounded.stageTransform(source: large, result: transform(source: large, text: large.text))
        }
        #expect(bounded == original)
        #expect(bounded.textRevision?.rawText.utf8.elementsEqual(raw.utf8) == true)
        #expect(bounded.outputHistory == nil)
    }

    @Test func `Invalid parent source digest duplicate identities and active mismatch are rejected`() throws {
        var metadata = fixture()
        let source = try #require(metadata.textRevision)
        try metadata.stageTransform(source: source, result: transform(source: source, text: source.text))
        let history = try #require(metadata.outputHistory)
        let output = try #require(history.last)
        metadata.outputHistory?.append(output)
        #expect(throws: DictationTransformError.invalidHistory) { try metadata.validateOutputHistory() }
        metadata.outputHistory = history
        metadata.activeOutputID = UUID()
        #expect(throws: DictationTransformError.invalidHistory) { try metadata.validateOutputHistory() }
        metadata.activeOutputID = output.id
        metadata.outputHistory = Array(history.dropLast()) + [DictationOutputRevision(id: output.id,
            parentOutputID: output.parentOutputID, textRevision: output.textRevision, mode: output.mode,
            sourceRevisionID: output.sourceRevisionID, sourceSHA256: String(repeating: "0", count: 64),
            configurationID: output.configurationID, promptTemplateVersion: output.promptTemplateVersion,
            promptTemplateSHA256: output.promptTemplateSHA256, createdAt: output.createdAt)]
        #expect(throws: DictationTransformError.invalidHistory) { try metadata.validateOutputHistory() }
        metadata.outputHistory = [DictationOutputRevision(parentOutputID: UUID(), textRevision: source, mode: .verbatim)]
        metadata.activeOutputID = nil
        metadata.textRevision = source
        #expect(throws: DictationTransformError.invalidHistory) { try metadata.validateOutputHistory() }
    }

    @Test func `Output history survives store reopening and preserves earlier archive data`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-OutputHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        var brief = BriefDocument()
        let take = BriefTake(expectedRevision: brief.revisionID)
        brief.takes = [take]
        session.brief = brief
        var metadata = fixture(id: take.id)
        session.dictation = DictationSession(recordings: [metadata])
        try await store.save(session)
        let archivedBrief = session.brief
        let source = try #require(metadata.textRevision)
        try metadata.stageTransform(source: source, result: transform(source: source, text: source.text))
        session.dictation?.recordings = [metadata]
        try session.validateDictationMetadata()
        try await store.save(session)
        let reopened = try SessionStore(root: root)
        let recovered = try #require(try await reopened.loadSessions().first)
        #expect(recovered == session)
        #expect(recovered.brief == archivedBrief)
        #expect(recovered.segments.isEmpty)
        #expect(recovered.dictation?.recordings.first?.outputHistory == metadata.outputHistory)
        #expect(recovered.dictation?.recordings.first?.textRevision?.rawText.utf8.elementsEqual(source.rawText.utf8) == true)
        try recovered.validateDictationMetadata()
    }

    @Test func `Historical template provenance survives prompt updates without permitting stale new results`() throws {
        var metadata = fixture()
        let source = try #require(metadata.textRevision)
        let currentResult = transform(source: source, text: source.text)
        try metadata.stageTransform(source: source, result: currentResult)
        let history = try #require(metadata.outputHistory)
        let output = try #require(history.last)
        let historicalHash = String(repeating: "a", count: 64)
        metadata.outputHistory = Array(history.dropLast()) + [DictationOutputRevision(id: output.id,
            parentOutputID: output.parentOutputID, textRevision: output.textRevision, mode: output.mode,
            sourceRevisionID: output.sourceRevisionID, sourceSHA256: output.sourceSHA256,
            configurationID: output.configurationID, promptTemplateVersion: 999,
            promptTemplateSHA256: historicalHash, createdAt: output.createdAt)]
        try metadata.validateOutputHistory()
        let reopened = try JSONDecoder().decode(DictationRecordingMetadata.self, from: JSONEncoder().encode(metadata))
        try reopened.validateOutputHistory()
        #expect(reopened.outputHistory?.last?.promptTemplateVersion == 999)
        #expect(reopened.outputHistory?.last?.promptTemplateSHA256 == historicalHash)
        var stale = currentResult
        stale.promptTemplateVersion = 999
        stale.promptTemplateSHA256 = historicalHash
        var original = fixture()
        original.textRevision = source
        #expect(throws: DictationTransformError.mismatchedResult) {
            try original.stageTransform(source: source, result: stale)
        }
    }

    private func fixture(id: UUID = UUID()) -> DictationRecordingMetadata {
        DictationRecordingMetadata(id: id, state: .ready,
            textRevision: DictationTextRevision(rawText: "ähm, bitte nicht senden. Grüße an die Straße.",
                text: "Bitte nicht senden. Grüße an die Straße.", sourceTranscriptIDs: []))
    }

    private func transform(source: DictationTextRevision, text: String,
                           mode: DictationOutputMode = .clean) -> DictationTransformResult {
        DictationTransformResult(jobID: UUID(), sourceRevisionID: source.id,
            sourceSHA256: DictationTransformPolicy.sourceDigest(source.text), mode: mode,
            text: text, generatedTokens: 20, configurationID: UUID(),
            promptTemplateVersion: DictationTransformPolicy.templateVersion,
            promptTemplateSHA256: DictationTransformPolicy.promptTemplateSHA256(for: mode))
    }
}
