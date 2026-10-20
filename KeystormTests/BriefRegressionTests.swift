import Foundation
import Testing
@testable import Keystorm

struct BriefRegressionTests {
    @Test("Undoing accepted material records omission, survives relaunch, and redo restores it")
    func undoMaterialDisposition() throws {
        var session = reversalSession()
        session.facts = [session.facts[0]]
        let fact = session.facts[0]
        var brief = BriefDocument()
        let block = BriefBlock(text: fact.text, origin: .speech, sources: fact.sources, factIDs: [fact.id])
        try brief.apply([.append(section: .constraints, block: block)], expectedRevision: brief.revisionID, label: "Accept material")
        try brief.undo()
        #expect(brief.blocks.isEmpty)
        #expect(brief.removedFactIDs == [fact.id])
        #expect(brief.activeLedgerFacts(in: session).isEmpty)
        brief = try JSONDecoder().decode(BriefDocument.self, from: JSONEncoder().encode(brief))
        try brief.validate(session: session)
        try brief.redo()
        #expect(brief.block(block.id)?.text == fact.text)
        #expect(!brief.removedFactIDs.contains(fact.id))
        try brief.undo()
        #expect(brief.removedFactIDs.contains(fact.id))
    }

    @Test("Removing one duplicate representation does not omit a still-visible fact")
    func undoKeepsStillRepresentedFacts() throws {
        let factID = UUID()
        var brief = BriefDocument()
        let first = BriefBlock(text: "Shared fact", factIDs: [factID])
        let second = BriefBlock(text: "Another representation", factIDs: [factID])
        try brief.apply([.append(section: .goal, block: first)], expectedRevision: brief.revisionID, label: "First")
        try brief.apply([.append(section: .constraints, block: second)], expectedRevision: brief.revisionID, label: "Second")
        try brief.undo()
        #expect(brief.block(first.id) != nil)
        #expect(!brief.removedFactIDs.contains(factID))
    }

    @Test("Explicit reversals require choosing the current instruction and can be undone")
    func reversalResolution() throws {
        let session = reversalSession()
        var brief = try reversalBrief(session)
        let old = session.facts[0]
        let correction = session.facts[1]
        #expect(brief.reviewIssues(session: session).contains { $0.kind == .superseded && $0.severity == .blocker })
        #expect(throws: (any Error).self) { try brief.markReviewed(session: session) }
        let edits = try brief.supersessionEdits(factID: correction.id, session: session)
        #expect(edits.count == 2)
        try brief.apply(edits, expectedRevision: brief.revisionID, label: "Use explicit correction")
        #expect(brief.section(.constraints).blocks.map(\.text) == [correction.text])
        #expect(brief.removedFactIDs.contains(old.id))
        #expect(!brief.activeLedgerFacts(in: session).contains { $0.id == old.id })
        #expect(!brief.reviewIssues(session: session).contains { $0.kind == .superseded && $0.severity == .blocker })
        try brief.markReviewed(session: session)
        try brief.undo()
        #expect(brief.blocks.contains { $0.factIDs.contains(old.id) })
        #expect(brief.reviewIssues(session: session).contains { $0.kind == .superseded && $0.severity == .blocker })
        try brief.redo()
        #expect(brief.removedFactIDs.contains(old.id))
        #expect(!brief.reviewIssues(session: session).contains { $0.kind == .superseded && $0.severity == .blocker })
        #expect(session.facts[0].status == .confirmed, "Original ledger records remain unchanged.")
    }

    @Test("Recency alone never establishes a supersession")
    func unrelatedFactsDoNotCreateReversals() throws {
        var session = reversalSession()
        session.facts[1].supersedes = nil
        let brief = try reversalBrief(session)
        #expect(!brief.reviewIssues(session: session).contains { $0.kind == .superseded && $0.severity == .blocker })
        #expect(throws: (any Error).self) { try brief.supersessionEdits(factID: session.facts[1].id, session: session) }
    }

    @Test("Old brief JSON decodes when undo omission metadata is absent")
    func undoMetadataMigration() throws {
        let document = BriefDocument()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        json.removeValue(forKey: "undoDispositions")
        let restored = try JSONDecoder().decode(BriefDocument.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.undoDispositions == nil)
        try restored.validateStructure()
    }

    private func reversalSession() -> VoiceSession {
        let first = TranscriptRevision(rawText: "Use 256 for the cache.", text: "Use 256 for the cache.")
        let second = TranscriptRevision(rawText: "Correction: use 512 for the cache only.", text: "Correction: use 512 for the cache only.")
        let old = Fact(kind: .constraint, status: .confirmed, text: first.text, sources: [source(first)])
        let correction = Fact(kind: .constraint, status: .ambiguous, text: second.text, sources: [source(second)], supersedes: old.id)
        var session = VoiceSession()
        session.transcripts = [first, second]
        session.facts = [old, correction]
        return session
    }

    private func reversalBrief(_ session: VoiceSession) throws -> BriefDocument {
        var brief = BriefDocument()
        let old = session.facts[0]
        let correction = session.facts[1]
        try brief.apply([
            .append(section: .constraints, block: BriefBlock(text: old.text, origin: .speech, sources: old.sources, factIDs: [old.id])),
            .append(section: .questions, block: BriefBlock(text: correction.text, origin: .speech, sources: correction.sources, factIDs: [correction.id]))
        ], expectedRevision: brief.revisionID, label: "Add source material")
        return brief
    }

    private func source(_ transcript: TranscriptRevision) -> SourceReference {
        SourceReference(transcriptID: transcript.id, startUTF8: 0, endUTF8: transcript.text.utf8.count, quote: transcript.text)
    }
}

@MainActor
struct BriefCoordinatorRegressionTests {
    @Test("Recomputing a stale proposal keeps its recorded material and the latest typed text")
    func recomputeStaleProposal() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(root: root)
        await model.initialize(loadLibrary: true)
        await model.appendBriefBlock(text: "Original typed paragraph.")
        let typedID = try #require(model.currentBrief?.blocks.first?.id)
        try await addMaterial("Keep recovery local.", model)
        await model.prepareBrief()
        let proposal = try #require(model.pendingBriefProposal)
        let factID = try #require(model.selectedSession?.facts.first?.id)
        model.updateBriefBlock(id: typedID, text: "Typed paragraph, amended while reviewing.")
        await model.refreshBriefProposal()
        #expect(model.error == nil)
        #expect(model.pendingBriefProposal?.id != proposal.id)
        #expect(model.pendingBriefProposal?.expectedRevision == model.currentBrief?.revisionID)
        #expect(model.currentBrief?.removedFactIDs.contains(factID) == false)
        #expect(model.currentBrief?.takes.first?.status == .pending)
        await model.acceptBriefProposal()
        #expect(model.currentBrief?.blocks.count == 2)
        #expect(model.currentBrief?.block(typedID)?.text == "Typed paragraph, amended while reviewing.")
        #expect(model.currentBrief?.takes.first?.status == .applied)
        await model.stopForTermination()
    }

    @Test("An undone take is not offered again when preparing later material")
    func undoneTakeStaysOmitted() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(root: root)
        await model.initialize(loadLibrary: true)
        try await addMaterial("Use a cloud service.", model)
        await model.prepareBrief()
        await model.acceptBriefProposal()
        let oldFactID = try #require(model.selectedSession?.facts.first?.id)
        await model.undoBrief()
        await model.prepareBrief()
        #expect(model.pendingBriefProposal == nil)
        #expect(model.currentBrief?.removedFactIDs.contains(oldFactID) == true)
        try await addMaterial("Keep microphone recordings local.", model)
        await model.prepareBrief()
        #expect(model.pendingBriefProposal?.edits.count == 1)
        await model.acceptBriefProposal()
        #expect(model.currentBrief?.blocks.map(\.text) == ["Keep microphone recordings local."])
        await model.stopForTermination()
    }

    @Test("Typed exact text and actual clipboard insertions retain honest origins")
    func exactInsertionOrigins() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(root: root)
        await model.initialize(loadLibrary: true)
        await model.insertExactReference(text: "Manually typed exact text.", origin: .typed)
        #expect(model.currentBrief?.blocks.first?.origin == .typed)
        #expect(model.currentBrief?.blocks.first?.exact == true)
        #expect(model.selectedSession?.contexts.isEmpty == true)
        await model.insertExactReference(text: "Copied exact text.")
        #expect(model.currentBrief?.blocks.last?.origin == .clipboard)
        #expect(model.selectedSession?.contexts.last?.content == "Copied exact text.")
        await model.stopForTermination()
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-BriefRegression-\(UUID().uuidString)")
    }

    private func addMaterial(_ text: String, _ model: WorkspaceModel) async throws {
        model.captureIntent = .addMaterial
        await model.importTranscript(text: text)
        let transcript = try #require(model.selectedSession?.currentTranscripts.last)
        await model.addFact(transcriptID: transcript.id, text: text, kind: .requirement, status: .confirmed)
    }
}
