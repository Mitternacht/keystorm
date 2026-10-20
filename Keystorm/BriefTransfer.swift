import Foundation

struct PreparedBriefExport: Sendable {
    let directory: URL
    let destination: URL
    let provenance: URL?
}

/// Prepare all potentially expensive encoding and synchronization away from the UI actor.
/// The coordinator checks its current revision immediately before this small atomic commit.
enum BriefTransfer {
    struct Provenance: Codable {
        var version = 2
        var exportedAt = Date()
        var scope: String?
        var omittedHistoricalFactIDs: [UUID]?
        var sessionID: UUID
        var brief: BriefDocument
        var dispositions: [FactDisposition]
        var facts: [Fact]
        var transcripts: [TranscriptRevision]
        var contexts: [ContextSnapshot]
        var segments: [AudioSegment]
        var gaps: [SessionGap]
        var configurations: [ProcessingConfiguration]
    }

    static func prepare(_ snapshot: ReviewedBriefSnapshot, to destination: URL,
                        includeProvenance: Bool) throws -> PreparedBriefExport {
        guard snapshot.session.trashedAt == nil,
              let brief = snapshot.session.brief, brief.revisionID == snapshot.revisionID, brief.isReviewed,
              snapshot.text.utf8.elementsEqual(brief.markdown(title: snapshot.session.title).utf8) else {
            throw KeystormError.message("The export snapshot does not match a reviewed document.")
        }
        try brief.validate(session: snapshot.session)
        guard !brief.reviewIssues(session: snapshot.session).contains(where: { $0.severity == .blocker }) else {
            throw KeystormError.message("Resolve pending changes and source issues before exporting.")
        }
        let sidecar = includeProvenance ? destination.appendingPathExtension("provenance.json") : nil
        try requireAbsent(destination)
        if let sidecar { try requireAbsent(sidecar) }
        let stage = destination.deletingLastPathComponent()
            .appendingPathComponent(".brief-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        do {
            try write(Data(snapshot.text.utf8), to: stage.appendingPathComponent("brief.md"))
            if sidecar != nil {
                let provenance = try currentProvenance(session: snapshot.session, brief: brief)
                let data = try JSONEncoder().encode(provenance)
                guard data.count <= 64 * 1_024 * 1_024 else {
                    throw KeystormError.message("Provenance exceeds the 64 MB transfer limit.")
                }
                try write(data, to: stage.appendingPathComponent("provenance.json"))
            }
            try CaptureDurability.synchronizeDirectory(stage)
            return PreparedBriefExport(directory: stage, destination: destination, provenance: sidecar)
        } catch { try? FileManager.default.removeItem(at: stage); throw error }
    }

    /// The handoff sidecar describes the reviewed document; a full archive retains library history.
    private static func currentProvenance(session: VoiceSession, brief: BriefDocument) throws -> Provenance {
        let activeTranscripts = session.activeTranscriptRevisions
        let transcriptsByID = Dictionary(activeTranscripts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let activeTranscriptIDs = Set(transcriptsByID.keys)
        let factsByID = Dictionary(session.facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func hasActiveSources(_ fact: Fact) -> Bool {
            fact.sources.allSatisfy { activeTranscriptIDs.contains($0.transcriptID) }
        }
        var factIDs = Set(LedgerValidation.currentFacts(in: session).map(\.id))
        factIDs.formUnion(brief.blocks.flatMap(\.factIDs))
        factIDs.formUnion(brief.removedFactIDs.filter { factsByID[$0].map(hasActiveSources) ?? false })
        var omittedPredecessors = Set<UUID>()
        var factQueue = Array(factIDs)
        var index = 0
        while index < factQueue.count {
            guard let fact = factsByID[factQueue[index]], hasActiveSources(fact) else {
                throw KeystormError.message("The brief still links a fact from Trash or an earlier audio version. Restore or reconcile that source before exporting.")
            }
            if let previousID = fact.supersedes, let previous = factsByID[previousID] {
                if hasActiveSources(previous) {
                    if factIDs.insert(previousID).inserted { factQueue.append(previousID) }
                } else { omittedPredecessors.insert(previousID) }
            }
            index += 1
        }
        let facts = session.facts.filter { factIDs.contains($0.id) }
        var transcriptIDs = Set(brief.blocks.flatMap(\.sources).map(\.transcriptID))
        transcriptIDs.formUnion(facts.flatMap(\.sources).map(\.transcriptID))
        var transcriptQueue = Array(transcriptIDs)
        index = 0
        while index < transcriptQueue.count {
            guard let transcript = transcriptsByID[transcriptQueue[index]] else {
                throw KeystormError.message("A required document source is in Trash or an earlier audio version. Restore or reconcile it before exporting.")
            }
            for parent in transcript.replacedRevisionIDs {
                guard activeTranscriptIDs.contains(parent) else {
                    throw KeystormError.message("A required correction ancestor is unavailable in the active recording version.")
                }
                if transcriptIDs.insert(parent).inserted { transcriptQueue.append(parent) }
            }
            index += 1
        }
        let transcripts = activeTranscripts.filter { transcriptIDs.contains($0.id) }
        let segmentIDs = Set(transcripts.flatMap(\.segmentIDs))
        let contextIDs = Set(brief.blocks.flatMap(\.contextIDs))
        let represented = Set(brief.blocks.flatMap(\.factIDs))
        let removed = Set(brief.removedFactIDs)
        let dispositions = facts.map { fact in
            FactDisposition(factID: fact.id, disposition: represented.contains(fact.id) ? "included" :
                removed.contains(fact.id) ? "deliberately omitted or replaced" :
                fact.status == .superseded ? "superseded" : "unresolved")
        }
        var current = BriefDocument()
        current.schemaVersion = brief.schemaVersion
        current.revisionID = brief.revisionID
        current.sections = brief.sections
        current.reviewedRevisionID = brief.reviewedRevisionID
        current.removedFactIDs = brief.removedFactIDs.filter { factIDs.contains($0) }
        return Provenance(scope: "Reviewed current brief and its required active source lineage; library, Trash and undo history are excluded. Use a full session archive for reversible history.",
            omittedHistoricalFactIDs: omittedPredecessors.sorted { $0.uuidString < $1.uuidString },
            sessionID: session.id, brief: current, dispositions: dispositions, facts: facts, transcripts: transcripts,
            contexts: session.contexts.filter { contextIDs.contains($0.id) },
            segments: session.activeSegments.filter { segmentIDs.contains($0.id) },
            gaps: session.gaps, configurations: session.configurations)
    }

    static func commit(_ export: PreparedBriefExport) throws {
        defer { discard(export) }
        try requireAbsent(export.destination)
        if let sidecar = export.provenance { try requireAbsent(sidecar) }
        var movedSidecar = false
        do {
            if let sidecar = export.provenance {
                try FileManager.default.moveItem(at: export.directory.appendingPathComponent("provenance.json"), to: sidecar)
                movedSidecar = true
            }
            try FileManager.default.moveItem(at: export.directory.appendingPathComponent("brief.md"), to: export.destination)
            try CaptureDurability.synchronizeDirectory(export.destination.deletingLastPathComponent())
        } catch {
            if movedSidecar, !FileManager.default.fileExists(atPath: export.destination.path), let sidecar = export.provenance {
                try? FileManager.default.removeItem(at: sidecar)
            }
            throw error
        }
    }

    static func discard(_ export: PreparedBriefExport) {
        try? FileManager.default.removeItem(at: export.directory)
    }

    private static func requireAbsent(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw KeystormError.message("Choose a new filename; existing files are preserved.")
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        try CaptureDurability.synchronize(url)
    }
}
