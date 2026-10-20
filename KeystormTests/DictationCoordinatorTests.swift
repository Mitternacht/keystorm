import Foundation
import Testing
@testable import Keystorm

@MainActor
@Suite(.serialized)
struct DictationCoordinatorTests {
    @Test("Returning to a recording before debounce preserves its pending edit")
    func returningBeforeDebouncePreservesPendingEdit() async throws {
        let backend = MultiRecordingEditBackend()
        let first = backend.add(raw: "Raw A", text: "Original A")
        let second = backend.add(raw: "Raw B", text: "Original B")
        let adapter = CoordinatorAdapter(trace: CoordinatorTrace())
        adapter.isTrusted = false
        let coordinator = DictationCoordinator(backend: backend, delivery: DictationDeliveryService(adapter: adapter,
            ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999))
        coordinator.restore(first)
        coordinator.resultText = "Edited A"
        coordinator.restore(second)
        coordinator.restore(first)
        #expect(coordinator.resultText == "Edited A")
        coordinator.resultText += " plus another edit"
        await coordinator.waitUntilSettled()
        #expect(backend.dictationMetadata(first)?.textRevision?.text == "Edited A plus another edit")
    }

    @Test("An interrupted backend updates dictation and drops the stale insertion capability")
    func backendInterruptionReconcilesIntoDictation() async throws {
        let rig = CoordinatorRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        let handle = try #require(rig.coordinator.handle)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Interruption-\(UUID())")
        let model = WorkspaceModel(root: root)
        let interactions = AppInteractionController()
        await model.initialize(loadLibrary: true)
        var session = VoiceSession(id: handle.sessionID)
        session.status = .interrupted
        session.gaps = [SessionGap(reason: "Microphone disconnected")]
        session.brief = BriefDocument()
        session.brief?.takes = [BriefTake(id: handle.takeID, expectedRevision: UUID(), status: .paused)]
        session.dictation = DictationSession(recordings: [DictationRecordingMetadata(id: handle.takeID, state: .recording)])
        try await model.registerImportedSession(session)
        #expect(model.dictationCaptureStatus(handle) == .interrupted("Microphone disconnected"))
        interactions.configure(workspace: model, showWorkspace: {}, dictation: rig.coordinator, startShortcuts: false)
        #expect(rig.coordinator.state == .paused)
        #expect(rig.coordinator.message.contains("Microphone disconnected"))
        #expect(rig.coordinator.destinationLabel == "Copy after recording")
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writeCount == 0)
        #expect(rig.coordinator.resultText.isEmpty)
        #expect(rig.coordinator.state == .paused)
        interactions.stop()
        await model.stopForTermination()
        await interactions.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Interruption keeps processing owned until its cancelled task drains")
    func interruptionCannotOverlapAnotherResumeOrFinish() async {
        let rig = CoordinatorRig()
        rig.backend.suspended = [.complete]
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.backend.waitFor(.complete)
        rig.coordinator.reconcileCaptureStatus(.interrupted("Device lost"))
        #expect(rig.coordinator.state == .processing)
        #expect(rig.coordinator.isTransitioning)
        rig.coordinator.pauseResume()
        rig.coordinator.finish()
        #expect(rig.backend.count(.resume) == 0)
        #expect(rig.backend.count(.complete) == 1)
        rig.backend.release(.complete)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .paused)
        #expect(rig.coordinator.message.contains("Device lost"))
        #expect(rig.adapter.writeCount == 0)
    }

    @Test("Repeated controls cannot overlap begin, pause, resume, or final transcription")
    func controlsSerializeRecordingTransitions() async throws {
        let rig = CoordinatorRig()
        rig.backend.suspended = [.begin, .pause, .resume, .complete]
        rig.coordinator.toggle()
        await rig.backend.waitFor(.begin)
        #expect(rig.coordinator.state == .starting)
        rig.coordinator.toggle()
        rig.coordinator.finish()
        rig.coordinator.pauseResume()
        #expect(rig.backend.count(.begin) == 1)
        rig.backend.release(.begin)
        await rig.coordinator.waitUntilSettled()
        let original = try #require(rig.coordinator.handle)
        #expect(rig.coordinator.state == .recording)

        rig.coordinator.pauseResume()
        await rig.backend.waitFor(.pause)
        rig.coordinator.pauseResume()
        rig.coordinator.finish()
        rig.coordinator.toggle()
        #expect(rig.backend.count(.pause) == 1)
        #expect(rig.backend.count(.complete) == 0)
        rig.backend.release(.pause)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .paused)
        #expect(rig.coordinator.handle == original)

        rig.coordinator.pauseResume()
        await rig.backend.waitFor(.resume)
        rig.coordinator.finish()
        rig.coordinator.pauseResume()
        rig.coordinator.toggle()
        #expect(rig.backend.count(.resume) == 1)
        rig.backend.release(.resume)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .recording)
        #expect(rig.coordinator.handle == original)

        rig.coordinator.finish()
        await rig.backend.waitFor(.complete)
        #expect(rig.coordinator.state == .processing)
        rig.coordinator.finish()
        rig.coordinator.pauseResume()
        rig.coordinator.toggle()
        #expect(rig.backend.count(.complete) == 1)
        #expect(rig.adapter.writeCount == 0)
        rig.backend.release(.complete)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.handle == original)
        #expect(rig.coordinator.resultText == rig.backend.completedRevision.text)
        #expect(rig.adapter.writeCount == 1)
        #expect(rig.adapter.snapshot.text == "Before Grüße aus München. After")
        #expect(rig.backend.allHandles.allSatisfy { $0 == original })
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writeCount == 1)
    }

    @Test("A durable pending delivery intent precedes the first external write")
    func pendingIntentMustCommitBeforeDelivery() async throws {
        let rig = CoordinatorRig()
        rig.backend.suspended = [.savePending]
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.backend.waitFor(.savePending)
        #expect(rig.coordinator.state == .processing)
        #expect(rig.adapter.writeCount == 0)
        #expect(rig.backend.saved.isEmpty)
        rig.coordinator.finish()
        rig.coordinator.toggle()
        rig.backend.release(.savePending)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writeCount == 1)
        #expect(rig.backend.saved.map(\.delivery?.state) == [.pending, .inserted])
        let pending = try #require(rig.backend.saved.first?.delivery)
        let receipt = try #require(rig.backend.saved.last?.delivery)
        #expect(pending.requestID == receipt.requestID)
        let savedPending = try #require(rig.trace.events.firstIndex(of: "saved:pending"))
        let externalWrite = try #require(rig.trace.events.firstIndex(of: "write"))
        let savedReceipt = try #require(rig.trace.events.firstIndex(of: "saved:inserted"))
        #expect(savedPending < externalWrite)
        #expect(externalWrite < savedReceipt)
        #expect(rig.backend.saved.allSatisfy { $0.revision == rig.backend.completedRevision })
    }

    @Test("A failed pending save preserves the result and never writes to another app")
    func failedPendingSaveDoesNotDeliver() async {
        let rig = CoordinatorRig()
        rig.backend.failSaving = .pending
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.resultText == rig.backend.completedRevision.text)
        #expect(rig.coordinator.message == CoordinatorFailure.persistence.localizedDescription)
        #expect(rig.adapter.writeCount == 0)
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writeCount == 0)
    }

    @Test("A receipt save failure cannot repeat an already confirmed insertion")
    func failedReceiptSaveNeverRetriesDelivery() async throws {
        let rig = CoordinatorRig()
        rig.backend.failSaving = .inserted
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        let handle = try #require(rig.coordinator.handle)
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.adapter.writeCount == 1)
        #expect(rig.backend.metadata?.delivery?.state == .pending)
        rig.coordinator.finish()
        rig.coordinator.restore(handle)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writeCount == 1)
        #expect(rig.coordinator.destinationLabel == "Copy after recording")
        #expect(rig.coordinator.resultText == rig.backend.completedRevision.text)
    }

    @Test("Cancellation after the write was sent still saves the delivery receipt, never leaving it pending",
          arguments: [PostWriteCancellation.shutdown, .interruption])
    func receiptSurvivesCancellationAfterWrite(_ cancellation: PostWriteCancellation) async throws {
        let rig = CoordinatorRig()
        // Like the workspace store, which refuses every save from a cancelled task.
        rig.backend.checksCancellationOnSave = true
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.adapter.onWrite = { [weak coordinator = rig.coordinator] in
            switch cancellation {
            case .shutdown: coordinator?.cancelForShutdown()
            case .interruption: coordinator?.reconcileCaptureStatus(.interrupted("Device lost"))
            }
        }
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writeCount == 1)
        let receipt = try #require(rig.backend.metadata?.delivery)
        #expect([DictationDeliveryState.inserted, .uncertain, .pasted].contains(receipt.state))
        #expect(rig.backend.saved.compactMap(\.delivery?.state) == [.pending, receipt.state])
        #expect(rig.backend.saved.first?.delivery?.requestID == receipt.requestID)
        // The operation still honours its cancellation once the receipt is durable.
        if cancellation == .interruption {
            #expect(rig.coordinator.state == .paused)
            #expect(rig.coordinator.message.contains("Device lost"))
        }
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writeCount == 1)
    }

    @Test("Dropping a capture without delivery turns off the accessibility mode it turned on, once",
          arguments: [CapturedTargetDrop.cancel, .stopped, .interruption, .shutdown, .failedFinish])
    func droppedCaptureReleasesManualAccessibility(_ drop: CapturedTargetDrop) async throws {
        let suiteName = "Keystorm.DictationCoordinatorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = DictationPreferences(defaults: defaults)
        preferences.pasteIntoOtherApps = true
        let adapter = ManualAccessibilityAdapter()
        let backend = CoordinatorBackend(trace: CoordinatorTrace())
        let coordinator = DictationCoordinator(backend: backend, delivery: DictationDeliveryService(adapter: adapter,
            ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999), preferences: preferences)
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .recording)
        #expect(coordinator.destinationLabel == "Paste into Editor")
        #expect(adapter.manualAccessibilityWrites == [true])
        switch drop {
        case .cancel: coordinator.cancel()
        case .stopped: coordinator.reconcileCaptureStatus(.paused)
        case .interruption: coordinator.reconcileCaptureStatus(.interrupted("Device lost"))
        case .shutdown: coordinator.cancelForShutdown()
        case .failedFinish:
            backend.completionFailure = .incomplete
            coordinator.finish()
        }
        await coordinator.waitUntilSettled()
        #expect(adapter.manualAccessibilityWrites == [true, false])
        #expect(adapter.pastePreparations == 0)
        if drop != .shutdown { #expect(coordinator.destinationLabel == "Copy after recording") }
    }

    @Test("A capture dropped while Finish still holds it is released at once, not when that operation ends",
          arguments: [CapturedTargetDrop.cancel, .interruption, .shutdown])
    func droppedCaptureReleasesWhileFinishHoldsIt(_ drop: CapturedTargetDrop) async throws {
        let suiteName = "Keystorm.DictationCoordinatorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = DictationPreferences(defaults: defaults)
        preferences.pasteIntoOtherApps = true
        let adapter = ManualAccessibilityAdapter()
        let backend = CoordinatorBackend(trace: CoordinatorTrace())
        backend.suspended = [.savePending]
        let coordinator = DictationCoordinator(backend: backend, delivery: DictationDeliveryService(adapter: adapter,
            ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999), preferences: preferences)
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(adapter.manualAccessibilityWrites == [true])
        coordinator.finish()
        await backend.waitFor(.savePending)
        #expect(coordinator.state == .processing)
        switch drop {
        case .cancel: coordinator.cancel()
        case .interruption: coordinator.reconcileCaptureStatus(.interrupted("Device lost"))
        case .shutdown: coordinator.cancelForShutdown()
        case .stopped, .failedFinish: Issue.record("Only cancel, interruption, and shutdown can drop a capture during Finish.")
        }
        // The suspended Finish operation still references the capture, so only an explicit release ends the mode now.
        #expect(adapter.manualAccessibilityWrites == [true, false])
        backend.release(.savePending)
        await coordinator.waitUntilSettled()
        #expect(adapter.manualAccessibilityWrites == [true, false])
        #expect(adapter.pastePreparations == 0)
        #expect(backend.saved.compactMap(\.delivery?.state) == [.pending])
    }

    @Test("A failed Finish speaks its complete reason once, as part of settling")
    func failedFinishAnnouncesReason() async {
        let rig = CoordinatorRig()
        let log = AnnouncementLog()
        rig.coordinator.announceStatus = { log.spoken.append($0) }
        rig.backend.completionFailure = .worker
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .failed)
        #expect(rig.coordinator.message == CoordinatorFailure.worker.localizedDescription)
        #expect(log.spoken == ["Starting", "Recording", "Transcribing",
            "Dictation failed. " + CoordinatorFailure.worker.localizedDescription])
    }

    @Test("A receipt that cannot be saved settles Ready with its reason in the one announcement")
    func failedReceiptSaveAnnouncesReason() async {
        let rig = CoordinatorRig()
        let log = AnnouncementLog()
        rig.coordinator.announceStatus = { log.spoken.append($0) }
        rig.backend.failSaving = .inserted
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.adapter.writeCount == 1)
        let message = rig.coordinator.message
        #expect(message == CoordinatorFailure.persistence.localizedDescription)
        #expect(log.spoken == ["Starting", "Recording", "Transcribing", "Ready to copy. " + message])
    }

    @Test("A refused Start from idle settles as failed and speaks the reason once")
    func refusedStartFromIdleAnnouncesReason() async {
        let rig = CoordinatorRig()
        let log = AnnouncementLog()
        rig.coordinator.announceStatus = { log.spoken.append($0) }
        rig.adapter.protected = true
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .failed)
        #expect(rig.coordinator.wantsRecordingHUD)
        #expect(log.spoken == ["Dictation failed. " + DictationCaptureFailure.secureField.message])
    }

    @Test("A refused Start while a failure is shown keeps its Needs attention HUD and speaks the reason once")
    func refusedStartAfterFailureKeepsHUD() async {
        let rig = CoordinatorRig()
        let log = AnnouncementLog()
        rig.coordinator.announceStatus = { log.spoken.append($0) }
        rig.adapter.protected = true
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .failed)
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        let reason = DictationCaptureFailure.secureField.message
        #expect(rig.coordinator.state == .failed)
        #expect(rig.coordinator.message == reason)
        #expect(rig.coordinator.wantsRecordingHUD)
        #expect(log.spoken == ["Dictation failed. " + reason, reason])
        #expect(rig.coordinator.spokenMessageRevision == rig.coordinator.messageRevision)
        #expect(rig.backend.count(.begin) == 0)
    }

    @Test("A refused Start after a result speaks its reason every time and never re-presents that result")
    func refusedStartAfterResultAnnouncesReason() async {
        let rig = CoordinatorRig()
        let log = AnnouncementLog()
        rig.coordinator.announceStatus = { log.spoken.append($0) }
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.wantsRecordingHUD)
        #expect(log.spoken == ["Starting", "Recording", "Transcribing", "Inserted into TextEdit."])
        rig.adapter.protected = true
        rig.coordinator.toggle()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        let reason = DictationCaptureFailure.secureField.message
        #expect(log.spoken.dropFirst(4).elementsEqual([reason, reason]))
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.message == reason)
        // The status line skips a revision the coordinator already spoke.
        #expect(rig.coordinator.spokenMessageRevision == rig.coordinator.messageRevision)
        #expect(!rig.coordinator.wantsRecordingHUD)
        #expect(rig.coordinator.resultText == rig.backend.completedRevision.text)
        #expect(rig.backend.count(.begin) == 1)
        #expect(rig.adapter.writeCount == 1)
    }

    @Test("Every status assignment advances the message revision, even when its text repeats")
    func repeatedMessageAdvancesRevision() {
        let backend = MultiRecordingEditBackend()
        let recording = backend.add(raw: "Raw text", text: "Saved text")
        let adapter = CoordinatorAdapter(trace: CoordinatorTrace())
        adapter.isTrusted = false
        let coordinator = DictationCoordinator(backend: backend, delivery: DictationDeliveryService(adapter: adapter,
            ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999))
        coordinator.restore(recording)
        coordinator.discardTransformPreview()
        let first = coordinator.messageRevision
        let text = coordinator.message
        coordinator.discardTransformPreview()
        #expect(coordinator.message == text)
        #expect(coordinator.messageRevision == first + 1)
        #expect(coordinator.spokenMessageRevision == nil)
    }

    @Test("A repeated interruption report neither posts a new status nor speaks again")
    func repeatedInterruptionReportIsIdempotent() async {
        let rig = CoordinatorRig()
        let log = AnnouncementLog()
        rig.coordinator.announceStatus = { log.spoken.append($0) }
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.reconcileCaptureStatus(.interrupted("Device lost"))
        #expect(rig.coordinator.state == .paused)
        #expect(log.spoken.last == "Recording interrupted and paused")
        let revision = rig.coordinator.messageRevision
        let spoken = log.spoken
        rig.coordinator.reconcileCaptureStatus(.interrupted("Device lost"))
        #expect(rig.coordinator.messageRevision == revision)
        #expect(log.spoken == spoken)
        #expect(rig.coordinator.message.contains("Device lost"))
    }

    @Test("Incomplete transcription or worker failure produces no external output",
          arguments: [CoordinatorFailure.incomplete, .worker])
    func failedCompletionCannotDeliver(_ failure: CoordinatorFailure) async {
        let rig = CoordinatorRig()
        rig.backend.completionFailure = failure
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .failed)
        #expect(rig.coordinator.resultText.isEmpty)
        #expect(rig.adapter.writeCount == 0)
        #expect(rig.backend.saved.count == 1)
        #expect(rig.backend.saved.first?.state == .failed)
        #expect(rig.backend.saved.first?.revision == nil)
        #expect(rig.backend.saved.first?.delivery == nil)
        #expect(rig.backend.saved.first?.failure == failure.localizedDescription)
    }

    @Test("Restored interrupted recordings resume the original take with no stale insertion target",
          arguments: [DictationRecordingState.recording, .paused])
    func restoreIsPausedAndCopyOnly(_ savedState: DictationRecordingState) async {
        let rig = CoordinatorRig()
        rig.backend.metadata = DictationRecordingMetadata(id: rig.backend.recording.takeID, state: savedState)
        rig.coordinator.restore(rig.backend.recording)
        #expect(rig.coordinator.state == .paused)
        #expect(rig.coordinator.destinationLabel == "Copy after recording")
        #expect(rig.adapter.focusReads == 0)
        rig.coordinator.pauseResume()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .recording)
        #expect(rig.backend.count(.begin) == 0)
        #expect(rig.backend.count(.resume) == 1)
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.adapter.writeCount == 0)
        #expect(rig.coordinator.resultText == rig.backend.completedRevision.text)
        #expect(rig.backend.allHandles.allSatisfy { $0 == rig.backend.recording })
    }

    @Test("Missing Accessibility access still allows local recording and a reviewable result")
    func missingAccessibilityUsesCopyResult() async {
        let rig = CoordinatorRig()
        rig.adapter.isTrusted = false
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .recording)
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.resultText == rig.backend.completedRevision.text)
        #expect(rig.adapter.focusReads == 0)
        #expect(rig.adapter.writeCount == 0)
        #expect(rig.coordinator.destinationLabel == "Copy after recording")
    }

    @Test("A protected field blocks capture before the recording backend starts")
    func secureFieldCannotStartRecording() async {
        let rig = CoordinatorRig()
        rig.adapter.protected = true
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .failed)
        #expect(rig.backend.count(.begin) == 0)
        #expect(rig.adapter.snapshotReads == 0)
        #expect(rig.adapter.writeCount == 0)
    }

    @Test("Shutdown before completion or intent commit prevents any external write",
          arguments: [DictationShutdownPoint.completion, .pendingIntent])
    func shutdownCancellationCannotDeliver(_ point: DictationShutdownPoint) async throws {
        let rig = CoordinatorRig()
        let stage: CoordinatorStage = point == .completion ? .complete : .savePending
        rig.backend.suspended = [stage]
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        let handle = try #require(rig.coordinator.handle)
        rig.coordinator.finish()
        await rig.backend.waitFor(stage)
        #expect(rig.coordinator.state == .processing)
        #expect(rig.adapter.writeCount == 0)
        rig.coordinator.cancelForShutdown()
        rig.backend.release(stage)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.writeCount == 0)
        #expect(rig.adapter.snapshot.text == "Before replace After")
        #expect(rig.backend.saved.allSatisfy { $0.delivery?.state != .inserted })
        #expect(rig.coordinator.handle == handle)
        // This backend deliberately returns completed text despite cancellation, so
        // clearing the ephemeral capability must independently prevent delivery.
        #expect(rig.coordinator.resultText == rig.backend.completedRevision.text)
        if point == .pendingIntent {
            #expect(rig.backend.saved.first?.delivery?.state == .pending)
        }
    }

    @Test("Shutdown joins queued edits without cancelling either recording's save")
    func shutdownPreservesPendingEdits() async throws {
        let backend = MultiRecordingEditBackend()
        let first = backend.add(raw: "original A before shutdown", text: "Initial A")
        let second = backend.add(raw: "original B before shutdown", text: "Initial B")
        let adapter = CoordinatorAdapter(trace: CoordinatorTrace())
        adapter.isTrusted = false
        let coordinator = DictationCoordinator(backend: backend, delivery: DictationDeliveryService(adapter: adapter,
            ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999))
        coordinator.restore(first)
        coordinator.resultText = "Final A before shutdown"
        coordinator.restore(second)
        coordinator.resultText = "Final B before shutdown"
        coordinator.cancelForShutdown()
        await coordinator.waitUntilSettled()
        let savedFirst = try #require(backend.dictationMetadata(first)?.textRevision)
        let savedSecond = try #require(backend.dictationMetadata(second)?.textRevision)
        #expect(backend.saved.count == 2)
        #expect(savedFirst.text == "Final A before shutdown")
        #expect(savedFirst.rawText == "original A before shutdown")
        #expect(savedSecond.text == "Final B before shutdown")
        #expect(savedSecond.rawText == "original B before shutdown")
        #expect(savedFirst.sourceTranscriptIDs == backend.originalSources[first.takeID])
        #expect(savedSecond.sourceTranscriptIDs == backend.originalSources[second.takeID])
        #expect(adapter.writeCount == 0)
    }

    @Test("Edits to two recordings inside one debounce interval preserve both original sources")
    func switchingRecordingsDoesNotCancelAnotherEdit() async throws {
        let backend = MultiRecordingEditBackend()
        let first = backend.add(raw: "raw source A", text: "Original A")
        let second = backend.add(raw: "raw source B", text: "Original B")
        let adapter = CoordinatorAdapter(trace: CoordinatorTrace())
        adapter.isTrusted = false
        let coordinator = DictationCoordinator(backend: backend, delivery: DictationDeliveryService(adapter: adapter,
            ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999))
        coordinator.restore(first)
        coordinator.resultText = "Edited A with Grüße."
        // No suspension: both edits are queued inside the same 300 ms interval.
        coordinator.restore(second)
        coordinator.resultText = "Edited B with München."
        await coordinator.waitUntilSettled()
        #expect(backend.saved.count == 2)
        let savedFirst = try #require(backend.dictationMetadata(first)?.textRevision)
        let savedSecond = try #require(backend.dictationMetadata(second)?.textRevision)
        #expect(savedFirst.text == "Edited A with Grüße.")
        #expect(savedFirst.rawText == "raw source A")
        #expect(savedSecond.text == "Edited B with München.")
        #expect(savedSecond.rawText == "raw source B")
        #expect(savedFirst.sourceTranscriptIDs == backend.originalSources[first.takeID])
        #expect(savedSecond.sourceTranscriptIDs == backend.originalSources[second.takeID])
        #expect(coordinator.handle == second)
        #expect(coordinator.resultText == savedSecond.text)
        coordinator.restore(first)
        #expect(coordinator.resultText == savedFirst.text)
        #expect(adapter.writeCount == 0)
    }

    @Test("A queued edit survives New Dictation and starting another recording",
          arguments: [QueuedEditExit.newDraft, .startRecording])
    func leavingResultPreservesQueuedEdit(_ action: QueuedEditExit) async throws {
        let backend = MultiRecordingEditBackend()
        let first = backend.add(raw: "untouched original source", text: "Original text")
        let adapter = CoordinatorAdapter(trace: CoordinatorTrace())
        adapter.isTrusted = false
        let coordinator = DictationCoordinator(backend: backend, delivery: DictationDeliveryService(adapter: adapter,
            ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999))
        coordinator.restore(first)
        coordinator.resultText = "A pending edit before leaving."
        coordinator.newDraft()
        #expect(coordinator.state == .idle)
        #expect(coordinator.handle == nil)
        #expect(coordinator.resultText.isEmpty)
        if action == .startRecording { coordinator.toggle() }
        await coordinator.waitUntilSettled()
        let saved = try #require(backend.dictationMetadata(first)?.textRevision)
        #expect(saved.text == "A pending edit before leaving.")
        #expect(saved.rawText == "untouched original source")
        #expect(saved.sourceTranscriptIDs == backend.originalSources[first.takeID])
        #expect(backend.saved.count == 1)
        #expect(adapter.writeCount == 0)
        if action == .startRecording {
            #expect(coordinator.state == .recording)
            #expect(coordinator.handle != first)
            #expect(backend.beginCount == 1)
        } else {
            #expect(coordinator.state == .idle)
            #expect(backend.beginCount == 0)
        }
    }

    @Test("Complete dictation keeps original and edited text distinct in timeline order")
    func completeTextPreservesRawSource() throws {
        let fixture = makeCompleteRecording()
        let revision = try WorkspaceModel.completeDictationText(in: fixture.session, takeID: fixture.takeID)
        #expect(revision.rawText == "raw one raw two raw three")
        #expect(revision.text == "Edited one. Grüße aus München. Not forty two.")
        #expect(revision.sourceTranscriptIDs == fixture.session.transcripts.map(\.id))
    }

    @Test("A complete multi-segment speech window is accepted without duplicating its text")
    func groupedWindowIsEmittedOnce() throws {
        var fixture = makeCompleteRecording()
        let first = fixture.session.segments[0], second = fixture.session.segments[1]
        fixture.session.transcripts[0].segmentIDs = [first.id, second.id]
        fixture.session.transcripts[0].endTime = second.endTime
        fixture.session.transcripts.remove(at: 1)
        let revision = try WorkspaceModel.completeDictationText(in: fixture.session, takeID: fixture.takeID)
        #expect(revision.text == "Edited one. Not forty two.")
        #expect(revision.sourceTranscriptIDs.count == 2)
    }

    @Test("Unsafe audio or transcript coverage never becomes insertion text", arguments: [
        DictationCoverageFault.unavailableAudio, .missingWindow, .incompleteWindow, .duplicateCoverage,
        .duplicateIDInsideWindow, .foreignAudio, .audioGap, .audioOverlap, .missingInterval,
        .nonfiniteWindow, .partialWindow, .overlappingWindow, .crossPauseWindow, .captureDiscontinuity
    ])
    func unsafeCoverageIsRejected(_ fault: DictationCoverageFault) {
        var fixture = makeCompleteRecording()
        switch fault {
        case .captureDiscontinuity: fixture.session.gaps.append(SessionGap(reason: "The microphone clock jumped."))
        case .unavailableAudio: fixture.session.unavailableSegmentIDs = [fixture.session.segments[0].id]
        case .missingWindow: fixture.session.transcripts.remove(at: 1)
        case .incompleteWindow: fixture.session.transcripts[0].isComplete = false
        case .duplicateCoverage:
            fixture.session.transcripts[0].segmentIDs.append(fixture.session.segments[1].id)
        case .duplicateIDInsideWindow:
            fixture.session.transcripts[0].segmentIDs.append(fixture.session.segments[0].id)
        case .foreignAudio: fixture.session.transcripts[0].segmentIDs.append(UUID())
        case .audioGap: fixture.session.segments[1].startTime += 0.5
        case .audioOverlap: fixture.session.segments[1].startTime -= 0.5
        case .missingInterval:
            fixture.session.segments.removeLast()
            fixture.session.transcripts.removeLast()
        case .nonfiniteWindow: fixture.session.transcripts[0].endTime = .nan
        case .partialWindow: fixture.session.transcripts[0].endTime = 0.25
        case .overlappingWindow: fixture.session.transcripts[0].endTime = 3
        case .crossPauseWindow:
            fixture.session.transcripts[1].segmentIDs.append(fixture.session.segments[2].id)
            fixture.session.transcripts[1].endTime = fixture.session.segments[2].endTime
            fixture.session.transcripts.removeLast()
        }
        #expect(throws: (any Error).self) {
            try WorkspaceModel.completeDictationText(in: fixture.session, takeID: fixture.takeID)
        }
    }

    private func makeCompleteRecording() -> (session: VoiceSession, takeID: UUID) {
        let first = UUID(), resumed = UUID()
        var take = BriefTake(intervalID: first, expectedRevision: UUID(), status: .pending)
        take.intervalIDs.append(resumed)
        var session = VoiceSession()
        session.brief = BriefDocument()
        session.brief?.takes = [take]
        session.intervals = [
            CaptureInterval(id: first, startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 4)),
            CaptureInterval(id: resumed, startedAt: Date(timeIntervalSince1970: 3_604), endedAt: Date(timeIntervalSince1970: 3_606))
        ]
        session.segments = [first, first, resumed].enumerated().map { index, interval in
            AudioSegment(intervalID: interval, fileName: "\(index).caf", startTime: Double(index * 2),
                frameCount: 32_000, sampleRate: 16_000, channelCount: 1, sha256: "fixture")
        }
        let texts = ["Edited one.", "Grüße aus München.", "Not forty two."]
        session.transcripts = session.segments.enumerated().map { index, segment in
            TranscriptRevision(rawText: "raw \(["one", "two", "three"][index])", text: texts[index],
                segmentIDs: [segment.id], startTime: segment.startTime, endTime: segment.endTime)
        }
        return (session, take.id)
    }
}

enum DictationCoverageFault: Sendable {
    case unavailableAudio, missingWindow, incompleteWindow, duplicateCoverage, duplicateIDInsideWindow
    case foreignAudio, audioGap, audioOverlap, missingInterval, nonfiniteWindow, partialWindow
    case overlappingWindow, crossPauseWindow, captureDiscontinuity
}

enum DictationShutdownPoint: Sendable { case completion, pendingIntent }

enum QueuedEditExit: Sendable { case newDraft, startRecording }

enum PostWriteCancellation: Sendable { case shutdown, interruption }

enum CapturedTargetDrop: Sendable { case cancel, stopped, interruption, shutdown, failedFinish }

/// Collects VoiceOver announcements in place of posting them.
@MainActor
private final class AnnouncementLog { var spoken: [String] = [] }

@MainActor
private final class MultiRecordingEditBackend: DictationRecordingBackend {
    var metadata: [UUID: DictationRecordingMetadata] = [:]
    var originalSources: [UUID: [UUID]] = [:]
    var saved: [(handle: DictationRecordingHandle, revision: DictationTextRevision)] = []
    var beginCount = 0

    func add(raw: String, text: String) -> DictationRecordingHandle {
        let handle = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
        let sources = [UUID()]
        let revision = DictationTextRevision(rawText: raw, text: text, sourceTranscriptIDs: sources)
        originalSources[handle.takeID] = sources
        metadata[handle.takeID] = DictationRecordingMetadata(id: handle.takeID, state: .ready, textRevision: revision)
        return handle
    }

    func dictationBegin() async throws -> DictationRecordingHandle {
        beginCount += 1
        let handle = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
        metadata[handle.takeID] = DictationRecordingMetadata(id: handle.takeID, state: .recording)
        return handle
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {}
    func dictationResume(_ handle: DictationRecordingHandle) async throws {}
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        throw CoordinatorFailure.incomplete
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? {
        metadata[handle.takeID]
    }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        if let revision {
            saved.append((handle, revision))
            metadata[handle.takeID]?.textRevision = revision
        }
        metadata[handle.takeID]?.state = state
        if let delivery { metadata[handle.takeID]?.delivery = delivery }
        metadata[handle.takeID]?.failureMessage = failure
    }
}

enum CoordinatorFailure: Error, LocalizedError, Sendable {
    case incomplete, worker, persistence
    var errorDescription: String? {
        switch self {
        case .incomplete: "Some audio is incomplete. Nothing was inserted."
        case .worker: "The local speech worker failed. Nothing was inserted."
        case .persistence: "The delivery intent could not be saved."
        }
    }
}

@MainActor
private final class CoordinatorTrace { var events: [String] = [] }

private enum CoordinatorStage: String, Hashable {
    case begin, pause, resume, complete, savePending, saveReceipt
}

@MainActor
private final class CoordinatorBackend: DictationRecordingBackend {
    struct Saved {
        let state: DictationRecordingState
        let revision: DictationTextRevision?
        let delivery: DictationDelivery?
        let failure: String?
    }
    let recording = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    let completedRevision = DictationTextRevision(rawText: "Grüße aus München.", text: "Grüße aus München.",
        sourceTranscriptIDs: [UUID()])
    var metadata: DictationRecordingMetadata?
    var suspended: Set<CoordinatorStage> = []
    var completionFailure: CoordinatorFailure?
    var failSaving: DictationDeliveryState?
    /// Mirrors WorkspaceModel.dictationSave, which begins with `try Task.checkCancellation()`.
    var checksCancellationOnSave = false
    var saved: [Saved] = []
    var allHandles: [DictationRecordingHandle] = []
    let trace: CoordinatorTrace
    private var counts: [CoordinatorStage: Int] = [:]
    private var gates: [CoordinatorStage: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [CoordinatorStage: [CheckedContinuation<Void, Never>]] = [:]

    init(trace: CoordinatorTrace) { self.trace = trace }
    func count(_ stage: CoordinatorStage) -> Int { counts[stage, default: 0] }
    func release(_ stage: CoordinatorStage) {
        suspended.remove(stage)
        gates.removeValue(forKey: stage)?.resume()
    }
    func waitFor(_ stage: CoordinatorStage) async {
        if count(stage) > 0 { return }
        await withCheckedContinuation { waiters[stage, default: []].append($0) }
    }
    private func enter(_ stage: CoordinatorStage) async {
        counts[stage, default: 0] += 1
        trace.events.append(stage.rawValue)
        let ready = waiters.removeValue(forKey: stage) ?? []
        if suspended.contains(stage) {
            await withCheckedContinuation { continuation in
                gates[stage] = continuation
                ready.forEach { $0.resume() }
            }
        } else { ready.forEach { $0.resume() } }
    }
    func dictationBegin() async throws -> DictationRecordingHandle {
        await enter(.begin)
        metadata = DictationRecordingMetadata(id: recording.takeID, state: .recording)
        return recording
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {
        allHandles.append(handle)
        await enter(.pause)
    }
    func dictationResume(_ handle: DictationRecordingHandle) async throws {
        allHandles.append(handle)
        await enter(.resume)
    }
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        allHandles.append(handle)
        await enter(.complete)
        if let completionFailure { throw completionFailure }
        return completedRevision
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? { metadata }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        if checksCancellationOnSave { try Task.checkCancellation() }
        allHandles.append(handle)
        if let delivery {
            await enter(delivery.state == .pending ? .savePending : .saveReceipt)
            if failSaving == delivery.state { throw CoordinatorFailure.persistence }
        }
        saved.append(Saved(state: state, revision: revision, delivery: delivery, failure: failure))
        if metadata == nil { metadata = DictationRecordingMetadata(id: handle.takeID) }
        metadata?.state = state
        if let revision { metadata?.textRevision = revision }
        if let delivery { metadata?.delivery = delivery }
        metadata?.failureMessage = failure
        if let delivery { trace.events.append("saved:\(delivery.state.rawValue)") }
    }
}

@MainActor
private final class CoordinatorField: DictationDeliveryField {}

@MainActor
private final class CoordinatorAdapter: DictationDeliveryAdapter {
    var isTrusted = true
    var protected = false
    var field = CoordinatorField()
    var snapshot = DictationFieldSnapshot(text: "Before replace After", selection: NSRange(location: 7, length: 7))
    var focusReads = 0
    var snapshotReads = 0
    var writeCount = 0
    /// Runs right after the external write, before delivery confirms it.
    var onWrite: (@MainActor () -> Void)?
    let trace: CoordinatorTrace
    init(trace: CoordinatorTrace) { self.trace = trace }
    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? {
        DictationDeliveryApplication(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
    }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField {
        focusReads += 1
        return field
    }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { lhs === rhs }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        DictationFieldMetadata(processIdentifier: 42, role: "AXTextArea", subrole: nil, isEnabled: true,
            isProtected: protected, selectedTextIsSettable: true)
    }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        snapshotReads += 1
        return snapshot
    }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        trace.events.append("write")
        writeCount += 1
        snapshot.text = (snapshot.text as NSString).replacingCharacters(in: snapshot.selection, with: text)
        snapshot.selection = NSRange(location: snapshot.selection.location + text.utf16.count, length: 0)
        onWrite?()
        return .accepted
    }
}

/// Like a Chromium or Electron app: its text area is exposed only while AXManualAccessibility is on.
@MainActor
private final class ManualAccessibilityAdapter: DictationDeliveryAdapter {
    let isTrusted = true
    let canPostPasteEvents = true
    let app = DictationDeliveryApplication(processIdentifier: 77, bundleIdentifier: "com.example.Editor", name: "Editor")
    let field = CoordinatorField()
    private var manualAccessibilityOn = false
    /// Every AXManualAccessibility write, in order.
    private(set) var manualAccessibilityWrites: [Bool] = []
    private(set) var pastePreparations = 0

    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { app }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField { field }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { lhs === rhs }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        DictationFieldMetadata(processIdentifier: app.processIdentifier,
            role: manualAccessibilityOn ? "AXTextArea" : "AXWebArea", subrole: nil, isEnabled: true,
            isProtected: false, selectedTextIsSettable: false, valueIsSettable: true)
    }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        Issue.record("The paste fallback never reads field text.")
        return DictationFieldSnapshot(text: "", selection: NSRange(location: 0, length: 0))
    }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        .rejected
    }
    func manualAccessibility(in application: DictationDeliveryApplication) -> Bool? { manualAccessibilityOn }
    func setManualAccessibility(_ enabled: Bool, in application: DictationDeliveryApplication) -> Bool {
        manualAccessibilityWrites.append(enabled)
        manualAccessibilityOn = enabled
        return true
    }
    func selectedTextRange(of field: any DictationDeliveryField) -> NSRange? { NSRange(location: 0, length: 0) }
    func prepareFallbackPaste(_ text: String, processIdentifier: Int32) throws -> any DictationPasteOperation {
        pastePreparations += 1
        throw CoordinatorFailure.persistence
    }
}

@MainActor
private struct CoordinatorRig {
    let trace: CoordinatorTrace
    let backend: CoordinatorBackend
    let adapter: CoordinatorAdapter
    let coordinator: DictationCoordinator
    init() {
        let trace = CoordinatorTrace()
        let backend = CoordinatorBackend(trace: trace)
        let adapter = CoordinatorAdapter(trace: trace)
        self.trace = trace
        self.backend = backend
        self.adapter = adapter
        coordinator = DictationCoordinator(backend: backend, delivery: DictationDeliveryService(adapter: adapter,
            ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999))
    }
}
