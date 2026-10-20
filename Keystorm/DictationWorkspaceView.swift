import AppKit
import Observation
import SwiftUI

/// Dictation is the primary workspace. The earlier document workflow remains available explicitly.
struct DictationWorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var interactions: AppInteractionController
    @Environment(\.openWindow) private var openWindow
    @State private var showDeveloperBriefs = false
    @State private var initialized = false

    var body: some View {
        Group {
            if showDeveloperBriefs {
                ContentView(model: model, interactions: interactions)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                Task {
                                    await model.leaveLegacyLibrary()
                                    showDeveloperBriefs = false
                                }
                            } label: {
                                Label("Dictation", systemImage: "chevron.backward")
                            }
                            .accessibilityIdentifier("dictation.back")
                            .disabled(model.isRecording || model.isCaptureTransitioning)
                        }
                    }
            } else if model.isLoadingLegacyLibrary {
                ProgressView("Opening saved documents…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if initialized, let coordinator = interactions.dictation {
                DictationMainWorkspace(model: model, interactions: interactions, coordinator: coordinator,
                    openDeveloperBriefs: {
                        Task {
                            guard !coordinator.reservesCapture, !coordinator.isTransitioning else { return }
                            if await model.loadLegacyLibrary() { showDeveloperBriefs = true }
                        }
                    })
            } else {
                ProgressView("Opening local dictation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            interactions.configure(workspace: model) { openWindow(id: "workspace") }
            await model.initialize()
            initialized = true
        }
        .frame(minWidth: 920, minHeight: 650)
        #if DEBUG
        .safeAreaInset(edge: .top, spacing: 0) {
            if let status = model.debugAudioSourceStatus {
                Label(status, systemImage: "testtube.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.bar)
                    .accessibilityIdentifier("dictation.fileValidation")
            }
        }
        #endif
    }
}

private struct DictationMainWorkspace: View {
    @Bindable var model: WorkspaceModel
    @Bindable var interactions: AppInteractionController
    @Bindable var coordinator: DictationCoordinator
    let openDeveloperBriefs: () -> Void
    @State private var showModels = false
    @State private var showDictionary = false
    @State private var showRecordingTools = false
    @State private var recordingToolsHandle: DictationRecordingHandle?

    var body: some View {
        NavigationSplitView {
            DictationHistorySidebar(model: model, coordinator: coordinator,
                openDeveloperBriefs: openDeveloperBriefs)
        } detail: {
            DictationEditorPane(coordinator: coordinator, model: model,
                shortcut: interactions.shortcuts.shortcut(for: .toggleDictation)?.displayName)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Keystorm")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        guard await coordinator.flushForRecordingTools(), let handle = coordinator.handle else { return }
                        recordingToolsHandle = handle
                        showRecordingTools = true
                    }
                } label: {
                    Label("Recording tools", systemImage: "waveform")
                }
                .help("Listen, trim, replace, restore, or export this recording")
                .accessibilityIdentifier("dictation.recordingTools")
                .disabled(coordinator.handle == nil || coordinator.hasActiveRecording || coordinator.isTransitioning ||
                    model.isRecording || model.isCaptureTransitioning || model.isBusy)
                Button { showDictionary = true } label: {
                    Label("Dictionary", systemImage: "character.book.closed")
                }
                .help("Review the terminology learned from your transcript corrections")
                .accessibilityIdentifier("dictation.dictionary")
                .disabled(coordinator.hasActiveRecording || coordinator.isTransitioning ||
                    model.isRecording || model.isCaptureTransitioning)
                Button { showModels = true } label: {
                    Label("Local models", systemImage: "cpu")
                }
                .help("Manage the models stored on this Mac")
                Menu {
                    Button("Allow insertion into apps…") { coordinator.requestAccessibilityPermission() }
                    Button("Open Accessibility settings…") { coordinator.openAccessibilitySettings() }
                } label: {
                    Label("Insertion access", systemImage: "keyboard")
                }
                .help("Manage permission to insert dictation into other apps")
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $showModels) {
            ModelManagerView(model: model).frame(minWidth: 760, minHeight: 560)
        }
        .sheet(isPresented: $showRecordingTools) {
            if let handle = recordingToolsHandle {
                DictationRecordingToolsView(model: model, handle: handle,
                    onAudioChanged: {
                        guard coordinator.handle == handle else { return }
                        coordinator.audioSourceDidChange()
                    },
                    onRetranscribe: {
                        guard coordinator.handle == handle else {
                            model.error = String(localized: "The selected recording changed. Open that recording’s tools again before transcribing.")
                            return
                        }
                        coordinator.retranscribeSavedRecording()
                    })
            }
        }
        .sheet(isPresented: $showDictionary) {
            DictationLearningDictionarySheet(controller: model.learningDictionary,
                unavailableMessage: model.recoveryMessages.first(where: { $0.contains("learning dictionary") }) ??
                    String(localized: "The local learning dictionary could not be opened. Reopen Keystorm to retry; your manually maintained dictionary is preserved."))
        }
        .alert("Keystorm", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

private struct DictationLearningDictionarySheet: View {
    let controller: LearningDictionaryController?
    let unavailableMessage: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Dictionary", systemImage: "character.book.closed").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            if let controller {
                LearningDictionaryView(controller: controller)
            } else {
                ContentUnavailableView("Learning dictionary unavailable", systemImage: "exclamationmark.circle",
                    description: Text(unavailableMessage))
                    .padding(24)
                    .accessibilityIdentifier("learning.unavailable")
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 650)
    }
}

/// Indexed headers keep sidebar updates independent of full transcript/audio payloads.
private struct DictationHistorySidebar: View {
    let model: WorkspaceModel
    let coordinator: DictationCoordinator
    let openDeveloperBriefs: () -> Void
    @State private var selectionTask: Task<Void, Never>?
    @State private var selectionGeneration = UUID()

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding<String?>(
                get: { coordinator.handle.map { $0.sessionID.uuidString + "/" + $0.takeID.uuidString } },
                set: { id in
                    guard let id, let entry = model.dictationHistoryEntries.first(where: { $0.stableID == id }) else { return }
                    select(entry.handle)
                }
            )) {
                Section("History") {
                    if model.dictationHistoryEntries.isEmpty, !model.isLoadingHistory {
                        Text("Your dictations will appear here.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(model.dictationHistoryEntries, id: \.stableID) { entry in
                        DictationHistoryRow(title: entry.title, preview: entry.preview,
                            createdAt: entry.createdAt, state: entry.state)
                            .tag(entry.stableID)
                            .accessibilityIdentifier("dictation.history.\(entry.id)")
                    }
                    if model.historyHasMore {
                        Button("Load older recordings") { Task { await model.loadMoreDictationHistory() } }
                            .disabled(model.isLoadingHistory)
                            .accessibilityIdentifier("dictation.history.loadMore")
                    }
                    if model.isLoadingHistory { ProgressView().controlSize(.small) }
                }
            }
            .listStyle(.sidebar)
            .disabled(coordinator.hasActiveRecording || coordinator.isTransitioning)
            if let error = model.historyError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Try again") { Task { await model.refreshDictationHistory() } }
                }.padding(12)
            }
            if model.historyMaintenanceAvailable || model.historyPendingRepairCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    if model.historyPendingRepairCount > 0 {
                        Text("Some recordings need a recovery check.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await model.checkHistoryForRecovery() }
                    } label: {
                        Label("Check library", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isCheckingHistory || coordinator.reservesCapture || coordinator.isTransitioning)
                    .help("Find recovered recordings. Existing recordings are checked when you open them.")
                    .accessibilityIdentifier("dictation.history.checkLibrary")
                    if model.isCheckingHistory { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            Divider()
            Button(action: openDeveloperBriefs) {
                Label("Developer briefs", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).padding(16).foregroundStyle(.secondary)
            .disabled(coordinator.hasActiveRecording || coordinator.isTransitioning)
            .accessibilityIdentifier("dictation.openLegacy")
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        .onDisappear { selectionTask?.cancel(); model.cancelHistorySelection() }
    }

    private func select(_ handle: DictationRecordingHandle) {
        guard !coordinator.reservesCapture, !coordinator.isTransitioning else { return }
        selectionTask?.cancel()
        model.cancelHistorySelection()
        let generation = UUID()
        selectionGeneration = generation
        selectionTask = Task { @MainActor in
            do {
                if coordinator.handle != nil, !(await coordinator.flushForRecordingTools()) {
                    throw KeystormError.message("Save the current edit before opening another recording.")
                }
                try Task.checkCancellation()
                try await model.selectHistoryRecording(handle)
                try Task.checkCancellation()
                guard selectionGeneration == generation, !coordinator.reservesCapture,
                      !coordinator.isTransitioning else { return }
                coordinator.restore(handle)
            } catch is CancellationError { }
            catch { model.error = error.localizedDescription }
        }
    }
}

private struct DictationHistoryRow: View {
    let title: String
    let preview: String
    let createdAt: Date
    let state: DictationRecordingState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                if state == .paused {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                        .accessibilityLabel("Paused recording")
                } else if state == .failed {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                        .accessibilityLabel("Needs attention")
                }
            }
            if !preview.isEmpty {
                Text(preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

private struct DictationEditorPane: View {
    @Bindable var coordinator: DictationCoordinator
    let model: WorkspaceModel
    let shortcut: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DictationPaneHeader(state: coordinator.state, destinationLabel: coordinator.destinationLabel,
                outputMode: coordinator.hasActiveRecording ? coordinator.captureMode.outputMode :
                    (coordinator.state == .idle ? coordinator.preferences.mode.outputMode : coordinator.outputMode))
            DictationQuickModeControl(preferences: coordinator.preferences,
                captureMode: coordinator.hasActiveRecording ? coordinator.captureMode : nil,
                isLocked: coordinator.hasActiveRecording || coordinator.isTransitioning)
            DictationContextControl(preferences: coordinator.preferences,
                status: coordinator.contextStatus,
                isLocked: coordinator.hasActiveRecording || coordinator.isTransitioning)
            HStack(alignment: .top, spacing: 16) {
                DictationResultEditor(text: $coordinator.resultText, state: coordinator.state,
                    shortcut: shortcut, editable: coordinator.state == .ready && !coordinator.isTransitioning && !model.isLoadingHistorySelection &&
                        !coordinator.hasTransformPreview)
                if let preview = coordinator.transformPreview {
                    DictationRewritePreview(preview: preview, isApplying: coordinator.isTransitioning,
                        apply: coordinator.applyTransformPreview, dismiss: coordinator.discardTransformPreview)
                } else if let preview = coordinator.longTransformPreview {
                    DictationLongRewritePreview(result: preview, sourceText: coordinator.resultText,
                        isApplying: coordinator.isTransitioning, apply: coordinator.applyTransformPreview,
                        dismiss: coordinator.discardTransformPreview)
                }
            }
            DictationStatusLine(message: model.isLoadingHistorySelection ? "Opening saved recording…" : coordinator.message,
                messageRevision: model.isLoadingHistorySelection ? nil : coordinator.messageRevision,
                spokenRevision: coordinator.spokenMessageRevision,
                state: model.isLoadingHistorySelection ? .processing : coordinator.state,
                recording: coordinator.handle, announcesMessages: announcesStatusMessages)
            VStack(alignment: .leading, spacing: 14) {
                if coordinator.state == .ready {
                    DictationRewriteControls(coordinator: coordinator)
                }
                if coordinator.hasActiveRecording && coordinator.recordingPurpose == .longRecording {
                    Text("Finish opens the transcript here.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("dictation.longRecordingPurpose")
                }
                HStack(alignment: .center) {
                    DictationCaptureControls(coordinator: coordinator)
                    Spacer(minLength: 16)
                    if coordinator.hasActiveRecording {
                        DictationCaptureClock(model: model)
                    } else {
                        Label("On this Mac", systemImage: "lock")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(30)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// DictationCoordinator speaks capture progress, cancellation, and delivery outcomes itself.
    private var announcesStatusMessages: Bool {
        switch coordinator.state {
        case .idle, .ready, .failed: true
        case .recording, .paused: coordinator.canCancel
        case .starting, .processing: false
        }
    }
}

/// The next recording preference stays separate from the saved result's output mode.
private struct DictationQuickModeControl: View {
    @Bindable var preferences: DictationPreferences
    let captureMode: DictationQuickMode?
    let isLocked: Bool

    private var selection: Binding<DictationQuickMode> {
        if let captureMode { .constant(captureMode) }
        else { $preferences.mode }
    }

    private var selectionTitle: LocalizedStringResource {
        captureMode == nil ? "Next recording" : "For this recording"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectionTitle)
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Dictation mode", selection: selection) {
                    ForEach(DictationQuickMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 330)
                .disabled(isLocked)
                .accessibilityIdentifier("dictation.quickMode")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text((captureMode ?? preferences.mode).detail)
                    .font(.callout).foregroundStyle(.secondary)
                if captureMode == nil, !preferences.appPresets.isEmpty {
                    Text("App presets in Settings choose the mode in ^[\(preferences.appPresets.count) app](inflect: true).")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("dictation.quickMode.presetNote")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
        }
        .help("Clean and Email run automatically when you finish. If either cannot complete safely, your original stays saved for review.")
    }
}

private struct DictationContextControl: View {
    @Bindable var preferences: DictationPreferences
    let status: String
    let isLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label("Context", systemImage: "text.viewfinder")
                    .font(.callout)
                Picker("Context access", selection: $preferences.contextMode) {
                    ForEach(DictationContextMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("dictation.context.mode")
                if preferences.contextMode != .off {
                    Picker("Formatting profile", selection: $preferences.contextProfile) {
                        ForEach(DictationContextProfileSelection.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityIdentifier("dictation.context.profile")
                }
                Spacer(minLength: 8)
                if isLocked {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier("dictation.context.status")
                }
            }
            .disabled(isLocked)
            if preferences.contextMode != .off {
                Text(preferences.contextMode == .nearbyText
                     ? "Use a small amount of nearby text for punctuation. It stays temporary."
                     : "Use the app's formatting profile. Field contents are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .help("Context is captured once when recording starts. It only guides formatting; your words stay unchanged.")
    }
}

private struct DictationPaneHeader: View {
    let state: DictationFlowState
    let destinationLabel: String
    let outputMode: DictationOutputMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dictation").font(.largeTitle).fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if state != .idle {
                    Label(destinationLabel, systemImage: "arrow.up.right.square")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 16) {
                Label("English + Deutsch", systemImage: "globe")
                Label(outputMode.displayTitle, systemImage: "text.alignleft")
                    .accessibilityIdentifier("dictation.outputMode")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct DictationResultEditor: View {
    @Binding var text: String
    let state: DictationFlowState
    let shortcut: String?
    let editable: Bool

    var body: some View {
        ZStack {
            TextEditor(text: $text)
                .font(.body)
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(20)
                .disabled(!editable)
                .accessibilityLabel("Dictation text")
                .accessibilityHint(DictationEmptyResult(state: state, shortcut: shortcut).accessibilityGuidance,
                    isEnabled: text.isEmpty)
                .accessibilityIdentifier("dictation.result")
            if text.isEmpty {
                DictationEmptyResult(state: state, shortcut: shortcut)
                    .padding(32)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 250)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

private struct DictationEmptyResult: View {
    let state: DictationFlowState
    let shortcut: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: state == .recording ? "waveform" : "mic")
                .font(.largeTitle)
                .foregroundStyle(state == .recording ? Color.accentColor : Color.secondary)
            Text(title).font(.title2).fontWeight(.medium)
            Text(detail).font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if state == .idle || state == .ready, let shortcut {
                Text(shortcut).font(.callout.monospaced())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.quaternary, in: .rect(cornerRadius: 7))
                    .padding(.top, 2)
            }
        }
    }

    /// The visual empty state is hidden from VoiceOver, so the editor carries the same guidance as its hint.
    var accessibilityGuidance: Text {
        if state == .idle || state == .ready, let shortcut {
            Text("\(Text(detail)) Your shortcut is \(shortcut).",
                comment: "Editor hint when no text exists. The first variable is the usage guidance; the second is the global dictation keyboard shortcut.")
        } else {
            Text(detail)
        }
    }

    private var title: LocalizedStringResource {
        switch state {
        case .recording: "Listening."
        case .paused: "Take your time."
        case .starting: "Opening your microphone…"
        case .processing: "Transcribing locally…"
        case .failed: "Your words stay yours."
        case .idle, .ready: "Speak freely."
        }
    }

    private var detail: LocalizedStringResource {
        switch state {
        case .recording: "Mix English and German naturally. Pause whenever you need."
        case .paused: "Resume the same recording, or finish to get your text."
        case .starting: "Your audio will be saved on this Mac."
        case .processing: "Your recording is saved. Your text will appear here."
        case .failed: "Check the message below, then try again."
        case .idle, .ready: "Start here to record and copy. Use your shortcut in another app to dictate into its text field."
        }
    }
}

private struct DictationStatusLine: View {
    let message: String
    /// Advances on every coordinator message assignment; nil while a placeholder message is shown.
    let messageRevision: Int?
    /// A revision the coordinator already announced itself.
    let spokenRevision: Int?
    let state: DictationFlowState
    let recording: DictationRecordingHandle?
    let announcesMessages: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if state == .starting || state == .processing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: state == .failed ? "exclamationmark.circle" :
                    state == .ready ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(.secondary)
            }
            Text(message).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dictation.status")
        // DictationCoordinator announces state transitions, capture progress, cancellation, and delivery
        // outcomes; opening another recording stays silent. Announce only messages posted within the
        // same settled state of the same recording, such as copy, rewrite, save, and interruption results or errors.
        // Each new message revision is announced, even when its text repeats, as after a second Copy.
        .onChange(of: Snapshot(message: message, revision: messageRevision, spokenRevision: spokenRevision,
            state: state, recording: recording, announces: announcesMessages)) { old, new in
            guard old.announces, new.announces, new.state == old.state, new.recording == old.recording,
                  let revision = new.revision, revision != old.revision, revision != new.spokenRevision,
                  !new.message.isEmpty else { return }
            AccessibilityNotification.Announcement(new.message).post()
        }
    }

    private struct Snapshot: Equatable {
        let message: String
        let revision: Int?
        let spokenRevision: Int?
        let state: DictationFlowState
        let recording: DictationRecordingHandle?
        let announces: Bool
    }
}

private struct DictationRewriteControls: View {
    let coordinator: DictationCoordinator

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Clean up") { coordinator.prepareTransform(.clean) }
                Button("Format as email") { coordinator.prepareTransform(.email) }
                    .accessibilityIdentifier("dictation.rewrite.email")
                Button("Summarize") { coordinator.prepareTransform(.summarize) }
                Button("Organize into bullets") { coordinator.prepareTransform(.organize) }
                Divider()
                Menu("Translate") {
                    Button("To English") { coordinator.prepareTransform(.translateEnglish) }
                        .accessibilityLabel("Translate to English")
                        .accessibilityIdentifier("dictation.rewrite.translateEnglish")
                    Button("To German") { coordinator.prepareTransform(.translateGerman) }
                        .accessibilityLabel("Translate to German")
                        .accessibilityIdentifier("dictation.rewrite.translateGerman")
                }
                .accessibilityIdentifier("dictation.rewrite.translate")
            } label: {
                Label("Rewrite", systemImage: "wand.and.stars")
            }
            .accessibilityIdentifier("dictation.rewrite")
            .help("Preview a local rewrite before applying it")
            .disabled(coordinator.isTransitioning || coordinator.hasTransformPreview)
            DictationOutputVersions(coordinator: coordinator)
            if coordinator.isTransforming {
                ProgressView().controlSize(.small)
                Text(coordinator.canCancelTransform ? "Rewriting on this Mac…" : "Saving on this Mac…")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Cancel", action: coordinator.cancelTransform)
                    .accessibilityIdentifier("dictation.cancelTransform")
                    .disabled(!coordinator.canCancelTransform)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }
}

private struct DictationOutputVersions: View {
    let coordinator: DictationCoordinator

    var body: some View {
        Menu {
            ForEach(coordinator.outputVersions) { version in
                Button {
                    coordinator.selectOutput(version.id)
                } label: {
                    HStack {
                        if version.mode == .verbatim {
                            Text(version.textRevision.text == version.textRevision.rawText ?
                                "Original transcript" : "Edited transcript")
                        } else {
                            Text(version.mode.displayTitle)
                        }
                        Text(version.createdAt, format: .dateTime.hour().minute().second())
                        if coordinator.activeOutputID == version.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                // The checkmark is visual only; expose the current version as state.
                .accessibilityAddTraits(coordinator.activeOutputID == version.id ? .isSelected : [])
                .accessibilityValue("Current version", isEnabled: coordinator.activeOutputID == version.id)
                .accessibilityIdentifier("dictation.version.\(version.id)")
            }
        } label: {
            Label("Versions", systemImage: "clock.arrow.circlepath")
        }
        .accessibilityIdentifier("dictation.versions")
        .help("Return to an earlier saved version")
        .disabled(coordinator.isTransitioning || coordinator.hasTransformPreview ||
            coordinator.outputVersions.isEmpty)
    }
}

private struct DictationRewritePreview: View {
    let preview: DictationTransformResult
    let isApplying: Bool
    let apply: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Preview").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(preview.mode.displayTitle).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(preview.text)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if preview.mode.translationTarget != nil {
                Text("Check the meaning before applying. Local checks compare digits, links, paths, handles and code exactly; spelled-out numbers, names and meaning are not checked.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictation.preview.translationNotice")
            }
            Text("Your saved text stays unchanged until you apply.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Dismiss", action: dismiss)
                    .accessibilityIdentifier("dictation.discardPreview")
                Spacer(minLength: 8)
                Button("Apply", action: apply)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("dictation.applyPreview")
            }
            .disabled(isApplying)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 250)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictation.preview")
    }
}

private struct DictationLongRewritePreview: View {
    let result: LongDictationTransformResult
    let sourceText: String
    let isApplying: Bool
    let apply: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(result.mode.displayTitle).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(result.plan.chunks.count) sections").font(.callout).foregroundStyle(.secondary)
            }
            Text("Each section keeps its own source. Review the complete draft before applying.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(result.plan.chunks) { chunk in
                        if chunk.index < result.outputs.count {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Section \(chunk.index + 1)").font(.subheadline.weight(.semibold))
                                    .accessibilityAddTraits(.isHeader)
                                Text(result.outputs[chunk.index].text).textSelection(.enabled)
                                DisclosureGroup("Source passage") {
                                    Text(sourcePassage(chunk)).font(.callout).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }
            }
            HStack {
                Button("Dismiss", action: dismiss).accessibilityIdentifier("dictation.discardPreview")
                Spacer()
                Button("Apply", action: apply).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("dictation.applyPreview")
            }.disabled(isApplying)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 18))
        .accessibilityIdentifier("dictation.longPreview")
    }

    private func sourcePassage(_ chunk: LongDictationTransformPlan.Chunk) -> String {
        let revision = DictationTextRevision(rawText: sourceText, text: sourceText, sourceTranscriptIDs: [])
        return (try? LongDictationTransformService.sourceText(for: chunk, in: revision)) ?? ""
    }
}

private struct DictationCaptureControls: View {
    let coordinator: DictationCoordinator

    var body: some View {
        HStack(spacing: 12) {
            if coordinator.hasActiveRecording {
                Button(action: coordinator.pauseResume) {
                    Label(coordinator.state == .paused ? "Resume" : "Pause",
                        systemImage: coordinator.state == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("dictation.pause")
                .disabled(coordinator.isTransitioning)
                Button(action: coordinator.finish) {
                    Label("Finish", systemImage: "stop.fill")
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("dictation.finish")
                .disabled(coordinator.isTransitioning)
                Button(action: coordinator.cancel) {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("dictation.cancel")
                .help("Cancel dictation and keep the saved audio. Once insertion begins, it must finish.")
                .disabled(!coordinator.canCancel)
            } else {
                Button(action: coordinator.toggle) {
                    Label("Start dictation", systemImage: "mic.fill")
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("dictation.start")
                .disabled(coordinator.isTransitioning)
                Button(action: coordinator.startLongRecording) {
                    Label("Long recording", systemImage: "recordingtape")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("dictation.startLongRecording")
                .help("Record with pause and resume. Finish opens the transcript here.")
                .disabled(coordinator.isTransitioning)
                if coordinator.state == .failed, coordinator.handle != nil {
                    Button(action: coordinator.finish) {
                        Label("Retry transcription", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("dictation.retry")
                    .disabled(coordinator.isTransitioning)
                }
            }
            if coordinator.state == .ready {
                Button(action: coordinator.copyResult) {
                    Label("Copy text", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glass)
                .disabled(coordinator.isTransitioning || coordinator.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("dictation.copy")
            }
        }
        .controlSize(.large)
    }
}

private struct DictationCaptureClock: View {
    let model: WorkspaceModel

    var body: some View {
        Text(Duration.seconds(model.recordingHUDElapsed), format: .time(pattern: .hourMinuteSecond))
            .font(.title3.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Recording duration")
            .accessibilityValue(Text(Duration.seconds(model.recordingHUDElapsed),
                format: .units(allowed: [.hours, .minutes, .seconds], width: .wide)))
            .accessibilityAddTraits(.updatesFrequently)
    }
}


#if DEBUG
/// Preview-only backend: no microphone, model, filesystem, clipboard, or delivery operations.
@MainActor
private final class DictationPreviewBackend: DictationRecordingBackend {
    let metadata: DictationRecordingMetadata?

    init(metadata: DictationRecordingMetadata?) { self.metadata = metadata }

    func dictationBegin() async throws -> DictationRecordingHandle {
        throw KeystormError.message("Preview capture is disabled.")
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {}
    func dictationResume(_ handle: DictationRecordingHandle) async throws {}
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        throw KeystormError.message("Preview inference is disabled.")
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? { metadata }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {}
}

@MainActor
enum DictationPreviewFixtures {
    static let text = """
        Please update die Datenschutzerklärung before Friday.

        Keep the recording entirely local, and preserve German words such as Kündigungsfrist and Überweisung exactly as spoken. We can review the final wording tomorrow.

        Could you also move the project meeting to übermorgen at ten?
        """

    static func coordinator(state: DictationRecordingState? = nil) -> DictationCoordinator {
        let handle = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
        let metadata = state.map {
            DictationRecordingMetadata(id: handle.takeID, state: $0,
                textRevision: $0 == .ready ? DictationTextRevision(rawText: text, text: text,
                                                                 sourceTranscriptIDs: []) : nil)
        }
        let coordinator = DictationCoordinator(backend: DictationPreviewBackend(metadata: metadata))
        if state != nil { coordinator.restore(handle) }
        return coordinator
    }
}

private struct DictationDesignPreview: View {
    @State private var model = WorkspaceModel()
    @State private var coordinator: DictationCoordinator
    let colorScheme: ColorScheme

    init(colorScheme: ColorScheme, result: Bool, mode: DictationQuickMode = .verbatim,
         contextMode: DictationContextMode = .off) {
        self.colorScheme = colorScheme
        let coordinator = DictationPreviewFixtures.coordinator(state: result ? .ready : nil)
        coordinator.preferences.mode = mode
        coordinator.preferences.contextMode = contextMode
        _coordinator = State(initialValue: coordinator)
    }

    var body: some View {
        // Compose the real content without the canvas host's overlapping window toolbar.
        HStack(spacing: 0) {
            DictationHistorySidebar(model: model, coordinator: coordinator, openDeveloperBriefs: {})
                .frame(width: 250)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            DictationEditorPane(coordinator: coordinator, model: model, shortcut: "⌥⇧⌘D")
        }
        .frame(width: 1180, height: 780)
        .preferredColorScheme(colorScheme)
        .allowsHitTesting(false)
    }
}

#Preview("Dictation · Idle · Light") { DictationDesignPreview(colorScheme: .light, result: false) }
#Preview("Dictation · Result · Light") { DictationDesignPreview(colorScheme: .light, result: true) }
#Preview("Dictation · Idle · Dark") { DictationDesignPreview(colorScheme: .dark, result: false) }
#Preview("Dictation · Result · Dark") { DictationDesignPreview(colorScheme: .dark, result: true) }

private struct DictationRewriteDesignPreview: View {
    @State private var source = DictationPreviewFixtures.text
    let colorScheme: ColorScheme
    private let candidate = DictationTransformResult(jobID: UUID(), sourceRevisionID: UUID(),
        sourceSHA256: DictationTransformPolicy.sourceDigest(DictationPreviewFixtures.text), mode: .organize,
        text: """
            - Please update die Datenschutzerklärung before Friday.

            - Keep the recording entirely local, and preserve German words such as Kündigungsfrist and Überweisung exactly as spoken.

            - We can review the final wording tomorrow.

            - Could you also move the project meeting to übermorgen at ten?
            """,
        generatedTokens: 80, configurationID: UUID(),
        promptTemplateVersion: DictationTransformPolicy.templateVersion,
        promptTemplateSHA256: DictationTransformPolicy.promptTemplateSHA256(for: .organize))

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Review rewrite").font(.largeTitle).fontWeight(.semibold)
            Text("Compare your saved words with the local rewrite.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Saved text").font(.headline)
                    DictationResultEditor(text: $source, state: .ready, shortcut: nil, editable: false)
                }
                DictationRewritePreview(preview: candidate, isApplying: false, apply: {}, dismiss: {})
            }
        }
        .padding(30)
        .frame(width: 1180, height: 780)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(colorScheme)
        .allowsHitTesting(false)
    }
}

#Preview("Dictation · Rewrite · Light") { DictationRewriteDesignPreview(colorScheme: .light) }
#Preview("Dictation · Rewrite · Dark") { DictationRewriteDesignPreview(colorScheme: .dark) }
#Preview("Dictation · Clean · Light") { DictationDesignPreview(colorScheme: .light, result: false, mode: .clean) }
#Preview("Dictation · Clean · Dark") { DictationDesignPreview(colorScheme: .dark, result: false, mode: .clean) }
#Preview("Dictation · Email · Light") { DictationDesignPreview(colorScheme: .light, result: false, mode: .email) }
#Preview("Dictation · Email · Dark") { DictationDesignPreview(colorScheme: .dark, result: false, mode: .email) }
#Preview("Dictation · Context · Light") {
    DictationDesignPreview(colorScheme: .light, result: false, mode: .clean, contextMode: .nearbyText)
}
#Preview("Dictation · Context · Dark") {
    DictationDesignPreview(colorScheme: .dark, result: false, mode: .clean, contextMode: .application)
}
#endif
