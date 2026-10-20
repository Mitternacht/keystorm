import AppKit
import Combine
import SwiftUI

enum OnboardingWindow {
    static let id = "onboarding"
}

/// First-run setup: local models, permissions and shortcuts. It opens by itself at the first
/// launch only; Keystorm → Set Up Keystorm… reopens it.
struct OnboardingView: View {
    let model: OnboardingModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                OnboardingStepList(model: model)
                    .frame(width: 220)
                Divider()
                ScrollView {
                    OnboardingStepContent(model: model)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            OnboardingFooter(model: model) { dismissWindow(id: OnboardingWindow.id) }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 500, idealHeight: 580)
        .onAppear { model.begin() }
        .onDisappear { model.windowDidClose() }
        // Permissions change in System Settings, so re-read them whenever Keystorm is active again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}

/// Opens setup once at the first launch. Later launches open it only from the menu.
private struct OnboardingFirstRunPresentation: ViewModifier {
    let model: OnboardingModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            guard model.claimAutomaticPresentation() else { return }
            openWindow(id: OnboardingWindow.id)
        }
    }
}

extension View {
    func onboardingFirstRunPresentation(_ model: OnboardingModel) -> some View {
        modifier(OnboardingFirstRunPresentation(model: model))
    }
}

/// The app menu item that reopens setup.
struct OnboardingMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Set Up Keystorm…") {
            openWindow(id: OnboardingWindow.id)
            NSApp.activate()
        }
    }
}

private struct OnboardingStepList: View {
    let model: OnboardingModel

    var body: some View {
        List(selection: Binding<OnboardingStep?>(
            get: { model.step },
            set: { if let step = $0 { model.step = step } }
        )) {
            Section("Steps") {
                ForEach(OnboardingStep.allCases) { step in
                    OnboardingStepRow(step: step, status: model.status(of: step))
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Setup steps")
        .accessibilityIdentifier("onboarding.steps")
    }
}

private struct OnboardingStepRow: View {
    let step: OnboardingStep
    let status: OnboardingStepStatus

    var body: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                    Text(status.title).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: step.systemImage).accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private extension OnboardingStepStatus {
    var symbol: String {
        switch self {
        case .checking: "ellipsis.circle"
        case .inProgress: "arrow.down.circle"
        case .actionNeeded: "exclamationmark.circle.fill"
        case .optional: "circle.dashed"
        case .complete: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .complete: .green
        case .actionNeeded: .orange
        case .inProgress: .accentColor
        case .checking, .optional: .secondary
        }
    }
}

private struct OnboardingStepContent: View {
    let model: OnboardingModel

    var body: some View {
        switch model.step {
        case .models: OnboardingModelsStep(model: model)
        case .microphone: OnboardingMicrophoneStep(model: model)
        case .accessibility: OnboardingAccessibilityStep(model: model)
        case .shortcuts: OnboardingShortcutsStep(model: model)
        }
    }
}

private struct OnboardingFooter: View {
    let model: OnboardingModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if model.isFirstRun {
                Button("Skip Setup") { model.skip(); close() }
                    .help("Close setup. You can reopen it from the Keystorm menu.")
                    .accessibilityHint("Closes setup. You can reopen it from the Keystorm menu.")
                    .accessibilityIdentifier("onboarding.skip")
            }
            Spacer()
            if model.canGoBack {
                Button("Back") { model.goBack() }
                    .accessibilityIdentifier("onboarding.back")
            }
            if model.isLastStep {
                Button("Done") { model.finish(); close() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.done")
            } else {
                Button("Continue") { model.goForward() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.continue")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: Shared pieces

private struct OnboardingStepHeader: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingStatusLine: View {
    let isSatisfied: Bool
    let text: LocalizedStringResource

    var body: some View {
        Label {
            Text(text).font(.headline).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isSatisfied ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isSatisfied ? Color.green : Color.orange)
                .accessibilityHidden(true)
        }
    }
}

private struct OnboardingPoint: View {
    let systemImage: String
    let text: LocalizedStringResource

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// Buttons sit side by side, and stack when larger text no longer fits.
private struct OnboardingButtonRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }
}

// MARK: Steps

private struct OnboardingModelsStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingStepHeader(title: "Local models",
                message: "Installing downloads verified model files. Recording, transcription and text processing stay on this Mac.")
            ForEach(OnboardingModelKind.allCases) { kind in
                OnboardingModelRow(kind: kind, state: model.state(of: kind), canInstall: model.canInstallModels) {
                    // Unstructured, so closing the window does not cancel a running download.
                    Task { await model.install(kind) }
                }
            }
            let waiting = !model.canInstallModels && OnboardingModelKind.allCases.contains { kind in
                switch model.state(of: kind) {
                case .notInstalled, .failed: true
                case .checking, .installing, .installed: false
                }
            }
            if waiting {
                Text("Installing becomes available when Keystorm finishes its current recording or task.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OnboardingModelRow: View {
    let kind: OnboardingModelKind
    let state: ModelInstallState
    let canInstall: Bool
    let install: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                layout {
                    OnboardingModelDescription(kind: kind)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ModelInstallControl(displayName: kind.descriptor.displayName,
                        downloadBytes: kind.descriptor.downloadBytes, state: state,
                        canInstall: canInstall, install: install)
                        .accessibilityIdentifier("onboarding.model." + kind.descriptor.id)
                }
                if case .failed(let message) = state {
                    Label {
                        Text("Couldn’t install: \(message)").fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                    .font(.callout)
                }
            }
            .padding(6)
        }
        .onChange(of: state) { oldState, newState in
            let name = kind.descriptor.displayName
            switch (oldState, newState) {
            case (.installing, .installed):
                AccessibilityNotification.Announcement(String(localized: "\(name) is installed.")).post()
            case (.installing, .failed(let message)):
                AccessibilityNotification.Announcement(String(localized: "\(name) couldn’t be installed. \(message)")).post()
            default:
                break
            }
        }
    }
}

private struct OnboardingModelDescription: View {
    let kind: OnboardingModelKind

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kind.title).font(.headline)
                Text(kind.isRequired ? "Required" : "Optional")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(kind.purpose)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(kind.descriptor.displayName) · \(kind.descriptor.downloadBytes.formatted(.byteCount(style: .file))) download")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingMicrophoneStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingStepHeader(title: "Microphone",
                message: "Keystorm uses the microphone only while you record. Recordings are saved and transcribed on this Mac.")
            OnboardingStatusLine(isSatisfied: model.microphone == .authorized, text: status)
            if let guidance {
                Text(guidance)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OnboardingButtonRow {
                if model.microphone == .notDetermined {
                    Button("Allow Microphone Access…") {
                        Task { await model.requestMicrophoneAccess() }
                    }
                    .disabled(model.isRequestingMicrophone)
                    .accessibilityHint("Shows the macOS microphone request.")
                    .accessibilityIdentifier("onboarding.microphone.request")
                }
                Button("Open Microphone Settings…") { model.openSettings(.microphone) }
                    .accessibilityHint("Opens Privacy & Security, Microphone, in System Settings.")
                    .accessibilityIdentifier("onboarding.microphone.settings")
            }
        }
    }

    private var status: LocalizedStringResource {
        switch model.microphone {
        case .authorized: "Microphone access is on."
        case .notDetermined: "Keystorm hasn’t asked for microphone access yet."
        case .denied: "Microphone access is off."
        case .restricted: "Microphone access is restricted on this Mac."
        }
    }

    private var guidance: LocalizedStringResource? {
        switch model.microphone {
        case .authorized: nil
        case .notDetermined: "macOS asks once. You can change your answer later in System Settings."
        case .denied: "Turn on Keystorm in System Settings → Privacy & Security → Microphone. This page updates when you come back."
        case .restricted: "A device management profile or Screen Time setting may block it. Ask the person who manages this Mac."
        }
    }
}

private struct OnboardingAccessibilityStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingStepHeader(title: "Accessibility",
                message: "With Accessibility access, Keystorm can put finished dictation into the text field where you started. Without it, dictation is Copy-only.")
            OnboardingStatusLine(isSatisfied: model.accessibilityTrusted,
                text: model.accessibilityTrusted ? "Accessibility access is on." : "Accessibility access is off, so dictation is Copy-only.")
            OnboardingButtonRow {
                if !model.accessibilityTrusted {
                    Button("Request Access…") { model.requestAccessibilityAccess() }
                        .accessibilityHint("Shows the macOS Accessibility request, which adds Keystorm to the list in System Settings.")
                        .accessibilityIdentifier("onboarding.accessibility.request")
                }
                Button("Open Accessibility Settings…") { model.openSettings(.accessibility) }
                    .accessibilityHint("Opens Privacy & Security, Accessibility, in System Settings.")
                    .accessibilityIdentifier("onboarding.accessibility.settings")
            }
            if !model.accessibilityTrusted {
                Text("Turn on Keystorm in the Accessibility list. This page updates when you come back.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Finished dictation") { Text(deliveryMode) }
            GroupBox("With Accessibility access") {
                VStack(alignment: .leading, spacing: 10) {
                    OnboardingPoint(systemImage: "doc.text",
                        text: "In TextEdit, Keystorm inserts the finished text into the field you started in and checks that it arrived.")
                    OnboardingPoint(systemImage: "doc.on.clipboard", text: pasteDescription)
                    OnboardingPoint(systemImage: "lock",
                        text: "Known terminal apps, recognized terminals inside editors, and password fields are never pasted into.")
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Copy-only mode") {
                OnboardingPoint(systemImage: "doc.on.doc",
                    text: "Without Accessibility access, Keystorm still records and transcribes. When you finish, the text stays in Keystorm for you to copy and paste yourself. Keystorm also keeps the result to copy whenever a field can’t be checked safely.")
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var deliveryMode: LocalizedStringResource {
        switch model.deliveryMode {
        case .copyOnly: "Copy-only"
        case .textEditOnly: "Inserted in TextEdit; Copy-only elsewhere"
        case .textEditAndPaste: "Inserted in TextEdit; pasted in other apps"
        }
    }

    private var pasteDescription: LocalizedStringResource {
        model.pastesIntoOtherApps
            ? "In other apps, Paste into other apps is on: when Keystorm can check the text field you started in, it pastes there. Those apps can’t confirm what they received, and support varies by app, so check the result."
            : "In other apps, Paste into other apps is off, so the result stays in Keystorm to copy. You can turn it on in Settings → Dictation."
    }
}

private struct OnboardingShortcutsStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingStepHeader(title: "Shortcuts",
                message: "These shortcuts work in any app while Keystorm is running, even when its window is closed.")
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.shortcutRows) { row in
                        OnboardingShortcutLine(row: row)
                    }
                }
                .padding(6)
            }
            let others = model.otherShortcutRows
            if !others.isEmpty {
                GroupBox("Also assigned") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("These work in any app too. Change or clear them in Settings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(others) { row in
                            OnboardingShortcutLine(row: row)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let shortcut = model.dictationShortcut {
                Text("Press \(shortcut) to start dictating, and press it again to finish. To have the text inserted or pasted, start with the cursor in the text field where the words should go.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No dictation shortcut is assigned. Assign one in Settings, or start dictation from the Keystorm menu bar icon.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Verbatim, the default mode, delivers the speech model’s text without rewriting it. Clean and Email tidy it up on this Mac when you finish, and need the text model.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsLink { Text("Change Shortcuts in Settings…") }
                .accessibilityIdentifier("onboarding.shortcuts.settings")
            OnboardingSummary(model: model)
        }
    }
}

private struct OnboardingShortcutLine: View {
    let row: OnboardingShortcutRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                if let binding = row.binding {
                    Text(binding).font(.body.weight(.semibold))
                } else {
                    Text("Not assigned").foregroundStyle(.secondary)
                }
            } label: {
                Text(row.action.title)
            }
            if let problem = row.problem {
                Label {
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                .font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What is still missing, each item linking to its step.
private struct OnboardingSummary: View {
    let model: OnboardingModel

    var body: some View {
        let missing = model.missingRequirements
        let required = missing.filter(\.isRequired)
        let optional = missing.filter { !$0.isRequired }
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if required.isEmpty {
                    OnboardingStatusLine(isSatisfied: true, text: "Ready to dictate.")
                } else {
                    OnboardingStatusLine(isSatisfied: false, text: "Before you can dictate:")
                    ForEach(required) { item in OnboardingRequirementLink(model: model, requirement: item) }
                }
                if !optional.isEmpty {
                    Text("Optional:")
                        .font(.headline)
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(optional) { item in OnboardingRequirementLink(model: model, requirement: item) }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OnboardingRequirementLink: View {
    let model: OnboardingModel
    let requirement: OnboardingRequirement

    var body: some View {
        if requirement.step == model.step {
            // Already on this step, so a link would do nothing.
            Text(requirement.title)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button {
                model.step = requirement.step
            } label: {
                Text(requirement.title)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.link)
            .accessibilityHint("Opens that setup step.")
        }
    }
}

// MARK: Previews

#if DEBUG
@MainActor
private final class PreviewOnboardingModels: OnboardingModelInstalling {
    let checked: Bool
    let installed: Set<String>
    let progress: [String: Double]

    init(checked: Bool = true, installed: Set<String> = [], progress: [String: Double] = [:]) {
        self.checked = checked
        self.installed = installed
        self.progress = progress
    }

    var onboardingModelsChecked: Bool { checked }
    var onboardingCanInstall: Bool { checked && progress.isEmpty }
    func onboardingIsInstalled(_ id: String) -> Bool { installed.contains(id) }
    func onboardingInstallProgress(_ id: String) -> Double? { progress[id] }
    func onboardingInstall(_ descriptor: ModelDescriptor) async -> String? {
        "The network connection was lost."
    }
}

@MainActor
private final class PreviewOnboardingPermissions: OnboardingPermissionProviding {
    let microphone: OnboardingMicrophoneStatus
    let trusted: Bool

    init(microphone: OnboardingMicrophoneStatus, trusted: Bool) {
        self.microphone = microphone
        self.trusted = trusted
    }

    func microphoneStatus() -> OnboardingMicrophoneStatus { microphone }
    func requestMicrophoneAccess() async -> Bool { false }
    func isAccessibilityTrusted() -> Bool { trusted }
    func promptForAccessibilityAccess() {}
    func openSettings(_ pane: OnboardingSettingsPane) {}
}

@MainActor
private final class PreviewOnboardingSettings: OnboardingSettingsProviding {
    func onboardingShortcut(for action: ShortcutAction) -> String? {
        ShortcutPreferences.defaults.shortcuts[action.rawValue]?.displayName
    }
    func onboardingShortcutRegistration(for action: ShortcutAction) -> ShortcutRegistration? { .registered }
    var onboardingPastesIntoOtherApps: Bool { true }
}

@MainActor
private func previewOnboarding(models: PreviewOnboardingModels? = nil,
                               microphone: OnboardingMicrophoneStatus = .notDetermined,
                               trusted: Bool = false) -> OnboardingModel {
    let model = OnboardingModel(models: models ?? PreviewOnboardingModels(),
        permissions: PreviewOnboardingPermissions(microphone: microphone, trusted: trusted),
        settings: PreviewOnboardingSettings(), automaticPresentationAllowed: false)
    model.refreshPermissions()
    return model
}

#Preview("First run") {
    OnboardingView(model: previewOnboarding())
        .frame(width: 760, height: 580)
}

#Preview("Installing speech model") {
    OnboardingView(model: previewOnboarding(
        models: PreviewOnboardingModels(progress: [ModelCatalog.primarySpeech.id: 0.42]),
        microphone: .authorized))
        .frame(width: 760, height: 580)
}

#Preview("Install failed") {
    let model = previewOnboarding(microphone: .authorized)
    OnboardingView(model: model)
        .frame(width: 760, height: 580)
        .task { await model.install(.speech) }
}

#Preview("Checking models") {
    OnboardingView(model: previewOnboarding(models: PreviewOnboardingModels(checked: false)))
        .frame(width: 760, height: 580)
}

#Preview("Ready") {
    OnboardingView(model: previewOnboarding(
        models: PreviewOnboardingModels(installed: [ModelCatalog.primarySpeech.id, ModelCatalog.primaryText.id]),
        microphone: .authorized, trusted: true))
        .frame(width: 760, height: 580)
}

#Preview("Microphone denied") {
    ScrollView {
        OnboardingMicrophoneStep(model: previewOnboarding(microphone: .denied))
            .padding(28)
    }
    .frame(width: 540, height: 420)
}

#Preview("Copy-only") {
    ScrollView {
        OnboardingAccessibilityStep(model: previewOnboarding(trusted: false))
            .padding(28)
    }
    .frame(width: 540, height: 620)
}

#Preview("Shortcuts and summary") {
    ScrollView {
        OnboardingShortcutsStep(model: previewOnboarding(
            models: PreviewOnboardingModels(installed: [ModelCatalog.primarySpeech.id]),
            microphone: .authorized))
            .padding(28)
    }
    .frame(width: 540, height: 680)
}
#endif
