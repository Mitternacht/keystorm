import Foundation

enum BriefSectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case goal, changes, constraints, acceptance, deferred, questions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .goal: "Goal"
        case .changes: "Proposed changes"
        case .constraints: "Constraints"
        case .acceptance: "Acceptance criteria"
        case .deferred: "Deferred work"
        case .questions: "Open questions"
        }
    }
    static func matching(_ text: String) -> Self? {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "goal", "goals", "objective", "objectives": return .goal
        case "changes", "proposed changes", "requirements", "requirement", "tasks", "task": return .changes
        case "constraints", "constraint", "limitations": return .constraints
        case "acceptance", "acceptance criteria", "tests", "test": return .acceptance
        case "deferred", "deferred work", "later", "out of scope": return .deferred
        case "questions", "open questions", "question", "uncertainties": return .questions
        default: return nil
        }
    }
}

enum BriefOrigin: String, Codable, Sendable { case typed, clipboard, file, speech, voiceEdit, migrated }

struct BriefBlock: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var origin: BriefOrigin = .typed
    var sources: [SourceReference] = []
    var contextIDs: [UUID] = []
    var factIDs: [UUID] = []
    var exact = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.text.utf8.elementsEqual(rhs.text.utf8) && lhs.origin == rhs.origin &&
        lhs.sources == rhs.sources && lhs.contextIDs == rhs.contextIDs && lhs.factIDs == rhs.factIDs && lhs.exact == rhs.exact
    }
}

struct BriefSection: Identifiable, Codable, Equatable, Sendable {
    var kind: BriefSectionKind
    var blocks: [BriefBlock] = []
    var id: BriefSectionKind { kind }
}

enum CaptureIntent: String, Codable, CaseIterable, Sendable { case addMaterial, editBrief }
enum BriefTakeStatus: String, Codable, Sendable { case recording, paused, pending, applied, failed, discarded, dismissed }

/// Derived audio keeps the original capture and earlier generations available for restoration.
struct RecordingAudioRevision: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var label: String
    var intervalIDs: [UUID]
}

struct BriefTake: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var intervalID: UUID?
    var intervalIDs: [UUID] = []
    var intent: CaptureIntent = .addMaterial
    var targetSection: BriefSectionKind = .changes
    var expectedRevision: UUID
    var selectedBlockIDs: [UUID] = []
    var status: BriefTakeStatus = .pending
    var transcriptIDs: [UUID] = []
    var createdAt = Date()
    var name: String?
    var trashedAt: Date?
    var audioRevisions: [RecordingAudioRevision]?
    var activeAudioRevisionID: UUID?
    var displayName: String {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Recording" : value
    }
    var captureIntervalIDs: [UUID] { Self.unique((intervalID.map { [$0] } ?? []) + intervalIDs) }
    var activeIntervalIDs: [UUID] {
        guard let activeAudioRevisionID,
              let revision = audioRevisions?.first(where: { $0.id == activeAudioRevisionID }) else { return captureIntervalIDs }
        return revision.intervalIDs
    }
    var allIntervalIDs: [UUID] { Self.unique(captureIntervalIDs + (audioRevisions ?? []).flatMap(\.intervalIDs)) }
    var expectedRevisionID: UUID {
        get { expectedRevision }
        set { expectedRevision = newValue }
    }
    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
    private enum CodingKeys: String, CodingKey {
        case id, intervalID, intervalIDs, intent, targetSection, expectedRevision, selectedBlockIDs
        case status, transcriptIDs, createdAt, name, trashedAt, audioRevisions, activeAudioRevisionID
    }
}

extension BriefTake {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        intervalID = try values.decodeIfPresent(UUID.self, forKey: .intervalID)
        intervalIDs = try values.decodeIfPresent([UUID].self, forKey: .intervalIDs) ?? []
        intent = try values.decode(CaptureIntent.self, forKey: .intent)
        targetSection = try values.decode(BriefSectionKind.self, forKey: .targetSection)
        expectedRevision = try values.decode(UUID.self, forKey: .expectedRevision)
        selectedBlockIDs = try values.decode([UUID].self, forKey: .selectedBlockIDs)
        status = try values.decode(BriefTakeStatus.self, forKey: .status)
        transcriptIDs = try values.decode([UUID].self, forKey: .transcriptIDs)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        trashedAt = try values.decodeIfPresent(Date.self, forKey: .trashedAt)
        audioRevisions = try values.decodeIfPresent([RecordingAudioRevision].self, forKey: .audioRevisions)
        activeAudioRevisionID = try values.decodeIfPresent(UUID.self, forKey: .activeAudioRevisionID)
    }
}

enum BriefEdit: Codable, Equatable, Sendable {
    case append(section: BriefSectionKind, block: BriefBlock)
    case replace(blockID: UUID, text: String, origin: BriefOrigin, sources: [SourceReference], allowExact: Bool = false)
    case move(blockID: UUID, section: BriefSectionKind, index: Int?)
    case remove(blockID: UUID, allowExact: Bool = false)
}

enum BriefProposalAction: String, Codable, Sendable { case edits, undo, redo }

struct BriefProposal: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var expectedRevision: UUID
    var edits: [BriefEdit]
    var takeIDs: [UUID]
    var label: String
    var createdAt = Date()
    var issues: [String] = []
    var action: BriefProposalAction = .edits
    var expectedRevisionID: UUID {
        get { expectedRevision }
        set { expectedRevision = newValue }
    }
    var summary: String { label }
}

struct BriefPlacement: Codable, Equatable, Sendable {
    var section: BriefSectionKind
    var index: Int
    var block: BriefBlock
}

struct BriefBlockChange: Codable, Equatable, Sendable {
    var blockID: UUID
    var before: BriefPlacement?
    var after: BriefPlacement?
}

struct BriefChange: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var label: String
    var beforeRevisionID: UUID
    var afterRevisionID: UUID
    var changes: [BriefBlockChange]
    var addedRemovedFactIDs: [UUID]
    var restoredFactIDs: [UUID]
}

struct BriefUndoDisposition: Codable, Equatable, Sendable {
    var changeID: UUID
    var addedRemovedFactIDs: [UUID]
    var restoredFactIDs: [UUID]
}

enum BriefHistoryAction: String, Codable, Sendable { case apply, undo, redo }

struct BriefHistoryEvent: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var action: BriefHistoryAction
    var changeID: UUID
    var revisionID: UUID
}

enum BriefIssueSeverity: String, Codable, Sendable { case attention, blocker }
enum BriefIssueKind: String, Codable, Sendable {
    case emptyDocument, missingSource, staleSource, invalidSource, missingContext, missingFact
    case unsupportedAddition, uncertain, superseded, omittedFact, pendingTake, migrated
    case recordingGap, unavailableAudio, incompleteTranscription
}

struct BriefReviewIssue: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var kind: BriefIssueKind
    var severity: BriefIssueSeverity
    var message: String
    var blockID: UUID?
    var factID: UUID?
}

enum BriefDocumentError: LocalizedError, Equatable {
    case staleRevision, missingBlock, duplicateBlock, protectedLiteral, ambiguousTarget, unsupportedCommand
    case invalidDocument(String)
    var errorDescription: String? {
        switch self {
        case .staleRevision: "The brief changed. Review this change against the current document."
        case .missingBlock: "The selected passage no longer exists."
        case .duplicateBlock: "A passage identifier occurs more than once."
        case .protectedLiteral: "This is an exact reference. Unlock it deliberately before changing or removing it."
        case .ambiguousTarget: "Select a passage or name an unambiguous section and numbered passage."
        case .unsupportedCommand: "Use append to section: text, replace selected with text, move selected to section, remove selected, undo, or redo."
        case .invalidDocument(let message): message
        }
    }
}

/// A durable document and a compact, append-only change journal. Changes copy only affected blocks,
/// never the complete transcript or complete document. Undo branches remain in the journal.
struct BriefDocument: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var revisionID = UUID()
    var sections = BriefSectionKind.allCases.map { BriefSection(kind: $0) }
    var takes: [BriefTake] = []
    var history: [BriefChange] = []
    var events: [BriefHistoryEvent] = []
    var undoStack: [UUID] = []
    var redoStack: [UUID] = []
    var reviewedRevisionID: UUID?
    var removedFactIDs: [UUID] = []
    var pendingProposal: BriefProposal?
    private(set) var journalTextBytes = 0
    // Optional for archives created before undo started carrying explicit omission state.
    var undoDispositions: [BriefUndoDisposition]?

    var cursor: Int { undoStack.count }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isReviewed: Bool { reviewedRevisionID == revisionID }
    var blocks: [BriefBlock] { sections.flatMap(\.blocks) }

    func section(_ kind: BriefSectionKind) -> BriefSection {
        sections.first { $0.kind == kind } ?? BriefSection(kind: kind)
    }
    func block(_ id: UUID) -> BriefBlock? { blocks.first { $0.id == id } }
    func placement(_ id: UUID) -> BriefPlacement? {
        for section in sections {
            if let index = section.blocks.firstIndex(where: { $0.id == id }) {
                return BriefPlacement(section: section.kind, index: index, block: section.blocks[index])
            }
        }
        return nil
    }

    func markdown(title: String) -> String {
        var parts = ["# " + title]
        for section in sections where !section.blocks.isEmpty {
            parts.append("## " + section.kind.title)
            parts.append(section.blocks.map(\.text).joined(separator: "\n\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    mutating func apply(_ edits: [BriefEdit], expectedRevision: UUID, label: String, coalesce: Bool = false) throws {
        guard expectedRevision == revisionID else { throw BriefDocumentError.staleRevision }
        guard !edits.isEmpty, edits.count <= 2_000 else {
            throw BriefDocumentError.invalidDocument("A change must contain between 1 and 2,000 operations.")
        }
        try validateStructure(checkJournal: false)
        var next = self
        var affected = Set<UUID>()
        let previousRemoved = Set(removedFactIDs)
        var nextRemoved = previousRemoved
        for edit in edits {
            switch edit {
            case .append(let kind, let block):
                guard next.placement(block.id) == nil else { throw BriefDocumentError.duplicateBlock }
                guard !block.text.isEmpty || block.origin == .typed else { throw BriefDocumentError.invalidDocument("A proposed passage cannot be empty.") }
                guard let index = next.sections.firstIndex(where: { $0.kind == kind }) else { throw BriefDocumentError.ambiguousTarget }
                next.sections[index].blocks.append(block)
                nextRemoved.subtract(block.factIDs)
                affected.insert(block.id)
            case .replace(let id, let text, let origin, let sources, let allowExact):
                guard let position = next.placement(id) else { throw BriefDocumentError.missingBlock }
                guard !position.block.exact || allowExact else { throw BriefDocumentError.protectedLiteral }
                guard !text.isEmpty || origin == .typed else { throw BriefDocumentError.invalidDocument("A proposed replacement cannot be empty.") }
                let sectionIndex = next.sections.firstIndex { $0.kind == position.section }!
                var block = position.block
                if !text.utf8.elementsEqual(block.text.utf8) {
                    nextRemoved.formUnion(block.factIDs)
                    block.factIDs = []
                }
                block.text = text
                block.origin = origin
                block.sources = sources
                // Deliberately unlocking an exact block makes subsequent edits ordinary edits.
                if allowExact { block.exact = false }
                next.sections[sectionIndex].blocks[position.index] = block
                affected.insert(id)
            case .move(let id, let kind, let requestedIndex):
                guard let position = next.placement(id) else { throw BriefDocumentError.missingBlock }
                let sourceIndex = next.sections.firstIndex { $0.kind == position.section }!
                next.sections[sourceIndex].blocks.remove(at: position.index)
                guard let destination = next.sections.firstIndex(where: { $0.kind == kind }) else { throw BriefDocumentError.ambiguousTarget }
                let index = requestedIndex ?? next.sections[destination].blocks.count
                guard index >= 0, index <= next.sections[destination].blocks.count else {
                    throw BriefDocumentError.invalidDocument("The destination position is outside the section.")
                }
                next.sections[destination].blocks.insert(position.block, at: index)
                affected.insert(id)
            case .remove(let id, let allowExact):
                guard let position = next.placement(id) else { throw BriefDocumentError.missingBlock }
                guard !position.block.exact || allowExact else { throw BriefDocumentError.protectedLiteral }
                nextRemoved.formUnion(position.block.factIDs)
                let sectionIndex = next.sections.firstIndex { $0.kind == position.section }!
                next.sections[sectionIndex].blocks.remove(at: position.index)
                affected.insert(id)
            }
        }
        let changes = affected.sorted { $0.uuidString < $1.uuidString }.compactMap { id -> BriefBlockChange? in
            let before = placement(id)
            let after = next.placement(id)
            return before == after ? nil : BriefBlockChange(blockID: id, before: before, after: after)
        }
        guard !changes.isEmpty else { return }
        // A fact remains represented when another passage still carries it.
        nextRemoved.subtract(next.blocks.flatMap(\.factIDs))
        next.removedFactIDs = nextRemoved.sorted { $0.uuidString < $1.uuidString }
        let nextRevision = UUID()
        let change = BriefChange(label: label, beforeRevisionID: revisionID, afterRevisionID: nextRevision,
                                 changes: changes,
                                 addedRemovedFactIDs: Array(nextRemoved.subtracting(previousRemoved)),
                                 restoredFactIDs: Array(previousRemoved.subtracting(nextRemoved)))
        var committedID = change.id
        // A caller-controlled typing burst is one undo unit. Spoken and accepted proposals never coalesce.
        if coalesce, label == "Edit text", edits.count == 1, case .replace = edits[0],
           let previous = next.history.last, next.undoStack.last == previous.id,
           next.redoStack.isEmpty, previous.label == label,
           previous.changes.count == 1, changes.count == 1,
           previous.changes[0].blockID == changes[0].blockID,
           Date().timeIntervalSince(previous.createdAt) < 2 {
            var merged = previous
            merged.afterRevisionID = nextRevision
            merged.changes[0].after = changes[0].after
            merged.addedRemovedFactIDs = Array(Set(previous.addedRemovedFactIDs).union(change.addedRemovedFactIDs))
            merged.restoredFactIDs = Array(Set(previous.restoredFactIDs).union(change.restoredFactIDs))
            next.journalTextBytes += (changes[0].after?.block.text.utf8.count ?? 0) - (previous.changes[0].after?.block.text.utf8.count ?? 0)
            next.history[next.history.count - 1] = merged
            committedID = merged.id
        } else {
            next.journalTextBytes += changes.reduce(0) { $0 + ($1.before?.block.text.utf8.count ?? 0) + ($1.after?.block.text.utf8.count ?? 0) }
            next.history.append(change)
            next.undoStack.append(change.id)
        }
        next.redoStack = []
        next.revisionID = nextRevision
        next.reviewedRevisionID = nil
        if next.events.last?.changeID == committedID, coalesce {
            next.events[next.events.count - 1].revisionID = nextRevision
        } else {
            next.events.append(BriefHistoryEvent(action: .apply, changeID: committedID, revisionID: nextRevision))
        }
        try next.validateStructure(checkJournal: false)
        self = next
    }

    mutating func undo() throws {
        try validateStructure()
        guard let id = undoStack.last, let change = history.first(where: { $0.id == id }) else { return }
        var next = self
        try next.restore(change.changes, forward: false)
        let originalRemoved = Set(next.removedFactIDs)
        var removed = originalRemoved
        removed.subtract(change.addedRemovedFactIDs)
        removed.formUnion(change.restoredFactIDs)
        let represented = Set(next.blocks.flatMap(\.factIDs))
        let removedByUndo = Set(change.changes.compactMap(\.after).flatMap { $0.block.factIDs }).subtracting(represented)
        removed.formUnion(removedByUndo)
        removed.subtract(represented)
        var dispositions = next.undoDispositions ?? []
        dispositions.removeAll { $0.changeID == id }
        dispositions.append(BriefUndoDisposition(changeID: id,
            addedRemovedFactIDs: Array(removed.subtracting(originalRemoved)),
            restoredFactIDs: Array(originalRemoved.subtracting(removed))))
        next.undoDispositions = dispositions
        next.removedFactIDs = Array(removed)
        next.undoStack.removeLast()
        next.redoStack.append(id)
        next.revisionID = UUID()
        next.reviewedRevisionID = nil
        next.events.append(BriefHistoryEvent(action: .undo, changeID: id, revisionID: next.revisionID))
        try next.validateStructure()
        self = next
    }

    mutating func redo() throws {
        try validateStructure()
        guard let id = redoStack.last, let change = history.first(where: { $0.id == id }) else { return }
        var next = self
        try next.restore(change.changes, forward: true)
        var removed = Set(next.removedFactIDs)
        if let disposition = next.undoDispositions?.first(where: { $0.changeID == id }) {
            removed.subtract(disposition.addedRemovedFactIDs)
            removed.formUnion(disposition.restoredFactIDs)
        } else {
            removed.formUnion(change.addedRemovedFactIDs)
            removed.subtract(change.restoredFactIDs)
        }
        next.removedFactIDs = Array(removed)
        next.redoStack.removeLast()
        next.undoStack.append(id)
        next.revisionID = UUID()
        next.reviewedRevisionID = nil
        next.events.append(BriefHistoryEvent(action: .redo, changeID: id, revisionID: next.revisionID))
        try next.validateStructure()
        self = next
    }

    private mutating func restore(_ changes: [BriefBlockChange], forward: Bool) throws {
        for change in changes {
            let expected = forward ? change.before : change.after
            guard placement(change.blockID) == expected else {
                throw BriefDocumentError.invalidDocument("The undo journal does not match the current document.")
            }
        }
        let ids = Set(changes.map(\.blockID))
        for index in sections.indices { sections[index].blocks.removeAll { ids.contains($0.id) } }
        let placements = changes.compactMap { forward ? $0.after : $0.before }
        for kind in BriefSectionKind.allCases {
            let sectionIndex = sections.firstIndex { $0.kind == kind }!
            for placement in placements.filter({ $0.section == kind }).sorted(by: { $0.index < $1.index }) {
                guard placement.index >= 0, placement.index <= sections[sectionIndex].blocks.count else {
                    throw BriefDocumentError.invalidDocument("The stored undo operation has an invalid position.")
                }
                sections[sectionIndex].blocks.insert(placement.block, at: placement.index)
            }
        }
    }

    /// Only explicit source-linked decision relations produce this preview; recency never does.
    func supersessionEdits(factID: UUID, session: VoiceSession) throws -> [BriefEdit] {
        guard let correction = session.facts.first(where: { $0.id == factID }), let earlierID = correction.supersedes else {
            throw BriefDocumentError.invalidDocument("Choose an explicit source-linked correction.")
        }
        let earlier = blocks.filter { $0.factIDs.contains(earlierID) }
        let replacements = blocks.filter { $0.factIDs.contains(factID) }
        guard !earlier.isEmpty, !replacements.isEmpty,
              let target = placement(earlier[0].id)?.section else { throw BriefDocumentError.staleRevision }
        guard !earlier.contains(where: \.exact) else { throw BriefDocumentError.protectedLiteral }
        var edits = earlier.map { BriefEdit.remove(blockID: $0.id) }
        for block in replacements where placement(block.id)?.section == .questions {
            edits.append(.move(blockID: block.id, section: target, index: nil))
        }
        return edits
    }

    func activeLedgerFacts(in session: VoiceSession) -> [Fact] {
        let omitted = Set(removedFactIDs)
        return LedgerValidation.currentFacts(in: session).filter { !omitted.contains($0.id) }
    }

    mutating func markReviewed(session: VoiceSession) throws {
        try validate(session: session)
        let blockers = reviewIssues(session: session).filter { $0.severity == .blocker }
        guard blockers.isEmpty else { throw BriefDocumentError.invalidDocument(blockers.map(\.message).joined(separator: "\n")) }
        reviewedRevisionID = revisionID
    }

    /// Structural and provenance validation also runs when importing a document.
    func validate(session: VoiceSession) throws {
        try validateStructure()
        let provenanceKinds: Set<BriefIssueKind> = [.missingSource, .invalidSource, .missingContext, .missingFact]
        let failures = reviewIssues(session: session).filter { $0.severity == .blocker && provenanceKinds.contains($0.kind) }
        guard failures.isEmpty else { throw BriefDocumentError.invalidDocument(failures.map(\.message).joined(separator: "\n")) }
        let transcripts = Dictionary(session.transcripts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let factIDs = Set(session.facts.map(\.id))
        let contextIDs = Set(session.contexts.map(\.id))
        func validateBlock(_ block: BriefBlock) throws {
            guard (!block.text.isEmpty || block.origin == .typed), block.text.utf8.count <= 2_000_000,
                  Set(block.factIDs).isSubset(of: factIDs), Set(block.contextIDs).isSubset(of: contextIDs) else {
                throw BriefDocumentError.invalidDocument("A historical or proposed passage has invalid linked facts or context.")
            }
            if [.speech, .voiceEdit].contains(block.origin), block.sources.isEmpty {
                throw BriefDocumentError.invalidDocument("A historical or proposed speech passage has no source.")
            }
            for source in block.sources {
                guard let transcript = transcripts[source.transcriptID], Self.isValid(source, in: transcript.text) else {
                    throw BriefDocumentError.invalidDocument("A historical or proposed quotation has a missing or mismatched source.")
                }
            }
        }
        guard Set(removedFactIDs).isSubset(of: factIDs) else {
            throw BriefDocumentError.invalidDocument("A deliberately removed fact is absent from the archive.")
        }
        for disposition in undoDispositions ?? [] {
            guard Set(disposition.addedRemovedFactIDs + disposition.restoredFactIDs).isSubset(of: factIDs) else {
                throw BriefDocumentError.invalidDocument("An undo omission references a missing fact.")
            }
        }
        for change in history {
            guard Set(change.addedRemovedFactIDs + change.restoredFactIDs).isSubset(of: factIDs) else {
                throw BriefDocumentError.invalidDocument("An undo disposition references a missing fact.")
            }
            for item in change.changes {
                for placement in [item.before, item.after].compactMap({ $0 }) { try validateBlock(placement.block) }
            }
        }
        if let proposal = pendingProposal {
            guard Set(proposal.takeIDs).isSubset(of: Set(takes.map(\.id))) else {
                throw BriefDocumentError.invalidDocument("A pending proposal references a missing take.")
            }
            for edit in proposal.edits {
                switch edit {
                case .append(_, let block): try validateBlock(block)
                case .replace(_, let text, let origin, let sources, let allowExact):
                    guard !allowExact else { throw BriefDocumentError.protectedLiteral }
                    try validateBlock(BriefBlock(text: text, origin: origin, sources: sources))
                case .move(_, _, let index):
                    if let index, index < 0 || index > 10_000 {
                        throw BriefDocumentError.invalidDocument("A pending move has an invalid destination.")
                    }
                case .remove(_, let allowExact):
                    guard !allowExact else { throw BriefDocumentError.protectedLiteral }
                }
            }
        }
        try validateRecordingMetadata(session: session)
    }

    /// Bounded identity validation is also used by storage without scanning document text.
    func validateRecordingMetadata(session: VoiceSession) throws {
        let intervals = Set(session.intervals.map(\.id))
        let transcripts = Set(session.transcripts.map(\.id))
        guard takes.count <= 10_000, Set(takes.map(\.id)).count == takes.count,
              session.trashedAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw BriefDocumentError.invalidDocument("Recording identities or Trash metadata are invalid.")
        }
        var owners = [UUID: UUID]()
        var revisionIDs = Set<UUID>()
        for take in takes {
            let revisions = take.audioRevisions ?? []
            guard (take.name?.utf8.count ?? 0) <= 16_384,
                  take.trashedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
                  take.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  revisions.count <= 1_000, take.intervalIDs.count <= 20_000,
                  Set(take.intervalIDs).count == take.intervalIDs.count,
                  Set(take.transcriptIDs).isSubset(of: transcripts),
                  Set(take.allIntervalIDs).isSubset(of: intervals),
                  take.activeAudioRevisionID.map({ id in revisions.contains { $0.id == id } }) ?? true else {
                throw BriefDocumentError.invalidDocument("A recording has invalid names, versions, ranges or source references.")
            }
            var generationIntervals = Set(take.captureIntervalIDs)
            for revision in revisions {
                guard revisionIDs.insert(revision.id).inserted,
                      revision.createdAt.timeIntervalSinceReferenceDate.isFinite,
                      revision.label.utf8.count <= 16_384,
                      !revision.intervalIDs.isEmpty, revision.intervalIDs.count <= 20_000,
                      Set(revision.intervalIDs).count == revision.intervalIDs.count,
                      generationIntervals.isDisjoint(with: revision.intervalIDs) else {
                    throw BriefDocumentError.invalidDocument("Recording versions must have unique identities and their own retained audio intervals.")
                }
                generationIntervals.formUnion(revision.intervalIDs)
            }
            for interval in take.allIntervalIDs {
                guard owners.updateValue(take.id, forKey: interval) == nil else {
                    throw BriefDocumentError.invalidDocument("An audio interval belongs to more than one recording.")
                }
            }
        }
    }

    func validateStructure(checkJournal: Bool = true) throws {
        guard schemaVersion == 1 else { throw BriefDocumentError.invalidDocument("This brief uses an unsupported document version.") }
        guard sections.count == BriefSectionKind.allCases.count,
              Set(sections.map(\.kind)).count == BriefSectionKind.allCases.count else {
            throw BriefDocumentError.invalidDocument("The brief must contain each of the six sections exactly once.")
        }
        guard Set(blocks.map(\.id)).count == blocks.count else { throw BriefDocumentError.duplicateBlock }
        guard history.count <= 20_000, takes.count <= 10_000, blocks.count <= 10_000,
              blocks.reduce(0, { $0 + $1.text.utf8.count }) <= 2_000_000 else {
            throw BriefDocumentError.invalidDocument("The brief exceeds the bounded document limits.")
        }
        let historyIDs = Set(history.map(\.id))
        guard historyIDs.count == history.count, Set(undoStack).count == undoStack.count,
              Set(redoStack).count == redoStack.count,
              Set(undoStack).isDisjoint(with: redoStack),
              Set(undoStack + redoStack).isSubset(of: historyIDs) else {
            throw BriefDocumentError.invalidDocument("The brief has an invalid undo journal.")
        }
        let dispositions = undoDispositions ?? []
        guard dispositions.count <= history.count, Set(dispositions.map(\.changeID)).count == dispositions.count,
              Set(dispositions.map(\.changeID)).isSubset(of: historyIDs) else {
            throw BriefDocumentError.invalidDocument("The brief has invalid undo omissions.")
        }
        guard Set(takes.map(\.id)).count == takes.count else {
            throw BriefDocumentError.invalidDocument("A recorded take identifier occurs more than once.")
        }
        guard journalTextBytes >= 0, journalTextBytes <= 32_000_000 else {
            throw BriefDocumentError.invalidDocument("The document history exceeds the bounded archive limit.")
        }
        if checkJournal {
        var journalBytes = 0
        for change in history {
            guard change.changes.count <= 2_000, Set(change.changes.map(\.blockID)).count == change.changes.count else {
                throw BriefDocumentError.invalidDocument("The undo journal contains duplicated or excessive operations.")
            }
            for item in change.changes {
                guard item.before != nil || item.after != nil else {
                    throw BriefDocumentError.invalidDocument("The undo journal contains an empty operation.")
                }
                for placement in [item.before, item.after].compactMap({ $0 }) {
                    guard placement.block.id == item.blockID, placement.index >= 0, placement.index <= 10_000,
                          !placement.block.text.isEmpty || placement.block.origin == .typed else {
                        throw BriefDocumentError.invalidDocument("The undo journal contains a malformed passage.")
                    }
                    journalBytes += placement.block.text.utf8.count
                }
            }
        }
        guard journalBytes == journalTextBytes else {
            throw BriefDocumentError.invalidDocument("The document history has an invalid size checkpoint.")
        }
        }
        for block in blocks where block.text.isEmpty && block.origin != .typed {
            throw BriefDocumentError.invalidDocument("An imported proposed passage is empty: " + block.id.uuidString)
        }
        if let proposal = pendingProposal, proposal.edits.count > 2_000 {
            throw BriefDocumentError.invalidDocument("The pending proposal has too many operations.")
        }
    }

    func reviewIssues(session: VoiceSession) -> [BriefReviewIssue] {
        var issues: [BriefReviewIssue] = []
        func add(_ key: String, _ kind: BriefIssueKind, _ severity: BriefIssueSeverity, _ message: String, blockID: UUID? = nil, factID: UUID? = nil) {
            issues.append(BriefReviewIssue(id: key, kind: kind, severity: severity, message: message, blockID: blockID, factID: factID))
        }
        if session.trashedAt != nil {
            add("trashed-brief", .staleSource, .blocker, "Restore this brief from Trash before reviewing or exporting it.")
        }
        if blocks.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            add("empty", .emptyDocument, .blocker, "Add material to the brief before finishing it.")
        }
        if !session.gaps.isEmpty {
            add("recording-gaps", .recordingGap, .attention,
                "The recording has \(session.gaps.count) reported gap(s). Inspect the missing coverage in Sources before handing off.")
        }
        let activeSegments = session.activeSegments
        let inactiveIntervals = session.inactiveRecordingIntervalIDs
        let inactiveSegmentIDs = Set(session.segments.filter { inactiveIntervals.contains($0.intervalID) }.map(\.id))
        let unavailable = Set(session.unavailableSegmentIDs).subtracting(inactiveSegmentIDs)
        if !unavailable.isEmpty {
            add("unavailable-audio", .unavailableAudio, .attention,
                "\(unavailable.count) saved audio segment(s) are unavailable. Their recordings cannot currently be checked; inspect Sources before handing off.")
        }
        let currentTranscripts = session.currentTranscripts
        let covered = Set(currentTranscripts.filter(\.isComplete).flatMap(\.segmentIDs))
        let dismissedIntervals = Set(takes.filter { [.discarded, .dismissed].contains($0.status) }.flatMap(\.activeIntervalIDs))
        let uncovered = activeSegments.filter {
            !unavailable.contains($0.id) && !covered.contains($0.id) && !dismissedIntervals.contains($0.intervalID)
        }
        if !uncovered.isEmpty {
            add("untranscribed-audio", .incompleteTranscription, .blocker,
                "\(uncovered.count) saved audio segment(s) still need complete transcription or deliberate dismissal of their take.")
        }
        let transcripts = Dictionary(session.transcripts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(currentTranscripts.map(\.id))
        let inactiveTranscriptIDs = session.inactiveTranscriptIDs
        let trashedTranscriptIDs = session.trashedTranscriptIDs
        let contexts = Set(session.contexts.map(\.id))
        let facts = Dictionary(session.facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for section in sections {
            for block in section.blocks {
                let key = block.id.uuidString
                if [.speech, .voiceEdit].contains(block.origin) && block.sources.isEmpty {
                    add(key + ":missing", .missingSource, .blocker, "A speech-derived passage has no supporting source.", blockID: block.id)
                }
                if block.origin == .migrated {
                    add(key + ":migration", .migrated, .attention, "This passage came from an older draft. Check its wording and sources.", blockID: block.id)
                }
                for source in block.sources {
                    guard let transcript = transcripts[source.transcriptID] else {
                        add(key + ":absent:" + source.transcriptID.uuidString, .missingSource, .blocker, "A cited transcript is missing.", blockID: block.id)
                        continue
                    }
                    if !Self.isValid(source, in: transcript.text) {
                        add(key + ":invalid:" + source.transcriptID.uuidString, .invalidSource, .blocker, "A source quotation does not match its exact UTF-8 range.", blockID: block.id)
                    } else if inactiveTranscriptIDs.contains(source.transcriptID) {
                        let message = trashedTranscriptIDs.contains(source.transcriptID)
                            ? "This passage cites a recording in Trash. Restore the recording or remove/reconcile this passage before handoff."
                            : "This passage cites an earlier recording version. Select that version or reconcile/remove this passage before handoff."
                        add(key + ":inactive:" + source.transcriptID.uuidString, .staleSource, .blocker, message, blockID: block.id)
                    } else if !currentIDs.contains(source.transcriptID) || !transcript.isComplete {
                        add(key + ":stale:" + source.transcriptID.uuidString, .staleSource, .blocker, "A source was corrected or is incomplete. Reconcile this passage with the current transcript.", blockID: block.id)
                    }
                }
                for id in block.contextIDs where !contexts.contains(id) {
                    add(key + ":context:" + id.uuidString, .missingContext, .blocker, "A referenced file or clipboard snapshot is missing.", blockID: block.id)
                }
                for id in block.factIDs {
                    guard let fact = facts[id] else {
                        add(key + ":fact:" + id.uuidString, .missingFact, .blocker, "A linked fact is missing.", blockID: block.id, factID: id)
                        continue
                    }
                    if fact.status == .superseded {
                        add(key + ":superseded:" + id.uuidString, .superseded, .attention, "This passage includes a superseded decision.", blockID: block.id, factID: id)
                    } else if fact.status != .confirmed && section.kind != .questions {
                        add(key + ":uncertain:" + id.uuidString, .uncertain, .attention, "This passage includes brainstorming or an unresolved interpretation.", blockID: block.id, factID: id)
                    }
                }
                // Literal checks find obvious additions. Passing them does not prove semantic fidelity.
                if block.origin == .speech, !block.sources.isEmpty {
                    let quotes = block.sources.map(\.quote).joined(separator: " ")
                    let unsupported = Self.numericTokens(block.text).subtracting(Self.numericTokens(quotes))
                    if !unsupported.isEmpty {
                        add(key + ":numbers", .unsupportedAddition, .blocker, "Check numbers absent from the cited source: " + unsupported.sorted().joined(separator: ", "), blockID: block.id)
                    }
                }
            }
        }
        let liveFactIDs = Set(blocks.flatMap(\.factIDs))
        for correction in session.facts where correction.status != .superseded && liveFactIDs.contains(correction.id) {
            guard let earlierID = correction.supersedes, liveFactIDs.contains(earlierID),
                  let earlier = facts[earlierID],
                  let earlierBlock = blocks.first(where: { $0.factIDs.contains(earlierID) }) else { continue }
            add("reversal:" + correction.id.uuidString, .superseded, .blocker,
                "Resolve this explicit change of mind: “" + earlier.text + "” → “" + correction.text + "”. Choose which instruction the brief should retain.",
                blockID: earlierBlock.id, factID: correction.id)
        }
        let represented = liveFactIDs.union(removedFactIDs)
        for fact in LedgerValidation.currentFacts(in: session) where fact.status == .confirmed && !represented.contains(fact.id) {
            add("omitted:" + fact.id.uuidString, .omittedFact, .attention, "A confirmed source fact is not included or deliberately removed: " + fact.text, factID: fact.id)
        }
        for take in takes where take.trashedAt == nil && [.recording, .paused, .pending, .failed].contains(take.status) {
            add("take:" + take.id.uuidString, .pendingTake, .blocker, "A recorded take still needs processing, applying, or deliberate dismissal.")
        }
        if pendingProposal != nil {
            add("proposal", .pendingTake, .blocker, "Apply or dismiss the pending changes before finishing the brief.")
        }
        return issues
    }

    static func isValid(_ source: SourceReference, in text: String) -> Bool {
        guard source.startUTF8 >= 0, source.endUTF8 > source.startUTF8, source.endUTF8 <= text.utf8.count else { return false }
        // Compare the original byte slice directly. Copying the whole transcript per citation
        // makes review quadratic in source length and loses the benefit of bounded quotations.
        let bytes = text.utf8
        let start = bytes.index(bytes.startIndex, offsetBy: source.startUTF8)
        let end = bytes.index(start, offsetBy: source.endUTF8 - source.startUTF8)
        return bytes[start..<end].elementsEqual(source.quote.utf8)
    }

    private static let numericTokenExpression = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])\d+(?:[.,]\d+)*(?![\p{L}\p{N}_])"#)

    private static func numericTokens(_ text: String) -> Set<String> {
        return Set(numericTokenExpression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }

    /// Older sessions stay readable without rewriting their immutable transcript or draft history.
    static func migrating(session: VoiceSession) -> BriefDocument {
        if let existing = session.brief { return existing }
        var result = BriefDocument()
        if let draft = session.drafts.last, !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var kind: BriefSectionKind = .changes
            var lines: [String] = []
            func flush() {
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !text.isEmpty, let index = result.sections.firstIndex(where: { $0.kind == kind }) {
                    result.sections[index].blocks.append(BriefBlock(text: text, origin: .migrated))
                }
                lines = []
            }
            var fenced = false
            for (lineIndex, line) in draft.text.components(separatedBy: "\n").enumerated() {
                if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle() }
                if !fenced, line.hasPrefix("## "), let next = BriefSectionKind.matching(String(line.dropFirst(3))) {
                    flush()
                    kind = next
                } else if lineIndex != 0 || !line.hasPrefix("# ") { lines.append(line) }
            }
            flush()
        } else {
            let superseded = Set(session.facts.filter(\.reviewed).compactMap(\.supersedes))
            let current = Set(session.currentTranscripts.map(\.id))
            for fact in session.facts where fact.status != .superseded && !superseded.contains(fact.id) {
                guard fact.sources.allSatisfy({ current.contains($0.transcriptID) }) else { continue }
                let kind: BriefSectionKind = fact.status != .confirmed ? .questions :
                    (fact.kind == .goal ? .goal : fact.kind == .constraint ? .constraints : fact.kind == .question ? .questions : .changes)
                let index = result.sections.firstIndex { $0.kind == kind }!
                result.sections[index].blocks.append(BriefBlock(text: fact.text, origin: .speech, sources: fact.sources, factIDs: [fact.id]))
            }
        }
        return result
    }
}

enum BriefVoiceCommand: Equatable, Sendable { case edits([BriefEdit]), undo, redo }

/// Only call in explicit Edit Brief mode. Material recording is never interpreted as a command.
/// The small grammar executes common edits immediately and refuses to guess an editing target.
enum BriefVoiceParser {
    static func parse(_ text: String, document: BriefDocument, targetSection: BriefSectionKind,
                      selectedBlockIDs: [UUID], sources: [SourceReference] = []) throws -> BriefVoiceCommand {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = command.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if lower == "undo" || lower == "undo that" { return .undo }
        if lower == "redo" || lower == "redo that" { return .redo }
        if let groups = captures(#"^(?:append|add)\s+to\s+(.+?)\s*:\s*([\s\S]+)$"#, command),
           let section = BriefSectionKind.matching(groups[0]) {
            return .edits([.append(section: section, block: BriefBlock(text: groups[1], origin: .voiceEdit, sources: sources))])
        }
        if let groups = captures(#"^(?:append|add)\s*:\s*([\s\S]+)$"#, command) {
            return .edits([.append(section: targetSection, block: BriefBlock(text: groups[0], origin: .voiceEdit, sources: sources))])
        }
        if let groups = captures(#"^(?:replace|change)\s+(.+?)\s+(?:with|to)\s+([\s\S]+)$"#, command) {
            let ids = try targets(groups[0], document: document, targetSection: targetSection, selected: selectedBlockIDs)
            guard ids.count == 1 else { throw BriefDocumentError.ambiguousTarget }
            return .edits([.replace(blockID: ids[0], text: groups[1], origin: .voiceEdit, sources: sources)])
        }
        if let groups = captures(#"^move\s+(.+?)\s+to\s+(.+?)[.!?]?$"#, command),
           let section = BriefSectionKind.matching(groups[1]) {
            let ids = try targets(groups[0], document: document, targetSection: targetSection, selected: selectedBlockIDs)
            return .edits(ids.map { .move(blockID: $0, section: section, index: nil) })
        }
        if let groups = captures(#"^(?:remove|delete)\s+(.+?)[.!?]?$"#, command) {
            let ids = try targets(groups[0], document: document, targetSection: targetSection, selected: selectedBlockIDs)
            return .edits(ids.map { .remove(blockID: $0) })
        }
        throw BriefDocumentError.unsupportedCommand
    }

    private static func targets(_ raw: String, document: BriefDocument, targetSection: BriefSectionKind,
                                selected: [UUID]) throws -> [UUID] {
        let phrase = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["selected", "selection", "the selection", "selected passage", "selected passages", "the selected passage"].contains(phrase) {
            guard !selected.isEmpty, Set(selected).count == selected.count, selected.allSatisfy({ document.block($0) != nil }) else {
                throw BriefDocumentError.ambiguousTarget
            }
            // Stable document order, irrespective of click order.
            let ids = Set(selected)
            return document.blocks.filter { ids.contains($0.id) }.map(\.id)
        }
        guard let groups = captures(#"^(?:the\s+)?(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|[1-9][0-9]?)\s+(.+)$"#, phrase) else {
            throw BriefDocumentError.ambiguousTarget
        }
        let ordinal = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"].firstIndex(of: groups[0]).map { $0 + 1 } ?? Int(groups[0])!
        let noun = groups[1]
        let kind: BriefSectionKind
        if ["passage", "paragraph", "block", "item"].contains(noun) { kind = targetSection }
        else if let named = BriefSectionKind.matching(noun) { kind = named }
        else { throw BriefDocumentError.ambiguousTarget }
        let blocks = document.section(kind).blocks
        guard ordinal > 0, ordinal <= blocks.count else { throw BriefDocumentError.ambiguousTarget }
        return [blocks[ordinal - 1].id]
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
