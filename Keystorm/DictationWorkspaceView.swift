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
            // Apply the retention setting at launch, after the workspace is usable.
            await model.applyDictationRetention(DictationRetention.load())
        }
        .frame(minWidth: 920, minHeight: 650)
        #if DEBUG
        .safeAreaBar(edge: .top, spacing: 0) {
            if let status = model.debugAudioSourceStatus {
                Label(status, systemImage: "testtube.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
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
            // The mode picker is a system segmented control in the window toolbar, which supplies the glass
            // itself. It stays locked while a recording is active, and shows that recording's own mode.
            ToolbarItem(placement: .principal) {
                DictationModePicker(preferences: coordinator.preferences,
                    captureMode: coordinator.hasActiveRecording ? coordinator.captureMode : nil,
                    isLocked: coordinator.hasActiveRecording || coordinator.isTransitioning)
            }
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
                .help("Add your own words, and review the terminology learned from your transcript corrections")
                .accessibilityIdentifier("dictation.dictionary")
                .disabled(coordinator.hasActiveRecording || coordinator.isTransitioning ||
                    model.isRecording || model.isCaptureTransitioning)
            }
            // Related items share one system glass group; fixed spacers separate the groups.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
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
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
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
        Group {
            if let controller {
                LearningDictionaryView(controller: controller)
            } else {
                ContentUnavailableView("Learning dictionary unavailable", systemImage: "exclamationmark.circle",
                    description: Text(unavailableMessage))
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("learning.unavailable")
            }
        }
        // The title bar floats above the content; scrolling content blurs beneath it instead of a hand-drawn divider.
        .safeAreaBar(edge: .top, spacing: 0) {
            HStack {
                Label("Dictionary", systemImage: "character.book.closed").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 650)
    }
}

/// What a confirmed deletion removes.
private enum DictationDeletionRequest {
    case all
    case entries([DictationHistoryHeader])
}

private struct DictationSearchKey: Hashable {
    var text: String
    var revision: Int
}

/// Indexed headers keep sidebar updates independent of full transcript/audio payloads.
private struct DictationHistorySidebar: View {
    let model: WorkspaceModel
    let coordinator: DictationCoordinator
    let openDeveloperBriefs: () -> Void
    @State private var selectionTask: Task<Void, Never>?
    @State private var selectionGeneration = UUID()
    /// Empty means "follow the open recording"; two or more rows select a batch to delete.
    @State private var selection: Set<String> = []
    @State private var searchText = ""
    @State private var searchResults: [DictationHistoryHeader]?
    @State private var searchRevision = 0
    @State private var pendingDeletion: DictationDeletionRequest?
    @State private var pendingRetention: DictationRetention?
    @AppStorage(DictationRetention.storageKey) private var retentionRaw = DictationRetention.forever.rawValue

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var visibleEntries: [DictationHistoryHeader] {
        isSearching ? (searchResults ?? []) : model.dictationHistoryEntries
    }
    private var isLocked: Bool { coordinator.hasActiveRecording || coordinator.isTransitioning }

    private var listSelection: Binding<Set<String>> {
        Binding(
            get: {
                selection.isEmpty
                    ? Set(coordinator.handle.map { [$0.sessionID.uuidString + "/" + $0.takeID.uuidString] } ?? [])
                    : selection
            },
            set: { ids in
                selection = ids
                guard ids.count == 1, let id = ids.first,
                      let entry = visibleEntries.first(where: { $0.stableID == id }) else { return }
                select(entry.handle)
            })
    }

    private var retentionBinding: Binding<DictationRetention> {
        Binding(
            get: { DictationRetention(rawValue: retentionRaw) ?? .forever },
            set: { choice in
                // A choice that deletes data on its own waits for a confirmation.
                if choice.removesData { pendingRetention = choice } else { retentionRaw = choice.rawValue }
            })
    }

    private var emptyMessage: LocalizedStringKey {
        if !isSearching { return "Your dictations will appear here." }
        return searchResults == nil ? "Searching…" : "No dictations match your search."
    }

    private var deletionTitle: LocalizedStringKey {
        switch pendingDeletion {
        case .some(.all): "Delete all dictations?"
        case .some(.entries(let entries)): entries.count == 1 ? "Delete this dictation?" : "Delete \(entries.count) dictations?"
        case .none: ""
        }
    }

    var body: some View {
        List(selection: listSelection) {
            Section {
                if visibleEntries.isEmpty, !model.isLoadingHistory {
                    VStack(spacing: 8) {
                        Image(systemName: isSearching ? "magnifyingglass" : "waveform")
                            .font(.title2).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text(emptyMessage)
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
                ForEach(visibleEntries, id: \.stableID) { entry in
                    DictationHistoryRow(title: entry.title, preview: entry.preview,
                        createdAt: entry.createdAt, state: entry.state)
                        .tag(entry.stableID)
                        .accessibilityIdentifier("dictation.history.\(entry.id)")
                }
                if !isSearching, model.historyHasMore {
                    Button("Load older recordings") { Task { await model.loadMoreDictationHistory() } }
                        .disabled(model.isLoadingHistory)
                        .accessibilityIdentifier("dictation.history.loadMore")
                }
                if model.isLoadingHistory { ProgressView().controlSize(.small) }
            } header: {
                HStack {
                    Text("History")
                    Spacer()
                    historyMenu
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(isLocked || model.isDeletingDictationHistory)
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button("Delete…", role: .destructive) { requestDelete(ids: ids) }
            }
        }
        .onDeleteCommand { requestDelete(ids: listSelection.wrappedValue) }
        // Selection actions, notices and the developer-briefs link float over the list as one bar, so history rows
        // scroll beneath them. The buttons are system glass in one container; there is no hand-drawn divider.
        .safeAreaBar(edge: .bottom, spacing: 0) { sidebarFooter }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search dictations")
        .task(id: DictationSearchKey(text: searchText, revision: searchRevision)) { await runSearch() }
        .onChange(of: coordinator.handle) { selection = [] }
        .onDisappear { selectionTask?.cancel(); model.cancelHistorySelection() }
        .confirmationDialog(deletionTitle, isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let request = pendingDeletion { performDeletion(request) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The audio and transcript are permanently removed from this Mac. This can’t be undone.")
        }
        .confirmationDialog(Text(pendingRetention?.title ?? DictationRetention.forever.title), isPresented: Binding(
            get: { pendingRetention != nil },
            set: { if !$0 { pendingRetention = nil } }
        ), titleVisibility: .visible) {
            Button("Apply", role: .destructive) {
                if let choice = pendingRetention { applyRetention(choice) }
                pendingRetention = nil
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            if let choice = pendingRetention { Text(choice.confirmationMessage) }
        }
    }

    /// The floating layer under the history list. Every control is a system glass button; the container keeps
    /// neighbouring glass shapes rendering together. Nothing here paints its own backdrop.
    private var sidebarFooter: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if listSelection.wrappedValue.count > 1 {
                    HStack {
                        Text("\(listSelection.wrappedValue.count) selected")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete…", role: .destructive) { requestDelete(ids: listSelection.wrappedValue) }
                            .buttonStyle(.glass)
                            .disabled(isLocked || model.isDeletingDictationHistory)
                            .accessibilityIdentifier("dictation.history.deleteSelected")
                    }
                }
                if let error = model.historyError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Try again") { Task { await model.refreshDictationHistory() } }
                        .buttonStyle(.glass)
                }
                if model.historyMaintenanceAvailable || model.historyPendingRepairCount > 0 {
                    if model.historyPendingRepairCount > 0 {
                        Text("Some recordings need a recovery check.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await model.checkHistoryForRecovery() }
                    } label: {
                        Label("Check library", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .disabled(model.isCheckingHistory || coordinator.reservesCapture || coordinator.isTransitioning)
                    .help("Find recovered recordings. Existing recordings are checked when you open them.")
                    .accessibilityIdentifier("dictation.history.checkLibrary")
                    if model.isCheckingHistory { ProgressView().controlSize(.small) }
                }
                Button(action: openDeveloperBriefs) {
                    Label("Developer briefs", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.glass)
                .disabled(coordinator.hasActiveRecording || coordinator.isTransitioning)
                .accessibilityIdentifier("dictation.openLegacy")
            }
        }
        .padding(12)
    }

    private var historyMenu: some View {
        Menu {
            Picker("Keep recordings", selection: retentionBinding) {
                ForEach(DictationRetention.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Delete all dictations…", role: .destructive) { pendingDeletion = .all }
                .disabled(isLocked || model.isDeletingDictationHistory || model.dictationHistoryEntries.isEmpty)
        } label: {
            Label("History options", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .labelStyle(.iconOnly)
        .fixedSize()
        .accessibilityIdentifier("dictation.history.menu")
    }

    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchResults = nil; return }
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        let found = (try? await model.store?.searchHistory(query, limit: 50)) ?? []
        guard !Task.isCancelled else { return }
        searchResults = found
    }

    private func requestDelete(ids: Set<String>) {
        guard !isLocked, !model.isDeletingDictationHistory, !ids.isEmpty else { return }
        let entries = visibleEntries.filter { ids.contains($0.stableID) }
        guard !entries.isEmpty else { return }
        pendingDeletion = .entries(entries)
    }

    private func performDeletion(_ request: DictationDeletionRequest) {
        let currentKey = coordinator.handle.map { $0.sessionID.uuidString + "/" + $0.takeID.uuidString }
        let touchesCurrent: Bool
        switch request {
        case .all: touchesCurrent = currentKey != nil
        case .entries(let entries): touchesCurrent = currentKey.map { key in entries.contains { $0.stableID == key } } ?? false
        }
        Task {
            let result: DictationDeletionResult
            switch request {
            case .all: result = await model.deleteAllDictationHistory()
            case .entries(let entries): result = await model.deleteDictationSessions(entries.map(\.sessionID))
            }
            selection = []
            searchRevision += 1
            // The open recording was deleted: leave the editor on a blank draft instead of a ghost.
            if touchesCurrent, let currentKey,
               !model.dictationHistoryEntries.contains(where: { $0.stableID == currentKey }) {
                coordinator.newDraft()
            }
            report(result)
        }
    }

    private func applyRetention(_ choice: DictationRetention) {
        retentionRaw = choice.rawValue
        Task {
            let result = await model.applyDictationRetention(choice)
            searchRevision += 1
            report(result)
        }
    }

    private func report(_ result: DictationDeletionResult) {
        if result.failed > 0 {
            model.error = result.firstError ?? String(localized: "Some dictations could not be deleted.")
        } else if result.skippedInUse > 0 {
            model.error = String(localized: "Some dictations are still in use and were kept.")
        }
    }

    private func select(_ handle: DictationRecordingHandle) {
        guard !coordinator.reservesCapture, !coordinator.isTransitioning else { selection = []; return }
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
            catch {
                selection = []
                model.error = error.localizedDescription
            }
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
        // The transcript is the bottom layer: plain text on the window background. It is the last item in the
        // column, so its scroll view reaches the window's bottom edge and the text passes under the floating bar.
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 24) {
                DictationPaneHeader(state: coordinator.state, destinationLabel: coordinator.destinationLabel,
                    outputMode: coordinator.hasActiveRecording ? coordinator.captureMode.outputMode :
                        (coordinator.state == .idle ? coordinator.preferences.mode.outputMode : coordinator.outputMode))
                VStack(alignment: .leading, spacing: 16) {
                    DictationModeSummary(preferences: coordinator.preferences,
                        captureMode: coordinator.hasActiveRecording ? coordinator.captureMode : nil)
                    DictationContextControl(preferences: coordinator.preferences,
                        status: coordinator.contextStatus,
                        isLocked: coordinator.hasActiveRecording || coordinator.isTransitioning)
                }
                // Status and progress sit above the transcript so nothing but text ends at the bottom edge.
                DictationStatusLine(message: model.isLoadingHistorySelection ? "Opening saved recording…" : coordinator.message,
                    messageRevision: model.isLoadingHistorySelection ? nil : coordinator.messageRevision,
                    spokenRevision: coordinator.spokenMessageRevision,
                    state: model.isLoadingHistorySelection ? .processing : coordinator.state,
                    recording: coordinator.handle, announcesMessages: announcesStatusMessages)
                if coordinator.isTransforming {
                    DictationTransformProgress(canCancel: coordinator.canCancelTransform)
                }
                if coordinator.hasActiveRecording && coordinator.recordingPurpose == .longRecording {
                    Text("Finish opens the transcript here.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("dictation.longRecordingPurpose")
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            HStack(alignment: .top, spacing: 0) {
                DictationResultEditor(text: $coordinator.resultText, state: coordinator.state,
                    shortcut: shortcut, editable: coordinator.state == .ready && !coordinator.isTransitioning && !model.isLoadingHistorySelection &&
                        !coordinator.hasTransformPreview)
                if let preview = coordinator.transformPreview {
                    DictationRewritePreview(preview: preview, isApplying: coordinator.isTransitioning,
                        apply: coordinator.applyTransformPreview, dismiss: coordinator.discardTransformPreview)
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                } else if let preview = coordinator.longTransformPreview {
                    DictationLongRewritePreview(result: preview, sourceText: coordinator.resultText,
                        isApplying: coordinator.isTransitioning, apply: coordinator.applyTransformPreview,
                        dismiss: coordinator.discardTransformPreview)
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // One floating glass cluster at the bottom. A bar, not an inset with a background, so the transcript
        // scrolls under it and the scroll edge effect extends to match.
        .safeAreaBar(edge: .bottom, spacing: 0) {
            DictationControlBar(coordinator: coordinator, model: model)
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
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

/// What the next recording will do. The mode itself is chosen in the window toolbar.
/// The next recording preference stays separate from the saved result's output mode.
private struct DictationModeSummary: View {
    let preferences: DictationPreferences
    let captureMode: DictationQuickMode?

    private var selectionTitle: LocalizedStringResource {
        captureMode == nil ? "Next recording" : "For this recording"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectionTitle)
                .font(.caption).foregroundStyle(.secondary)
            Text((captureMode ?? preferences.mode).detail)
                .font(.callout).foregroundStyle(.secondary)
            if captureMode == nil, !preferences.appPresets.isEmpty {
                Text("App presets in Settings choose the mode in ^[\(preferences.appPresets.count) app](inflect: true).")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictation.quickMode.presetNote")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The mode picker is a system segmented control. The window toolbar hosts it and draws its glass; nothing here
/// adds a backdrop.
private struct DictationModePicker: View {
    @Bindable var preferences: DictationPreferences
    let captureMode: DictationQuickMode?
    let isLocked: Bool

    private var selection: Binding<DictationQuickMode> {
        if let captureMode { .constant(captureMode) }
        else { $preferences.mode }
    }

    var body: some View {
        Picker("Dictation mode", selection: selection) {
            ForEach(DictationQuickMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(isLocked)
        .help("Clean and Email run automatically when you finish. If either cannot complete safely, your original stays saved for review.")
        .accessibilityIdentifier("dictation.quickMode")
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
                Label("On this Mac", systemImage: "lock")
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
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                // 27 pt plus the editor's own 5 pt text inset lines the text up with the 32 pt header margin,
                // while the scroll view itself stays full width so its scroll bar sits at the pane edge.
                .padding(.horizontal, 27)
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
        .frame(minHeight: 240)
        // The transcript is content, not chrome: plain text on the window background, no card and no glass.
        // It scrolls beneath the floating control bar.
    }
}

private struct DictationEmptyResult: View {
    let state: DictationFlowState
    let shortcut: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(systemName: state == .recording ? "waveform" : "mic")
                    .foregroundStyle(state == .recording ? Color.red : Color.secondary)
                    .symbolEffect(.pulse, isActive: state == .recording && !reduceMotion)
            }
        } description: {
            Text(detail)
        } actions: {
            if state == .idle || state == .ready, let shortcut {
                Text(shortcut).font(.callout.monospaced())
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
            }
        }
        .frame(maxWidth: 420)
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

/// Progress for a running rewrite stays with the content; its Cancel button lives in the control bar.
private struct DictationTransformProgress: View {
    let canCancel: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(canCancel ? "Rewriting on this Mac…" : "Saving on this Mac…")
                .font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DictationRewriteControls: View {
    let coordinator: DictationCoordinator
    let namespace: Namespace.ID
    let iconOnly: Bool

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
                DictationBarLabel("Rewrite", systemImage: "wand.and.stars", iconOnly: iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .glassEffectID("rewrite", in: namespace)
            .accessibilityIdentifier("dictation.rewrite")
            .help("Preview a local rewrite before applying it")
            .disabled(coordinator.isTransitioning || coordinator.hasTransformPreview)
            DictationOutputVersions(coordinator: coordinator, namespace: namespace, iconOnly: iconOnly)
            if coordinator.isTransforming {
                Button(action: coordinator.cancelTransform) {
                    DictationBarLabel("Cancel", systemImage: "xmark", iconOnly: iconOnly)
                }
                .buttonStyle(.glass)
                .glassEffectID("cancelTransform", in: namespace)
                .accessibilityIdentifier("dictation.cancelTransform")
                .dictationBarHelp("Cancel", iconOnly: iconOnly)
                .disabled(!coordinator.canCancelTransform)
            }
        }
    }
}

private struct DictationOutputVersions: View {
    let coordinator: DictationCoordinator
    let namespace: Namespace.ID
    let iconOnly: Bool

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
            DictationBarLabel("Versions", systemImage: "clock.arrow.circlepath", iconOnly: iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .glassEffectID("versions", in: namespace)
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
            GlassEffectContainer(spacing: 8) {
                HStack {
                    Button("Dismiss", action: dismiss)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("dictation.discardPreview")
                    Spacer(minLength: 8)
                    Button("Apply", action: apply)
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("dictation.applyPreview")
                }
            }
            .disabled(isApplying)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 240)
        // A proposed rewrite is set apart from the saved transcript by a hairline, not a filled card, so its
        // buttons sit on the window like every other control.
        .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
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
            GlassEffectContainer(spacing: 8) {
                HStack {
                    Button("Dismiss", action: dismiss).buttonStyle(.glass)
                        .accessibilityIdentifier("dictation.discardPreview")
                    Spacer()
                    Button("Apply", action: apply).buttonStyle(.glassProminent)
                        .accessibilityIdentifier("dictation.applyPreview")
                }
            }
            .disabled(isApplying)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
        .accessibilityIdentifier("dictation.longPreview")
    }

    private func sourcePassage(_ chunk: LongDictationTransformPlan.Chunk) -> String {
        let revision = DictationTextRevision(rawText: sourceText, text: sourceText, sourceTranscriptIDs: [])
        return (try? LongDictationTransformService.sourceText(for: chunk, in: revision)) ?? ""
    }
}

/// The floating functional layer. One glass container holds every capture, copy and rewrite control, so
/// neighbouring shapes render together and morph between idle and recording. It has no backdrop of its own: the
/// controls are the glass, and the transcript passes beneath them. The mode picker lives in the window toolbar.
private struct DictationControlBar: View {
    let coordinator: DictationCoordinator
    let model: WorkspaceModel
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            // Controls drop their text labels before anything is clipped.
            ViewThatFits(in: .horizontal) {
                DictationBarActions(coordinator: coordinator, model: model,
                    namespace: glassNamespace, iconOnly: false)
                DictationBarActions(coordinator: coordinator, model: model,
                    namespace: glassNamespace, iconOnly: true)
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: coordinator.state)
        .animation(reduceMotion ? nil : .smooth, value: coordinator.hasActiveRecording)
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}

private struct DictationBarActions: View {
    let coordinator: DictationCoordinator
    let model: WorkspaceModel
    let namespace: Namespace.ID
    let iconOnly: Bool

    var body: some View {
        HStack(spacing: 12) {
            DictationCaptureControls(coordinator: coordinator, namespace: namespace, iconOnly: iconOnly)
            if coordinator.state == .ready {
                DictationRewriteControls(coordinator: coordinator, namespace: namespace, iconOnly: iconOnly)
            }
            Spacer(minLength: 0)
            if coordinator.hasActiveRecording {
                DictationCaptureClock(model: model, isPaused: coordinator.state == .paused)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

/// A button label that drops its text for icon-only bars. The title still names the control for VoiceOver.
private struct DictationBarLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let iconOnly: Bool

    init(_ title: LocalizedStringKey, systemImage: String, iconOnly: Bool) {
        self.title = title
        self.systemImage = systemImage
        self.iconOnly = iconOnly
    }

    var body: some View {
        if iconOnly {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct DictationCaptureControls: View {
    let coordinator: DictationCoordinator
    let namespace: Namespace.ID
    let iconOnly: Bool

    private var pauseTitle: LocalizedStringKey { coordinator.state == .paused ? "Resume" : "Pause" }

    var body: some View {
        HStack(spacing: 12) {
            if coordinator.hasActiveRecording {
                Button(action: coordinator.pauseResume) {
                    DictationBarLabel(pauseTitle,
                        systemImage: coordinator.state == .paused ? "play.fill" : "pause.fill", iconOnly: iconOnly)
                }
                .buttonStyle(.glass)
                .glassEffectID("secondary", in: namespace)
                .accessibilityIdentifier("dictation.pause")
                .dictationBarHelp(pauseTitle, iconOnly: iconOnly)
                .disabled(coordinator.isTransitioning)
                // Red carries meaning here: this stops a live recording.
                Button(action: coordinator.finish) {
                    DictationBarLabel("Finish", systemImage: "stop.fill", iconOnly: false)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .glassEffectID("primary", in: namespace)
                .accessibilityIdentifier("dictation.finish")
                .disabled(coordinator.isTransitioning)
                Button(action: coordinator.cancel) {
                    DictationBarLabel("Cancel", systemImage: "xmark", iconOnly: iconOnly)
                }
                .buttonStyle(.glass)
                .glassEffectID("cancel", in: namespace)
                .accessibilityIdentifier("dictation.cancel")
                .help("Cancel dictation and keep the saved audio. Once insertion begins, it must finish.")
                .disabled(!coordinator.canCancel)
            } else {
                Button(action: coordinator.toggle) {
                    DictationBarLabel("Start dictation", systemImage: "mic.fill", iconOnly: false)
                }
                .buttonStyle(.glassProminent)
                .glassEffectID("primary", in: namespace)
                .accessibilityIdentifier("dictation.start")
                .disabled(coordinator.isTransitioning)
                Button(action: coordinator.startLongRecording) {
                    DictationBarLabel("Long recording", systemImage: "recordingtape", iconOnly: iconOnly)
                }
                .buttonStyle(.glass)
                .glassEffectID("secondary", in: namespace)
                .accessibilityIdentifier("dictation.startLongRecording")
                .help("Record with pause and resume. Finish opens the transcript here.")
                .disabled(coordinator.isTransitioning)
                if coordinator.state == .failed, coordinator.handle != nil {
                    Button(action: coordinator.finish) {
                        DictationBarLabel("Retry transcription", systemImage: "arrow.clockwise", iconOnly: iconOnly)
                    }
                    .buttonStyle(.glass)
                    .glassEffectID("retry", in: namespace)
                    .accessibilityIdentifier("dictation.retry")
                    .dictationBarHelp("Retry transcription", iconOnly: iconOnly)
                    .disabled(coordinator.isTransitioning)
                }
            }
            if coordinator.state == .ready {
                Button(action: coordinator.copyResult) {
                    DictationBarLabel("Copy text", systemImage: "doc.on.doc", iconOnly: iconOnly)
                }
                .buttonStyle(.glass)
                .glassEffectID("copy", in: namespace)
                .dictationBarHelp("Copy text", iconOnly: iconOnly)
                .disabled(coordinator.isTransitioning || coordinator.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("dictation.copy")
            }
        }
    }
}

private struct DictationCaptureClock: View {
    let model: WorkspaceModel
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            // Red marks a live recording; the pulse is skipped when paused or when Reduce Motion is on.
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(isPaused ? Color.secondary : Color.red)
                .symbolEffect(.pulse, isActive: !isPaused && !reduceMotion)
                .accessibilityHidden(true)
            Text(Duration.seconds(model.recordingHUDElapsed), format: .time(pattern: .hourMinuteSecond))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Recording duration")
                .accessibilityValue(Text(Duration.seconds(model.recordingHUDElapsed),
                    format: .units(allowed: [.hours, .minutes, .seconds], width: .wide)))
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(.horizontal, 8)
    }
}

private extension View {
    /// Shows a control's name as a tooltip only when its text label is hidden, so VoiceOver never hears it twice.
    func dictationBarHelp(_ title: LocalizedStringKey, iconOnly: Bool) -> some View {
        help(iconOnly ? title : "")
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
                .background(.regularMaterial)
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
