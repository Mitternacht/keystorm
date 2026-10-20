import Foundation

/// Persisted intent and results for dictation. Audio remains owned by the existing take archive.
struct DictationSession: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var recordings: [DictationRecordingMetadata] = []
}

enum DictationLanguagePolicy: String, Codable, CaseIterable, Sendable {
    /// Preserve English/German code switching rather than translate into one language.
    case mixedEnglishGerman
    case automatic
}

enum DictationOutputMode: String, Codable, CaseIterable, Sendable {
    case verbatim, clean, summarize, organize
    /// Clean plus email paragraphing; available before recording and as a preview.
    case email
    /// Explicit preview-only translations. The target is part of the persisted mode.
    case translateEnglish, translateGerman

    var displayTitle: String {
        switch self {
        case .verbatim: String(localized: "Verbatim")
        case .clean: String(localized: "Clean")
        case .summarize: String(localized: "Summarize")
        case .organize: String(localized: "Organize")
        case .email: String(localized: "Email")
        case .translateEnglish: String(localized: "English translation")
        case .translateGerman: String(localized: "German translation")
        }
    }
}

enum DictationRecordingPurpose: String, Codable, Sendable {
    case quick, longRecording
}

enum DictationRecordingState: String, Codable, Sendable {
    case recording, paused, captured, processing, ready, failed, cancelled
}

struct DictationTextRevision: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var rawText: String
    var text: String
    var sourceTranscriptIDs: [UUID]
    var appliedLearnedTermIDs: [UUID]?
    var createdAt = Date()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.rawText.utf8.elementsEqual(rhs.rawText.utf8) &&
        lhs.text.utf8.elementsEqual(rhs.text.utf8) && lhs.sourceTranscriptIDs == rhs.sourceTranscriptIDs &&
        lhs.appliedLearnedTermIDs == rhs.appliedLearnedTermIDs &&
        lhs.createdAt == rhs.createdAt
    }
}

enum DictationDeliveryState: String, Codable, Sendable {
    case pending, inserted, copied, failed, uncertain, targetChanged
    /// Paste fallback: one Command-V was sent and the staged text was read. Not a verified insertion.
    case pasted
}

/// A durable delivery receipt stores no accessibility objects or cross-process references.
struct DictationDelivery: Codable, Equatable, Sendable {
    var requestID: UUID
    var textRevisionID: UUID?
    var targetLabel: String
    var state: DictationDeliveryState = .pending
    var detail: String?
    var updatedAt = Date()
}

/// Append-only output provenance. An entry's identity is the identity of its text snapshot.
struct DictationOutputRevision: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let parentOutputID: UUID?
    let textRevision: DictationTextRevision
    let mode: DictationOutputMode
    let sourceRevisionID: UUID?
    let sourceSHA256: String?
    let configurationID: UUID?
    let promptTemplateVersion: Int?
    let promptTemplateSHA256: String?
    let contextSHA256: String?
    let contextProfile: DictationContextProfile?
    let contextAvailability: DictationContextAvailability?
    let longTransform: LongDictationTransformResult?
    let createdAt: Date

    init(id: UUID? = nil, parentOutputID: UUID? = nil, textRevision: DictationTextRevision,
         mode: DictationOutputMode, sourceRevisionID: UUID? = nil, sourceSHA256: String? = nil,
         configurationID: UUID? = nil, promptTemplateVersion: Int? = nil,
         promptTemplateSHA256: String? = nil, contextSHA256: String? = nil,
         contextProfile: DictationContextProfile? = nil, contextAvailability: DictationContextAvailability? = nil,
         longTransform: LongDictationTransformResult? = nil, createdAt: Date? = nil) {
        self.id = id ?? textRevision.id
        self.parentOutputID = parentOutputID
        self.textRevision = textRevision
        self.mode = mode
        self.sourceRevisionID = sourceRevisionID
        self.sourceSHA256 = sourceSHA256
        self.configurationID = configurationID
        self.promptTemplateVersion = promptTemplateVersion
        self.promptTemplateSHA256 = promptTemplateSHA256
        self.contextSHA256 = contextSHA256
        self.contextProfile = contextProfile
        self.contextAvailability = contextAvailability
        self.longTransform = longTransform
        self.createdAt = createdAt ?? textRevision.createdAt
    }
}

struct DictationRecordingMetadata: Identifiable, Codable, Equatable, Sendable {
    /// This is the existing BriefTake.id, never a second recording identity.
    var id: UUID
    var state: DictationRecordingState = .captured
    var languagePolicy: DictationLanguagePolicy = .mixedEnglishGerman
    var outputMode: DictationOutputMode = .verbatim
    /// Nil preserves Verbatim semantics for recordings created before Quick Clean.
    var captureMode: DictationQuickMode?
    var purpose: DictationRecordingPurpose?
    var captureAppBundleID: String?
    var textRevision: DictationTextRevision?
    /// Optional so older archives retain their existing representation until transformed.
    var outputHistory: [DictationOutputRevision]?
    var activeOutputID: UUID?
    var delivery: DictationDelivery?
    var failureMessage: String?
    var createdAt = Date()
    var updatedAt = Date()
}

/// An immutable view of one archived take. It is intentionally not Codable: persisting it
/// would introduce a second mutable authority for audio ownership and version selection.
struct Recording: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date
    let trashedAt: Date?
    let legacyStatus: BriefTakeStatus
    let captureIntervalIDs: [UUID]
    let activeIntervalIDs: [UUID]
    let allIntervalIDs: [UUID]
    let audioRevisions: [RecordingAudioRevision]
    let activeAudioRevisionID: UUID?
    let transcriptIDs: [UUID]
    let dictation: DictationRecordingMetadata?

    var state: DictationRecordingState {
        switch legacyStatus {
        case .recording: .recording
        case .paused: .paused
        case .failed: .failed
        case .discarded, .dismissed: .cancelled
        case .pending, .applied: dictation?.state ?? .captured
        }
    }
}

extension VoiceSession {
    /// No migration or mutation is required to browse an existing brief's recordings.
    var recordings: [Recording] {
        let metadata = Dictionary((dictation?.recordings ?? []).map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        return (brief?.takes ?? []).map { take in
            Recording(id: take.id, name: take.displayName, createdAt: take.createdAt,
                      trashedAt: trashedAt ?? take.trashedAt, legacyStatus: take.status,
                      captureIntervalIDs: take.captureIntervalIDs,
                      activeIntervalIDs: take.activeIntervalIDs, allIntervalIDs: take.allIntervalIDs,
                      audioRevisions: take.audioRevisions ?? [],
                      activeAudioRevisionID: take.activeAudioRevisionID,
                      transcriptIDs: take.transcriptIDs, dictation: metadata[take.id])
        }
    }

    /// Explicit, additive compatibility extraction. It never rekeys takes, moves intervals,
    /// changes selected versions, rewrites transcripts, or synthesizes audio ownership.
    /// Existing metadata is left intact so capture/output transitions remain caller-controlled.
    @discardableResult
    mutating func materializeDictationMetadata() -> Bool {
        var changed = dictation == nil
        var metadata = dictation ?? DictationSession()
        var known = Set(metadata.recordings.map(\.id))
        let complete = currentTranscripts.filter(\.isComplete)
        let completeAudio = Set(complete.flatMap(\.segmentIDs))
        for take in brief?.takes ?? [] where known.insert(take.id).inserted {
            let state: DictationRecordingState
            switch take.status {
            case .recording: state = .recording
            case .paused: state = .paused
            case .failed: state = .failed
            case .discarded, .dismissed: state = .cancelled
            case .pending, .applied:
                let audio = takeSegments(take)
                let hasCompleteText = complete.contains { take.transcriptIDs.contains($0.id) }
                let completeSource = audio.isEmpty ? hasCompleteText : Set(audio.map(\.id)).isSubset(of: completeAudio)
                state = completeSource ? .ready : .captured
            }
            metadata.recordings.append(DictationRecordingMetadata(id: take.id, state: state,
                createdAt: take.createdAt, updatedAt: take.createdAt))
            changed = true
        }
        if changed { dictation = metadata }
        return changed
    }

    mutating func invalidateDictationOutput(takeID: UUID) throws {
        guard let index = dictation?.recordings.firstIndex(where: { $0.id == takeID }) else { return }
        try dictation?.recordings[index].invalidateAudioSelection()
    }

    /// Additive metadata validation is separate from the legacy document's source invariants.
    func validateDictationMetadata() throws {
        guard let dictation else { return }
        let takes = Set((brief?.takes ?? []).map(\.id))
        let transcripts = Set(transcripts.map(\.id))
        guard dictation.schemaVersion == 1,
              dictation.recordings.count <= 10_000,
              Set(dictation.recordings.map(\.id)).count == dictation.recordings.count,
              Set(dictation.recordings.map(\.id)).isSubset(of: takes) else {
            throw KeystormError.message("Dictation metadata has invalid recording identities or an unsupported version.")
        }
        for recording in dictation.recordings {
            try recording.validateOutputHistory()
            for output in recording.outputHistory ?? [] {
                guard Set(output.textRevision.sourceTranscriptIDs).isSubset(of: transcripts) else {
                    throw DictationTransformError.invalidHistory
                }
            }
            guard recording.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  recording.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  (recording.failureMessage?.utf8.count ?? 0) <= 16_384,
                  recording.captureAppBundleID.map({ !$0.isEmpty && $0.utf8.count <= 256 &&
                      $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) ||
                          (48...57).contains($0) || $0 == 46 || $0 == 45 } }) ?? true else {
                throw KeystormError.message("A dictation recording has invalid timestamps or failure details.")
            }
            if let revision = recording.textRevision {
                guard revision.createdAt.timeIntervalSinceReferenceDate.isFinite,
                      revision.rawText.utf8.count <= 8_000_000, revision.text.utf8.count <= 8_000_000,
                      revision.sourceTranscriptIDs.count <= 100_000,
                      DictationRecordingMetadata.hasValidLearnedTermIDs(revision),
                      Set(revision.sourceTranscriptIDs).count == revision.sourceTranscriptIDs.count,
                      Set(revision.sourceTranscriptIDs).isSubset(of: transcripts) else {
                    throw KeystormError.message("A dictation text revision has invalid source references or exceeds the text limit.")
                }
            }
            if let delivery = recording.delivery {
                guard delivery.targetLabel.utf8.count <= 16_384,
                      (delivery.detail?.utf8.count ?? 0) <= 16_384,
                      delivery.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
                    throw KeystormError.message("A dictation delivery receipt has invalid target details.")
                }
            }
        }
    }
}

extension DictationRecordingMetadata {
    static let maximumOutputHistoryCount = 128
    static let maximumOutputHistoryBytes = 2 * 1_024 * 1_024

    /// A qualified learned spelling is a separate recoverable output, never a rewrite of ASR.
    mutating func stageLearnedCorrection(source: DictationTextRevision, application: LearnedTermApplication) throws {
        guard textRevision == source, !application.termIDs.isEmpty,
              Set(application.termIDs).count == application.termIDs.count,
              application.termIDs.count <= 64, application.text.utf8.count <= 8_000_000,
              !application.text.utf8.elementsEqual(source.text.utf8) else {
            throw DictationTransformError.staleSource
        }
        var next = self
        var history = outputHistory ?? []
        try next.checkpoint(source, in: &history)
        let corrected = DictationTextRevision(rawText: source.rawText, text: application.text,
            sourceTranscriptIDs: source.sourceTranscriptIDs, appliedLearnedTermIDs: application.termIDs)
        history.append(DictationOutputRevision(parentOutputID: source.id, textRevision: corrected, mode: .verbatim))
        next.outputHistory = history
        next.textRevision = corrected
        next.activeOutputID = corrected.id
        next.outputMode = .verbatim
        next.delivery = nil
        next.updatedAt = Date()
        try next.validateOutputHistory()
        self = next
    }

    /// Apply only the exact source the job saw. The caller still presents the draft for review;
    /// this operation never delivers text to another app.
    mutating func stageTransform(source: DictationTextRevision, result: DictationTransformResult,
                                 context: DictationContextSnapshot? = nil) throws {
        try context?.validate()
        try validateOutputHistory()
        guard result.sourceRevisionID == source.id,
              result.sourceSHA256 == DictationTransformPolicy.sourceDigest(source.text),
              result.promptTemplateVersion == DictationTransformPolicy.templateVersion,
              result.promptTemplateSHA256 == DictationTransformPolicy.promptTemplateSHA256(for: result.mode, context: context),
              result.contextSHA256 == context?.digest,
              result.generatedTokens >= (result.mode == .verbatim ? 0 : 1),
              result.generatedTokens <= DictationTransformPolicy.maxGeneratedTokens else {
            throw DictationTransformError.mismatchedResult
        }
        try DictationTransformPolicy.validateText(result.text, source: source.text, mode: result.mode)
        let existing = outputHistory?.first { $0.id == result.jobID }
        if let existing {
            guard existing.sourceRevisionID == source.id,
                  existing.sourceSHA256 == result.sourceSHA256, existing.mode == result.mode,
                  existing.configurationID == result.configurationID,
                  existing.promptTemplateVersion == result.promptTemplateVersion,
                  existing.promptTemplateSHA256 == result.promptTemplateSHA256,
                  existing.contextSHA256 == result.contextSHA256,
                  existing.contextProfile == context?.profile,
                  existing.contextAvailability == context?.availability,
                  existing.textRevision.text.utf8.elementsEqual(result.text.utf8),
                  existing.textRevision.rawText.utf8.elementsEqual(source.rawText.utf8),
                  existing.textRevision.sourceTranscriptIDs == source.sourceTranscriptIDs,
                  existing.textRevision.appliedLearnedTermIDs == source.appliedLearnedTermIDs else {
                throw DictationTransformError.mismatchedResult
            }
            if activeOutputID == existing.id,
               textRevision.map({ Self.sameTextRevision($0, existing.textRevision) }) == true { return }
        }
        guard let current = textRevision, Self.sameTextRevision(current, source),
              result.jobID != source.id else { throw DictationTransformError.staleSource }
        var next = self
        var history = outputHistory ?? []
        try next.checkpoint(current, in: &history)
        let output = existing ?? DictationOutputRevision(parentOutputID: source.id,
            textRevision: DictationTextRevision(id: result.jobID, rawText: source.rawText, text: result.text,
                sourceTranscriptIDs: source.sourceTranscriptIDs, appliedLearnedTermIDs: source.appliedLearnedTermIDs),
            mode: result.mode, sourceRevisionID: source.id, sourceSHA256: result.sourceSHA256,
            configurationID: result.configurationID, promptTemplateVersion: result.promptTemplateVersion,
            promptTemplateSHA256: result.promptTemplateSHA256, contextSHA256: result.contextSHA256,
            contextProfile: context?.profile, contextAvailability: context?.availability)
        if existing == nil { history.append(output) }
        next.outputHistory = history
        next.activeOutputID = output.id
        next.textRevision = output.textRevision
        next.outputMode = output.mode
        next.delivery = nil
        next.updatedAt = Date()
        try next.validateOutputHistory()
        self = next
    }

    /// A long preview retains per-section ranges and generation provenance beside its saved output.
    mutating func stageLongTransform(source: DictationTextRevision, result: LongDictationTransformResult) throws {
        try validateOutputHistory()
        try LongDictationTransformService.validate(result, source: source, configuration: result.plan.configuration)
        guard result.jobID != source.id, let first = result.outputs.first else { throw LongDictationTransformError.invalidResult }
        let existing = outputHistory?.first { $0.id == result.jobID }
        if let existing {
            guard existing.longTransform == result, existing.parentOutputID == source.id,
                  existing.sourceRevisionID == source.id, existing.sourceSHA256 == result.sourceSHA256,
                  existing.textRevision.rawText.utf8.elementsEqual(source.rawText.utf8),
                  existing.textRevision.sourceTranscriptIDs == source.sourceTranscriptIDs,
                  existing.textRevision.appliedLearnedTermIDs == source.appliedLearnedTermIDs else {
                throw DictationTransformError.mismatchedResult
            }
            if activeOutputID == existing.id, textRevision == existing.textRevision { return }
        }
        guard textRevision == source else { throw DictationTransformError.staleSource }
        var next = self
        var history = outputHistory ?? []
        try next.checkpoint(source, in: &history)
        let output = existing ?? DictationOutputRevision(parentOutputID: source.id,
            textRevision: DictationTextRevision(id: result.jobID, rawText: source.rawText, text: result.text,
                sourceTranscriptIDs: source.sourceTranscriptIDs, appliedLearnedTermIDs: source.appliedLearnedTermIDs),
            mode: result.mode, sourceRevisionID: source.id, sourceSHA256: result.sourceSHA256,
            configurationID: result.configurationID, promptTemplateVersion: first.promptTemplateVersion,
            promptTemplateSHA256: first.promptTemplateSHA256, longTransform: result)
        if existing == nil { history.append(output) }
        let text = output.textRevision
        next.outputHistory = history
        next.activeOutputID = text.id
        next.textRevision = text
        next.outputMode = result.mode
        next.delivery = nil
        next.updatedAt = Date()
        try next.validateOutputHistory()
        self = next
    }

    /// Reject obviously full history before spending time on a long model job.
    func preflightLongTransformHistory(source: DictationTextRevision, plan: LongDictationTransformPlan? = nil) throws {
        guard textRevision == source else { throw DictationTransformError.staleSource }
        var history = outputHistory ?? []
        try checkpoint(source, in: &history)
        guard history.count < Self.maximumOutputHistoryCount,
              try JSONEncoder().encode(history).count + source.rawText.utf8.count < Self.maximumOutputHistoryBytes else {
            throw DictationTransformError.historyLimit
        }
        if let plan {
            guard plan.sourceRevisionID == source.id,
                  plan.sourceSHA256 == DictationTransformPolicy.sourceDigest(source.text),
                  !plan.chunks.isEmpty, plan.chunks.count <= LongDictationTransformService.maximumChunks else {
                throw LongDictationTransformError.invalidResult
            }
            // Empty section text gives a strict storage lower bound. It is never a model
            // result or a persisted output; actual Apply still checks exact encoded bytes.
            let receipts = plan.chunks.map { chunk in
                DictationTransformResult(jobID: UUID(), sourceRevisionID: source.id,
                    sourceSHA256: chunk.sourceSHA256, mode: plan.mode, text: "", generatedTokens: 1,
                    configurationID: plan.configuration.id,
                    promptTemplateVersion: DictationTransformPolicy.templateVersion,
                    promptTemplateSHA256: DictationTransformPolicy.promptTemplateSHA256(for: plan.mode))
            }
            let minimum = LongDictationTransformResult(plan: plan, outputs: receipts, generatedTokens: receipts.count)
            let revision = DictationTextRevision(id: minimum.jobID, rawText: source.rawText, text: minimum.text,
                sourceTranscriptIDs: source.sourceTranscriptIDs, appliedLearnedTermIDs: source.appliedLearnedTermIDs,
                createdAt: Date(timeIntervalSinceReferenceDate: 0))
            history.append(DictationOutputRevision(parentOutputID: source.id, textRevision: revision, mode: plan.mode,
                sourceRevisionID: source.id, sourceSHA256: plan.sourceSHA256,
                configurationID: plan.configuration.id, promptTemplateVersion: DictationTransformPolicy.templateVersion,
                promptTemplateSHA256: DictationTransformPolicy.promptTemplateSHA256(for: plan.mode), longTransform: minimum))
            guard try JSONEncoder().encode(history).count <= Self.maximumOutputHistoryBytes else {
                throw DictationTransformError.historyLimit
            }
        }
    }

    /// Restoring a saved version first checkpoints unsnapshotted manual edits.
    mutating func selectOutput(id: UUID) throws {
        try validateOutputHistory()
        guard let output = outputHistory?.first(where: { $0.id == id }) else {
            throw DictationTransformError.missingOutput
        }
        if activeOutputID == id,
           textRevision.map({ Self.sameTextRevision($0, output.textRevision) }) == true { return }
        var next = self
        var history = outputHistory ?? []
        if let current = textRevision { try next.checkpoint(current, in: &history) }
        next.outputHistory = history
        next.activeOutputID = output.id
        next.textRevision = output.textRevision
        next.outputMode = output.mode
        next.delivery = nil
        next.updatedAt = Date()
        try next.validateOutputHistory()
        self = next
    }

    /// SessionStore additionally validates each snapshot's transcript IDs against the archive.
    func validateOutputHistory() throws {
        if let textRevision, !Self.hasValidLearnedTermIDs(textRevision) {
            throw DictationTransformError.invalidHistory
        }
        guard let history = outputHistory else {
            guard activeOutputID == nil else { throw DictationTransformError.invalidHistory }
            return
        }
        guard history.count <= Self.maximumOutputHistoryCount else { throw DictationTransformError.historyLimit }
        var earlier = [UUID: DictationOutputRevision]()
        for output in history {
            let revision = output.textRevision
            guard earlier[output.id] == nil, output.id == revision.id,
                  output.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  revision.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  revision.rawText.utf8.count <= 8_000_000, revision.text.utf8.count <= 8_000_000,
                  revision.sourceTranscriptIDs.count <= 100_000,
                  Self.hasValidLearnedTermIDs(revision),
                  Set(revision.sourceTranscriptIDs).count == revision.sourceTranscriptIDs.count,
                  output.parentOutputID.map({ earlier[$0] != nil }) ?? true else {
                throw DictationTransformError.invalidHistory
            }
            if let digest = output.contextSHA256 {
                guard DictationTransformPolicy.hasValidDigestFormat(digest), output.contextProfile != nil,
                      output.contextAvailability != nil, output.sourceRevisionID != nil else {
                    throw DictationTransformError.invalidHistory
                }
            } else if output.contextProfile != nil || output.contextAvailability != nil {
                throw DictationTransformError.invalidHistory
            }
            if let sourceID = output.sourceRevisionID {
                guard let source = earlier[sourceID],
                      output.parentOutputID == sourceID,
                      output.sourceSHA256 == DictationTransformPolicy.sourceDigest(source.textRevision.text),
                      output.configurationID != nil,
                      let templateVersion = output.promptTemplateVersion,
                      let templateHash = output.promptTemplateSHA256,
                      templateVersion > 0, DictationTransformPolicy.hasValidDigestFormat(templateHash),
                      revision.rawText.utf8.elementsEqual(source.textRevision.rawText.utf8),
                      revision.sourceTranscriptIDs == source.textRevision.sourceTranscriptIDs,
                      revision.appliedLearnedTermIDs == source.textRevision.appliedLearnedTermIDs else {
                    throw DictationTransformError.invalidHistory
                }
            } else {
                guard output.sourceSHA256 == nil, output.configurationID == nil,
                      output.promptTemplateVersion == nil, output.promptTemplateSHA256 == nil else {
                    throw DictationTransformError.invalidHistory
                }
            }
            if let result = output.longTransform {
                guard let sourceID = output.sourceRevisionID, let source = earlier[sourceID],
                      result.jobID == output.id, result.mode == output.mode,
                      result.configurationID == output.configurationID,
                      result.outputs.first?.promptTemplateVersion == output.promptTemplateVersion,
                      result.outputs.first?.promptTemplateSHA256 == output.promptTemplateSHA256,
                      output.contextSHA256 == nil,
                      result.text.utf8.elementsEqual(revision.text.utf8) else {
                    throw DictationTransformError.invalidHistory
                }
                try LongDictationTransformService.validateHistorical(result, source: source.textRevision)
            }
            earlier[output.id] = output
        }
        if let current = textRevision, let historical = earlier[current.id] {
            guard Self.sameTextRevision(current, historical.textRevision) else {
                throw DictationTransformError.invalidHistory
            }
        }
        if let activeOutputID {
            guard let active = earlier[activeOutputID], let current = textRevision,
                  Self.sameTextRevision(current, active.textRevision), outputMode == active.mode else {
                throw DictationTransformError.invalidHistory
            }
        }
        guard try JSONEncoder().encode(history).count <= Self.maximumOutputHistoryBytes else {
            throw DictationTransformError.historyLimit
        }
    }

    private func checkpoint(_ current: DictationTextRevision,
                            in history: inout [DictationOutputRevision]) throws {
        if let existing = history.first(where: { $0.id == current.id }) {
            guard Self.sameTextRevision(current, existing.textRevision) else {
                throw DictationTransformError.invalidHistory
            }
            return
        }
        let raw = history.first {
            $0.sourceRevisionID == nil &&
            $0.textRevision.text.utf8.elementsEqual(current.rawText.utf8) &&
            $0.textRevision.rawText.utf8.elementsEqual(current.rawText.utf8) &&
            $0.textRevision.sourceTranscriptIDs == current.sourceTranscriptIDs
        }
        var rawID = raw?.id
        if rawID == nil, !current.text.utf8.elementsEqual(current.rawText.utf8) {
            var id = UUID()
            while history.contains(where: { $0.id == id }) || id == current.id { id = UUID() }
            let original = DictationTextRevision(id: id, rawText: current.rawText, text: current.rawText,
                sourceTranscriptIDs: current.sourceTranscriptIDs, createdAt: current.createdAt)
            history.append(DictationOutputRevision(textRevision: original, mode: .verbatim))
            rawID = original.id
        }
        // A manual edit has no model provenance. Do not infer a model parent from recency.
        history.append(DictationOutputRevision(parentOutputID: rawID,
            textRevision: current, mode: .verbatim))
    }

    static func hasValidLearnedTermIDs(_ revision: DictationTextRevision) -> Bool {
        guard let ids = revision.appliedLearnedTermIDs else { return true }
        return !ids.isEmpty && ids.count <= 64 && Set(ids).count == ids.count
    }

    mutating func checkpointCurrentOutput() throws {
        var next = self
        var history = outputHistory ?? []
        if let current = textRevision { try next.checkpoint(current, in: &history) }
        next.outputHistory = history.isEmpty ? nil : history
        next.delivery = nil
        try next.validateOutputHistory()
        self = next
    }

    /// Audio changes retain old outputs for inspection, but none remains the current transcript.
    mutating func invalidateAudioSelection() throws {
        var next = self
        var history = outputHistory ?? []
        if let current = textRevision { try next.checkpoint(current, in: &history) }
        next.outputHistory = history.isEmpty ? nil : history
        next.textRevision = nil
        next.activeOutputID = nil
        next.delivery = nil
        next.outputMode = .verbatim
        next.state = .captured
        next.failureMessage = nil
        next.updatedAt = Date()
        try next.validateOutputHistory()
        self = next
    }

    private static func sameTextRevision(_ lhs: DictationTextRevision, _ rhs: DictationTextRevision) -> Bool {
        lhs.id == rhs.id && lhs.rawText.utf8.elementsEqual(rhs.rawText.utf8) &&
        lhs.text.utf8.elementsEqual(rhs.text.utf8) && lhs.sourceTranscriptIDs == rhs.sourceTranscriptIDs &&
        lhs.appliedLearnedTermIDs == rhs.appliedLearnedTermIDs &&
        lhs.createdAt == rhs.createdAt
    }
}
