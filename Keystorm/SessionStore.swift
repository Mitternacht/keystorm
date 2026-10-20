import Foundation
import SQLite3
import CryptoKit
import Darwin
import AVFoundation

/// Single-writer catalog. Audio is committed by the recorder before this actor acknowledges it.
actor SessionStore {
    private let root: URL
    private let catalog: SQLiteCatalog
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    // One bounded residency slot avoids decoding growing checkpoint JSON for every audio commit.
    private var appendCache: CaptureCache?
    private var queryDiagnostics = QueryDiagnostics()

    struct QueryDiagnostics: Equatable, Sendable {
        var fullPayloadDecodes = 0
        var decodedSessionIDs: Set<UUID> = []
        var historyPageQueries = 0
        var rejectedCatalogPayloads = 0
        var largestCatalogPayloadBytesCopied = 0
    }

    func historyQueryDiagnostics(reset: Bool = false) -> QueryDiagnostics {
        let value = queryDiagnostics
        if reset { queryDiagnostics = QueryDiagnostics() }
        return value
    }

    private struct SnapshotStamp: Equatable {
        var size: UInt64
        var inode: UInt64
        var modified: Date
    }

    private struct CaptureCache {
        var snapshot: Snapshot
        var segmentsByID: [UUID: AudioSegment]
        var dataVersion: Int32
        var stamp: SnapshotStamp?
    }

    private struct Snapshot: Codable {
        var version = 1
        var revision: Int64
        var session: VoiceSession
        // Ephemeral read provenance; never written into the source checkpoint.
        var catalogRevision: Int64?
        var catalogReadIssue: String?
        private enum CodingKeys: String, CodingKey { case version, revision, session }
    }

    /// Private publication state makes a derived recording atomic with its source metadata.
    private struct RecordingPublication: Codable {
        var version = 1
        var expectedRevision: Int64
        var expectedUpdatedAt: Date
        var nextSession: VoiceSession
        var newSegmentIDs: [UUID]
    }

    init(root: URL? = nil) throws {
        let location = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Keystorm", isDirectory: true)
        self.root = location.standardizedFileURL
        try FileManager.default.createDirectory(at: location.appendingPathComponent("Sessions"), withIntermediateDirectories: true)
        catalog = try SQLiteCatalog(url: location.appendingPathComponent("catalog.sqlite"))
    }

    func sessionDirectory(_ id: UUID) throws -> URL {
        let directory = root.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        try requireContained(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func audioDirectory(_ id: UUID) throws -> URL {
        let directory = try sessionDirectory(id).appendingPathComponent("Audio", isDirectory: true)
        try requireContained(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func audioURL(for segment: AudioSegment, in sessionID: UUID) throws -> URL {
        guard segment.fileName.lowercased() == "\(segment.id.uuidString).caf".lowercased(), !segment.fileName.contains("/") else {
            throw KeystormError.message("Unsafe audio filename: \(segment.fileName)")
        }
        let directory = try audioDirectory(sessionID)
        let url = directory.appendingPathComponent(segment.fileName)
        var attributes = stat()
        if lstat(url.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFLNK {
            throw KeystormError.message("Managed audio cannot be a symbolic link.")
        }
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else {
            throw KeystormError.message("Audio reference escapes its session.")
        }
        return url
    }

    /// The primary library does not run full-store recovery or decode a session.
    /// Full audio validation is deferred until that recording is opened.
    func prepareLazyStartup(limit: Int = 50) throws -> DictationHistoryStartup {
        let pending = try catalog.historyPendingRepairCount()
        let interrupted = try catalog.historyInterruptedCount()
        var reports: [String] = []
        if interrupted > 0 {
            reports.append("\(interrupted) interrupted recording session(s) will be recovered when opened. Their original audio is preserved.")
        }
        if pending > 0 {
            reports.append("\(pending) history checkpoint(s) need a synchronized snapshot check. Use Check library to continue bounded recovery.")
        }
        return DictationHistoryStartup(page: try historyPage(limit: limit),
            reports: reports, pendingRepairCount: pending,
            totalSessionCount: try catalog.totalSessionCount(), maintenanceAvailable: true)
    }

    func historyPage(limit: Int = 50, before: DictationHistoryCursor? = nil) throws -> DictationHistoryPage {
        queryDiagnostics.historyPageQueries += 1
        return try catalog.historyPage(limit: limit, before: before)
    }

    /// Hydrates and validates only the selected archive. Cancellation never turns a
    /// skipped source check into an unavailable-audio marker or a successful repair.
    func hydrateSession(_ id: UUID) throws -> DictationSessionHydration {
        try Task.checkCancellation()
        let reports = try self.recover(sessionID: id)
        guard let entry = try currentEntry(id) else { throw KeystormError.message("The selected recording is no longer available.") }
        return DictationSessionHydration(session: entry.session, reports: reports)
    }

    /// Bounded discovery of synchronized snapshots omitted by an old/corrupt
    /// catalog or interrupted publication. This scans folder names but decodes
    /// only changed/unindexed checkpoints in the requested slice. Audio recovery
    /// still happens on selection or through the explicit legacy maintenance flow.
    func maintainHistory(limit: Int = 16, afterDirectory: String? = nil) throws -> DictationHistoryMaintenance {
        guard (1...100).contains(limit),
              afterDirectory == nil || UUID(uuidString: afterDirectory!) != nil else {
            throw KeystormError.message("Invalid history maintenance page.")
        }
        let directories = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sessions"),
            includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let remaining = directories.filter { afterDirectory == nil || $0.lastPathComponent > afterDirectory! }
        var reports: [String] = []
        var repaired = 0
        for directory in remaining.prefix(limit) {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            do {
                try requireContained(directory)
                let stamp = try snapshotStampValue(id)
                guard try catalog.historyNeedsRepair(id, snapshotStamp: stamp) else { continue }
                guard let entry = try currentEntry(id) else {
                    throw KeystormError.message("No committed checkpoint was found. Original files were retained for inspection.")
                }
                try Task.checkCancellation()
                // Reconcile SQL to the same winning checkpoint without advancing
                // its source revision. The JSON snapshot remains the fallback.
                try catalog.putSession(id: id, revision: entry.revision,
                    payload: encoder.encode(entry.session), snapshotStamp: stamp)
                repaired += 1
            } catch is CancellationError { throw CancellationError() }
            catch {
                try catalog.markHistoryRepair(id, reason: error.localizedDescription)
                reports.append("Session \(id): " + error.localizedDescription)
            }
        }
        let next = remaining.count > limit ? remaining.prefix(limit).last?.lastPathComponent : nil
        return .init(inspectedCount: min(limit, remaining.count), repairedCount: repaired,
            nextDirectory: next, reports: reports)
    }

    /// A plain selected checkpoint read for persistence reconciliation. This does
    /// not interrupt a live capture or run historical audio recovery.
    func loadSession(_ id: UUID) throws -> VoiceSession? {
        try Task.checkCancellation()
        return try currentEntry(id)?.session
    }

    /// Import collision checks must include evicted archives and retained orphan
    /// folders, not merely the workspace's bounded hydrated cache.
    func containsSession(_ id: UUID) throws -> Bool {
        if try catalog.containsSession(id) { return true }
        let directory = root.appendingPathComponent("Sessions").appendingPathComponent(id.uuidString)
        try requireContained(directory)
        return FileManager.default.fileExists(atPath: directory.path)
    }

    /// Explicit complete-library loading is retained for the developer brief browser.
    func loadSessions() throws -> [VoiceSession] {
        let entries = try readEntries().entries
        return entries.values.map(\.session).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Snapshot rename precedes SQLite commit. Recovery chooses the higher monotonic revision.
    /// Neither the database transaction nor JSON snapshot is claimed to commit the audio itself.
    func save(_ session: VoiceSession) throws {
        // Invalidate before any publication attempt: JSON may succeed even when SQL fails.
        appendCache = nil
        guard session.schemaVersion == 1 else { throw KeystormError.message("Unsupported session schema \(session.schemaVersion).") }
        guard Set(session.segments.map(\.id)).count == session.segments.count,
              Set(session.transcripts.map(\.id)).count == session.transcripts.count else {
            throw KeystormError.message("Duplicate source record identities cannot be committed.")
        }
        try session.brief?.validateRecordingMetadata(session: session)
        try session.validateDictationMetadata()
        guard session.trashedAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw KeystormError.message("The brief has invalid Trash metadata.")
        }
        let previous = try currentEntry(session.id)
        if let previous { try preserveOriginals(previous.session, in: session) }
        let previousIDs = Set(previous?.session.segments.map(\.id) ?? [])
        for segment in session.segments where !previousIDs.contains(segment.id) {
            try validateAudio(segment, sessionID: session.id)
            guard !session.segments.contains(where: { Self.overlaps($0, segment) }) else {
                throw KeystormError.message("Audio ranges overlap. Preserve the files and resolve their source coverage first.")
            }
        }
        guard (previous?.revision ?? 0) < Int64.max else {
            throw KeystormError.message("The session revision limit has been reached.")
        }
        let snapshot = Snapshot(revision: (previous?.revision ?? 0) + 1, session: session)
        let data = try encoder.encode(snapshot)
        guard data.count <= 64 * 1_024 * 1_024 else {
            throw KeystormError.message("Session metadata exceeds the 64 MB storage limit. Export or start another brief before adding more material.")
        }
        try DurableFile.replace(data, at: sessionDirectory(session.id).appendingPathComponent("session.json"))
        try catalog.putSession(id: session.id, revision: snapshot.revision, payload: encoder.encode(session), snapshotStamp: snapshotStampValue(session.id))
    }

    /// Audio and its sidecar have already been committed by the recorder. This method
    /// acknowledges only their bounded metadata delta in the existing catalog transaction.
    func appendCapturedSegments(sessionID: UUID, segments: [AudioSegment], updatedAt: Date) throws -> VoiceSession {
        guard !segments.isEmpty, segments.count <= IncrementalSessionJournal.maximumSegmentsPerDelta,
              Set(segments.map(\.id)).count == segments.count,
              updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw KeystormError.message("The captured audio batch has invalid identities or bounds.")
        }
        let stamp = try snapshotStamp(sessionID)
        let dataVersion = try catalog.dataVersion()
        let durableRevision = try catalog.captureRevision(sessionID)
        if appendCache?.snapshot.session.id != sessionID || appendCache?.stamp != stamp ||
            appendCache?.dataVersion != dataVersion || appendCache?.snapshot.revision != durableRevision {
            appendCache = nil
            guard let entry = try currentEntry(sessionID) else {
                throw KeystormError.message("The recording needs a durable session checkpoint before audio can be appended.")
            }
            // A synchronized JSON checkpoint may be ahead after an interrupted SQL commit.
            // Reconcile that already-durable state before admitting another journal revision.
            if try catalog.captureRevision(sessionID) != entry.revision || !catalog.hasCaptureHeader(sessionID) {
                try catalog.putSession(id: sessionID, revision: entry.revision, payload: encoder.encode(entry.session))
            }
            guard Set(entry.session.segments.map(\.id)).count == entry.session.segments.count else {
                throw KeystormError.message("The recording checkpoint has duplicate source identities.")
            }
            appendCache = CaptureCache(snapshot: entry,
                segmentsByID: Dictionary(uniqueKeysWithValues: entry.session.segments.map { ($0.id, $0) }),
                dataVersion: try catalog.dataVersion(), stamp: try snapshotStamp(sessionID))
        }
        guard let baseline = appendCache?.snapshot else {
            throw KeystormError.message("The recording checkpoint is unavailable.")
        }
        var fresh: [AudioSegment] = []
        for segment in segments {
            if let existing = appendCache?.segmentsByID[segment.id] {
                guard existing == segment else {
                    throw KeystormError.message("An acknowledged capture identity cannot be rewritten.")
                }
            } else { fresh.append(segment) }
        }
        guard !fresh.isEmpty else { return baseline.session }
        try validateCaptureOwnership(fresh, in: baseline.session)
        let directory = try audioDirectory(sessionID)
        for segment in fresh {
            _ = try audioURL(for: segment, in: sessionID)
            try validatePublicationSegment(segment, in: directory)
        }
        let delta = try catalog.appendCapture(sessionID: sessionID, expectedRevision: baseline.revision,
            segments: fresh, updatedAt: updatedAt)
        // All fallible work precedes the in-memory publication. SQL owns duplicate/range
        // validation; the cache is updated only after its FULL-synchronous commit.
        guard var cache = appendCache else { preconditionFailure("Capture cache lost inside serialized storage") }
        appendCache = nil
        if let last = cache.snapshot.session.segments.last, let first = delta.segments.first,
           last.startTime > first.startTime {
            cache.snapshot.session.segments.append(contentsOf: delta.segments)
            cache.snapshot.session.segments.sort { $0.startTime < $1.startTime }
        } else {
            cache.snapshot.session.segments.append(contentsOf: delta.segments)
        }
        for segment in delta.segments { cache.segmentsByID[segment.id] = segment }
        cache.snapshot.session.invalidateDerivedWork()
        cache.snapshot.session.updatedAt = delta.updatedAt
        cache.snapshot.revision = delta.revision
        appendCache = cache
        return cache.snapshot.session
    }

    private func validateCaptureOwnership(_ segments: [AudioSegment], in session: VoiceSession) throws {
        guard session.schemaVersion == 1, session.trashedAt == nil,
              Set(session.intervals.map(\.id)).count == session.intervals.count else {
            throw KeystormError.message("Captured audio cannot be appended to this session.")
        }
        let intervals = Dictionary(uniqueKeysWithValues: session.intervals.map { ($0.id, $0) })
        for segment in segments {
            guard let interval = intervals[segment.intervalID],
                  segment.startTime.isFinite, segment.startTime >= 0, segment.endTime.isFinite,
                  segment.frameCount > 0, segment.sampleRate.isFinite, segment.sampleRate > 0,
                  (1...64).contains(segment.channelCount), segment.committedAt.timeIntervalSinceReferenceDate.isFinite,
                  segment.fileName.lowercased() == (segment.id.uuidString + ".caf").lowercased(),
                  segment.sha256.count == 64, segment.sha256.allSatisfy(\.isHexDigit),
                  interval.sampleRate == 0 || abs(interval.sampleRate - segment.sampleRate) <= 0.001,
                  interval.channelCount == 0 || interval.channelCount == segment.channelCount else {
                throw KeystormError.message("Captured audio does not match its durable interval.")
            }
            if let brief = session.brief {
                let owners = brief.takes.filter { $0.captureIntervalIDs.contains(segment.intervalID) }
                guard owners.count == 1, owners[0].trashedAt == nil, owners[0].activeAudioRevisionID == nil else {
                    throw KeystormError.message("Captured audio is not owned by an original recording.")
                }
            }
        }
    }

    private func snapshotStamp(_ id: UUID) throws -> SnapshotStamp? {
        let url = try sessionDirectory(id).appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw KeystormError.message("The synchronized checkpoint is not a regular managed file.")
        }
        return SnapshotStamp(size: size.uint64Value, inode: inode.uint64Value, modified: modified)
    }

    private func snapshotStampValue(_ id: UUID) throws -> String? {
        try snapshotStamp(id).map { "\($0.size):\($0.inode):\($0.modified.timeIntervalSinceReferenceDate)" }
    }

    /// Publish only a completed private render. After the journal is synchronized, recovery owns it.
    func commitRecordingEdit(_ session: VoiceSession, stagedDirectory: URL, expectedUpdatedAt: Date) throws {
        guard let baseline = try currentEntry(session.id), baseline.session.updatedAt == expectedUpdatedAt,
              baseline.session.status != .recording, session.status != .recording,
              baseline.session.trashedAt == nil, session.trashedAt == nil else {
            throw KeystormError.message("The brief changed or is recording. Keep the rendered edit and retry against the current brief.")
        }
        let stage = try requireRecordingStage(stagedDirectory, sessionID: session.id)
        let journal = stage.appendingPathComponent("publication.json")
        guard !FileManager.default.fileExists(atPath: journal.path) else {
            throw KeystormError.message("This recording edit already has a recovery journal. Recover it before retrying.")
        }
        try session.brief?.validateRecordingMetadata(session: session)
        try preserveOriginals(baseline.session, in: session)
        let previousIDs = Set(baseline.session.segments.map(\.id))
        let generated = session.segments.filter { !previousIDs.contains($0.id) }
        let publication = RecordingPublication(expectedRevision: baseline.revision, expectedUpdatedAt: expectedUpdatedAt,
            nextSession: session, newSegmentIDs: generated.map(\.id))
        try validatePublication(publication, sessionID: session.id)
        let expectedFiles = Set(generated.flatMap { [$0.fileName, $0.id.uuidString + ".json"] })
        guard Set(try FileManager.default.contentsOfDirectory(atPath: stage.path)) == expectedFiles else {
            throw KeystormError.message("The private recording render contains unexpected or missing files.")
        }
        let audio = try audioDirectory(session.id)
        for segment in generated {
            for name in [segment.fileName, segment.id.uuidString + ".json"] {
                guard !FileManager.default.fileExists(atPath: audio.appendingPathComponent(name).path) else {
                    throw KeystormError.message("A generated audio identity is already occupied. Existing assets were preserved.")
                }
            }
            try validatePublicationSegment(segment, in: stage)
            try CaptureDurability.synchronize(stage.appendingPathComponent(segment.fileName))
            try CaptureDurability.synchronize(stage.appendingPathComponent(segment.id.uuidString + ".json"))
        }
        let data = try encoder.encode(publication)
        guard data.count <= 64 * 1_024 * 1_024 else { throw KeystormError.message("Recording edit metadata exceeds the 64 MB limit.") }
        try DurableFile.replace(data, at: journal)
        try publishRecordingAssets(publication, from: stage)
        try save(session)
        // Metadata is already committed. A remaining journal is idempotently cleaned on startup.
        try? cleanRecordingPublication(stage)
    }

    private func requireRecordingStage(_ stage: URL, sessionID: UUID) throws -> URL {
        let directory = try sessionDirectory(sessionID)
        let name = stage.lastPathComponent
        let prefix = ".recording-edit-"
        let values = try stage.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
              stage.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL,
              stage.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath(),
              values.isDirectory == true, values.isSymbolicLink != true else {
            throw KeystormError.message("Recording edits must use their own private managed staging directory.")
        }
        try requireContained(stage)
        return stage
    }

    private func validatePublication(_ publication: RecordingPublication, sessionID: UUID) throws {
        let session = publication.nextSession
        let ids = Set(publication.newSegmentIDs)
        let intervalIDs = Set(session.intervals.map(\.id))
        guard publication.version == 1, publication.expectedRevision > 0, session.id == sessionID,
              session.schemaVersion == 1, session.status != .recording,
              !ids.isEmpty, ids.count == publication.newSegmentIDs.count, ids.count <= 20_000,
              Set(session.segments.map(\.id)).count == session.segments.count,
              ids.isSubset(of: Set(session.segments.map(\.id))),
              session.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              publication.expectedUpdatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw KeystormError.message("Recording edit recovery metadata has invalid identities or bounds.")
        }
        let takes = session.brief?.takes ?? []
        let derivedIntervals = Set(takes.flatMap { ($0.audioRevisions ?? []).flatMap(\.intervalIDs) })
        let selectedIntervals = Set(takes.filter { $0.trashedAt == nil }.flatMap(\.activeIntervalIDs))
        for segment in session.segments where ids.contains(segment.id) {
            guard derivedIntervals.contains(segment.intervalID), selectedIntervals.contains(segment.intervalID),
                  segment.fileName == segment.id.uuidString + ".caf", intervalIDs.contains(segment.intervalID),
                  segment.startTime.isFinite, segment.startTime >= 0, segment.endTime.isFinite,
                  segment.sampleRate.isFinite, segment.sampleRate > 0, segment.frameCount > 0,
                  segment.channelCount > 0, segment.channelCount <= 64,
                  segment.sha256.count == 64, segment.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw KeystormError.message("Generated recording assets have invalid source metadata.")
            }
        }
        try session.brief?.validateRecordingMetadata(session: session)
    }

    private func validatePublicationSegment(_ segment: AudioSegment, in directory: URL) throws {
        let sidecar = directory.appendingPathComponent(segment.id.uuidString + ".json")
        let decoded = try decoder.decode(AudioSegment.self, from: readManagedMetadata(sidecar, maximumBytes: 256 * 1_024))
        guard decoded == segment else { throw KeystormError.message("Generated audio sidecar does not match the recording edit.") }
        try validateAudio(segment, at: directory.appendingPathComponent(segment.fileName))
    }

    private func publishRecordingAssets(_ publication: RecordingPublication, from stage: URL) throws {
        let audio = try audioDirectory(publication.nextSession.id)
        let ids = Set(publication.newSegmentIDs)
        for segment in publication.nextSession.segments where ids.contains(segment.id) {
            for name in [segment.fileName, segment.id.uuidString + ".json"] {
                let source = stage.appendingPathComponent(name)
                let destination = audio.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: destination.path) {
                    guard !FileManager.default.fileExists(atPath: source.path) else {
                        throw KeystormError.message("A generated asset exists in both staging and managed audio. Both copies were retained.")
                    }
                } else {
                    _ = try readManagedFileSize(source)
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            }
            try validatePublicationSegment(segment, in: audio)
        }
        try CaptureDurability.synchronizeDirectory(audio)
        try CaptureDurability.synchronizeDirectory(stage)
    }

    private func cleanRecordingPublication(_ stage: URL) throws {
        try FileManager.default.removeItem(at: stage)
        try CaptureDurability.synchronizeDirectory(stage.deletingLastPathComponent())
    }

    /// Runs before orphan-sidecar recovery, so a partial audio edit never becomes unrelated source.
    private func recoverRecordingPublications(entries: inout [UUID: Snapshot]) throws -> (reports: [String], blocked: Set<UUID>) {
        var reports: [String] = []
        var blocked = Set<UUID>()
        for id in entries.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let directory = try sessionDirectory(id)
            let stages = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".recording-edit-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for candidate in stages {
                try Task.checkCancellation()
                do {
                    let stage = try requireRecordingStage(candidate, sessionID: id)
                    let journal = stage.appendingPathComponent("publication.json")
                    guard FileManager.default.fileExists(atPath: journal.path) else {
                        reports.append("Unpublished recording render retained for inspection: " + stage.lastPathComponent)
                        continue
                    }
                    let publication = try decoder.decode(RecordingPublication.self,
                        from: readManagedMetadata(journal, maximumBytes: 64 * 1_024 * 1_024))
                    try validatePublication(publication, sessionID: id)
                    guard let current = try currentEntry(id) else { throw KeystormError.message("Recording edit baseline is missing.") }
                    let currentSegments = Dictionary(current.session.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let generatedIDs = Set(publication.newSegmentIDs)
                    let generated = publication.nextSession.segments.filter { generatedIDs.contains($0.id) }
                    let committed = generated.allSatisfy { currentSegments[$0.id] == $0 }
                    if committed {
                        try publishRecordingAssets(publication, from: stage)
                        try cleanRecordingPublication(stage)
                        reports.append("Completed recording edit publication cleanup.")
                    } else if current.revision == publication.expectedRevision && current.session.updatedAt == publication.expectedUpdatedAt {
                        try preserveOriginals(current.session, in: publication.nextSession)
                        try publishRecordingAssets(publication, from: stage)
                        try save(publication.nextSession)
                        try cleanRecordingPublication(stage)
                        reports.append("Recovered interrupted recording edit with its original recording versions intact.")
                    } else {
                        // Keep generated files out of generic orphan recovery; never move a currently referenced asset.
                        let audio = try audioDirectory(id)
                        for segment in generated where currentSegments[segment.id] == nil {
                            for name in [segment.fileName, segment.id.uuidString + ".json"] {
                                let source = audio.appendingPathComponent(name)
                                let target = stage.appendingPathComponent(name)
                                if FileManager.default.fileExists(atPath: source.path) {
                                    guard !FileManager.default.fileExists(atPath: target.path) else {
                                        throw KeystormError.message("Conflicting generated copies require inspection before recovery.")
                                    }
                                    _ = try readManagedFileSize(source)
                                    try FileManager.default.moveItem(at: source, to: target)
                                }
                            }
                        }
                        try CaptureDurability.synchronizeDirectory(audio)
                        try CaptureDurability.synchronizeDirectory(stage)
                        let quarantine = directory.appendingPathComponent(".recording-conflict-" + UUID().uuidString)
                        try FileManager.default.moveItem(at: stage, to: quarantine)
                        try CaptureDurability.synchronizeDirectory(directory)
                        reports.append("A recording edit conflicted with newer brief changes. Generated assets were retained in " + quarantine.lastPathComponent + "; the current brief was preserved.")
                    }
                    entries[id] = try currentEntry(id)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    blocked.insert(id)
                    reports.append("Recording edit recovery needs inspection before orphan audio can be adopted: " + error.localizedDescription)
                }
            }
        }
        return (reports, blocked)
    }

    func loadDictionary() throws -> [DictionaryEntry] {
        guard let data = try catalog.metadata("dictionary") else { return [] }
        return try decoder.decode([DictionaryEntry].self, from: data)
    }

    func saveDictionary(_ entries: [DictionaryEntry]) throws {
        let data = try encoder.encode(entries)
        try catalog.putMetadata("dictionary", payload: data)
    }

    /// Run once at startup, before recording. This never deletes or guesses the contents of an unfinished tail.
    @discardableResult
    func recover(sessionID: UUID? = nil) throws -> [String] {
        appendCache = nil
        var loaded: (entries: [UUID: Snapshot], reports: [String])
        if let sessionID {
            let entry = try currentEntry(sessionID)
            var sourceReports: [String] = []
            if let issue = entry?.catalogReadIssue {
                sourceReports.append("The catalog copy was rejected; recovering its synchronized checkpoint. " + issue)
            }
            loaded = (entry.map { [sessionID: $0] } ?? [:], sourceReports)
        } else { loaded = try readEntries() }
        var reports = loaded.reports
        let publications = try recoverRecordingPublications(entries: &loaded.entries)
        reports.append(contentsOf: publications.reports)
        if let sessionID, publications.blocked.contains(sessionID) {
            throw KeystormError.message("This recording has an unfinished audio publication that needs inspection before editing. Original sources and its recovery journal were preserved. " + publications.reports.joined(separator: " "))
        }
        for id in loaded.entries.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
            guard !publications.blocked.contains(id) else { continue }
            guard var entry = loaded.entries[id] else { continue }
            var session = entry.session
            let original = session
            if session.status == .recording {
                session.status = .interrupted
                addGap("Recording was interrupted. Audio after the last acknowledged segment may be missing.", to: &session, from: session.updatedAt)
                reports.append("\(session.title): interrupted recording recovered.")
            }
            if var brief = session.brief {
                for index in brief.takes.indices where brief.takes[index].status == .recording {
                    brief.takes[index].status = .paused
                }
                if brief != session.brief { brief.reviewedRevisionID = nil }
                session.brief = brief
            }
            if session.dictation != nil {
                session.materializeDictationMetadata()
                for index in session.dictation!.recordings.indices where session.dictation!.recordings[index].state == .recording {
                    session.dictation!.recordings[index].state = .paused
                }
            }
            for index in session.jobs.indices where session.jobs[index].status == .running {
                session.jobs[index].status = .incomplete
                session.jobs[index].error = "Processing was interrupted. Retry this section; completed source material is preserved."
                reports.append("\(session.title): interrupted \(session.jobs[index].stage.rawValue) job needs retry.")
            }
            let directory = try audioDirectory(id)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            var unavailable = Set<UUID>()
            for segment in session.segments {
                try Task.checkCancellation()
                do { try validateAudio(segment, sessionID: id) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    unavailable.insert(segment.id)
                    let reason = "Audio \(segment.id.uuidString) is unavailable: \(error.localizedDescription)"
                    addGap(reason, to: &session, from: segment.committedAt,
                           segmentIDs: [segment.id], intervalIDs: [segment.intervalID])
                    reports.append("\(session.title): \(reason)")
                }
            }
            var committedByID = Dictionary(session.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for sidecar in files.filter({ $0.pathExtension == "json" }) {
                try Task.checkCancellation()
                do {
                    let segment = try decoder.decode(AudioSegment.self, from: readManagedMetadata(sidecar, maximumBytes: 256 * 1_024))
                    guard sidecar.deletingPathExtension().lastPathComponent.lowercased() == segment.id.uuidString.lowercased() else { throw KeystormError.message("Sidecar identity mismatch.") }
                    if let existing = committedByID[segment.id] {
                        guard existing == segment else { throw KeystormError.message("Sidecar conflicts with an immutable segment.") }
                        continue
                    }
                    try validateAudio(segment, sessionID: id)
                    guard !session.segments.contains(where: { Self.overlaps($0, segment) }) else {
                        throw KeystormError.message("Audio range overlaps a committed segment. Inspect both files before choosing coverage.")
                    }
                    session.segments.append(segment)
                    committedByID[segment.id] = segment
                    reports.append("\(session.title): recovered durable orphan segment \(segment.id.uuidString).")
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let reason = "Uncommitted sidecar \(sidecar.lastPathComponent): \(error.localizedDescription)"
                    addGap(reason, to: &session)
                    reports.append("\(session.title): \(reason)")
                }
            }
            let fileNames = Set(files.map(\.lastPathComponent))
            let committedNames = Set(session.segments.map(\.fileName))
            for file in files {
                let isTail = file.pathExtension == "partial" || file.pathExtension == "tmp"
                let hasNoSidecar = file.pathExtension == "caf" &&
                    !fileNames.contains(file.deletingPathExtension().lastPathComponent + ".json") &&
                    !committedNames.contains(file.lastPathComponent)
                if isTail || hasNoSidecar {
                    let reason = "Incomplete audio tail \(file.lastPathComponent) retained for inspection; it is not acknowledged audio."
                    addGap(reason, to: &session)
                    reports.append("\(session.title): \(reason)")
                }
            }
            session.segments.sort { $0.startTime < $1.startTime }
            for intervalID in Set(session.segments.map(\.intervalID)) where !session.intervals.contains(where: { $0.id == intervalID }) {
                let segments = session.segments.filter { $0.intervalID == intervalID }
                guard let first = segments.first else { continue }
                let start = segments.map { $0.committedAt.addingTimeInterval(-$0.duration) }.min() ?? first.committedAt
                let end = segments.map(\.committedAt).max() ?? first.committedAt
                session.intervals.append(CaptureInterval(id: intervalID, startedAt: start, endedAt: max(start, end), sampleRate: first.sampleRate, channelCount: first.channelCount))
                reports.append("\(session.title): recovered interval wall times are approximate; monotonic host time is unknown.")
            }
            for index in session.intervals.indices where session.intervals[index].endedAt == nil {
                let interval = session.intervals[index]
                let lastCommit = session.segments.filter { $0.intervalID == interval.id }.map(\.committedAt).max() ?? interval.startedAt
                session.intervals[index].endedAt = max(interval.startedAt, lastCommit)
            }
            session.unavailableSegmentIDs = unavailable.sorted { $0.uuidString < $1.uuidString }
            if session.unavailableSegmentIDs != original.unavailableSegmentIDs { session.invalidateDerivedWork() }
            try Task.checkCancellation()
            // Catalog reconciliation is required even when only the snapshot was newer.
            entry.session = session
            if session != original { session.updatedAt = Date(); try save(session) }
            else {
                let stamp = try snapshotStampValue(id)
                let sourceNeedsReconciliation = entry.catalogRevision != entry.revision || stamp == nil
                let indexNeedsReconciliation = try catalog.historyNeedsRepair(id, snapshotStamp: stamp)
                if sourceNeedsReconciliation || indexNeedsReconciliation {
                    if sourceNeedsReconciliation {
                        try DurableFile.replace(encoder.encode(entry), at: sessionDirectory(id).appendingPathComponent("session.json"))
                    }
                    try catalog.putSession(id: id, revision: entry.revision, payload: encoder.encode(session), snapshotStamp: snapshotStampValue(id))
                }
            }
            loaded.entries[id] = entry
        }
        return reports
    }

    private func addGap(_ reason: String, to session: inout VoiceSession, from date: Date? = nil,
                        segmentIDs: [UUID]? = nil, intervalIDs: [UUID]? = nil) {
        guard !session.gaps.contains(where: {
            $0.reason == reason && $0.segmentIDs == segmentIDs && $0.intervalIDs == intervalIDs
        }) else { return }
        session.gaps.append(SessionGap(startedAt: date ?? session.updatedAt, endedAt: Date(), reason: reason,
                                      segmentIDs: segmentIDs, intervalIDs: intervalIDs))
    }

    private func validateAudio(_ segment: AudioSegment, sessionID: UUID) throws {
        guard segment.startTime.isFinite, segment.startTime >= 0, segment.frameCount > 0, segment.sampleRate.isFinite, segment.sampleRate > 0, segment.channelCount > 0,
              segment.sha256.count == 64, segment.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw KeystormError.message("Invalid audio metadata.")
        }
        let url = try audioURL(for: segment, in: sessionID)
        try validateAudio(segment, at: url)
    }

    private func validateAudio(_ segment: AudioSegment, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw KeystormError.message("File is missing.") }
        _ = try readManagedFileSize(url)
        guard try Self.checksum(url) == segment.sha256.lowercased() else { throw KeystormError.message("SHA-256 checksum mismatch; original file retained.") }
        let audio = try AVAudioFile(forReading: url)
        defer { audio.close() }
        guard audio.length == segment.frameCount,
              abs(audio.fileFormat.sampleRate - segment.sampleRate) < 0.001,
              Int(audio.fileFormat.channelCount) == segment.channelCount else {
            throw KeystormError.message("Audio header does not match its frame count or format metadata.")
        }
    }

    private static func overlaps(_ lhs: AudioSegment, _ rhs: AudioSegment) -> Bool {
        lhs.id != rhs.id && min(lhs.endTime, rhs.endTime) - max(lhs.startTime, rhs.startTime) > 0.001
    }

    nonisolated static func checksum(_ url: URL) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw KeystormError.message("The managed audio file could not be opened for verification.") }
        defer { close(descriptor) }
        let capacity = 1_048_576
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<UInt64>.alignment)
        defer { scratch.deallocate() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, scratch, capacity)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw KeystormError.message("The managed audio file could not be read for verification.")
            }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: scratch, count: count))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func requireContained(_ url: URL) throws {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(prefix) else { throw KeystormError.message("Storage directory escapes the application data folder.") }
    }

    private func preserveOriginals(_ old: VoiceSession, in new: VoiceSession) throws {
        // Identity lookup makes every debounced save linear in source records.
        let segments = Dictionary(uniqueKeysWithValues: new.segments.map { ($0.id, $0) })
        let transcripts = Dictionary(uniqueKeysWithValues: new.transcripts.map { ($0.id, $0) })
        for segment in old.segments where segments[segment.id] != segment {
            throw KeystormError.message("Original audio segments cannot be removed or rewritten.")
        }
        for revision in old.transcripts {
            guard let current = transcripts[revision.id], current == revision,
                  current.rawText.utf8.elementsEqual(revision.rawText.utf8),
                  current.text.utf8.elementsEqual(revision.text.utf8) else {
                throw KeystormError.message("Transcript revisions are immutable. Append a correction revision instead.")
            }
        }
        let newDictation = Dictionary((new.dictation?.recordings ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for recording in old.dictation?.recordings ?? [] {
            let outputs = Dictionary((newDictation[recording.id]?.outputHistory ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for original in recording.outputHistory ?? [] {
                guard let current = outputs[original.id], current == original,
                      current.textRevision.text.utf8.elementsEqual(original.textRevision.text.utf8),
                      current.textRevision.rawText.utf8.elementsEqual(original.textRevision.rawText.utf8) else {
                    throw KeystormError.message("Saved dictation output versions are immutable. Keep earlier versions and append a new one.")
                }
            }
        }
        let takes = Dictionary((new.brief?.takes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for take in old.brief?.takes ?? [] {
            guard let current = takes[take.id],
                  Set(take.captureIntervalIDs).isSubset(of: Set(current.captureIntervalIDs)),
                  take.intervalID == nil || current.intervalID == take.intervalID else {
                throw KeystormError.message("Original recordings cannot be removed or reassigned. Move the recording to Trash instead.")
            }
            let revisions = Dictionary((current.audioRevisions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for revision in take.audioRevisions ?? [] where revisions[revision.id] != revision {
                throw KeystormError.message("Recording versions are immutable. Keep earlier versions and append a new one.")
            }
        }
    }

    private func decodeCatalogRow(_ row: SQLiteCatalog.Row) throws -> VoiceSession {
        if let problem = row.payloadFailure {
            queryDiagnostics.rejectedCatalogPayloads += 1
            throw KeystormError.message(problem)
        }
        queryDiagnostics.largestCatalogPayloadBytesCopied =
            max(queryDiagnostics.largestCatalogPayloadBytesCopied, row.payload.count)
        return try decodeSessionPayload(row.payload, id: row.id)
    }

    private func decodeSessionPayload(_ data: Data, id: UUID) throws -> VoiceSession {
        queryDiagnostics.fullPayloadDecodes += 1
        queryDiagnostics.decodedSessionIDs.insert(id)
        try Task.checkCancellation()
        let session = try decoder.decode(VoiceSession.self, from: data)
        try Task.checkCancellation()
        return session
    }

    private func decodeSnapshotPayload(_ data: Data, id: UUID) throws -> Snapshot {
        queryDiagnostics.fullPayloadDecodes += 1
        queryDiagnostics.decodedSessionIDs.insert(id)
        try Task.checkCancellation()
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        try Task.checkCancellation()
        return snapshot
    }

    private func currentEntry(_ id: UUID) throws -> Snapshot? {
        var selected: Snapshot?
        var catalogFailure: (any Error)?
        if let row = try catalog.session(id) {
            do { selected = Snapshot(revision: row.revision, session: try decodeCatalogRow(row), catalogRevision: row.revision) }
            catch { catalogFailure = error }
            if let selected { try check(selected, id: id) }
        }
        let url = try sessionDirectory(id).appendingPathComponent("session.json")
        if FileManager.default.fileExists(atPath: url.path),
           let snapshot = try? decodeSnapshotPayload(readManagedMetadata(url, maximumBytes: 64 * 1_024 * 1_024), id: id) {
            try check(snapshot, id: id)
            if let selected, selected.revision == snapshot.revision, selected.session != snapshot.session {
                throw KeystormError.message("The catalog and synchronized checkpoint disagree at the same revision.")
            }
            if snapshot.revision > (selected?.revision ?? -1) {
                var fallback = snapshot
                fallback.catalogReadIssue = catalogFailure?.localizedDescription
                selected = fallback
            }
        }
        if selected == nil, let catalogFailure { throw catalogFailure }
        return try selected.map(replayingCaptureTail)
    }

    /// A validated checkpoint wins over its covered old tail. Every later revision
    /// must be present; an indexed head detects deletion of even the final delta.
    private func replayingCaptureTail(_ checkpoint: Snapshot) throws -> Snapshot {
        let expected = max(checkpoint.revision, try catalog.captureRevision(checkpoint.session.id) ?? checkpoint.revision)
        guard checkpoint.revision < expected else { return checkpoint }
        var result = checkpoint
        guard Set(result.session.segments.map(\.id)).count == result.session.segments.count else {
            throw KeystormError.message("The capture checkpoint contains duplicate sources.")
        }
        var known = Set(result.session.segments.map(\.id))
        var ordered = result.session.segments.sorted { $0.startTime < $1.startTime }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ !Self.overlaps($0.0, $0.1) }) else {
            throw KeystormError.message("The capture checkpoint has conflicting audio ranges.")
        }
        while result.revision < expected {
            let page = try catalog.captureDeltas(result.session.id, after: result.revision)
            guard !page.isEmpty else {
                throw KeystormError.message("The acknowledged capture tail is missing. Its original files were retained.")
            }
            for delta in page {
                guard delta.revision == result.revision + 1, delta.revision <= expected else {
                    throw KeystormError.message("The capture journal changed during recovery.")
                }
                try validateCaptureOwnership(delta.segments, in: result.session)
                for segment in delta.segments {
                    guard known.insert(segment.id).inserted else {
                        throw KeystormError.message("The capture journal repeats an immutable source.")
                    }
                    // Binary neighbors suffice because insertion retains sorted disjoint
                    // acknowledged capture ranges. No historical audio file is reread here.
                    var low = 0, high = ordered.count
                    while low < high {
                        let middle = low + (high - low) / 2
                        if ordered[middle].startTime < segment.startTime { low = middle + 1 } else { high = middle }
                    }
                    guard (low == 0 || !Self.overlaps(ordered[low - 1], segment)),
                          (low == ordered.count || !Self.overlaps(ordered[low], segment)) else {
                        throw KeystormError.message("The capture journal overlaps acknowledged audio.")
                    }
                    ordered.insert(segment, at: low)
                }
                result.session.invalidateDerivedWork()
                result.session.updatedAt = delta.updatedAt
                result.revision = delta.revision
            }
        }
        result.session.segments = ordered
        return result
    }

    private func readManagedFileSize(_ url: URL) throws -> Int {
        try requireContained(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else {
            throw KeystormError.message("Managed audio assets must be regular files without symbolic links.")
        }
        return size
    }

    private func readManagedMetadata(_ url: URL, maximumBytes: Int) throws -> Data {
        try requireContained(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= maximumBytes else {
            throw KeystormError.message("Managed metadata must be a bounded regular file without symbolic links.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw KeystormError.message("Managed metadata grew beyond its supported size.")
        }
        return data
    }

    private func check(_ snapshot: Snapshot, id: UUID) throws {
        guard snapshot.version == 1, snapshot.session.schemaVersion == 1 else { throw KeystormError.message("A newer storage schema is present. Update Keystorm before opening it.") }
        guard snapshot.session.id == id, snapshot.revision > 0 else { throw KeystormError.message("Session snapshot identity or revision is invalid.") }
    }

    private func readEntries() throws -> (entries: [UUID: Snapshot], reports: [String]) {
        var entries: [UUID: Snapshot] = [:]
        var reports: [String] = []
        for row in try catalog.sessions() {
            try Task.checkCancellation()
            let session: VoiceSession
            do { session = try decodeCatalogRow(row) }
            catch is CancellationError { throw CancellationError() }
            catch {
                reports.append("Session \(row.id) catalog copy could not be read; checking its synchronized snapshot. \(error.localizedDescription)")
                continue
            }
            let snapshot = Snapshot(revision: row.revision, session: session)
            try check(snapshot, id: row.id)
            entries[row.id] = snapshot
        }
        let sessions = root.appendingPathComponent("Sessions", isDirectory: true)
        for directory in try FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            try requireContained(directory)
            let url = directory.appendingPathComponent("session.json")
            guard FileManager.default.fileExists(atPath: url.path) else {
                if entries[id] == nil { reports.append("Session folder \(id) has no committed metadata; files retained for inspection.") }
                continue
            }
            let snapshot: Snapshot
            do { snapshot = try decodeSnapshotPayload(readManagedMetadata(url, maximumBytes: 64 * 1_024 * 1_024), id: id) }
            catch is CancellationError { throw CancellationError() }
            catch { reports.append("Session \(id) snapshot could not be read; catalog copy retained. \(error.localizedDescription)"); continue }
            try check(snapshot, id: id)
            if let existing = entries[id], existing.revision == snapshot.revision, existing.session != snapshot.session {
                throw KeystormError.message("The catalog and synchronized checkpoint disagree at the same revision.")
            }
            if snapshot.revision > (entries[id]?.revision ?? -1) { entries[id] = snapshot }
        }
        for id in Array(entries.keys) {
            if let checkpoint = entries[id] { entries[id] = try replayingCaptureTail(checkpoint) }
        }
        return (entries, reports)
    }
}

/// Owns a single SQLite connection. SessionStore serializes all access after construction.
private final class SQLiteCatalog: @unchecked Sendable {
    struct Row {
        var id: UUID
        var revision: Int64
        var payload: Data
        var payloadFailure: String?
    }
    private var connection: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else { throw KeystormError.message("Could not open session catalog (SQLite \(result)).") }
        sqlite3_busy_timeout(connection, 5_000)
        do {
            let version = try scalar("PRAGMA user_version")
            guard version <= DictationHistoryRepository.catalogVersion else { throw KeystormError.message("A newer catalog schema is present. Update Keystorm before opening it.") }
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA fullfsync=ON")
            if version == 0 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL, payload BLOB NOT NULL)")
                    try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
                    try execute("PRAGMA user_version=1")
                    try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            guard let connection else { throw failure() }
            try IncrementalSessionJournal(connection: connection).migrate()
            try DictationHistoryRepository(connection: connection).migrate()
        } catch { sqlite3_close(connection); connection = nil; throw error }
    }

    deinit { sqlite3_close(connection) }

    private func failure() -> KeystormError { .message("Session catalog: \(String(cString: sqlite3_errmsg(connection)))") }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }

    private func scalar(_ sql: String) throws -> Int32 {
        let statement = try statement(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int(statement, 0)
    }

    private func bind(_ text: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else { throw failure() }
    }

    private func bind(_ data: Data, at index: Int32, to statement: OpaquePointer) throws {
        let result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
        guard result == SQLITE_OK else { throw failure() }
    }

    func putSession(id: UUID, revision: Int64, payload: Data, snapshotStamp: String? = nil) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try statement("INSERT INTO sessions(id, revision, payload) VALUES(?, ?, ?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision, payload=excluded.payload")
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, at: 1, to: statement)
            guard sqlite3_bind_int64(statement, 2, revision) == SQLITE_OK else { throw failure() }
            try bind(payload, at: 3, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            let session = try JSONDecoder().decode(VoiceSession.self, from: payload)
            guard session.id == id, let connection else { throw failure() }
            try IncrementalSessionJournal(connection: connection).recordCheckpoint(session, revision: revision)
            try DictationHistoryRepository(connection: connection).recordCheckpoint(session, revision: revision, snapshotStamp: snapshotStamp)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func historyPage(limit: Int, before: DictationHistoryCursor?) throws -> DictationHistoryPage {
        guard let connection else { throw failure() }
        return try DictationHistoryRepository(connection: connection).page(limit: limit, before: before)
    }

    func historyPendingRepairCount() throws -> Int {
        guard let connection else { throw failure() }
        return try DictationHistoryRepository(connection: connection).pendingRepairCount()
    }

    func historyInterruptedCount() throws -> Int {
        guard let connection else { throw failure() }
        return try DictationHistoryRepository(connection: connection).interruptedCount()
    }

    func totalSessionCount() throws -> Int {
        guard let connection else { throw failure() }
        return try DictationHistoryRepository(connection: connection).totalSessionCount()
    }

    func historyNeedsRepair(_ id: UUID, snapshotStamp: String?) throws -> Bool {
        guard let connection else { throw failure() }
        return try DictationHistoryRepository(connection: connection).needsRepair(id, snapshotStamp: snapshotStamp)
    }

    func markHistoryRepair(_ id: UUID, reason: String) throws {
        guard let connection else { throw failure() }
        try DictationHistoryRepository(connection: connection).markRepair(id, reason: reason)
    }

    func dataVersion() throws -> Int32 { try scalar("PRAGMA data_version") }

    func hasCaptureHeader(_ id: UUID) throws -> Bool { try captureHeaderRevision(id) != nil }

    private func captureHeaderRevision(_ id: UUID) throws -> Int64? {
        let query = try statement("SELECT revision FROM session_history_headers WHERE session_id=?")
        defer { sqlite3_finalize(query) }
        try bind(id.uuidString, at: 1, to: query)
        let result = sqlite3_step(query)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, sqlite3_column_int64(query, 0) > 0 else { throw failure() }
        return sqlite3_column_int64(query, 0)
    }

    func captureRevision(_ id: UUID) throws -> Int64? {
        guard let connection else { throw failure() }
        let tail = try IncrementalSessionJournal(connection: connection).latestRevision(sessionID: id)
        let header = try captureHeaderRevision(id)
        if let tail, let header { return max(tail, header) }
        return tail ?? header
    }

    func captureDeltas(_ id: UUID, after revision: Int64) throws -> [IncrementalSessionJournal.CaptureDelta] {
        guard let connection else { throw failure() }
        return try IncrementalSessionJournal(connection: connection).deltas(sessionID: id, afterRevision: revision)
    }

    func appendCapture(sessionID: UUID, expectedRevision: Int64, segments: [AudioSegment],
                       updatedAt: Date) throws -> IncrementalSessionJournal.CaptureDelta {
        guard let connection else { throw failure() }
        return try IncrementalSessionJournal(connection: connection).append(sessionID: sessionID,
            expectedRevision: expectedRevision, segments: segments, updatedAt: updatedAt)
    }

    func containsSession(_ id: UUID) throws -> Bool {
        let query = try statement("SELECT 1 FROM sessions WHERE id=?")
        defer { sqlite3_finalize(query) }
        try bind(id.uuidString, at: 1, to: query)
        let result = sqlite3_step(query)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure() }
        return result == SQLITE_ROW
    }

    func session(_ id: UUID) throws -> Row? { try sessions(id).first }

    func sessions(_ id: UUID? = nil) throws -> [Row] {
        // CASE prevents SQLite from materializing an unbounded source value in
        // the result, before either sqlite3_column_blob or Swift Data is called.
        let statement = try statement("""
            SELECT id,revision,
                   CASE WHEN typeof(payload)='blob' THEN
                       CASE WHEN length(payload) BETWEEN 1 AND 67108864 THEN payload ELSE NULL END
                   ELSE NULL END,
                   typeof(payload),
                   CASE WHEN typeof(payload)='blob' THEN length(payload) ELSE -1 END
            FROM sessions
            """ + (id == nil ? "" : " WHERE id=?"))
        defer { sqlite3_finalize(statement) }
        if let id { try bind(id.uuidString, at: 1, to: statement) }
        var rows: [Row] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let string = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: string)) else { throw failure() }
            let count = sqlite3_column_int64(statement, 4)
            let kind = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            let payload: Data
            let payloadFailure: String?
            if kind == "blob", count > 0, count <= 64 * 1_024 * 1_024 {
                guard sqlite3_column_type(statement, 2) == SQLITE_BLOB,
                      Int64(sqlite3_column_bytes(statement, 2)) == count,
                      let bytes = sqlite3_column_blob(statement, 2) else { throw failure() }
                payload = Data(bytes: bytes, count: Int(count))
                payloadFailure = nil
            } else {
                payload = Data()
                payloadFailure = "Session \(id) catalog payload is not a bounded non-empty BLOB (maximum 64 MiB). Its synchronized checkpoint will be checked; rejected catalog bytes remain untouched until a valid recovery is published."
            }
            rows.append(Row(id: id, revision: sqlite3_column_int64(statement, 1),
                payload: payload, payloadFailure: payloadFailure))
        }
        return rows
    }

    func metadata(_ key: String) throws -> Data? {
        let statement = try statement("SELECT payload FROM metadata WHERE key=?")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    func putMetadata(_ key: String, payload: Data) throws {
        let statement = try statement("INSERT INTO metadata(key,payload) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        try bind(payload, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
}

private enum DurableFile {
    /// fsync content, atomic rename on the same volume, then fsync the directory entry.
    static func replace(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw KeystormError.message("Could not create durable snapshot.") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let descriptor = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
