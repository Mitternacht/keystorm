import Foundation
import Testing
@testable import Keystorm

struct CorrectionClassificationRuntimeTests {
    @Test("Installed Qwen classifies fixed terminology and wording-change fixtures",
        .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_LEARNING_CLASSIFIER"] == "1"),
        .timeLimit(.minutes(10)))
    func installedModelCorpus() async throws {
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let client = InferenceWorkerClient(modelDirectory: models)
        struct CaseResult: Codable {
            var name: String
            var expectedTerminology: Bool
            var request: CorrectionClassificationRequest
            var result: CorrectionClassificationResult?
            var error: String?
            var milliseconds: Double
            var generatedEnvelope: String? = nil
        }
        let fixtures: [(String, String, String, Bool)] = [
            ("german-name", "Send die Rechnung to Muller tomorrow.", "Send die Rechnung to Müller tomorrow.", true),
            ("deployment-product", "The Kubernettes deployment is ready.", "The Kubernetes deployment is ready.", true),
            ("database-product", "Query Postgress for the database migration.", "Query Postgres for the database migration.", true),
            ("german-privacy", "Bitte den Datenshutz für die Anwendung prüfen.", "Bitte den Datenschutz für die Anwendung prüfen.", true),
            ("preference-strength", "I like this design.", "I love this design.", false),
            ("tense-grammar", "This pipeline works in production.", "This pipeline worked in production.", false),
            ("tone-wording", "The tone feels calm.", "The tone feels cool.", false),
            ("uncertainty-wording", "This explanation is possible.", "This explanation is plausible.", false)
        ]
        var reports: [CaseResult] = []
        do {
            let config = try #require(try await client.verifiedConfiguration(for: ModelCatalog.primaryText),
                "The pinned Qwen model must already be installed; this test never downloads models.")
            for (name, before, after, positive) in fixtures {
                let source = DictationTextRevision(rawText: before, text: before, sourceTranscriptIDs: [])
                let edited = DictationTextRevision(rawText: before, text: after, sourceTranscriptIDs: [])
                let evidence = try #require(CorrectionLearningPolicy.evidence(source: source, edited: edited,
                    sessionID: UUID(), takeID: UUID(), appBundleID: nil),
                    "The fixed corpus item must reach the real classifier after deterministic filtering.")
                let request = CorrectionClassificationRequest(evidence: evidence, configuration: config)
                let start = ContinuousClock.now
                do {
                    let result = try await client.classifyCorrection(request)
                    try CorrectionLearningPolicy.validate(result, request: request)
                    if positive {
                        #expect(result.classification == .terminology,
                            "The DEV spelling correction should retain its typed model decision.")
                        let lexical = try #require(result.lexicalAssessment,
                            "Current classifications require a bound local lexical assessment.")
                        if lexical.verdict == .knownSourceWord {
                            #expect(!CorrectionLearningPolicy.isAutomaticVote(result, evidence: evidence),
                                "Known source words need review even for an intended spelling correction.")
                        } else {
                            #expect(lexical.verdict == .notInExclusionLexicon,
                                "The bundled exclusion resources must be available in this runtime check.")
                            #expect(CorrectionLearningPolicy.isAutomaticVote(result, evidence: evidence),
                                "Expected a useful spelling vote for an unknown-source DEV fixture \(name)")
                        }
                    } else {
                        #expect(!CorrectionLearningPolicy.isAutomaticVote(result, evidence: evidence),
                            "A wording/grammar fixture must not produce an automatic promotion vote: \(name)")
                    }
                    reports.append(CaseResult(name: name, expectedTerminology: positive,
                        request: request, result: result, error: nil,
                        milliseconds: milliseconds(start.duration(to: .now))))
                } catch {
                    reports.append(CaseResult(name: name, expectedTerminology: positive,
                        request: request, result: nil, error: error.localizedDescription,
                        milliseconds: milliseconds(start.duration(to: .now))))
                    reports[reports.count - 1].generatedEnvelope = (error as? DictationTransformGenerationFailure)?.generatedEnvelope
                    if let envelope = reports.last?.generatedEnvelope { print("DEV_CLASSIFIER_FAILURE", name, envelope) }
                    Issue.record(error, "Actual local classifier failed for \(name)")
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            Attachment.record(try encoder.encode(reports), named: "local-learning-fixed-corpus.json")
            // Fixed compatibility corpus, not a held-out precision or multilingual accuracy claim.
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
}
