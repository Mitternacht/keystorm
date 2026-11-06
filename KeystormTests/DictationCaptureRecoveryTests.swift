import AppKit
import Foundation
import Testing
@testable import Keystorm

/// How the coordinator behaves when the microphone stops on its own, when a take holds no speech, and when Clean
/// fails. The backend and delivery target are fakes, and every clipboard write goes to a private pasteboard.
@MainActor
@Suite(.serialized)
struct DictationCaptureRecoveryTests {
    private static let routeChange = "The microphone changed. Recording is paused and saved; resume to continue on the current input."

    // MARK: Suspended capture keeps the destination

    @Test("A route change pauses the take, keeps the destination, and Finish still inserts")
    func suspensionKeepsTheDestination() async throws {
        let rig = RecoveryRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        let destination = rig.coordinator.destinationLabel
        #expect(rig.coordinator.state == .recording)

        rig.coordinator.reconcileCaptureStatus(.suspended(Self.routeChange))
        #expect(rig.coordinator.state == .paused)
        #expect(rig.coordinator.message.contains("The microphone changed"))
        #expect(rig.coordinator.destinationLabel == destination)

        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.adapter.writes == [rig.backend.text.text])
        #expect(rig.coordinator.deliveredOnFinish)
        #expect(rig.backend.completeCount == 1)
    }

    @Test("Resume after a route change continues the same take and Finish then inserts once")
    func resumeAfterSuspension() async throws {
        let rig = RecoveryRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        let handle = try #require(rig.coordinator.handle)
        rig.coordinator.reconcileCaptureStatus(.suspended(Self.routeChange))
        #expect(rig.coordinator.state == .paused)

        rig.coordinator.pauseResume()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.resumeCount == 1)
        #expect(rig.coordinator.state == .recording)
        #expect(rig.coordinator.handle == handle)

        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.adapter.writes == [rig.backend.text.text])
    }

    @Test("A resume that cannot open the input leaves the take paused, the destination held, and Finish working")
    func failedResumeStaysFinishable() async throws {
        let rig = RecoveryRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        let destination = rig.coordinator.destinationLabel
        rig.coordinator.reconcileCaptureStatus(.suspended(Self.routeChange))
        rig.backend.resumeError = RecoveryFailure.noInput

        rig.coordinator.pauseResume()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .paused)
        #expect(rig.coordinator.message == RecoveryFailure.noInput.localizedDescription)
        #expect(rig.coordinator.destinationLabel == destination)

        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.adapter.writes == [rig.backend.text.text])
    }

    @Test("A suspension report never moves a take that is not recording")
    func suspensionIgnoredWhenNotRecording() async throws {
        let rig = RecoveryRig()
        rig.coordinator.reconcileCaptureStatus(.suspended(Self.routeChange))
        #expect(rig.coordinator.state == .idle)
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.reconcileCaptureStatus(.suspended(Self.routeChange))
        #expect(rig.coordinator.state == .ready)
    }

    @Test("A suspension is announced as an interruption, not as a plain pause")
    func suspensionIsAnnounced() async throws {
        let rig = RecoveryRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.spoken.lines.removeAll()
        rig.coordinator.reconcileCaptureStatus(.suspended(Self.routeChange))
        #expect(rig.spoken.lines == ["Recording interrupted and paused"])
    }

    // MARK: Hard interruption still reaches a result

    @Test("After a hard interruption Finish shows the saved text and copies it instead of inserting")
    func hardInterruptionBeforeFinishStillCompletes() async throws {
        let rig = RecoveryRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.reconcileCaptureStatus(.interrupted("Device lost"))
        #expect(rig.coordinator.state == .paused)
        #expect(rig.coordinator.destinationLabel == "Copy after recording")

        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.resultText == rig.backend.text.text)
        #expect(rig.adapter.writes.isEmpty)
        #expect(rig.pasteboard.string(forType: .string) == rig.backend.text.text)
    }

    @Test("When Finish itself fails after a hard interruption the take stays paused and says why")
    func hardInterruptionWithFailedFinishStaysPaused() async throws {
        let rig = RecoveryRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.backend.completeError = RecoveryFailure.incomplete
        rig.coordinator.reconcileCaptureStatus(.interrupted("Device lost"))

        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .paused)
        #expect(rig.coordinator.message.contains("Device lost"))
        #expect(rig.coordinator.message.contains(RecoveryFailure.incomplete.localizedDescription))
        #expect(rig.adapter.writes.isEmpty)
        #expect(rig.coordinator.canCancel)
    }

    // MARK: No speech

    @Test("A take with no speech closes quietly: idle, no HUD, saved as cancelled, announced once")
    func noSpeechIsAQuietDismiss() async throws {
        let rig = RecoveryRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.backend.completeError = DictationNoSpeechError()
        rig.spoken.lines.removeAll()

        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .idle)
        #expect(!rig.coordinator.wantsRecordingHUD)
        #expect(!rig.coordinator.hasActiveRecording)
        #expect(rig.coordinator.message == "No speech detected.")
        #expect(rig.coordinator.resultText.isEmpty)
        #expect(rig.backend.saved.last?.state == .cancelled)
        #expect(rig.adapter.writes.isEmpty)
        #expect(rig.spoken.lines.filter { $0 == "No speech detected." }.count == 1)
        #expect(rig.spoken.lines.last == "No speech detected.")

        // The next dictation starts as usual.
        rig.backend.completeError = nil
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .recording)
    }

    @Test("Any other failed Finish is still a failure the user sees")
    func otherFailuresStayFailures() async throws {
        let rig = RecoveryRig()
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.backend.completeError = RecoveryFailure.incomplete
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .failed)
        #expect(rig.coordinator.message == RecoveryFailure.incomplete.localizedDescription)
        #expect(rig.backend.saved.last?.state == .failed)
    }

    // MARK: Cleanup failure

    @Test("A failed Clean with no destination still shows and copies the raw text and says cleanup failed")
    func failedCleanWithoutDestinationCopiesRaw() async throws {
        let rig = RecoveryRig(mode: .clean)
        rig.adapter.isTrusted = false
        rig.backend.transformError = RecoveryFailure.transform
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.resultText == rig.backend.text.text)
        #expect(rig.coordinator.cleanupFailureReason == RecoveryFailure.transform.localizedDescription)
        #expect(rig.coordinator.message.contains("Cleanup failed"))
        #expect(rig.adapter.writes.isEmpty)
        #expect(rig.pasteboard.string(forType: .string) == rig.backend.text.text)
    }

    @Test("A cleanup failure clears when the next dictation starts")
    func cleanupFailureClearsOnNextStart() async throws {
        let rig = RecoveryRig(mode: .clean)
        rig.backend.transformError = RecoveryFailure.transform
        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.finish()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.cleanupFailureReason != nil)
        #expect(rig.adapter.writes == [rig.backend.text.text])

        rig.coordinator.toggle()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.cleanupFailureReason == nil)
    }
}

// MARK: - Fixtures

private enum RecoveryFailure: LocalizedError {
    case incomplete, noInput, transform
    var errorDescription: String? {
        switch self {
        case .incomplete: "Some audio is incomplete. Nothing was inserted."
        case .noInput: "The microphone has no usable audio format."
        case .transform: "The local Clean model failed."
        }
    }
}

@MainActor
private final class SpokenLog { var lines: [String] = [] }

@MainActor
private final class RecoveryBackend: DictationRecordingBackend {
    let recording = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    let text = DictationTextRevision(rawText: "Bitte send die Rechnung to Müller.",
        text: "Bitte send die Rechnung to Müller.", sourceTranscriptIDs: [UUID()])
    var metadata: DictationRecordingMetadata?
    var completeError: (any Error)?
    var resumeError: (any Error)?
    var transformError: (any Error)?
    private(set) var resumeCount = 0
    private(set) var completeCount = 0
    private(set) var saved: [(state: DictationRecordingState, delivery: DictationDelivery?)] = []

    func dictationBegin() async throws -> DictationRecordingHandle {
        metadata = DictationRecordingMetadata(id: recording.takeID, state: .recording)
        return recording
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws { metadata?.state = .paused }
    func dictationResume(_ handle: DictationRecordingHandle) async throws {
        resumeCount += 1
        if let resumeError { throw resumeError }
        metadata?.state = .recording
    }
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        completeCount += 1
        if let completeError { throw completeError }
        metadata?.state = .ready
        metadata?.textRevision = text
        return text
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? {
        handle == recording ? metadata : nil
    }
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode) async throws -> DictationTransformResult {
        throw transformError ?? RecoveryFailure.transform
    }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        saved.append((state, delivery))
        metadata?.state = state
        if let revision { metadata?.textRevision = revision }
        if let delivery { metadata?.delivery = delivery }
        metadata?.failureMessage = failure
    }
}

@MainActor
private struct RecoveryRig {
    let backend: RecoveryBackend
    let adapter: CleanFinishAdapter
    let spoken: SpokenLog
    /// One named test clipboard, so nothing here touches the user's clipboard.
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("Keystorm-DictationCaptureRecoveryTests"))
    let coordinator: DictationCoordinator

    init(mode: DictationQuickMode = .verbatim) {
        let backend = RecoveryBackend()
        let adapter = CleanFinishAdapter(trace: CleanFinishTrace())
        let preferences = DictationPreferences()
        preferences.mode = mode
        let log = SpokenLog()
        self.spoken = log
        self.backend = backend
        self.adapter = adapter
        coordinator = DictationCoordinator(backend: backend,
            delivery: DictationDeliveryService(adapter: adapter,
                ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999),
            preferences: preferences)
        pasteboard.clearContents()
        coordinator.pasteboard = pasteboard
        coordinator.recordingHUDAutoHideDelay = .milliseconds(1)
        coordinator.announceStatus = { log.lines.append($0) }
    }
}
