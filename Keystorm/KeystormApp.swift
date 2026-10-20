import SwiftUI
import AppKit

struct KeystormApp: App {
    @State private var workspace: WorkspaceModel
    @State private var interactions: AppInteractionController
    @State private var onboarding: OnboardingModel

    init() {
        let root = Self.testRoot
        let workspace = WorkspaceModel(root: root)
        let interactions = AppInteractionController()
        _workspace = State(initialValue: workspace)
        _interactions = State(initialValue: interactions)
        _onboarding = State(initialValue: OnboardingModel(models: workspace,
            permissions: SystemOnboardingPermissions(), settings: interactions, defaults: .standard,
            automaticPresentationAllowed: Self.allowsAutomaticOnboarding(testRoot: root)))
    }

    /// Isolated UI validation and hosted unit tests must not open the setup window by themselves.
    private static func allowsAutomaticOnboarding(testRoot: URL?) -> Bool {
        #if DEBUG
        if testRoot != nil { return false }
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("XCTest") }) { return false }
        #endif
        return true
    }

    private static var testRoot: URL? {
        #if DEBUG
        do {
            if let configuration = try DebugAudioValidationConfiguration.configuration() {
                return configuration.root
            }
        } catch {
            preconditionFailure("Invalid isolated audio validation manifest: " + error.localizedDescription)
        }
        if let path = ProcessInfo.processInfo.environment["KEYSTORM_UI_TEST_ROOT"] {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let prefix = "Keystorm-UI-"
            // The app and XCUI runner have different process-specific temporary folders.
            // Use a tightly named shared /tmp child, only in DEBUG builds.
            if url.deletingLastPathComponent().resolvingSymlinksInPath() == URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath(),
               url.lastPathComponent.hasPrefix(prefix),
               UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))) != nil {
                return url
            }
            preconditionFailure("Invalid isolated UI test storage path.")
        }
        #endif
        return nil
    }
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    var body: some Scene {
        Window("Keystorm", id: "workspace") {
            DictationWorkspaceView(model: workspace, interactions: interactions)
                .onAppear {
                    lifecycle.workspace = workspace
                    lifecycle.interactions = interactions
                    #if DEBUG
                    if let configuration = try? DebugAudioValidationConfiguration.configuration() {
                        configuration.logPermissions()
                    }
                    // Isolated UI validation can inspect both appearances without changing macOS preferences.
                    if Self.testRoot != nil {
                        switch ProcessInfo.processInfo.environment["KEYSTORM_UI_APPEARANCE"] {
                        case "light": NSApp.appearance = NSAppearance(named: .aqua)
                        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                        default: break
                        }
                    }
                    #endif
                }
                .onboardingFirstRunPresentation(onboarding)
        }
        .defaultSize(width: 1180, height: 780)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New dictation") { interactions.dictation?.newDraft() }
                    .keyboardShortcut("n")
                    .disabled(interactions.dictation?.hasActiveRecording == true || workspace.isRecording || workspace.isCaptureTransitioning)
            }
            CommandGroup(after: .appInfo) { OnboardingMenuCommand() }
        }
        // Opened by the first launch or the app menu; never restored or opened at a later launch.
        Window("Set Up Keystorm", id: OnboardingWindow.id) {
            OnboardingView(model: onboarding)
        }
        .defaultSize(width: 760, height: 580)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        Settings { KeystormSettings(model: workspace, interactions: interactions) }
        MenuBarExtra {
            KeystormQuickMenu(model: workspace, interactions: interactions)
        } label: {
            Label(workspace.isRecording ? "Recording" : "Keystorm", systemImage: workspace.isRecording ? "mic.fill" : "waveform")
        }
    }
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    var workspace: WorkspaceModel?
    var interactions: AppInteractionController?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let workspace else { return .terminateNow }
        terminating = true
        interactions?.stop()
        Task {
            await workspace.stopForTermination()
            await interactions?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
