import Foundation
import Testing
@testable import Keystorm

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DictationInteractionTests {
    @Test("Legacy capture actions cannot change an active dictation", arguments: [
        DictationFlowState.starting, .recording, .paused, .processing
    ])
    func legacyActionsRespectDictationOwnership(_ state: DictationFlowState) async {
        let rig = InteractionRig()
        await rig.prepare(state)
        let originalHandle = rig.flow.handle
        rig.controller.perform(.toggleRecording)
        rig.controller.perform(.recordEdit)
        rig.controller.shortcuts.onHoldRecording?(true)
        await rig.controller.waitForRecordingControls()
        rig.controller.shortcuts.onHoldRecording?(false)
        await rig.controller.waitForRecordingControls()
        #expect(rig.legacy.calls.isEmpty)
        #expect(rig.legacy.captureIntent == .editBrief)
        #expect(rig.flow.state == state)
        #expect(rig.flow.handle == originalHandle)
        await rig.close()
    }

    @Test("A queued manual shortcut rechecks ownership before touching capture",
          arguments: [ShortcutAction.toggleRecording, .recordEdit])
    func queuedManualActionCannotAcquireDictation(_ action: ShortcutAction) async {
        let rig = InteractionRig()
        rig.controller.perform(action)
        // State becomes starting synchronously, before either queued Task executes.
        rig.flow.toggle()
        #expect(rig.flow.state == .starting)
        await rig.controller.waitForRecordingControls()
        await rig.flow.waitUntilSettled()
        #expect(rig.legacy.calls.isEmpty)
        #expect(rig.flow.state == .recording)
        await rig.close()
    }

    @Test("A queued hold press cannot acquire dictation's paused or starting recorder")
    func queuedHoldStartRechecksOwnership() async {
        let rig = InteractionRig()
        rig.controller.shortcuts.onHoldRecording?(true)
        rig.flow.toggle()
        await rig.controller.waitForRecordingControls()
        await rig.flow.waitUntilSettled()
        rig.controller.shortcuts.onHoldRecording?(false)
        await rig.controller.waitForRecordingControls()
        #expect(rig.legacy.calls.isEmpty)
        #expect(rig.flow.state == .recording)
        await rig.close()
    }

    @Test("Local rewriting reserves capture until its cancelled worker finishes")
    func rewritingBlocksLegacyCaptureUntilSettled() async {
        let rig = InteractionRig()
        await rig.prepare(.recording)
        rig.flow.finish()
        await rig.flow.waitUntilSettled()
        let saved = rig.flow.resultText
        rig.backend.suspended = [.transform]
        rig.flow.prepareTransform(.clean)
        await rig.backend.waitFor(.transform)
        #expect(rig.flow.state == .ready)
        #expect(!rig.flow.hasActiveRecording)
        #expect(rig.flow.isTransforming)
        #expect(rig.flow.reservesCapture)
        #expect(!rig.flow.wantsRecordingHUD)
        rig.controller.perform(.toggleRecording)
        rig.controller.perform(.recordEdit)
        rig.controller.shortcuts.onHoldRecording?(true)
        await rig.controller.waitForRecordingControls()
        rig.controller.shortcuts.onHoldRecording?(false)
        rig.flow.cancelTransform()
        #expect(rig.flow.reservesCapture)
        rig.controller.perform(.toggleRecording)
        rig.controller.shortcuts.onHoldRecording?(true)
        await rig.controller.waitForRecordingControls()
        rig.controller.shortcuts.onHoldRecording?(false)
        #expect(rig.legacy.calls.isEmpty)
        #expect(rig.flow.resultText == saved)
        rig.backend.release(.transform)
        await rig.flow.waitUntilSettled()
        #expect(!rig.flow.reservesCapture)
        #expect(rig.flow.resultText == saved)
        await rig.close()
    }

    @Test("Legacy toggle and edit shortcuts keep their behavior when dictation is inactive")
    func inactiveDictationPreservesManualControls() async {
        let rig = InteractionRig()
        rig.controller.perform(.toggleRecording)
        await rig.controller.waitForRecordingControls()
        #expect(rig.legacy.calls == [.start])
        #expect(rig.legacy.captureIntent == .addMaterial)
        #expect(rig.legacy.isRecording)
        rig.controller.perform(.toggleRecording)
        await rig.controller.waitForRecordingControls()
        #expect(rig.legacy.calls == [.start, .pause])
        #expect(!rig.legacy.isRecording)
        rig.controller.perform(.recordEdit)
        await rig.controller.waitForRecordingControls()
        #expect(rig.legacy.calls.last == .newEdit)
        #expect(rig.legacy.openTake?.intent == .editBrief)
        rig.controller.perform(.recordEdit)
        await rig.controller.waitForRecordingControls()
        #expect(rig.legacy.calls.last == .pause)
        rig.controller.perform(.recordEdit)
        await rig.controller.waitForRecordingControls()
        #expect(rig.legacy.calls.last == .resume)
        #expect(rig.legacy.isRecording)
        await rig.close()
    }

    @Test("Releasing a legacy-owned hold still pauses its recording")
    func inactiveDictationPreservesHoldRelease() async {
        let rig = InteractionRig()
        rig.controller.shortcuts.onHoldRecording?(true)
        await rig.controller.waitForRecordingControls()
        #expect(rig.legacy.calls == [.start])
        #expect(rig.legacy.isRecording)
        rig.controller.shortcuts.onHoldRecording?(false)
        await rig.controller.waitForRecordingControls()
        #expect(rig.legacy.calls == [.start, .pause])
        #expect(!rig.legacy.isRecording)
        await rig.close()
    }

    @Test("A release during pending legacy startup drains that capture after dictation is rejected")
    func releaseDrainsPendingLegacyStartup() async {
        let rig = InteractionRig()
        rig.legacy.suspendStart = true
        rig.controller.shortcuts.onHoldRecording?(true)
        await rig.legacy.waitForStart()
        rig.backend.rejectBegin = true
        rig.flow.toggle()
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .failed)
        rig.controller.shortcuts.onHoldRecording?(false)
        rig.legacy.releaseStart()
        await rig.controller.waitForRecordingControls()
        #expect(rig.legacy.calls == [.start, .pause])
        #expect(!rig.legacy.isRecording)
        await rig.close()
    }
}

@MainActor
private final class InteractionLegacyRecorder: LegacyRecordingBackend {
    enum Call: Equatable { case start, pause, resume, newEdit }
    var isRecording = false
    var isCaptureTransitioning = false
    var captureIntent: CaptureIntent = .editBrief
    var openTake: BriefTake?
    var hasOpenTake: Bool { openTake != nil }
    var calls: [Call] = []
    var suspendStart = false
    private var startGate: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func startRecording() async {
        calls.append(.start)
        isCaptureTransitioning = true
        if suspendStart {
            await withCheckedContinuation { continuation in
                startGate = continuation
                startWaiters.forEach { $0.resume() }
                startWaiters.removeAll()
            }
        }
        if openTake == nil { openTake = BriefTake(intent: captureIntent, expectedRevision: UUID()) }
        openTake?.status = .recording
        isRecording = true
        isCaptureTransitioning = false
    }
    func pauseRecording() async {
        calls.append(.pause)
        isRecording = false
        openTake?.status = .paused
    }
    func resumeRecording() async {
        calls.append(.resume)
        isRecording = true
        openTake?.status = .recording
    }
    func startNewTake(intent: CaptureIntent?) async {
        calls.append(.newEdit)
        openTake = BriefTake(intent: intent ?? captureIntent, expectedRevision: UUID(), status: .recording)
        isRecording = true
    }
    func waitForStart() async {
        if startGate != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func releaseStart() {
        suspendStart = false
        startGate?.resume()
        startGate = nil
    }
}

@MainActor
private final class InteractionDictationBackend: DictationRecordingBackend {
    enum Stage: Hashable { case begin, complete, transform }
    enum Failure: Error { case busy }
    let handle = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    var suspended: Set<Stage> = []
    var rejectBegin = false
    private var entered: Set<Stage> = []
    private var gates: [Stage: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [Stage: [CheckedContinuation<Void, Never>]] = [:]

    func dictationBegin() async throws -> DictationRecordingHandle {
        await enter(.begin)
        if rejectBegin { throw Failure.busy }
        return handle
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {}
    func dictationResume(_ handle: DictationRecordingHandle) async throws {}
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        await enter(.complete)
        return DictationTextRevision(rawText: "Hallo world.", text: "Hallo world.", sourceTranscriptIDs: [])
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? { nil }
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode) async throws -> DictationTransformResult {
        await enter(.transform)
        throw Failure.busy
    }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {}
    func waitFor(_ stage: Stage) async {
        if entered.contains(stage) { return }
        await withCheckedContinuation { waiters[stage, default: []].append($0) }
    }
    func release(_ stage: Stage) {
        suspended.remove(stage)
        gates.removeValue(forKey: stage)?.resume()
    }
    private func enter(_ stage: Stage) async {
        entered.insert(stage)
        if suspended.contains(stage) {
            await withCheckedContinuation { continuation in
                gates[stage] = continuation
                waiters.removeValue(forKey: stage)?.forEach { $0.resume() }
            }
        } else { waiters.removeValue(forKey: stage)?.forEach { $0.resume() } }
    }
}

@MainActor
private struct InteractionRig {
    let workspace: WorkspaceModel
    let legacy = InteractionLegacyRecorder()
    let backend = InteractionDictationBackend()
    let flow: DictationCoordinator
    let controller = AppInteractionController()
    init() {
        workspace = WorkspaceModel(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-Interaction-" + UUID().uuidString))
        flow = DictationCoordinator(backend: backend,
            delivery: DictationDeliveryService(adapter: InteractionUntrustedAdapter()))
        controller.configure(workspace: workspace, showWorkspace: {}, dictation: flow,
                             legacyRecording: legacy, startShortcuts: false)
    }
    func prepare(_ state: DictationFlowState) async {
        if state == .starting { backend.suspended = [.begin] }
        flow.toggle()
        if state == .starting { await backend.waitFor(.begin); return }
        await flow.waitUntilSettled()
        if state == .paused {
            flow.pauseResume()
            await flow.waitUntilSettled()
        } else if state == .processing {
            backend.suspended = [.complete]
            flow.finish()
            await backend.waitFor(.complete)
        }
    }
    func close() async {
        backend.release(.begin)
        backend.release(.complete)
        backend.release(.transform)
        await flow.waitUntilSettled()
        await controller.shutdown()
    }
}

@MainActor
private struct InteractionUntrustedAdapter: DictationDeliveryAdapter {
    var isTrusted: Bool { false }
    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { nil }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField {
        throw InteractionDictationBackend.Failure.busy
    }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { false }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        throw InteractionDictationBackend.Failure.busy
    }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        throw InteractionDictationBackend.Failure.busy
    }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        .rejected
    }
}
