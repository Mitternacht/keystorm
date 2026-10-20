import Foundation
import Testing
@testable import Keystorm

@MainActor
struct LearningControllerTests {
    @Test func savesEvidenceBeforeStartingAIAndCancellationLeavesItPending() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("learning.json")
        let repository = try LearningRepository(url: url)
        let gate = LearningClassifierGate()
        let controller = LearningDictionaryController(repository: repository) { evidence in
            await gate.classify(evidence)
        }
        await controller.setEnabled(true)
        let original = "Please open swifft tomorrow."
        let source = DictationTextRevision(rawText: original, text: original, sourceTranscriptIDs: [])
        let edited = DictationTextRevision(rawText: original, text: "Please open Swift tomorrow.", sourceTranscriptIDs: [])
        await controller.submit(source: source, edited: edited, sessionID: UUID(), takeID: UUID(), appBundleID: nil)
        await gate.waitUntilStarted()
        let saved = try JSONDecoder().decode(LearningDictionarySnapshot.self, from: Data(contentsOf: url))
        #expect(saved.evidence.map { $0.evidence.id } == [edited.id])
        #expect(saved.evidence.first?.receipt == nil)
        controller.cancelPendingClassification()
        gate.release()
        await controller.waitUntilSettled()
        #expect((await repository.pending()).map(\.id) == [edited.id])
        #expect(controller.entries.first?.status == .pending)
        #expect(!controller.isClassifying)

        let restarted = try LearningRepository(url: url)
        #expect((await restarted.pending()).map(\.id) == [edited.id])
        #expect((await restarted.snapshot()).terms.first?.status == .pending)
    }

    @Test func explicitRetryUsesSavedEvidenceWithoutReadingPastTranscripts() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"))
        try await repository.setEnabled(true)
        let evidence = try LearningFixture.evidence()
        _ = try await repository.enqueue(evidence)
        var classifiedIDs: [UUID] = []
        let controller = LearningDictionaryController(repository: repository) { value in
            classifiedIDs.append(value.id)
            return LearningFixture.receipt(value)
        }
        await controller.refresh()
        #expect(classifiedIDs.isEmpty)
        controller.drainPending()
        await controller.waitUntilSettled()
        #expect(classifiedIDs == [evidence.id])
        #expect((await repository.pending()).isEmpty)
        #expect(controller.entries.first?.status == .review)
    }

    @Test func forgettingDuringNonCooperativeAIRejectsLatePublication() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"))
        let gate = LearningClassifierGate()
        let controller = LearningDictionaryController(repository: repository) { evidence in
            await gate.classify(evidence)
        }
        await controller.setEnabled(true)
        let original = "Please open swifft tomorrow."
        let source = DictationTextRevision(rawText: original, text: original, sourceTranscriptIDs: [])
        let edited = DictationTextRevision(rawText: original, text: "Please open Swift tomorrow.", sourceTranscriptIDs: [])
        await controller.submit(source: source, edited: edited, sessionID: UUID(), takeID: UUID(), appBundleID: nil)
        await gate.waitUntilStarted()
        let term = try #require(controller.entries.first)
        await controller.forget(id: term.id)
        gate.release()
        await controller.waitUntilSettled()
        #expect(controller.entries.isEmpty)
        #expect((await repository.snapshot()).evidence.isEmpty)
        #expect((await repository.snapshot()).tombstones == [edited.id])
    }

    @Test func disabledLearningDoesNotQueueOrInvokeAI() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"))
        var calls = 0
        let controller = LearningDictionaryController(repository: repository) { evidence in
            calls += 1
            return LearningFixture.receipt(evidence)
        }
        await controller.refresh()
        let original = "Please open swifft tomorrow."
        await controller.submit(source: DictationTextRevision(rawText: original, text: original, sourceTranscriptIDs: []),
            edited: DictationTextRevision(rawText: original, text: "Please open Swift tomorrow.", sourceTranscriptIDs: []),
            sessionID: UUID(), takeID: UUID(), appBundleID: nil)
        controller.drainPending()
        await controller.waitUntilSettled()
        #expect(calls == 0)
        #expect((await repository.snapshot()).evidence.isEmpty)
    }
}

@MainActor
private final class LearningClassifierGate {
    private var continuation: CheckedContinuation<CorrectionClassificationReceipt, Never>?
    private var evidence: CorrectionEvidence?
    private(set) var started = false

    func classify(_ value: CorrectionEvidence) async -> CorrectionClassificationReceipt {
        evidence = value
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        for _ in 0..<10_000 {
            if started { return }
            await Task.yield()
        }
        Issue.record("The fake local classifier did not start.")
    }

    func release() {
        guard let evidence else { return }
        continuation?.resume(returning: LearningFixture.receipt(evidence))
        continuation = nil
    }
}
