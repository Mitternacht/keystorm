import Foundation

/// A run is comparable only when source data, hardware, model artifacts, and runtime are identified.
/// This is a record format, not a claim that any model has been qualified.
struct EvaluationRunContext: Codable, Equatable, Sendable {
    var datasetID: String
    var datasetRevision: String
    var sourceHashes: [String: String]
    var hardware: String
    var physicalMemoryBytes: UInt64
    var operatingSystem: String
    var configuration: ProcessingConfiguration
    var decodingAndWindowSettings: [String: String]
    var coldStart: Bool
    var recordedAt = Date()
}

struct EvaluationMeasurements: Codable, Equatable, Sendable {
    // Unmeasured values remain nil; download size is never substituted for resident memory.
    var downloadBytes: UInt64?
    var peakProcessBytes: UInt64?
    var peakMLXActiveBytes: UInt64?
    var peakCacheBytes: UInt64?
    var processingSeconds: Double?
    var sourceSeconds: Double?
    var transcriptionLagP95Seconds: Double?
    var maximumBacklogSeconds: Double?
    var thermalStates: [String] = []
    var batteryPercentagePointsConsumed: Double?
}

enum EvaluationAnnotationKind: String, Codable, Sendable {
    case requirement, criticalTerm, clause, negation, number, explicitReversal, caveat, exploratoryIdea
}

struct EvaluationAnnotation: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var kind: EvaluationAnnotationKind
    var critical = true
    var expectedMeaning: String
    var source: SourceReference
    /// Exact probes are useful for identifiers and numbers; they do not score paraphrase fidelity.
    var requiredLiterals: [String] = []
    var expectedStatus: FactStatus?
    var supersedesAnnotationID: String?
}

struct EvaluationFixture: Codable, Equatable, Sendable {
    var id: String
    var revision: String
    var synthetic: Bool
    var transcripts: [TranscriptRevision]
    var annotations: [EvaluationAnnotation]
}

enum EvaluationSemanticOutcome: String, Codable, Sendable {
    case preserved, omitted, negationReversed, meaningChanged, statusChanged, unresolved
}

/// Semantic matching is explicitly adjudicated. A second model or valid JSON is not ground truth.
struct EvaluationFactReview: Codable, Equatable, Sendable {
    var annotationID: String
    var matchingFactIDs: [UUID]
    var outcome: EvaluationSemanticOutcome
    var notes = ""
}

/// Every output claim must be reviewed, including claims with syntactically valid citations.
struct EvaluationClaimReview: Codable, Equatable, Sendable {
    var factID: UUID
    var supportedByCitedSources: Bool
    var notes = ""
}

struct FidelityScore: Codable, Equatable, Sendable {
    var criticalFactRecall: Double?
    var preservedCriticalFacts: Int
    var totalCriticalFacts: Int
    var omittedAnnotationIDs: [String]
    var negationReversalIDs: [String]
    var explicitReversalErrorIDs: [String]
    var missingLiteralProbes: [String]
    var statusMismatchIDs: [String]
    var wrongSupersessionIDs: [String]
    var unsupportedFactIDs: [UUID]
    var unsupportedConfirmedInstructionIDs: [UUID]
    var validSourceReferences: Int
    var totalSourceReferences: Int
    var sourceReferenceAccuracy: Double?
    var citationSupportAccuracy: Double?
}

/// Self-contained local report: metadata, source annotations, outputs, adjudication and measurements.
/// Synthetic reports exercise the harness and cannot establish representative model quality.
struct EvaluationReport: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    var context: EvaluationRunContext
    var fixture: EvaluationFixture
    var outputFacts: [Fact]
    var factReviews: [EvaluationFactReview]
    var claimReviews: [EvaluationClaimReview]
    var measurements: EvaluationMeasurements
    var score: FidelityScore

    init(context: EvaluationRunContext, fixture: EvaluationFixture, outputFacts: [Fact], factReviews: [EvaluationFactReview], claimReviews: [EvaluationClaimReview], measurements: EvaluationMeasurements = EvaluationMeasurements()) throws {
        guard !context.datasetID.isEmpty, !context.datasetRevision.isEmpty,
              !context.hardware.isEmpty, !context.operatingSystem.isEmpty,
              !context.configuration.modelID.isEmpty, !context.configuration.runtime.isEmpty,
              !context.configuration.revision.isEmpty, !context.configuration.quantization.isEmpty else {
            throw KeystormError.message("An evaluation report needs explicit dataset, hardware, model, quantization, and runtime metadata.")
        }
        self.context = context
        self.fixture = fixture
        self.outputFacts = outputFacts
        self.factReviews = factReviews
        self.claimReviews = claimReviews
        self.measurements = measurements
        score = try FidelityEvaluator.score(fixture: fixture, facts: outputFacts, factReviews: factReviews, claimReviews: claimReviews)
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

enum FidelityEvaluator {
    static func score(fixture: EvaluationFixture, facts: [Fact], factReviews: [EvaluationFactReview], claimReviews: [EvaluationClaimReview]) throws -> FidelityScore {
        let annotationIDs = Set(fixture.annotations.map(\.id))
        let factIDs = Set(facts.map(\.id))
        guard annotationIDs.count == fixture.annotations.count, factIDs.count == facts.count,
              Set(factReviews.map(\.annotationID)) == annotationIDs, factReviews.count == annotationIDs.count,
              Set(claimReviews.map(\.factID)) == factIDs, claimReviews.count == factIDs.count else {
            throw KeystormError.message("Evaluation needs exactly one human review per annotation and output claim, without duplicate identities.")
        }
        guard Set(fixture.transcripts.map(\.id)).count == fixture.transcripts.count else { throw KeystormError.message("Duplicate fixture transcript identities.") }
        let indexed = Dictionary(uniqueKeysWithValues: fixture.transcripts.map { ($0.id, $0) })
        for annotation in fixture.annotations {
            guard valid(annotation.source, in: indexed), annotation.supersedesAnnotationID.map({ annotationIDs.contains($0) }) ?? true else {
                throw KeystormError.message("Fixture annotation has invalid source evidence or a missing decision relation.")
            }
        }
        let reviews = Dictionary(uniqueKeysWithValues: factReviews.map { ($0.annotationID, $0) })
        let outputs = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        for review in factReviews {
            guard Set(review.matchingFactIDs).isSubset(of: factIDs),
                  review.outcome != .preserved || !review.matchingFactIDs.isEmpty,
                  review.outcome != .omitted || review.matchingFactIDs.isEmpty else {
                throw KeystormError.message("Evaluation review refers to a missing fact or contradicts its match outcome.")
            }
        }
        var missingLiterals: [String] = []
        var statusMismatches: [String] = []
        var wrongSupersession: [String] = []
        for annotation in fixture.annotations {
            guard let review = reviews[annotation.id] else { continue }
            let matching = review.matchingFactIDs.compactMap { outputs[$0] }
            let statements = matching.map(\.text).joined(separator: "\n")
            for literal in annotation.requiredLiterals where !statements.contains(literal) {
                missingLiterals.append("\(annotation.id): \(literal)")
            }
            if let expected = annotation.expectedStatus, !matching.isEmpty, !matching.contains(where: { $0.status == expected }) {
                statusMismatches.append(annotation.id)
            }
            if let previous = annotation.supersedesAnnotationID {
                let previousIDs = Set(reviews[previous]?.matchingFactIDs ?? [])
                if !matching.contains(where: { $0.supersedes.map(previousIDs.contains) ?? false }) { wrongSupersession.append(annotation.id) }
            }
        }
        let critical = fixture.annotations.filter(\.critical)
        let preserved = critical.filter { reviews[$0.id]?.outcome == .preserved }.count
        let references = facts.flatMap(\.sources)
        let validReferences = references.filter { valid($0, in: indexed) }.count
        let unsupported = claimReviews.filter { !$0.supportedByCitedSources }.map(\.factID)
        let unsupportedSet = Set(unsupported)
        let instructionKinds: Set<FactKind> = [.requirement, .constraint, .decision, .task]
        let unsupportedConfirmed = facts.filter { unsupportedSet.contains($0.id) && $0.status == .confirmed && instructionKinds.contains($0.kind) }.map(\.id)
        return FidelityScore(
            criticalFactRecall: critical.isEmpty ? nil : Double(preserved) / Double(critical.count),
            preservedCriticalFacts: preserved, totalCriticalFacts: critical.count,
            omittedAnnotationIDs: fixture.annotations.filter { reviews[$0.id]?.outcome == .omitted }.map(\.id),
            negationReversalIDs: factReviews.filter { $0.outcome == .negationReversed }.map(\.annotationID),
            explicitReversalErrorIDs: fixture.annotations.filter { $0.kind == .explicitReversal && reviews[$0.id]?.outcome != .preserved }.map(\.id),
            missingLiteralProbes: missingLiterals, statusMismatchIDs: statusMismatches, wrongSupersessionIDs: wrongSupersession,
            unsupportedFactIDs: unsupported, unsupportedConfirmedInstructionIDs: unsupportedConfirmed,
            validSourceReferences: validReferences, totalSourceReferences: references.count,
            sourceReferenceAccuracy: references.isEmpty ? nil : Double(validReferences) / Double(references.count),
            citationSupportAccuracy: claimReviews.isEmpty ? nil : Double(claimReviews.filter(\.supportedByCitedSources).count) / Double(claimReviews.count))
    }

    private static func valid(_ source: SourceReference, in transcripts: [UUID: TranscriptRevision]) -> Bool {
        guard let transcript = transcripts[source.transcriptID] else { return false }
        let bytes = Array(transcript.text.utf8)
        guard source.startUTF8 >= 0, source.endUTF8 > source.startUTF8, source.endUTF8 <= bytes.count else { return false }
        return String(bytes: bytes[source.startUTF8..<source.endUTF8], encoding: .utf8) == source.quote
    }
}

/// Synthetic regression material exercises the scorer. It is not a representative recording corpus.
enum EvaluationFixtures {
    static func fidelityTripwire() throws -> EvaluationFixture {
        let text = """
        Use a 256 MB cache, not 512 MB. Keep project Photon local and never upload audio.
        Brainstorming only: maybe add cloud sync someday.
        Correction: for the cache only, use 128 MB instead of 256 MB. Keep the no-upload rule.
        Retain the example path /Projects/Photon/config.json, including its case.
        """
        let transcript = TranscriptRevision(rawText: text, text: text, origin: .imported, timingPrecision: .unavailable)
        func source(_ quote: String) throws -> SourceReference {
            guard let range = text.range(of: quote) else { throw KeystormError.message("Synthetic fixture quote is missing.") }
            let start = text[..<range.lowerBound].utf8.count
            return SourceReference(transcriptID: transcript.id, startUTF8: start, endUTF8: start + quote.utf8.count, quote: quote)
        }
        return EvaluationFixture(id: "intent-tripwire", revision: "1", synthetic: true, transcripts: [transcript], annotations: [
            EvaluationAnnotation(id: "cache-original", kind: .number, expectedMeaning: "Initial cache size is 256 MB rather than 512 MB.", source: try source("Use a 256 MB cache, not 512 MB."), requiredLiterals: ["256", "512"], expectedStatus: .confirmed),
            EvaluationAnnotation(id: "local-only", kind: .negation, expectedMeaning: "Photon and audio processing stay local; uploading audio is prohibited.", source: try source("Keep project Photon local and never upload audio."), requiredLiterals: ["Photon"], expectedStatus: .confirmed),
            EvaluationAnnotation(id: "cloud-idea", kind: .exploratoryIdea, expectedMeaning: "Cloud sync is brainstorming, not an instruction.", source: try source("Brainstorming only: maybe add cloud sync someday."), expectedStatus: .exploratory),
            EvaluationAnnotation(id: "cache-reversal", kind: .explicitReversal, expectedMeaning: "Only the cache size changes to 128 MB; no-upload remains active.", source: try source("Correction: for the cache only, use 128 MB instead of 256 MB. Keep the no-upload rule."), requiredLiterals: ["128", "256"], expectedStatus: .confirmed, supersedesAnnotationID: "cache-original"),
            EvaluationAnnotation(id: "example-path", kind: .criticalTerm, expectedMeaning: "Retain the exact path and capitalization.", source: try source("Retain the example path /Projects/Photon/config.json, including its case."), requiredLiterals: ["/Projects/Photon/config.json"], expectedStatus: .confirmed)
        ])
    }
}
