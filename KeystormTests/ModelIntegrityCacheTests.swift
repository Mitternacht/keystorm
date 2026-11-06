import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Keystorm

/// Temporary directories and tiny synthetic "models" only. Nothing touches Application Support.
struct ModelIntegrityCacheTests {
    private struct Fixture {
        let root: URL
        let modelDirectory: URL
        let model: ModelDescriptor
        let files: [URL]

        func engine() -> LocalInference { LocalInference(modelDirectory: root) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-IntegrityCache-\(UUID().uuidString)", isDirectory: true)
        let id = "synthetic-model"
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("weights"), withIntermediateDirectories: true)
        let contents: [(String, Data)] = [
            ("config.json", Data(repeating: 0x41, count: 4_096)),
            ("weights/model.bin", Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        ]
        var artifacts: [ModelArtifact] = []
        var files: [URL] = []
        for (path, data) in contents {
            let url = directory.appendingPathComponent(path)
            try data.write(to: url)
            files.append(url)
            artifacts.append(ModelArtifact(path: path, sha256: Self.digest(data), bytes: Int64(data.count)))
        }
        let url = URL(string: "https://example.invalid/model")!
        let model = ModelDescriptor(id: id, displayName: "Synthetic", purpose: .speech, role: "test",
            runtime: "none", quantization: "none", licenseURL: url, modelCardURL: url, runtimeURL: url,
            installable: true, repository: "none/none", revision: "0", artifacts: artifacts)
        return Fixture(root: root, modelDirectory: directory, model: model, files: files)
    }

    @Test("A new process skips the full hash for files it has already verified")
    func secondProcessUsesPersistedRecord() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let first = fixture.engine()
        #expect(try await first.verifyArtifacts(fixture.model, at: fixture.modelDirectory))
        #expect(await first.integrityVerificationCount == 1)
        #expect(await first.integrityCacheHitCount == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(ModelIntegrityStore.fileName).path))

        // A fresh engine stands in for a new worker process: no in-memory fingerprint.
        let second = fixture.engine()
        #expect(try await second.verifyArtifacts(fixture.model, at: fixture.modelDirectory))
        #expect(await second.integrityVerificationCount == 0)
        #expect(await second.integrityCacheHitCount == 1)
        // The per-process fast path still answers without touching the record again.
        #expect(try await second.verifyArtifacts(fixture.model, at: fixture.modelDirectory) == false)
        #expect(await second.integrityCacheHitCount == 1)
    }

    @Test("Forcing a check always hashes, because it is the explicit repair path")
    func forceAlwaysHashes() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.engine().verifyArtifacts(fixture.model, at: fixture.modelDirectory)
        let engine = fixture.engine()
        _ = try await engine.verifyArtifacts(fixture.model, at: fixture.modelDirectory, force: true)
        #expect(await engine.integrityVerificationCount == 1)
        #expect(await engine.integrityCacheHitCount == 0)
    }

    @Test("Changed content is caught even when the size stays the same")
    func sameSizeEditIsDetected() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.engine().verifyArtifacts(fixture.model, at: fixture.modelDirectory)
        var edited = try Data(contentsOf: fixture.files[1])
        edited[100] ^= 0xFF
        try edited.write(to: fixture.files[1])
        let engine = fixture.engine()
        await #expect(throws: (any Error).self) {
            try await engine.verifyArtifacts(fixture.model, at: fixture.modelDirectory)
        }
        #expect(await engine.integrityCacheHitCount == 0)
    }

    @Test("Putting the modification time back does not hide an edit")
    func restoredModificationTimeIsDetected() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.engine().verifyArtifacts(fixture.model, at: fixture.modelDirectory)
        let original = try #require(try FileManager.default.attributesOfItem(atPath: fixture.files[1].path)[.modificationDate] as? Date)
        var edited = try Data(contentsOf: fixture.files[1])
        edited[7] ^= 0x01
        try edited.write(to: fixture.files[1])
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: fixture.files[1].path)
        let engine = fixture.engine()
        await #expect(throws: (any Error).self) {
            try await engine.verifyArtifacts(fixture.model, at: fixture.modelDirectory)
        }
    }

    @Test("A size change is rejected before any record is consulted")
    func sizeChangeIsDetected() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.engine().verifyArtifacts(fixture.model, at: fixture.modelDirectory)
        let handle = try FileHandle(forWritingTo: fixture.files[0])
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00]))
        try handle.close()
        let engine = fixture.engine()
        await #expect(throws: (any Error).self) {
            try await engine.verifyArtifacts(fixture.model, at: fixture.modelDirectory)
        }
        #expect(await engine.integrityCacheHitCount == 0)
    }

    @Test("A replaced file has a new identity and is hashed again")
    func replacedFileIsDetected() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.engine().verifyArtifacts(fixture.model, at: fixture.modelDirectory)
        // Identical bytes in a new inode: still correct, but not the file the record describes.
        let data = try Data(contentsOf: fixture.files[0])
        let replacement = fixture.files[0].deletingLastPathComponent().appendingPathComponent("replacement.tmp")
        try data.write(to: replacement)
        _ = try FileManager.default.replaceItemAt(fixture.files[0], withItemAt: replacement)
        let engine = fixture.engine()
        #expect(try await engine.verifyArtifacts(fixture.model, at: fixture.modelDirectory))
        #expect(await engine.integrityCacheHitCount == 0)
        #expect(await engine.integrityVerificationCount == 1)
    }

    @Test("A record made for a different pinned digest never vouches for the current catalog")
    func catalogDigestChangeInvalidatesRecord() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.engine().verifyArtifacts(fixture.model, at: fixture.modelDirectory)
        var other = fixture.model
        other.artifacts[1] = ModelArtifact(path: other.artifacts[1].path,
            sha256: String(repeating: "0", count: 64), bytes: other.artifacts[1].bytes)
        let engine = fixture.engine()
        await #expect(throws: (any Error).self) {
            try await engine.verifyArtifacts(other, at: fixture.modelDirectory)
        }
        #expect(await engine.integrityCacheHitCount == 0)
    }

    @Test("A damaged or foreign record file confirms nothing and is replaced by the next verification")
    func damagedRecordFileIsIgnored() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let recordFile = fixture.root.appendingPathComponent(ModelIntegrityStore.fileName)
        for junk in [Data("not json".utf8), Data("{\"version\":99,\"records\":[]}".utf8), Data()] {
            try junk.write(to: recordFile)
            let engine = fixture.engine()
            #expect(try await engine.verifyArtifacts(fixture.model, at: fixture.modelDirectory))
            #expect(await engine.integrityCacheHitCount == 0)
            #expect(await engine.integrityVerificationCount == 1)
        }
        let healed = fixture.engine()
        _ = try await healed.verifyArtifacts(fixture.model, at: fixture.modelDirectory)
        #expect(await healed.integrityCacheHitCount == 1)
    }

    @Test("The store keeps unrelated records, replaces a path's record and bounds its size")
    func storeBookkeeping() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-IntegrityStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.bin")
        let b = directory.appendingPathComponent("b.bin")
        try Data("alpha".utf8).write(to: a)
        try Data("bravo".utf8).write(to: b)
        let store = ModelIntegrityStore(modelDirectory: directory)
        let identityA = try #require(ModelFileIdentity.current(at: a))
        let identityB = try #require(ModelFileIdentity.current(at: b))
        let digestA = String(repeating: "a", count: 64)
        let digestB = String(repeating: "b", count: 64)
        #expect(!store.confirms([identityA], expectedSHA256: [digestA]))
        store.remember([identityA], expectedSHA256: [digestA])
        store.remember([identityB], expectedSHA256: [digestB])
        #expect(store.confirms([identityA, identityB], expectedSHA256: [digestA, digestB]))
        #expect(!store.confirms([identityA], expectedSHA256: [digestB]))
        #expect(!store.confirms([], expectedSHA256: []))
        #expect(!store.confirms([identityA], expectedSHA256: []))
        // Re-verifying one path replaces only its record.
        store.remember([identityA], expectedSHA256: [String(repeating: "c", count: 64)])
        #expect(!store.confirms([identityA], expectedSHA256: [digestA]))
        #expect(store.confirms([identityB], expectedSHA256: [digestB]))
        #expect(store.load().count == 2)
        store.removeAll()
        #expect(store.load().isEmpty)
    }

    @Test("Identity needs a regular file: a missing file or a symbolic link has none")
    func identityRequiresRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-IntegrityIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("real.bin")
        try Data("x".utf8).write(to: file)
        let link = directory.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(ModelFileIdentity.current(at: file) != nil)
        #expect(ModelFileIdentity.current(at: link) == nil)
        #expect(ModelFileIdentity.current(at: directory.appendingPathComponent("missing.bin")) == nil)
        #expect(ModelFileIdentity.current(at: directory) == nil)
        let first = try #require(ModelFileIdentity.current(at: file))
        try Data("xy".utf8).write(to: file)
        #expect(ModelFileIdentity.current(at: file) != first)
    }
}
