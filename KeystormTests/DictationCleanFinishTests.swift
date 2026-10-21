import Foundation
import Testing
@testable import Keystorm

@MainActor
@Suite(.serialized)
struct DictationCleanFinishTests {
    @Test("Verbatim is the default and finishing never invokes a text worker")
    func defaultVerbatimDoesNotInvokeTextWorker() async throws {
        let rig = CleanFinishRig()
        #expect(rig.preferences.mode == .verbatim)
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.begunModes == [.verbatim])
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.count(.transform) == 0)
        #expect(rig.backend.count(.apply) == 0)
        #expect(rig.adapter.writes == [rig.backend.source.text])
        #expect(rig.coordinator.resultText == rig.backend.source.text)
        #expect(rig.backend.metadata?.outputHistory == nil)
    }

    @Test("Clean is captured at Start and only its saved output is inserted once")
    func cleanSnapshotPreservesOriginalAndInsertsOnce() async throws {
        let rig = CleanFinishRig(mode: .clean)
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        let handle = try #require(rig.coordinator.handle)
        let focusReadsAtStart = rig.adapter.focusReads
        #expect(focusReadsAtStart > 0)
        rig.preferences.mode = .verbatim
        rig.coordinator.pauseResume()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.pauseResume()
        await rig.coordinator.waitUntilSettled()
        // Pause/resume must retain the original capability without capturing a new target.
        #expect(rig.adapter.focusReads == focusReadsAtStart)
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.begunModes == [.clean])
        #expect(rig.backend.resumedModes == [.clean])
        #expect(rig.backend.count(.transform) == 1)
        #expect(rig.backend.count(.apply) == 1)
        #expect(rig.coordinator.captureMode == .clean)
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.outputMode == .clean)
        #expect(rig.coordinator.resultText == rig.backend.cleanText)
        #expect(rig.adapter.writes == [rig.backend.cleanText])
        #expect(rig.adapter.snapshot.text == "Before " + rig.backend.cleanText + " After")
        let metadata = try #require(rig.backend.metadata)
        let saved = try #require(metadata.textRevision)
        let original = try #require(metadata.outputHistory?.first(where: { $0.mode == .verbatim }))
        #expect(original.textRevision == rig.backend.source)
        #expect(saved.id != rig.backend.source.id)
        #expect(saved.rawText.utf8.elementsEqual(rig.backend.source.rawText.utf8))
        #expect(saved.sourceTranscriptIDs == rig.backend.source.sourceTranscriptIDs)
        #expect(metadata.outputHistory?.count == 2)
        #expect(metadata.activeOutputID == saved.id)
        let pending = try #require(rig.backend.saved.first(where: { $0.delivery?.state == .pending }))
        let receipt = try #require(rig.backend.saved.first(where: { $0.delivery?.state == .inserted }))
        #expect(pending.revision == saved)
        #expect(receipt.revision == saved)
        #expect(pending.delivery?.requestID == receipt.delivery?.requestID)
        #expect(pending.delivery?.textRevisionID == saved.id)
        #expect(receipt.delivery?.textRevisionID == saved.id)
        try expectEvent("complete:durable-raw", before: "transform", in: rig.trace.events)
        try expectEvent("apply:durable-clean", before: "save:pending", in: rig.trace.events)
        try expectEvent("save:pending", before: "write", in: rig.trace.events)
        try expectEvent("write", before: "save:inserted", in: rig.trace.events)
        rig.coordinator.finish()
        rig.coordinator.restore(handle)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writes == [rig.backend.cleanText])
        #expect(rig.coordinator.destinationLabel == "Copy after recording")
        #expect(rig.coordinator.resultText == rig.backend.cleanText)
    }

    @Test("Switching preferences to Clean during Verbatim capture affects only the next recording")
    func preferenceChangeDoesNotUpgradeCurrentCapture() async {
        let rig = CleanFinishRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.preferences.mode = .clean
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.captureMode == .verbatim)
        #expect(rig.backend.count(.transform) == 0)
        #expect(rig.adapter.writes == [rig.backend.source.text])
    }

    @Test("Unavailable Clean preflight prevents microphone capture and does not downgrade to Verbatim")
    func missingModelFailsBeforeCapture() async {
        let rig = CleanFinishRig(mode: .clean)
        rig.backend.preflightFailure = true
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .failed)
        #expect(rig.backend.begunModes == [.clean])
        #expect(rig.backend.microphoneBegins == 0)
        #expect(rig.backend.metadata == nil)
        #expect(rig.backend.count(.complete) == 0)
        #expect(rig.backend.count(.transform) == 0)
        #expect(rig.adapter.writes.isEmpty)
        #expect(rig.coordinator.message == CleanFinishFailure.modelUnavailable.localizedDescription)
    }

    @Test("A protected destination blocks Clean before preflight or microphone capture")
    func protectedTargetBlocksBeforePreflight() async {
        let rig = CleanFinishRig(mode: .clean)
        rig.adapter.protected = true
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.begunModes.isEmpty)
        #expect(rig.backend.microphoneBegins == 0)
        #expect(rig.adapter.writes.isEmpty)
    }

    @Test("Missing Accessibility access still permits Clean recording and a saved copy-only result")
    func cleanWithoutAccessibilityIsCopyOnly() async throws {
        let rig = CleanFinishRig(mode: .clean)
        rig.adapter.isTrusted = false
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.resultText == rig.backend.cleanText)
        #expect(rig.backend.metadata?.outputMode == .clean)
        #expect(rig.adapter.focusReads == 0)
        #expect(rig.adapter.writes.isEmpty)
        #expect(rig.backend.saved.allSatisfy { $0.delivery == nil })
    }

    @Test("Failed local Clean keeps the durable raw transcript and never inserts a fallback",
          arguments: [CleanFinishFault.worker, .malformedIdentity, .changedMeaning, .sourceChanged, .applyPersistence])
    func invalidCleanNeverDelivers(_ fault: CleanFinishFault) async throws {
        let rig = CleanFinishRig(mode: .clean)
        rig.backend.fault = fault
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.resultText == rig.backend.source.text)
        #expect(rig.coordinator.outputMode == .verbatim)
        #expect(rig.adapter.writes.isEmpty)
        #expect(rig.backend.saved.allSatisfy { $0.delivery == nil })
        #expect(rig.backend.metadata?.textRevision?.rawText == rig.backend.source.rawText)
        #expect(rig.backend.metadata?.outputHistory == nil)
        #expect(rig.coordinator.destinationLabel == "Copy after recording")
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writes.isEmpty)
    }

    @Test("A destination changed while Clean runs cannot receive automatic output",
          arguments: [CleanFinishTargetDrift.application, .field, .selection, .text])
    func targetDriftAfterModelWaitDoesNotInsert(_ drift: CleanFinishTargetDrift) async throws {
        let rig = CleanFinishRig(mode: .clean)
        rig.backend.suspended = [.transform]
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        try await rig.backend.observe(.transform)
        rig.adapter.drift(drift)
        rig.backend.release(.transform)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.resultText == rig.backend.cleanText)
        #expect(rig.backend.metadata?.outputMode == .clean)
        #expect(rig.backend.metadata?.delivery?.state == .targetChanged)
        #expect(rig.adapter.writes.isEmpty)
        #expect(rig.backend.count(.transform) == 1)
    }

    @Test("Cancel before delivery suppresses cooperative and late worker results",
          arguments: [CleanFinishCancellation.cooperativeWorker, .lateWorker, .applying, .pendingIntent])
    func cancellationBeforeCommitNeverInserts(_ point: CleanFinishCancellation) async throws {
        let rig = CleanFinishRig(mode: .clean)
        let stage: CleanFinishStage = switch point {
        case .cooperativeWorker, .lateWorker: .transform
        case .applying: .apply
        case .pendingIntent: .pending
        }
        rig.backend.suspended = [stage]
        rig.backend.honorsCancellation = point != .lateWorker
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        try await rig.backend.observe(stage)
        #expect(rig.coordinator.canCancel)
        rig.coordinator.cancel()
        #expect(rig.coordinator.destinationLabel == "Copy after recording")
        // A deliberately suspended worker must be released before joining cancellation.
        rig.backend.release(stage)
        await rig.coordinator.waitUntilSettled()
        #expect(!rig.coordinator.isTransitioning)
        #expect(rig.adapter.writes.isEmpty)
        #expect(rig.backend.metadata?.state == .cancelled)
        #expect(rig.backend.metadata?.textRevision?.rawText == rig.backend.source.rawText)
        #expect(rig.backend.saved.allSatisfy { $0.delivery?.state != .inserted })
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writes.isEmpty)
    }

    @Test("Restored paused Clean recording keeps its saved mode and has no insertion capability")
    func restoredCleanResumesStoredModeAndIsCopyOnly() async throws {
        let rig = CleanFinishRig()
        rig.backend.seedPaused(mode: .clean)
        rig.coordinator.restore(rig.backend.recording)
        #expect(rig.preferences.mode == .verbatim)
        #expect(rig.coordinator.captureMode == .clean)
        #expect(rig.coordinator.state == .paused)
        #expect(rig.adapter.focusReads == 0)
        rig.coordinator.pauseResume()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.begunModes.isEmpty)
        #expect(rig.backend.resumedModes == [.clean])
        #expect(rig.backend.count(.transform) == 1)
        #expect(rig.coordinator.resultText == rig.backend.cleanText)
        #expect(rig.coordinator.captureMode == .clean)
        #expect(rig.adapter.focusReads == 0)
        #expect(rig.adapter.writes.isEmpty)
        #expect(rig.coordinator.destinationLabel == "Copy after recording")
    }

    @Test("Restored Clean cannot resume when its verified text model is no longer available")
    func restoredCleanMissingModelKeepsPausedAudio() async {
        let rig = CleanFinishRig()
        rig.backend.seedPaused(mode: .clean)
        rig.backend.preflightFailure = true
        rig.coordinator.restore(rig.backend.recording)
        rig.coordinator.pauseResume()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .paused)
        #expect(rig.coordinator.captureMode == .clean)
        #expect(rig.backend.metadata?.state == .paused)
        #expect(rig.backend.resumedModes == [.clean])
        #expect(rig.backend.microphoneBegins == 0)
        #expect(rig.backend.count(.transform) == 0)
        #expect(rig.adapter.writes.isEmpty)
    }

    @Test("Legacy paused recordings without a saved mode remain Verbatim")
    func legacyPausedRecordingDoesNotAdoptCleanPreference() async {
        let rig = CleanFinishRig(mode: .clean)
        rig.backend.seedPaused(mode: nil)
        rig.coordinator.restore(rig.backend.recording)
        #expect(rig.coordinator.captureMode == .verbatim)
        rig.coordinator.pauseResume()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.resumedModes == [.verbatim])
        #expect(rig.backend.count(.transform) == 0)
        #expect(rig.coordinator.resultText == rig.backend.source.text)
        #expect(rig.adapter.writes.isEmpty)
    }

    @Test("Long recording ignores Quick Clean, does not inspect a field, and stages its transcript")
    func longRecordingIsVerbatimAndHasNoInsertionCapability() async throws {
        let rig = CleanFinishRig(mode: .clean)
        rig.preferences.contextMode = .nearbyText
        rig.coordinator.startLongRecording()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.recordingPurpose == .longRecording)
        #expect(rig.backend.metadata?.purpose == .longRecording)
        #expect(rig.backend.begunModes == [.verbatim])
        #expect(rig.adapter.focusReads == 0)
        rig.coordinator.pauseResume()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.pauseResume()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.count(.transform) == 0)
        #expect(rig.adapter.writes.isEmpty)
        #expect(rig.coordinator.resultText == rig.backend.source.text)
        #expect(rig.coordinator.state == .ready)
        #expect(rig.backend.saved.allSatisfy { $0.delivery == nil })
    }

    @Test("Saved audio transcription stages output without inheriting an old destination")
    func savedAudioReprocessingNeverDelivers() async throws {
        let rig = CleanFinishRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        let writes = rig.adapter.writes
        #expect(!writes.isEmpty)
        rig.coordinator.retranscribeSavedRecording()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writes == writes)
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.resultText == rig.backend.source.text)
    }

    private func expectEvent(_ first: String, before second: String, in events: [String]) throws {
        let firstIndex = try #require(events.firstIndex(of: first))
        let secondIndex = try #require(events.firstIndex(of: second))
        #expect(firstIndex < secondIndex)
    }
}

enum CleanFinishFault: Sendable { case worker, malformedIdentity, changedMeaning, sourceChanged, applyPersistence }
enum CleanFinishTargetDrift: Sendable { case application, field, selection, text }
enum CleanFinishCancellation: Sendable { case cooperativeWorker, lateWorker, applying, pendingIntent }
private enum CleanFinishStage: String, Hashable { case complete, transform, apply, pending }
private enum CleanFinishFailure: LocalizedError {
    case modelUnavailable, persistence, noCapture
    var errorDescription: String? {
        switch self {
        case .modelUnavailable: "The verified local Clean model is unavailable."
        case .persistence: "The Clean output could not be committed."
        case .noCapture: "This test has no active capture."
        }
    }
}

@MainActor
final class CleanFinishTrace { var events: [String] = [] }

@MainActor
private final class CleanFinishBackend: DictationRecordingBackend {
    struct Saved {
        let revision: DictationTextRevision?
        let delivery: DictationDelivery?
    }
    let recording = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    let source = DictationTextRevision(
        rawText: "äh please keep die Rechnung local not today and keep 42 Dateien",
        text: "äh please keep die Rechnung local not today and keep 42 Dateien",
        sourceTranscriptIDs: [UUID(), UUID()])
    let cleanText = "Please keep die Rechnung local, not today, and keep 42 Dateien."
    let configuration = ProcessingConfiguration(modelID: "clean-finish-fixture", revision: "fixture",
        runtime: "deterministic local adapter", quantization: "4-bit", thinking: false,
        inputLimit: 4_096, outputLimit: 512)
    let trace: CleanFinishTrace
    var metadata: DictationRecordingMetadata?
    var begunModes: [DictationQuickMode] = []
    var resumedModes: [DictationQuickMode] = []
    var microphoneBegins = 0
    var preflightFailure = false
    var fault: CleanFinishFault?
    var suspended: Set<CleanFinishStage> = []
    var honorsCancellation = true
    var saved: [Saved] = []
    private var requests: [UUID: DictationTransformRequest] = [:]
    private var counts: [CleanFinishStage: Int] = [:]
    private var gates: [CleanFinishStage: CheckedContinuation<Void, Never>] = [:]

    init(trace: CleanFinishTrace) { self.trace = trace }

    func seedPaused(mode: DictationQuickMode?) {
        metadata = DictationRecordingMetadata(id: recording.takeID, state: .paused)
        metadata?.captureMode = mode
    }
    func count(_ stage: CleanFinishStage) -> Int { counts[stage, default: 0] }
    func observe(_ stage: CleanFinishStage) async throws {
        for _ in 0..<250 {
            if count(stage) > 0 { return }
            try await Task.sleep(for: .milliseconds(4))
        }
        try #require(count(stage) > 0, "The coordinator did not reach the expected stage.")
    }
    func release(_ stage: CleanFinishStage) {
        suspended.remove(stage)
        gates.removeValue(forKey: stage)?.resume()
    }
    private func enter(_ stage: CleanFinishStage) async {
        counts[stage, default: 0] += 1
        trace.events.append(stage.rawValue)
        if suspended.contains(stage) {
            await withCheckedContinuation { gates[stage] = $0 }
        }
    }
    func dictationSetPurpose(_ handle: DictationRecordingHandle, purpose: DictationRecordingPurpose) async throws {
        metadata?.purpose = purpose
    }
    func dictationBegin(mode: DictationQuickMode) async throws -> DictationRecordingHandle {
        begunModes.append(mode)
        trace.events.append("preflight:" + mode.rawValue)
        if mode == .clean, preflightFailure { throw CleanFinishFailure.modelUnavailable }
        let handle = try await dictationBegin()
        metadata?.captureMode = mode
        return handle
    }
    func dictationBegin() async throws -> DictationRecordingHandle {
        microphoneBegins += 1
        trace.events.append("microphone:begin")
        metadata = DictationRecordingMetadata(id: recording.takeID, state: .recording)
        return recording
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {
        guard handle == recording else { throw CleanFinishFailure.noCapture }
        metadata?.state = .paused
    }
    func dictationResume(_ handle: DictationRecordingHandle) async throws {
        guard handle == recording else { throw CleanFinishFailure.noCapture }
        let mode = metadata?.captureMode ?? .verbatim
        resumedModes.append(mode)
        if mode == .clean, preflightFailure { throw CleanFinishFailure.modelUnavailable }
        metadata?.state = .recording
    }
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        guard handle == recording else { throw CleanFinishFailure.noCapture }
        await enter(.complete)
        try Task.checkCancellation()
        metadata?.state = .ready
        metadata?.textRevision = source
        trace.events.append("complete:durable-raw")
        return source
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? {
        handle == recording ? metadata : nil
    }
    func dictationCancel(_ handle: DictationRecordingHandle) async throws {
        guard handle == recording else { throw CleanFinishFailure.noCapture }
        trace.events.append("cancel")
        metadata?.state = .cancelled
    }
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode) async throws -> DictationTransformResult {
        guard handle == recording, metadata?.textRevision == source, mode == .clean else {
            throw DictationTransformError.staleSource
        }
        let request = DictationTransformRequest(sourceRevisionID: source.id,
            sourceSHA256: DictationTransformPolicy.sourceDigest(source.text), mode: mode,
            sourceText: source.text, configuration: configuration)
        requests[request.jobID] = request
        await enter(.transform)
        if honorsCancellation { try Task.checkCancellation() }
        if fault == .worker { throw CleanFinishFailure.modelUnavailable }
        var result = DictationTransformResult(jobID: request.jobID, sourceRevisionID: source.id,
            sourceSHA256: request.sourceSHA256, mode: .clean,
            text: cleanText, generatedTokens: 32, configurationID: configuration.id,
            promptTemplateVersion: DictationTransformPolicy.templateVersion,
            promptTemplateSHA256: DictationTransformPolicy.promptTemplateSHA256(for: .clean))
        if fault == .malformedIdentity { result.sourceRevisionID = UUID() }
        if fault == .changedMeaning { result.text = cleanText.replacingOccurrences(of: "not today", with: "today") }
        if fault == .sourceChanged {
            metadata?.textRevision?.id = UUID()
        }
        return result
    }
    func dictationApplyTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                 result: DictationTransformResult) async throws -> DictationRecordingMetadata {
        guard handle == recording, let request = requests[result.jobID] else {
            throw DictationTransformError.mismatchedResult
        }
        await enter(.apply)
        try Task.checkCancellation()
        try DictationTransformPolicy.validate(result, request: request)
        if fault == .applyPersistence { throw CleanFinishFailure.persistence }
        guard var next = metadata else { throw DictationTransformError.staleSource }
        try next.stageTransform(source: source, result: result)
        metadata = next
        trace.events.append("apply:durable-clean")
        return next
    }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        guard handle == recording else { throw CleanFinishFailure.noCapture }
        if delivery?.state == .pending {
            await enter(.pending)
            try Task.checkCancellation()
        }
        guard var next = metadata else { throw CleanFinishFailure.noCapture }
        next.state = state
        if let revision { next.textRevision = revision }
        if let delivery { next.delivery = delivery }
        next.failureMessage = failure
        metadata = next
        saved.append(Saved(revision: revision, delivery: delivery))
        if let delivery { trace.events.append("save:" + delivery.state.rawValue) }
    }
}

@MainActor
final class CleanFinishField: DictationDeliveryField {}

@MainActor
final class CleanFinishAdapter: DictationDeliveryAdapter {
    let trace: CleanFinishTrace
    var isTrusted = true
    var protected = false
    var appPID: Int32 = 42
    var field = CleanFinishField()
    var snapshot = DictationFieldSnapshot(text: "Before replace After", selection: NSRange(location: 7, length: 7))
    var focusReads = 0
    var writes: [String] = []
    init(trace: CleanFinishTrace) { self.trace = trace }
    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? {
        DictationDeliveryApplication(processIdentifier: appPID, bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
    }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField {
        focusReads += 1
        return field
    }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { lhs === rhs }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        DictationFieldMetadata(processIdentifier: appPID, role: "AXTextArea", subrole: nil,
            isEnabled: true, isProtected: protected, selectedTextIsSettable: true)
    }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot { snapshot }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        trace.events.append("write")
        writes.append(text)
        snapshot.text = (snapshot.text as NSString).replacingCharacters(in: snapshot.selection, with: text)
        snapshot.selection = NSRange(location: snapshot.selection.location + text.utf16.count, length: 0)
        return .accepted
    }
    func drift(_ drift: CleanFinishTargetDrift) {
        switch drift {
        case .application: appPID = 99
        case .field: field = CleanFinishField()
        case .selection: snapshot.selection = NSRange(location: 0, length: 0)
        case .text: snapshot.text += " changed"
        }
    }
}

@MainActor
private struct CleanFinishRig {
    let trace: CleanFinishTrace
    let backend: CleanFinishBackend
    let adapter: CleanFinishAdapter
    let preferences: DictationPreferences
    let coordinator: DictationCoordinator
    init(mode: DictationQuickMode = .verbatim) {
        let trace = CleanFinishTrace()
        let backend = CleanFinishBackend(trace: trace)
        let adapter = CleanFinishAdapter(trace: trace)
        let preferences = DictationPreferences()
        preferences.mode = mode
        // Copy when not inserted is covered in DictationCoordinatorTests; this suite asserts receipts and messages without it.
        preferences.copyWhenNotInserted = false
        self.trace = trace
        self.backend = backend
        self.adapter = adapter
        self.preferences = preferences
        coordinator = DictationCoordinator(backend: backend,
            delivery: DictationDeliveryService(adapter: adapter,
                ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999),
            preferences: preferences)
    }
}
