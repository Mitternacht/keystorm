import Foundation
import Testing
@testable import Keystorm

struct BriefInferenceTests {
    @Test("Structured edits cannot guess between unselected passages")
    func ambiguousTargets() throws {
        var document = BriefDocument()
        let first = BriefBlock(text: "Keep local processing.")
        let second = BriefBlock(text: "Keep audio recovery.")
        try document.apply([.append(section: .changes, block: first), .append(section: .changes, block: second)],
            expectedRevision: document.revisionID, label: "Fixture")
        let envelope = BriefEditEnvelope(complete: true, ambiguous: false, reason: "", edits: [
            .init(operation: "remove", blockID: first.id.uuidString, section: nil, text: "")
        ])
        #expect(throws: (any Error).self) {
            try LocalInference.validatedBriefEdits(envelope, document: document,
                targetSection: .changes, selectedBlockIDs: [], sources: [])
        }
        let selected = try LocalInference.validatedBriefEdits(envelope, document: document,
            targetSection: .changes, selectedBlockIDs: [first.id], sources: [])
        #expect(selected == [.remove(blockID: first.id, allowExact: false)])
    }

    @Test("Structured edits reject unknown IDs, exact references, and incomplete output")
    func boundedEdits() throws {
        var document = BriefDocument()
        let exact = BriefBlock(text: "let exact = 256", exact: true)
        try document.apply([.append(section: .constraints, block: exact)], expectedRevision: document.revisionID, label: "Fixture")
        let unknown = BriefEditEnvelope(complete: true, ambiguous: false, reason: "", edits: [
            .init(operation: "replace", blockID: UUID().uuidString, section: nil, text: "Invented")
        ])
        #expect(throws: (any Error).self) {
            try LocalInference.validatedBriefEdits(unknown, document: document,
                targetSection: .constraints, selectedBlockIDs: [exact.id], sources: [])
        }
        let protected = BriefEditEnvelope(complete: true, ambiguous: false, reason: "", edits: [
            .init(operation: "remove", blockID: exact.id.uuidString, section: nil, text: "")
        ])
        #expect(throws: (any Error).self) {
            try LocalInference.validatedBriefEdits(protected, document: document,
                targetSection: .constraints, selectedBlockIDs: [exact.id], sources: [])
        }
        let incomplete = BriefEditEnvelope(complete: false, ambiguous: false, reason: "", edits: [
            .init(operation: "append", blockID: nil, section: nil, text: "A partial requirement")
        ])
        #expect(throws: (any Error).self) {
            try LocalInference.validatedBriefEdits(incomplete, document: document,
                targetSection: .constraints, selectedBlockIDs: [], sources: [])
        }
    }

    @Test("Model hashes are reused until nanosecond file metadata changes")
    func verificationCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Integrity-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = directory.appendingPathComponent("weights")
        try Data([1, 2, 3, 4]).write(to: artifact)
        let expected = try LocalInference.sha256(artifact)
        let link = URL(string: "https://example.com")!
        let model = ModelDescriptor(id: "fixture", displayName: "Fixture", purpose: .speech,
            role: "Test", runtime: "Test", quantization: "Test", licenseURL: link,
            modelCardURL: link, runtimeURL: link, installable: true,
            repository: "fixture/model", revision: "test",
            artifacts: [ModelArtifact(path: "weights", sha256: expected, bytes: 4)])
        let inference = LocalInference(modelDirectory: root)
        #expect(try await inference.verifyArtifacts(model, at: directory))
        #expect(try await !inference.verifyArtifacts(model, at: directory))
        #expect(await inference.integrityVerificationCount == 1)
        let oldDate = try artifact.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try Data([9, 8, 7, 6]).write(to: artifact)
        if let oldDate {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: artifact.path)
        }
        await #expect(throws: (any Error).self) {
            try await inference.verifyArtifacts(model, at: directory)
        }
        #expect(await inference.integrityVerificationCount == 1)
    }
}
