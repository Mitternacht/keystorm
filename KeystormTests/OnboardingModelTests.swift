import Foundation
import Testing
@testable import Keystorm

/// Installed-model status for setup. Installing never downloads: queued failures are returned,
/// otherwise the model is marked installed.
@MainActor
private final class FakeOnboardingModels: OnboardingModelInstalling {
    var checked = true
    var canInstall = true
    var installed: Set<String> = []
    var progress: [String: Double] = [:]
    var failures: [String] = []
    var failsWithoutMessage = false
    private(set) var installCalls: [String] = []
    var duringInstall: (@MainActor (ModelDescriptor) async -> Void)?

    var onboardingModelsChecked: Bool { checked }
    var onboardingCanInstall: Bool { canInstall }
    func onboardingIsInstalled(_ id: String) -> Bool { installed.contains(id) }
    func onboardingInstallProgress(_ id: String) -> Double? { progress[id] }

    func onboardingInstall(_ descriptor: ModelDescriptor) async -> String? {
        installCalls.append(descriptor.id)
        await duringInstall?(descriptor)
        if failsWithoutMessage { return nil }
        if !failures.isEmpty { return failures.removeFirst() }
        installed.insert(descriptor.id)
        return nil
    }
}

/// Stands in for TCC. A granted request changes the status the next refresh reads.
@MainActor
private final class FakeOnboardingPermissions: OnboardingPermissionProviding {
    var microphone: OnboardingMicrophoneStatus = .notDetermined
    var grantsMicrophone = true
    var trusted = false
    private(set) var microphoneRequests = 0
    private(set) var accessibilityPrompts = 0
    private(set) var openedPanes: [OnboardingSettingsPane] = []

    func microphoneStatus() -> OnboardingMicrophoneStatus { microphone }

    func requestMicrophoneAccess() async -> Bool {
        microphoneRequests += 1
        microphone = grantsMicrophone ? .authorized : .denied
        return grantsMicrophone
    }

    func isAccessibilityTrusted() -> Bool { trusted }
    func promptForAccessibilityAccess() { accessibilityPrompts += 1 }
    func openSettings(_ pane: OnboardingSettingsPane) { openedPanes.append(pane) }
}

/// Starts from the shipped default bindings, all registered.
@MainActor
private final class FakeOnboardingSettings: OnboardingSettingsProviding {
    var bindings: [ShortcutAction: String] = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.compactMap { action in
        ShortcutPreferences.defaults.shortcuts[action.rawValue].map { (action, $0.displayName) }
    })
    var registrations: [ShortcutAction: ShortcutRegistration] = Dictionary(uniqueKeysWithValues:
        ShortcutAction.allCases.map { ($0, ShortcutRegistration.registered) })
    var pastes = true

    func onboardingShortcut(for action: ShortcutAction) -> String? { bindings[action] }
    func onboardingShortcutRegistration(for action: ShortcutAction) -> ShortcutRegistration? { registrations[action] }
    var onboardingPastesIntoOtherApps: Bool { pastes }
}

@MainActor
private final class Recorder<Value> {
    var values: [Value] = []
}

enum OnboardingExit: String, CaseIterable, Sendable {
    case finish, skip, closeWindow
}

@MainActor
struct OnboardingModelTests {
    private let models = FakeOnboardingModels()
    private let permissions = FakeOnboardingPermissions()
    private let settings = FakeOnboardingSettings()
    private let speechID = ModelCatalog.primarySpeech.id
    private let textID = ModelCatalog.primaryText.id

    private func makeModel(defaults: UserDefaults? = nil, automaticPresentationAllowed: Bool = true) -> OnboardingModel {
        OnboardingModel(models: models, permissions: permissions, settings: settings, defaults: defaults,
                        automaticPresentationAllowed: automaticPresentationAllowed)
    }

    // MARK: First run

    @Test("A fresh install presents setup automatically, once per launch")
    func firstLaunchPresentsOnce() throws {
        let suiteName = "Keystorm.OnboardingModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel(defaults: defaults)
        #expect(model.isFirstRun)
        #expect(model.shouldPresentAutomatically)
        #expect(model.claimAutomaticPresentation())
        #expect(!model.claimAutomaticPresentation())
        // Presenting alone records nothing; quitting before a choice shows setup again next launch.
        #expect(defaults.object(forKey: OnboardingModel.completionKey) == nil)
        #expect(makeModel(defaults: defaults).claimAutomaticPresentation())
    }

    @Test("Finishing, skipping or closing setup stops automatic presentation at later launches",
          arguments: OnboardingExit.allCases)
    func exitPersists(_ exit: OnboardingExit) throws {
        let suiteName = "Keystorm.OnboardingModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel(defaults: defaults)
        #expect(model.claimAutomaticPresentation())
        switch exit {
        case .finish: model.finish()
        case .skip: model.skip()
        case .closeWindow: model.windowDidClose()
        }
        #expect(!model.isFirstRun)
        #expect(defaults.string(forKey: OnboardingModel.completionKey) == (exit == .finish ? "finished" : "skipped"))
        let relaunched = makeModel(defaults: defaults)
        #expect(!relaunched.isFirstRun)
        #expect(!relaunched.shouldPresentAutomatically)
        #expect(!relaunched.claimAutomaticPresentation())
    }

    @Test("Closing or skipping after finishing keeps the finished record")
    func finishedIsNotDowngraded() throws {
        let suiteName = "Keystorm.OnboardingModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel(defaults: defaults)
        model.finish()
        model.windowDidClose()
        model.skip()
        #expect(defaults.string(forKey: OnboardingModel.completionKey) == "finished")
    }

    @Test("Test hosts and isolated UI runs never open setup by themselves")
    func automaticPresentationCanBeDisabled() throws {
        let suiteName = "Keystorm.OnboardingModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel(defaults: defaults, automaticPresentationAllowed: false)
        #expect(model.isFirstRun)
        #expect(!model.shouldPresentAutomatically)
        #expect(!model.claimAutomaticPresentation())
        #expect(defaults.object(forKey: OnboardingModel.completionKey) == nil)
    }

    @Test("An unrecognized stored value counts as not yet completed")
    func unknownStoredValue() throws {
        let suiteName = "Keystorm.OnboardingModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("futureState", forKey: OnboardingModel.completionKey)
        let model = makeModel(defaults: defaults)
        #expect(model.isFirstRun)
        #expect(model.claimAutomaticPresentation())
        // Reading never rewrites the stored value; only a new choice replaces it.
        #expect(defaults.string(forKey: OnboardingModel.completionKey) == "futureState")
        model.skip()
        #expect(defaults.string(forKey: OnboardingModel.completionKey) == "skipped")
    }

    // MARK: Models

    @Test("Model rows follow the workspace: checking, missing, downloading and installed")
    func modelStates() {
        let model = makeModel()
        models.checked = false
        #expect(model.state(of: .speech) == .checking)
        #expect(model.status(of: .models) == .checking)
        models.installed = [speechID]
        #expect(model.state(of: .speech) == .installed)
        #expect(model.state(of: .text) == .checking)

        models.checked = true
        models.installed = []
        #expect(model.state(of: .speech) == .notInstalled)
        #expect(model.status(of: .models) == .actionNeeded)
        models.progress[speechID] = 0.25
        #expect(model.state(of: .speech) == .installing(0.25))
        #expect(model.status(of: .models) == .inProgress)
        models.progress = [:]
        models.installed = [speechID]
        #expect(model.state(of: .text) == .notInstalled)
        #expect(model.status(of: .models) == .optional)
        models.installed = [speechID, textID]
        #expect(model.status(of: .models) == .complete)
    }

    @Test("A failed install shows its reason, and Retry installs through the same path")
    func failedInstallCanBeRetried() async {
        let model = makeModel()
        models.failures = ["The network connection was lost."]
        await model.install(.speech)
        #expect(model.state(of: .speech) == .failed("The network connection was lost."))
        #expect(model.status(of: .models) == .actionNeeded)
        #expect(models.installCalls == [speechID])

        await model.install(.speech)
        #expect(model.state(of: .speech) == .installed)
        #expect(model.installFailures[.speech] == nil)
        #expect(models.installCalls == [speechID, speechID])
    }

    @Test("An install that ends without a model and without a reason still shows a failure")
    func failureWithoutReason() async throws {
        let model = makeModel()
        models.failsWithoutMessage = true
        await model.install(.text)
        let message: String? = if case .failed(let reason) = model.state(of: .text) { reason } else { nil }
        #expect(try #require(message).contains(ModelCatalog.primaryText.displayName))
    }

    @Test("Install is not attempted before models are checked, while busy, or when already installed")
    func installRefusedWhenUnavailable() async {
        let model = makeModel()
        models.checked = false
        await model.install(.speech)
        models.checked = true
        models.canInstall = false
        await model.install(.speech)
        models.canInstall = true
        models.installed = [textID]
        await model.install(.text)
        #expect(models.installCalls.isEmpty)
        #expect(model.state(of: .speech) == .notInstalled)
    }

    @Test("A running install shows progress and ignores a second press")
    func installInProgress() async {
        let model = makeModel()
        let observed = Recorder<ModelInstallState>()
        let statuses = Recorder<OnboardingStepStatus>()
        models.duringInstall = { @MainActor [weak model] _ in
            guard let model else { return }
            observed.values.append(model.state(of: .speech))
            statuses.values.append(model.status(of: .models))
            await model.install(.speech)
        }
        await model.install(.speech)
        #expect(observed.values == [.installing(nil)])
        #expect(statuses.values == [.inProgress])
        #expect(models.installCalls == [speechID])
        #expect(model.state(of: .speech) == .installed)
    }

    @Test("Before the real workspace reads its models, setup shows Checking and installs nothing")
    func workspaceConformanceBeforeStartup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-Onboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(root: directory)
        let model = OnboardingModel(models: workspace, permissions: permissions, settings: settings)
        #expect(!workspace.onboardingModelsChecked)
        #expect(!workspace.onboardingCanInstall)
        #expect(model.state(of: .speech) == .checking)
        await model.install(.speech)
        #expect(model.state(of: .speech) == .checking)
        #expect(workspace.installProgress.isEmpty)

        // An empty isolated root has no models. Install is offered but deliberately not pressed.
        await workspace.initialize()
        #expect(workspace.onboardingModelsChecked)
        #expect(workspace.onboardingCanInstall)
        #expect(model.state(of: .speech) == .notInstalled)
        #expect(model.state(of: .text) == .notInstalled)
        await workspace.stopForTermination()
    }

    // MARK: Permissions

    @Test("Refreshing reads changes made in System Settings and never asks for access")
    func refreshReadsOnly() {
        let model = makeModel()
        permissions.microphone = .denied
        model.refreshPermissions()
        #expect(model.microphone == .denied)
        #expect(!model.accessibilityTrusted)
        #expect(model.status(of: .microphone) == .actionNeeded)
        #expect(model.status(of: .accessibility) == .optional)

        // The person grants both in System Settings; Keystorm becomes active again.
        permissions.microphone = .authorized
        permissions.trusted = true
        model.refreshPermissions()
        #expect(model.microphone == .authorized)
        #expect(model.accessibilityTrusted)
        #expect(model.status(of: .microphone) == .complete)
        #expect(model.status(of: .accessibility) == .complete)
        #expect(permissions.microphoneRequests == 0)
        #expect(permissions.accessibilityPrompts == 0)
    }

    @Test("Opening setup reads permissions without requesting them")
    func beginDoesNotRequest() {
        let model = makeModel()
        model.begin()
        #expect(permissions.microphoneRequests == 0)
        #expect(permissions.accessibilityPrompts == 0)
        #expect(permissions.openedPanes.isEmpty)
    }

    @Test("The microphone request runs once, only while access is undecided")
    func microphoneRequestOnlyWhenUndecided() async {
        let model = makeModel()
        await model.requestMicrophoneAccess()
        #expect(permissions.microphoneRequests == 1)
        #expect(model.microphone == .authorized)
        #expect(!model.isRequestingMicrophone)
        await model.requestMicrophoneAccess()
        #expect(permissions.microphoneRequests == 1)
    }

    @Test("A decided or restricted microphone is never requested again",
          arguments: [OnboardingMicrophoneStatus.denied, .restricted, .authorized])
    func decidedMicrophoneIsNotRequested(_ status: OnboardingMicrophoneStatus) async {
        let model = makeModel()
        permissions.microphone = status
        await model.requestMicrophoneAccess()
        #expect(permissions.microphoneRequests == 0)
        #expect(model.microphone == status)
    }

    @Test("The Accessibility request is shown only while Keystorm is not trusted")
    func accessibilityPromptOnlyWhenUntrusted() {
        let model = makeModel()
        model.requestAccessibilityAccess()
        #expect(permissions.accessibilityPrompts == 1)
        permissions.trusted = true
        model.requestAccessibilityAccess()
        #expect(permissions.accessibilityPrompts == 1)
        #expect(model.accessibilityTrusted)
    }

    @Test("Settings buttons open the Microphone and Accessibility privacy panes")
    func settingsPanes() {
        let model = makeModel()
        model.openSettings(.microphone)
        model.openSettings(.accessibility)
        #expect(permissions.openedPanes == [.microphone, .accessibility])
        #expect(OnboardingSettingsPane.microphone.url?.absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(OnboardingSettingsPane.accessibility.url?.absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @Test("Without Accessibility trust dictation is Copy-only; with it, paste follows the setting",
          arguments: [(false, true), (false, false), (true, false), (true, true)])
    func deliveryMode(trusted: Bool, pastes: Bool) {
        let model = makeModel()
        permissions.trusted = trusted
        settings.pastes = pastes
        model.refreshPermissions()
        let expected: OnboardingDeliveryMode = !trusted ? .copyOnly : (pastes ? .textEditAndPaste : .textEditOnly)
        #expect(model.deliveryMode == expected)
        #expect(model.pastesIntoOtherApps == pastes)
    }

    // MARK: Shortcuts

    @Test("Shortcut rows show the current bindings, not the shipped defaults")
    func shortcutRowsReadCurrentBindings() {
        let model = makeModel()
        settings.bindings[.toggleDictation] = "⌃⌥Space"
        settings.bindings[.pauseResumeDictation] = nil
        settings.registrations[.showWorkspace] = .unavailable("Another app uses this shortcut.")
        let rows = model.shortcutRows
        #expect(rows.map(\.action) == [.toggleDictation, .pauseResumeDictation, .showWorkspace])
        #expect(rows[0].binding == "⌃⌥Space")
        #expect(rows[0].problem == nil)
        #expect(rows[1].binding == nil)
        #expect(rows[2].problem == "Another app uses this shortcut.")
        #expect(model.dictationShortcut == "⌃⌥Space")
        #expect(model.status(of: .shortcuts) == .complete)
    }

    @Test("Every other assigned global shortcut is listed, so none is active unexplained")
    func otherAssignedShortcutsAreListed() throws {
        let model = makeModel()
        // The shipped defaults also bind developer-brief recording, which starts the microphone.
        #expect(model.otherShortcutRows.map(\.action) == [.toggleRecording, .recordEdit])
        #expect(model.otherShortcutRows.allSatisfy { !OnboardingModel.explainedShortcuts.contains($0.action) })

        settings.bindings[.recordEdit] = nil
        settings.bindings[.readSection] = "⌃⌥R"
        settings.registrations[.readSection] = .unavailable("Already in use.")
        let rows = model.otherShortcutRows
        #expect(rows.map(\.action) == [.toggleRecording, .readSection])
        let readSection = try #require(rows.first { $0.action == .readSection })
        #expect(readSection.binding == "⌃⌥R")
        #expect(readSection.problem == "Already in use.")
    }

    @Test("A missing or refused dictation shortcut is reported, but does not block dictation")
    func missingDictationShortcut() {
        let model = makeModel()
        models.installed = [speechID]
        permissions.microphone = .authorized
        model.refreshPermissions()
        settings.registrations[.toggleDictation] = .unavailable("Already in use.")
        #expect(model.status(of: .shortcuts) == .optional)
        settings.registrations[.toggleDictation] = .registered
        settings.bindings[.toggleDictation] = nil
        #expect(model.status(of: .shortcuts) == .optional)
        #expect(model.dictationShortcut == nil)
        #expect(model.missingRequirements.contains(.dictationShortcut))
        #expect(model.isReadyToDictate)
    }

    // MARK: What is missing and steps

    @Test("A fresh install lists what is missing, required items first")
    func missingRequirements() {
        let model = makeModel()
        model.refreshPermissions()
        #expect(model.missingRequirements == [.speechModel, .microphone, .textModel, .accessibility])
        #expect(!model.isReadyToDictate)

        models.installed = [speechID]
        permissions.microphone = .authorized
        model.refreshPermissions()
        #expect(model.missingRequirements == [.textModel, .accessibility])
        #expect(model.missingRequirements.allSatisfy { !$0.isRequired })
        #expect(model.isReadyToDictate)

        models.installed = [speechID, textID]
        permissions.trusted = true
        model.refreshPermissions()
        #expect(model.missingRequirements.isEmpty)
        #expect(OnboardingRequirement.allCases.map(\.step) == [.models, .microphone, .models, .accessibility, .shortcuts])
    }

    @Test("Opening setup starts at the first step that blocks dictation or is still being checked")
    func beginSelectsFirstBlockingStep() {
        let model = makeModel()
        model.begin()
        #expect(model.step == .models)

        models.checked = false
        models.installed = [speechID]
        model.step = .shortcuts
        model.begin()
        #expect(model.step == .models)

        models.checked = true
        models.installed = [speechID, textID]
        model.begin()
        #expect(model.step == .microphone)

        permissions.microphone = .authorized
        model.step = .shortcuts
        model.begin()
        #expect(model.step == .models)
    }

    @Test("Back and Continue stay within the steps")
    func stepNavigation() {
        let model = makeModel()
        #expect(model.step == .models)
        #expect(!model.canGoBack)
        model.goBack()
        #expect(model.step == .models)
        for _ in OnboardingStep.allCases { model.goForward() }
        #expect(model.step == .shortcuts)
        #expect(model.isLastStep)
        model.goForward()
        #expect(model.step == .shortcuts)
        model.goBack()
        #expect(model.step == .accessibility)
        #expect(model.canGoBack)
        #expect(!model.isLastStep)
    }
}
