import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var interactions: AppInteractionController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showSources = false
    @State private var showModels = false
    @State private var showDictionary = false
    @State private var showNewPassage = false
    @State private var showExactReference = false
    @State private var showReview = false
    @State private var showRecordings = false
    @State private var showTrash = false
    @State private var navigationRequest: BriefSectionNavigation?

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                BriefSidebar(model: model, openTrash: { showTrash = true }) { navigationRequest = BriefSectionNavigation(section: $0) }
            } detail: {
                if let document = model.currentBrief {
                    VStack(spacing: 0) {
                        BriefHeader(model: model)
                        if let proposal = model.pendingBriefProposal {
                            BriefProposalView(proposal: proposal, document: document, model: model)
                                .padding(.horizontal, 24).padding(.vertical, 12)
                            Divider()
                        }
                        BriefDocumentSurface(sections: document.sections, model: model,
                                             interactions: interactions, reviewIsPresented: showReview,
                                             navigationRequest: navigationRequest)
                        VStack(spacing: 0) {
                            BriefCaptureBar(model: model, interactions: interactions)
                            BriefCommandBar(model: model)
                            BriefFinishBar(model: model, interactions: interactions, review: { showReview = true })
                        }
                        .background(.bar)
                    }
                } else {
                    if model.isBusy {
                        ProgressView("Opening your briefs…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView {
                            Label("Start an implementation brief", systemImage: "doc.text")
                        } description: {
                            Text("Speak through a change, add exact references, and refine one document.")
                        } actions: {
                            Button("New brief") { Task { await model.newSession() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }.navigationSplitViewStyle(.balanced)
            Divider()
            ActivityFooter(model: model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showNewPassage = true } label: { Label("Add paragraph", systemImage: "text.badge.plus") }
                    .disabled(model.currentBrief == nil || model.isEditingRecording)
                    .accessibilityIdentifier("addPassage")
                Menu {
                    Button("Insert exact text…") { showExactReference = true }
                    Button("Insert clipboard exactly") { interactions.insertClipboard() }
                    Button("Insert selected text file…") { insertReferenceFile(model: model) }
                } label: { Label("Exact reference", systemImage: "curlybraces") }
                .disabled(model.currentBrief == nil || model.isEditingRecording)
                .accessibilityIdentifier("insertExactReferenceMenu")
                Button { showRecordings = true } label: { Label("Recordings", systemImage: "waveform") }
                    .disabled(model.selectedSessionID == nil)
                    .accessibilityIdentifier("openRecordings")
                Button { showSources = true } label: { Label("Sources", systemImage: "waveform.and.magnifyingglass") }
                    .accessibilityIdentifier("openSources")
                Menu {
                    Button("Local models…") { showModels = true }
                    Button("Project vocabulary…") { showDictionary = true }
                    Button("Shortcuts & settings…") { openSettings() }
                    Divider()
                    Button("Show Trash…") { showTrash = true }
                } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                .accessibilityIdentifier("workspaceSettingsMenu")
            }
        }
        .sheet(isPresented: $showNewPassage) {
            AddBriefPassageSheet(model: model, exact: false)
        }
        .sheet(isPresented: $showExactReference) {
            AddBriefPassageSheet(model: model, exact: true)
        }
        .sheet(isPresented: $showSources) { BriefSourcesPanel(model: model) }
        .sheet(isPresented: $showRecordings) { BriefRecordingsSheet(model: model, interactions: interactions) }
        .sheet(isPresented: $showTrash) { BriefTrashSheet(model: model) }
        .sheet(isPresented: $showModels) { ModelManagerView(model: model).frame(minWidth: 760, minHeight: 560) }
        .sheet(isPresented: $showDictionary) { DictionaryView(model: model).frame(minWidth: 650, minHeight: 500) }
        .sheet(isPresented: $showReview) { BriefFinishReview(model: model) }
        .alert("Keystorm", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .task {
            interactions.configure(workspace: model) { openWindow(id: "workspace") }
            await model.initialize()
            await model.ensureBrief()
            #if DEBUG
            model.previewRecordingHUDForUITest()
            #endif
        }
        .onChange(of: model.currentBrief?.revisionID) { interactions.validateReadback() }
        .onChange(of: model.selectedSectionKind) { interactions.validateReadback() }
        .onChange(of: model.selectedSessionID) { interactions.readback.stop() }
        .onChange(of: model.isRecording) { if model.isRecording { interactions.readback.stop() } }
        .frame(minWidth: 1020, minHeight: 700)
    }
}

struct BriefSectionNavigation: Equatable {
    let id = UUID()
    let section: BriefSectionKind
}

#if DEBUG
private struct WorkspaceDesignPreview: View {
    @State private var model = WorkspaceModel.workspacePreview()
    @State private var interactions = AppInteractionController()
    let colorScheme: ColorScheme
    var compact = false

    var body: some View {
        // Compose the real workspace components without startup side effects or canvas toolbars.
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                BriefSidebar(model: model, openTrash: {}) { model.selectedSectionKind = $0 }
                    .frame(width: 250)
                    .background(Color(nsColor: .windowBackgroundColor))
                Divider()
                VStack(spacing: 0) {
                    BriefHeader(model: model)
                    BriefDocumentSurface(sections: model.currentBrief?.sections ?? [], model: model,
                        interactions: interactions, reviewIsPresented: false, navigationRequest: nil)
                    VStack(spacing: 0) {
                        BriefCaptureBar(model: model, interactions: interactions)
                        BriefCommandBar(model: model)
                        BriefFinishBar(model: model, interactions: interactions, review: {})
                    }.background(.bar)
                }
            }
            Divider()
            ActivityFooter(model: model)
        }
        .frame(width: compact ? 1020 : 1180, height: compact ? 700 : 780)
        .preferredColorScheme(colorScheme)
        .allowsHitTesting(false)
    }
}

#Preview("Workspace · Light") { WorkspaceDesignPreview(colorScheme: .light) }
#Preview("Workspace · Dark") { WorkspaceDesignPreview(colorScheme: .dark) }
#Preview("Workspace · Compact") { WorkspaceDesignPreview(colorScheme: .light, compact: true) }
#endif


/// Keep section navigation out of the window's invalidation boundary and respect writing focus.
struct BriefDocumentSurface: View {
    let sections: [BriefSection]
    @Bindable var model: WorkspaceModel
    @Bindable var interactions: AppInteractionController
    let reviewIsPresented: Bool
    let navigationRequest: BriefSectionNavigation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    BriefTakeSummary(model: model)
                    ForEach(sections) { section in
                        BriefSectionEditor(section: section, model: model, interactions: interactions)
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 28)
                .frame(maxWidth: 840).frame(maxWidth: .infinity)
            }
            .background(.background)
            .onChange(of: navigationRequest) { _, request in
                // Explicit navigation also works when the selected section has not changed.
                // Focusing a paragraph never creates a request or moves the writing viewport.
                guard let request else { return }
                if reduceMotion { proxy.scrollTo(request.section, anchor: .top) }
                else { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(request.section, anchor: .top) } }
            }
            .onChange(of: reviewIsPresented) { _, presented in
                guard !presented, let passage = model.selectedBlockIDs.first else { return }
                proxy.scrollTo(passage, anchor: .center)
            }
        }
    }
}

struct BriefSidebar: View {
    @Bindable var model: WorkspaceModel
    let openTrash: () -> Void
    let navigate: (BriefSectionKind) -> Void
    @State private var renameTarget: BriefRenameTarget?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedSessionID) {
                Section("Briefs") {
                    ForEach(model.activeSessions) { session in
                        BriefSessionRow(id: session.id, title: session.title, createdAt: session.createdAt,
                                        duration: session.activeRecordedDuration).tag(session.id)
                            .contextMenu {
                                Button("Rename…") { renameTarget = BriefRenameTarget(id: session.id, title: session.title) }
                                    .disabled(model.isBusy)
                                Button("Move to Trash", systemImage: "trash", role: .destructive) {
                                    Task { await model.trashSession(id: session.id) }
                                }.disabled(model.isBusy)
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(height: min(CGFloat(max(1, model.activeSessions.count)) * 70 + 40, 260))
            .disabled(model.isRecording || model.isCaptureTransitioning || model.isEditingRecording)
            .onDeleteCommand {
                guard !model.isRecording, !model.isCaptureTransitioning, !model.isBusy,
                      let id = model.selectedSessionID else { return }
                Task { await model.trashSession(id: id) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Outline").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 6)
                    ForEach(BriefSectionKind.allCases) { kind in
                        Button {
                            model.selectedSectionKind = kind
                            model.selectedBlockIDs = []
                            navigate(kind)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: kind.navigationSymbol)
                                    .frame(width: 18).foregroundStyle(.secondary)
                                Text(kind.title)
                                Spacer(minLength: 4)
                                Text("\(model.currentBrief?.section(kind).blocks.count ?? 0)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .contentShape(.rect)
                            .background(model.selectedSectionKind == kind ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(kind.title), \(model.currentBrief?.section(kind).blocks.count ?? 0) paragraphs")
                        .accessibilityValue(model.selectedSectionKind == kind ? "Selected" : "")
                        .accessibilityIdentifier("section-\(kind.rawValue)")
                    }
                }.padding(.horizontal, 12)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: 8) {
                Button { Task { await model.newSession() } } label: {
                    Label("New brief", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isRecording || model.isCaptureTransitioning || model.isEditingRecording)
                .accessibilityIdentifier("newBrief")
                Button(action: openTrash) { Label("Trash", systemImage: "trash").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help("Open Trash")
                    .accessibilityIdentifier("openTrash")
            }.controlSize(.large).padding(12)
        }
        .navigationTitle("Keystorm")
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        .sheet(item: $renameTarget) { target in
            LibraryNameSheet(title: "Rename brief", fieldLabel: "Brief title", fieldIdentifier: "briefTitle",
                saveLabel: "Save title", initialName: target.title) { name in
                    await model.renameSession(id: target.id, title: name)
                    let message = model.error
                    if message != nil { model.error = nil }
                    return message
                }
        }
    }
}

private extension BriefSectionKind {
    var navigationSymbol: String {
        switch self {
        case .goal: "scope"
        case .changes: "text.alignleft"
        case .constraints: "slider.horizontal.3"
        case .acceptance: "checklist"
        case .deferred: "clock"
        case .questions: "questionmark.circle"
        }
    }

    var writingPrompt: LocalizedStringKey {
        switch self {
        case .goal: "What would you like to achieve?"
        case .changes: "Describe what should change."
        case .constraints: "Add the details that must stay true."
        case .acceptance: "How will you know it’s done?"
        case .deferred: "Keep ideas for later here."
        case .questions: "What still needs an answer?"
        }
    }
}

struct BriefSessionRow: View {
    let id: UUID
    let title: String
    let createdAt: Date
    let duration: Double
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text").font(.body).foregroundStyle(.secondary)
                .padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                HStack {
                    Text(createdAt, format: .dateTime.month(.abbreviated).day())
                    if duration > 0 {
                        Text("·")
                        Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("briefSession-\(id.uuidString)")
    }
}

private struct BriefHeaderTitleIdentity: Hashable {
    let sessionID: UUID?
    let title: String
}

struct BriefHeader: View {
    @Bindable var model: WorkspaceModel
    @State private var renaming = false
    @State private var name = ""
    @State private var renameSessionID: UUID?
    var body: some View {
        let title = model.selectedSession?.title ?? "Implementation brief"
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.largeTitle.weight(.semibold))
                    .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("briefTitleHeading")
                    // Recreate only the selectable heading wrapper when its brief/title changes.
                    .id(BriefHeaderTitleIdentity(sessionID: model.selectedSessionID, title: title))
                HStack(spacing: 12) {
                    BriefProjectButton(model: model)
                    if model.currentBrief?.isReviewed == true {
                        Label("Reviewed", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Text("Draft").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                name = model.selectedSession?.title ?? ""
                renameSessionID = model.selectedSessionID
                renaming = true
            } label: { Label("Rename", systemImage: "pencil").labelStyle(.iconOnly) }
                .buttonStyle(.borderless).help("Rename brief")
                .disabled(model.isRecording || model.isCaptureTransitioning || model.isEditingRecording)
                .padding(.top, 6)
        }
        .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 8)
            .popover(isPresented: $renaming) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Brief title", text: $name).frame(width: 300)
                        .autocorrectionDisabled(true)
                        .onSubmit { saveTitle() }
                        .accessibilityLabel("Brief title").accessibilityIdentifier("briefTitle")
                    Button("Save title", action: saveTitle)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(18)
            }
    }

    private func saveTitle() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let title = name
        Task {
            guard let renameSessionID, model.selectedSessionID == renameSessionID else {
                model.error = "The selected brief changed. Open Rename again for the intended brief."
                return
            }
            await model.renameSession(id: renameSessionID, title: title)
            if model.error == nil { renaming = false }
        }
    }
}

struct BriefCaptureBar: View {
    @Bindable var model: WorkspaceModel
    @Bindable var interactions: AppInteractionController
    private var primaryTitle: String { model.isRecording ? "Pause take" : model.canResumeTake ? "Resume take" : "Record take" }
    private var displayedIntent: Binding<CaptureIntent> {
        Binding {
            model.openTake?.intent ?? model.captureIntent
        } set: { intent in
            guard !model.hasOpenTake, !model.isCaptureTransitioning, !model.isEditingRecording else { return }
            model.captureIntent = intent
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    interactions.readback.stop()
                    Task {
                        if model.isRecording { await model.pauseRecording() }
                        else { await model.startRecording() }
                    }
                } label: {
                    Label(primaryTitle, systemImage: model.isRecording ? "pause.fill" : model.canResumeTake ? "play.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent).tint(model.isRecording ? .red : .accentColor)
                .controlSize(.large).disabled(model.isCaptureTransitioning || model.isEditingRecording)
                .accessibilityIdentifier("recordPause")

                Picker("Intent", selection: displayedIntent) {
                    Text("Add material").tag(CaptureIntent.addMaterial)
                    Text("Edit brief").tag(CaptureIntent.editBrief)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                .disabled(model.hasOpenTake || model.isCaptureTransitioning || model.isEditingRecording)

                HStack(spacing: 4) {
                    Button {
                        interactions.readback.stop()
                        Task { await model.finishTake() }
                    } label: { Label("Finish take", systemImage: "stop.fill").labelStyle(.iconOnly) }
                        .disabled(!model.hasOpenTake || model.isCaptureTransitioning || model.isEditingRecording)
                        .help("Finish this take before updating the brief.")
                        .accessibilityIdentifier("finishTake")
                    Button {
                        interactions.readback.stop()
                        Task { await model.startNewTake() }
                    } label: { Label("New take", systemImage: "plus").labelStyle(.iconOnly) }
                        .disabled(model.isCaptureTransitioning || model.isEditingRecording)
                        .help("Start a separate recording take.")
                        .accessibilityIdentifier("newTake")
                }.buttonStyle(.borderless)

                Spacer(minLength: 4)
                BriefCaptureMetrics(model: model)
                Button("Update brief") {
                    interactions.readback.stop()
                    Task { await model.prepareBrief() }
                }
                .buttonStyle(.bordered)
                .disabled(model.hasOpenTake || model.isCaptureTransitioning || model.isBusy)
                .help(model.hasOpenTake ? "Finish the take before preparing changes." : "Review proposed changes from your recorded material.")
                .accessibilityIdentifier("updateBrief")
            }
            if let take = model.openTake {
                Text("\(take.intent == .addMaterial ? "Add material" : "Edit brief") · \(take.targetSection.title)")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    .accessibilityLabel("Current take: \(take.intent == .addMaterial ? "Add material" : "Edit brief"), \(take.targetSection.title)")
            }
        }
        .padding(12)
        .modifier(BriefCaptureSurface())
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The floating recording controls sit above the document's opaque content layer.
private struct BriefCaptureSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(.separator))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
    }
}

struct BriefCaptureMetrics: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            BriefTakeClock(model: model)
            if let session = model.selectedSession, session.activeRecordedDuration > 0 {
                Text("Saved \(Int(session.activeSavedDuration))s · transcribed \(Int(session.activeTranscribedDuration))s")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct BriefTakeClock: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(Duration.seconds((model.isRecording || model.hasOpenTake) ? model.takeElapsed : (model.selectedSession?.activeRecordedDuration ?? 0)),
                 format: .time(pattern: .hourMinuteSecond)).font(.callout.monospacedDigit())
            Text(model.isRecording ? "Recording" : model.canResumeTake ? "Take paused" : "Ready")
                .font(.caption).foregroundStyle(model.isRecording ? Color.red : Color.secondary)
        }
    }
}

struct BriefSectionEditor: View {
    let section: BriefSection
    @Bindable var model: WorkspaceModel
    @Bindable var interactions: AppInteractionController
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    model.selectedSectionKind = section.kind
                    model.selectedBlockIDs = []
                } label: {
                    Text(section.kind.title).font(.headline).accessibilityAddTraits(.isHeader)
                }.buttonStyle(.plain)
                Spacer()
                Button {
                    model.selectedSectionKind = section.kind
                    interactions.readSelectedSection()
                } label: { Label("Read \(section.kind.title)", systemImage: "speaker.wave.2").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help("Read this section")
                    .disabled(section.blocks.isEmpty || model.isRecording)
            }
            .id(section.kind)
            if section.blocks.isEmpty {
                Text(section.kind.writingPrompt)
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 4).padding(.bottom, 6)
            }
            ForEach(section.blocks) { block in
                BriefPassageRow(id: block.id, text: block.text, origin: block.origin,
                    exact: block.exact, sourceCount: block.sources.count,
                    section: section.kind, model: model, interactions: interactions)
                    .id(block.id)
            }
        }
    }
}

struct BriefPassageRow: View {
    let id: UUID
    let text: String
    let origin: BriefOrigin
    let exact: Bool
    let sourceCount: Int
    let section: BriefSectionKind
    @Bindable var model: WorkspaceModel
    @Bindable var interactions: AppInteractionController
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button {
                    model.selectedSectionKind = section
                    model.selectedBlockIDs = [id]
                } label: {
                    Label("Target passage in \(section.title)",
                          systemImage: model.selectedBlockIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                        .labelStyle(.iconOnly)
                }
                    .buttonStyle(.plain).foregroundStyle(model.selectedBlockIDs.contains(id) ? Color.accentColor : .secondary)
                    .accessibilityValue(model.selectedBlockIDs.contains(id) ? "Selected" : "Not selected")
                    .help("Target this passage for an edit").accessibilityIdentifier("target-\(id.uuidString)")
                Text(exact ? "Exact reference" : origin == .typed ? "Your text" : "Source-linked passage")
                    .font(.caption2).foregroundStyle(.secondary)
                if exact {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("Locked exact reference")
                }
                Spacer()
                if sourceCount > 0 {
                    Button("\(sourceCount) sources") { showSource = true }
                        .font(.caption).buttonStyle(.borderless)
                }
                Menu {
                    ForEach(BriefSectionKind.allCases) { kind in
                        Button("Move to \(kind.title)") { Task { await model.moveBriefBlock(id: id, to: kind, index: nil) } }
                    }
                    Divider()
                    if exact {
                        Button("Unlock exact reference for editing") { Task { await model.unlockBriefBlock(id: id) } }
                    } else {
                        Button("Remove passage", role: .destructive) {
                            Task { await model.removeBriefBlock(id: id) }
                        }
                    }
                } label: { Label("Passage actions", systemImage: "ellipsis").labelStyle(.iconOnly) }
                    .menuStyle(.borderlessButton).frame(width: 28)
                    .accessibilityIdentifier("passageActions-\(id.uuidString)")
                    .disabled(model.isEditingRecording)
            }.padding(.horizontal, 10).padding(.top, 8)
            NativeBriefEditor(blockID: id, text: text, editable: !exact && !model.isEditingRecording,
                highlight: interactions.highlight(for: id),
                accessibilityLabel: exact ? String(localized: "Exact reference in \(section.title)") :
                    String(localized: "Paragraph in \(section.title)"),
                onChange: { model.updateBriefBlock(id: id, text: $0) },
                onFocus: { model.selectedSectionKind = section; model.selectedBlockIDs = [id] })
                .accessibilityIdentifier("editor-\(id.uuidString)")
        }
        .background(model.selectedBlockIDs.contains(id) ? Color.accentColor.opacity(0.045) : exact ? Color.primary.opacity(0.035) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(model.selectedBlockIDs.contains(id) ? Color.accentColor.opacity(0.3) : .clear))
        .sheet(isPresented: $showSource) { BriefPassageSources(blockID: id, model: model) }
    }
}

struct BriefCommandBar: View {
    @Bindable var model: WorkspaceModel
    @State private var command = ""
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Type an editing instruction…", text: $command)
                .textFieldStyle(.plain).autocorrectionDisabled(true)
                .accessibilityLabel("Editing instruction")
                .onSubmit { propose() }.accessibilityIdentifier("briefCommand")
                .disabled(model.isEditingRecording)
            Button("Preview edit", action: propose)
                .buttonStyle(.borderless)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy || model.isRecording)
                .accessibilityIdentifier("previewBriefEdit")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.background, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4)))
        .padding(.horizontal, 20).padding(.top, 8)
    }
    private func propose() {
        let instruction = command
        guard !model.isBusy, !model.isRecording, !model.isCaptureTransitioning, !model.isEditingRecording,
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await model.proposeBriefCommand(text: instruction); if model.error == nil { command = "" } }
    }
}

struct BriefProposalView: View {
    let proposal: BriefProposal
    let document: BriefDocument
    @Bindable var model: WorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(proposal.label, systemImage: "sparkles").font(.headline).lineLimit(2)
                Spacer()
                Text("Proposed change").font(.caption).foregroundStyle(.secondary)
            }
            if !proposal.edits.isEmpty || !proposal.issues.isEmpty || proposal.expectedRevision != document.revisionID {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(proposal.edits.enumerated(), id: \.offset) { _, edit in
                            BriefEditPreview(edit: edit, document: document)
                        }
                        ForEach(proposal.issues, id: \.self) { issue in
                            Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                        if proposal.expectedRevision != document.revisionID {
                            Text("The brief changed. Recompute these changes against your latest text, or reject this material.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .accessibilityIdentifier("briefChangePreview")
            }
            HStack {
                Button("Reject change") { Task { await model.discardBriefProposal() } }.accessibilityIdentifier("discardBriefChange")
                    .disabled(model.isEditingRecording)
                if proposal.expectedRevision != document.revisionID {
                    Button("Recompute changes") { Task { await model.refreshBriefProposal() } }
                        .disabled(model.isBusy).accessibilityIdentifier("refreshBriefChange")
                }
                Spacer()
                Button("Apply change") { Task { await model.acceptBriefProposal() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.isEditingRecording || proposal.expectedRevision != document.revisionID)
                    .accessibilityIdentifier("applyBriefChange")
            }
        }.id(proposal.id)
            .padding(16).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.25)))
    }
}

struct BriefEditPreview: View {
    let edit: BriefEdit
    let document: BriefDocument
    var body: some View {
        switch edit {
        case .append(let section, let block):
            VStack(alignment: .leading, spacing: 4) {
                Text("Add to \(section.title)").font(.caption).foregroundStyle(.secondary)
                Text(block.text).textSelection(.enabled)
            }
        case .replace(let id, let text, _, _, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(document.block(id)?.text ?? "Missing passage").strikethrough().foregroundStyle(.secondary)
                Text(text).textSelection(.enabled)
            }
        case .move(let id, let section, _):
            Label("Move to \(section.title)", systemImage: "arrow.turn.down.right").font(.caption)
            Text(document.block(id)?.text ?? "Missing passage").textSelection(.enabled)
        case .remove(let id, _):
            Text(document.block(id)?.text ?? "Missing passage").strikethrough().foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct BriefTakeSummary: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        let takes = model.pendingBriefTakes
        if !takes.isEmpty || model.pendingBriefIssue != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let issue = model.pendingBriefIssue {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                ForEach(takes) { take in
                    HStack {
                        Label(take.intent == .addMaterial ? "Material for \(take.targetSection.title)" : "Editing instruction",
                              systemImage: take.intent == .addMaterial ? "waveform" : "text.cursor")
                        Text(take.status.rawValue).foregroundStyle(.secondary)
                        Spacer()
                        if take.status != .recording {
                            Button("Exclude take") { Task { await model.dismissBriefTake(id: take.id) } }.font(.caption)
                        }
                    }.font(.caption)
                }
                Text("Your document stays stable. Update the brief to review a proposed change.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct BriefFinishBar: View {
    @Bindable var model: WorkspaceModel
    @Bindable var interactions: AppInteractionController
    let review: () -> Void
    var body: some View {
        HStack {
            Button { Task { await model.undoBrief() } } label: { Label("Undo change", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly) }
                .help("Undo brief change")
                .disabled(model.isEditingRecording || model.currentBrief?.canUndo != true).accessibilityIdentifier("undoBrief")
            Button { Task { await model.redoBrief() } } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(model.isEditingRecording || model.currentBrief?.canRedo != true).help("Redo brief change")
                .accessibilityLabel("Redo brief change").accessibilityIdentifier("redoBrief")
            Divider().frame(height: 18)
            Button { interactions.readSelectedSection() } label: { Label("Read section", systemImage: "speaker.wave.2").labelStyle(.iconOnly) }
                .disabled(model.isRecording || model.isCaptureTransitioning)
            if interactions.readback.isSpeaking {
                Button(interactions.readback.isPaused ? "Resume" : "Pause") { interactions.readback.togglePause() }
                Button { interactions.readback.stop() } label: { Label("Stop read-back", systemImage: "stop.fill").labelStyle(.iconOnly) }
                    .help("Stop read-back")
            }
            Spacer()
            Button("Review & finish", action: review)
                .buttonStyle(.borderedProminent).accessibilityIdentifier("reviewBrief")
                .disabled(model.isEditingRecording)
            Button("Copy") { copyReviewedBrief(model) }
                .disabled(model.currentBrief?.isReviewed != true).accessibilityIdentifier("copyBrief")
            Button("Save Markdown…") { saveReviewedBrief(model) }
                .buttonStyle(.bordered).disabled(model.currentBrief?.isReviewed != true)
                .accessibilityIdentifier("saveBrief")
        }
        .buttonStyle(.borderless).controlSize(.regular)
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 14)
    }
}

struct AddBriefPassageSheet: View {
    @Bindable var model: WorkspaceModel
    let exact: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var targetSessionID: UUID?
    @State private var targetSection: BriefSectionKind?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(exact ? "Insert an exact reference" : "Add a paragraph").font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Into \((targetSection ?? model.selectedSectionKind).title)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(exact ? .body.monospaced() : .body).frame(minHeight: 220)
                .disabled(model.isEditingRecording)
                .accessibilityLabel(exact ? "Exact reference text" : "New paragraph text")
                .accessibilityIdentifier("newPassageText")
            if exact { Text("The inserted text is protected from automatic rewriting until you explicitly unlock it.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(exact ? "Insert reference" : "Add paragraph") {
                    let value = text
                    Task {
                        guard let targetSessionID, model.selectedSessionID == targetSessionID,
                              model.selectedSectionKind == targetSection else {
                            model.error = "The insertion target changed. Open a new paragraph or reference for the selected brief."
                            return
                        }
                        if exact { await model.insertExactReference(text: value, filePath: nil, origin: .typed) }
                        else { await model.appendBriefBlock(text: value, origin: .typed, exact: false, filePath: nil) }
                        dismiss()
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(model.isEditingRecording || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targetSessionID == nil ||
                              model.selectedSessionID != targetSessionID || model.selectedSectionKind != targetSection)
                    .accessibilityIdentifier("confirmPassage")
            }
        }.padding(24).frame(width: 650)
            .onAppear {
                if targetSessionID == nil {
                    targetSessionID = model.selectedSessionID
                    targetSection = model.selectedSectionKind
                }
            }
    }
}

struct BriefFinishReview: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false
    @State private var targetSessionID: UUID?
    @State private var targetRevisionID: UUID?
    private var reviewTargetIsCurrent: Bool {
        targetSessionID != nil && targetRevisionID != nil && model.selectedSessionID == targetSessionID &&
            model.currentBrief?.revisionID == targetRevisionID
    }
    var body: some View {
        let issues = model.briefReviewIssues
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Finish this brief").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Check the scope, constraints, and acceptance criteria. Open source material wherever an interpretation needs checking.")
                .foregroundStyle(.secondary)
            List(issues) { issue in
                VStack(alignment: .leading, spacing: 4) {
                    Label(issue.message, systemImage: issue.severity == .blocker ? "exclamationmark.triangle.fill" : "questionmark.circle")
                        .foregroundStyle(issue.severity == .blocker ? Color.orange : Color.secondary)
                    if issue.kind == .superseded, issue.severity == .blocker, let factID = issue.factID {
                        Button("Review using the correction") {
                            Task {
                                guard reviewTargetIsCurrent else { return }
                                await model.proposeBriefSupersession(factID: factID)
                                if model.pendingBriefProposal != nil { dismiss() }
                            }
                        }.font(.caption)
                    }
                    if let id = issue.blockID {
                        Button("Show passage") {
                            if let placement = model.currentBrief?.placement(id) { model.selectedSectionKind = placement.section; model.selectedBlockIDs = [id] }
                            dismiss()
                        }.font(.caption)
                    }
                }.padding(.vertical, 4)
            }.overlay {
                if issues.isEmpty {
                    ContentUnavailableView("Ready for your review", systemImage: "checkmark.shield",
                        description: Text("Read through your brief, then mark it reviewed when you’re ready to share."))
                }
            }
            if targetSessionID != nil && !reviewTargetIsCurrent {
                Label("The brief changed during review. Close this sheet, inspect the latest brief, and open Review & finish again.",
                      systemImage: "arrow.clockwise").font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("staleBriefReview")
            }
            Toggle("I have reviewed this brief and its open issues.", isOn: $confirmed)
                .disabled(!reviewTargetIsCurrent).accessibilityIdentifier("confirmBriefReview")
            Button("Mark reviewed") {
                Task {
                    guard reviewTargetIsCurrent else { return }
                    await model.reviewBrief()
                    if reviewTargetIsCurrent && model.currentBrief?.isReviewed == true { dismiss() }
                }
            }.buttonStyle(.borderedProminent)
                .disabled(!reviewTargetIsCurrent || !confirmed || model.isRecording || model.isBusy || issues.contains { $0.severity == .blocker })
                .accessibilityIdentifier("approveBrief")
        }.padding(24).frame(width: 720, height: 540)
            .onAppear {
                if targetSessionID == nil {
                    targetSessionID = model.selectedSessionID
                    targetRevisionID = model.currentBrief?.revisionID
                }
            }
    }
}

struct BriefSourcesPanel: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Sources & history").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() } }.padding()
            TabView {
                Tab("Recordings & transcript", systemImage: "waveform") { TranscriptView(model: model).padding(.top) }
                Tab("Meaning ledger", systemImage: "list.bullet.clipboard") { BriefLedgerInspector(model: model) }
                Tab("Context & archive", systemImage: "folder") { ContextView(model: model) }
                Tab("Earlier drafts", systemImage: "clock") { DraftHistoryView(drafts: model.selectedSession?.drafts ?? []) }
            }
        }.frame(minWidth: 850, minHeight: 600)
    }
}

struct BriefLedgerInspector: View {
    @Bindable var model: WorkspaceModel
    @State private var inspectedFact: Fact?
    var body: some View {
        List(model.selectedSession?.facts ?? []) { fact in
            VStack(alignment: .leading, spacing: 6) {
                Text(fact.text).textSelection(.enabled)
                HStack {
                    Text("\(fact.kind.rawValue) · \(fact.status.rawValue)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Inspect source") { inspectedFact = fact }
                }.font(.caption)
            }.padding(.vertical, 6)
        }.sheet(item: $inspectedFact) { SourceEvidenceView(fact: $0, model: model) }
    }
}

struct BriefPassageSources: View {
    let blockID: UUID
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Supporting material").font(.title2); Spacer(); Button("Done") { dismiss() } }
            if let block = model.currentBrief?.block(blockID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(block.text).font(.headline).textSelection(.enabled)
                        ForEach(block.sources) { source in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(source.quote).textSelection(.enabled)
                                if let session = model.selectedSession,
                                   let transcript = session.transcripts.first(where: { $0.id == source.transcriptID }) {
                                    Text("Source timing: \(transcript.timingPrecision.rawValue)").font(.caption).foregroundStyle(.secondary)
                                    if let segment = session.availableSegments.first(where: { transcript.segmentIDs.contains($0.id) }) {
                                        Button("Play source segment") { Task { await model.playback(segment: segment) } }
                                    }
                                    DisclosureGroup("Full transcript region") { Text(transcript.text).textSelection(.enabled) }
                                }
                            }
                            Divider()
                        }
                        ForEach(block.contextIDs, id: \.self) { id in
                            if let context = model.selectedSession?.contexts.first(where: { $0.id == id }) {
                                Text(context.title).font(.headline)
                                Text(context.content).font(.body.monospaced()).textSelection(.enabled)
                                Text(context.sha256).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        if block.sources.isEmpty && block.contextIDs.isEmpty {
                            Text("Added directly by you.").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.padding(24).frame(width: 700, height: 500)
    }
}

@MainActor
func copyReviewedBrief(_ model: WorkspaceModel) {
    guard let targetSessionID = model.selectedSessionID, let targetRevisionID = model.currentBrief?.revisionID else { return }
    Task {
        do {
            let snapshot = try await model.reviewedBriefSnapshot()
            guard snapshot.session.id == targetSessionID, snapshot.revisionID == targetRevisionID,
                  model.isCurrentBrief(snapshot) else { throw KeystormError.message("The brief changed. Review it again before copying.") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snapshot.text, forType: .string)
        } catch { model.error = error.localizedDescription }
    }
}

@MainActor
func saveReviewedBrief(_ model: WorkspaceModel) {
    guard let targetSessionID = model.selectedSessionID, let targetRevisionID = model.currentBrief?.revisionID,
          model.currentBrief?.isReviewed == true else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    let title = (model.selectedSession?.title ?? "Implementation brief").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    panel.nameFieldStringValue = title + ".md"
    if let path = model.selectedSession?.projectPath { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
    panel.begin { response in
        guard response == .OK, let url = panel.url else { return }
        Task {
            do {
                guard model.selectedSessionID == targetSessionID, model.currentBrief?.revisionID == targetRevisionID,
                      model.currentBrief?.isReviewed == true else {
                    throw KeystormError.message("The selected brief changed while choosing an export destination. Review it and save again.")
                }
                try await model.exportBrief(to: url, includeProvenance: true)
            } catch { model.error = error.localizedDescription }
        }
    }
}

@MainActor
func insertReferenceFile(model: WorkspaceModel) {
    guard let targetSessionID = model.selectedSessionID else { return }
    let targetSection = model.selectedSectionKind
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Insert an explicitly selected UTF-8 text or code file as an exact reference."
    panel.begin { response in
        guard response == .OK, let url = panel.url else { return }
        Task {
            do {
                let text = try await Task.detached {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 131_073) ?? Data()
                    guard data.count <= 131_072, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                        throw KeystormError.message("Choose a UTF-8 text file under 128 KB.")
                    }
                    return value
                }.value
                guard model.selectedSessionID == targetSessionID, model.selectedSectionKind == targetSection else {
                    throw KeystormError.message("The insertion target changed while reading the file. Select the intended brief and section, then insert again.")
                }
                await model.insertExactReference(text: text, filePath: url.path)
            } catch { model.error = error.localizedDescription }
        }
    }
}
