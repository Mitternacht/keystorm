import AVFoundation
import CryptoKit
import Foundation

/// Explicit user-initiated transfer only. No network calls or assistant execution.
enum SessionTransfer {
    private static let maximumManifestBytes = 64 * 1_024 * 1_024
    private static let maximumSidecarBytes = 256 * 1_024
    private static let maximumAudioBytes: Int64 = 50 * 1_024 * 1_024 * 1_024

    private struct PromptProvenance: Codable {
        var version = 1
        var exportedAt = Date()
        var sessionID: UUID
        var sessionTitle: String
        var draft: PromptRevision
        var facts: [Fact]
        var transcripts: [TranscriptRevision]
        var contexts: [ContextSnapshot]
        var segments: [AudioSegment]
        var gaps: [SessionGap]
        var configurations: [ProcessingConfiguration]
    }

    static func exportPrompt(
        draft: PromptRevision, session: VoiceSession, to destination: URL,
        includeProvenance: Bool
    ) throws {
        try validateMetadata(session)
        guard session.trashedAt == nil, draft.reviewed, !draft.stale,
              session.drafts.contains(where: { $0 == draft && $0.text.utf8.elementsEqual(draft.text.utf8) }),
              Set(draft.transcriptIDs) == Set(session.currentTranscripts.map(\.id)),
              Set(draft.contextIDs) == Set(session.contexts.map(\.id)) else {
            throw KeystormError.message("Review the current draft before exporting. Its source revisions must still be current.")
        }
        let currentFacts = Set(LedgerValidation.currentFacts(in: session).map(\.id))
        guard Set(draft.factIDs).isSubset(of: currentFacts) else {
            throw KeystormError.message("The draft contains facts from superseded or stale sources.")
        }
        let sidecar = destination.appendingPathExtension("provenance.json")
        try requireAbsent(destination)
        if includeProvenance { try requireAbsent(sidecar) }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".prompt-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let text = stage.appendingPathComponent("prompt.txt")
        try writeDurably(Data(draft.text.utf8), to: text)
        var movedSidecar = false
        do {
            if includeProvenance {
                let inactiveTranscriptIDs = session.inactiveTranscriptIDs
                let provenance = PromptProvenance(
                    sessionID: session.id, sessionTitle: session.title, draft: draft,
                    facts: session.facts.filter { fact in
                        fact.sources.allSatisfy { !inactiveTranscriptIDs.contains($0.transcriptID) }
                    }, transcripts: session.activeTranscriptRevisions, contexts: session.contexts,
                    segments: session.activeSegments, gaps: session.gaps, configurations: session.configurations
                )
                let stagedSidecar = stage.appendingPathComponent("provenance.json")
                try writeDurably(JSONEncoder().encode(provenance), to: stagedSidecar)
                try FileManager.default.moveItem(at: stagedSidecar, to: sidecar)
                movedSidecar = true
            }
            try FileManager.default.moveItem(at: text, to: destination)
            try CaptureDurability.synchronizeDirectory(destination.deletingLastPathComponent())
        } catch {
            // Only remove the newly created companion, never an existing destination.
            if movedSidecar, !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: sidecar)
            }
            throw error
        }
    }

    /// A portable folder package. Only referenced committed assets are copied.
    static func exportArchive(session: VoiceSession, audioDirectory: URL, to destination: URL) throws {
        try validateMetadata(session)
        guard session.status != .recording, session.unavailableSegmentIDs.isEmpty else {
            throw KeystormError.message("Pause recording and restore missing audio before exporting a complete session archive.")
        }
        try requireAbsent(destination)
        try requireDirectory(audioDirectory)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".session-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let audio = stage.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: false)
        try copyVerifiedAudio(session: session, from: audioDirectory, to: audio)
        try writeDurably(JSONEncoder().encode(session), to: stage.appendingPathComponent("session.json"))
        try CaptureDurability.synchronizeDirectory(audio)
        try CaptureDurability.synchronizeDirectory(stage)
        try FileManager.default.moveItem(at: stage, to: destination)
        try CaptureDurability.synchronizeDirectory(destination.deletingLastPathComponent())
    }

    /// Imports into a new session identity. Existing sessions and the chosen archive are untouched.
    static func importArchive(from archive: URL, store: SessionStore) async throws -> VoiceSession {
        try requireDirectory(archive)
        let manifest = try child("session.json", in: archive)
        let data = try readMetadata(manifest, maximumBytes: maximumManifestBytes)
        var session = try JSONDecoder().decode(VoiceSession.self, from: data)
        try validateMetadata(session)
        guard session.unavailableSegmentIDs.isEmpty else {
            throw KeystormError.message("This archive declares missing audio. Restore its assets before importing it.")
        }
        let sourceAudio = try child("Audio", in: archive)
        try requireDirectory(sourceAudio)
        let existing = Set(try await store.loadSessions().map(\.id))
        repeat { session.id = UUID() } while existing.contains(session.id)
        let target = try await store.sessionDirectory(session.id)
        // This freshly generated identity must not reuse a partial import directory.
        guard try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty else {
            throw KeystormError.message("The new import directory is unexpectedly occupied.")
        }
        let stage = target.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        var saveAttempted = false
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            try copyVerifiedAudio(session: session, from: sourceAudio, to: stage)
            try CaptureDurability.synchronizeDirectory(stage)
            let audio = target.appendingPathComponent("Audio", isDirectory: true)
            try FileManager.default.moveItem(at: stage, to: audio)
            try CaptureDurability.synchronizeDirectory(target)
            if session.status == .recording {
                session.status = .interrupted
                session.gaps.append(SessionGap(reason: "Imported while recording was active. No audio beyond the archived segments is assumed."))
            }
            for index in session.intervals.indices where session.intervals[index].endedAt == nil {
                let interval = session.intervals[index]
                let end = session.segments.filter { $0.intervalID == interval.id }.map(\.committedAt).max() ?? interval.startedAt
                session.intervals[index].endedAt = max(interval.startedAt, end)
            }
            for index in session.jobs.indices where session.jobs[index].status == .running {
                session.jobs[index].status = .incomplete
                session.jobs[index].error = "Processing was active at export. Retry this section locally."
            }
            if var brief = session.brief {
                for index in brief.takes.indices where brief.takes[index].status == .recording {
                    brief.takes[index].status = .paused
                }
                session.brief = brief
            }
            // Preserve original draft/source IDs but require review after import.
            for index in session.drafts.indices { session.drafts[index].reviewed = false }
            session.brief?.reviewedRevisionID = nil
            session.updatedAt = Date()
            saveAttempted = true
            try await store.save(session)
            return session
        } catch {
            // A save may have durably renamed session.json before its catalog write failed.
            // Retain such a folder for startup reconciliation.
            if !saveAttempted { try? FileManager.default.removeItem(at: target) }
            throw error
        }
    }

    private static func copyVerifiedAudio(session: VoiceSession, from source: URL, to target: URL) throws {
        var total: Int64 = 0
        for segment in session.segments {
            let audio = try child(segment.fileName, in: source)
            let sidecarName = "\(segment.id.uuidString).json"
            let sidecar = try child(sidecarName, in: source)
            let decoded = try JSONDecoder().decode(
                AudioSegment.self, from: readMetadata(sidecar, maximumBytes: maximumSidecarBytes)
            )
            guard decoded == segment else { throw KeystormError.message("Audio sidecar conflicts with session metadata.") }
            let size = try regularFileSize(audio)
            guard size <= maximumAudioBytes - total else { throw KeystormError.message("The archive exceeds the 50 GB audio transfer limit.") }
            total += size
            try validateAudio(segment, at: audio)
            let copy = target.appendingPathComponent(segment.fileName)
            try FileManager.default.copyItem(at: audio, to: copy)
            // Validate the actual local copy too, guarding against source mutation during copy.
            try validateAudio(segment, at: copy)
            try CaptureDurability.synchronize(copy)
            try writeDurably(JSONEncoder().encode(segment), to: target.appendingPathComponent(sidecarName))
        }
    }

    private static func validateAudio(_ segment: AudioSegment, at url: URL) throws {
        _ = try regularFileSize(url)
        guard try SessionStore.checksum(url) == segment.sha256.lowercased() else {
            throw KeystormError.message("Audio checksum mismatch. No complete session was imported.")
        }
        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        guard file.length == segment.frameCount,
              abs(file.fileFormat.sampleRate - segment.sampleRate) < 0.001,
              Int(file.fileFormat.channelCount) == segment.channelCount else {
            throw KeystormError.message("Audio header differs from its source metadata.")
        }
    }

    private static func validateMetadata(_ session: VoiceSession) throws {
        guard session.schemaVersion == 1 else { throw KeystormError.message("Unsupported archive schema.") }
        guard session.trashedAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw KeystormError.message("The archive has invalid Trash metadata.")
        }
        let groups = [
            session.intervals.map(\.id), session.segments.map(\.id), session.transcripts.map(\.id),
            session.facts.map(\.id), session.contexts.map(\.id), session.drafts.map(\.id),
            session.corrections.map(\.id), session.jobs.map(\.id), session.configurations.map(\.id)
        ]
        guard groups.allSatisfy({ $0.count <= 50_000 && Set($0).count == $0.count }),
              session.segments.count <= 20_000, session.gaps.count <= 50_000 else {
            throw KeystormError.message("Archive record counts or identities are invalid.")
        }
        try bounded(session.title, bytes: 16_384)
        try bounded(session.taskDescription, bytes: 2 * 1_024 * 1_024)
        let intervals = Set(session.intervals.map(\.id))
        let segments = Set(session.segments.map(\.id))
        let transcripts = Set(session.transcripts.map(\.id))
        let contexts = Set(session.contexts.map(\.id))
        let facts = Set(session.facts.map(\.id))
        let configurations = Set(session.configurations.map(\.id))
        for segment in session.segments {
            guard segment.fileName == "\(segment.id.uuidString).caf", intervals.contains(segment.intervalID),
                  segment.startTime.isFinite, segment.startTime >= 0,
                  segment.sampleRate.isFinite, segment.sampleRate > 0, segment.sampleRate <= 384_000,
                  segment.frameCount > 0, segment.channelCount > 0, segment.channelCount <= 64,
                  segment.endTime.isFinite, segment.duration <= 600,
                  segment.sha256.count == 64, segment.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw KeystormError.message("Unsafe audio identity, range, or format in archive.")
            }
        }
        let ordered = session.segments.sorted { $0.startTime < $1.startTime }
        for index in ordered.indices.dropFirst() where ordered[index].startTime < ordered[index - 1].endTime - 0.001 {
            throw KeystormError.message("Archive contains overlapping audio source ranges.")
        }
        let revisions = Dictionary(uniqueKeysWithValues: session.transcripts.map { ($0.id, $0) })
        var parentCounts = [UUID: Int]()
        var children = [UUID: [UUID]]()
        for transcript in session.transcripts {
            try bounded(transcript.text, bytes: 2 * 1_024 * 1_024)
            try bounded(transcript.rawText, bytes: 2 * 1_024 * 1_024)
            guard transcript.startTime.isFinite, transcript.endTime.isFinite,
                  transcript.startTime >= 0, transcript.endTime >= transcript.startTime,
                  Set(transcript.segmentIDs).isSubset(of: segments),
                  (transcript.replacesIDs?.count ?? 0) <= 20_000,
                  Set(transcript.replacesIDs ?? []).count == (transcript.replacesIDs?.count ?? 0),
                  Set(transcript.replacedRevisionIDs).isSubset(of: transcripts),
                  !transcript.replacedRevisionIDs.contains(transcript.id),
                  transcript.configurationID == nil || configurations.contains(transcript.configurationID!) else {
                throw KeystormError.message("Archive transcript references or timing are invalid.")
            }
            let parents = transcript.replacedRevisionIDs
            parentCounts[transcript.id] = parents.count
            for parent in parents { children[parent, default: []].append(transcript.id) }
        }
        // Linear topological traversal supports merged corrections without recursive stack growth.
        var ready = session.transcripts.filter { parentCounts[$0.id] == 0 }.map(\.id)
        var processed = 0
        while processed < ready.count {
            for child in children[ready[processed], default: []] {
                parentCounts[child, default: 0] -= 1
                if parentCounts[child] == 0 { ready.append(child) }
            }
            processed += 1
        }
        guard processed == session.transcripts.count else { throw KeystormError.message("Cyclic transcript revision history.") }
        for context in session.contexts {
            try bounded(context.content, bytes: 4 * 1_024 * 1_024)
            try bounded(context.title, bytes: 16_384)
            let checksum = SHA256.hash(data: Data(context.content.utf8)).map { String(format: "%02x", $0) }.joined()
            guard checksum == context.sha256.lowercased() else { throw KeystormError.message("Context snapshot checksum mismatch.") }
        }
        for fact in session.facts {
            try bounded(fact.text, bytes: 1_024 * 1_024)
            guard fact.sources.count <= 10_000,
                  fact.supersedes == nil || facts.contains(fact.supersedes!) else {
                throw KeystormError.message("Archive fact history is invalid.")
            }
        }
        try LedgerValidation.validate(session.facts, transcripts: session.transcripts)
        try session.brief?.validate(session: session)
        for patch in session.corrections {
            guard let original = revisions[patch.originalRevisionID], let corrected = revisions[patch.correctedRevisionID],
                  corrected.replacedRevisionIDs.contains(original.id),
                  patch.before.utf8.elementsEqual(original.text.utf8),
                  patch.after.utf8.elementsEqual(corrected.text.utf8) else {
                throw KeystormError.message("Archive correction history is inconsistent.")
            }
        }
        for draft in session.drafts {
            try bounded(draft.text, bytes: 8 * 1_024 * 1_024)
            guard Set(draft.factIDs).isSubset(of: facts), Set(draft.transcriptIDs).isSubset(of: transcripts),
                  Set(draft.contextIDs).isSubset(of: contexts),
                  draft.dispositions.allSatisfy({ facts.contains($0.factID) }),
                  draft.configurationID == nil || configurations.contains(draft.configurationID!) else {
                throw KeystormError.message("Archive draft refers to missing source records.")
            }
        }
        guard try JSONEncoder().encode(session).count <= maximumManifestBytes else {
            throw KeystormError.message("Archive metadata exceeds the 64 MB limit.")
        }
    }

    private static func bounded(_ text: String, bytes: Int) throws {
        guard text.utf8.count <= bytes else { throw KeystormError.message("Archive text exceeds the supported metadata limit.") }
    }

    private static func readMetadata(_ url: URL, maximumBytes: Int) throws -> Data {
        let size = try regularFileSize(url)
        guard size <= maximumBytes else { throw KeystormError.message("Archive metadata file is too large.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw KeystormError.message("Archive metadata file grew beyond its limit.") }
        return data
    }

    private static func child(_ name: String, in directory: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw KeystormError.message("Unsafe archive path.")
        }
        let url = directory.appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else {
            throw KeystormError.message("Archive reference escapes its folder.")
        }
        return url
    }

    private static func regularFileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else {
            throw KeystormError.message("Archive assets must be regular files, without symbolic links.")
        }
        return Int64(size)
    }

    private static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw KeystormError.message("Choose a session folder package without symbolic links.")
        }
    }

    private static func requireAbsent(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw KeystormError.message("Choose a new export filename; existing files are preserved.")
        }
    }

    private static func writeDurably(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        try CaptureDurability.synchronize(url)
    }
}
