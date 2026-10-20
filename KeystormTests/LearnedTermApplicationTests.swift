import Foundation
import Testing
@testable import Keystorm

struct LearnedTermApplicationTests {
    @Test func repeatedOwnCorrectionsNeedApprovalBeforeQualifiedFutureApplication() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for _ in 0..<2 {
            let evidence = try LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode.")
            _ = try await repository.enqueue(evidence)
            try await repository.classify(LearningFixture.receipt(evidence))
        }
        #expect((await repository.snapshot()).terms.first?.status == .review)
        #expect((await repository.suggestions(for: "Compile swifft in Xcode.", appBundleID: nil)).isEmpty)
        let id = try #require((await repository.snapshot()).terms.first?.id)
        try await repository.approve(id: id)
        let heldOut = "In Xcode, compile swifft carefully."
        let suggestions = await repository.suggestions(for: heldOut, appBundleID: nil)
        let result = LearnedTermApplicator.apply(suggestions: suggestions, to: heldOut)
        #expect(result.text == "In Xcode, compile Swift carefully.")
        #expect(result.termIDs.count == 1)
        let unrelated = "The bird named swifft flew overhead."
        #expect((await repository.suggestions(for: unrelated, appBundleID: nil)).isEmpty)
        #expect(LearnedTermApplicator.apply(suggestions: suggestions, to: unrelated).text == unrelated)
    }

    @Test func applicationDoesNotBroadenToUnqualifiedOccurrences() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        let evidence = try LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode.")
        _ = try await repository.enqueue(evidence)
        let term = try #require((await repository.snapshot()).terms.first)
        try await repository.approve(id: term.id)
        let gap = String(repeating: " . ", count: 100)
        let text = "Compile swifft in Xcode." + gap + "The bird swifft sings."
        let suggestions = await repository.suggestions(for: text, appBundleID: nil)
        let result = LearnedTermApplicator.apply(suggestions: suggestions, to: text)
        #expect(result.text == "Compile Swift in Xcode." + gap + "The bird swifft sings.")
        #expect(result.termIDs == [term.id])
        #expect((await repository.suggestions(for: "Compile aswifft in Xcode.", appBundleID: nil)).isEmpty)
        #expect((await repository.suggestions(for: "Compile swifft_value in Xcode.", appBundleID: nil)).isEmpty)
        #expect((await repository.suggestions(for: "Compile Swifft in Xcode.", appBundleID: nil)).isEmpty)
    }

    @Test func missingOwnershipChangedSourceAndConflictingCanonicalNeverApply() {
        let text = "Compile swifft in Xcode."
        let range = (text as NSString).range(of: "swifft")
        let span = LearnedTermSpan(utf16Location: range.location, utf16Length: range.length)
        let term = LearnedTermSuggestion(id: UUID(), variant: "swifft", canonical: "Swift",
            language: .english, sourceSHA256: DictationTransformPolicy.sourceDigest(text), qualifiedSpans: [span])
        #expect(LearnedTermApplicator.apply(suggestions: [term], to: text).text == "Compile Swift in Xcode.")
        var missing = term
        missing.qualifiedSpans = nil
        #expect(LearnedTermApplicator.apply(suggestions: [missing], to: text).text == text)
        #expect(LearnedTermApplicator.apply(suggestions: [term], to: text + "!").text == text + "!")
        var conflict = term
        conflict.canonical = "Swifft"
        #expect(LearnedTermApplicator.apply(suggestions: [term, conflict], to: text).text == text)
    }

    @Test func preservesExactBytesOutsideReplacementAndRejectsMalformedOrOverlappingSpans() {
        let text = "ä\r\nCompile swifft in Xcode.\tGrüße e\u{301}!"
        let range = (text as NSString).range(of: "swifft")
        let span = LearnedTermSpan(utf16Location: range.location, utf16Length: range.length)
        let term = LearnedTermSuggestion(id: UUID(), variant: "swifft", canonical: "Swift",
            language: .mixed, sourceSHA256: DictationTransformPolicy.sourceDigest(text), qualifiedSpans: [span])
        let output = LearnedTermApplicator.apply(suggestions: [term], to: text)
        #expect(output.text.utf8.elementsEqual("ä\r\nCompile Swift in Xcode.\tGrüße e\u{301}!".utf8))
        var bad = term
        bad.qualifiedSpans = [LearnedTermSpan(utf16Location: Int.max, utf16Length: 6)]
        #expect(LearnedTermApplicator.apply(suggestions: [bad], to: text).text.utf8.elementsEqual(text.utf8))
        var duplicate = term
        duplicate.qualifiedSpans = [span, span]
        #expect(LearnedTermApplicator.apply(suggestions: [duplicate], to: text).termIDs.isEmpty)
    }

    @Test func capacityAdmissionReservesDeletionAndReversalSlots() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("learning.json")
        var snapshot = LearningDictionarySnapshot()
        snapshot.isEnabled = true
        snapshot.tombstones = (0..<(LearningRepository.maxTombstones - 2)).map { _ in UUID() }
        try JSONEncoder().encode(snapshot).write(to: url)
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        let first = try LearningFixture.evidence()
        #expect(try await repository.enqueue(first))
        await #expect(throws: CorrectionLearningError.storageLimit) {
            try await repository.enqueue(LearningFixture.evidence())
        }
        let term = try #require((await repository.snapshot()).terms.first)
        try await repository.forget(id: term.id)
        #expect((await repository.snapshot()).terms.isEmpty)
        #expect((await repository.snapshot()).evidence.isEmpty)
        #expect((await repository.snapshot()).tombstones.contains(first.id))
    }

    @Test(arguments: ["Swift", "swift"]) @MainActor
    func manualReversalDisablesOriginInsteadOfLearningTheOpposite(appliedSpelling: String) async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for _ in 0..<2 {
            let evidence = try LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode.")
            _ = try await repository.enqueue(evidence)
            try await repository.classify(LearningFixture.receipt(evidence))
        }
        let term = try #require((await repository.snapshot()).terms.first)
        #expect(term.status == .review)
        try await repository.approve(id: term.id)
        #expect((await repository.snapshot()).terms.first?.status == .approved)
        let source = DictationTextRevision(rawText: "Compile swifft in Xcode.", text: "Compile " + appliedSpelling + " in Xcode.",
            sourceTranscriptIDs: [], appliedLearnedTermIDs: [term.id])
        let edited = DictationTextRevision(rawText: source.rawText, text: "Compile swifft in Xcode.", sourceTranscriptIDs: [])
        let controller = LearningDictionaryController(repository: repository) { evidence in
            Issue.record("A user reversal must never be classified as new positive evidence.")
            return LearningFixture.receipt(evidence)
        }
        await controller.refresh()
        await controller.submit(source: source, edited: edited, sessionID: UUID(), takeID: UUID(), appBundleID: nil)
        await controller.waitUntilSettled()
        let snapshot = await repository.snapshot()
        #expect(snapshot.terms.count == 1)
        #expect(snapshot.terms.first?.status == .disabled)
        #expect(snapshot.terms.first?.negativeCount == 1)
        #expect(snapshot.tombstones.contains(edited.id))
        let reopened = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        #expect((await reopened.suggestions(for: "Compile swifft in Xcode.", appBundleID: nil)).isEmpty)
        #expect((await reopened.snapshot()).terms.first?.negativeCount == 1)
    }

    @Test(arguments: [
        "Compile /tmp/swifft.txt in Xcode.",
        "Compile https://example.org/swifft in Xcode.",
        "Compile swifft@example.org in Xcode.",
        "Compile `swifft` in Xcode.",
        "let swifft = 42 // Xcode",
        "Compile C:\\Tools\\swifft in Xcode.",
        "Compile swifft() in Xcode.",
        "Compile swifft[index] in Xcode."
    ])
    func protectedLiteralsCannotBeChanged(text: String) {
        #expect(LearnedTermApplicator.literalRanges(of: "swifft", in: text).isEmpty)
        let range = (text as NSString).range(of: "swifft")
        let term = LearnedTermSuggestion(id: UUID(), variant: "swifft", canonical: "Swift", language: .english,
            sourceSHA256: DictationTransformPolicy.sourceDigest(text),
            qualifiedSpans: [LearnedTermSpan(utf16Location: range.location, utf16Length: range.length)])
        #expect(LearnedTermApplicator.apply(suggestions: [term], to: text).text == text)
    }

    @Test func partialDecomposedGraphemeCannotBeMatchedOrReplaced() {
        let text = "Compile cafe\u{301} in Xcode."
        #expect(LearnedTermApplicator.literalRanges(of: "cafe", in: text).isEmpty)
        let range = (text as NSString).range(of: "cafe")
        let term = LearnedTermSuggestion(id: UUID(), variant: "cafe", canonical: "Caffe", language: .english,
            sourceSHA256: DictationTransformPolicy.sourceDigest(text),
            qualifiedSpans: [LearnedTermSpan(utf16Location: range.location, utf16Length: range.length)])
        let result = LearnedTermApplicator.apply(suggestions: [term], to: text)
        #expect(result.text.utf8.elementsEqual(text.utf8))
        #expect(result.termIDs.isEmpty)
    }

    @Test func retrievalBudgetsAfterRelevanceInsteadOfStarvingLaterMatches() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for index in 0..<24 {
            let suffix = String(UnicodeScalar(97 + index)!)
            let evidence = try LearningFixture.evidence(old: "Compile swifft" + suffix + " in Xcode.",
                new: "Compile Swift" + suffix + " in Xcode.")
            _ = try await repository.enqueue(evidence)
            let term = try #require((await repository.snapshot()).terms.last)
            try await repository.approve(id: term.id)
        }
        let evidence = try LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode.")
        _ = try await repository.enqueue(evidence)
        let relevant = try #require((await repository.snapshot()).terms.last)
        try await repository.approve(id: relevant.id)
        #expect(!(await repository.suggestions(appBundleID: nil)).contains(where: { $0.id == relevant.id }))
        let qualified = await repository.suggestions(for: "Compile swifft in Xcode.", appBundleID: nil)
        #expect(qualified.map(\.id) == [relevant.id])
        #expect(LearnedTermApplicator.apply(suggestions: qualified, to: "Compile swifft in Xcode.").text == "Compile Swift in Xcode.")
    }

    @Test @MainActor func correctionToThirdSpellingDisablesOriginAndKeepsOnlyObservedNewPair() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        for _ in 0..<2 {
            let evidence = try LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode.")
            _ = try await repository.enqueue(evidence)
            try await repository.classify(LearningFixture.receipt(evidence))
        }
        let origin = try #require((await repository.snapshot()).terms.first)
        try await repository.approve(id: origin.id)
        let source = DictationTextRevision(rawText: "Compile swifft in Xcode.", text: "Compile Swift in Xcode.",
            sourceTranscriptIDs: [], appliedLearnedTermIDs: [origin.id])
        let edited = DictationTextRevision(rawText: source.rawText, text: "Compile Swifty in Xcode.", sourceTranscriptIDs: [])
        var classifiedPairs: [(String, String)] = []
        let controller = LearningDictionaryController(repository: repository) { evidence in
            classifiedPairs.append((evidence.variant, evidence.canonical))
            return LearningFixture.receipt(evidence)
        }
        await controller.refresh()
        await controller.submit(source: source, edited: edited, sessionID: UUID(), takeID: UUID(), appBundleID: nil)
        await controller.waitUntilSettled()
        let snapshot = await repository.snapshot()
        #expect(snapshot.terms.first(where: { $0.id == origin.id })?.status == .disabled)
        #expect(snapshot.terms.first(where: { $0.id == origin.id })?.negativeCount == 1)
        let observed = try #require(snapshot.terms.first(where: { $0.id != origin.id }))
        #expect(observed.variant == "Swift")
        #expect(observed.canonical == "Swifty")
        #expect(observed.status == .review)
        #expect(classifiedPairs.count == 1)
        #expect(classifiedPairs.first?.0 == "Swift")
        #expect(!snapshot.terms.contains(where: { $0.variant == "swifft" && $0.canonical == "Swifty" }))
        let reopened = try LearningRepository(url: url, lexicalAssessor: LearningFixture.lexicalAssessor)
        #expect((await reopened.snapshot()).terms.first(where: { $0.id == origin.id })?.status == .disabled)
    }

    @Test func disabledPendingEvidenceIsNotClassified() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"), lexicalAssessor: LearningFixture.lexicalAssessor)
        try await repository.setEnabled(true)
        _ = try await repository.enqueue(LearningFixture.evidence())
        let term = try #require((await repository.snapshot()).terms.first)
        #expect((await repository.pending()).count == 1)
        try await repository.disable(id: term.id)
        #expect((await repository.pending()).isEmpty)
    }
}

