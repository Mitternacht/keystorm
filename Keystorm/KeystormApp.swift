import SwiftUI
import AppKit

struct KeystormApp: App {
    @State private var workspace: WorkspaceModel
    @State private var interactions: AppInteractionController
    @State private var onboarding: OnboardingModel
    @State private var bootstrap: AppBootstrap

    init() {
        let root = Self.testRoot
        let workspace = WorkspaceModel(root: root)
        let interactions = AppInteractionController()
        let onboarding = OnboardingModel(models: workspace,
            permissions: SystemOnboardingPermissions(), settings: interactions, defaults: .standard,
            automaticPresentationAllowed: Self.allowsAutomaticOnboarding(testRoot: root))
        let bootstrap = AppBootstrap(workspace: workspace, interactions: interactions, onboarding: onboarding,
            presentation: AppPresentation(managesPolicy: !Self.isIsolatedRun))
        _workspace = State(initialValue: workspace)
        _interactions = State(initialValue: interactions)
        _onboarding = State(initialValue: onboarding)
        _bootstrap = State(initialValue: bootstrap)
        AppLifecycle.bootstrap = bootstrap
    }

    /// Isolated UI validation and hosted unit tests keep a regular app with its window open at launch.
    private static var isIsolatedRun: Bool {
        #if DEBUG
        if testRoot != nil { return true }
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("XCTest") }) { return true }
        #endif
        return false
    }

    /// Read once at launch. A menu-bar app opens no window by itself; setup opens when it is needed.
    private static let presentsWorkspaceAtLaunch = AppPresentation.presentsWorkspaceAtLaunch(
        showInDock: AppPresentationPreferences().resolvedShowInDock(), isolatedRun: isIsolatedRun)

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
        Window("Keystorm", id: AppWindowRouter.workspaceID) {
            WorkspaceWindowRoot(bootstrap: bootstrap)
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
        // Title and toolbar share one glass bar over the sidebar and content, the Mac-native shape.
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(Self.presentsWorkspaceAtLaunch ? .presented : .suppressed)
        // In menu-bar mode a window left open at the last quit must not come back by itself at launch.
        .restorationBehavior(Self.presentsWorkspaceAtLaunch ? .automatic : .disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New dictation") { interactions.dictation?.newDraft() }
                    .keyboardShortcut("n")
                    .disabled(interactions.dictation?.hasActiveRecording == true || workspace.isRecording || workspace.isCaptureTransitioning)
            }
            CommandGroup(after: .newItem) {
                Button("Transcribe Audio or Video File…") { interactions.chooseAndTranscribeFile() }
                    .disabled(interactions.dictation?.reservesCapture != false || workspace.isRecording || workspace.isCaptureTransitioning)
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
            KeystormMenuBarMenu(bootstrap: bootstrap)
        } label: {
            MenuBarIcon(bootstrap: bootstrap)
        }
        // A real menu, not a panel: the system menu takes the new glass look by itself, it dismisses on
        // every choice, and it never takes focus from the app that dictation will insert into.
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    /// Set by `KeystormApp.init`, before AppKit calls the delegate.
    static var bootstrap: AppBootstrap?
    var workspace: WorkspaceModel?
    var interactions: AppInteractionController?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let bootstrap = Self.bootstrap else { return }
        // Shutdown must reach the workspace even when no window ever opened.
        workspace = bootstrap.workspace
        interactions = bootstrap.interactions
        bootstrap.presentation.applyCurrentPolicy()
        #if DEBUG
        // Hosted unit tests start nothing by themselves; a window path or test starts the app when it needs it.
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("XCTest") }),
           ProcessInfo.processInfo.environment["KEYSTORM_UI_TEST_ROOT"] == nil { return }
        #endif
        bootstrap.start()
    }

    /// Opening the app again (Finder, Spotlight, the Dock) brings the window back when none is showing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let router = Self.bootstrap?.router else { return true }
        router.showWorkspace()
        return false
    }

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
