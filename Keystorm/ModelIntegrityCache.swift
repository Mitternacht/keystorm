import Darwin
import Foundation

/// What `lstat` says about one installed model file when its SHA-256 was last verified.
/// Any difference, in any field, means the file may have changed and must be hashed again.
/// Size and modification time catch edits and replacement; inode and device catch a swapped
/// file; the status-change time catches an edit whose modification time was put back.
nonisolated struct ModelFileIdentity: Codable, Hashable, Sendable {
    let path: String
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(path: String, information: stat) {
        self.path = path
        device = Int64(information.st_dev)
        inode = UInt64(information.st_ino)
        size = Int64(information.st_size)
        modifiedSeconds = Int64(information.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        changedSeconds = Int64(information.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(information.st_ctimespec.tv_nsec)
    }

    /// Nil for a missing file, a symbolic link, or anything that is not a regular file.
    static func current(at url: URL) -> ModelFileIdentity? {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return ModelFileIdentity(path: url.standardizedFileURL.path, information: information)
    }
}

nonisolated struct ModelIntegrityRecord: Codable, Hashable, Sendable {
    let identity: ModelFileIdentity
    /// The digest the file was verified against, which is the catalog's pinned value.
    let sha256: String
}

/// Remembers which model files already passed the full SHA-256 check, so a new worker (every
/// launch, and every restart after a crash) does not read and hash gigabytes again.
///
/// Trade-off, stated plainly: this file lives in the same user-writable folder as the models,
/// so it protects against accidental damage, interrupted copies, restores and replaced files,
/// not against someone who can already write to that folder. The pinned digests in the catalog
/// stay the authority: a record counts only while the file still has exactly the identity it had
/// when it was hashed and the record's digest equals the catalog's current one. A new model
/// revision, a replaced file, a size change or a touched file all fall back to the full hash.
/// Damage that leaves every one of those fields unchanged is not detectable without hashing,
/// which holds equally for the per-process cache this one extends.
nonisolated struct ModelIntegrityStore: Sendable {
    static let fileName = ".keystorm-integrity-v1.json"
    static let version = 1
    static let maximumRecords = 512
    private static let maximumFileBytes = 1_024 * 1_024

    private struct Payload: Codable {
        var version: Int
        var records: [ModelIntegrityRecord]
    }

    let fileURL: URL

    init(modelDirectory: URL) {
        fileURL = modelDirectory.appendingPathComponent(Self.fileName)
    }

    /// True only when every artifact has a record whose identity and digest both match.
    /// A missing, unreadable or foreign file confirms nothing, and never throws.
    func confirms(_ identities: [ModelFileIdentity], expectedSHA256: [String]) -> Bool {
        guard !identities.isEmpty, identities.count == expectedSHA256.count else { return false }
        let known = Dictionary(load().map { ($0.identity.path, $0) }, uniquingKeysWith: { _, new in new })
        return zip(identities, expectedSHA256).allSatisfy { identity, digest in
            guard let record = known[identity.path] else { return false }
            return record.identity == identity && record.sha256 == digest
        }
    }

    /// Best effort: a failed write only costs the next worker a full hash. Records for the same
    /// paths are replaced, other records are kept, and the file is replaced atomically so a
    /// concurrent reader never sees half a file. Two writers can lose one update, never corrupt it.
    func remember(_ identities: [ModelFileIdentity], expectedSHA256: [String]) {
        guard identities.count == expectedSHA256.count, !identities.isEmpty else { return }
        let fresh = zip(identities, expectedSHA256).map { ModelIntegrityRecord(identity: $0, sha256: $1) }
        let replaced = Set(fresh.map(\.identity.path))
        var records = load().filter { !replaced.contains($0.identity.path) }
        records.append(contentsOf: fresh)
        if records.count > Self.maximumRecords { records.removeFirst(records.count - Self.maximumRecords) }
        guard let data = try? JSONEncoder().encode(Payload(version: Self.version, records: records)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Drops every record. Used when a model is removed or reinstalled from scratch.
    func removeAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func load() -> [ModelIntegrityRecord] {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= Self.maximumFileBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.version else { return [] }
        return payload.records.filter { $0.sha256.count == 64 }
    }
}
