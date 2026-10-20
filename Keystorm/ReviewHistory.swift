import SwiftUI

struct SourceEvidenceView: View {
    let fact: Fact
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Source evidence").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(fact.text).font(.headline).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(fact.sources) { source in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(source.quote).font(.body).textSelection(.enabled)
                            if let session = model.selectedSession,
                               let transcript = session.transcripts.first(where: { $0.id == source.transcriptID }) {
                                HStack {
                                    Text(transcript.origin == .imported ? "Imported text" : "Recorded audio")
                                    Text("Timing: \(transcript.timingPrecision.rawValue)")
                                    Spacer()
                                    if let segment = session.availableSegments.first(where: { transcript.segmentIDs.contains($0.id) }) {
                                        Button("Play source segment") { Task { await model.playback(segment: segment) } }
                                    }
                                }.font(.caption).foregroundStyle(.secondary)
                                Text("UTF-8 bytes \(source.startUTF8)…\(source.endUTF8) · revision \(transcript.id.uuidString)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                DisclosureGroup("Full transcript region") {
                                    Text(transcript.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if transcript.rawText != transcript.text {
                                    DisclosureGroup("Original model output") {
                                        Text(transcript.rawText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            } else {
                                Label("Source revision is unavailable.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                        Divider()
                    }
                }
            }
        }.padding(24).frame(minWidth: 650, idealWidth: 800, minHeight: 450)
    }
}

struct DraftHistoryView: View {
    let drafts: [PromptRevision]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?

    private var selected: PromptRevision? { drafts.first { $0.id == selectedID } ?? drafts.last }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Draft history").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            HSplitView {
                List(drafts.reversed(), selection: $selectedID) { draft in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.createdAt, format: .dateTime.month().day().hour().minute().second())
                        Text("\(draft.detail.rawValue) · \(draft.stale ? "sources changed" : draft.reviewed ? "reviewed" : "unreviewed")")
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(draft.id)
                }.frame(minWidth: 220, idealWidth: 250)
                ScrollView {
                    if let selected {
                        Text(selected.text).font(.body.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                }.frame(minWidth: 430)
            }
        }.frame(minWidth: 760, minHeight: 540)
    }
}
