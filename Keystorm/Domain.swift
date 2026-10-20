import Foundation

enum SessionStatus: String, Codable, Sendable { case ready, recording, paused, interrupted }
enum TimingPrecision: String, Codable, Sendable { case word, window, unavailable }
enum TranscriptOrigin: String, Codable, Sendable { case transcription, imported }
enum FactKind: String, Codable, CaseIterable, Sendable { case goal, requirement, constraint, decision, example, task, question }
enum FactStatus: String, Codable, CaseIterable, Sendable { case confirmed, exploratory, ambiguous, superseded }
enum DetailLevel: String, Codable, CaseIterable, Sendable { case brief, standard, detailed }
enum JobStage: String, Codable, Sendable { case transcription, extraction, composition }
enum JobStatus: String, Codable, Sendable { case pending, running, completed, failed, incomplete, cancelled }

struct AudioSegment: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var intervalID: UUID
    var fileName: String
    var startTime: Double
    var frameCount: Int64
    var sampleRate: Double
    var channelCount: Int
    var sha256: String
    var committedAt = Date()
    var duration: Double { Double(frameCount) / sampleRate }
    var endTime: Double { startTime + duration }
}

struct CaptureInterval: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var startedAt = Date()
    var endedAt: Date?
    var hostTime: UInt64 = 0
    var sampleRate: Double = 0
    var channelCount: Int = 0
}

struct SessionGap: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var startedAt = Date()
    var endedAt: Date?
    var reason: String
    /// Known affected source identities. Absent or empty scopes retain legacy session-wide uncertainty.
    var segmentIDs: [UUID]? = nil
    var intervalIDs: [UUID]? = nil
}

struct SourceReference: Codable, Equatable, Sendable, Identifiable {
    struct ID: Hashable, Sendable {
        let transcriptID: UUID
        let startUTF8: Int
        let endUTF8: Int
    }
    var id: ID { ID(transcriptID: transcriptID, startUTF8: startUTF8, endUTF8: endUTF8) }
    var transcriptID: UUID
    var startUTF8: Int
    var endUTF8: Int
    var quote: String
}

struct TranscriptRevision: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var replacesID: UUID?
    var replacesIDs: [UUID]?
    var rawText: String
    var text: String
    var origin: TranscriptOrigin = .transcription
    var segmentIDs: [UUID] = []
    var startTime: Double = 0
    var endTime: Double = 0
    var timingPrecision: TimingPrecision = .window
    var configurationID: UUID?
    var isComplete = true
    var replacedRevisionIDs: [UUID] {
        var seen = Set<UUID>()
        return ((replacesID.map { [$0] } ?? []) + (replacesIDs ?? [])).filter { seen.insert($0).inserted }
    }
}

struct CorrectionPatch: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var originalRevisionID: UUID
    var correctedRevisionID: UUID
    var before: String
    var after: String
    var dictionaryEntryID: UUID?
}

struct Fact: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var kind: FactKind
    var status: FactStatus = .ambiguous
    var text: String
    var sources: [SourceReference]
    var supersedes: UUID?
    var reviewed = false
}

struct ContextSnapshot: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var title: String
    var content: String
    var sha256: String
    var filePath: String?
}

struct DictionaryEntry: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var canonical: String
    var aliases: [String]
    var explanation: String = ""
    var projectPath: String?
    var automatic = false
}

struct FactDisposition: Codable, Equatable, Sendable {
    var factID: UUID
    var disposition: String
}

struct PromptRevision: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var detail: DetailLevel
    var text: String
    var factIDs: [UUID]
    var transcriptIDs: [UUID]
    var contextIDs: [UUID]
    var dispositions: [FactDisposition]
    var configurationID: UUID?
    var stale = false
    var reviewed = false
}

struct ProcessingConfiguration: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var modelID: String
    var revision: String
    var runtime: String
    var quantization: String
    var thinking = false
    var inputLimit = 4096
    var outputLimit = 2048
    var audioWindowSeconds: Double = 15
    var artifactHashes: [String: String] = [:]
}

struct ProcessingJob: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var stage: JobStage
    var status: JobStatus = .pending
    var inputIDs: [UUID] = []
    var configurationID: UUID?
    var completedUnits = 0
    var totalUnits = 0
    var error: String?
}

struct VoiceSession: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var schemaVersion = 1
    var title = "Untitled session"
    var createdAt = Date()
    var updatedAt = Date()
    var trashedAt: Date?
    var status: SessionStatus = .ready
    var projectPath: String?
    var taskDescription = ""
    var intervals: [CaptureInterval] = []
    var gaps: [SessionGap] = []
    var segments: [AudioSegment] = []
    var unavailableSegmentIDs: [UUID] = []
    var transcripts: [TranscriptRevision] = []
    var corrections: [CorrectionPatch] = []
    var contexts: [ContextSnapshot] = []
    var facts: [Fact] = []
    var drafts: [PromptRevision] = []
    var jobs: [ProcessingJob] = []
    var configurations: [ProcessingConfiguration] = []
    var brief: BriefDocument?
    /// Additive optional metadata: archives created before dictation support decode unchanged.
    var dictation: DictationSession?
    var recordedDuration: Double { segments.map(\.endTime).max() ?? 0 }
    /// Original assets stay in segments; only the selected, non-trashed versions enter inference.
    var inactiveRecordingIntervalIDs: Set<UUID> {
        if trashedAt != nil { return Set(intervals.map(\.id)) }
        var result = Set<UUID>()
        for take in brief?.takes ?? [] {
            let active = take.trashedAt == nil ? Set(take.activeIntervalIDs) : []
            result.formUnion(Set(take.allIntervalIDs).subtracting(active))
        }
        return result
    }
    var trashedIntervalIDs: Set<UUID> {
        if trashedAt != nil { return Set(intervals.map(\.id)) }
        return Set((brief?.takes ?? []).filter { $0.trashedAt != nil }.flatMap(\.allIntervalIDs))
    }
    var activeSegments: [AudioSegment] {
        guard trashedAt == nil else { return [] }
        let inactive = inactiveRecordingIntervalIDs
        return segments.filter { !inactive.contains($0.intervalID) }
    }
    var availableSegments: [AudioSegment] {
        let unavailable = Set(unavailableSegmentIDs)
        return activeSegments.filter { !unavailable.contains($0.id) }.sorted { $0.startTime < $1.startTime }
    }
    /// Cumulative selected audio duration, excluding Trash and earlier audio versions.
    var activeRecordedDuration: Double { activeSegments.reduce(0) { $0 + $1.duration } }
    var activeSavedDuration: Double {
        let unavailable = Set(unavailableSegmentIDs)
        return activeSegments.reduce(0) { $0 + (unavailable.contains($1.id) ? 0 : $1.duration) }
    }
    var activeTranscribedDuration: Double {
        let covered = Set(currentTranscripts.filter(\.isComplete).flatMap(\.segmentIDs))
        let unavailable = Set(unavailableSegmentIDs)
        return activeSegments.reduce(0) { $0 + (covered.contains($1.id) && !unavailable.contains($1.id) ? $1.duration : 0) }
    }
    func takeSegments(_ take: BriefTake) -> [AudioSegment] {
        let intervals = Set(take.activeIntervalIDs)
        return segments.filter { intervals.contains($0.intervalID) }.sorted { $0.startTime < $1.startTime }
    }
    func takeDuration(_ take: BriefTake) -> Double {
        takeSegments(take).reduce(0) { $0 + $1.duration }
    }
    var trashedTranscriptIDs: Set<UUID> {
        if trashedAt != nil { return Set(transcripts.map(\.id)) }
        let direct = Set((brief?.takes ?? []).filter { $0.trashedAt != nil }.flatMap(\.transcriptIDs))
        return excludedTranscriptIDs(intervals: trashedIntervalIDs, direct: direct)
    }
    var inactiveTranscriptIDs: Set<UUID> {
        if trashedAt != nil { return Set(transcripts.map(\.id)) }
        let direct = Set((brief?.takes ?? []).filter { $0.trashedAt != nil }.flatMap(\.transcriptIDs))
        return excludedTranscriptIDs(intervals: inactiveRecordingIntervalIDs, direct: direct)
    }
    var activeTranscriptRevisions: [TranscriptRevision] {
        let inactive = inactiveTranscriptIDs
        return transcripts.filter { !inactive.contains($0.id) }
    }
    /// Propagate removal through correction descendants, including imported text without audio IDs.
    private func excludedTranscriptIDs(intervals: Set<UUID>, direct: Set<UUID>) -> Set<UUID> {
        guard !intervals.isEmpty || !direct.isEmpty else { return [] }
        let segmentIDs = Set(segments.filter { intervals.contains($0.intervalID) }.map(\.id))
        var excluded = direct
        var children = [UUID: [UUID]]()
        for transcript in transcripts {
            if transcript.segmentIDs.contains(where: segmentIDs.contains) { excluded.insert(transcript.id) }
            for parent in transcript.replacedRevisionIDs { children[parent, default: []].append(transcript.id) }
        }
        var queue = Array(excluded)
        var index = 0
        while index < queue.count {
            for child in children[queue[index], default: []] where excluded.insert(child).inserted { queue.append(child) }
            index += 1
        }
        return excluded
    }
    var savedThrough: Double {
        var through = 0.0
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            guard !unavailableSegmentIDs.contains(segment.id), segment.startTime <= through + 0.05 else { break }
            through = segment.endTime
        }
        return through
    }
    var currentTranscripts: [TranscriptRevision] {
        let active = activeTranscriptRevisions
        let replaced = Set(active.flatMap(\.replacedRevisionIDs))
        return active.filter { !replaced.contains($0.id) }.sorted { $0.startTime < $1.startTime }
    }
    var transcribedThrough: Double {
        // Historical original-source prefix; active effective durations are reported separately.
        let replaced = Set(transcripts.flatMap(\.replacedRevisionIDs))
        let covered = Set(transcripts.filter { $0.isComplete && !replaced.contains($0.id) }.flatMap(\.segmentIDs))
        var through = 0.0
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            guard !unavailableSegmentIDs.contains(segment.id), covered.contains(segment.id), segment.startTime <= through + 0.05 else { break }
            through = segment.endTime
        }
        return through
    }
    /// Materialize only known legacy interval boundaries; pause/resume grouping cannot be inferred.
    @discardableResult
    mutating func materializeLegacyRecordings() -> Bool {
        var changed = brief == nil
        var document = BriefDocument.migrating(session: self)
        let ownedIntervals = Set(document.takes.flatMap(\.allIntervalIDs))
        let intervalSegments = Dictionary(grouping: segments, by: \.intervalID)
        let unowned = intervals.filter { !ownedIntervals.contains($0.id) && !(intervalSegments[$0.id] ?? []).isEmpty }
        guard !unowned.isEmpty else {
            if changed { brief = document }
            return changed
        }
        let segmentIntervals = Dictionary(segments.map { ($0.id, $0.intervalID) }, uniquingKeysWith: { first, _ in first })
        var transcriptIntervals = [UUID: Set<UUID>]()
        var transcriptIDsByInterval = [UUID: [UUID]]()
        for transcript in transcripts {
            let associated = Set(transcript.segmentIDs.compactMap { segmentIntervals[$0] })
            transcriptIntervals[transcript.id] = associated
            for interval in associated { transcriptIDsByInterval[interval, default: []].append(transcript.id) }
        }
        let current = currentTranscripts
        let covered = Set(current.filter(\.isComplete).flatMap(\.segmentIDs))
        var factsByInterval = [UUID: Set<UUID>]()
        for fact in LedgerValidation.currentFacts(in: self) {
            let associated = fact.sources.reduce(into: Set<UUID>()) { $0.formUnion(transcriptIntervals[$1.transcriptID] ?? []) }
            for interval in associated { factsByInterval[interval, default: []].insert(fact.id) }
        }
        let represented = Set(document.blocks.flatMap(\.factIDs)).union(document.removedFactIDs)
        var takeIDs = Set(document.takes.map(\.id))
        for interval in unowned {
            var id = interval.id
            while !takeIDs.insert(id).inserted { id = UUID() }
            let relevantFacts = factsByInterval[interval.id] ?? []
            let audioIDs = Set((intervalSegments[interval.id] ?? []).map(\.id))
            // A legacy draft alone cannot establish which source material it preserved.
            let representedCompleteSource = !relevantFacts.isEmpty && relevantFacts.isSubset(of: represented) && audioIDs.isSubset(of: covered)
            document.takes.append(BriefTake(id: id, intervalID: interval.id, expectedRevision: document.revisionID,
                status: representedCompleteSource ? .applied : .pending,
                transcriptIDs: transcriptIDsByInterval[interval.id] ?? [], createdAt: interval.startedAt))
            changed = true
        }
        brief = document
        return changed
    }

    mutating func invalidateDerivedWork() {
        for index in drafts.indices { drafts[index].stale = true }
        facts = facts.map { var fact = $0; fact.reviewed = false; return fact }
        updatedAt = Date()
    }
}

enum KeystormError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}
