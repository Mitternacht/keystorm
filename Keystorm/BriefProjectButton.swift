import AppKit
import SwiftUI

/// A brief keeps its destination even when focus moves to another application.
struct BriefProjectButton: View {
    @Bindable var model: WorkspaceModel

    private var project: URL? {
        model.selectedSession?.projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var body: some View {
        Menu {
            Button(project == nil ? "Choose project folder…" : "Change project folder…") { chooseFolder() }
            if let project {
                Text(project.path).textSelection(.enabled)
                Button("Show in Finder") { NSWorkspace.shared.open(project) }
                Button("Detach folder") {
                    Task { await model.updateSession(project: "") }
                }
            }
        } label: {
            Label(project?.lastPathComponent ?? "Attach project…", systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .menuStyle(.borderlessButton).frame(maxWidth: 300, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .help(project?.path ?? "Choose where the finished Markdown belongs. Folder contents are read only when you explicitly attach files.")
        .accessibilityIdentifier("briefProject")
        .disabled(model.isCaptureTransitioning)
    }

    private func chooseFolder() {
        guard let sessionID = model.selectedSessionID else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Attach project"
        panel.message = "The folder is this brief’s destination. Select files separately to include their contents as context."
        panel.directoryURL = project
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard model.selectedSessionID == sessionID else { return }
                await model.updateSession(project: url.path)
            }
        }
    }
}
