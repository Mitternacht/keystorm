import Foundation
import Testing
@testable import Keystorm

@MainActor
struct DictationCancelTests {
    @Test("Cancel during resume drains capture even when startup completes after the first cancel")
    func cancelWhileResuming() async throws {
        let rig = CancellationRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.pauseResume()
        await rig.coordinator.waitUntilSettled()
        rig.backend.suspended = [.resume]
        defer { rig.backend.releaseAll() }
        rig.coordinator.pauseResume()
        await rig.backend.waitFor(.resume)
        rig.coordinator.cancel()
        // Allow cancellation to observe the in-flight resume without requiring
        // the backend drain to run before startup has finished.
        await Task.yield()
        rig.backend.release(.resume)
        await rig.coordinator.waitUntilSettled()
        #expect(!rig.backend.captureActive)
        #expect(!rig.coordinator.hasActiveRecording)
    }

    @Test("Cancel during startup waits for the capture handle and pauses saved audio")
    func cancelWhileStarting() async throws {
        let rig = CancellationRig()
        rig.backend.suspended = [.begin]
        defer { rig.backend.releaseAll() }
        rig.coordinator.toggle()
        await rig.backend.waitFor(.begin)
        #expect(rig.coordinator.state == .starting)
        #expect(rig.coordinator.canCancel)

        rig.coordinator.cancel()
        rig.coordinator.cancel()
        #expect(rig.backend.pauseCount == 0)
        #expect(rig.adapter.writeCount == 0)
        rig.backend.release(.begin)
        await rig.coordinator.waitUntilSettled()

        #expect(rig.coordinator.handle == rig.backend.recording)
        #expect(rig.backend.metadata?.state == .cancelled)
        #expect(rig.backend.pauseCount == 1)
        #expect(rig.backend.cancelCount == 1)
        #expect(rig.backend.savedAudioIDs == rig.backend.originalAudioIDs)
        #expect(!rig.backend.captureActive)
        #expect(!rig.coordinator.hasActiveRecording)
        #expect(!rig.coordinator.isTransitioning)
        #expect(!rig.coordinator.canCancel)
        #expect(rig.backend.metadata?.delivery == nil)
        #expect(rig.adapter.writeCount == 0)
    }

    @Test("Cancel preserves recording identity and audio without producing or delivering text",
          arguments: [false, true])
    func cancelCapturedAudio(alreadyPaused: Bool) async throws {
        let rig = CancellationRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        let originalHandle = try #require(rig.coordinator.handle)
        if alreadyPaused {
            rig.coordinator.pauseResume()
            await rig.coordinator.waitUntilSettled()
            #expect(rig.coordinator.state == .paused)
        }
        #expect(rig.coordinator.canCancel)

        rig.coordinator.cancel()
        rig.coordinator.cancel()
        await rig.coordinator.waitUntilSettled()

        #expect(rig.coordinator.handle == originalHandle)
        #expect(rig.backend.metadata?.state == .cancelled)
        #expect(rig.backend.metadata?.textRevision == nil)
        #expect(rig.backend.metadata?.delivery == nil)
        #expect(rig.backend.savedAudioIDs == rig.backend.originalAudioIDs)
        #expect(rig.backend.pauseCount == 1)
        #expect(rig.backend.completeCount == 0)
        #expect(rig.backend.cancelCount == 1)
        #expect(!rig.backend.captureActive)
        #expect(!rig.coordinator.hasActiveRecording)
        #expect(!rig.coordinator.isTransitioning)
        #expect(rig.adapter.writeCount == 0)

        rig.coordinator.cancel()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.cancelCount == 1)
        #expect(rig.backend.pauseCount == 1)
        #expect(rig.adapter.writeCount == 0)
    }

    @Test("Cancel cannot claim suppression after an external write is awaiting confirmation")
    func cancelAfterWriteDoesNotMisreportDelivery() async throws {
        let rig = CancellationRig()
        rig.adapter.holdWriteVisibility = true
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.adapter.waitForWrite()

        // The production service has written once, but its next snapshot remains
        // stale until this test releases it. Confirmation is genuinely suspended.
        #expect(rig.coordinator.state == .processing)
        #expect(rig.adapter.writeCount == 1)
        #expect(rig.backend.metadata?.delivery?.state == .pending)
        #expect(!rig.coordinator.canCancel)
        rig.coordinator.cancel()
        #expect(rig.backend.cancelCount == 0)
        #expect(!rig.coordinator.message.localizedCaseInsensitiveContains("cancel"))

        rig.adapter.revealWrittenValue()
        await rig.coordinator.waitUntilSettled()

        #expect(rig.coordinator.state == .ready)
        #expect(!rig.coordinator.isTransitioning)
        #expect(rig.backend.metadata?.state == .ready)
        #expect(rig.backend.metadata?.delivery?.state == .inserted)
        #expect(rig.backend.cancelCount == 0)
        #expect(rig.adapter.writeCount == 1)
        #expect(rig.coordinator.message == "Inserted into TextEdit.")
        #expect(rig.backend.metadata?.delivery?.detail == rig.coordinator.message)
        #expect(rig.adapter.snapshot.text.contains(rig.backend.completedRevision.text))
    }

    @Test("Cancel while processing keeps completed source output and suppresses external delivery",
          arguments: [false, true])
    func cancelWhileProcessing(completionIgnoresCancellation: Bool) async throws {
        let rig = CancellationRig()
        rig.backend.completionIgnoresCancellation = completionIgnoresCancellation
        rig.backend.suspended = [.complete]
        defer { rig.backend.releaseAll() }
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        let originalHandle = try #require(rig.coordinator.handle)
        rig.coordinator.finish()
        await rig.backend.waitFor(.complete)
        #expect(rig.coordinator.state == .processing)
        #expect(rig.coordinator.canCancel)

        rig.coordinator.cancel()
        rig.coordinator.cancel()
        rig.backend.release(.complete)
        await rig.coordinator.waitUntilSettled()

        #expect(rig.coordinator.handle == originalHandle)
        #expect(rig.backend.metadata?.state == .cancelled)
        #expect(rig.backend.savedAudioIDs == rig.backend.originalAudioIDs)
        #expect(rig.backend.cancelCount == 1)
        #expect(rig.backend.completeCount == 1)
        #expect(rig.backend.metadata?.delivery == nil)
        if completionIgnoresCancellation {
            #expect(rig.backend.metadata?.textRevision == rig.backend.completedRevision)
        } else {
            #expect(rig.backend.metadata?.textRevision == nil)
        }
        #expect(!rig.backend.captureActive)
        #expect(!rig.coordinator.hasActiveRecording)
        #expect(!rig.coordinator.isTransitioning)
        #expect(!rig.coordinator.canCancel)
        #expect(rig.adapter.writeCount == 0)

        rig.coordinator.cancel()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.cancelCount == 1)
        #expect(rig.adapter.writeCount == 0)
    }
}

private enum CancellationStage: Hashable { case begin, resume, complete }
private enum CancellationTestFailure: Error { case unexpectedPaste }

@MainActor
private final class CancellationBackend: DictationRecordingBackend {
    let recording = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    let originalAudioIDs = [UUID(), UUID()]
    var savedAudioIDs: [UUID] = []
    let completedRevision = DictationTextRevision(
        rawText: "Please send die Rechnung to Müller, not today.",
        text: "Please send die Rechnung to Müller, not today.",
        sourceTranscriptIDs: [UUID(), UUID()])
    var metadata: DictationRecordingMetadata?
    var captureActive = false
    var pauseCount = 0
    var completeCount = 0
    var cancelCount = 0
    var completionIgnoresCancellation = true
    var suspended: Set<CancellationStage> = []
    private var entered: Set<CancellationStage> = []
    private var gates: [CancellationStage: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [CancellationStage: [CheckedContinuation<Void, Never>]] = [:]

    func waitFor(_ stage: CancellationStage) async {
        if entered.contains(stage) { return }
        await withCheckedContinuation { waiters[stage, default: []].append($0) }
    }

    func release(_ stage: CancellationStage) {
        suspended.remove(stage)
        gates.removeValue(forKey: stage)?.resume()
    }

    func releaseAll() {
        suspended.removeAll()
        let pending = Array(gates.values)
        gates.removeAll()
        for continuation in pending { continuation.resume() }
    }

    private func enter(_ stage: CancellationStage) async {
        entered.insert(stage)
        let ready = waiters.removeValue(forKey: stage) ?? []
        if suspended.contains(stage) {
            await withCheckedContinuation { continuation in
                gates[stage] = continuation
                for waiter in ready { waiter.resume() }
            }
        } else {
            for waiter in ready { waiter.resume() }
        }
    }

    func dictationBegin() async throws -> DictationRecordingHandle {
        // A hardware startup may finish after cancellation. The coordinator must
        // still obtain its handle and drain it rather than abandon capture.
        await enter(.begin)
        savedAudioIDs = originalAudioIDs
        captureActive = true
        metadata = DictationRecordingMetadata(id: recording.takeID, state: .recording)
        return recording
    }

    func dictationPause(_ handle: DictationRecordingHandle) async throws {
        #expect(handle == recording)
        pauseCount += 1
        captureActive = false
        metadata?.state = .paused
    }

    func dictationResume(_ handle: DictationRecordingHandle) async throws {
        #expect(handle == recording)
        await enter(.resume)
        captureActive = true
        metadata?.state = .recording
    }

    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        #expect(handle == recording)
        completeCount += 1
        captureActive = false
        metadata?.state = .processing
        await enter(.complete)
        if !completionIgnoresCancellation { try Task.checkCancellation() }
        // Like the real backend, successful ASR durably saves its output before
        // returning it. Cancellation prevents delivery, not source preservation.
        metadata?.textRevision = completedRevision
        metadata?.state = .ready
        return completedRevision
    }

    func dictationCancel(_ handle: DictationRecordingHandle) async throws {
        #expect(handle == recording)
        cancelCount += 1
        if captureActive { try await dictationPause(handle) }
        try await dictationSave(handle, state: .cancelled, revision: nil, delivery: nil, failure: nil)
    }

    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? {
        handle == recording ? metadata : nil
    }

    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        #expect(handle == recording)
        metadata?.state = state
        if let revision { metadata?.textRevision = revision }
        if let delivery { metadata?.delivery = delivery }
        metadata?.failureMessage = failure
    }
}

@MainActor
private final class CancellationField: DictationDeliveryField {}

/// All target capture and writes stay in this in-memory adapter; the test never
/// reads accessibility state or writes into another application.
@MainActor
private final class CancellationAdapter: DictationDeliveryAdapter {
    var isTrusted = true
    let field = CancellationField()
    var snapshot = DictationFieldSnapshot(text: "Before  After", selection: NSRange(location: 7, length: 0))
    var writeCount = 0
    var holdWriteVisibility = false
    private var heldSnapshot: DictationFieldSnapshot?
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForWrite() async {
        if writeCount > 0 { return }
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    func revealWrittenValue() { heldSnapshot = nil }

    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? {
        DictationDeliveryApplication(processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
    }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField { field }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { lhs === rhs }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        DictationFieldMetadata(processIdentifier: 42, role: "AXTextArea", subrole: nil,
            isEnabled: true, isProtected: false, selectedTextIsSettable: true)
    }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        heldSnapshot ?? snapshot
    }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        writeCount += 1
        if holdWriteVisibility { heldSnapshot = snapshot }
        snapshot.text = (snapshot.text as NSString).replacingCharacters(in: snapshot.selection, with: text)
        snapshot.selection = NSRange(location: snapshot.selection.location + text.utf16.count, length: 0)
        let ready = writeWaiters
        writeWaiters.removeAll()
        for waiter in ready { waiter.resume() }
        return .accepted
    }
    func preparePaste(_ text: String, in field: any DictationDeliveryField,
                      processIdentifier: Int32) throws -> any DictationPasteOperation {
        throw CancellationTestFailure.unexpectedPaste
    }
}

@MainActor
private struct CancellationRig {
    let backend: CancellationBackend
    let adapter: CancellationAdapter
    let coordinator: DictationCoordinator

    init() {
        let backend = CancellationBackend()
        let adapter = CancellationAdapter()
        self.backend = backend
        self.adapter = adapter
        coordinator = DictationCoordinator(backend: backend, delivery: DictationDeliveryService(
            adapter: adapter, ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999))
    }
}
