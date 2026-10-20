import Foundation
import Testing
@testable import Keystorm

@MainActor
struct ExternalCorrectionLearningTests {
    @Test func legacyEvidenceDigestAndReceiptRemainByteCompatible() throws {
        let evidence = try LearningFixture.evidence()
        #expect(evidence.origin == nil)
        #expect(evidence.sha256 == legacyDigest(evidence))
        let encoded = try JSONEncoder().encode(evidence)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["origin"] == nil)
        let decoded = try JSONDecoder().decode(CorrectionEvidence.self, from: encoded)
        #expect(decoded.origin == nil)
        #expect(decoded.sha256 == legacyDigest(evidence))
        var receipt = LearningFixture.receipt(decoded)
        receipt.result.promptTemplateVersion = 3
        receipt.result.promptTemplateSHA256 = CorrectionLearningPolicy.legacyV2PromptSHA256
        let restored = try JSONDecoder().decode(CorrectionClassificationReceipt.self, from: JSONEncoder().encode(receipt))
        try CorrectionLearningPolicy.validateHistorical(restored.result, request: restored.request)
        #expect(restored.result.evidenceSHA256 == legacyDigest(evidence))
    }

    @Test func provenanceIsBoundAndCannotBeForgedIntoAnOldReceipt() throws {
        let evidence = try externalEvidence()
        let origin = try #require(evidence.origin)
        #expect(origin.kind == .destinationObservation)
        #expect(origin.sourceClassification == .deliveredPassage)
        #expect(origin.attribution == .unverified)
        var unmarked = evidence
        unmarked.origin = nil
        #expect(unmarked.sha256 != evidence.sha256)
        let receipt = LearningFixture.receipt(evidence)
        try CorrectionLearningPolicy.validate(receipt.result, request: receipt.request)
        var forged = receipt
        forged.request.evidence.origin?.deliveryID = UUID()
        #expect(throws: CorrectionLearningError.invalidClassification) {
            try CorrectionLearningPolicy.validate(forged.result, request: forged.request)
        }
        forged = receipt
        forged.request.evidence.origin?.observedAt.addTimeInterval(1)
        #expect(throws: CorrectionLearningError.invalidClassification) {
            try CorrectionLearningPolicy.validate(forged.result, request: forged.request)
        }
        #expect(evidence.userPayload.contains("unverified"))
        #expect(!evidence.userPayload.contains(origin.deliveryID.uuidString))
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func bothOptInsAreRequiredBeforeCollection(flags: (Bool, Bool)) async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"),
            lexicalAssessor: LearningFixture.lexicalAssessor)
        var classified = 0
        let controller = LearningDictionaryController(repository: repository) { evidence in
            classified += 1
            return LearningFixture.receipt(evidence)
        }
        await controller.refresh()
        #expect(!controller.externalCorrectionsEnabled)
        await controller.setEnabled(flags.0)
        await controller.setExternalCorrectionsEnabled(flags.1)
        let source = sourceRevision()
        let original = source
        await controller.submitExternal(source: source, correctedText: "Compile Swift in Xcode.",
            sessionID: UUID(), takeID: UUID(), appBundleID: "com.apple.TextEdit",
            deliveryID: UUID(), observedAt: Date())
        await controller.waitUntilSettled()
        let snapshot = await repository.snapshot()
        #expect(snapshot.evidence.count == (flags.0 && flags.1 ? 1 : 0))
        #expect(classified == (flags.0 && flags.1 ? 1 : 0))
        #expect(source == original)
    }

    @Test func repeatedObservationIsIdempotentAndNeverActivatesBeforeApproval() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        var calls = 0
        let controller = LearningDictionaryController(repository: repository) { evidence in
            calls += 1
            return LearningFixture.receipt(evidence)
        }
        await controller.refresh()
        await controller.setEnabled(true)
        await controller.setExternalCorrectionsEnabled(true)
        let source = sourceRevision(), session = UUID(), take = UUID(), delivery = UUID()
        let observed = Date()
        for time in [observed, observed.addingTimeInterval(1)] {
            await controller.submitExternal(source: source, correctedText: "Compile Swift in Xcode.",
                sessionID: session, takeID: take, appBundleID: "com.apple.TextEdit",
                deliveryID: delivery, observedAt: time)
            await controller.waitUntilSettled()
        }
        #expect(calls == 1)
        let snapshot = await repository.snapshot()
        #expect(snapshot.evidence.count == 1)
        #expect(snapshot.evidence.first?.evidence.origin?.observedAt == observed)
        let entry = try #require(snapshot.terms.first)
        #expect(entry.status == .review)
        #expect(controller.originSummaries[entry.id] == .destinationObservation)
        #expect((await controller.suggestions(for: source.text, appBundleID: "com.apple.TextEdit")).isEmpty)
        let reopened = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        #expect((await reopened.snapshot()).externalCorrectionsEnabled)
        #expect((await reopened.snapshot()).terms.first?.status == .review)
        await controller.approve(id: entry.id)
        let suggestions = await controller.suggestions(for: source.text, appBundleID: "com.apple.TextEdit")
        #expect(LearnedTermApplicator.apply(suggestions: suggestions, to: source.text).text == "Compile Swift in Xcode.")
        #expect((await controller.suggestions(for: source.text, appBundleID: "com.example.Other")).isEmpty)
    }

    @Test func externalChangesDoNotDisableOrRevokeAnExistingApproval() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"),
            lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        let saved = try LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode.")
        _ = try await repository.enqueue(saved)
        let id = try #require((await repository.snapshot()).terms.first?.id)
        try await repository.approve(id: id)
        let controller = LearningDictionaryController(repository: repository) { LearningFixture.receipt($0) }
        await controller.refresh()
        await controller.setExternalCorrectionsEnabled(true)
        let applied = DictationTextRevision(rawText: "Compile swifft in Xcode.",
            text: "Compile Swift in Xcode.", sourceTranscriptIDs: [], appliedLearnedTermIDs: [id])
        await controller.submitExternal(source: applied, correctedText: "Compile swifft in Xcode.",
            sessionID: UUID(), takeID: UUID(), appBundleID: "com.apple.TextEdit",
            deliveryID: UUID(), observedAt: Date())
        await controller.waitUntilSettled()
        await controller.submitExternal(source: sourceRevision(), correctedText: "Compile Swifty in Xcode.",
            sessionID: UUID(), takeID: UUID(), appBundleID: "com.apple.TextEdit",
            deliveryID: UUID(), observedAt: Date())
        await controller.waitUntilSettled()
        let snapshot = await repository.snapshot()
        let original = try #require(snapshot.terms.first(where: { $0.id == id }))
        #expect(original.status == .approved)
        #expect(original.hasRejectedAppliedCorrection != true)
        #expect(original.negativeCount == 0)
        let observation = try #require(snapshot.evidence.first(where: { $0.evidence.origin != nil })?.evidence)
        #expect(try await !repository.rejectReversal(observation, appliedTermIDs: [id]))
        #expect((await repository.snapshot()).terms.first(where: { $0.id == id })?.status == .approved)
    }

    @Test func collectionRejectsUnsupportedUnboundedAndSensitivePassages() {
        let source = sourceRevision()
        func candidate(_ corrected: String, app: String = "com.apple.TextEdit", at: Date = Date()) -> CorrectionEvidence? {
            ExternalCorrectionEvidencePolicy.evidence(source: source, correctedText: corrected,
                sessionID: UUID(), takeID: UUID(), appBundleID: app, deliveryID: UUID(), observedAt: at)
        }
        #expect(candidate("Compile Swift in Xcode.", app: "com.apple.Terminal") == nil)
        #expect(candidate("Compile Swift in Xcode.", at: Date().addingTimeInterval(3600)) == nil)
        #expect(candidate("Compile Swift in Xcode.", at: Date().addingTimeInterval(-901)) == nil)
        #expect(candidate(String(repeating: "a", count: CorrectionLearningPolicy.maxTranscriptUTF8 + 1)) == nil)
        #expect(candidate("Compile Swift in Xcode!") == nil)
        let secret = DictationTextRevision(rawText: "The passphrase is swifft.",
            text: "The passphrase is swifft.", sourceTranscriptIDs: [])
        #expect(ExternalCorrectionEvidencePolicy.evidence(source: secret, correctedText: "The passphrase is Swift.",
            sessionID: UUID(), takeID: UUID(), appBundleID: "com.apple.TextEdit",
            deliveryID: UUID(), observedAt: Date()) == nil)
    }

    @Test(arguments: [false, true])
    func aConsentCycleCannotCommitAnOldExternalClassification(global: Bool) async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"),
            lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        try await repository.setExternalCorrectionsEnabled(true)
        let evidence = try externalEvidence()
        let token = try #require(await repository.classificationConsent(for: evidence))
        #expect(try await repository.enqueue(evidence, consentGeneration: token))
        if global {
            try await repository.setEnabled(false); try await repository.setEnabled(true)
        } else {
            try await repository.setExternalCorrectionsEnabled(false)
            try await repository.setExternalCorrectionsEnabled(true)
        }
        try await repository.classify(LearningFixture.receipt(evidence), consentGeneration: token)
        #expect((await repository.snapshot()).evidence.first?.receipt == nil)
    }

    @Test func cancelledActorSubmissionCannotPublishEvidence() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"),
            lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        try await repository.setExternalCorrectionsEnabled(true)
        let evidence = try externalEvidence()
        let token = try #require(await repository.classificationConsent(for: evidence))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.enqueue(evidence, consentGeneration: token)
        }
        #expect(try await !task.value)
        #expect((await repository.snapshot()).evidence.isEmpty)
    }

    @Test func consentObserversAreImmediateAndCancelable() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("learning.json"),
            lexicalAssessor: LearningFixture.lexicalAssessor)
        let controller = LearningDictionaryController(repository: repository) { LearningFixture.receipt($0) }
        await controller.refresh()
        let initial = controller.externalCorrectionConsentGeneration
        var calls = 0
        let token = controller.observeExternalCorrectionConsentChanges {
            calls += 1
            #expect(controller.externalCorrectionConsentGeneration != initial)
        }
        await controller.setEnabled(true)
        await controller.setExternalCorrectionsEnabled(true)
        #expect(calls == 2)
        token.cancel(); token.cancel()
        await controller.setExternalCorrectionsEnabled(false)
        #expect(calls == 2)
    }

    @Test func existingPolicy4Receipt3AndMissingExternalFlagRoundTrip() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for _ in 0..<2 {
            let evidence = try LearningFixture.evidence()
            _ = try await repository.enqueue(evidence)
            try await repository.classify(LearningFixture.receipt(evidence))
        }
        var snapshot = await repository.snapshot()
        for index in snapshot.evidence.indices {
            snapshot.evidence[index].receipt?.result.promptTemplateVersion = 3
            snapshot.evidence[index].receipt?.result.promptTemplateSHA256 = CorrectionLearningPolicy.legacyV2PromptSHA256
        }
        let original = snapshot
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "externalCorrectionsEnabled")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        let reopened = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        let restored = await reopened.snapshot()
        #expect(!restored.externalCorrectionsEnabled)
        #expect(restored.evidence == original.evidence)
        #expect(restored.terms == original.terms)
        #expect(restored.terms.first?.status == .review)
    }

    private func sourceRevision() -> DictationTextRevision {
        DictationTextRevision(rawText: "Compile swifft in Xcode.", text: "Compile swifft in Xcode.", sourceTranscriptIDs: [])
    }

    private func externalEvidence() throws -> CorrectionEvidence {
        try #require(ExternalCorrectionEvidencePolicy.evidence(source: sourceRevision(),
            correctedText: "Compile Swift in Xcode.", sessionID: UUID(), takeID: UUID(),
            appBundleID: "com.apple.TextEdit", deliveryID: UUID(), observedAt: Date()))
    }

    private func legacyDigest(_ value: CorrectionEvidence) -> String {
        struct Legacy: Encodable {
            let id: UUID; let sessionID: UUID; let takeID: UUID
            let sourceOutputID: UUID; let editedOutputID: UUID
            let appBundleID: String?; let variant: String; let canonical: String
            let leftContext: String; let rightContext: String
            let sourceSHA256: String; let editedSHA256: String
        }
        let payload = Legacy(id: value.id, sessionID: value.sessionID, takeID: value.takeID,
            sourceOutputID: value.sourceOutputID, editedOutputID: value.editedOutputID,
            appBundleID: value.appBundleID, variant: value.variant, canonical: value.canonical,
            leftContext: value.leftContext, rightContext: value.rightContext,
            sourceSHA256: value.sourceSHA256, editedSHA256: value.editedSHA256)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return DictationTransformPolicy.sourceDigest(String(decoding: (try? encoder.encode(payload)) ?? Data(), as: UTF8.self))
    }
}
