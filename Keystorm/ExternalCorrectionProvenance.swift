import Foundation

/// Accessibility observes the changed passage; it does not identify its editor.
struct CorrectionEvidenceOrigin: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case destinationObservation }
    enum SourceClassification: String, Codable, Sendable { case deliveredPassage }
    enum Attribution: String, Codable, Sendable { case unverified }

    var kind: Kind = .destinationObservation
    var deliveryID: UUID
    var observedAt: Date
    var sourceClassification: SourceClassification = .deliveredPassage
    var attribution: Attribution = .unverified
}

enum ExternalCorrectionEvidencePolicy {
    static let supportedAppBundleID = "com.apple.TextEdit"
    static let maximumObservationAge: TimeInterval = 15 * 60

    /// The backend must first verify that source/app/delivery identify its exact,
    /// saved delivered passage. This method never changes the source revision.
    static func evidence(source: DictationTextRevision, correctedText: String,
                         sessionID: UUID, takeID: UUID, appBundleID: String,
                         deliveryID: UUID, observedAt: Date, now: Date = Date()) -> CorrectionEvidence? {
        guard appBundleID == supportedAppBundleID,
              observedAt.timeIntervalSinceReferenceDate.isFinite,
              observedAt.timeIntervalSince(now) <= 60,
              now.timeIntervalSince(observedAt) <= maximumObservationAge,
              !source.text.utf8.elementsEqual(correctedText.utf8),
              correctedText.utf8.count <= CorrectionLearningPolicy.maxTranscriptUTF8,
              let editedID = eventID(source: source, correctedText: correctedText, sessionID: sessionID,
                  takeID: takeID, appBundleID: appBundleID, deliveryID: deliveryID),
              editedID != source.id else { return nil }
        let edited = DictationTextRevision(id: editedID, rawText: source.rawText,
            text: correctedText, sourceTranscriptIDs: source.sourceTranscriptIDs)
        guard var evidence = CorrectionLearningPolicy.evidence(source: source, edited: edited,
            sessionID: sessionID, takeID: takeID, appBundleID: appBundleID) else { return nil }
        evidence.createdAt = now
        evidence.origin = CorrectionEvidenceOrigin(deliveryID: deliveryID, observedAt: observedAt)
        return (try? CorrectionLearningPolicy.validateEvidence(evidence)) == nil ? nil : evidence
    }

    /// Timestamp-independent identity makes repeated notifications of the same
    /// delivered-source change idempotent while retaining the first observation.
    private static func eventID(source: DictationTextRevision, correctedText: String,
                                sessionID: UUID, takeID: UUID, appBundleID: String,
                                deliveryID: UUID) -> UUID? {
        struct Identity: Encodable {
            let namespace = "destination-correction-v1"
            var sessionID: UUID; var takeID: UUID; var sourceOutputID: UUID
            var appBundleID: String; var deliveryID: UUID
            var sourceSHA256: String; var correctedSHA256: String
        }
        let identity = Identity(sessionID: sessionID, takeID: takeID, sourceOutputID: source.id,
            appBundleID: appBundleID, deliveryID: deliveryID,
            sourceSHA256: DictationTransformPolicy.sourceDigest(source.text),
            correctedSHA256: DictationTransformPolicy.sourceDigest(correctedText))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(identity) else { return nil }
        var hex = Array(DictationTransformPolicy.sourceDigest(String(decoding: data, as: UTF8.self)).prefix(32))
        guard hex.count == 32 else { return nil }
        hex[12] = "8"; hex[16] = "8" // custom UUID version and RFC variant
        let value = String(hex)
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(value.dropFirst(range.lowerBound).prefix(range.count))
        }
        return UUID(uuidString: groups.joined(separator: "-"))
    }

    static func validOrigin(_ evidence: CorrectionEvidence) -> Bool {
        guard let origin = evidence.origin else { return true }
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")
        return evidence.appBundleID == supportedAppBundleID && origin.deliveryID != zero &&
            origin.observedAt.timeIntervalSinceReferenceDate.isFinite &&
            origin.observedAt.timeIntervalSince(evidence.createdAt) <= 60 &&
            evidence.createdAt.timeIntervalSince(origin.observedAt) <= maximumObservationAge
    }
}

enum LearningEvidenceOriginSummary: Equatable, Sendable {
    case savedEditor, destinationObservation, mixed

    var description: LocalizedStringResource {
        switch self {
        case .savedEditor:
            "Saved correction in Keystorm's transcript editor."
        case .destinationObservation:
            "Observed change after dictation in TextEdit. It may come from you or the destination app; authorship is not verified."
        case .mixed:
            "Includes saved editor corrections and observed changes after dictation in TextEdit. Destination changes may come from you or the app; authorship is not verified."
        }
    }
}


@MainActor
final class LearningConsentCancellation: ExternalCorrectionCancellation {
    private var cancellation: (@MainActor () -> Void)?
    init(_ cancellation: @escaping @MainActor () -> Void) { self.cancellation = cancellation }
    func cancel() {
        let action = cancellation
        cancellation = nil
        action?()
    }
}
