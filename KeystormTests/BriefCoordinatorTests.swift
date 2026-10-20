import Foundation
import Testing
@testable import Keystorm

@MainActor
struct BriefCoordinatorTests {
    private func root() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Brief-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func addMaterial(_ text: String, model: WorkspaceModel) async throws {
        model.captureIntent = .addMaterial
        await model.importTranscript(text: text)
        let transcript = try #require(model.selectedSession?.currentTranscripts.last)
        await model.addFact(transcriptID: transcript.id, text: text, kind: .requirement, status: .confirmed)
    }

    @Test("Several takes do not require every fact checkbox")
    func severalTakes() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(root: directory)
        await model.initialize(loadLibrary: true)
        try await addMaterial("Keep 256, not 512. Do not upload audio.", model: model)
        await model.prepareBrief()
        #expect(model.error == nil)
        #expect(model.currentBrief?.blocks.isEmpty == true)
        #expect(model.pendingBriefProposal?.edits.count == 1)
        await model.acceptBriefProposal()
        let originalID = try #require(model.currentBrief?.blocks.first?.id)
        try await addMaterial("Allow pause and resume across launches.", model: model)
        await model.prepareBrief()
        #expect(model.currentBrief?.blocks.count == 1)
        await model.acceptBriefProposal()
        #expect(model.currentBrief?.blocks.count == 2)
        #expect(model.currentBrief?.block(originalID)?.text == "Keep 256, not 512. Do not upload audio.")
        #expect(model.selectedSession?.facts.allSatisfy { !$0.reviewed } == true)
        await model.reviewBrief()
        #expect(model.currentBrief?.isReviewed == true)
        let snapshot = try await model.reviewedBriefSnapshot()
        #expect(snapshot.text.contains("not 512"))
        #expect(model.isCurrentBrief(snapshot))
        let destination = directory.appendingPathComponent("brief.md")
        try await model.exportBrief(to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == snapshot.text)
        let sidecar = try Data(contentsOf: destination.appendingPathExtension("provenance.json"))
        let provenance = try JSONDecoder().decode(BriefTransfer.Provenance.self, from: sidecar)
        #expect(provenance.dispositions.count == 2)
        #expect(provenance.dispositions.allSatisfy { $0.disposition == "included" })
        await model.stopForTermination()
    }

    @Test("Typing preserves edits and rejects stale acceptance")
    func staleProposal() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(root: directory)
        await model.initialize(loadLibrary: true)
        await model.appendBriefBlock(text: "Existing typed constraint.")
        let blockID = try #require(model.currentBrief?.blocks.first?.id)
        try await addMaterial("Add local recovery.", model: model)
        await model.prepareBrief()
        let oldRevision = try #require(model.pendingBriefProposal?.expectedRevision)
        model.updateBriefBlock(id: blockID, text: "Existing typed constraint, amended while reviewing.")
        #expect(model.currentBrief?.revisionID != oldRevision)
        await model.acceptBriefProposal()
        #expect(model.error?.contains("changed") == true)
        #expect(model.currentBrief?.blocks.count == 1)
        #expect(model.currentBrief?.block(blockID)?.text.contains("amended") == true)
        await model.discardBriefProposal()
        await model.prepareBrief()
        #expect(model.pendingBriefProposal == nil)
        #expect(model.currentBrief?.blocks.count == 1)
        await model.stopForTermination()
    }

    @Test("Edit commands stay out of the requirement ledger")
    func editCommandsAreNotRequirements() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(root: directory)
        await model.initialize(loadLibrary: true)
        await model.appendBriefBlock(text: "Use a remote service.")
        model.selectedBlockID = try #require(model.currentBrief?.blocks.first?.id)
        await model.proposeBriefCommand(text: "replace selected with Keep all processing local.")
        #expect(model.error == nil)
        #expect(model.selectedSession?.facts.isEmpty == true)
        #expect(model.currentBrief?.blocks.first?.text == "Use a remote service.")
        #expect(model.currentBrief?.takes.last?.intent == .editBrief)
        let commandTranscript = try #require(model.selectedSession?.currentTranscripts.last)
        await model.addFact(transcriptID: commandTranscript.id, text: commandTranscript.text, kind: .requirement, status: .confirmed)
        #expect(model.selectedSession?.facts.isEmpty == true)
        await model.acceptBriefProposal()
        #expect(model.currentBrief?.blocks.first?.text == "Keep all processing local.")
        #expect(model.currentBrief?.blocks.first?.sources.first?.quote == commandTranscript.text)
        await model.reviewBrief()
        #expect(model.currentBrief?.isReviewed == true)
        await model.stopForTermination()
    }

    @Test("Material that resembles an edit remains material")
    func materialIsNotACommand() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(root: directory)
        await model.initialize(loadLibrary: true)
        await model.appendBriefBlock(text: "Preserve this paragraph.")
        try await addMaterial("The example command is delete the second paragraph.", model: model)
        await model.prepareBrief()
        await model.acceptBriefProposal()
        #expect(model.currentBrief?.blocks.count == 2)
        #expect(model.currentBrief?.blocks.first?.text == "Preserve this paragraph.")
        #expect(model.selectedSession?.facts.count == 1)
        await model.stopForTermination()
    }

    @Test("Typing coalesces durably and undo survives reopening")
    func durableTypingUndo() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(root: directory)
        await model.initialize(loadLibrary: true)
        await model.appendBriefBlock(text: "Original.")
        let id = try #require(model.currentBrief?.blocks.first?.id)
        model.updateBriefBlock(id: id, text: "Changed once.")
        model.updateBriefBlock(id: id, text: "Changed twice with café 🧠.")
        await model.flushBriefEdits()
        #expect(model.currentBrief?.history.count == 2)
        await model.stopForTermination()
        let reopened = WorkspaceModel(root: directory)
        await reopened.initialize(loadLibrary: true)
        #expect(reopened.currentBrief?.block(id)?.text == "Changed twice with café 🧠.")
        await reopened.undoBrief()
        #expect(reopened.currentBrief?.block(id)?.text == "Original.")
        await reopened.redoBrief()
        #expect(reopened.currentBrief?.block(id)?.text == "Changed twice with café 🧠.")
        await reopened.stopForTermination()
    }

    @Test("Removed requirements are not resurrected by preparation")
    func removedFactsStayRemoved() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(root: directory)
        await model.initialize(loadLibrary: true)
        try await addMaterial("Support a cloud service.", model: model)
        await model.prepareBrief()
        await model.acceptBriefProposal()
        let id = try #require(model.currentBrief?.blocks.first?.id)
        await model.removeBriefBlock(id: id)
        await model.prepareBrief()
        #expect(model.pendingBriefProposal == nil)
        #expect(model.currentBrief?.blocks.isEmpty == true)
        #expect(model.currentBrief?.removedFactIDs.count == 1)
        await model.undoBrief()
        #expect(model.currentBrief?.block(id)?.text == "Support a cloud service.")
        await model.stopForTermination()
    }

    @Test("Exact references require deliberate unlocking")
    func exactReferences() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(root: directory)
        await model.initialize(loadLibrary: true)
        let code = "let café = \"/tmp/Exact.swift\"\n// Never upload this.\n"
        await model.insertExactReference(text: code, filePath: "/tmp/Exact.swift")
        let block = try #require(model.currentBrief?.blocks.first)
        #expect(block.exact)
        #expect(model.selectedSession?.contexts.last?.content == code)
        model.updateBriefBlock(id: block.id, text: "Accidental replacement")
        #expect(model.currentBrief?.block(block.id)?.text == code)
        await model.unlockBriefBlock(id: block.id)
        model.updateBriefBlock(id: block.id, text: "Deliberately edited reference.")
        await model.flushBriefEdits()
        #expect(model.currentBrief?.block(block.id)?.text == "Deliberately edited reference.")
        #expect(model.selectedSession?.contexts.last?.content == code)
        await model.stopForTermination()
    }

    @Test(arguments: [CaptureIntent.editBrief, .addMaterial])
    func trashedTakesCannotBlockOrEnterActiveMaterialProposals(intent: CaptureIntent) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(root: directory)
        await model.initialize(loadLibrary: true)
        await model.appendBriefBlock(text: "Preserve this typed paragraph.")
        model.captureIntent = intent
        if intent == .addMaterial {
            try await addMaterial("Add an obsolete network upload.", model: model)
        } else {
            await model.importTranscript(text: "replace selected with obsolete network upload.")
        }
        let trashedTake = try #require(model.currentBrief?.takes.last)
        await model.trashTake(id: trashedTake.id)
        #expect(model.error == nil)
        try await addMaterial("Keep current processing local.", model: model)
        let activeTakeID = try #require(model.currentBrief?.takes.last?.id)
        await model.prepareBrief()
        #expect(model.error == nil)
        let proposal = try #require(model.pendingBriefProposal)
        #expect(proposal.takeIDs == [activeTakeID])
        #expect(!proposal.takeIDs.contains(trashedTake.id))
        await model.acceptBriefProposal()
        #expect(model.currentBrief?.blocks.map(\.text) == ["Preserve this typed paragraph.", "Keep current processing local."])
        #expect(model.currentBrief?.takes.first(where: { $0.id == trashedTake.id })?.status == .pending)
        #expect(model.currentBrief?.takes.first(where: { $0.id == trashedTake.id })?.trashedAt != nil)
        await model.stopForTermination()
    }

    @Test("A staged export is not current after another edit")
    func exportRevisionGuard() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(root: directory)
        await model.initialize(loadLibrary: true)
        await model.appendBriefBlock(text: "A reviewed instruction.")
        await model.reviewBrief()
        let snapshot = try await model.reviewedBriefSnapshot()
        let staged = try BriefTransfer.prepare(snapshot, to: directory.appendingPathComponent("out.md"), includeProvenance: true)
        defer { BriefTransfer.discard(staged) }
        let id = try #require(model.currentBrief?.blocks.first?.id)
        model.updateBriefBlock(id: id, text: "An unreviewed new instruction.")
        #expect(!model.isCurrentBrief(snapshot))
        #expect(!FileManager.default.fileExists(atPath: staged.destination.path))
        await model.stopForTermination()
    }
}
