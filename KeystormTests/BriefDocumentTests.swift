import Foundation
import Testing
@testable import Keystorm

struct BriefDocumentTests {
    @Test func atomicChangesRejectStaleRevisions() throws {
        var document = BriefDocument()
        let original = BriefBlock(text: "Preserve all requirements.")
        try document.apply([.append(section: .changes, block: original)], expectedRevision: document.revisionID, label: "Add")
        let snapshot = document
        #expect(throws: BriefDocumentError.missingBlock) {
            try document.apply([
                .replace(blockID: original.id, text: "Changed", origin: .typed, sources: []),
                .remove(blockID: UUID())
            ], expectedRevision: document.revisionID, label: "Invalid batch")
        }
        #expect(document == snapshot)
        #expect(throws: BriefDocumentError.staleRevision) {
            try document.apply([.remove(blockID: original.id)], expectedRevision: UUID(), label: "Stale")
        }
        #expect(document == snapshot)
    }

    @Test func undoRedoSurviveSerializationAndKeepAbandonedBranches() throws {
        var document = BriefDocument()
        let first = BriefBlock(text: "First")
        let second = BriefBlock(text: "Second")
        try document.apply([.append(section: .changes, block: first), .append(section: .changes, block: second)],
                           expectedRevision: document.revisionID, label: "Two requirements")
        try document.apply([.move(blockID: first.id, section: .constraints, index: nil), .remove(blockID: second.id)],
                           expectedRevision: document.revisionID, label: "Revise scope")
        let finalSections = document.sections
        try document.undo()
        #expect(document.section(.changes).blocks.map(\.id) == [first.id, second.id])
        let data = try JSONEncoder().encode(document)
        var restored = try JSONDecoder().decode(BriefDocument.self, from: data)
        try restored.validateStructure()
        try restored.redo()
        #expect(restored.sections == finalSections)
        try restored.undo()
        try restored.apply([.replace(blockID: second.id, text: "New branch", origin: .typed, sources: [])],
                           expectedRevision: restored.revisionID, label: "Different choice")
        #expect(!restored.canRedo)
        #expect(restored.history.count == 3)
        #expect(restored.history[1].label == "Revise scope")
        #expect(restored.events.contains { $0.action == .undo })
    }

    @Test func typingBurstCreatesOneUndoUnit() throws {
        var document = BriefDocument()
        let block = BriefBlock(text: "Original")
        try document.apply([.append(section: .goal, block: block)], expectedRevision: document.revisionID, label: "Add goal")
        for text in ["N", "Ne", "New", "New goal"] {
            try document.apply([.replace(blockID: block.id, text: text, origin: .typed, sources: [])],
                               expectedRevision: document.revisionID, label: "Edit text", coalesce: true)
        }
        #expect(document.history.count == 2)
        #expect(document.history.last?.changes[0].before?.block.text == "Original")
        try document.validateStructure()
        try document.undo()
        #expect(document.block(block.id)?.text == "Original")
        try document.redo()
        #expect(document.block(block.id)?.text == "New goal")
    }

    @Test func exactUnicodeReferencesRequireDeliberateUnlocking() throws {
        var document = BriefDocument()
        let literal = "  let café = \"/tmp/e\u{301}/Q8_0\";\n\t// Never use 512 instead of 256.\n"
        let block = BriefBlock(text: literal, origin: .clipboard, exact: true)
        try document.apply([.append(section: .constraints, block: block)],
                           expectedRevision: document.revisionID, label: "Paste exact reference")
        #expect(Array(document.block(block.id)!.text.utf8) == Array(literal.utf8))
        #expect(document.markdown(title: "Test").contains(literal))
        #expect(throws: BriefDocumentError.protectedLiteral) {
            try document.apply([.replace(blockID: block.id, text: "Changed", origin: .voiceEdit, sources: [])],
                               expectedRevision: document.revisionID, label: "Voice replace")
        }
        #expect(throws: BriefDocumentError.protectedLiteral) {
            try document.apply([.remove(blockID: block.id)], expectedRevision: document.revisionID, label: "Remove")
        }
        try document.apply([.move(blockID: block.id, section: .changes, index: nil)],
                           expectedRevision: document.revisionID, label: "Move reference")
        #expect(document.block(block.id)?.exact == true)
        try document.apply([.replace(blockID: block.id, text: "Deliberately edited", origin: .typed, sources: [], allowExact: true)],
                           expectedRevision: document.revisionID, label: "Unlock and edit")
        #expect(document.block(block.id)?.exact == false)
        try document.undo()
        #expect(Array(document.block(block.id)!.text.utf8) == Array(literal.utf8))
    }

    @Test func durableFactDispositionsPreventResurrection() throws {
        var document = BriefDocument()
        let factID = UUID()
        let block = BriefBlock(text: "Use 256.", factIDs: [factID])
        try document.apply([.append(section: .constraints, block: block)], expectedRevision: document.revisionID, label: "Add")
        try document.apply([.replace(blockID: block.id, text: "Use 512.", origin: .typed, sources: [])],
                           expectedRevision: document.revisionID, label: "Explicit reversal")
        #expect(document.removedFactIDs.contains(factID))
        #expect(document.block(block.id)?.factIDs.isEmpty == true)
        try document.undo()
        #expect(!document.removedFactIDs.contains(factID))
        #expect(document.block(block.id)?.factIDs == [factID])
        try document.apply([.remove(blockID: block.id)], expectedRevision: document.revisionID, label: "Remove")
        let restored = try JSONDecoder().decode(BriefDocument.self, from: JSONEncoder().encode(document))
        #expect(restored.removedFactIDs.contains(factID))
        #expect(restored.blocks.isEmpty)
    }

    @Test func strictVoiceTargetsRejectAmbiguity() throws {
        var document = BriefDocument()
        let a = BriefBlock(text: "First")
        let b = BriefBlock(text: "Second")
        try document.apply([.append(section: .changes, block: a), .append(section: .changes, block: b)],
                           expectedRevision: document.revisionID, label: "Add")
        let command = try BriefVoiceParser.parse("Move the second requirement to constraints.", document: document,
                                                targetSection: .goal, selectedBlockIDs: [])
        #expect(command == .edits([.move(blockID: b.id, section: .constraints, index: nil)]))
        #expect(throws: BriefDocumentError.ambiguousTarget) {
            try BriefVoiceParser.parse("Remove requirement", document: document, targetSection: .changes, selectedBlockIDs: [])
        }
        #expect(throws: BriefDocumentError.ambiguousTarget) {
            try BriefVoiceParser.parse("Replace selected with one thing", document: document,
                                       targetSection: .changes, selectedBlockIDs: [a.id, b.id])
        }
        #expect(throws: BriefDocumentError.unsupportedCommand) {
            try BriefVoiceParser.parse("For example, delete the second paragraph.", document: document,
                                       targetSection: .changes, selectedBlockIDs: [b.id])
        }
        #expect(try BriefVoiceParser.parse("Undo.", document: document, targetSection: .changes, selectedBlockIDs: []) == .undo)
    }

    @Test func sourcesRequireExactUTF8IncludingCanonicalDifferences() throws {
        let text = "Keep e\u{301} and 👩🏽‍💻 exactly."
        let source = SourceReference(transcriptID: UUID(), startUTF8: 0, endUTF8: text.utf8.count, quote: text)
        #expect(BriefDocument.isValid(source, in: text))
        var composed = source
        composed.quote = "Keep é and 👩🏽‍💻 exactly."
        #expect(!BriefDocument.isValid(composed, in: text))
        var split = source
        split.startUTF8 = 6
        #expect(!BriefDocument.isValid(split, in: text))
    }

    @Test func focusedReviewRequiresNoPerFactCheckboxes() throws {
        let statement = "Use 256 and never overwrite the archive."
        let transcript = TranscriptRevision(rawText: statement, text: statement)
        let source = fullSource(transcript)
        let fact = Fact(kind: .constraint, status: .confirmed, text: statement, sources: [source], reviewed: false)
        var session = VoiceSession()
        session.transcripts = [transcript]
        session.facts = [fact]
        var document = BriefDocument()
        try document.apply([.append(section: .constraints,
                                    block: BriefBlock(text: statement, origin: .speech, sources: [source], factIDs: [fact.id]))],
                           expectedRevision: document.revisionID, label: "Take")
        #expect(document.reviewIssues(session: session).isEmpty)
        try document.markReviewed(session: session)
        #expect(document.isReviewed)
        try document.apply([.append(section: .goal, block: BriefBlock(text: "A deliberate typed instruction"))],
                           expectedRevision: document.revisionID, label: "Typed goal")
        #expect(!document.isReviewed)
    }

    @Test func correctionsFlagPassagesWhileArchivesStayRecoverable() throws {
        let original = TranscriptRevision(rawText: "Use 256.", text: "Use 256.")
        let corrected = TranscriptRevision(replacesID: original.id, rawText: original.rawText, text: "Use 512.")
        var session = VoiceSession()
        session.transcripts = [original, corrected]
        var document = BriefDocument()
        try document.apply([.append(section: .changes,
                                    block: BriefBlock(text: original.text, origin: .speech, sources: [fullSource(original)]))],
                           expectedRevision: document.revisionID, label: "Take")
        try document.validate(session: session)
        #expect(document.reviewIssues(session: session).contains { $0.kind == .staleSource && $0.severity == .blocker })
        #expect(throws: (any Error).self) { try document.markReviewed(session: session) }
        session.transcripts.removeAll { $0.id == original.id }
        #expect(throws: (any Error).self) { try document.validate(session: session) }
    }

    @Test func unsupportedNumbersAndPendingTakesBlockApproval() throws {
        let transcript = TranscriptRevision(rawText: "Keep 256.", text: "Keep 256.")
        var session = VoiceSession()
        session.transcripts = [transcript]
        var document = BriefDocument()
        try document.apply([.append(section: .constraints,
                                    block: BriefBlock(text: "Keep 512.", origin: .speech, sources: [fullSource(transcript)]))],
                           expectedRevision: document.revisionID, label: "Bad extraction")
        document.takes = [BriefTake(expectedRevision: document.revisionID)]
        let issues = document.reviewIssues(session: session)
        #expect(issues.contains { $0.kind == .unsupportedAddition })
        #expect(issues.contains { $0.kind == .pendingTake })
        #expect(throws: (any Error).self) { try document.markReviewed(session: session) }
        document.takes[0].status = .discarded
        #expect(!document.reviewIssues(session: session).contains { $0.kind == .pendingTake })
    }

    @Test func oldSessionMigrationRetainsDraftAndLiteralHeadings() throws {
        var legacy = VoiceSession()
        legacy.title = "A brief"
        legacy.drafts = [PromptRevision(detail: .standard,
            text: "# A brief\n\n## Goal\nKeep typed goal.\n\n## Constraints\n~~~text\n## Goal\n# literal comment\n~~~\n",
            factIDs: [], transcriptIDs: [], contextIDs: [], dispositions: [])]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "brief")
        let decoded = try JSONDecoder().decode(VoiceSession.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.brief == nil)
        let document = BriefDocument.migrating(session: decoded)
        #expect(document.section(.goal).blocks.first?.text == "Keep typed goal.")
        #expect(document.section(.constraints).blocks.first?.text.contains("## Goal\n# literal comment") == true)
        #expect(document.reviewIssues(session: decoded).contains { $0.kind == .migrated })
        #expect(decoded.drafts == legacy.drafts)
    }

    @Test func pendingUndoProposalsKeepMeaningAfterRelaunch() throws {
        var document = BriefDocument()
        document.pendingProposal = BriefProposal(expectedRevision: document.revisionID, edits: [], takeIDs: [],
                                                 label: "Undo the last change", action: .undo)
        let restored = try JSONDecoder().decode(BriefDocument.self, from: JSONEncoder().encode(document))
        #expect(restored.pendingProposal?.action == .undo)
        #expect(restored.pendingProposal?.expectedRevisionID == restored.revisionID)
        #expect(restored.pendingProposal?.summary == "Undo the last change")
    }

    @Test func malformedDocumentsAndJournalEndpointsFailSafely() throws {
        var malformed = BriefDocument()
        malformed.sections.removeLast()
        #expect(throws: (any Error).self) { try malformed.undo() }
        var duplicate = BriefDocument()
        let block = BriefBlock(text: "Duplicate")
        duplicate.sections[0].blocks = [block, block]
        #expect(throws: BriefDocumentError.duplicateBlock) { try duplicate.validateStructure() }
        var valid = BriefDocument()
        try valid.apply([.append(section: .goal, block: block)], expectedRevision: valid.revisionID, label: "Add")
        valid.sections[0].blocks[0].text = "Tampered journal endpoint"
        #expect(throws: (any Error).self) { try valid.undo() }
    }

    @Test func ordinaryTypingMayTemporarilyEmptyAPassage() throws {
        var document = BriefDocument()
        let block = BriefBlock(text: "Select all and replace")
        try document.apply([.append(section: .goal, block: block)], expectedRevision: document.revisionID, label: "Add")
        try document.apply([.replace(blockID: block.id, text: "", origin: .typed, sources: [])],
                           expectedRevision: document.revisionID, label: "Edit text")
        #expect(document.block(block.id)?.text == "")
        try document.validateStructure()
        #expect(document.reviewIssues(session: VoiceSession()).contains { $0.kind == .emptyDocument })
        try document.undo()
        #expect(document.block(block.id)?.text == block.text)
    }

    private func fullSource(_ transcript: TranscriptRevision) -> SourceReference {
        SourceReference(transcriptID: transcript.id, startUTF8: 0, endUTF8: transcript.text.utf8.count, quote: transcript.text)
    }
}
