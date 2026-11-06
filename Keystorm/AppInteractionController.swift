import AppKit
import Observation
import UniformTypeIdentifiers

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
    let shortcuts: ShortcutManager
    let readback = BriefReadback()
    private(set) var dictation: DictationCoordinator?
    /// Watches Escape only while a dictation is starting, recording or paused. `configure` creates the real one when
    /// shortcuts are started; tests assign a fake before `configure`.
    @ObservationIgnored var escapeWatcher: (any EscapeKeyWatching)?
    @ObservationIgnored private var dictationHUD: DictationHUDController?
    @ObservationIgnored private weak var workspace: WorkspaceModel?
    @ObservationIgnored var showWorkspace: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var hold: HoldRecordingCoordinator?
    @ObservationIgnored private var legacyRecording: (any LegacyRecordingBackend)?
    @ObservationIgnored private var legacyRecordingTask: Task<Void, Never>?
    @ObservationIgnored private var recordingHUD: RecordingHUDController?
    @ObservationIgnored private var recordingHUDObservation: UUID?
    @ObservationIgnored private var preparedDictationMode: DictationQuickMode?
    private(set) var readbackBlockRanges: [UUID: NSRange] = [:]

    /// Tests pass a shortcut manager with a private defaults suite so preferences never reach the real ones.
    init(shortcuts: ShortcutManager? = nil) {
        self.shortcuts = shortcuts ?? ShortcutManager()
    }

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
        observeDictationWarmup()
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
        shortcuts.isDictationActive = { [weak self] in self?.dictationAcceptsFinish == true }
        shortcuts.onDictationCommand = { [weak self] command in self?.handleDictationCommand(command) }
        var escape = escapeWatcher
        #if DEBUG
        let uiTesting = ProcessInfo.processInfo.environment["KEYSTORM_UI_TEST_ROOT"] != nil
        #else
        let uiTesting = false
        #endif
        // The real Escape hotkey only exists when real shortcuts do, so tests never claim Escape on this Mac.
        if escape == nil, startShortcuts, !uiTesting { escape = EscapeCancelHotkey() }
        escape?.onEscape = { [weak self] in self?.cancelDictationFromEscape() }
        escapeWatcher = escape
        #if DEBUG
        if ProcessInfo.processInfo.environment["KEYSTORM_UI_TEST_ROOT"] != nil { return }
        #endif
        if startShortcuts { shortcuts.start() }
        #if DEBUG
        startDebugAutoTakeIfRequested()
        #endif
    }

    #if DEBUG
    /// Isolated file-audio runs only: `KEYSTORM_DEBUG_AUTOTAKE=<seconds>` starts one take once the workspace has
    /// opened, finishes it after that many seconds and logs the outcome. `KEYSTORM_DEBUG_AUTOTAKE_QUIT=1` then quits.
    /// It drives the same coordinator calls as the shortcut, so a crash soak does not need synthetic key events.
    private func startDebugAutoTakeIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let recordSeconds = environment["KEYSTORM_DEBUG_AUTOTAKE"].flatMap(Double.init), recordSeconds > 0,
              let configuration = try? DebugAudioValidationConfiguration.configuration() else { return }
        let quits = environment["KEYSTORM_DEBUG_AUTOTAKE_QUIT"] == "1"
        Task { @MainActor [weak self] in
            @MainActor func wait(for states: Set<DictationFlowState>, seconds: Double) async -> Bool {
                let deadline = ContinuousClock.now + .seconds(seconds)
                while ContinuousClock.now < deadline {
                    if let state = self?.dictation?.state, states.contains(state) { return true }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return false
            }
            try? await Task.sleep(for: .seconds(6))
            guard let dictation = self?.dictation else { return }
            // Whatever field is focused elsewhere decides where Finish would write, and a protected one refuses
            // Start. Accuracy runs measure the text, so they bring Keystorm itself to the front.
            if environment["KEYSTORM_DEBUG_AUTOTAKE_ACTIVATE"] == "1" {
                NSApp.activate()
                try? await Task.sleep(for: .milliseconds(600))
            }
            if environment["KEYSTORM_DEBUG_AUTOTAKE_SETTINGS"] == "1" {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            // Take the mode for this run only; the stored preference is put back before the process exits.
            let storedMode = dictation.preferences.mode
            // The finished text must not land on the real clipboard during a run.
            let storedCopy = dictation.preferences.copyWhenNotInserted
            dictation.preferences.copyWhenNotInserted = false
            if let name = environment["KEYSTORM_DEBUG_AUTOTAKE_MODE"], let mode = DictationQuickMode(rawValue: name) {
                dictation.preferences.mode = mode
            }
            dictation.toggle()
            guard await wait(for: [.recording], seconds: 30) else {
                configuration.log("autotake-no-recording", fields: ["state": dictation.state.rawValue,
                    "message": dictation.message])
                dictation.preferences.mode = storedMode
                dictation.preferences.copyWhenNotInserted = storedCopy
                if quits { exit(0) }
                return
            }
            // `KEYSTORM_DEBUG_AUTOTAKE_PAUSES="60:8,120:8"` pauses after 60 s of recording for 8 s, and so on. The
            // record time counts only time spent recording, so a pause never eats into it.
            let pauses = (environment["KEYSTORM_DEBUG_AUTOTAKE_PAUSES"] ?? "").split(separator: ",").compactMap { part -> (Double, Double)? in
                let pair = part.split(separator: ":").compactMap { Double($0) }
                return pair.count == 2 ? (pair[0], pair[1]) : nil
            }.sorted { $0.0 < $1.0 }
            var recorded = 0.0
            var nextPause = 0
            var pauseLog: [String] = []
            while recorded < recordSeconds {
                try? await Task.sleep(for: .milliseconds(100))
                if dictation.state == .recording { recorded += 0.1 }
                if nextPause < pauses.count, recorded >= pauses[nextPause].0, dictation.state == .recording {
                    let (_, length) = pauses[nextPause]
                    nextPause += 1
                    dictation.pauseResume()
                    guard await wait(for: [.paused], seconds: 30) else { pauseLog.append("pause-failed:\(dictation.state.rawValue)"); continue }
                    try? await Task.sleep(for: .seconds(length))
                    dictation.pauseResume()
                    if await wait(for: [.recording], seconds: 30) { pauseLog.append("pause-ok@\(Int(recorded))s/\(Int(length))s") }
                    else { pauseLog.append("resume-failed:\(dictation.state.rawValue)") }
                }
            }
            let finishStarted = ContinuousClock.now
            dictation.finish()
            let finished = await wait(for: [.ready, .failed], seconds: 180)
            let components = finishStarted.duration(to: .now).components
            configuration.log("autotake-result", fields: [
                "finished": finished, "state": dictation.state.rawValue, "text": dictation.resultText,
                "message": dictation.message, "destination": dictation.destinationLabel,
                "mode": dictation.captureMode.rawValue, "pauses": pauseLog,
                "rawText": dictation.handle.flatMap { self?.workspace?.dictationMetadata($0)?.textRevision?.rawText } ?? "",
                "finishSeconds": Double(components.seconds) + Double(components.attoseconds) / 1e18])
            try? await Task.sleep(for: .seconds(4))
            dictation.preferences.mode = storedMode
            dictation.preferences.copyWhenNotInserted = storedCopy
            if quits { exit(0) }
        }
    }
    #endif

    /// File > Transcribe Audio or Video File…: asks for a file, then runs it through the dictation engine.
    func chooseAndTranscribeFile() {
        guard let dictation, !dictation.reservesCapture, !dictation.isTransitioning else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Transcribe an audio or video file")
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showWorkspace?()
        dictation.transcribeFile(url)
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

    /// Starting, recording or paused: a shortcut press finishes the take, and Escape cancels it.
    private var dictationAcceptsFinish: Bool {
        guard let state = dictation?.state else { return false }
        return state == .starting || state == .recording || state == .paused
    }

    /// Start and finish from the dictation shortcut's tap and hold gesture. Both only act in the states they apply
    /// to, so a release after a refused or finished take never starts another.
    private func handleDictationCommand(_ command: DictationGestureCommand) {
        guard let dictation else { return }
        workspace?.recordPerformance(kind: "hotkey-main-queue",
            milliseconds: Double(shortcuts.lastDispatchNanoseconds) / 1_000_000)
        switch command {
        case .start:
            switch dictation.state {
            case .idle, .ready, .failed: perform(.toggleDictation)
            case .starting, .recording, .paused, .processing: break
            }
        case .finish:
            switch dictation.state {
            // Finish while the microphone is still opening is remembered and runs once recording begins.
            case .starting: dictation.toggle()
            case .recording, .paused: dictation.finish()
            case .idle, .ready, .failed, .processing: break
            }
        }
    }

    /// Escape ends a dictation that is starting, recording or paused, and is never watched otherwise.
    private func cancelDictationFromEscape() {
        guard let dictation, dictationAcceptsFinish, dictation.canCancel else { return }
        shortcuts.cancelDictationGesture()
        dictation.cancel()
    }

    /// Follows the dictation state: Escape is watched only while there is a take to cancel.
    func syncEscapeWatcher() {
        escapeWatcher?.setActive(dictationAcceptsFinish)
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

    /// Event-driven idle preparation. Busy changes allow a pending mode selection to retry;
    /// the remembered selection prevents the warm-up's own completion from scheduling it again.
    private func observeDictationWarmup() {
        guard let workspace, let dictation, let generation = recordingHUDObservation else { return }
        var mode = DictationQuickMode.verbatim
        var installed = false
        var idle = false
        withObservationTracking {
            mode = dictation.preferences.mode
            installed = workspace.installedModelIDs.contains(ModelCatalog.primaryText.id)
            idle = !workspace.isBusy && !workspace.isRecording && !workspace.isCaptureTransitioning
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.recordingHUDObservation == generation else { return }
                self.observeDictationWarmup()
            }
        }
        if !installed || !mode.transformsOnFinish { preparedDictationMode = nil; return }
        if preparedDictationMode != mode, idle, workspace.prepareNextDictation(mode: mode) {
            preparedDictationMode = mode
        }
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
                _ = dictation.wantsRecordingHUD; _ = dictation.recordingHUDDismissed
                if let handle = dictation.handle { nextCaptureStatus = workspace.dictationCaptureStatus(handle) }
                showDictation = dictation.wantsRecordingHUD && !dictation.recordingHUDDismissed && (dictation.hasActiveRecording ||
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
        syncEscapeWatcher()
        if let dictation {
            // A dismissed HUD stays hidden until the next Start, whatever changes after it.
            showDictation = dictation.wantsRecordingHUD && !dictation.recordingHUDDismissed && (dictation.hasActiveRecording ||
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
        escapeWatcher?.setActive(false)
        recordingHUDObservation = nil
        recordingHUD?.hide()
        dictationHUD?.hide()
        readback.stop()
    }
}
