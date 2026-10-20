import Foundation
import Testing
@testable import Keystorm

struct CorrectionLearningTests {
    @Test func isolatesOneWholeTermAndRetainsProvenance() throws {
        let fixture = try LearningFixture.evidence()
        #expect(fixture.variant == "swifft")
        #expect(fixture.canonical == "Swift")
        #expect(fixture.leftContext == "Please open ")
        #expect(fixture.rightContext == " tomorrow.")
        #expect(fixture.id == fixture.editedOutputID)
        #expect(fixture.sha256.count == 64)
        #expect(fixture.sourceOutputID != fixture.editedOutputID)
        #expect(!fixture.userPayload.contains(fixture.sessionID.uuidString))
    }

    @Test func supportsGermanAndCompoundSegmentation() throws {
        let german = try LearningFixture.evidence(old: "Bitte frag Mülar morgen.", new: "Bitte frag Müller morgen.")
        #expect(german.canonical == "Müller")
        let compound = try LearningFixture.evidence(old: "Open swift ui tomorrow.", new: "Open SwiftUI tomorrow.")
        #expect(compound.variant == "swift ui")
        #expect(compound.canonical == "SwiftUI")
    }

    @Test(arguments: [
        ("Please send 42 tomorrow.", "Please send 43 tomorrow."),
        ("Please send tomorrow.", "Please not send tomorrow."),
        ("Please use nice tomorrow.", "Please use pleasant tomorrow."),
        ("Open https://example.org today.", "Open https://example.com today."),
        ("Use /tmp/voiec.txt today.", "Use /tmp/voice.txt today."),
        ("My password is swifft.", "My password is Swift."),
        ("Open swifft is saft today.", "Open Swift is safe today."),
        ("Open swifft and send now.", "Open Swift and send later."),
        ("Open swifft tomorrow.", "Open tomorrow."),
        ("Please open swifft tomorrow.", "Please open Swift tomorrow!")
    ])
    func rejectsUnsafeOrUnboundedEdits(pair: (String, String)) {
        let old = DictationTextRevision(rawText: pair.0, text: pair.0, sourceTranscriptIDs: [])
        let new = DictationTextRevision(rawText: pair.0, text: pair.1, sourceTranscriptIDs: [])
        #expect(CorrectionLearningPolicy.evidence(source: old, edited: new, sessionID: UUID(), takeID: UUID(),
            appBundleID: nil) == nil)
    }

    @Test func rejectsModelOrForeignSourceChanges() {
        let source = DictationTextRevision(rawText: "raw", text: "Please open swifft.", sourceTranscriptIDs: [])
        let changedRaw = DictationTextRevision(rawText: "different", text: "Please open Swift.", sourceTranscriptIDs: [])
        #expect(CorrectionLearningPolicy.evidence(source: source, edited: changedRaw,
            sessionID: UUID(), takeID: UUID(), appBundleID: nil) == nil)
    }

    @Test func boundsLocalContextWithoutBreakingUTF8() throws {
        let left = String(repeating: "ä", count: 100) + " "
        let evidence = try LearningFixture.evidence(old: left + "swifft tomorrow.", new: left + "Swift tomorrow.")
        #expect(evidence.leftContext.utf8.count <= CorrectionLearningPolicy.maxContextUTF8)
        #expect(evidence.leftContext.hasSuffix(" "))
        #expect(!evidence.leftContext.contains("�"))
    }

    @Test func classificationMustCopyObservedStringsAndIdentityExactly() throws {
        let evidence = try LearningFixture.evidence()
        let receipt = LearningFixture.receipt(evidence)
        try CorrectionLearningPolicy.validate(receipt.result, request: receipt.request)
        var changed = receipt.result
        changed.canonical = "SwiftUI"
        #expect(throws: CorrectionLearningError.invalidClassification) {
            try CorrectionLearningPolicy.validate(changed, request: receipt.request)
        }
        changed = receipt.result
        changed.evidenceSHA256 = String(repeating: "0", count: 64)
        #expect(throws: CorrectionLearningError.invalidClassification) {
            try CorrectionLearningPolicy.validate(changed, request: receipt.request)
        }
        changed = receipt.result
        changed.confidence = .nan
        #expect(throws: CorrectionLearningError.invalidClassification) {
            try CorrectionLearningPolicy.validate(changed, request: receipt.request)
        }
        changed = receipt.result
        changed.generatedTokens = CorrectionLearningPolicy.maxGeneratedTokens
        #expect(throws: CorrectionLearningError.invalidClassification) {
            try CorrectionLearningPolicy.validate(changed, request: receipt.request)
        }
    }
}

struct LearningRepositoryTests {
    @Test func offByDefaultAndIndependentOfManualDictionary() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manual = dir.appendingPathComponent("dictionary.json")
        let original = Data("[{\"canonical\":\"Manual\",\"aliases\":[\"manual\"]}]".utf8)
        try original.write(to: manual)
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        #expect(!(await repository.snapshot()).isEnabled)
        #expect(try await !repository.enqueue(LearningFixture.evidence()))
        #expect(try Data(contentsOf: manual) == original)
    }

    @Test func repeatedSpellingEvidenceStillRequiresExplicitApproval() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        let first = try LearningFixture.evidence()
        #expect(try await repository.enqueue(first))
        try await repository.classify(LearningFixture.receipt(first))
        let repeated = try LearningFixture.evidence(session: first.sessionID)
        #expect(try await repository.enqueue(repeated))
        try await repository.classify(LearningFixture.receipt(repeated))
        #expect((await repository.snapshot()).terms.first?.status == .review)
        let second = try LearningFixture.evidence()
        #expect(try await repository.enqueue(second))
        try await repository.classify(LearningFixture.receipt(second))
        #expect((await repository.snapshot()).terms.first?.status == .review)
        #expect((await repository.snapshot()).terms.first?.positiveSessionCount == 2)
        #expect((await repository.suggestions(appBundleID: nil)).isEmpty)
        let id = try #require((await repository.snapshot()).terms.first?.id)
        try await repository.approve(id: id)
        #expect((await repository.suggestions(appBundleID: nil)).count == 1)
    }

    @Test func negativeAndConflictingEvidenceRequireReview() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for _ in 0..<2 {
            let evidence = try LearningFixture.evidence()
            _ = try await repository.enqueue(evidence)
            try await repository.classify(LearningFixture.receipt(evidence))
        }
        let negative = try LearningFixture.evidence()
        _ = try await repository.enqueue(negative)
        try await repository.classify(LearningFixture.receipt(negative, classification: .style))
        #expect((await repository.snapshot()).terms.first?.status == .review)
        #expect((await repository.suggestions(appBundleID: nil)).isEmpty)

        let conflicting = try LearningFixture.evidence(new: "Please open Swifft tomorrow.")
        _ = try await repository.enqueue(conflicting)
        try await repository.classify(LearningFixture.receipt(conflicting))
        #expect((await repository.snapshot()).terms.allSatisfy { $0.status == .review })
    }

    @Test func explicitApprovalDisableAndForgetPersistAcrossRestart() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        let evidence = try LearningFixture.evidence()
        _ = try await repository.enqueue(evidence)
        let term = try #require((await repository.snapshot()).terms.first)
        try await repository.approve(id: term.id)
        #expect((await repository.suggestions(appBundleID: nil)).count == 1)
        try await repository.disable(id: term.id)
        #expect((await repository.suggestions(appBundleID: nil)).isEmpty)
        try await repository.forget(id: term.id)
        let persisted = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!persisted.contains("swifft"))
        #expect(!persisted.contains("Swift"))
        #expect(!persisted.contains(evidence.sourceSHA256))
        let reopened = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        #expect(try await !reopened.enqueue(evidence))
        #expect((await reopened.snapshot()).terms.isEmpty)
        #expect((await reopened.snapshot()).tombstones == [evidence.id])
    }

    @Test func duplicateEventNeverCountsTwiceAndPendingSurvivesRestart() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        let evidence = try LearningFixture.evidence()
        #expect(try await repository.enqueue(evidence))
        #expect(try await !repository.enqueue(evidence))
        let reopened = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        #expect((await reopened.pending()).map(\.id) == [evidence.id])
        #expect((await reopened.snapshot()).terms.first?.evidenceIDs == [evidence.id])
    }

    @Test func scopedRetrievalIsBoundedAndAmbiguityFailsClosed() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        let evidence = try LearningFixture.evidence(app: "com.example.Editor")
        _ = try await repository.enqueue(evidence)
        let first = try #require((await repository.snapshot()).terms.first)
        try await repository.approve(id: first.id)
        #expect((await repository.suggestions(appBundleID: nil)).isEmpty)
        #expect((await repository.suggestions(appBundleID: "com.example.Editor")).count == 1)
        #expect((await repository.suggestions(appBundleID: "com.example.Editor", tokenBudget: 1)).isEmpty)
        let global = try LearningFixture.evidence(new: "Please open Swifft tomorrow.")
        _ = try await repository.enqueue(global)
        let second = try #require((await repository.snapshot()).terms.first(where: { $0.appBundleID == nil }))
        try await repository.approve(id: second.id)
        #expect((await repository.suggestions(appBundleID: "com.example.Editor")).isEmpty)
        #expect((await repository.suggestions(appBundleID: nil)).count == 1)
    }

    @Test func failedWriteNeverPublishesAnInMemoryCandidate() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("learning.json")
        let setup = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await setup.setEnabled(true)
        let before = try Data(contentsOf: url)
        let repository = try LearningRepository(url: url, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }, lexicalAssessor: LearningFixture.lexicalAssessor)
        let evidence = try LearningFixture.evidence()
        await #expect(throws: (any Error).self) { try await repository.enqueue(evidence) }
        #expect((await repository.snapshot()).terms.isEmpty)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func historicalPromptProvenanceSurvivesTemplateChanges() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        let evidence = try LearningFixture.evidence()
        _ = try await repository.enqueue(evidence)
        var old = LearningFixture.receipt(evidence)
        old.result.promptTemplateVersion = 999
        old.result.promptTemplateSHA256 = String(repeating: "a", count: 64)
        #expect(throws: CorrectionLearningError.invalidClassification) {
            try CorrectionLearningPolicy.validate(old.result, request: old.request)
        }
        try CorrectionLearningPolicy.validateHistorical(old.result, request: old.request)
        var snapshot = await repository.snapshot()
        snapshot.evidence[0].receipt = old
        snapshot.terms[0].positiveSessionCount = 0
        snapshot.terms[0].negativeCount = 1
        snapshot.terms[0].language = .unknown
        snapshot.terms[0].status = .review
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        let reopened = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        let term = try #require((await reopened.snapshot()).terms.first)
        try await reopened.approve(id: term.id)
        #expect((await reopened.suggestions(appBundleID: nil)).count == 1)
        #expect((await reopened.snapshot()).evidence.first?.receipt == old)
    }

    @Test func staleClassificationCannotRestoreForgottenText() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        let evidence = try LearningFixture.evidence()
        _ = try await repository.enqueue(evidence)
        let term = try #require((await repository.snapshot()).terms.first)
        try await repository.forget(id: term.id)
        try await repository.classify(LearningFixture.receipt(evidence))
        #expect((await repository.snapshot()).terms.isEmpty)
        #expect((await repository.snapshot()).evidence.isEmpty)
    }
}

enum LearningFixture {
    static let lexicalAssessor = LearningFixtureLexicalAssessor()
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Learning-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func evidence(old: String = "Please open swifft tomorrow.", new: String = "Please open Swift tomorrow.",
                         session: UUID = UUID(), app: String? = nil) throws -> CorrectionEvidence {
        let source = DictationTextRevision(rawText: old, text: old, sourceTranscriptIDs: [])
        let edited = DictationTextRevision(rawText: old, text: new, sourceTranscriptIDs: [])
        return try #require(CorrectionLearningPolicy.evidence(source: source, edited: edited,
            sessionID: session, takeID: UUID(), appBundleID: app))
    }
    static func receipt(_ evidence: CorrectionEvidence, classification: CorrectionClassification = .terminology,
                        confidence: Double = 0.99) -> CorrectionClassificationReceipt {
        let config = ProcessingConfiguration(modelID: "fixture", revision: "fixture", runtime: "fixture", quantization: "fixture")
        let request = CorrectionClassificationRequest(evidence: evidence, configuration: config)
        let result = CorrectionClassificationResult(jobID: request.jobID, evidenceID: evidence.id,
            evidenceSHA256: evidence.sha256, classification: classification, confidence: confidence,
            language: .english, variant: evidence.variant, canonical: evidence.canonical,
            configurationID: config.id, promptTemplateVersion: CorrectionLearningPolicy.templateVersion,
            promptTemplateSHA256: CorrectionLearningPolicy.promptTemplateSHA256, generatedTokens: 64,
            relation: classification == .terminology ? .sameTermSpelling : classification == .style ? .wording : .uncertain,
            lexicalAssessment: CorrectionLexicalAssessment(evidence: evidence, verdict: .notInExclusionLexicon,
                lexiconSHA256: String(repeating: "f", count: 64)))
        return CorrectionClassificationReceipt(request: request, result: result)
    }
}

