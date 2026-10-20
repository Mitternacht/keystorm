import Darwin
import Foundation
import Observation

struct CorrectionClassificationReceipt: Codable, Equatable, Sendable {
    var request: CorrectionClassificationRequest
    var result: CorrectionClassificationResult
}

enum LearnedTermStatus: String, Codable, Sendable {
    case pending, review, learned, approved, disabled
    var title: String {
        switch self {
        case .pending: String(localized: "Waiting for local AI")
        case .review: String(localized: "Review")
        case .learned: String(localized: "Needs approval")
        case .approved: String(localized: "Approved")
        case .disabled: String(localized: "Disabled")
        }
    }
}

struct LearnedTerm: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var variant: String
    var canonical: String
    var appBundleID: String?
    var status: LearnedTermStatus = .pending
    var evidenceIDs: [UUID]
    var positiveSessionCount = 0
    var negativeCount = 0
    var reversalEventIDs: [UUID]?
    var hasRejectedAppliedCorrection: Bool?
    var lexicalReviewReason: CorrectionLexicalVerdict?
    var language: CorrectionLanguage = .unknown
    var updatedAt = Date()

    var whyLearned: String {
        switch status {
        case .learned:
            String(localized: "Historical spelling evidence is available. Approve this exact correction before future use.")
        case .approved: String(localized: "You approved this exact observed correction.")
        case .disabled: String(localized: "You disabled this term or corrected a spelling it applied. It is excluded from future recognition corrections.")
        case .pending: String(localized: "A correction candidate was saved. Local classification is pending; approval is required before future use.")
        case .review:
            if lexicalReviewReason == .knownSourceWord {
                String(localized: "The original spelling appears in the local word list. Review this change before it is used.")
            } else if lexicalReviewReason == .unavailable {
                String(localized: "The local word list could not be verified. Review this correction before it is used.")
            } else {
                negativeCount > 0
                    ? String(localized: "The evidence includes a wording change, an uncertain decision, or conflicting language evidence. Review before using it.")
                    : String(localized: "Spelling evidence is available for review. Approve this exact correction before future use; repeated evidence does not enable it.")
            }
        }
    }
}

struct LearnedTermSuggestion: Identifiable, Equatable, Sendable {
    var id: UUID
    var variant: String
    var canonical: String
    var appBundleID: String?
    var language: CorrectionLanguage
    /// Only context-qualified retrieval supplies ownership for automatic application.
    var sourceSHA256: String?
    var qualifiedSpans: [LearnedTermSpan]?
}

struct LearningEvidenceRecord: Codable, Equatable, Sendable {
    var evidence: CorrectionEvidence
    var receipt: CorrectionClassificationReceipt?
}

struct LearningDictionarySnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    /// nil identifies the original confidence-gated policy, kept readable for migration.
    var automaticPolicyVersion: Int? = CorrectionLearningPolicy.automaticPolicyVersion
    var isEnabled = false
    var externalCorrectionsEnabled = false
    var evidence: [LearningEvidenceRecord] = []
    var terms: [LearnedTerm] = []
    /// Event identities only. Forgotten spellings, context and hashes are removed.
    var tombstones: [UUID] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, automaticPolicyVersion, isEnabled, externalCorrectionsEnabled, evidence, terms, tombstones
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        automaticPolicyVersion = try container.decodeIfPresent(Int.self, forKey: .automaticPolicyVersion)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        externalCorrectionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .externalCorrectionsEnabled) ?? false
        evidence = try container.decode([LearningEvidenceRecord].self, forKey: .evidence)
        terms = try container.decode([LearnedTerm].self, forKey: .terms)
        tombstones = try container.decode([UUID].self, forKey: .tombstones)
    }
}

/// One writer, a separate file, and publication only after the fsynced replacement.
/// This never modifies the existing manually maintained terminology dictionary.
actor LearningRepository {
    static let maxEvidence = 2_048
    static let maxTerms = 256
    static let maxTombstones = 8_192
    static let maxFileBytes = 2 * 1_024 * 1_024

    private let url: URL
    private let write: @Sendable (Data, URL) throws -> Void
    private let lexicalAssessor: any CorrectionLexicalAssessing
    private var value: LearningDictionarySnapshot
    private var consentGeneration: UInt64 = 0

    init(url: URL? = nil, writer: (@Sendable (Data, URL) throws -> Void)? = nil,
         lexicalAssessor: any CorrectionLexicalAssessing = BundledCorrectionLexicon.shared) throws {
        self.url = try url ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Keystorm/Learning/dictionary-v1.json")
        self.write = writer ?? Self.atomicWrite
        self.lexicalAssessor = lexicalAssessor
        if FileManager.default.fileExists(atPath: self.url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: self.url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maxFileBytes,
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                throw CorrectionLearningError.unsupportedStore
            }
            let data = try Data(contentsOf: self.url)
            var decoded = try JSONDecoder().decode(LearningDictionarySnapshot.self, from: data)
            let storedPolicy = decoded.automaticPolicyVersion ?? 1
            guard (1...CorrectionLearningPolicy.automaticPolicyVersion).contains(storedPolicy) else {
                throw CorrectionLearningError.unsupportedStore
            }
            // Validate each former policy's derived state before conservatively
            // migrating it; immutable historical receipts are never rewritten.
            try Self.validate(decoded, policyVersion: storedPolicy)
            if storedPolicy != CorrectionLearningPolicy.automaticPolicyVersion {
                decoded.automaticPolicyVersion = CorrectionLearningPolicy.automaticPolicyVersion
                Self.recompute(&decoded)
                try Self.validate(decoded)
            }
            self.value = decoded
        } else {
            self.value = LearningDictionarySnapshot()
        }
    }

    func snapshot() -> LearningDictionarySnapshot { value }

    func setEnabled(_ enabled: Bool) throws {
        var next = value
        next.isEnabled = enabled
        try publish(next)
        consentGeneration &+= 1
    }

    func setExternalCorrectionsEnabled(_ enabled: Bool) throws {
        var next = value
        next.externalCorrectionsEnabled = enabled
        try publish(next)
        consentGeneration &+= 1
    }

    func classificationConsent(for evidence: CorrectionEvidence) -> UInt64? {
        guard value.isEnabled,
              evidence.origin == nil || value.externalCorrectionsEnabled else { return nil }
        return consentGeneration
    }

    @discardableResult
    func enqueue(_ evidence: CorrectionEvidence, consentGeneration expectedGeneration: UInt64? = nil) throws -> Bool {
        guard !Task.isCancelled, value.isEnabled, evidence.origin == nil ||
            (value.externalCorrectionsEnabled && expectedGeneration == consentGeneration) else { return false }
        try CorrectionLearningPolicy.validateEvidence(evidence)
        guard !CorrectionSensitiveContext.contains(evidence: evidence) else { return false }
        guard !value.tombstones.contains(evidence.id),
              !value.evidence.contains(where: { $0.evidence.id == evidence.id }) else { return false }
        var next = value
        if next.terms.contains(where: { Self.samePair($0, evidence) && $0.status == .disabled }) {
            next.tombstones.append(evidence.id)
            try publish(next)
            return false
        }
        next.evidence.append(LearningEvidenceRecord(evidence: evidence))
        if let index = next.terms.firstIndex(where: { Self.samePair($0, evidence) }) {
            next.terms[index].evidenceIDs.append(evidence.id)
            next.terms[index].updatedAt = evidence.createdAt
        } else {
            next.terms.append(LearnedTerm(variant: evidence.variant, canonical: evidence.canonical,
                appBundleID: evidence.appBundleID, evidenceIDs: [evidence.id], updatedAt: evidence.createdAt))
        }
        Self.recompute(&next)
        try publish(next)
        return true
    }

    /// Reject an applied spelling when the person changes it in the editor.
    /// Exact reversals are suppressed; a third spelling remains an observed B→C event.
    @discardableResult
    func rejectReversal(_ evidence: CorrectionEvidence, appliedTermIDs: [UUID]) throws -> Bool {
        guard value.isEnabled, evidence.origin == nil else { return false }
        try CorrectionLearningPolicy.validateEvidence(evidence)
        let matches = value.terms.indices.filter { index in
            appliedTermIDs.contains(value.terms[index].id) &&
            value.terms[index].canonical.lowercased().utf8.elementsEqual(evidence.variant.lowercased().utf8)
        }
        guard !matches.isEmpty else { return false }
        let isReversal = matches.contains {
            value.terms[$0].variant.lowercased().utf8.elementsEqual(evidence.canonical.lowercased().utf8)
        }
        if value.tombstones.contains(evidence.id) { return true }
        let activeMatches = matches.filter { value.terms[$0].status != .disabled }
        guard !activeMatches.isEmpty else { return isReversal }
        var next = value
        if isReversal { next.tombstones.append(evidence.id) }
        for index in activeMatches {
            next.terms[index].status = .disabled
            next.terms[index].hasRejectedAppliedCorrection = true
            if isReversal {
                next.terms[index].reversalEventIDs = (next.terms[index].reversalEventIDs ?? []) + [evidence.id]
            }
        }
        Self.recompute(&next)
        try publish(next)
        return isReversal
    }

    func pending() -> [CorrectionEvidence] {
        guard value.isEnabled else { return [] }
        let disabled = Set(value.terms.filter { $0.status == .disabled }.flatMap(\.evidenceIDs))
        return value.evidence.filter {
            $0.receipt == nil && !disabled.contains($0.evidence.id) &&
                ($0.evidence.origin == nil || value.externalCorrectionsEnabled)
        }.map(\.evidence)
    }

    func classify(_ receipt: CorrectionClassificationReceipt, consentGeneration expectedGeneration: UInt64? = nil) throws {
        try CorrectionLearningPolicy.validate(receipt.result, request: receipt.request)
        guard !Task.isCancelled, value.isEnabled,
              receipt.request.evidence.origin == nil ||
                (value.externalCorrectionsEnabled && expectedGeneration == consentGeneration),
              let index = value.evidence.firstIndex(where: { $0.evidence.id == receipt.request.evidence.id }),
              value.evidence[index].evidence == receipt.request.evidence,
              value.evidence[index].receipt == nil else { return }
        var next = value
        next.evidence[index].receipt = receipt
        Self.recompute(&next)
        try publish(next)
    }

    func approve(id: UUID) throws {
        guard let index = value.terms.firstIndex(where: { $0.id == id }) else { throw CorrectionLearningError.missingEntry }
        var next = value
        let selected = next.terms[index]
        // An explicit choice resolves rival spellings in this scope.
        for other in next.terms.indices where Self.sameVariant(next.terms[other], selected) && other != index {
            next.terms[other].status = .disabled
        }
        next.terms[index].status = .approved
        Self.recompute(&next)
        try publish(next)
    }

    func disable(id: UUID) throws {
        guard let index = value.terms.firstIndex(where: { $0.id == id }) else { throw CorrectionLearningError.missingEntry }
        var next = value
        next.terms[index].status = .disabled
        Self.recompute(&next)
        try publish(next)
    }

    func forget(id: UUID) throws {
        guard let term = value.terms.first(where: { $0.id == id }) else { throw CorrectionLearningError.missingEntry }
        var next = value
        let forgotten = Set(term.evidenceIDs)
        next.evidence.removeAll { forgotten.contains($0.evidence.id) }
        next.terms.removeAll { $0.id == id }
        next.tombstones.append(contentsOf: forgotten.subtracting(next.tombstones))
        Self.recompute(&next)
        try publish(next)
    }

    func suggestions(appBundleID: String?, maximumTerms: Int = 64, tokenBudget: Int = 512) -> [LearnedTermSuggestion] {
        bounded(eligibleSuggestions(appBundleID: appBundleID), maximumTerms: maximumTerms, tokenBudget: tokenBudget)
    }

    func suggestions(for text: String, appBundleID: String?) async -> [LearnedTermSuggestion] {
        guard value.isEnabled, !Task.isCancelled,
              text.utf8.count <= LearnedTermApplicator.maxSourceUTF8 else { return [] }
        let records = Dictionary(uniqueKeysWithValues: value.evidence.map { ($0.evidence.id, $0) })
        let sourceSHA256 = DictationTransformPolicy.sourceDigest(text)
        let protected = LearnedTermApplicator.protectedLiteralRanges(in: text)
        var languageCache: [String: CorrectionLanguage] = [:]
        func language(in context: String) -> CorrectionLanguage {
            if let cached = languageCache[context] { return cached }
            guard languageCache.count < LearnedTermApplicator.maxSpans else { return .unknown }
            let result = CorrectionLanguageScope.recognized(in: context)
            languageCache[context] = result
            return result
        }
        var qualified: [LearnedTermSuggestion] = []
        var admittedTerms: [UUID: LearnedTerm] = [:]
        // Evidence counts never authorize use. Both the query and final admission
        // require an explicit approval for this exact observed pair.
        for suggestion in eligibleSuggestions(appBundleID: appBundleID) {
            guard !Task.isCancelled else { return [] }
            guard let term = value.terms.first(where: { $0.id == suggestion.id }) else { continue }
            let supporting = term.evidenceIDs.compactMap { records[$0] }.filter { record in
                !CorrectionSensitiveContext.contains(evidence: record.evidence) &&
                    (term.status == .approved || record.receipt.map {
                        CorrectionLearningPolicy.isAutomaticVote($0.result, evidence: record.evidence)
                    } == true)
            }
            let evidenceWords = Set(supporting.flatMap {
                LearnedTermApplicator.meaningfulWords($0.evidence.leftContext + " " + $0.evidence.rightContext)
            })
            guard !evidenceWords.isEmpty else { continue }
            let languageScopes: [CorrectionLanguage] = term.status == .approved
                ? supporting.map { language(in: $0.evidence.leftContext + " " + $0.evidence.rightContext) }
                : [term.language]
            guard languageScopes.contains(where: { $0 != .unknown }) else { continue }
            let matches = LearnedTermApplicator.literalRanges(of: term.variant, in: text, excluding: protected).filter { range in
                guard !CorrectionSensitiveContext.contains(in: text, around: range, replacement: term.canonical) else { return false }
                let left = String(text[..<range.lowerBound].suffix(96))
                let right = String(text[range.upperBound...].prefix(96))
                let nearby = Set(LearnedTermApplicator.meaningfulWords(left + " " + right))
                guard !nearby.isDisjoint(with: evidenceWords) else { return false }
                let localLanguage = language(in: left + " " + right)
                return languageScopes.contains { CorrectionLanguageScope.permits(localLanguage, scope: $0) }
            }
            guard !matches.isEmpty else { continue }
            var candidate = suggestion
            candidate.sourceSHA256 = sourceSHA256
            candidate.qualifiedSpans = matches.map {
                let range = NSRange($0, in: text)
                return LearnedTermSpan(utf16Location: range.location, utf16Length: range.length)
            }
            qualified.append(candidate)
            admittedTerms[term.id] = term
        }
        // Later awaits may permit Disable, Forget, rivals, or language conflicts.
        guard value.isEnabled, !Task.isCancelled else { return [] }
        let currentEligible = Set(eligibleSuggestions(appBundleID: appBundleID).map(\.id))
        qualified.removeAll { candidate in
            !currentEligible.contains(candidate.id) ||
                value.terms.first(where: { $0.id == candidate.id }) != admittedTerms[candidate.id]
        }
        return bounded(qualified, maximumTerms: 64, tokenBudget: 512)
    }

    private func eligibleSuggestions(appBundleID: String?) -> [LearnedTermSuggestion] {
        guard value.isEnabled else { return [] }
        let safeEvidenceIDs = Set(value.evidence.filter {
            !CorrectionSensitiveContext.contains(evidence: $0.evidence)
        }.map { $0.evidence.id })
        let eligible = value.terms.filter {
            $0.status == .approved &&
            ($0.appBundleID == nil || $0.appBundleID == appBundleID) &&
            $0.evidenceIDs.contains(where: safeEvidenceIDs.contains)
        }
        var result: [LearnedTermSuggestion] = []
        for term in eligible {
            let rivals = eligible.filter { Self.variantKey($0.variant) == Self.variantKey(term.variant) }
            guard Set(rivals.map { DictationTransformPolicy.sourceDigest($0.canonical) }).count == 1,
                  !result.contains(where: { Self.variantKey($0.variant) == Self.variantKey(term.variant) }) else { continue }
            result.append(LearnedTermSuggestion(id: term.id, variant: term.variant, canonical: term.canonical,
                appBundleID: term.appBundleID, language: term.language))
        }
        return result
    }

    private func bounded(_ candidates: [LearnedTermSuggestion], maximumTerms: Int, tokenBudget: Int) -> [LearnedTermSuggestion] {
        guard maximumTerms > 0, tokenBudget > 0 else { return [] }
        var result: [LearnedTermSuggestion] = []
        var consumed = 0
        for candidate in candidates {
            // Conservative UTF8-byte estimate; runtime still counts the complete model input.
            let cost = candidate.variant.utf8.count + candidate.canonical.utf8.count + 16
            guard consumed + cost <= min(tokenBudget, 512) else { continue }
            result.append(candidate)
            consumed += cost
            if result.count >= min(maximumTerms, 64) { break }
        }
        return result
    }

    private func publish(_ next: LearningDictionarySnapshot) throws {
        try Self.validate(next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= Self.maxFileBytes else { throw CorrectionLearningError.storageLimit }
        try write(data, url)
        value = next
    }

    private static func recompute(_ snapshot: inout LearningDictionarySnapshot,
                                  policyVersion: Int = CorrectionLearningPolicy.automaticPolicyVersion) {
        let records = Dictionary(uniqueKeysWithValues: snapshot.evidence.map { ($0.evidence.id, $0) })
        func isPositive(_ record: LearningEvidenceRecord) -> Bool {
            guard let receipt = record.receipt else { return false }
            let generatingPolicy = policyVersion == 4 ? receipt.result.promptTemplateVersion : policyVersion
            if generatingPolicy == 1 {
                return receipt.result.classification == .terminology &&
                    receipt.result.confidence >= CorrectionLearningPolicy.promotionConfidence
            }
            if generatingPolicy == 2 {
                return CorrectionLearningPolicy.isLegacyV2AutomaticVote(receipt.result, evidence: record.evidence)
            }
            if generatingPolicy == 4 {
                return CorrectionLearningPolicy.isAutomaticVote(receipt.result, evidence: record.evidence)
            }
            return CorrectionLearningPolicy.isLegacyV3SpellingCorroboration(receipt.result, evidence: record.evidence)
        }
        for index in snapshot.terms.indices {
            let matches = snapshot.terms[index].evidenceIDs.compactMap { records[$0] }
            let lexicalVerdicts = matches.compactMap { $0.receipt?.result.lexicalAssessment?.verdict }
            snapshot.terms[index].lexicalReviewReason = policyVersion < 3 ? nil :
                lexicalVerdicts.contains(.knownSourceWord) ? .knownSourceWord :
                lexicalVerdicts.contains(.unavailable) ? .unavailable : nil
            let candidates = matches.filter(isPositive)
            let languages = Set(candidates.compactMap { $0.receipt?.result.language })
            let hasLanguageConflict = policyVersion != 1 && languages.count > 1
            let positive = hasLanguageConflict ? [] : candidates
            let positiveIDs = Set(positive.map { $0.evidence.id })
            snapshot.terms[index].positiveSessionCount = Set(positive.map { $0.evidence.sessionID }).count
            snapshot.terms[index].negativeCount = max(snapshot.terms[index].reversalEventIDs?.count ?? 0,
                snapshot.terms[index].hasRejectedAppliedCorrection == true ? 1 : 0) + matches.filter {
                $0.receipt != nil && !positiveIDs.contains($0.evidence.id)
            }.count
            snapshot.terms[index].language = positive.last?.receipt?.result.language ?? .unknown
            guard snapshot.terms[index].status != .disabled && snapshot.terms[index].status != .approved else { continue }
            if policyVersion < 4 && snapshot.terms[index].positiveSessionCount >= 2 && snapshot.terms[index].negativeCount == 0 {
                snapshot.terms[index].status = .learned
            } else if matches.allSatisfy({ $0.receipt == nil }) {
                snapshot.terms[index].status = .pending
            } else {
                snapshot.terms[index].status = .review
            }
        }
        for index in snapshot.terms.indices where snapshot.terms[index].status != .disabled && snapshot.terms[index].status != .approved {
            let rivals = snapshot.terms.filter {
                $0.id != snapshot.terms[index].id && $0.status != .disabled &&
                sameVariant($0, snapshot.terms[index]) &&
                !$0.canonical.utf8.elementsEqual(snapshot.terms[index].canonical.utf8)
            }
            if !rivals.isEmpty { snapshot.terms[index].status = .review }
        }
    }

    private static func validate(_ snapshot: LearningDictionarySnapshot,
                                 policyVersion: Int = CorrectionLearningPolicy.automaticPolicyVersion) throws {
        guard snapshot.schemaVersion == 1,
              (1...CorrectionLearningPolicy.automaticPolicyVersion).contains(policyVersion),
              policyVersion == 1 ? snapshot.automaticPolicyVersion == nil :
                snapshot.automaticPolicyVersion == policyVersion else {
            throw CorrectionLearningError.unsupportedStore
        }
        guard snapshot.evidence.count <= maxEvidence, snapshot.terms.count <= maxTerms,
              snapshot.tombstones.count <= maxTombstones,
              snapshot.evidence.count + snapshot.tombstones.count + snapshot.terms.filter({ $0.status != .disabled }).count <= maxTombstones else {
            throw CorrectionLearningError.storageLimit
        }
        let eventIDs = snapshot.evidence.map { $0.evidence.id }
        guard Set(eventIDs).count == eventIDs.count,
              Set(snapshot.terms.map(\.id)).count == snapshot.terms.count,
              Set(snapshot.tombstones).count == snapshot.tombstones.count,
              Set(eventIDs).isDisjoint(with: snapshot.tombstones) else { throw CorrectionLearningError.unsupportedStore }
        for record in snapshot.evidence {
            try CorrectionLearningPolicy.validateEvidence(record.evidence)
            if let receipt = record.receipt {
                guard receipt.request.evidence == record.evidence else { throw CorrectionLearningError.unsupportedStore }
                try CorrectionLearningPolicy.validateHistorical(receipt.result, request: receipt.request)
            }
        }
        let records = Dictionary(uniqueKeysWithValues: snapshot.evidence.map { ($0.evidence.id, $0.evidence) })
        var covered = Set<UUID>()
        for term in snapshot.terms {
            guard !term.evidenceIDs.isEmpty, Set(term.evidenceIDs).count == term.evidenceIDs.count,
                  term.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  Set(term.reversalEventIDs ?? []).count == (term.reversalEventIDs?.count ?? 0),
                  Set(term.reversalEventIDs ?? []).isSubset(of: Set(snapshot.tombstones)),
                  term.evidenceIDs.allSatisfy({ id in
                      guard let evidence = records[id] else { return false }
                      return covered.insert(id).inserted && samePair(term, evidence)
                  }) else { throw CorrectionLearningError.unsupportedStore }
        }
        guard covered == Set(eventIDs) else { throw CorrectionLearningError.unsupportedStore }
        var derived = snapshot
        recompute(&derived, policyVersion: policyVersion)
        guard derived.terms == snapshot.terms else { throw CorrectionLearningError.unsupportedStore }
    }

    private static func samePair(_ term: LearnedTerm, _ evidence: CorrectionEvidence) -> Bool {
        term.variant.utf8.elementsEqual(evidence.variant.utf8) &&
        term.canonical.utf8.elementsEqual(evidence.canonical.utf8) && term.appBundleID == evidence.appBundleID
    }
    private static func sameVariant(_ lhs: LearnedTerm, _ rhs: LearnedTerm) -> Bool {
        variantKey(lhs.variant) == variantKey(rhs.variant) && lhs.appBundleID == rhs.appBundleID
    }
    private static func variantKey(_ value: String) -> String {
        DictationTransformPolicy.sourceDigest(value.lowercased())
    }

    private static func atomicWrite(_ data: Data, _ target: URL) throws {
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(".learning-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = try FileHandle(forWritingTo: temp)
        do {
            try file.write(contentsOf: data)
            try file.synchronize()
            try file.close()
        } catch {
            try? file.close()
            throw error
        }
        guard Darwin.rename(temp.path, target.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

@MainActor @Observable
final class LearningDictionaryController {
    private(set) var isEnabled = false
    private(set) var externalCorrectionsEnabled = false
    private(set) var externalCorrectionConsentGeneration = UUID()
    private(set) var originSummaries: [UUID: LearningEvidenceOriginSummary] = [:]
    private(set) var entries: [LearnedTerm] = []
    private(set) var isClassifying = false
    private(set) var status = ""
    private(set) var errorMessage: String?
    /// Advances each time an outcome or error is reported, so views announce a repeated identical message again.
    private(set) var announcementToken = 0
    /// The message the latest report carried, kept as reported: a later success that clears `errorMessage`
    /// before the view reacts must not turn this report into an older status, or into silence.
    private(set) var announcement: String?
    @ObservationIgnored private let repository: LearningRepository
    @ObservationIgnored private let classifier: @MainActor (CorrectionEvidence) async throws -> CorrectionClassificationReceipt
    @ObservationIgnored private var classificationTask: Task<Void, Never>?
    @ObservationIgnored private var classificationEventID: UUID?
    @ObservationIgnored private var externalConsentObservers: [UUID: @MainActor () -> Void] = [:]

    init(repository: LearningRepository,
         classifier: @escaping @MainActor (CorrectionEvidence) async throws -> CorrectionClassificationReceipt) {
        self.repository = repository
        self.classifier = classifier
    }

    func refresh() async {
        let snapshot = await repository.snapshot()
        isEnabled = snapshot.isEnabled
        externalCorrectionsEnabled = snapshot.externalCorrectionsEnabled
        let evidenceByID = Dictionary(uniqueKeysWithValues: snapshot.evidence.map { ($0.evidence.id, $0.evidence) })
        originSummaries = Dictionary(uniqueKeysWithValues: snapshot.terms.map { entry in
            let origins = entry.evidenceIDs.compactMap { evidenceByID[$0]?.origin }
            let count = entry.evidenceIDs.count
            let summary: LearningEvidenceOriginSummary = origins.isEmpty ? .savedEditor :
                origins.count == count ? .destinationObservation : .mixed
            return (entry.id, summary)
        })
        entries = snapshot.terms.sorted { $0.updatedAt > $1.updatedAt }
    }

    func setEnabled(_ enabled: Bool) async {
        if !enabled { isEnabled = false; cancelPendingClassification() }
        invalidateExternalConsent()
        do {
            try await repository.setEnabled(enabled)
            errorMessage = nil
            await refresh()
            if enabled { drainPending() }
        } catch { reportError(error); await refresh() }
    }

    func setExternalCorrectionsEnabled(_ enabled: Bool) async {
        if !enabled { externalCorrectionsEnabled = false; cancelPendingClassification() }
        invalidateExternalConsent()
        do {
            try await repository.setExternalCorrectionsEnabled(enabled)
            errorMessage = nil
            await refresh()
            if enabled { drainPending() }
        } catch { reportError(error); await refresh() }
    }

    func observeExternalCorrectionConsentChanges(_ onChange: @escaping @MainActor () -> Void) -> any ExternalCorrectionCancellation {
        let id = UUID()
        externalConsentObservers[id] = onChange
        return LearningConsentCancellation { [weak self] in self?.externalConsentObservers.removeValue(forKey: id) }
    }

    private func invalidateExternalConsent() {
        externalCorrectionConsentGeneration = UUID()
        let callbacks = Array(externalConsentObservers.values)
        for callback in callbacks { callback() }
    }

    /// Observations never mutate the delivered source or infer who changed it.
    func submitExternal(source: DictationTextRevision, correctedText: String,
                        sessionID: UUID, takeID: UUID, appBundleID: String,
                        deliveryID: UUID, observedAt: Date) async {
        let consentID = externalCorrectionConsentGeneration
        guard !Task.isCancelled, isEnabled, externalCorrectionsEnabled,
              let evidence = ExternalCorrectionEvidencePolicy.evidence(source: source, correctedText: correctedText,
                sessionID: sessionID, takeID: takeID, appBundleID: appBundleID,
                deliveryID: deliveryID, observedAt: observedAt),
              let generation = await repository.classificationConsent(for: evidence) else { return }
        guard !Task.isCancelled, consentID == externalCorrectionConsentGeneration,
              isEnabled, externalCorrectionsEnabled else { return }
        do {
            guard try await repository.enqueue(evidence, consentGeneration: generation) else { return }
            await refresh()
            drainPending()
        } catch { reportError(error) }
    }

    /// Returns after the evidence is durable. Model work is a separate cancellable task.
    func submit(source: DictationTextRevision, edited: DictationTextRevision,
                sessionID: UUID, takeID: UUID, appBundleID: String?) async {
        guard isEnabled, let evidence = CorrectionLearningPolicy.evidence(source: source, edited: edited,
            sessionID: sessionID, takeID: takeID, appBundleID: appBundleID) else { return }
        do {
            if let applied = source.appliedLearnedTermIDs, !applied.isEmpty,
               try await repository.rejectReversal(evidence, appliedTermIDs: applied) {
                await refresh()
                return
            }
            guard try await repository.enqueue(evidence) else { return }
            await refresh()
            drainPending()
        } catch { reportError(error) }
    }

    func drainPending() {
        guard isEnabled, classificationTask == nil else { return }
        classificationTask = Task { [weak self] in
            guard let self else { return }
            isClassifying = true
            defer { isClassifying = false; classificationTask = nil }
            while !Task.isCancelled {
                guard let evidence = (await repository.pending()).first else { return }
                classificationEventID = evidence.id
                defer { classificationEventID = nil }
                do {
                    try Task.checkCancellation()
                    guard let generation = await repository.classificationConsent(for: evidence) else { return }
                    try Task.checkCancellation()
                    guard isEnabled, evidence.origin == nil || externalCorrectionsEnabled else { return }
                    let receipt = try await classifier(evidence)
                    try Task.checkCancellation()
                    try await repository.classify(receipt, consentGeneration: generation)
                    await refresh()
                    reportStatus(String(localized: "Local terminology review updated."))
                } catch is CancellationError {
                    return
                } catch {
                    // Durable pending evidence can be retried on the next idle period.
                    reportError(error)
                    return
                }
            }
        }
    }

    func cancelPendingClassification() { classificationTask?.cancel() }
    func waitUntilSettled() async { await classificationTask?.value }

    func approve(id: UUID) async {
        do { try await repository.approve(id: id); await refresh(); errorMessage = nil }
        catch { reportError(error) }
    }
    func disable(id: UUID) async {
        cancelClassification(for: id)
        do { try await repository.disable(id: id); await refresh(); errorMessage = nil }
        catch { reportError(error) }
    }
    func forget(id: UUID) async {
        cancelClassification(for: id)
        do { try await repository.forget(id: id); await refresh(); errorMessage = nil }
        catch { reportError(error) }
    }
    func suggestions(appBundleID: String?) async -> [LearnedTermSuggestion] {
        await repository.suggestions(appBundleID: appBundleID)
    }

    func suggestions(for text: String, appBundleID: String?) async -> [LearnedTermSuggestion] {
        await repository.suggestions(for: text, appBundleID: appBundleID)
    }

    /// Reports an outcome; it replaces any earlier error.
    private func reportStatus(_ message: String) {
        status = message
        errorMessage = nil
        announcement = message
        announcementToken &+= 1
    }

    private func reportError(_ error: any Error) {
        let message = error.localizedDescription
        errorMessage = message
        announcement = message
        announcementToken &+= 1
    }

    private func cancelClassification(for id: UUID) {
        if let active = classificationEventID,
           entries.first(where: { $0.id == id })?.evidenceIDs.contains(active) == true {
            cancelPendingClassification()
        }
    }
}

