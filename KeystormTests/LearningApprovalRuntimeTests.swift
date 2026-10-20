import Foundation
import Testing
@testable import Keystorm

/// Actual local model + production approval-required repository, using fixed DEV text.
/// No microphone, external insertion, or held-out accuracy claim.
struct LearningApprovalRuntimeTests {
    @Test("Actual local AI candidates require approval before English/German reuse",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_LEARNING_APPROVAL"] == "1"),
          .timeLimit(.minutes(10)))
    func installedModelReviewApproveAndReopen() async throws {
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
            let app = "org.keystorm.approval.runtime"
            for (index, pair) in [
                ("The Kubernettes deployment is ready.", "The Kubernetes deployment is ready."),
                ("Bitte den Datenshutz für die Anwendung prüfen.", "Bitte den Datenschutz für die Anwendung prüfen.")
            ].enumerated() {
                let url = root.appendingPathComponent("case-\(index).json")
                let repository = try LearningRepository(url: url)
                try await repository.setEnabled(true)
                for _ in 0..<2 {
                    let source = DictationTextRevision(rawText: pair.0, text: pair.0, sourceTranscriptIDs: [])
                    let edited = DictationTextRevision(rawText: pair.0, text: pair.1, sourceTranscriptIDs: [])
                    let evidence = try #require(CorrectionLearningPolicy.evidence(source: source, edited: edited,
                        sessionID: UUID(), takeID: UUID(), appBundleID: app))
                    try #require(try await repository.enqueue(evidence))
                    let request = CorrectionClassificationRequest(evidence: evidence, configuration: configuration)
                    let classification = try await client.classifyCorrection(request)
                    try CorrectionLearningPolicy.validate(classification, request: request)
                    try await repository.classify(.init(request: request, result: classification))
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
            Attachment.record(try encoder.encode(results), named: "learning-approval-actual-model.json")
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }
}
