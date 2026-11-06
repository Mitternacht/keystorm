import AppKit
import SwiftUI

/// The menu-bar icon. It also hands the window actions to the router and starts the app, because this
/// view exists from launch even when no window is open.
struct MenuBarIcon: View {
    let bootstrap: AppBootstrap
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = bootstrap.menuStatus.state
        Label {
            Text(state.title)
        } icon: {
            Image(systemName: state.symbolName)
        }
        // The glyph itself changes per state; recording breathes and processing sweeps, so the state
        // also reads from motion. Both stay still under Reduce Motion.
        .symbolEffect(.pulse, isActive: state == .recording && !reduceMotion)
        .symbolEffect(.variableColor.iterative, isActive: state == .processing && !reduceMotion)
        .task {
            bootstrap.router.capture(openWindow: openWindow, openSettings: openSettings)
            await bootstrap.ensureStarted()
            bootstrap.presentOnboardingIfNeeded()
        }
    }
}

/// Start, stop and the last result without opening a window, plus the ways into the window and settings.
struct KeystormMenuBarMenu: View {
    let bootstrap: AppBootstrap
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// Each window button hands the router this menu's own actions first, so a window opens even if the
    /// icon's launch task has not run yet.
    private func route(_ action: @MainActor (AppWindowRouter) -> Void) {
        bootstrap.router.capture(openWindow: openWindow, openSettings: openSettings)
        action(bootstrap.router)
    }

    var body: some View {
        @Bindable var presentation = bootstrap.presentation
        let state = bootstrap.menuStatus.state
        // The state header repeats the icon's glyph, so the menu opens on what the icon was showing.
        Label {
            Text(state.title)
        } icon: {
            Image(systemName: state.symbolName)
        }
        if let flow = bootstrap.interactions.dictation {
            Divider()
            DictationMenuItems(flow: flow, interactions: bootstrap.interactions)
        }
        let notices = bootstrap.notices.visible(from: bootstrap.workspace.recoveryMessages)
        if !notices.isEmpty {
            Divider()
            ForEach(Array(notices.prefix(3)), id: \.self) { message in
                Button {
                    bootstrap.notices.dismiss(message)
                } label: {
                    Label {
                        Text("Dismiss notice: \(MenuBarText.preview(of: message, limit: 40) ?? "")")
                    } icon: {
                        Image(systemName: "xmark.circle")
                    }
                }
            }
        }
        Divider()
        Button { route { $0.showWorkspace() } } label: {
            Label("Open Keystorm", systemImage: "macwindow")
        }
        Button { route { $0.showOnboarding() } } label: {
            Label("Set Up Keystorm…", systemImage: "checklist")
        }
        Button { route { $0.showSettings() } } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")
        Toggle("Show in Dock", isOn: $presentation.showInDock)
        Divider()
        Button("Quit Keystorm") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

private struct DictationMenuItems: View {
    let flow: DictationCoordinator
    let interactions: AppInteractionController

    var body: some View {
        let toggleTitle: LocalizedStringKey = flow.hasActiveRecording ? "Finish dictation" : "Start dictation"
        Button {
            interactions.perform(.toggleDictation)
        } label: {
            Label(toggleTitle, systemImage: flow.hasActiveRecording ? "stop.fill" : "mic.fill")
        }
        .disabled(flow.isTransitioning)
        if flow.state == .recording || flow.state == .paused {
            let pauseTitle: LocalizedStringKey = flow.state == .paused ? "Resume dictation" : "Pause dictation"
            Button {
                interactions.perform(.pauseResumeDictation)
            } label: {
                Label(pauseTitle, systemImage: flow.state == .paused ? "play.fill" : "pause.fill")
            }
            .disabled(flow.isTransitioning)
        }
        if flow.hasActiveRecording {
            Button { flow.cancel() } label: {
                Label("Cancel dictation", systemImage: "xmark.circle")
            }
            .disabled(!flow.canCancel)
        }
        if flow.insertionUndo.isAvailable {
            Button {
                Task { _ = await flow.undoLastInsertion() }
            } label: {
                Label("Undo last dictation in \(flow.insertionUndo.destinationName ?? "the app")",
                      systemImage: "arrow.uturn.backward")
            }
            .disabled(flow.isTransitioning || flow.hasActiveRecording)
        }
        if let preview = MenuBarText.preview(of: flow.resultText) {
            Divider()
            Text(verbatim: preview)
            Button { copyLastResult() } label: {
                Label("Copy last result", systemImage: "doc.on.doc")
            }
            .disabled(flow.isTransitioning || flow.hasActiveRecording)
        }
    }

    /// A finished take copies through the coordinator, which saves edits first. Anything older is plain text.
    private func copyLastResult() {
        if flow.state == .ready {
            flow.copyResult()
        } else {
            flow.pasteboard.clearContents()
            flow.pasteboard.setString(flow.resultText, forType: .string)
        }
    }
}

/// The workspace window's content. It waits for the app's startup, so the window never races the
/// start that the menu bar or the launch hook already began.
struct WorkspaceWindowRoot: View {
    let bootstrap: AppBootstrap
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if bootstrap.isReady {
                DictationWorkspaceView(model: bootstrap.workspace, interactions: bootstrap.interactions)
            } else {
                ProgressView("Opening local dictation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minWidth: 920, minHeight: 650)
            }
        }
        // A bar, not a plain inset, so scroll views under the notice keep a matching scroll edge effect.
        .safeAreaBar(edge: .top, spacing: 0) {
            RecoveryBanner(workspace: bootstrap.workspace, notices: bootstrap.notices)
        }
        .task {
            bootstrap.router.capture(openWindow: openWindow, openSettings: openSettings)
            await bootstrap.ensureStarted()
        }
    }
}

/// Startup and maintenance messages, shown once and dismissible. It never blocks the window.
struct RecoveryBanner: View {
    let workspace: WorkspaceModel
    let notices: RecoveryNotices

    var body: some View {
        let visible = notices.visible(from: workspace.recoveryMessages)
        if !visible.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(visible.prefix(3)), id: \.self) { message in
                        Text(verbatim: message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if visible.count > 3 {
                        Text("and \(visible.count - 3) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Dismiss") { notices.dismissAll(visible) }
                    .accessibilityHint("Hides these notices for this launch.")
                    .accessibilityIdentifier("workspace.recoveryBanner.dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            // The notice floats over the workspace, so it is the one place in this shell that carries
            // custom glass. The system glass handles Reduce Transparency and Increase Contrast.
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Notices")
            .accessibilityIdentifier("workspace.recoveryBanner")
        }
    }
}
