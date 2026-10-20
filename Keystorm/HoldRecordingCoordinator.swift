import Foundation
import Observation

/// Serializes hold-to-record transitions without work in the keyboard callback.
/// A release during permission/startup is remembered and drains only the capture that this coordinator owns.
@MainActor @Observable
final class HoldRecordingCoordinator {
    enum Phase: Equatable { case idle, starting, recording, stopping }
    private(set) var phase: Phase = .idle
    private(set) var isPressed = false
    private(set) var acceptsPresses = true
    @ObservationIgnored private let isRecording: @MainActor () -> Bool
    /// Returns true only if this call started the capture, never for a pre-existing capture.
    @ObservationIgnored private let start: @MainActor () async -> Bool
    @ObservationIgnored private let pause: @MainActor () async -> Void
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var failedCurrentPress = false

    init(isRecording: @escaping @MainActor () -> Bool,
         start: @escaping @MainActor () async -> Bool,
         pause: @escaping @MainActor () async -> Void) {
        self.isRecording = isRecording; self.start = start; self.pause = pause
    }

    var isActive: Bool { phase != .idle }

    func setPressed(_ pressed: Bool) {
        guard acceptsPresses || !pressed, isPressed != pressed else { return }
        isPressed = pressed
        if !pressed { failedCurrentPress = false }
        schedule()
    }

    /// Returns true when a pending/owned hold take is being drained. The caller must not start another capture yet.
    @discardableResult
    func cancelForManualControl() -> Bool {
        let wasActive = isActive
        cancel()
        return wasActive
    }

    func cancel() {
        isPressed = false
        failedCurrentPress = false
        schedule()
    }

    /// Synchronous edge used before an asynchronous app shutdown starts.
    func beginShutdown() {
        acceptsPresses = false
        cancel()
    }

    func shutdown() async {
        beginShutdown()
        await waitForSettled()
    }

    /// Waits for permission/start/pause transitions, rather than waiting for a held recording to end.
    func waitForSettled() async {
        while let worker { await worker.value }
    }

    private func schedule() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    private func run() async {
        defer { worker = nil }
        while true {
            switch phase {
            case .idle:
                guard acceptsPresses, isPressed, !failedCurrentPress else { return }
                guard !isRecording() else {
                    // A held shortcut never acquires or pauses a manually started capture.
                    failedCurrentPress = true
                    return
                }
                phase = .starting
                let ownsCapture = await start()
                if ownsCapture {
                    phase = .recording
                } else {
                    phase = .idle
                    // A failed/declined permission request must not loop while the key remains down.
                    failedCurrentPress = isPressed
                    return
                }
            case .recording:
                if !isRecording() { phase = .idle; continue }
                guard !acceptsPresses || !isPressed else { return }
                phase = .stopping
                await pause()
                if isRecording() {
                    // Keep ownership visible if the recorder failed to stop; a later cancel can retry safely.
                    phase = .recording
                    return
                }
                // New presses during pause only change desired state. No newer start can run until this completes.
                phase = .idle
            case .starting, .stopping:
                // Only this worker creates transitions; event callbacks update desired state and never spawn competitors.
                assertionFailure("A capture transition was entered by more than one worker.")
                return
            }
        }
    }
}
