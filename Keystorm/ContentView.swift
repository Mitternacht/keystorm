import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LegacyWorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @State private var tab = SessionTab.transcript
    @State private var showImport = false
    @State private var showModels = false
    @State private var showDictionary = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
            SessionSidebar(model: model).disabled(model.isRecording)
        } detail: {
            if let session = model.selectedSession {
                VStack(spacing: 0) {
                    RecordingBar(model: model, savedThrough: session.savedThrough,
                                 transcribedThrough: session.transcribedThrough, gapCount: session.gaps.count)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Picker("Workspace", selection: $tab) {
                        ForEach(SessionTab.allCases) { item in Text(item.title).tag(item) }
                    }
                    .pickerStyle(.segmented).padding()
                    SessionContent(model: model, tab: tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .navigationTitle(session.title)
                .navigationSubtitle("Private workspace · on-device processing")
            } else {
                ContentUnavailableView {
                    Label("Make room for a long thought", systemImage: "waveform")
                } description: {
                    Text("Record naturally. Keep the original. Review a prompt that preserves what you meant.")
                } actions: {
                    Button("New session") { Task { await model.newSession() } }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("newSessionEmpty")
                }
            }
        }
            .navigationSplitViewStyle(.balanced)
            Divider()
            ActivityFooter(model: model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showImport = true } label: { Label("Import transcript", systemImage: "text.badge.plus") }
                    .help("Add explicitly selected text without claiming it was transcribed")
                Button { showDictionary = true } label: { Label("Dictionary", systemImage: "character.book.closed") }
                Button { showModels = true } label: { Label("Local models", systemImage: "cpu") }
            }
        }
        .sheet(isPresented: $showImport) {
            TextImportSheet { text in await model.importTranscript(text: text) }
        }
        .sheet(isPresented: $showModels) { ModelManagerView(model: model).frame(minWidth: 760, minHeight: 560) }
        .sheet(isPresented: $showDictionary) { DictionaryView(model: model).frame(minWidth: 650, minHeight: 500) }
        .alert("Keystorm", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .task { await model.initialize() }
        .frame(minWidth: 940, minHeight: 650)
    }
}

enum SessionTab: String, CaseIterable, Identifiable {
    case transcript, facts, prompt, context
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self { case .transcript: "Transcript"; case .facts: "Facts & decisions"; case .prompt: "Prepared prompt"; case .context: "Context" }
    }
}

struct SessionSidebar: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedSessionID) {
                Section("Sessions") {
                    ForEach(model.sessions) { session in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(session.title).lineLimit(1).font(.headline)
                            HStack {
                                Text(session.createdAt, format: .dateTime.month(.abbreviated).day())
                                Spacer()
                                Text(Duration.seconds(session.recordedDuration), format: .time(pattern: .minuteSecond))
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(session.id)
                    }
                }
            }.listStyle(.sidebar)
            Divider()
            Button { Task { await model.newSession() } } label: {
                Label("New session", systemImage: "plus").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).padding().disabled(model.isRecording)
                .accessibilityIdentifier("newSession")
        }
        .navigationTitle("Keystorm")
        .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
    }
}

struct RecordingBar: View {
    @Bindable var model: WorkspaceModel
    let savedThrough: Double
    let transcribedThrough: Double
    let gapCount: Int
    var body: some View {
        HStack(spacing: 18) {
            Button {
                Task { if model.isRecording { await model.pauseRecording() } else { await model.startRecording() } }
            } label: {
                Label(model.isRecording ? "Pause recording" : "Record", systemImage: model.isRecording ? "pause.fill" : "mic.fill")
                    .padding(.horizontal, 7)
            }
            .buttonStyle(.borderedProminent).tint(model.isRecording ? .red : .accentColor)
            .controlSize(.large).accessibilityIdentifier("recordPause")
            VStack(alignment: .leading, spacing: 4) {
                Text(Duration.seconds(model.elapsed), format: .time(pattern: .hourMinuteSecond))
                    .font(.title2.monospacedDigit()).contentTransition(.numericText())
                Text(model.isRecording ? "Recording now" : "Recording paused").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SavedMetric(title: "Saved through", seconds: savedThrough, symbol: "checkmark.shield")
            SavedMetric(title: "Transcribed through", seconds: transcribedThrough, symbol: "text.alignleft")
            if gapCount > 0 {
                Label { Text("\(gapCount) gaps") } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    .font(.caption).help("Open session context to inspect interruptions")
            }
        }.padding(20)
    }
}

struct SavedMetric: View {
    let title: LocalizedStringResource
    let seconds: Double
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { Text(title) } icon: { Image(systemName: symbol) }.font(.caption).foregroundStyle(.secondary)
            Text(Duration.seconds(seconds), format: .time(pattern: .hourMinuteSecond)).monospacedDigit()
        }
    }
}

struct SessionContent: View {
    @Bindable var model: WorkspaceModel
    let tab: SessionTab
    var body: some View {
        switch tab {
        case .transcript: TranscriptView(model: model)
        case .facts: FactsView(model: model)
        case .prompt: PromptReviewView(model: model)
        case .context: ContextView(model: model)
        }
    }
}

struct TranscriptView: View {
    @Bindable var model: WorkspaceModel
    @State private var editing: TranscriptRevision?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("The original stays available").font(.headline)
                Spacer()
                Button("Transcribe saved audio") { Task { await model.transcribePending() } }.disabled(model.isBusy)
            }.padding(.horizontal).padding(.bottom)
            if let session = model.selectedSession, !session.currentTranscripts.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(session.currentTranscripts) { revision in
                            TranscriptCard(revision: revision, suggestions: Terminology.suggestions(in: revision.text, entries: model.dictionary, projectPath: session.projectPath),
                                edit: { editing = revision },
                                useAsRequirement: { Task { await model.addFact(transcriptID: revision.id, text: revision.text, kind: .requirement, status: .confirmed) } },
                                play: {
                                    if let segment = session.availableSegments.first(where: { revision.segmentIDs.contains($0.id) }) {
                                        Task { await model.playback(segment: segment) }
                                    }
                                }, apply: { suggestion in
                                    Task {
                                        do { await model.correctTranscript(id: revision.id, text: try Terminology.applying(suggestion, to: revision.text)) }
                                        catch { model.error = error.localizedDescription }
                                    }
                                })
                        }
                    }.padding()
                }
            } else {
                ContentUnavailableView("Your words will appear here", systemImage: "waveform",
                    description: Text("Recording works before models are installed. Add local models for progressive transcription, or import text to try review and export."))
            }
            HStack {
                Text("Corrections create new revisions.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Undo last correction") { Task { await model.undoLastCorrection() } }
                    .disabled(model.selectedSession?.corrections.isEmpty ?? true)
            }.padding()
        }
        .sheet(item: $editing) { revision in
            TranscriptEditor(revision: revision) { text in await model.correctTranscript(id: revision.id, text: text) }
        }
    }
}

struct TranscriptCard: View {
    let revision: TranscriptRevision
    let suggestions: [DictionarySuggestion]
    let edit: () -> Void
    let useAsRequirement: () -> Void
    let play: () -> Void
    let apply: (DictionarySuggestion) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(revision.origin == .imported ? "Imported text" : "Transcribed audio", systemImage: revision.origin == .imported ? "doc.text" : "waveform")
                    .font(.caption).foregroundStyle(.secondary)
                if revision.origin == .transcription {
                    Text(Duration.seconds(revision.startTime), format: .time(pattern: .minuteSecond)).font(.caption.monospacedDigit())
                }
                Spacer()
                if !revision.isComplete {
                    Label { Text("Needs review") } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }.font(.caption)
                }
                if !revision.segmentIDs.isEmpty {
                    Button(action: play) { Image(systemName: "play.fill") }.help("Play supporting audio")
                        .accessibilityLabel("Play supporting audio")
                }
                Button("Edit", action: edit).buttonStyle(.borderless)
            }
            Text(revision.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if revision.rawText != revision.text {
                DisclosureGroup("Original transcription") { Text(revision.rawText).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            ForEach(suggestions) { suggestion in
                HStack {
                    Text("\(suggestion.original) → \(suggestion.replacement)").font(.callout)
                    Spacer()
                    Button("Accept correction") { apply(suggestion) }
                }.padding(8).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Button("Use as requirement", action: useAsRequirement).font(.caption)
                .help("Deliberately add this exact text to the source-linked fact ledger")
        }
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.6)))
    }
}

struct FactsView: View {
    @Bindable var model: WorkspaceModel
    @State private var inspectedFact: Fact?
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Review meaning before shortening").font(.headline)
                Spacer()
                Button("Extract & prepare") { Task { await model.preparePrompt() } }.disabled(model.isBusy || model.isRecording)
            }.padding()
            if let session = model.selectedSession {
                let facts = LedgerValidation.currentFacts(in: session)
                if facts.isEmpty {
                    ContentUnavailableView("No facts yet", systemImage: "list.bullet.clipboard",
                        description: Text("Extract with your local model, or deliberately use transcript text as a requirement."))
                } else {
                    List(facts) { fact in
                        FactCard(fact: fact, inspect: { inspectedFact = fact }) { status, reviewed in
                            Task { await model.updateFact(id: fact.id, status: status, reviewed: reviewed) }
                        }
                    }.listStyle(.inset)
                }
            }
        }
        .sheet(item: $inspectedFact) { fact in
            SourceEvidenceView(fact: fact, model: model)
        }
    }
}

struct FactCard: View {
    let fact: Fact
    let inspect: () -> Void
    let update: (FactStatus, Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(fact.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Status", selection: Binding(get: { fact.status }, set: { update($0, fact.reviewed) })) {
                    Text("Confirmed").tag(FactStatus.confirmed)
                    Text("Exploratory").tag(FactStatus.exploratory)
                    Text("Ambiguous").tag(FactStatus.ambiguous)
                    Text("Superseded").tag(FactStatus.superseded)
                }.labelsHidden().frame(maxWidth: 150)
                Toggle("Reviewed", isOn: Binding(get: { fact.reviewed }, set: { update(fact.status, $0) })).toggleStyle(.checkbox)
            }
            Text(fact.text).textSelection(.enabled)
            DisclosureGroup("Supporting source") {
                ForEach(fact.sources) { source in
                    Text(source.quote).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Button("Inspect full source", action: inspect).font(.caption)
            if fact.supersedes != nil {
                Label {
                    Text("Proposed correction to an earlier decision; verify its scope.")
                } icon: {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
                }
                .font(.caption)
            }
        }.padding(.vertical, 10)
    }
}

struct PromptReviewView: View {
    @Bindable var model: WorkspaceModel
    @State private var editedText = ""
    @State private var editing = false
    @State private var showHistory = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Detail", selection: $model.detail) {
                    Text("Brief").tag(DetailLevel.brief)
                    Text("Standard").tag(DetailLevel.standard)
                    Text("Detailed").tag(DetailLevel.detailed)
                }.frame(maxWidth: 270)
                Button("Prepare prompt") { Task { await model.preparePrompt() } }.disabled(model.isBusy || model.isRecording)
                Spacer()
                if let draft = model.currentDraft {
                    Text(draft.createdAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
            }.padding()
            if let draft = model.currentDraft {
                if draft.stale {
                    Label {
                        Text("Sources changed. Prepare a new version before export.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    .padding(.horizontal)
                }
                ScrollView {
                    Text(draft.text).font(.body.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }.background(.background)
                Divider()
                HStack {
                    Button("Edit draft") { editedText = draft.text; editing = true }
                    Button(draft.reviewed ? "Reviewed" : "I've reviewed this draft") { Task { await model.reviewDraft() } }
                        .disabled(draft.stale || draft.reviewed).accessibilityIdentifier("reviewDraft")
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.text, forType: .string)
                    }.disabled(!draft.reviewed || draft.stale).accessibilityIdentifier("copyPrompt")
                    Button("Export…") { exportPrompt(model: model) }
                        .buttonStyle(.borderedProminent).disabled(!draft.reviewed || draft.stale)
                        .accessibilityIdentifier("exportPrompt")
                }.padding()
                DisclosureGroup("Fact coverage and draft history") {
                    Text("\(draft.dispositions.filter { $0.disposition == "included" }.count) facts represented; \(draft.dispositions.filter { $0.disposition != "included" }.count) omitted, superseded, or stale.")
                    if let session = model.selectedSession {
                        Text("\(session.drafts.count) immutable draft versions").foregroundStyle(.secondary)
                        Button("Inspect previous drafts") { showHistory = true }
                        ForEach(draft.dispositions.filter { $0.disposition != "included" }, id: \.factID) { item in
                            if let fact = session.facts.first(where: { $0.id == item.factID }) {
                                Text("\(item.disposition): \(fact.text)").font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }.font(.caption).padding([.horizontal, .bottom])
            } else {
                ContentUnavailableView("A prompt you can stand behind", systemImage: "text.document",
                    description: Text("Prepare from source-linked facts, inspect open questions, then review before copying or exporting."))
            }
        }
        .sheet(isPresented: $editing) {
            DraftEditor(text: $editedText) { await model.amendDraft(text: editedText) }
        }
        .sheet(isPresented: $showHistory) {
            DraftHistoryView(drafts: model.selectedSession?.drafts ?? [])
        }
    }
}

struct ContextView: View {
    @Bindable var model: WorkspaceModel
    @State private var title = ""
    @State private var taskText = ""
    @State private var contextText = ""
    var body: some View {
        Form {
            Section("Session") {
                TextField("Title", text: $title)
                TextField("Task description", text: $taskText, axis: .vertical).lineLimit(3...8)
                HStack {
                    Text(model.selectedSession?.projectPath ?? "No project selected").foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Choose repository…") { chooseRepository(model: model) }
                }
                Button("Save session details") { Task { await model.updateSession(title: title, task: taskText, project: model.selectedSession?.projectPath) } }
            }
            Section("Selected context") {
                TextEditor(text: $contextText).frame(minHeight: 100).font(.body.monospaced())
                HStack {
                    Button("Add note snapshot") {
                        let value = contextText
                        Task { await model.addContext(title: "Selected note", content: value, filePath: nil); contextText = "" }
                    }.disabled(contextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Add selected file…") { chooseContextFile(model: model) }
                }
                ForEach(model.selectedSession?.contexts ?? []) { context in
                    DisclosureGroup(context.title) {
                        Text(context.content).font(.callout).textSelection(.enabled)
                        Text("Snapshot \(context.createdAt.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Interruptions & processing") {
                ForEach(model.selectedSession?.gaps ?? []) { gap in
                    Label { Text(gap.reason) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Text(gap.startedAt, format: .dateTime).font(.caption)
                }
                ForEach(model.selectedSession?.jobs ?? []) { job in
                    HStack {
                        Text(job.stage.rawValue)
                        Spacer()
                        if job.status == .failed || job.status == .incomplete {
                            Label { Text(job.status.rawValue) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                        } else {
                            Text(job.status.rawValue).foregroundStyle(.secondary)
                        }
                    }
                    if let error = job.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Portable sessions") {
                Button("Export session archive, including audio…") { exportArchive(model: model) }
                Button("Import session archive…") { importArchive(model: model) }
            }
        }.formStyle(.grouped)
        .onAppear { refresh() }
        .onChange(of: model.selectedSessionID) { refresh() }
    }
    private func refresh() { title = model.selectedSession?.title ?? ""; taskText = model.selectedSession?.taskDescription ?? "" }
}

struct ModelManagerView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Local models").font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Downloads install verified model data. Recording, transcription, and preparation stay on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }.padding()
            List {
                Section("Speech engine") {
                    Picker("Use for transcription", selection: $model.selectedSpeechModelID) {
                        Text("Parakeet Ultra").tag(ModelCatalog.primarySpeech.id)
                        Text("Parakeet TDT 0.6B v2").tag(ModelCatalog.englishBaseline.id)
                    }.disabled(model.isRecording || model.isBusy || model.isCaptureTransitioning)
                }
                ForEach(ModelCatalog.models) { descriptor in
                    ModelRow(descriptor: descriptor, installed: model.installedModelIDs.contains(descriptor.id),
                             progress: model.installProgress[descriptor.id], busy: model.isBusy) {
                        Task { await model.installModel(descriptor) }
                    }
                }
            }
            Text("Download size is not peak RAM. Comparison candidates are listed for evaluation and are not silently installed.")
                .font(.caption).foregroundStyle(.secondary).padding()
        }
    }
}

struct ModelRow: View {
    let descriptor: ModelDescriptor
    let installed: Bool
    let progress: Double?
    let busy: Bool
    let install: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(descriptor.displayName).font(.headline)
                    Text(descriptor.role).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if installed || progress != nil || descriptor.installable {
                    ModelInstallControl(displayName: descriptor.displayName, downloadBytes: descriptor.downloadBytes,
                        state: installState, canInstall: !busy, install: install)
                } else { Text("Evaluation only").font(.caption).foregroundStyle(.secondary) }
            }
            Text(descriptor.quantization).font(.caption).foregroundStyle(.secondary)
            HStack {
                Link("Model card", destination: descriptor.modelCardURL)
                Link("Runtime", destination: descriptor.runtimeURL)
                Link("License", destination: descriptor.licenseURL)
            }.font(.caption)
        }.padding(.vertical, 8)
    }

    private var installState: ModelInstallState {
        if installed { .installed } else if let progress { .installing(progress) } else { .notInstalled }
    }
}

/// What a local model install control shows. Local Models and first-run setup share it.
enum ModelInstallState: Equatable {
    /// Installed models are still being read at startup.
    case checking
    case notInstalled
    /// A nil fraction means the download started but has not reported progress yet.
    case installing(Double?)
    case installed
    /// The last install attempt ended without an installed model; the message explains why.
    case failed(String)
}

/// The trailing install control for one local model. Installing reuses `WorkspaceModel.installModel`.
struct ModelInstallControl: View {
    let displayName: String
    let downloadBytes: Int64
    let state: ModelInstallState
    let canInstall: Bool
    let install: () -> Void

    var body: some View {
        switch state {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Checking whether \(displayName) is installed"))
        case .installed:
            Label { Text("Installed") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        case .installing(let progress):
            ProgressView(value: progress).frame(width: 120)
                .accessibilityLabel(Text("Downloading \(displayName)"))
        case .notInstalled:
            Button("Install \(downloadBytes.formatted(.byteCount(style: .file)))", action: install)
                .disabled(!canInstall)
                .accessibilityLabel(Text("Install \(displayName), \(downloadBytes.formatted(.byteCount(style: .file)))"))
        case .failed:
            Button("Retry", action: install)
                .disabled(!canInstall)
                .accessibilityLabel(Text("Retry installing \(displayName)"))
        }
    }
}

struct DictionaryView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var canonical = ""
    @State private var aliases = ""
    @State private var explanation = ""
    @State private var projectOnly = true
    @State private var automatic = false
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("Terminology dictionary").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }.padding()
            Form {
                TextField("Correct spelling", text: $canonical)
                TextField("Misheard aliases, separated by commas", text: $aliases)
                TextField("Meaning or context", text: $explanation)
                Toggle("Only for this project", isOn: $projectOnly).disabled(model.selectedSession?.projectPath == nil)
                Toggle("Apply these exact aliases automatically to new transcripts", isOn: $automatic)
                Button("Add dictionary entry") {
                    let entry = DictionaryEntry(canonical: canonical.trimmingCharacters(in: .whitespacesAndNewlines),
                        aliases: aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                        explanation: explanation, projectPath: projectOnly ? model.selectedSession?.projectPath : nil, automatic: automatic)
                    Task { await model.addDictionaryEntry(entry); canonical = ""; aliases = ""; explanation = ""; automatic = false }
                }.disabled(canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || aliases.isEmpty)
            }.padding(.horizontal)
            Text("Entries suggest corrections unless you explicitly approve automatic aliases. Every accepted or automatic edit creates an undoable revision.")
                .font(.caption).foregroundStyle(.secondary).padding()
            List(model.dictionary) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.canonical).font(.headline)
                    Text(entry.aliases.joined(separator: ", ")).foregroundStyle(.secondary)
                    Text(entry.projectPath == nil ? "Global" : "Project").font(.caption)
                    Toggle("Approved automatic aliases", isOn: Binding(
                        get: { entry.automatic },
                        set: { enabled in Task { await model.setDictionaryAutomatic(id: entry.id, enabled: enabled) } }
                    )).toggleStyle(.checkbox).font(.caption)
                }
            }
        }
    }
}

struct ActivityFooter: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        HStack(spacing: 8) {
            if model.isBusy { ProgressView().controlSize(.small) }
            Text(model.activity).lineLimit(2)
            Spacer()
            Label("On this Mac", systemImage: "lock.shield")
                .help("Recordings, transcripts, and briefs are processed locally.")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 6).background(.bar)
    }
}

struct TextImportSheet: View {
    let save: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import transcript text").font(.title2.bold())
            Text("Imported text is labeled separately from microphone transcription.").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 240)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Import") { let value = text; Task { await save(value); dismiss() } }
                    .buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("confirmImport")
            }
        }.padding(24).frame(width: 620)
    }
}

struct TranscriptEditor: View {
    let revision: TranscriptRevision
    let save: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct transcript").font(.title2.bold())
            Text("The original and all earlier revisions remain available.").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 240)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save correction") { let value = text; Task { await save(value); dismiss() } }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 620).onAppear { text = revision.text }
    }
}

struct DraftEditor: View {
    @Binding var text: String
    let save: () async -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit a new draft version").font(.title2.bold())
            TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 300)
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button("Save new version") { Task { await save(); dismiss() } }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 650)
    }
}

@MainActor private func chooseRepository(model: WorkspaceModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
    panel.message = "Choose the repository whose context you want to use."
    if panel.runModal() == .OK, let url = panel.url {
        Task { await model.updateSession(title: nil, task: nil, project: url.path) }
    }
}

@MainActor private func chooseContextFile(model: WorkspaceModel) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
        Task {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 256 * 1024 else { throw KeystormError.message("Select a text file smaller than 256 KB.") }
                let value = try String(contentsOf: url, encoding: .utf8)
                await model.addContext(title: url.lastPathComponent, content: value, filePath: url.path)
            } catch { model.error = error.localizedDescription }
        }
    }
}

@MainActor private func exportPrompt(model: WorkspaceModel) {
    guard let session = model.selectedSession, let draft = model.currentDraft else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "Prompt-\(session.drafts.count).md"
    if panel.runModal() == .OK, let url = panel.url {
        Task {
            do { try await Task.detached(priority: .userInitiated) { try SessionTransfer.exportPrompt(draft: draft, session: session, to: url, includeProvenance: true) }.value }
            catch { model.error = error.localizedDescription }
        }
    }
}

@MainActor private func exportArchive(model: WorkspaceModel) {
    guard let session = model.selectedSession, let store = model.store else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Session-\(session.id.uuidString.prefix(8)).keystorm"
    if panel.runModal() == .OK, let url = panel.url {
        Task {
            do {
                let audio = try await store.audioDirectory(session.id)
                try await Task.detached(priority: .userInitiated) { try SessionTransfer.exportArchive(session: session, audioDirectory: audio, to: url) }.value
            } catch { model.error = error.localizedDescription }
        }
    }
}

@MainActor private func importArchive(model: WorkspaceModel) {
    guard let store = model.store else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false
    if panel.runModal() == .OK, let url = panel.url {
        Task {
            do {
                let session = try await Task.detached(priority: .userInitiated) { try await SessionTransfer.importArchive(from: url, store: store) }.value
                try await model.registerImportedSession(session)
            } catch { model.error = error.localizedDescription }
        }
    }
}
