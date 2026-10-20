import Foundation
import Testing
@testable import Keystorm

struct LearningApprovalPolicyTests {
    @Test func formerV3AutomaticCredentialStateMigratesWithoutLosingEvidenceOrApproval() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.json")
        let snapshot = try historicalV3Snapshot()
        let oldReceipts = snapshot.evidence
        let oldTerm = try #require(snapshot.terms.first(where: { $0.status == .learned }))
        let approved = try #require(snapshot.terms.first(where: { $0.status == .approved }))
        #expect(CorrectionSensitiveContext.contains(evidence: snapshot.evidence[0].evidence))
        #expect(!CorrectionSensitiveContext.containsLegacyV3(evidence: snapshot.evidence[0].evidence))
        try JSONEncoder().encode(snapshot).write(to: url)
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        let migrated = await repository.snapshot()
        #expect(migrated.automaticPolicyVersion == 4)
        #expect(migrated.evidence == oldReceipts)
        let current = try #require(migrated.terms.first(where: { $0.id == oldTerm.id }))
        #expect(current.status == .review)
        #expect(current.positiveSessionCount == oldTerm.positiveSessionCount)
        #expect(current.negativeCount == oldTerm.negativeCount)
        #expect(migrated.terms.first(where: { $0.id == approved.id }) == approved)
        #expect(!(await repository.suggestions(appBundleID: nil)).contains(where: { $0.id == oldTerm.id }))
        #expect((await repository.suggestions(for: "Compile swifft in Xcode.", appBundleID: nil)).isEmpty)
        try await repository.setEnabled(true)
        let reopened = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        #expect((await reopened.snapshot()).terms.first(where: { $0.id == oldTerm.id })?.status == .review)
        #expect((await reopened.snapshot()).terms.first(where: { $0.id == oldTerm.id })?.positiveSessionCount == 2)
    }

    @Test func approvedLegacySensitiveEvidenceCannotBecomeAnUnqualifiedHint() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.json")
        let snapshot = try historicalV3Snapshot()
        let id = try #require(snapshot.terms.first(where: { $0.status == .learned })?.id)
        try JSONEncoder().encode(snapshot).write(to: url)
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.approve(id: id)
        #expect((await repository.snapshot()).terms.first(where: { $0.id == id })?.status == .approved)
        #expect(!(await repository.suggestions(appBundleID: nil)).contains(where: { $0.id == id }))
        #expect((await repository.suggestions(for: "Compile swifft in Xcode.", appBundleID: nil)).isEmpty)
    }

    @Test func repeatedSafeCorroborationStaysReviewAcrossRestartUntilApproval() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for _ in 0..<4 {
            let evidence = try LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode.")
            _ = try await repository.enqueue(evidence)
            try await repository.classify(LearningFixture.receipt(evidence, confidence: 1))
        }
        let before = try #require((await repository.snapshot()).terms.first)
        #expect(before.positiveSessionCount == 4)
        #expect(before.status == .review)
        #expect((await repository.suggestions(appBundleID: nil)).isEmpty)
        let reopened = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        #expect((await reopened.snapshot()).terms.first?.status == .review)
        #expect((await reopened.suggestions(for: "Compile swifft in Xcode.", appBundleID: nil)).isEmpty)
        try await reopened.approve(id: before.id)
        let suggestions = await reopened.suggestions(for: "Compile swifft in Xcode.", appBundleID: nil)
        #expect(LearnedTermApplicator.apply(suggestions: suggestions, to: "Compile swifft in Xcode.").text == "Compile Swift in Xcode.")
    }

    @Test func currentStoreCannotSmuggleAFormerAutomaticAuthorization() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.json")
        var snapshot = try historicalV3Snapshot()
        snapshot.automaticPolicyVersion = 4
        try JSONEncoder().encode(snapshot).write(to: url)
        #expect(throws: CorrectionLearningError.unsupportedStore) {
            _ = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        }
    }

    /// Synthetic, valid under the exact frozen v3 rules. This is migration
    /// mechanics evidence and is not a held-out classifier accuracy case.
    private func historicalV3Snapshot() throws -> LearningDictionarySnapshot {
        var snapshot = LearningDictionarySnapshot()
        snapshot.automaticPolicyVersion = 3
        snapshot.isEnabled = true
        var ids: [UUID] = []
        for _ in 0..<2 {
            var evidence = try LearningFixture.evidence()
            evidence.leftContext = "The Xcode Zugangscode uses "
            evidence.rightContext = " during deployment."
            evidence.sourceSHA256 = DictationTransformPolicy.sourceDigest(
                evidence.leftContext + evidence.variant + evidence.rightContext)
            evidence.editedSHA256 = DictationTransformPolicy.sourceDigest(
                evidence.leftContext + evidence.canonical + evidence.rightContext)
            var receipt = LearningFixture.receipt(evidence)
            receipt.result.promptTemplateVersion = 3
            receipt.result.promptTemplateSHA256 = CorrectionLearningPolicy.legacyV2PromptSHA256
            #expect(CorrectionLearningPolicy.isLegacyV3SpellingCorroboration(receipt.result, evidence: evidence))
            ids.append(evidence.id)
            snapshot.evidence.append(LearningEvidenceRecord(evidence: evidence, receipt: receipt))
        }
        snapshot.terms.append(LearnedTerm(variant: "swifft", canonical: "Swift", status: .learned,
            evidenceIDs: ids, positiveSessionCount: 2, language: .english))
        let approved = try LearningFixture.evidence(old: "Review custome terminology.", new: "Review custom terminology.")
        snapshot.evidence.append(LearningEvidenceRecord(evidence: approved))
        snapshot.terms.append(LearnedTerm(variant: approved.variant, canonical: approved.canonical,
            status: .approved, evidenceIDs: [approved.id]))
        return snapshot
    }
}
