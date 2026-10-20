import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Every action retains the recording identity captured when the sheet opened.
struct DictationRecordingToolsView: View {
    let model: WorkspaceModel
    let handle: DictationRecordingHandle
    let onAudioChanged: () -> Void
    let onRetranscribe: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var row: RecordingRow?
    @State private var isWorking = false
    @State private var failureMessage: String?
    @State private var status = ""
    @State private var chooseReplacement = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DictationRecordingToolsHeader(title: row?.take.displayName ?? String(localized: "Recording"),
                isWorking: isWorking, close: { dismiss() })
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let row {
                        DictationAudioSummary(duration: row.duration, createdAt: row.take.createdAt,
                            activeRevision: row.take.audioRevisions?.first(where: { $0.id == row.take.activeAudioRevisionID })?.label)
                        DictationAudioPlaybackControls(hasAudio: !row.segments.isEmpty && row.duration > 0,
                            isWorking: isWorking,
                            play: { run { try await model.dictationPlayRecording(handle) } },
                            stop: { model.stopPlayback() })
                        DictationAudioTrimControls(duration: row.duration, isWorking: isWorking) { start, end in
                            run(changesAudio: true) {
                                try await model.dictationTrimRecording(handle, start: start, end: end)
                            }
                        }
                        DictationAudioVersionControls(activeRevisionID: row.take.activeAudioRevisionID,
                            versions: row.take.audioRevisions ?? [], isWorking: isWorking,
                            importReplacement: { chooseReplacement = true },
                            restore: { revisionID in
                                run(changesAudio: true) { try await model.dictationRestoreRecording(handle, revisionID: revisionID) }
                            })
                        Divider()
                        DictationAudioExportControls(isWorking: isWorking, hasAudio: !row.segments.isEmpty,
                            export: exportArchive,
                            retranscribe: {
                                model.stopPlayback()
                                dismiss()
                                onRetranscribe()
                            })
                    } else if failureMessage == nil {
                        ProgressView("Opening saved recording…")
                    }
                    if let failureMessage {
                        Label(failureMessage, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("dictation.audio.error")
                    }
                    if !status.isEmpty {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                            .accessibilityIdentifier("dictation.audio.status")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 600, idealHeight: 700)
        .interactiveDismissDisabled(isWorking)
        .onChange(of: model.sessions, initial: true) { _, _ in refresh() }
        .onChange(of: status) { _, message in
            if !message.isEmpty { AccessibilityNotification.Announcement(message).post() }
        }
        .onChange(of: failureMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .onDisappear { model.stopPlayback() }
        .fileImporter(isPresented: $chooseReplacement, allowedContentTypes: [.audio],
            allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let source = urls.first {
                        run(changesAudio: true) { try await model.dictationReplaceRecording(handle, from: source) }
                    }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { failureMessage = error.localizedDescription }
                }
            }
    }

    private func refresh() {
        do { row = try model.dictationRecordingForTools(handle) }
        catch { row = nil; failureMessage = error.localizedDescription }
    }

    private func run(changesAudio: Bool = false, operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        failureMessage = nil
        status = ""
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await operation()
                refresh()
                if changesAudio {
                    onAudioChanged()
                    status = String(localized: "Audio version saved. Transcribe the selected audio to create a current transcript; earlier outputs remain in Versions.")
                }
            } catch {
                failureMessage = error.localizedDescription
                model.error = nil
            }
        }
    }

    private func exportArchive() {
        guard !isWorking else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Export recording source archive")
        panel.message = String(localized: "The portable archive includes all recordings, original audio, saved versions, and transcripts in this session.")
        panel.nameFieldStringValue = "Dictation-" + String(handle.sessionID.uuidString.prefix(8)) + ".keystorm"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        run {
            try await model.dictationExportRecordingArchive(handle, to: destination)
            status = String(localized: "Source archive exported.")
        }
    }
}

private struct DictationRecordingToolsHeader: View {
    let title: String
    let isWorking: Bool
    let close: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Recording tools").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if isWorking { ProgressView().controlSize(.small).accessibilityLabel("Updating saved audio") }
            Button("Done", action: close).keyboardShortcut(.cancelAction).disabled(isWorking)
        }.padding(24)
    }
}

private struct DictationAudioSummary: View {
    let duration: Double
    let createdAt: Date
    let activeRevision: String?
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            LabeledContent("Duration", value: Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond)))
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(activeRevision ?? String(localized: "Original audio")).font(.callout.weight(.medium))
                Text(createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DictationAudioPlaybackControls: View {
    let hasAudio: Bool
    let isWorking: Bool
    let play: () -> Void
    let stop: () -> Void
    var body: some View {
        HStack {
            Button("Play selected audio", systemImage: "play.fill", action: play)
                .disabled(isWorking || !hasAudio).accessibilityIdentifier("dictation.audio.play")
            Button("Stop", systemImage: "stop.fill", action: stop)
                .accessibilityIdentifier("dictation.audio.stop")
            Spacer()
        }
    }
}

private struct DictationAudioTrimControls: View {
    let duration: Double
    let isWorking: Bool
    let trim: (Double, Double) -> Void
    @State private var start = 0.0
    @State private var end = 0.0
    private var valid: Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start && end <= duration
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trim a copy").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Choose a range in seconds across the selected audio. The original stays saved.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                LabeledContent("Start") {
                    TextField("Start seconds", value: $start, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                        .accessibilityIdentifier("dictation.audio.trim.start")
                }
                LabeledContent("End") {
                    TextField("End seconds", value: $end, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                        .accessibilityIdentifier("dictation.audio.trim.end")
                }
                Spacer()
            }
            Button("Save trimmed version", systemImage: "scissors") { trim(start, end) }
                .disabled(isWorking || !valid).accessibilityIdentifier("dictation.audio.trim")
        }
        .onChange(of: duration, initial: true) { _, value in start = 0; end = value }
        .disabled(isWorking)
    }
}

private struct DictationAudioVersionControls: View {
    let activeRevisionID: UUID?
    let versions: [RecordingAudioRevision]
    let isWorking: Bool
    let importReplacement: () -> Void
    let restore: (UUID?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio versions").font(.headline).accessibilityAddTraits(.isHeader)
            HStack {
                Button("Import replacement…", systemImage: "square.and.arrow.down", action: importReplacement)
                    .accessibilityIdentifier("dictation.audio.replace")
                Menu("Restore version", systemImage: "clock.arrow.circlepath") {
                    Button("Original audio") { restore(nil) }.disabled(activeRevisionID == nil)
                        .accessibilityAddTraits(activeRevisionID == nil ? .isSelected : [])
                        .accessibilityValue(activeRevisionID == nil ? String(localized: "Current version") : "")
                    ForEach(versions) { version in
                        Button {
                            restore(version.id)
                        } label: {
                            if version.id == activeRevisionID {
                                Label(version.label, systemImage: "checkmark")
                            } else {
                                Text(version.label)
                            }
                        }
                        .disabled(version.id == activeRevisionID)
                        .accessibilityAddTraits(version.id == activeRevisionID ? .isSelected : [])
                        .accessibilityValue(version.id == activeRevisionID ? String(localized: "Current version") : "")
                    }
                }
                .accessibilityIdentifier("dictation.audio.versions")
            }
            Text("Trimming, replacing, or restoring audio clears the current transcript and insertion receipt. Earlier text versions and source audio remain saved.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(isWorking)
    }
}

private struct DictationAudioExportControls: View {
    let isWorking: Bool
    let hasAudio: Bool
    let export: () -> Void
    let retranscribe: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Transcribe selected audio", systemImage: "text.bubble", action: retranscribe)
                    .disabled(!hasAudio).accessibilityIdentifier("dictation.audio.retranscribe")
                Spacer()
                Button("Export source archive…", systemImage: "square.and.arrow.up", action: export)
                    .disabled(!hasAudio).accessibilityIdentifier("dictation.audio.export")
            }
            Text("Transcription stays in Keystorm until you explicitly copy it. The archive contains all takes and versions from this session.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(isWorking)
    }
}
