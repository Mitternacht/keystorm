import Foundation
import Observation

/// The steps of first-run setup, in order.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case models, microphone, accessibility, shortcuts

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .models: "Local models"
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .shortcuts: "Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .models: "cpu"
        case .microphone: "mic"
        case .accessibility: "accessibility"
        case .shortcuts: "command"
        }
    }
}

/// How a step looks in the step list. Copy-only dictation works without the optional items.
enum OnboardingStepStatus: Equatable {
    case checking, inProgress, actionNeeded, optional, complete

    var title: LocalizedStringResource {
        switch self {
        case .checking: "Checking"
        case .inProgress: "Installing"
        case .actionNeeded: "Needs action"
        case .optional: "Optional"
        case .complete: "Done"
        }
    }
}

/// The two production models setup offers. Evaluation candidates are never offered here.
enum OnboardingModelKind: CaseIterable, Identifiable {
    case speech, text

    var id: Self { self }

    var descriptor: ModelDescriptor {
        switch self {
        case .speech: ModelCatalog.primarySpeech
        case .text: ModelCatalog.primaryText
        }
    }

    /// Dictation cannot start without the speech model; the text model only powers rewrites.
    var isRequired: Bool { self == .speech }

    var title: LocalizedStringResource {
        switch self {
        case .speech: "Speech model"
        case .text: "Text model"
        }
    }

    var purpose: LocalizedStringResource {
        switch self {
        case .speech: "Transcribes your dictation on this Mac. Needed to dictate."
        case .text: "Powers Clean and Email modes and Translate previews on this Mac. Verbatim dictation works without it."
        }
    }
}

enum OnboardingMicrophoneStatus: Equatable {
    case notDetermined, authorized, denied, restricted
}

/// Privacy & Security panes setup can open. Opening a pane never changes a permission.
enum OnboardingSettingsPane: Equatable {
    case microphone, accessibility

    var url: URL? {
        switch self {
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

/// What happens to finished dictation with the current Accessibility trust and paste setting.
enum OnboardingDeliveryMode: Equatable {
    /// No Accessibility trust: the result stays in Keystorm to copy.
    case copyOnly
    /// Verified TextEdit insertion; other apps keep the result in Keystorm to copy.
    case textEditOnly
    /// Verified TextEdit insertion, plus an unverifiable paste into other apps' text fields.
    case textEditAndPaste
}

/// Something setup can still help with. Only the speech model and microphone block dictation.
enum OnboardingRequirement: CaseIterable, Identifiable {
    case speechModel, microphone, textModel, accessibility, dictationShortcut

    var id: Self { self }

    var isRequired: Bool { self == .speechModel || self == .microphone }

    var step: OnboardingStep {
        switch self {
        case .speechModel, .textModel: .models
        case .microphone: .microphone
        case .accessibility: .accessibility
        case .dictationShortcut: .shortcuts
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .speechModel: "Install the speech model"
        case .microphone: "Allow microphone access"
        case .textModel: "Install the text model for Clean, Email and Translate"
        case .accessibility: "Turn on Accessibility to insert or paste results; until then, results are Copy-only"
        case .dictationShortcut: "Assign a dictation shortcut, or start dictation from the menu bar icon"
        }
    }
}

enum OnboardingCompletion: String {
    case finished, skipped
}

struct OnboardingShortcutRow: Identifiable, Equatable {
    let action: ShortcutAction
    /// The current binding as shown in Settings, or nil when none is assigned.
    let binding: String?
    /// Why macOS did not register the binding, when it refused it.
    let problem: String?
    var id: ShortcutAction { action }
}

/// Installed-model status and installation. `WorkspaceModel` conforms in OnboardingProviders.swift.
@MainActor
protocol OnboardingModelInstalling: AnyObject {
    /// False until the workspace has read which models are installed.
    var onboardingModelsChecked: Bool { get }
    /// False while recording, busy, or before startup finished; installing then would be refused.
    var onboardingCanInstall: Bool { get }
    func onboardingIsInstalled(_ id: String) -> Bool
    func onboardingInstallProgress(_ id: String) -> Double?
    /// Installs and returns nil on success, or the reason the model is still not installed.
    func onboardingInstall(_ descriptor: ModelDescriptor) async -> String?
}

/// Permission status and requests. Only explicit button actions call the request methods.
@MainActor
protocol OnboardingPermissionProviding: AnyObject {
    func microphoneStatus() -> OnboardingMicrophoneStatus
    func requestMicrophoneAccess() async -> Bool
    func isAccessibilityTrusted() -> Bool
    func promptForAccessibilityAccess()
    func openSettings(_ pane: OnboardingSettingsPane)
}

/// The current shortcut bindings and dictation delivery preference, read live.
@MainActor
protocol OnboardingSettingsProviding: AnyObject {
    func onboardingShortcut(for action: ShortcutAction) -> String?
    func onboardingShortcutRegistration(for action: ShortcutAction) -> ShortcutRegistration?
    var onboardingPastesIntoOtherApps: Bool { get }
}

/// First-run setup state. Model, permission and shortcut status come from injected providers,
/// so tests never touch TCC, the microphone, downloads or global shortcut registration.
/// Construction reads only the stored first-run choice; permission status is read by `refreshPermissions()`.
@MainActor
@Observable
final class OnboardingModel {
    static let completionKey = "onboarding.firstRun.v1"
    /// The shortcuts setup explains. Other assigned shortcuts are only listed (`otherShortcutRows`).
    static let explainedShortcuts: [ShortcutAction] = [.toggleDictation, .pauseResumeDictation, .showWorkspace]

    var step: OnboardingStep = .models
    private(set) var microphone: OnboardingMicrophoneStatus = .notDetermined
    private(set) var accessibilityTrusted = false
    private(set) var isRequestingMicrophone = false
    private(set) var installing: Set<OnboardingModelKind> = []
    private(set) var installFailures: [OnboardingModelKind: String] = [:]
    /// Persisted by `record(_:)`. Nil until setup is finished, skipped or closed for the first time.
    private(set) var completion: OnboardingCompletion? = nil

    @ObservationIgnored private let models: any OnboardingModelInstalling
    @ObservationIgnored private let permissions: any OnboardingPermissionProviding
    @ObservationIgnored private let settings: any OnboardingSettingsProviding
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let automaticPresentationAllowed: Bool
    @ObservationIgnored private var automaticPresentationClaimed = false

    init(models: any OnboardingModelInstalling, permissions: any OnboardingPermissionProviding,
         settings: any OnboardingSettingsProviding, defaults: UserDefaults? = nil,
         automaticPresentationAllowed: Bool = true) {
        self.models = models
        self.permissions = permissions
        self.settings = settings
        self.defaults = defaults
        self.automaticPresentationAllowed = automaticPresentationAllowed
        // Unknown stored values are treated as not yet completed, and left stored until a new choice.
        self.completion = defaults?.string(forKey: Self.completionKey).flatMap(OnboardingCompletion.init(rawValue:))
    }

    // MARK: First run

    var isFirstRun: Bool { completion == nil }

    var shouldPresentAutomatically: Bool { automaticPresentationAllowed && completion == nil }

    /// True at most once per launch, and only until setup is finished, skipped or closed.
    func claimAutomaticPresentation() -> Bool {
        guard shouldPresentAutomatically, !automaticPresentationClaimed else { return false }
        automaticPresentationClaimed = true
        return true
    }

    func finish() { record(.finished) }

    func skip() {
        guard completion != .finished else { return }
        record(.skipped)
    }

    /// Closing the window without choosing counts as skipping, so it does not reopen at launch.
    func windowDidClose() {
        if completion == nil { record(.skipped) }
    }

    /// Called whenever the setup window appears: re-reads permissions and opens the first step
    /// that blocks dictation, or is still being checked.
    func begin() {
        refreshPermissions()
        step = OnboardingStep.allCases.first { [.actionNeeded, .checking].contains(status(of: $0)) } ?? .models
    }

    // MARK: Steps

    var canGoBack: Bool { step != OnboardingStep.allCases.first }
    var isLastStep: Bool { step == OnboardingStep.allCases.last }

    func goForward() {
        if let next = OnboardingStep(rawValue: step.rawValue + 1) { step = next }
    }

    func goBack() {
        if let previous = OnboardingStep(rawValue: step.rawValue - 1) { step = previous }
    }

    func status(of step: OnboardingStep) -> OnboardingStepStatus {
        switch step {
        case .models:
            let speech = state(of: .speech), text = state(of: .text)
            if speech == .checking || text == .checking { return .checking }
            if isInstalling(speech) || isInstalling(text) { return .inProgress }
            if speech != .installed { return .actionNeeded }
            return text == .installed ? .complete : .optional
        case .microphone:
            return microphone == .authorized ? .complete : .actionNeeded
        case .accessibility:
            return accessibilityTrusted ? .complete : .optional
        case .shortcuts:
            return isSatisfied(.dictationShortcut) && shortcutProblem(for: .toggleDictation) == nil ? .complete : .optional
        }
    }

    var missingRequirements: [OnboardingRequirement] {
        OnboardingRequirement.allCases.filter { !isSatisfied($0) }
    }

    var isReadyToDictate: Bool { !missingRequirements.contains(where: \.isRequired) }

    // MARK: Models

    var canInstallModels: Bool { models.onboardingCanInstall }

    func state(of kind: OnboardingModelKind) -> ModelInstallState {
        let id = kind.descriptor.id
        if models.onboardingIsInstalled(id) { return .installed }
        if !models.onboardingModelsChecked { return .checking }
        if let progress = models.onboardingInstallProgress(id) { return .installing(progress) }
        if installing.contains(kind) { return .installing(nil) }
        if let failure = installFailures[kind] { return .failed(failure) }
        return .notInstalled
    }

    /// Install and Retry share this path. A failed attempt keeps its reason until the next try.
    func install(_ kind: OnboardingModelKind) async {
        let descriptor = kind.descriptor
        guard !installing.contains(kind), models.onboardingModelsChecked, models.onboardingCanInstall,
              !models.onboardingIsInstalled(descriptor.id) else { return }
        installFailures[kind] = nil
        installing.insert(kind)
        let failure = await models.onboardingInstall(descriptor)
        installing.remove(kind)
        if !models.onboardingIsInstalled(descriptor.id) {
            installFailures[kind] = failure ?? String(localized: "\(descriptor.displayName) was not installed. Try again.")
        }
    }

    // MARK: Permissions

    /// Reads current status only. It never asks macOS for access.
    func refreshPermissions() {
        microphone = permissions.microphoneStatus()
        accessibilityTrusted = permissions.isAccessibilityTrusted()
    }

    /// Shows the standard macOS microphone request, only while access was never decided.
    func requestMicrophoneAccess() async {
        refreshPermissions()
        guard microphone == .notDetermined, !isRequestingMicrophone else { return }
        isRequestingMicrophone = true
        _ = await permissions.requestMicrophoneAccess()
        isRequestingMicrophone = false
        refreshPermissions()
    }

    /// Shows the standard macOS Accessibility request, which lists Keystorm in System Settings.
    func requestAccessibilityAccess() {
        refreshPermissions()
        guard !accessibilityTrusted else { return }
        permissions.promptForAccessibilityAccess()
        refreshPermissions()
    }

    func openSettings(_ pane: OnboardingSettingsPane) {
        permissions.openSettings(pane)
    }

    /// The Settings → Dictation preference, which only takes effect with Accessibility access.
    var pastesIntoOtherApps: Bool { settings.onboardingPastesIntoOtherApps }

    var deliveryMode: OnboardingDeliveryMode {
        guard accessibilityTrusted else { return .copyOnly }
        return pastesIntoOtherApps ? .textEditAndPaste : .textEditOnly
    }

    // MARK: Shortcuts

    var shortcutRows: [OnboardingShortcutRow] {
        Self.explainedShortcuts.map { action in
            OnboardingShortcutRow(action: action, binding: settings.onboardingShortcut(for: action),
                                  problem: shortcutProblem(for: action))
        }
    }

    /// Every other assigned global shortcut, such as developer-brief recording, so that no active
    /// shortcut goes unexplained; some of them also start the microphone.
    var otherShortcutRows: [OnboardingShortcutRow] {
        ShortcutAction.allCases.filter { !Self.explainedShortcuts.contains($0) }.compactMap { action -> OnboardingShortcutRow? in
            guard let binding = settings.onboardingShortcut(for: action) else { return nil }
            return OnboardingShortcutRow(action: action, binding: binding, problem: shortcutProblem(for: action))
        }
    }

    var dictationShortcut: String? { settings.onboardingShortcut(for: .toggleDictation) }

    // MARK: Private

    private func record(_ value: OnboardingCompletion) {
        completion = value
        defaults?.set(value.rawValue, forKey: Self.completionKey)
    }

    private func shortcutProblem(for action: ShortcutAction) -> String? {
        switch settings.onboardingShortcutRegistration(for: action) {
        case .unavailable(let message): message
        case .registered, .disabled, nil: nil
        }
    }

    private func isInstalling(_ state: ModelInstallState) -> Bool {
        if case .installing = state { return true }
        return false
    }

    private func isSatisfied(_ requirement: OnboardingRequirement) -> Bool {
        switch requirement {
        case .speechModel: state(of: .speech) == .installed
        case .microphone: microphone == .authorized
        case .textModel: state(of: .text) == .installed
        case .accessibility: accessibilityTrusted
        case .dictationShortcut: settings.onboardingShortcut(for: .toggleDictation) != nil
        }
    }
}
