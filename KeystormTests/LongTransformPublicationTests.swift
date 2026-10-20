import Foundation
import Testing
@testable import Keystorm

struct LongTransformPublicationTests {
    @Test("A committed long preview can be acknowledged twice without another version")
    func exactRetryIsIdempotent() async throws {
        let fixture = try await publicationFixture()
        var metadata = fixture.metadata
        try metadata.stageLongTransform(source: fixture.source, result: fixture.result)
        let committed = metadata
        try metadata.stageLongTransform(source: fixture.source, result: fixture.result)
        #expect(metadata == committed)
        #expect(metadata.outputHistory?.count == 2)
        #expect(metadata.activeOutputID == fixture.result.jobID)
        #expect(metadata.textRevision?.text.utf8.elementsEqual(fixture.result.text.utf8) == true)
    }

    @Test("Reusing a long job identity with altered output or provenance fails atomically",
          arguments: [0, 1, 2, 3])
    func changedRetryFailsAtomically(field: Int) async throws {
        let fixture = try await publicationFixture()
        var metadata = fixture.metadata
        try metadata.stageLongTransform(source: fixture.source, result: fixture.result)
        let committed = metadata
        var changed = fixture.result
        switch field {
        case 0: changed.outputs[0].text += " BANANA"
        case 1: changed.outputs[0].promptTemplateSHA256 = String(repeating: "a", count: 64)
        case 2: changed.plan.chunks[0].endUTF8 -= 1
        default: changed.generatedTokens += 1
        }
        #expect(throws: (any Error).self) {
            try metadata.stageLongTransform(source: fixture.source, result: changed)
        }
        #expect(metadata == committed)
    }

    @Test("Restoring the original and reapplying the same long job reuses its immutable output")
    func restoredSourceReusesSavedResult() async throws {
        let fixture = try await publicationFixture()
        var metadata = fixture.metadata
        try metadata.stageLongTransform(source: fixture.source, result: fixture.result)
        let history = try #require(metadata.outputHistory)
        let originalOutput = try #require(metadata.textRevision)
        try metadata.selectOutput(id: fixture.source.id)
        #expect(metadata.textRevision == fixture.source)
        try metadata.stageLongTransform(source: fixture.source, result: fixture.result)
        #expect(metadata.outputHistory == history)
        #expect(metadata.activeOutputID == fixture.result.jobID)
        #expect(metadata.textRevision == originalOutput)
        #expect(metadata.outputMode == fixture.result.mode)
    }

    @MainActor
    @Test("A coordinator retries a committed long preview after a lost acknowledgement without another publication")
    func coordinatorCommitThenThrowRetry() async throws {
        let backend = LongPublicationBackend()
        let coordinator = DictationCoordinator(backend: backend)
        coordinator.restore(backend.handle)
        coordinator.prepareTransform(.summarize)
        await coordinator.waitUntilSettled()
        let preview = try #require(coordinator.longTransformPreview)
        coordinator.applyTransformPreview()
        await coordinator.waitUntilSettled()
        #expect(coordinator.hasTransformPreview)
        #expect(coordinator.resultText == backend.source.text)
        #expect(backend.metadata.activeOutputID == preview.jobID)
        #expect(backend.publications == 1)
        coordinator.applyTransformPreview()
        await coordinator.waitUntilSettled()
        #expect(!coordinator.hasTransformPreview)
        #expect(coordinator.resultText == preview.text)
        #expect(backend.applyAttempts == 2 && backend.publications == 1)
        #expect(backend.metadata.outputHistory?.count == 2)
        #expect(backend.metadata.delivery == nil)
        #expect(backend.saveCalls == 0)
    }

    @Test("Mandatory long provenance rejects a near-full archive before any chunk inference",
          .timeLimit(.minutes(1)))
    func impossiblePublicationFailsBeforeModelWork() async throws {
        // 698,000 raw/source bytes fit the previous rough 3x-source byte check,
        // but leave less room than the mandatory 80+ section receipts and plan.
        let source = DictationTextRevision(rawText: String(repeating: "word ", count: 139_600),
            text: String(repeating: "word ", count: 139_600), sourceTranscriptIDs: [UUID()])
        let config = publicationConfiguration()
        let plan = try LongDictationTransformService.plan(source: source, mode: .summarize,
            configuration: config)
        var metadata = DictationRecordingMetadata(id: UUID(), state: .ready)
        metadata.textRevision = source
        let original = metadata
        let worker = PublicationTransformCounter()
        await #expect(throws: DictationTransformError.historyLimit) {
            try metadata.preflightLongTransformHistory(source: source, plan: plan)
            _ = try await LongDictationTransformService.run(source: source, mode: .summarize,
                configuration: config) { request in
                    await worker.record()
                    return publicationOutput(request)
                }
        }
        #expect(await worker.calls == 0)
        #expect(metadata == original)
    }
}

private struct LongPublicationFixture {
    let metadata: DictationRecordingMetadata
    let source: DictationTextRevision
    let result: LongDictationTransformResult
}

private func publicationFixture() async throws -> LongPublicationFixture {
    let text = String(repeating: "Keep die Rechnung local, not online. ", count: 8)
    let source = DictationTextRevision(rawText: text, text: text, sourceTranscriptIDs: [UUID()])
    var metadata = DictationRecordingMetadata(id: UUID(), state: .ready)
    metadata.textRevision = source
    let result = try await LongDictationTransformService.run(source: source, mode: .organize,
        configuration: publicationConfiguration(), chunkUTF8Limit: 64) { publicationOutput($0) }
    return LongPublicationFixture(metadata: metadata, source: source, result: result)
}

private func publicationConfiguration() -> ProcessingConfiguration {
    ProcessingConfiguration(modelID: ModelCatalog.primaryText.id, revision: ModelCatalog.primaryText.revision ?? "",
        runtime: "Long-publication fixture", quantization: "4-bit", inputLimit: 4096, outputLimit: 2048)
}

private func publicationOutput(_ request: DictationTransformRequest) -> DictationTransformResult {
    let text: String
    if request.mode == .organize { text = "- " + request.sourceText }
    else { text = String(request.sourceText.split(whereSeparator: \.isWhitespace).first ?? "word") }
    return DictationTransformResult(jobID: request.jobID, sourceRevisionID: request.sourceRevisionID,
        sourceSHA256: request.sourceSHA256, mode: request.mode, text: text, generatedTokens: 16,
        configurationID: request.configuration.id, promptTemplateVersion: DictationTransformPolicy.templateVersion,
        promptTemplateSHA256: DictationTransformPolicy.promptTemplateSHA256(for: request.mode))
}

private enum LongPublicationFailure: Error { case unsupportedCapture, acknowledgementLost }

@MainActor
private final class LongPublicationBackend: DictationRecordingBackend {
    let handle = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    let source: DictationTextRevision
    var metadata: DictationRecordingMetadata
    var failFirstAcknowledgement = true
    var applyAttempts = 0
    var publications = 0
    var saveCalls = 0

    init() {
        let text = String(repeating: "Keep die Rechnung local, not online. ", count: 400)
        source = DictationTextRevision(rawText: text, text: text, sourceTranscriptIDs: [UUID()])
        metadata = DictationRecordingMetadata(id: handle.takeID, state: .ready, textRevision: source)
    }
    func dictationBegin() async throws -> DictationRecordingHandle { throw LongPublicationFailure.unsupportedCapture }
    func dictationPause(_ handle: DictationRecordingHandle) async throws { }
    func dictationResume(_ handle: DictationRecordingHandle) async throws { }
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        throw LongPublicationFailure.unsupportedCapture
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? {
        handle == self.handle ? metadata : nil
    }
    func dictationLongTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
        mode: DictationOutputMode) async throws -> LongDictationTransformResult {
        try await LongDictationTransformService.run(source: source, mode: mode,
            configuration: publicationConfiguration()) { publicationOutput($0) }
    }
    func dictationApplyLongTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
        result: LongDictationTransformResult) async throws -> DictationRecordingMetadata {
        applyAttempts += 1
        let count = metadata.outputHistory?.count ?? 0
        try metadata.stageLongTransform(source: source, result: result)
        if (metadata.outputHistory?.count ?? 0) > count { publications += 1 }
        if failFirstAcknowledgement {
            failFirstAcknowledgement = false
            throw LongPublicationFailure.acknowledgementLost
        }
        return metadata
    }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
        revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        saveCalls += 1
        throw LongPublicationFailure.unsupportedCapture
    }
}

private actor PublicationTransformCounter {
    private(set) var calls = 0
    func record() { calls += 1 }
}
