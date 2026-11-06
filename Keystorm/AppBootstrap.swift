import AppKit
import Observation
import SwiftUI

/// Where Keystorm shows itself. Stored in UserDefaults like the other preferences.
struct AppPresentationPreferences {
    static let showInDockKey = "app.showInDock.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The stored choice. With none stored, a new install lives in the menu bar only, and an install that
    /// already finished setup keeps the Dock icon it had. The decision is stored on first read, so
    /// finishing setup later never turns a new install into an old one.
    func resolvedShowInDock() -> Bool {
        if let stored = defaults.object(forKey: Self.showInDockKey) as? Bool { return stored }
        let existingInstall = defaults.string(forKey: OnboardingModel.completionKey) != nil
        defaults.set(existingInstall, forKey: Self.showInDockKey)
        return existingInstall
    }

    func setShowInDock(_ value: Bool) { defaults.set(value, forKey: Self.showInDockKey) }
}

/// The Dock icon, switched at runtime between a regular app and a menu-bar-only (accessory) app.
/// The Info.plist stays a regular app, so the switch happens just after launch.
@MainActor @Observable
final class AppPresentation {
    var showInDock: Bool {
        didSet {
            guard oldValue != showInDock else { return }
            preferences.setShowInDock(showInDock)
            applyPolicy(showInDock ? .regular : .accessory)
            if showInDock { activate() }
        }
    }

    /// Isolated UI runs and hosted unit tests keep a regular app, so their windows behave as before.
    @ObservationIgnored private let managesPolicy: Bool
    @ObservationIgnored private let preferences: AppPresentationPreferences
    @ObservationIgnored private let applyPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    @ObservationIgnored private let activate: @MainActor () -> Void

    init(preferences: AppPresentationPreferences = AppPresentationPreferences(), managesPolicy: Bool = true,
         applyPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = { _ = NSApp?.setActivationPolicy($0) },
         activate: @escaping @MainActor () -> Void = { NSApp?.activate() }) {
        self.preferences = preferences
        self.managesPolicy = managesPolicy
        self.applyPolicy = applyPolicy
        self.activate = activate
        showInDock = preferences.resolvedShowInDock()
    }

    /// Called once at launch, after the app finished starting.
    func applyCurrentPolicy() {
        guard managesPolicy else { return }
        applyPolicy(showInDock ? .regular : .accessory)
    }

    /// The workspace window opens by itself at launch only when the app is a regular Dock app, or when the
    /// run is an isolated UI or unit test. A menu-bar app waits for the person to ask for it.
    static func presentsWorkspaceAtLaunch(showInDock: Bool, isolatedRun: Bool) -> Bool {
        showInDock || isolatedRun
    }
}

/// Opens windows from outside a SwiftUI view. The actions come from the environment, so a view that is
/// always on screen (the menu-bar icon) hands them over once.
@MainActor
final class AppWindowRouter {
    static let workspaceID = "workspace"

    private var openWindow: OpenWindowAction?
    private var openSettings: OpenSettingsAction?

    func capture(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        self.openWindow = openWindow
        self.openSettings = openSettings
    }

    func showWorkspace() {
        openWindow?(id: Self.workspaceID)
        NSApp?.activate()
    }

    func showOnboarding() {
        openWindow?(id: OnboardingWindow.id)
        NSApp?.activate()
    }

    func showSettings() {
        openSettings?()
        NSApp?.activate()
    }
}

/// Starts everything the app needs to work without any window open: the shortcut manager, the
/// dictation coordinator and the workspace's saved state. Before menu-bar mode, the workspace window did this.
@MainActor @Observable
final class AppBootstrap {
    let workspace: WorkspaceModel
    let interactions: AppInteractionController
    let onboarding: OnboardingModel
    let presentation: AppPresentation
    @ObservationIgnored let router = AppWindowRouter()
    let menuStatus = MenuBarStatus()
    let notices = RecoveryNotices()
    /// True once the workspace has read its saved state (or failed to), so the window can show it.
    private(set) var isReady = false
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init(workspace: WorkspaceModel, interactions: AppInteractionController, onboarding: OnboardingModel,
         presentation: AppPresentation) {
        self.workspace = workspace
        self.interactions = interactions
        self.onboarding = onboarding
        self.presentation = presentation
    }

    /// Begins startup without waiting for it.
    func start() {
        Task { await ensureStarted() }
    }

    /// Runs startup once. Every caller, whichever window or launch hook reaches it first, waits for the same run.
    func ensureStarted() async {
        let task: Task<Void, Never>
        if let existing = startTask {
            task = existing
        } else {
            task = Task { await self.run() }
            startTask = task
        }
        await task.value
    }

    func presentOnboardingIfNeeded() {
        if onboarding.claimAutomaticPresentation() { router.showOnboarding() }
    }

    private func run() async {
        interactions.configure(workspace: workspace, showWorkspace: { [router] in router.showWorkspace() })
        observeMenuStatus()
        await workspace.initialize()
        isReady = true
    }

    /// Re-arms after each change, like the HUD observation. The icon follows the coordinator without a timer.
    private func observeMenuStatus() {
        var next = MenuBarState.idle
        withObservationTracking {
            next = MenuBarState.resolve(flow: interactions.dictation?.state, briefRecording: workspace.isRecording)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeMenuStatus() }
        }
        menuStatus.apply(next)
    }
}
