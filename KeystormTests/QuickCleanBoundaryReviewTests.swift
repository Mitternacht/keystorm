import Foundation
import Testing
@testable import Keystorm

@MainActor
struct QuickCleanBoundaryReviewTests {
    @Test("Unexpected applied metadata cannot reach an external destination",
          arguments: ReviewApplyFault.allCases)
    func mismatchedAppliedMetadataStopsDelivery(_ fault: ReviewApplyFault) async {
        let rig = ReviewCleanRig()
        rig.backend.applyFault = fault
        await rig.startAndFinish()
        #expect(rig.backend.applyCount == 1)
        #expect(rig.backend.pendingCount == 0)
        #expect(rig.adapter.writeCount == 0)
        #expect(rig.coordinator.state == .ready)
        #expect(rig.backend.metadata.outputHistory?.contains { $0.textRevision == rig.backend.raw } == true)
    }

    @Test("Cancellation keeps committed output but never inserts after an awaited commit",
          arguments: ReviewCommitPoint.allCases)
    func cancellationAcrossCommit(_ point: ReviewCommitPoint) async throws {
        let rig = ReviewCleanRig()
        rig.backend.suspendAt = point
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.backend.waitUntilSuspended()
        try #require(rig.coordinator.canCancel)
        rig.coordinator.cancel()
        #expect(rig.coordinator.isTransitioning)
        rig.backend.release()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writeCount == 0)
        #expect(rig.coordinator.state == .ready)
        #expect(!rig.coordinator.reservesCapture)
        #expect(rig.coordinator.outputMode == rig.backend.metadata.outputMode)
        #expect(rig.coordinator.activeOutputID == rig.backend.metadata.activeOutputID)
        #expect(rig.coordinator.outputVersions == rig.backend.metadata.outputHistory)
        #expect(rig.backend.metadata.textRevision?.rawText == rig.backend.raw.rawText)
        #expect(rig.backend.metadata.outputHistory?.contains { $0.textRevision == rig.backend.raw } == true)
        // Cancellation during an already-started commit may retain a pending intent;
        // replay is forbidden, including restoring and finishing that capture again.
        rig.coordinator.restore(rig.backend.recording)
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writeCount == 0)
    }

    @Test("A receipt save failure never claims that confirmed insertion did not happen")
    func receiptSaveFailurePreservesHonestDeliveryMessage() async {
        let rig = ReviewCleanRig()
        rig.backend.failReceiptSave = true
        await rig.startAndFinish()
        #expect(rig.adapter.writeCount == 1)
        #expect(rig.coordinator.state == .ready)
        #expect(!rig.coordinator.message.localizedCaseInsensitiveContains("nothing was inserted"))
        #expect(rig.coordinator.message.localizedCaseInsensitiveContains("destination") ||
            rig.coordinator.message.localizedCaseInsensitiveContains("insert"))
    }

    @Test("A changed saved revision during the pending intent commit prevents insertion")
    func sourceChangesDuringPendingCommit() async {
        let rig = ReviewCleanRig()
        rig.backend.changeSourceAfterPendingCommit = true
        await rig.startAndFinish()
        #expect(rig.backend.pendingCount == 1)
        #expect(rig.adapter.writeCount == 0)
        #expect(rig.coordinator.state == .ready)
        #expect(rig.backend.metadata.textRevision?.text == "An independently saved correction.")
    }
}

enum ReviewApplyFault: CaseIterable, Sendable {
    case recordingID, outputID, revisionID, text, rawText, transcriptIDs, mode, missingCurrent
}

enum ReviewCommitPoint: CaseIterable, Sendable {
    case beforeApplyCommit, afterApplyCommit, beforePendingCommit, afterPendingCommit
}

@MainActor
private final class ReviewCleanRig {
    let backend = ReviewCleanBackend()
    let adapter = ReviewCleanAdapter()
    let coordinator: DictationCoordinator

    init() {
        let preferences = DictationPreferences()
        preferences.mode = .clean
        coordinator = DictationCoordinator(backend: backend,
            delivery: DictationDeliveryService(adapter: adapter), preferences: preferences)
    }

    func startAndFinish() async {
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        coordinator.finish()
        await coordinator.waitUntilSettled()
    }
}

@MainActor
private final class ReviewCleanBackend: DictationRecordingBackend {
    let recording = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    let raw = DictationTextRevision(rawText: "äh keep 42 Dateien local not tomorrow",
        text: "äh keep 42 Dateien local not tomorrow", sourceTranscriptIDs: [UUID()])
    let configuration = ProcessingConfiguration(modelID: "review-clean-fixture", revision: "fixture",
        runtime: "review deterministic adapter", quantization: "4-bit", thinking: false,
        inputLimit: 4096, outputLimit: 512)
    var metadata: DictationRecordingMetadata
    var applyFault: ReviewApplyFault?
    var suspendAt: ReviewCommitPoint?
    var changeSourceAfterPendingCommit = false
    var failReceiptSave = false
    var applyCount = 0
    var pendingCount = 0
    private var suspended = false
    private var gate: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() { metadata = DictationRecordingMetadata(id: recording.takeID, state: .recording) }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        suspendAt = nil
        gate?.resume()
        gate = nil
    }

    private func pause(at point: ReviewCommitPoint) async {
        guard suspendAt == point else { return }
        await withCheckedContinuation { continuation in
            gate = continuation
            suspended = true
            let ready = waiters
            waiters = []
            ready.forEach { $0.resume() }
        }
        // Deliberately ignore cancellation: a filesystem commit may have completed
        // before the caller learns that cancellation was requested.
    }

    func dictationBegin() async throws -> DictationRecordingHandle { recording }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {}
    func dictationResume(_ handle: DictationRecordingHandle) async throws {}
    func dictationCancel(_ handle: DictationRecordingHandle) async throws { metadata.state = .cancelled }

    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        metadata.textRevision = raw
        metadata.state = .ready
        return raw
    }

    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? {
        handle == recording ? metadata : nil
    }

    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode) async throws -> DictationTransformResult {
        let request = DictationTransformRequest(sourceRevisionID: source.id,
            sourceSHA256: DictationTransformPolicy.sourceDigest(source.text), mode: mode,
            sourceText: source.text, configuration: configuration)
        let result = DictationTransformResult(jobID: request.jobID, sourceRevisionID: source.id,
            sourceSHA256: request.sourceSHA256, mode: mode, text: "Keep 42 Dateien local, not tomorrow.",
            generatedTokens: 15, configurationID: configuration.id,
            promptTemplateVersion: DictationTransformPolicy.templateVersion,
            promptTemplateSHA256: DictationTransformPolicy.promptTemplateSHA256(for: mode))
        try DictationTransformPolicy.validate(result, request: request)
        return result
    }

    func dictationApplyTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                 result: DictationTransformResult) async throws -> DictationRecordingMetadata {
        applyCount += 1
        await pause(at: .beforeApplyCommit)
        try metadata.stageTransform(source: source, result: result)
        await pause(at: .afterApplyCommit)
        var returned = metadata
        switch applyFault {
        case .recordingID: returned.id = UUID()
        case .outputID: returned.activeOutputID = UUID()
        case .revisionID: returned.textRevision?.id = UUID()
        case .text: returned.textRevision?.text = "Send everything now."
        case .rawText: returned.textRevision?.rawText = "An unrelated raw source."
        case .transcriptIDs: returned.textRevision?.sourceTranscriptIDs = [UUID()]
        case .mode: returned.outputMode = .summarize
        case .missingCurrent: returned.textRevision = nil
        case nil: break
        }
        return returned
    }

    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        if delivery?.state == .pending {
            pendingCount += 1
            await pause(at: .beforePendingCommit)
        }
        metadata.state = state
        if let revision { metadata.textRevision = revision }
        if let delivery { metadata.delivery = delivery }
        metadata.failureMessage = failure
        if failReceiptSave, delivery?.state == .inserted {
            throw KeystormError.message("The receipt could not be saved.")
        }
        if delivery?.state == .pending {
            if changeSourceAfterPendingCommit {
                metadata.textRevision = DictationTextRevision(rawText: raw.rawText,
                    text: "An independently saved correction.", sourceTranscriptIDs: raw.sourceTranscriptIDs)
                metadata.activeOutputID = nil
            }
            await pause(at: .afterPendingCommit)
        }
    }
}

@MainActor
private final class ReviewCleanField: DictationDeliveryField {}

@MainActor
private final class ReviewCleanAdapter: DictationDeliveryAdapter {
    let field = ReviewCleanField()
    let application = DictationDeliveryApplication(processIdentifier: 4812,
        bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
    var text = "Existing text "
    var selection = NSRange(location: 14, length: 0)
    var writeCount = 0
    var isTrusted: Bool { true }
    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { application }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField { field }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { lhs === rhs }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        DictationFieldMetadata(processIdentifier: application.processIdentifier, role: "AXTextArea",
            subrole: nil, isEnabled: true, isProtected: false, selectedTextIsSettable: true)
    }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        DictationFieldSnapshot(text: text, selection: selection)
    }
    func replaceSelectedText(_ replacement: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        writeCount += 1
        text = (text as NSString).replacingCharacters(in: selection, with: replacement)
        selection = NSRange(location: selection.location + replacement.utf16.count, length: 0)
        return .accepted
    }
}
