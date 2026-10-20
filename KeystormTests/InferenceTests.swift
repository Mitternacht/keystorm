import Foundation
import Testing
@testable import Keystorm

struct InferenceTests {
    @Test func sourceChunksPreserveUnicodeAndEveryByte() {
        let source = String(repeating: "Keep café 🧠 and path /tmp/File.swift; use 256, not 512. ", count: 80)
        let transcript = TranscriptRevision(rawText: source, text: source)
        let chunks = LocalInference.chunks(transcript, maxBytes: 180)
        let bytes = Array(source.utf8)
        var covered = Set<Int>()
        for chunk in chunks {
            let end = chunk.startUTF8 + chunk.text.utf8.count
            #expect(String(bytes: bytes[chunk.startUTF8..<end], encoding: .utf8) == chunk.text)
            #expect(chunk.text.utf8.count <= 180)
            covered.formUnion(chunk.startUTF8..<end)
        }
        #expect(covered.count == bytes.count)
        #expect(chunks.count > 1)
    }

    @Test func missingClausesRemainAmbiguousSourceMaterial() throws {
        let source = "Use café. Do not upload audio."
        let transcript = TranscriptRevision(rawText: source, text: source)
        let chunk = try #require(LocalInference.chunks(transcript).first)
        let envelope = ExtractionEnvelope(complete: true, facts: [
            .init(kind: .requirement, status: .confirmed, text: "Use café.", quote: "Use café.", supersedesID: nil)
        ])
        let facts = try LocalInference.validate(envelope: envelope, chunk: chunk, transcript: transcript)
        let unresolved = try #require(facts.first(where: { $0.status == .ambiguous }))
        #expect(unresolved.sources.first?.quote.contains("Do not upload audio") == true)
        #expect(facts.allSatisfy { $0.sources.first?.transcriptID == transcript.id })
    }

    @Test func inventedEvidenceIsRejected() throws {
        let transcript = TranscriptRevision(rawText: "Use 256.", text: "Use 256.")
        let chunk = try #require(LocalInference.chunks(transcript).first)
        let envelope = ExtractionEnvelope(complete: true, facts: [
            .init(kind: .requirement, status: .confirmed, text: "Use 512.", quote: "Use 512.", supersedesID: nil)
        ])
        #expect(throws: (any Error).self) {
            try LocalInference.validate(envelope: envelope, chunk: chunk, transcript: transcript)
        }
    }

    @Test func repeatedQuotesNeedDisambiguation() throws {
        let transcript = TranscriptRevision(rawText: "Yes. Yes.", text: "Yes. Yes.")
        let chunk = try #require(LocalInference.chunks(transcript).first)
        let envelope = ExtractionEnvelope(complete: true, facts: [
            .init(kind: .decision, status: .confirmed, text: "Yes", quote: "Yes.", supersedesID: nil)
        ])
        #expect(throws: (any Error).self) {
            try LocalInference.validate(envelope: envelope, chunk: chunk, transcript: transcript)
        }
    }

    @Test func proposedReversalRequiresReview() throws {
        let old = Fact(kind: .decision, status: .confirmed, text: "Use 512", sources: [])
        let transcript = TranscriptRevision(rawText: "Actually use 256 instead.", text: "Actually use 256 instead.")
        let chunk = try #require(LocalInference.chunks(transcript).first)
        let envelope = ExtractionEnvelope(complete: true, facts: [
            .init(kind: .decision, status: .confirmed, text: "Use 256", quote: transcript.text, supersedesID: old.id.uuidString)
        ])
        let fact = try #require(LocalInference.validate(envelope: envelope, chunk: chunk,
            transcript: transcript, priorFacts: [old]).first)
        #expect(fact.supersedes == old.id)
        #expect(fact.status == .ambiguous)
        #expect(!fact.reviewed)
    }

    @Test func downloadableCatalogPinsEveryArtifact() {
        for model in ModelCatalog.models where model.installable {
            #expect(model.revision?.count == 40)
            #expect(!model.artifacts.isEmpty)
            #expect(model.artifacts.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
            #expect(model.downloadBytes > 0)
        }
        #expect(!ModelCatalog.models.first(where: { $0.id == "cohere-8bit" })!.installable)
    }

    @Test func lostNegationAndChangedNumbersRequireReview() {
        #expect(LocalInference.hasCriticalLiteralMismatch(statement: "Upload audio.", evidence: "Do not upload audio."))
        #expect(LocalInference.hasCriticalLiteralMismatch(statement: "Use 512.", evidence: "Use 256."))
        #expect(!LocalInference.hasCriticalLiteralMismatch(statement: "Use 256, not 512.", evidence: "Use 256, not 512."))
    }

    @Test func corruptSameSizeInstallationCanBeRepaired() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactURL = directory.appendingPathComponent("weights")
        try Data([1, 2, 3, 4]).write(to: artifactURL)
        let expectedHash = try LocalInference.sha256(artifactURL)
        let link = URL(string: "https://example.com")!
        let model = ModelDescriptor(id: "fixture", displayName: "Fixture", purpose: .speech,
            role: "Test", runtime: "Test", quantization: "Test", licenseURL: link,
            modelCardURL: link, runtimeURL: link, installable: true,
            repository: "fixture/model", revision: "fixture-revision",
            artifacts: [ModelArtifact(path: "weights", sha256: expectedHash, bytes: 4)])
        let configuration = ProcessingConfiguration(modelID: model.id, revision: "fixture-revision",
            runtime: "Test", quantization: "Test", artifactHashes: ["weights": expectedHash])
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("installation.json"))
        let inference = LocalInference(modelDirectory: root)
        #expect(try await inference.verifiedConfiguration(for: model) != nil)
        try Data([9, 8, 7, 6]).write(to: artifactURL)
        #expect(await inference.isInstalled(model))
        #expect(try await inference.verifiedConfiguration(for: model) == nil)
    }

    @Test func explicitInstallReusesVerifiedBytesForNewRevisionOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("fixture")
        let artifactURL = directory.appendingPathComponent("nested/weights")
        try FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: artifactURL)
        let expectedHash = try LocalInference.sha256(artifactURL)
        let link = URL(string: "https://example.com")!
        let model = ModelDescriptor(id: "fixture", displayName: "Fixture", purpose: .speech,
            role: "Test", runtime: "Test", quantization: "Test", licenseURL: link,
            modelCardURL: link, runtimeURL: link, installable: true,
            repository: "keystorm-invalid-local-reuse-fixture/does-not-exist", revision: "new-revision",
            artifacts: [ModelArtifact(path: "nested/weights", sha256: expectedHash, bytes: 4)])
        let oldConfiguration = ProcessingConfiguration(modelID: model.id, revision: "old-revision",
            runtime: "Old runtime", quantization: "Test", artifactHashes: ["nested/weights": expectedHash])
        try JSONEncoder().encode(oldConfiguration).write(to: directory.appendingPathComponent("installation.json"))
        let inference = LocalInference(modelDirectory: root)
        let installedBefore = await inference.isInstalled(model)
        #expect(!installedBefore)
        let configuration = try await inference.install(model) { _ in }
        #expect(configuration.id != oldConfiguration.id)
        #expect(configuration.revision == "new-revision")
        #expect(configuration.artifactHashes == oldConfiguration.artifactHashes)
        #expect(oldConfiguration.revision == "old-revision")
        #expect(oldConfiguration.runtime == "Old runtime")
        let receipt = try await inference.configuration(for: model)
        #expect(receipt == configuration)
        let installedBytes = try Data(contentsOf: artifactURL)
        #expect(installedBytes == bytes)
        let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(children == [model.id])
    }

    @Test func packedEightBitTensorFailsFourBitAudit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = #"{"quantization":{"bits":4,"group_size":64}}"#
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        let header: [String: Any] = [
            "language_model.model.test.weight": ["dtype": "U32", "shape": [8, 16]],
            "language_model.model.test.scales": ["dtype": "BF16", "shape": [8, 1]]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: header)
        var littleEndianLength = UInt64(encoded.count).littleEndian
        var data = withUnsafeBytes(of: &littleEndianLength) { Data($0) }
        data.append(encoded)
        try data.write(to: directory.appendingPathComponent("model.safetensors"))
        #expect(throws: (any Error).self) { try LocalInference.auditTextQuantization(at: directory) }
    }
}
