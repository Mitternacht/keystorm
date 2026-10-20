import AppKit
import Observation

/// Capture commands shared by the legacy brief shortcuts and hold coordinator.
/// This boundary also lets interaction tests verify ownership without opening a microphone.
@MainActor
protocol LegacyRecordingBackend: AnyObject {
    var isRecording: Bool { get }
    var isCaptureTransitioning: Bool { get }
    var hasOpenTake: Bool { get }
    var captureIntent: CaptureIntent { get set }
    var openTake: BriefTake? { get }
    func startRecording() async
    func pauseRecording() async
    func resumeRecording() async
    func startNewTake(intent: CaptureIntent?) async
}

extension WorkspaceModel: LegacyRecordingBackend {}

@MainActor @Observable
final class AppInteractionController {
    let shortcuts = ShortcutManager()
    let readback = BriefReadback()
    private(set) var dictation: DictationCoordinator?
    @ObservationIgnored private var dictationHUD: DictationHUDController?
    @ObservationIgnored private weak var workspace: WorkspaceModel?
    @ObservationIgnored var showWorkspace: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var hold: HoldRecordingCoordinator?
    @ObservationIgnored private var legacyRecording: (any LegacyRecordingBackend)?
    @ObservationIgnored private var legacyRecordingTask: Task<Void, Never>?
    @ObservationIgnored private var recordingHUD: RecordingHUDController?
    @ObservationIgnored private var recordingHUDObservation: UUID?
    private(set) var readbackBlockRanges: [UUID: NSRange] = [:]

    func configure(workspace: WorkspaceModel, showWorkspace: @escaping @MainActor @Sendable () -> Void,
                   dictation injectedDictation: DictationCoordinator? = nil,
                   legacyRecording injectedRecording: (any LegacyRecordingBackend)? = nil,
                   startShortcuts: Bool = true) {
        self.workspace = workspace
        self.showWorkspace = showWorkspace
        guard !configured else { return }
        configured = true
        let recording = injectedRecording ?? workspace
        legacyRecording = recording
        let flow = injectedDictation ?? DictationCoordinator(backend: workspace,
            preferences: DictationPreferences(defaults: .standard))
        dictation = flow
        dictationHUD = DictationHUDController(coordinator: flow, showWorkspace: showWorkspace)
        recordingHUD = RecordingHUDController(onStop: { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            if workspace.isRecording { self.perform(.toggleRecording) }
            else { workspace.dismissRecordingHUD() }
        }, onOpenBrief: { [weak self] in self?.perform(.showWorkspace) })
        recordingHUDObservation = UUID()
        observeRecordingHUD()
        hold = HoldRecordingCoordinator(
            isRecording: { [weak recording] in recording?.isRecording == true },
            start: { [weak recording, weak self] in
                guard let self, let recording, self.dictation?.reservesCapture != true,
                      !recording.isRecording, !recording.isCaptureTransitioning else { return false }
                self.readback.stop()
                if !recording.hasOpenTake { recording.captureIntent = .addMaterial }
                await recording.startRecording()
                return recording.isRecording
            },
            pause: { [weak recording, weak self] in
                // A stale legacy release must never pause a newer dictation capture.
                guard self?.dictation?.hasActiveRecording != true else { return }
                await recording?.pauseRecording()
            }
        )
        shortcuts.onAction = { [weak self] action in
            guard let self else { return }
            self.workspace?.recordPerformance(kind: "hotkey-main-queue",
                milliseconds: Double(self.shortcuts.lastDispatchNanoseconds) / 1_000_000)
            self.perform(action)
        }
        shortcuts.onHoldRecording = { [weak self] pressed in self?.handleHold(pressed) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["KEYSTORM_UI_TEST_ROOT"] != nil { return }
        #endif
        if startShortcuts { shortcuts.start() }
    }

    func perform(_ action: ShortcutAction) {
        guard let workspace else { return }
        switch action {
        case .toggleDictation:
            readback.stop()
            dictation?.toggle()
        case .pauseResumeDictation:
            dictation?.pauseResume()
        case .toggleRecording, .recordEdit:
            performLegacyRecording(action)
        case .showWorkspace:
            showWorkspace?()
            NSApp.activate()
        case .readSection: readSelectedSection()
        case .pauseResumeReadback: readback.togglePause()
        case .undoBriefEdit: Task { await workspace.undoBrief() }
        case .insertClipboard: insertClipboard()
        }
    }

    private func performLegacyRecording(_ action: ShortcutAction) {
        guard dictation?.reservesCapture != true,
              let recording = legacyRecording, legacyRecordingTask == nil else { return }
        guard hold?.cancelForManualControl() != true else { return }
        readback.stop()
        legacyRecordingTask = Task { [weak self, weak recording] in
            guard let self else { return }
            defer { self.legacyRecordingTask = nil }
            // Dictation can acquire ownership after the shortcut callback, before this Task runs.
            guard !Task.isCancelled, let recording, self.dictation?.reservesCapture != true else { return }
            if recording.isRecording {
                await recording.pauseRecording()
            } else if action == .toggleRecording {
                if !recording.hasOpenTake { recording.captureIntent = .addMaterial }
                await recording.startRecording()
            } else if recording.openTake?.intent == .editBrief {
                await recording.resumeRecording()
            } else {
                await recording.startNewTake(intent: .editBrief)
            }
        }
    }

    private func handleHold(_ pressed: Bool) {
        // Always forward releases: a pending legacy-owned startup may still need draining.
        guard !pressed || dictation?.reservesCapture != true else { return }
        hold?.setPressed(pressed)
    }

    /// Joins shortcut transitions without waiting for a key to be released.
    func waitForRecordingControls() async {
        await legacyRecordingTask?.value
        await hold?.waitForSettled()
    }

    /// Observation re-arms only after a relevant change. The capture clock already runs;
    /// the HUD adds no timer and never scans the complete transcript during clock ticks.
    private func observeRecordingHUD() {
        guard let workspace, let generation = recordingHUDObservation else { return }
        var nextSnapshot: RecordingHUDSnapshot?
        var showDictation = false
        var dictationElapsed = 0.0
        var nextCaptureStatus: DictationCaptureStatus?
        withObservationTracking {
            if let dictation {
                _ = dictation.state; _ = dictation.message; _ = dictation.isTransitioning
                _ = dictation.wantsRecordingHUD
                if let handle = dictation.handle { nextCaptureStatus = workspace.dictationCaptureStatus(handle) }
                showDictation = dictation.wantsRecordingHUD && (dictation.hasActiveRecording ||
                    (dictation.state == .ready && dictation.handle != nil) || dictation.state == .failed)
                dictationElapsed = workspace.recordingHUDElapsed
            }
            nextSnapshot = workspace.recordingHUDSnapshot
            if nextSnapshot != nil {
                let seconds = max(0, Int(workspace.recordingHUDElapsed))
                nextSnapshot?.elapsed = String(format: "%d:%02d", seconds / 60, seconds % 60)
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.recordingHUDObservation == generation else { return }
                self.observeRecordingHUD()
            }
        }
        // Reconcile and presentation writes stay outside observation tracking.
        dictation?.reconcileCaptureStatus(nextCaptureStatus)
        if let dictation {
            showDictation = dictation.wantsRecordingHUD && (dictation.hasActiveRecording ||
                (dictation.state == .ready && dictation.handle != nil) || dictation.state == .failed)
        }
        if showDictation {
            recordingHUD?.hide()
            dictationHUD?.update(elapsed: dictationElapsed, preview: nextSnapshot?.transcript ?? "")
        } else {
            dictationHUD?.hide()
            if let nextSnapshot { recordingHUD?.update(nextSnapshot) }
            else { recordingHUD?.hide() }
        }
    }

    func shutdown() async {
        stop()
        await hold?.shutdown()
        await legacyRecordingTask?.value
        await dictation?.waitUntilSettled()
    }

    func readSelectedSection() {
        guard let workspace, let document = workspace.currentBrief else { return }
        guard !workspace.isRecording else { workspace.error = "Pause recording before listening to the brief."; return }
        let section = document.section(workspace.selectedSectionKind)
        var ranges: [UUID: NSRange] = [:]
        var offset = 0
        for block in section.blocks {
            let length = (block.text as NSString).length
            ranges[block.id] = NSRange(location: offset, length: length)
            offset += length + 2
        }
        readbackBlockRanges = ranges
        readback.read(text: section.blocks.map(\.text).joined(separator: "\n\n"),
                      sectionID: section.kind.rawValue, documentRevisionID: document.revisionID)
        if let error = readback.error { workspace.error = error }
    }

    func highlight(for blockID: UUID) -> NSRange? {
        guard let spoken = readback.currentRange, let block = readbackBlockRanges[blockID] else { return nil }
        let overlap = NSIntersectionRange(spoken, block)
        guard overlap.length > 0 else { return nil }
        return NSRange(location: overlap.location - block.location, length: overlap.length)
    }

    func validateReadback() {
        guard readback.isSpeaking else { return }
        guard let workspace, let document = workspace.currentBrief else { readback.stop(); return }
        if workspace.isRecording { readback.stop(); return }
        let section = document.section(workspace.selectedSectionKind)
        readback.validate(sectionID: section.kind.rawValue, documentRevisionID: document.revisionID,
                          text: section.blocks.map(\.text).joined(separator: "\n\n"))
    }

    func insertClipboard() {
        guard let workspace, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        guard text.utf8.count <= 131_072 else { workspace.error = "Choose an exact reference under 128 KB."; return }
        Task { await workspace.insertExactReference(text: text, filePath: nil) }
    }

    func stop() {
        legacyRecordingTask?.cancel()
        hold?.beginShutdown()
        dictation?.cancelForShutdown()
        shortcuts.stop()
        recordingHUDObservation = nil
        recordingHUD?.hide()
        dictationHUD?.hide()
        readback.stop()
    }
}
