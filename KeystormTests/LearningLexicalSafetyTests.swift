import Foundation
import Testing
@testable import Keystorm

/// Mechanics only. Actual runtime evaluation uses the pinned bundled resources.
struct LearningFixtureLexicalAssessor: CorrectionLexicalAssessing {
    var verdict: CorrectionLexicalVerdict = .notInExclusionLexicon
    func assess(_ evidence: CorrectionEvidence) async -> CorrectionLexicalAssessment {
        CorrectionLexicalAssessment(evidence: evidence, verdict: verdict,
            lexiconSHA256: verdict == .unavailable ? nil : String(repeating: "f", count: 64))
    }
}

struct LearningLexicalSafetyTests {
    @Test func exclusionMembershipIsBoundAndAbsenceIsOnlyAnAdditionalGate() async throws {
        let lexicon = fixtureLexicon()
        let evidence = try LearningFixture.evidence()
        let absent = await lexicon.assess(evidence)
        #expect(absent.verdict == .notInExclusionLexicon)
        #expect(absent.isBound(to: evidence))
        var receipt = LearningFixture.receipt(evidence)
        receipt.result.lexicalAssessment = absent
        #expect(CorrectionLearningPolicy.isAutomaticVote(receipt.result, evidence: evidence))
        receipt.result.classification = .style
        receipt.result.relation = .wording
        #expect(!CorrectionLearningPolicy.isAutomaticVote(receipt.result, evidence: evidence))
        let known = try LearningFixture.evidence(old: "Compile Database in Xcode.", new: "Compile Databasse in Xcode.")
        let assessment = await lexicon.assess(known)
        #expect(assessment.verdict == .knownSourceWord)
        #expect(!assessment.permitsAdditionalAutomaticGate(for: known))
        #expect(!absent.isBound(to: known))
    }

    @Test(arguments: ["decomposed", "duplicate", "unsorted", "missingNewline", "wrongHash", "missing"])
    func malformedOrUnavailableResourcesFailClosed(kind: String) async throws {
        let lexicon = BundledCorrectionLexicon(loader: {
            if kind == "missing" { throw CocoaError(.fileNoSuchFile) }
            var english = "apple\ndatabase\nword\n"
            switch kind {
            case "decomposed": english = "cafe\u{301}\n"
            case "duplicate": english = "apple\napple\n"
            case "unsorted": english = "word\napple\n"
            case "missingNewline": english = "apple"
            default: break
            }
            return (
                BundledCorrectionLexicon.Resource(data: Data(english.utf8),
                    expectedSHA256: kind == "wrongHash" ? String(repeating: "0", count: 64) : DictationTransformPolicy.sourceDigest(english)),
                Self.resource("datenbank\nwort\n")
            )
        })
        let evidence = try LearningFixture.evidence()
        let result = await lexicon.assess(evidence)
        #expect(result.verdict == .unavailable)
        #expect(result.isBound(to: evidence))
        #expect(!result.permitsAdditionalAutomaticGate(for: evidence))
    }

    @Test func missingOrForeignAssessmentCannotAuthorizeAVote() throws {
        let evidence = try LearningFixture.evidence()
        var receipt = LearningFixture.receipt(evidence)
        receipt.result.lexicalAssessment = nil
        #expect(throws: CorrectionLearningError.invalidClassification) {
            try CorrectionLearningPolicy.validate(receipt.result, request: receipt.request)
        }
        let foreign = try LearningFixture.evidence()
        receipt.result.lexicalAssessment = CorrectionLexicalAssessment(evidence: foreign,
            verdict: .notInExclusionLexicon, lexiconSHA256: String(repeating: "f", count: 64))
        #expect(throws: CorrectionLearningError.invalidClassification) {
            try CorrectionLearningPolicy.validate(receipt.result, request: receipt.request)
        }
    }

    @Test(arguments: [CorrectionLexicalVerdict.knownSourceWord, .unavailable])
    func completedLexicalRefusalsWaitForReviewWithoutRetry(verdict: CorrectionLexicalVerdict) async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"),
            lexicalAssessor: LearningFixtureLexicalAssessor(verdict: verdict))
        try await repository.setEnabled(true)
        for _ in 0..<2 {
            let evidence = try LearningFixture.evidence()
            var receipt = LearningFixture.receipt(evidence)
            receipt.result.lexicalAssessment = await LearningFixtureLexicalAssessor(verdict: verdict).assess(evidence)
            _ = try await repository.enqueue(evidence)
            try await repository.classify(receipt)
        }
        #expect((await repository.snapshot()).terms.first?.status == .review)
        #expect((await repository.pending()).isEmpty)
    }

    @Test(arguments: [CorrectionLexicalVerdict.knownSourceWord, .unavailable])
    func unapprovedEvidenceRemainsInactiveAfterRestart(verdict: CorrectionLexicalVerdict) async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        try await learnFixture(in: repository)
        let reopened = try LearningRepository(url: url,
            lexicalAssessor: LearningFixtureLexicalAssessor(verdict: verdict))
        #expect((await reopened.suggestions(for: "Compile swifft in Xcode.", appBundleID: nil)).isEmpty)
    }

    @Test func v2AutomaticVotesMigrateWithoutRewritingReceiptsOrApproval() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        try await learnFixture(in: repository)
        let approvedEvidence = try LearningFixture.evidence(old: "Review custome terminology.", new: "Review custom terminology.")
        _ = try await repository.enqueue(approvedEvidence)
        let approvedID = try #require((await repository.snapshot()).terms.first(where: { $0.variant == "custome" })?.id)
        try await repository.approve(id: approvedID)
        var snapshot = await repository.snapshot()
        snapshot.automaticPolicyVersion = 2
        if let index = snapshot.terms.firstIndex(where: { $0.variant == "swifft" }) {
            snapshot.terms[index].status = .learned
        }
        for index in snapshot.evidence.indices {
            snapshot.evidence[index].receipt?.result.promptTemplateVersion = 2
            snapshot.evidence[index].receipt?.result.promptTemplateSHA256 = CorrectionLearningPolicy.legacyV2PromptSHA256
            snapshot.evidence[index].receipt?.result.lexicalAssessment = nil
        }
        let originalReceipts = snapshot.evidence
        try JSONEncoder().encode(snapshot).write(to: url)
        let migrated = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        #expect((await migrated.snapshot()).terms.first?.status == .review)
        #expect((await migrated.snapshot()).automaticPolicyVersion == 4)
        #expect((await migrated.snapshot()).evidence == originalReceipts)
        #expect((await migrated.snapshot()).terms.first(where: { $0.id == approvedID })?.status == .approved)
        let id = try #require((await migrated.snapshot()).terms.first?.id)
        try await migrated.approve(id: id)
        #expect((await migrated.snapshot()).terms.first?.status == .approved)
    }

    @Test(arguments: ["passphrase", "PRIVATE-KEY", "API_key", "privater Schlüssel", "Kennwörter", "Anmeldedaten",
        "Zugangscode", "Zugriffscode", "Zugangskennwort", "Anmeldecode", "Geheimnummer", "Geheimzahl",
        "Sicherheitsschlüssel", "Sicherheitsschluessel", "Sicherheits-Schlüssel", "Access_Code",
        "secret-number", "securityKey", "RecoveryCode", "Codewörter"])
    func credentialContextIsExcludedAtCollectionAndLiteralApplication(label: String) async throws {
        let old = "Compile swifft in Xcode with " + label + "."
        let edited = old.replacingOccurrences(of: "swifft", with: "Swift")
        let source = DictationTextRevision(rawText: old, text: old, sourceTranscriptIDs: [])
        let output = DictationTextRevision(rawText: old, text: edited, sourceTranscriptIDs: [])
        #expect(CorrectionLearningPolicy.evidence(source: source, edited: output,
            sessionID: UUID(), takeID: UUID(), appBundleID: nil) == nil)
        let ranges = LearnedTermApplicator.literalRanges(of: "swifft", in: old)
        let spans = ranges.map {
            let range = NSRange($0, in: old)
            return LearnedTermSpan(utf16Location: range.location, utf16Length: range.length)
        }
        let suggestion = LearnedTermSuggestion(id: UUID(), variant: "swifft", canonical: "Swift",
            language: .english, sourceSHA256: DictationTransformPolicy.sourceDigest(old), qualifiedSpans: spans)
        #expect(LearnedTermApplicator.apply(suggestions: [suggestion], to: old).text == old)
    }

    @Test func approvedTermStillCannotApplyInCredentialContext() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"),
            lexicalAssessor: LearningFixtureLexicalAssessor(verdict: .knownSourceWord))
        try await repository.setEnabled(true)
        let evidence = try LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode.")
        _ = try await repository.enqueue(evidence)
        let id = try #require((await repository.snapshot()).terms.first?.id)
        try await repository.approve(id: id)
        #expect(!(await repository.suggestions(for: "Compile swifft in Xcode.", appBundleID: nil)).isEmpty)
        #expect((await repository.suggestions(for: "Compile swifft in Xcode with my passphrase.", appBundleID: nil)).isEmpty)
        var sensitive = evidence
        sensitive.id = UUID(); sensitive.editedOutputID = sensitive.id
        sensitive.leftContext = "The private key is "
        #expect(try await !repository.enqueue(sensitive))
    }

    @Test func credentialLabelsDoNotMatchUnrelatedLongerWords() {
        #expect(!CorrectionSensitiveContext.contains("A secretary is reviewing a monkey illustration."))
        #expect(!CorrectionSensitiveContext.contains("The tokenizer accepts several kinds of syntax."))
        #expect(CorrectionSensitiveContext.contains("Der Passwortmanager speichert den Zugang."))
        #expect(CorrectionSensitiveContext.contains("The privateKey belongs to this account."))
    }

    @Test func unapprovedEvidenceNeverProducesApplicationSpans() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"),
            lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        try await learnFixture(in: repository)
        #expect((await repository.snapshot()).terms.first?.positiveSessionCount == 2)
        #expect((await repository.snapshot()).terms.first?.status == .review)
        #expect((await repository.suggestions(appBundleID: nil)).isEmpty)
        #expect((await repository.suggestions(for: "Compile swifft in Xcode.", appBundleID: nil)).isEmpty)
    }

    private static func resource(_ text: String) -> BundledCorrectionLexicon.Resource {
        BundledCorrectionLexicon.Resource(data: Data(text.utf8), expectedSHA256: DictationTransformPolicy.sourceDigest(text))
    }

    private func fixtureLexicon() -> BundledCorrectionLexicon {
        BundledCorrectionLexicon(loader: { (Self.resource("apple\ndatabase\nword\n"), Self.resource("datenbank\nwort\n")) })
    }

    private func learnFixture(in repository: LearningRepository) async throws {
        for _ in 0..<2 {
            let evidence = try LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode.")
            _ = try await repository.enqueue(evidence)
            try await repository.classify(LearningFixture.receipt(evidence))
        }
    }
}

struct BundledLearningLexiconRuntimeTests {
    @Test("The installed bundled lexicon has verified English and German exclusions",
        .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_LEARNING_LEXICON"] == "1"))
    func installedResources() async throws {
        let english = try LearningFixture.evidence(old: "The database project is ready.", new: "The databasse project is ready.")
        let german = try LearningFixture.evidence(old: "Die Datenbank ist bereit.", new: "Die Dattenbank ist bereit.")
        let invented = try LearningFixture.evidence(old: "Compile qzxvqqzxv in Xcode.", new: "Compile qzxvqqzxva in Xcode.")
        let first = await BundledCorrectionLexicon.shared.assess(english)
        let second = await BundledCorrectionLexicon.shared.assess(german)
        let absent = await BundledCorrectionLexicon.shared.assess(invented)
        #expect(first.verdict == .knownSourceWord)
        #expect(second.verdict == .knownSourceWord)
        #expect(absent.verdict == .notInExclusionLexicon)
        #expect(first.lexiconSHA256 == second.lexiconSHA256)
        #expect(first.lexiconSHA256 == absent.lexiconSHA256)
        #expect(first.isBound(to: english))
        #expect(second.isBound(to: german))
        Attachment.record(try JSONEncoder().encode([first, second, absent]),
            named: "bundled-learning-lexicon-probe.json")
    }
}

