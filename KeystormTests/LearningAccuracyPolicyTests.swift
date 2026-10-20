import Foundation
import Testing
@testable import Keystorm

/// Development mechanics only. Independent accuracy cases are kept separately and frozen.
struct LearningAccuracyPolicyTests {
    @Test(arguments: [
        ("Muller", "Müller"), ("Kubernettes", "Kubernetes"),
        ("Postgress", "Postgres"), ("Datenshutz", "Datenschutz"),
        ("swifft", "Swift"), ("recieve", "receive")
    ])
    func admitsNarrowSpellingShape(pair: (String, String)) {
        #expect(CorrectionLearningPolicy.isNarrowSpellingRepair(pair.0, pair.1) ||
            CorrectionLearningPolicy.isDiacriticRepair(pair.0, pair.1))
    }

    @Test(arguments: [
        ("like", "love"), ("works", "worked"), ("calm", "cool"),
        ("possible", "plausible"), ("work", "works"), ("working", "worked"),
        ("schnell", "schneller"), ("freundlich", "freundliche"),
        ("API", "Apfel"), ("swift ui", "SwiftUI"), ("Swift", "swift")
    ])
    func spellingShapeCannotAuthorizeBroadOrGrammaticalChanges(pair: (String, String)) {
        #expect(!CorrectionLearningPolicy.isNarrowSpellingRepair(pair.0, pair.1))
        #expect(!CorrectionLearningPolicy.isDiacriticRepair(pair.0, pair.1))
    }

    @Test func typedDecisionReplacesTheUncalibratedScoreCutoff() throws {
        let evidence = try LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode.")
        var receipt = LearningFixture.receipt(evidence, confidence: 0.10)
        try CorrectionLearningPolicy.validate(receipt.result, request: receipt.request)
        #expect(CorrectionLearningPolicy.isAutomaticVote(receipt.result, evidence: evidence))
        receipt.result.classification = .style
        receipt.result.relation = .wording
        receipt.result.confidence = 1
        try CorrectionLearningPolicy.validate(receipt.result, request: receipt.request)
        #expect(!CorrectionLearningPolicy.isAutomaticVote(receipt.result, evidence: evidence))
    }

    @Test func relationAndClassificationMustAgree() throws {
        let evidence = try LearningFixture.evidence()
        var receipt = LearningFixture.receipt(evidence)
        receipt.result.relation = .wording
        #expect(throws: CorrectionLearningError.invalidClassification) {
            try CorrectionLearningPolicy.validate(receipt.result, request: receipt.request)
        }
        receipt.result.relation = nil
        #expect(throws: CorrectionLearningError.invalidClassification) {
            try CorrectionLearningPolicy.validate(receipt.result, request: receipt.request)
        }
    }

    @Test func repeatedHighScoringWordingCannotAutoPromote() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for _ in 0..<2 {
            let evidence = try LearningFixture.evidence(old: "This is possible for deployment.", new: "This is plausible for deployment.")
            _ = try await repository.enqueue(evidence)
            // Even a model's erroneous terminology classification cannot bypass shape checks.
            try await repository.classify(LearningFixture.receipt(evidence, confidence: 1))
        }
        #expect((await repository.snapshot()).terms.first?.status == .review)
        #expect((await repository.suggestions(for: "A possible deployment.", appBundleID: nil)).isEmpty)
    }

    @Test func repeatedTypedSpellingNeedsApprovalRegardlessOfSelfScore() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for _ in 0..<2 {
            let evidence = try LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode.")
            _ = try await repository.enqueue(evidence)
            try await repository.classify(LearningFixture.receipt(evidence, confidence: 0.10))
        }
        #expect((await repository.snapshot()).terms.first?.status == .review)
        let source = "Compile swifft in Xcode again."
        #expect((await repository.suggestions(for: source, appBundleID: nil)).isEmpty)
        let id = try #require((await repository.snapshot()).terms.first?.id)
        try await repository.approve(id: id)
        let suggestions = await repository.suggestions(for: source, appBundleID: nil)
        #expect(LearnedTermApplicator.apply(suggestions: suggestions, to: source).text == "Compile Swift in Xcode again.")
        #expect((await repository.suggestions(for: "The swifft garden.", appBundleID: nil)).isEmpty)
    }

    @Test func legacyAutomaticDecisionsMigrateToReviewAndApprovalPersists() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for _ in 0..<2 {
            let evidence = try LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode.")
            _ = try await repository.enqueue(evidence)
            try await repository.classify(LearningFixture.receipt(evidence))
        }
        let approvedEvidence = try LearningFixture.evidence(old: "Review custome terminology.", new: "Review custom terminology.")
        _ = try await repository.enqueue(approvedEvidence)
        let approvedID = try #require((await repository.snapshot()).terms.first(where: { $0.variant == "custome" })?.id)
        try await repository.approve(id: approvedID)
        var snapshot = await repository.snapshot()
        snapshot.automaticPolicyVersion = nil
        if let index = snapshot.terms.firstIndex(where: { $0.variant == "swifft" }) {
            snapshot.terms[index].status = .learned
        }
        for index in snapshot.evidence.indices where snapshot.evidence[index].receipt != nil {
            snapshot.evidence[index].receipt?.result.promptTemplateVersion = 1
            snapshot.evidence[index].receipt?.result.promptTemplateSHA256 = String(repeating: "a", count: 64)
            snapshot.evidence[index].receipt?.result.relation = nil
        }
        // The old derived state is internally valid under v1 and must be checked before migration.
        try JSONEncoder().encode(snapshot).write(to: url)
        let migrated = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        let migratedSnapshot = await migrated.snapshot()
        #expect(migratedSnapshot.automaticPolicyVersion == CorrectionLearningPolicy.automaticPolicyVersion)
        #expect(migratedSnapshot.terms.first(where: { $0.variant == "swifft" })?.status == .review)
        #expect(migratedSnapshot.terms.first(where: { $0.id == approvedID })?.status == .approved)
        #expect(migratedSnapshot.evidence.first?.receipt?.result.promptTemplateVersion == 1)
        // A subsequent durable mutation records the migration without discarding historical receipts.
        try await migrated.setEnabled(true)
        let reopened = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        #expect((await reopened.snapshot()).terms == migratedSnapshot.terms)
    }

    @Test func migrationNeverRepairsAnInvalidLegacyDerivedState() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.json")
        var snapshot = LearningDictionarySnapshot()
        snapshot.automaticPolicyVersion = nil
        let evidence = try LearningFixture.evidence()
        snapshot.evidence = [LearningEvidenceRecord(evidence: evidence)]
        snapshot.terms = [LearnedTerm(variant: evidence.variant, canonical: evidence.canonical,
            evidenceIDs: [evidence.id], positiveSessionCount: 9)]
        try JSONEncoder().encode(snapshot).write(to: url)
        #expect(throws: CorrectionLearningError.unsupportedStore) {
            _ = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        }
    }
}


struct LearningLanguageSafetyTests {
    @Test func conflictingGeneratedDecisionsBecomeCompletedUncertainEvidence() async throws {
        let evidence = try LearningFixture.evidence()
        let envelope = CorrectionClassificationEnvelope(complete: true, relation: .wording,
            classification: .terminology, confidence: 0.95, language: .english,
            variant: evidence.variant, canonical: evidence.canonical)
        let decision = CorrectionLearningPolicy.resolvedDecision(envelope)
        #expect(decision.classification == .uncertain)
        #expect(decision.relation == .uncertain)
        #expect(decision.hadConflictingDecision)
        var receipt = LearningFixture.receipt(evidence)
        receipt.result.classification = decision.classification
        receipt.result.relation = decision.relation
        receipt.result.hadConflictingDecision = decision.hadConflictingDecision
        try CorrectionLearningPolicy.validate(receipt.result, request: receipt.request)
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        _ = try await repository.enqueue(evidence)
        try await repository.classify(receipt)
        #expect((await repository.pending()).isEmpty)
        #expect((await repository.snapshot()).terms.first?.status == .review)
        #expect((await repository.snapshot()).evidence.first?.receipt?.result.hadConflictingDecision == true)
    }

    @Test func unknownLanguageCannotVoteOrPromote() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for _ in 0..<2 {
            let evidence = try LearningFixture.evidence()
            var receipt = LearningFixture.receipt(evidence)
            receipt.result.language = .unknown
            #expect(!CorrectionLearningPolicy.isAutomaticVote(receipt.result, evidence: evidence))
            _ = try await repository.enqueue(evidence)
            try await repository.classify(receipt)
        }
        #expect((await repository.snapshot()).terms.first?.positiveSessionCount == 0)
        #expect((await repository.snapshot()).terms.first?.status == .review)
    }

    @Test func differentReceiptLanguagesDemoteInsteadOfUsingLastVote() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for language in [CorrectionLanguage.english, .english, .german] {
            let evidence = try LearningFixture.evidence()
            var receipt = LearningFixture.receipt(evidence)
            receipt.result.language = language
            _ = try await repository.enqueue(evidence)
            try await repository.classify(receipt)
        }
        let term = try #require((await repository.snapshot()).terms.first)
        #expect(term.status == .review)
        #expect(term.positiveSessionCount == 0)
        #expect(term.negativeCount == 3)
        #expect(term.language == .unknown)
        #expect((await repository.suggestions(appBundleID: nil)).isEmpty)
        let reopened = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        #expect((await reopened.snapshot()).terms.first == term)
    }

    @Test(arguments: [false, true])
    func approvedRetrievalRespectsLanguageWithOrWithoutAIReview(approved: Bool) async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for _ in 0..<(approved ? 1 : 2) {
            let evidence = try LearningFixture.evidence(old: "Please compile swifft in the Xcode project.",
                new: "Please compile Swift in the Xcode project.")
            _ = try await repository.enqueue(evidence)
            if !approved { try await repository.classify(LearningFixture.receipt(evidence)) }
        }
        let id = try #require((await repository.snapshot()).terms.first?.id)
        try await repository.approve(id: id)
        let english = "Please compile swifft in the Xcode project again."
        let german = "Bitte kompiliere swifft in diesem Xcode Projekt."
        #expect(!(await repository.suggestions(for: english, appBundleID: nil)).isEmpty)
        #expect((await repository.suggestions(for: german, appBundleID: nil)).isEmpty)
        #expect((await repository.suggestions(for: "Xcode swifft.", appBundleID: nil)).isEmpty)
    }

    @Test func languageScopeIsExplicitAndUnknownFailsClosed() {
        #expect(CorrectionLanguageScope.permits(.english, scope: .english))
        #expect(!CorrectionLanguageScope.permits(.german, scope: .english))
        #expect(CorrectionLanguageScope.permits(.german, scope: .mixed))
        #expect(CorrectionLanguageScope.permits(.english, scope: .mixed))
        #expect(!CorrectionLanguageScope.permits(.unknown, scope: .mixed))
        #expect(!CorrectionLanguageScope.permits(.english, scope: .unknown))
        #expect(CorrectionLanguageScope.recognized(in: "Xcode") == .unknown)
        #expect(CorrectionLanguageScope.recognized(in: "Bonjour, nous travaillons ensemble dans ce projet.") == .unknown)
    }
}

