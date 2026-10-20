import Foundation
import Testing
@testable import Keystorm

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HoldRecordingTests {
    @Test func releaseBeforePermissionCompletesStopsTheOwnedTake() async {
        let recorder = ControlledHoldRecorder()
        let coordinator = recorder.coordinator()
        coordinator.setPressed(true)
        await recorder.waitForStart(1)
        coordinator.setPressed(false)
        recorder.completeStart(true)
        await coordinator.waitForSettled()
        #expect(recorder.starts == 1)
        #expect(recorder.pauses == 1)
        #expect(!recorder.recording)
        #expect(coordinator.phase == .idle)
    }

    @Test func releaseAndRepressWhileStartingCoalesceIntoOneTake() async {
        let recorder = ControlledHoldRecorder()
        let coordinator = recorder.coordinator()
        coordinator.setPressed(true)
        await recorder.waitForStart(1)
        coordinator.setPressed(false)
        coordinator.setPressed(true)
        recorder.completeStart(true)
        await coordinator.waitForSettled()
        #expect(recorder.starts == 1)
        #expect(recorder.pauses == 0)
        #expect(recorder.recording)
        coordinator.setPressed(false)
        await coordinator.waitForSettled()
        #expect(recorder.pauses == 1)
        #expect(!recorder.recording)
    }

    @Test func repressDuringPauseCannotBeStoppedByAnOldContinuation() async {
        let recorder = ControlledHoldRecorder(controlPause: true)
        let coordinator = recorder.coordinator()
        coordinator.setPressed(true)
        await recorder.waitForStart(1)
        recorder.completeStart(true)
        await coordinator.waitForSettled()
        coordinator.setPressed(false)
        await recorder.waitForPause(1)
        coordinator.setPressed(true)
        #expect(recorder.starts == 1)
        recorder.completePause()
        await recorder.waitForStart(2)
        recorder.completeStart(true)
        await coordinator.waitForSettled()
        #expect(recorder.starts == 2)
        #expect(recorder.pauses == 1)
        #expect(recorder.recording)
        #expect(coordinator.phase == .recording)
        coordinator.cancel()
        await recorder.waitForPause(2)
        recorder.completePause()
        await coordinator.waitForSettled()
        #expect(!recorder.recording)
    }

    @Test func permissionFailureDoesNotRetryUntilAnotherPress() async {
        let recorder = ControlledHoldRecorder()
        let coordinator = recorder.coordinator()
        coordinator.setPressed(true)
        await recorder.waitForStart(1)
        recorder.completeStart(false)
        await coordinator.waitForSettled()
        coordinator.setPressed(true)
        await coordinator.waitForSettled()
        #expect(recorder.starts == 1)
        #expect(recorder.pauses == 0)
        coordinator.setPressed(false)
        coordinator.setPressed(true)
        await recorder.waitForStart(2)
        recorder.completeStart(true)
        await coordinator.waitForSettled()
        coordinator.cancel()
        await coordinator.waitForSettled()
        #expect(recorder.starts == 2)
        #expect(recorder.pauses == 1)
    }

    @Test func manualControlDrainsPendingHoldAndNeverPausesAnUnownedTake() async {
        let recorder = ControlledHoldRecorder()
        let coordinator = recorder.coordinator()
        coordinator.setPressed(true)
        await recorder.waitForStart(1)
        #expect(coordinator.cancelForManualControl())
        recorder.completeStart(true)
        await coordinator.waitForSettled()
        #expect(!recorder.recording)
        #expect(!coordinator.cancelForManualControl())
        recorder.recording = true // A separate manual action owns this capture.
        coordinator.setPressed(true)
        await coordinator.waitForSettled()
        coordinator.setPressed(false)
        await coordinator.waitForSettled()
        #expect(recorder.recording)
        #expect(recorder.starts == 1)
        #expect(recorder.pauses == 1)
    }

    @Test func failedPauseKeepsOwnershipUntilAStopActuallySucceeds() async {
        let recorder = ControlledHoldRecorder()
        let coordinator = recorder.coordinator()
        coordinator.setPressed(true)
        await recorder.waitForStart(1)
        recorder.completeStart(true)
        await coordinator.waitForSettled()
        recorder.pauseSucceeds = false
        coordinator.setPressed(false)
        await coordinator.waitForSettled()
        #expect(recorder.recording)
        #expect(coordinator.phase == .recording)
        #expect(recorder.pauses == 1)
        #expect(coordinator.cancelForManualControl())
        recorder.pauseSucceeds = true
        await coordinator.waitForSettled()
        #expect(!recorder.recording)
        #expect(recorder.pauses == 2)
        #expect(coordinator.phase == .idle)
    }

    @Test func shutdownDrainsPendingStartupAndRejectsLaterPresses() async {
        let recorder = ControlledHoldRecorder()
        let coordinator = recorder.coordinator()
        coordinator.setPressed(true)
        await recorder.waitForStart(1)
        coordinator.beginShutdown()
        coordinator.setPressed(true)
        recorder.completeStart(true)
        await coordinator.shutdown()
        #expect(!coordinator.acceptsPresses)
        #expect(!coordinator.isPressed)
        #expect(!recorder.recording)
        #expect(recorder.starts == 1)
        #expect(recorder.pauses == 1)
        coordinator.setPressed(true)
        await coordinator.waitForSettled()
        #expect(recorder.starts == 1)
    }
}

@MainActor
private final class ControlledHoldRecorder {
    var recording = false
    var pauseSucceeds = true
    private(set) var starts = 0
    private(set) var pauses = 0
    private let controlPause: Bool
    private var startContinuation: CheckedContinuation<Bool, Never>?
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var pauseWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(controlPause: Bool = false) { self.controlPause = controlPause }

    func coordinator() -> HoldRecordingCoordinator {
        HoldRecordingCoordinator(isRecording: { self.recording }, start: {
            self.starts += 1
            let success = await withCheckedContinuation { continuation in
                self.startContinuation = continuation
                let ready = self.startWaiters.filter { $0.0 <= self.starts }
                self.startWaiters.removeAll { $0.0 <= self.starts }
                ready.forEach { $0.1.resume() }
            }
            self.recording = success
            return success
        }, pause: {
            self.pauses += 1
            if self.controlPause {
                await withCheckedContinuation { continuation in
                    self.pauseContinuation = continuation
                    let ready = self.pauseWaiters.filter { $0.0 <= self.pauses }
                    self.pauseWaiters.removeAll { $0.0 <= self.pauses }
                    ready.forEach { $0.1.resume() }
                }
            }
            if self.pauseSucceeds { self.recording = false }
        })
    }

    func waitForStart(_ count: Int) async {
        if starts >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }
    func waitForPause(_ count: Int) async {
        if pauses >= count { return }
        await withCheckedContinuation { pauseWaiters.append((count, $0)) }
    }
    func completeStart(_ success: Bool) {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(returning: success)
    }
    func completePause() {
        let continuation = pauseContinuation
        pauseContinuation = nil
        continuation?.resume()
    }
}
