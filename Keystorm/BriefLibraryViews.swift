import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BriefRenameTarget: Identifiable {
    let id: UUID
    let title: String
}

struct LibraryNameSheet: View {
    let title: String
    let fieldLabel: String
    let fieldIdentifier: String
    let saveLabel: String
    let save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saving = false
    @State private var failureMessage: String?

    init(title: String, fieldLabel: String, fieldIdentifier: String, saveLabel: String,
         initialName: String, save: @escaping (String) async -> String?) {
        self.title = title; self.fieldLabel = fieldLabel; self.fieldIdentifier = fieldIdentifier
        self.saveLabel = saveLabel; self.save = save
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                Text(fieldLabel).font(.callout.weight(.medium))
                TextField(fieldLabel, text: $name).textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .autocorrectionDisabled(true).accessibilityLabel(fieldLabel)
                    .accessibilityIdentifier(fieldIdentifier).onSubmit(commit)
            }
            if let failureMessage { LibrarySaveError(message: failureMessage) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(saveLabel, action: commit).keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 420).disabled(saving)
    }

    private func commit() {
        guard !saving, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        failureMessage = nil
        saving = true
        Task {
            if let message = await save(name) { failureMessage = message; saving = false }
            else { dismiss() }
        }
    }
}

struct BriefRecordingsSheet: View {
    @Bindable var model: WorkspaceModel
    @Bindable var interactions: AppInteractionController
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            LibrarySheetHeader(title: "Recordings", subtitle: Text(model.selectedSession?.title ?? String(localized: "This brief"))) {
                dismiss()
            }
            Divider()
            if model.recordings.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "waveform", description:
                    Text("Record a take to keep its audio and transcript here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selectedID) {
                        ForEach(model.recordings) { row in
                            RecordingLibraryRow(title: row.take.displayName, createdAt: row.take.createdAt,
                                                duration: row.duration, status: row.take.status.libraryLabel)
                                .tag(row.id).accessibilityIdentifier("recording-\(row.id.uuidString)")
                        }
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                    if let row = model.recordings.first(where: { $0.id == selectedID }) {
                        RecordingDetail(row: row, model: model, interactions: interactions).id(row.id)
                    } else {
                        ContentUnavailableView("Select a recording", systemImage: "waveform", description:
                            Text("Listen to audio, edit its transcript, or restore an earlier version."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }.frame(minWidth: 880, minHeight: 590)
            .onAppear { selectedID = model.recordings.first?.id }
            .onChange(of: model.selectedSessionID) { selectedID = model.recordings.first?.id }
            .onChange(of: model.recordings.count) {
                if !model.recordings.contains(where: { $0.id == selectedID }) { selectedID = model.recordings.first?.id }
            }
            .onDisappear { model.stopPlayback() }
    }
}

private extension BriefTakeStatus {
    var libraryLabel: LocalizedStringResource {
        switch self {
        case .recording: "Recording"
        case .paused: "Paused"
        case .pending: "Pending"
        case .applied: "Applied"
        case .failed: "Failed"
        case .discarded: "Discarded"
        case .dismissed: "Dismissed"
        }
    }
}

private struct RecordingLibraryRow: View {
    let title: String
    let createdAt: Date
    let duration: Double
    let status: LocalizedStringResource
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(status)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 9).accessibilityElement(children: .combine)
    }
}

private struct RecordingDetail: View {
    let row: RecordingRow
    @Bindable var model: WorkspaceModel
    @Bindable var interactions: AppInteractionController
    @State private var renaming = false
    @State private var editingTranscript = false
    @State private var trimming = false

    private var unavailable: Bool { model.isRecording || model.isCaptureTransitioning || model.isBusy }
    private var hasAudio: Bool { !row.segments.isEmpty && row.duration > 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RecordingDetailHeader(title: row.take.displayName, createdAt: row.take.createdAt, duration: row.duration)
                RecordingAudioControls(
                    unavailable: unavailable, hasAudio: hasAudio,
                    activeRevisionID: row.take.activeAudioRevisionID, revisions: row.take.audioRevisions ?? [],
                    play: { interactions.readback.stop(); Task { await model.playTake(id: row.id) } },
                    stop: { model.stopPlayback() }, rename: { renaming = true }, trim: { trimming = true },
                    replaceAudio: replaceAudio, restoreVersion: restoreVersion,
                    trash: { Task { _ = await guardTarget { await model.trashTake(id: row.id) } } }
                )
                Divider()
                RecordingTranscriptSection(text: row.transcriptText, editingUnavailable: unavailable || !hasAudio) {
                    editingTranscript = true
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 480).accessibilityIdentifier("recordingDetail-\(row.id.uuidString)")
            .sheet(isPresented: $renaming) {
                LibraryNameSheet(title: "Rename recording", fieldLabel: "Recording title", fieldIdentifier: "recordingTitle",
                    saveLabel: "Save name", initialName: row.take.name ?? row.take.displayName) { name in
                        await saveTarget { await model.renameTake(id: row.id, title: name) }
                    }
            }
            .sheet(isPresented: $editingTranscript) {
                RecordingTranscriptSheet(text: row.transcriptText) { text in
                    await saveTarget { await model.correctTakeTranscript(id: row.id, text: text) }
                }
            }
            .sheet(isPresented: $trimming) {
                RecordingTrimSheet(duration: row.duration) { start, end in
                    await saveTarget { await model.trimTake(id: row.id, start: start, end: end) }
                }
            }
    }

    private func guardTarget(_ operation: () async -> Void) async -> Bool {
        guard model.selectedSessionID == row.sessionID else {
            model.error = "The selected brief changed. Open this recording again before editing it."
            return false
        }
        await operation()
        return model.error == nil
    }

    private func saveTarget(_ operation: () async -> Void) async -> String? {
        _ = await guardTarget(operation)
        let message = model.error
        if message != nil { model.error = nil }
        return message
    }

    private func restoreVersion(_ id: UUID?) {
        Task { _ = await guardTarget { await model.restoreTakeAudioVersion(id: row.id, revisionID: id) } }
    }

    private func replaceAudio() {
        let sessionID = row.sessionID
        let takeID = row.id
        let panel = NSOpenPanel()
        panel.title = "Replace recording audio"
        panel.message = "Choose an audio file. The original recording remains available in Edit audio."
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard model.selectedSessionID == sessionID else {
                    model.error = "The selected brief changed while choosing audio. Open the recording again."
                    return
                }
                await model.replaceTake(id: takeID, from: url)
            }
        }
    }
}

private struct RecordingDetailHeader: View {
    let title: String
    let createdAt: Date
    let duration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.weight(.semibold)).textSelection(.enabled)
                .accessibilityAddTraits(.isHeader).accessibilityLabel(title)
                .accessibilityIdentifier("recordingTitleHeading").id(title)
            HStack(spacing: 8) {
                Text(createdAt, format: .dateTime.month(.wide).day().hour().minute())
                Text("·").accessibilityHidden(true)
                Text(Duration.seconds(duration), format: .time(pattern: .hourMinuteSecond))
                    .monospacedDigit()
            }.font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct RecordingAudioControls: View {
    let unavailable: Bool
    let hasAudio: Bool
    let activeRevisionID: UUID?
    let revisions: [RecordingAudioRevision]
    let play: () -> Void
    let stop: () -> Void
    let rename: () -> Void
    let trim: () -> Void
    let replaceAudio: () -> Void
    let restoreVersion: (UUID?) -> Void
    let trash: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Button("Play", systemImage: "play.fill", action: play)
                    .buttonStyle(.borderedProminent)
                    .disabled(unavailable || !hasAudio).accessibilityIdentifier("playRecording")
                Button("Stop", systemImage: "stop.fill", action: stop)
                    .accessibilityIdentifier("stopRecordingPlayback")
                Spacer(minLength: 12)
                Button("Rename…", action: rename).disabled(unavailable)
                    .accessibilityIdentifier("renameRecording")
            }
            HStack(spacing: 8) {
                Menu {
                    Button("Trim…", action: trim).disabled(!hasAudio)
                    Button("Replace audio…", action: replaceAudio)
                    Divider()
                    Button { restoreVersion(nil) } label: {
                        Label("Original recording", systemImage: activeRevisionID == nil ? "checkmark" : "waveform")
                    }.accessibilityIdentifier("restoreOriginalRecordingAudio")
                    ForEach(revisions) { revision in
                        Button { restoreVersion(revision.id) } label: {
                            Label("\(revision.label) · \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))",
                                  systemImage: activeRevisionID == revision.id ? "checkmark" : "waveform")
                        }.accessibilityIdentifier("restoreRecordingAudio-\(revision.id.uuidString)")
                    }
                } label: {
                    Label("Edit audio", systemImage: "waveform.path")
                }
                .disabled(unavailable).accessibilityIdentifier("editRecordingAudio")
                Spacer()
                Button("Move to Trash", systemImage: "trash", role: .destructive, action: trash)
                    .labelStyle(.iconOnly).help("Move to Trash")
                    .disabled(unavailable).accessibilityIdentifier("trashRecording")
            }
            Text("The original audio and earlier versions are available in Edit audio.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

private struct RecordingTranscriptSection: View {
    let text: String
    let editingUnavailable: Bool
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Transcript").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(text.isEmpty ? "Add transcript…" : "Edit transcript…", action: edit)
                    .disabled(editingUnavailable).accessibilityIdentifier("editRecordingTranscript")
            }
            RecordingTranscriptPreview(text: text)
                .lineSpacing(4)
        }
    }
}

private struct RecordingTranscriptPreview: View {
    let text: String
    private let limit = 6_000
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if text.isEmpty {
                Text("No transcript yet. Add one yourself, or transcribe this recording from Sources.")
                    .foregroundStyle(.secondary)
            } else {
                let preview = String(text.prefix(limit))
                Text(preview).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if preview.utf8.count < text.utf8.count {
                    Text("Long transcript preview. Open Edit transcript for the complete text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct RecordingTranscriptSheet: View {
    let save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var failureMessage: String?
    init(text: String, save: @escaping (String) async -> String?) {
        _text = State(initialValue: text); self.save = save
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording transcript").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("Edit this recording’s transcript. Original audio and transcript history are kept.")
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body).lineSpacing(4).padding(8)
                .frame(minHeight: 280)
                .background(.background, in: .rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
                .accessibilityLabel("Recording transcript").accessibilityIdentifier("recordingTranscript")
            if let failureMessage { LibrarySaveError(message: failureMessage) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save transcript") {
                    failureMessage = nil
                    saving = true
                    Task {
                        if let message = await save(text) { failureMessage = message; saving = false }
                        else { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("saveRecordingTranscript")
            }
        }.padding(24).frame(minWidth: 680, minHeight: 430).disabled(saving)
    }
}

private struct RecordingTrimSheet: View {
    let duration: Double
    let save: (Double, Double) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var start = 0.0
    @State private var end: Double
    @State private var saving = false
    @State private var failureMessage: String?
    init(duration: Double, save: @escaping (Double, Double) async -> String?) {
        self.duration = duration; self.save = save; _end = State(initialValue: duration)
    }
    private var valid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start && end <= duration }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trim recording").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("Keep a range from the current audio. The original and earlier versions remain available.")
                .foregroundStyle(.secondary)
            LabeledContent("Start (seconds)") {
                TextField("Start", value: $start, format: .number).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Trim start in seconds").accessibilityIdentifier("recordingTrimStart")
            }
            LabeledContent("End (seconds)") {
                TextField("End", value: $end, format: .number).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Trim end in seconds").accessibilityIdentifier("recordingTrimEnd")
            }
            if valid {
                Text("Kept duration: \((end - start).formatted(.number.precision(.fractionLength(0...3)))) seconds")
            } else {
                Text("Choose a start before the end, within \(duration.formatted(.number.precision(.fractionLength(0...3)))) seconds.")
                    .foregroundStyle(.red)
            }
            if let failureMessage { LibrarySaveError(message: failureMessage) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save trim") {
                    guard valid else { return }
                    failureMessage = nil
                    saving = true
                    Task {
                        if let message = await save(start, end) { failureMessage = message; saving = false }
                        else { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(!valid || saving)
                    .accessibilityIdentifier("saveRecordingTrim")
            }
        }.padding(24).frame(width: 480).disabled(saving)
    }
}

struct BriefTrashSheet: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: TrashContent = .briefs
    private enum TrashContent { case briefs, recordings }
    private var unavailable: Bool { model.isRecording || model.isCaptureTransitioning || model.isBusy }
    var body: some View {
        VStack(spacing: 0) {
            LibrarySheetHeader(title: "Trash", subtitle: Text("Restore briefs and recordings, including their audio and history.")) {
                dismiss()
            }
            Picker("Trash contents", selection: $selection) {
                Text("Briefs").tag(TrashContent.briefs)
                Text("Recordings").tag(TrashContent.recordings)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.bottom, 20)
            .accessibilityIdentifier("trashCategory")
            Divider()
            if selection == .briefs {
                if model.trashedSessions.isEmpty {
                    ContentUnavailableView("No briefs in Trash", systemImage: "trash", description:
                        Text("Briefs you move to Trash will appear here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.trashedSessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.title).font(.body.weight(.medium))
                                Text(session.createdAt, format: .dateTime.month(.wide).day().year())
                                    .font(.callout).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                            Spacer()
                            Button("Restore") { Task { await model.restoreSession(id: session.id) } }
                                .buttonStyle(.bordered).controlSize(.small).disabled(unavailable)
                                .accessibilityLabel(Text("Restore \(session.title)"))
                                .accessibilityIdentifier("restoreBrief-\(session.id.uuidString)")
                        }
                        .padding(.vertical, 10).accessibilityElement(children: .contain)
                        .accessibilityIdentifier("trashedBrief-\(session.id.uuidString)")
                    }
                    .listStyle(.inset)
                }
            } else {
                if model.trashedRecordings.isEmpty {
                    ContentUnavailableView("No recordings in Trash", systemImage: "trash", description:
                        Text("Recordings you move to Trash will appear here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.trashedRecordings) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.take.displayName).font(.body.weight(.medium))
                                Text(row.sessionTitle).font(.callout).foregroundStyle(.secondary)
                                if row.parentIsTrashed { Text("Restore the brief first").font(.caption).foregroundStyle(.secondary) }
                            }.accessibilityElement(children: .combine)
                            Spacer()
                            Button("Restore") { Task { await model.restoreTake(sessionID: row.sessionID, takeID: row.id) } }
                                .buttonStyle(.bordered).controlSize(.small).disabled(unavailable || row.parentIsTrashed)
                                .accessibilityLabel(Text("Restore \(row.take.displayName)"))
                                .accessibilityIdentifier("restoreRecording-\(row.id.uuidString)")
                        }
                        .padding(.vertical, 10).accessibilityElement(children: .contain)
                        .accessibilityIdentifier("trashedRecording-\(row.id.uuidString)")
                    }
                    .listStyle(.inset)
                }
            }
        }.frame(minWidth: 680, minHeight: 480)
    }
}


private struct LibrarySheetHeader: View {
    let title: LocalizedStringResource
    let subtitle: Text
    let done: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                subtitle.font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button("Done", action: done).keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered).controlSize(.regular)
        }
        .padding(24)
    }
}

private struct LibrarySaveError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("librarySaveError")
    }
}
