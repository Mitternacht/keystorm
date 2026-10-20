import Foundation
import Testing
@testable import Keystorm

struct EvaluationTests {
    @Test func `Scorer detects negation reversal omission unsupported additions and bad citations`() throws {
        let fixture = try EvaluationFixtures.fidelityTripwire()
        let original = fixture.annotations[0]
        let local = fixture.annotations[1]
        let path = fixture.annotations[4]
        let originalFact = Fact(kind: .constraint, status: .confirmed, text: "Use 256 MB, not 512 MB.", sources: [original.source])
        let reversedFact = Fact(kind: .requirement, status: .confirmed, text: "Upload Photon audio to the cloud.", sources: [local.source])
        var wrongSource = path.source
        wrongSource.startUTF8 += 1
        let invented = Fact(kind: .requirement, status: .confirmed, text: "Require a paid account and use /projects/photon/config.json.", sources: [wrongSource])
        let facts = [originalFact, reversedFact, invented]
        let reviews = [
            EvaluationFactReview(annotationID: "cache-original", matchingFactIDs: [originalFact.id], outcome: .preserved),
            EvaluationFactReview(annotationID: "local-only", matchingFactIDs: [reversedFact.id], outcome: .negationReversed),
            EvaluationFactReview(annotationID: "cloud-idea", matchingFactIDs: [], outcome: .omitted),
            EvaluationFactReview(annotationID: "cache-reversal", matchingFactIDs: [], outcome: .omitted),
            EvaluationFactReview(annotationID: "example-path", matchingFactIDs: [invented.id], outcome: .meaningChanged)
        ]
        let claims = [
            EvaluationClaimReview(factID: originalFact.id, supportedByCitedSources: true),
            EvaluationClaimReview(factID: reversedFact.id, supportedByCitedSources: false),
            EvaluationClaimReview(factID: invented.id, supportedByCitedSources: false)
        ]
        let score = try FidelityEvaluator.score(fixture: fixture, facts: facts, factReviews: reviews, claimReviews: claims)
        #expect(score.criticalFactRecall == 0.2)
        #expect(score.negationReversalIDs == ["local-only"])
        #expect(score.explicitReversalErrorIDs == ["cache-reversal"])
        #expect(score.wrongSupersessionIDs == ["cache-reversal"])
        #expect(score.omittedAnnotationIDs == ["cloud-idea", "cache-reversal"])
        #expect(score.unsupportedFactIDs.count == 2)
        #expect(score.unsupportedConfirmedInstructionIDs.count == 2)
        #expect(score.validSourceReferences == 2)
        #expect(score.totalSourceReferences == 3)
        #expect(score.missingLiteralProbes.contains("example-path: /Projects/Photon/config.json"))
    }

    @Test func `Report retains run provenance and leaves unmeasured resources unavailable`() throws {
        let fixture = try EvaluationFixtures.fidelityTripwire()
        var facts = fixture.annotations.map { annotation in
            Fact(kind: .requirement, status: annotation.expectedStatus ?? .ambiguous,
                 text: annotation.source.quote, sources: [annotation.source])
        }
        facts[3].supersedes = facts[0].id
        let reviews = zip(fixture.annotations, facts).map { annotation, fact in
            EvaluationFactReview(annotationID: annotation.id, matchingFactIDs: [fact.id], outcome: .preserved)
        }
        let claims = facts.map { EvaluationClaimReview(factID: $0.id, supportedByCitedSources: true) }
        let configuration = ProcessingConfiguration(modelID: "unit-test-fixture", revision: "synthetic-v1", runtime: "unit test, no inference", quantization: "not applicable")
        let context = EvaluationRunContext(datasetID: fixture.id, datasetRevision: fixture.revision,
            sourceHashes: [:], hardware: "synthetic unit test", physicalMemoryBytes: 0,
            operatingSystem: "unit test", configuration: configuration,
            decodingAndWindowSettings: [:], coldStart: false)
        let report = try EvaluationReport(context: context, fixture: fixture, outputFacts: facts,
            factReviews: reviews, claimReviews: claims)
        let decoded = try JSONDecoder().decode(EvaluationReport.self, from: report.jsonData())
        #expect(decoded.fixture.synthetic)
        #expect(decoded.context.configuration.runtime == "unit test, no inference")
        #expect(decoded.measurements.peakProcessBytes == nil)
        #expect(decoded.measurements.batteryPercentagePointsConsumed == nil)
        #expect(decoded.score.criticalFactRecall == 1)
        #expect(decoded.score.wrongSupersessionIDs.isEmpty)
    }

    @Test func `Incomplete adjudication cannot produce an apparently complete score`() throws {
        let fixture = try EvaluationFixtures.fidelityTripwire()
        #expect(throws: (any Error).self) {
            try FidelityEvaluator.score(fixture: fixture, facts: [], factReviews: [], claimReviews: [])
        }
    }

    @Test func `Correct literals and valid JSON do not substitute for semantic review`() throws {
        let fixture = try EvaluationFixtures.fidelityTripwire()
        let facts = fixture.annotations.map { annotation in
            Fact(kind: .requirement, status: annotation.expectedStatus ?? .ambiguous,
                 text: annotation.source.quote, sources: [annotation.source])
        }
        let reviews = zip(fixture.annotations, facts).map { annotation, fact in
            EvaluationFactReview(annotationID: annotation.id, matchingFactIDs: [fact.id], outcome: .unresolved)
        }
        let claims = facts.map { EvaluationClaimReview(factID: $0.id, supportedByCitedSources: true) }
        let score = try FidelityEvaluator.score(fixture: fixture, facts: facts, factReviews: reviews, claimReviews: claims)
        #expect(score.criticalFactRecall == 0)
        #expect(score.sourceReferenceAccuracy == 1)
        #expect(score.missingLiteralProbes.isEmpty)
        #expect(score.explicitReversalErrorIDs == ["cache-reversal"])
        #expect(score.wrongSupersessionIDs == ["cache-reversal"])
    }
}
