import Foundation
import Testing
@testable import Keystorm

/// Actual local model and external-observation evidence using fixed DEV text.
/// The separate adapter tests cover insertion/events; this is not held-out accuracy evidence.
struct ExternalCorrectionRuntimeTests {
    @Test("Actual destination-origin EN/DE candidates stay Review until approval",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_EXTERNAL_CORRECTIONS"] == "1"),
          .timeLimit(.minutes(10)))
    func installedModelExternalReviewApproveAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Approval-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let client = InferenceWorkerClient(modelDirectory: models)
        struct Result: Codable {
            var before: String
            var approved: String
            var repositoryPolicyVersion: Int
            var receipts: Int
            var classificationReceipts: [CorrectionClassificationReceipt]
            var beforeApproval: String
            var afterApproval: String
            var reopened: String
            var disabled: String
            var forgottenEvidence: Int
        }
        var results: [Result] = []
        do {
            let configuration = try #require(try await client.verifiedConfiguration(for: ModelCatalog.primaryText))
            let app = "com.apple.TextEdit"
            for (index, pair) in [
                ("The Kubernettes deployment is ready.", "The Kubernetes deployment is ready."),
                ("Bitte den Datenshutz für die Anwendung prüfen.", "Bitte den Datenschutz für die Anwendung prüfen.")
            ].enumerated() {
                let url = root.appendingPathComponent("case-\(index).json")
                let repository = try LearningRepository(url: url)
                try await repository.setEnabled(true)
                try await repository.setExternalCorrectionsEnabled(true)
                for _ in 0..<2 {
                    let source = DictationTextRevision(rawText: pair.0, text: pair.0, sourceTranscriptIDs: [])
                    let evidence = try #require(ExternalCorrectionEvidencePolicy.evidence(source: source, correctedText: pair.1,
                        sessionID: UUID(), takeID: UUID(), appBundleID: app,
                        deliveryID: UUID(), observedAt: Date()))
                    #expect(evidence.origin?.attribution == .unverified)
                    let enqueueConsent = try #require(await repository.classificationConsent(for: evidence))
                    try #require(try await repository.enqueue(evidence, consentGeneration: enqueueConsent))
                    let request = CorrectionClassificationRequest(evidence: evidence, configuration: configuration)
                    let classification = try await client.classifyCorrection(request)
                    try CorrectionLearningPolicy.validate(classification, request: request)
                    let consent = try #require(await repository.classificationConsent(for: evidence))
                    try await repository.classify(.init(request: request, result: classification), consentGeneration: consent)
                    #expect(source.rawText == pair.0 && source.text == pair.0)
                }
                let snapshot = await repository.snapshot()
                let term = try #require(snapshot.terms.first)
                #expect(snapshot.terms.count == 1 && term.status == .review)
                #expect(snapshot.evidence.compactMap(\.receipt).count == 2)
                let before = LearnedTermApplicator.apply(
                    suggestions: await repository.suggestions(for: pair.0, appBundleID: app), to: pair.0)
                #expect(before.text == pair.0 && before.termIDs.isEmpty)
                let unapprovedRestart = try LearningRepository(url: url)
                #expect(await unapprovedRestart.suggestions(for: pair.0, appBundleID: app).isEmpty)
                try await repository.approve(id: term.id)
                let applied = LearnedTermApplicator.apply(
                    suggestions: await repository.suggestions(for: pair.0, appBundleID: app), to: pair.0)
                #expect(applied.text == pair.1 && applied.termIDs == [term.id])
                let reopened = try LearningRepository(url: url)
                let afterRestart = LearnedTermApplicator.apply(
                    suggestions: await reopened.suggestions(for: pair.0, appBundleID: app), to: pair.0)
                #expect(afterRestart.text == pair.1)
                #expect(await reopened.suggestions(for: pair.0, appBundleID: "org.keystorm.other").isEmpty)
                try await reopened.disable(id: term.id)
                let disabled = LearnedTermApplicator.apply(
                    suggestions: await reopened.suggestions(for: pair.0, appBundleID: app), to: pair.0)
                #expect(disabled.text == pair.0 && disabled.termIDs.isEmpty)
                try await reopened.forget(id: term.id)
                let forgotten = await reopened.snapshot()
                #expect(forgotten.terms.isEmpty && forgotten.evidence.isEmpty)
                results.append(.init(before: pair.0, approved: pair.1,
                    repositoryPolicyVersion: try #require(snapshot.automaticPolicyVersion),
                    receipts: snapshot.evidence.compactMap(\.receipt).count,
                    classificationReceipts: snapshot.evidence.compactMap(\.receipt),
                    beforeApproval: before.text, afterApproval: applied.text,
                    reopened: afterRestart.text, disabled: disabled.text,
                    forgottenEvidence: forgotten.evidence.count))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            Attachment.record(try encoder.encode(results), named: "external-correction-actual-model.json")
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }
}
