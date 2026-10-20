import Foundation
import Testing
@testable import Keystorm

@MainActor
struct WorkspaceTests {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func `Manual review prepares an exportable prompt without installing weights`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(root: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.sqlite").path))
        await model.initialize(loadLibrary: true)
        #expect(model.installedModelIDs.isEmpty)
        #expect(model.elapsed == 0)
        let text = "Use 256, not 512. Keep project Photon offline."
        await model.importTranscript(text: text)
        let transcript = try #require(model.selectedSession?.currentTranscripts.first)
        #expect(model.selectedSession?.facts.isEmpty == true)
        await model.addFact(transcriptID: transcript.id, text: text, kind: .requirement, status: .confirmed)
        await model.preparePrompt()
        #expect(model.error == nil)
        let first = try #require(model.currentDraft)
        #expect(first.text.contains(text))
        #expect(!first.reviewed)
        await model.reviewDraft()
        #expect(model.currentDraft?.reviewed == true)
        await model.amendDraft(text: first.text + "\n\nManually reviewed addition.")
        #expect(model.selectedSession?.drafts.count == 2)
        #expect(model.currentDraft?.reviewed == false)
        #expect(model.currentDraft?.id != first.id)
        #expect(model.selectedSession?.drafts.first?.text == first.text)
        await model.stopForTermination()
    }

    @Test func `Correction and undo preserve originals and invalidate drafts`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(root: root)
        await model.initialize(loadLibrary: true)
        let original = "Do not send audio to a server."
        await model.importTranscript(text: original)
        let transcript = try #require(model.selectedSession?.currentTranscripts.first)
        await model.addFact(transcriptID: transcript.id, text: original, kind: .constraint, status: .confirmed)
        await model.preparePrompt()
        await model.correctTranscript(id: transcript.id, text: "Never upload recordings.")
        #expect(model.error == nil)
        #expect(model.selectedSession?.transcripts.count == 2)
        #expect(model.selectedSession?.transcripts.first?.rawText == original)
        #expect(model.currentDraft?.stale == true)
        await model.undoLastCorrection()
        #expect(model.selectedSession?.transcripts.count == 3)
        #expect(model.selectedSession?.currentTranscripts.first?.text == original)
        #expect(model.selectedSession?.transcripts.first?.rawText == original)
        await model.stopForTermination()
    }

    @Test func `Revoking automatic terminology affects future capture without rewriting sources`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(root: root)
        await model.initialize(loadLibrary: true)
        await model.importTranscript(text: "Project photon remains local.")
        let original = model.selectedSession?.transcripts
        let entry = DictionaryEntry(canonical: "Photon", aliases: ["photon"], automatic: true)
        await model.addDictionaryEntry(entry)
        await model.setDictionaryAutomatic(id: entry.id, enabled: false)
        #expect(model.error == nil)
        #expect(model.dictionary.first?.automatic == false)
        #expect(model.selectedSession?.transcripts == original)
        let reopened = WorkspaceModel(root: root)
        await reopened.initialize(loadLibrary: true)
        #expect(reopened.dictionary.first?.automatic == false)
        await model.stopForTermination()
        await reopened.stopForTermination()
    }

    @Test func `Unsupported extraction stays explicit rather than producing a fake prompt`() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(root: root)
        await model.initialize(loadLibrary: true)
        await model.importTranscript(text: "Preserve every requirement, including distant reversals.")
        await model.preparePrompt()
        #expect(model.currentDraft == nil)
        #expect(model.error?.contains("Install") == true)
        #expect(model.selectedSession?.facts.isEmpty == true)
        await model.stopForTermination()
    }
}
