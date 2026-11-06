import AppKit
import Foundation
import Testing
@testable import Keystorm

/// Seeded random sequences of shortcut edges, Escape and button presses against the real coordinator, gesture machine and
/// shortcut manager, with a backend that answers after random delays. Whatever the order, a take is never leaked
/// (two open at once, or one that nothing finished or cancelled) and the flow never gets stuck.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct DictationRandomizedStressTests {
    @Test("Random shortcut, Escape and button sequences never leak a take or wedge the flow",
          arguments: Array(UInt64(1)...UInt64(16)))
    func randomSequences(seed: UInt64) async throws {
        let rig = try StressRig()
        var random = SeededGenerator(seed: seed)
        var clock = 0.0
        var trace: [String] = []
        for step in 0..<120 {
            clock += Double.random(in: 0.01...0.6, using: &random)
            let choice = Int.random(in: 0..<10, using: &random)
            trace.append("\(step): op \(choice) from \(rig.flow.state.rawValue)")
            switch choice {
            case 0, 1: rig.key(true, at: clock)
            case 2, 3: rig.key(false, at: clock)
            case 4: rig.escape.press()
            case 5: rig.flow.finish()
            case 6: rig.flow.cancel()
            case 7: rig.flow.pauseResume()
            case 8: rig.flow.toggle()
            default: rig.manager.setDictationShortcutMode(
                [DictationShortcutMode.toggle, .pushToTalk, .tapOrHold].randomElement(using: &random)!)
            }
            rig.controller.syncEscapeWatcher()
            // Sometimes let the backend run, sometimes fire the next input while it is still working.
            if Bool.random(using: &random) { try await Task.sleep(for: .milliseconds(Int.random(in: 0...6, using: &random))) }
            else { await Task.yield() }
            #expect(rig.backend.openTakes <= 1,
                    "seed \(seed): two takes were open at once. \(trace.suffix(30).joined(separator: " | ")) backend: \(rig.backend.log.suffix(14).joined(separator: ", "))")
            if rig.backend.openTakes > 1 { break }
        }
        // Drain whatever the sequence left behind: cancel an open take, then let every task settle.
        for _ in 0..<6 {
            await rig.flow.waitUntilSettled()
            if rig.flow.canCancel { rig.flow.cancel() }
            await rig.flow.waitUntilSettled()
        }
        #expect([.idle, .ready, .failed].contains(rig.flow.state), "seed \(seed): stuck in \(rig.flow.state)")
        #expect(rig.backend.openTakes == 0, "seed \(seed): \(rig.backend.openTakes) take(s) leaked")
        #expect(rig.backend.maximumOpenTakes <= 1, "seed \(seed): two takes were open at once")
        // The flow still works afterwards.
        // A key still held from the sequence would swallow the next press as a repeat, so let go first.
        rig.key(false, at: clock + 99)
        rig.manager.setDictationShortcutMode(.toggle)
        rig.key(true, at: clock + 100)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .recording, "seed \(seed): a fresh start after the sequence ended in \(rig.flow.state)")
        rig.flow.cancel()
        await rig.flow.waitUntilSettled()
        await rig.close()
    }
}

/// Deterministic generator, so a failing seed replays exactly.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
private final class StressBackend: DictationRecordingBackend {
    private var generator = SeededGenerator(seed: 99)
    private(set) var openTakes = 0
    private(set) var maximumOpenTakes = 0
    private var open = Set<UUID>()
    private(set) var log: [String] = []

    private func pause() async throws { try await Task.sleep(for: .milliseconds(Int.random(in: 0...4, using: &generator))) }
    private func close(_ handle: DictationRecordingHandle) {
        open.remove(handle.takeID)
        openTakes = open.count
    }

    func dictationBegin() async throws -> DictationRecordingHandle {
        let handle = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
        log.append("begin \(handle.takeID.uuidString.prefix(4))")
        open.insert(handle.takeID)
        openTakes = open.count
        maximumOpenTakes = max(maximumOpenTakes, openTakes)
        // Like the real backend: once the microphone is open there is no cancellation point before the handle returns.
        try? await pause()
        return handle
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws { try await pause() }
    func dictationResume(_ handle: DictationRecordingHandle) async throws { try await pause() }
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        log.append("complete-start \(handle.takeID.uuidString.prefix(4))")
        try await pause()
        log.append("complete-end \(handle.takeID.uuidString.prefix(4))")
        close(handle)
        return DictationTextRevision(rawText: "Hello there.", text: "Hello there.", sourceTranscriptIDs: [])
    }
    func dictationCancel(_ handle: DictationRecordingHandle) async throws {
        log.append("cancel-start \(handle.takeID.uuidString.prefix(4))")
        try? await pause()
        log.append("cancel-end \(handle.takeID.uuidString.prefix(4))")
        close(handle)
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? { nil }
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode) async throws -> DictationTransformResult {
        throw StressFailure.unsupported
    }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {}
}

private enum StressFailure: Error { case unsupported }

@MainActor
private struct StressUntrustedAdapter: DictationDeliveryAdapter {
    var isTrusted: Bool { false }
    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { nil }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField {
        throw StressFailure.unsupported
    }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { false }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata { throw StressFailure.unsupported }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        throw StressFailure.unsupported
    }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        .rejected
    }
}

@MainActor
private final class StressEscape: EscapeKeyWatching {
    var onEscape: (@MainActor () -> Void)?
    private(set) var isActive = false
    func setActive(_ active: Bool) -> Bool { isActive = active; return true }
    func press() { if isActive { onEscape?() } }
}

@MainActor
private final class StressLegacyRecorder: LegacyRecordingBackend {
    var isRecording = false
    var isCaptureTransitioning = false
    var captureIntent: CaptureIntent = .editBrief
    var openTake: BriefTake?
    var hasOpenTake: Bool { openTake != nil }
    func startRecording() async {}
    func pauseRecording() async {}
    func resumeRecording() async {}
    func startNewTake(intent: CaptureIntent?) async {}
}

/// Private defaults suite, private pasteboard, temp root: never the user's settings, clipboard or library.
@MainActor
private struct StressRig {
    let suite: String
    let defaults: UserDefaults
    let workspace: WorkspaceModel
    let manager: ShortcutManager
    let backend = StressBackend()
    let flow: DictationCoordinator
    let controller: AppInteractionController
    let escape = StressEscape()
    let base = DispatchTime.now().uptimeNanoseconds

    init() throws {
        suite = "Keystorm.StressRig.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        workspace = WorkspaceModel(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-Stress-" + UUID().uuidString))
        manager = ShortcutManager(defaults: defaults, modifierMonitor: StressModifierMonitor())
        flow = DictationCoordinator(backend: backend,
            delivery: DictationDeliveryService(adapter: StressUntrustedAdapter()))
        flow.preferences.copyWhenNotInserted = false
        flow.pasteboard = NSPasteboard.withUniqueName()
        controller = AppInteractionController(shortcuts: manager)
        controller.escapeWatcher = escape
        controller.configure(workspace: workspace, showWorkspace: {}, dictation: flow,
                             legacyRecording: StressLegacyRecorder(), startShortcuts: false)
    }

    func key(_ pressed: Bool, at seconds: Double) {
        manager.handleShortcut(.toggleDictation, pressed: pressed, enqueuedAt: base + UInt64(seconds * 1_000_000_000))
    }

    func close() async {
        await controller.shutdown()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class StressModifierMonitor: ModifierShortcutMonitoring {
    var onOutput: (@MainActor (ModifierOnlyDetector.Output) -> Void)?
    func start(key: ModifierKey) -> ModifierMonitorStatus { .active }
    func stop() {}
    func reset() {}
}
