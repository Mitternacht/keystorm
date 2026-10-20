import Foundation
import Testing
@testable import Keystorm

struct DictationProvenanceReviewTests {
    @Test func learnedTermIdentityCannotChangeUnderSavedOutputID() throws {
        let term = UUID()
        let source = DictationTextRevision(rawText: "Muller Rechnung", text: "Müller Rechnung",
            sourceTranscriptIDs: [], appliedLearnedTermIDs: [term])
        var metadata = DictationRecordingMetadata(id: UUID(), state: .ready, textRevision: source,
            outputHistory: [DictationOutputRevision(textRevision: source, mode: .verbatim)],
            activeOutputID: source.id)
        try metadata.validateOutputHistory()
        metadata.textRevision?.appliedLearnedTermIDs = [UUID()]
        #expect(throws: DictationTransformError.invalidHistory) { try metadata.validateOutputHistory() }
    }

    @Test func malformedLearnedTermProvenanceFailsWithoutHistory() throws {
        let id = UUID()
        for ids in [[], [id, id], (0..<65).map { _ in UUID() }] as [[UUID]] {
            let source = DictationTextRevision(rawText: "text", text: "text", sourceTranscriptIDs: [],
                appliedLearnedTermIDs: ids)
            let metadata = DictationRecordingMetadata(id: UUID(), textRevision: source)
            #expect(throws: DictationTransformError.invalidHistory) { try metadata.validateOutputHistory() }
        }
    }

    @Test func transformedOutputRetainsExactLearnedTermLineage() throws {
        let source = DictationTextRevision(rawText: "send Muller die Rechnung", text: "send Müller die Rechnung",
            sourceTranscriptIDs: [], appliedLearnedTermIDs: [UUID()])
        var metadata = DictationRecordingMetadata(id: UUID(), state: .ready, textRevision: source)
        let result = DictationTransformResult(jobID: UUID(), sourceRevisionID: source.id,
            sourceSHA256: DictationTransformPolicy.sourceDigest(source.text), mode: .clean,
            text: "Send Müller die Rechnung.", generatedTokens: 12, configurationID: UUID(),
            promptTemplateVersion: DictationTransformPolicy.templateVersion,
            promptTemplateSHA256: DictationTransformPolicy.promptTemplateSHA256(for: .clean))
        try metadata.stageTransform(source: source, result: result)
        #expect(metadata.textRevision?.appliedLearnedTermIDs == source.appliedLearnedTermIDs)
        var forged = source
        forged.appliedLearnedTermIDs = [UUID()]
        #expect(throws: DictationTransformError.mismatchedResult) {
            try metadata.stageTransform(source: forged, result: result)
        }
    }

    @Test func audioSelectionInvalidatesCurrentTextAndRetainsOriginalAndManualOutputs() throws {
        let source = DictationTextRevision(rawText: "send die Rechnung", text: "Send die Rechnung.",
            sourceTranscriptIDs: [])
        var metadata = DictationRecordingMetadata(id: UUID(), state: .ready, textRevision: source,
            delivery: DictationDelivery(requestID: UUID(), textRevisionID: source.id,
                targetLabel: "TextEdit", state: .inserted))
        try metadata.invalidateAudioSelection()
        #expect(metadata.state == .captured)
        #expect(metadata.textRevision == nil)
        #expect(metadata.activeOutputID == nil)
        #expect(metadata.delivery == nil)
        #expect(metadata.outputHistory?.contains { $0.textRevision == source } == true)
        #expect(metadata.outputHistory?.contains { $0.textRevision.text == source.rawText } == true)
        try metadata.validateOutputHistory()
    }
}
