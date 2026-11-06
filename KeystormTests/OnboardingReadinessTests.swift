import Foundation
import Testing
@testable import Keystorm

/// Models whose check can fail and be retried. Nothing is downloaded.
@MainActor
private final class ReadinessModels: OnboardingModelInstalling {
    var checked = true
    var failure: String?
    var installed: Set<String> = []
    private(set) var retries = 0
    /// What a retry does, for tests that want it to succeed.
    var onRetry: (@MainActor () -> Void)?

    var onboardingModelsChecked: Bool { checked }
    var onboardingCanInstall: Bool { checked }
    var onboardingModelsCheckFailure: String? { failure }
    func onboardingIsInstalled(_ id: String) -> Bool { installed.contains(id) }
    func onboardingInstallProgress(_ id: String) -> Double? { nil }
    func onboardingInstall(_ descriptor: ModelDescriptor) async -> String? { "Not expected." }
    func onboardingRetryModelsCheck() async {
        retries += 1
        onRetry?()
    }
}

@MainActor
private final class ReadinessPermissions: OnboardingPermissionProviding {
    var microphone: OnboardingMicrophoneStatus = .notDetermined
    var trusted = false
    func microphoneStatus() -> OnboardingMicrophoneStatus { microphone }
    func requestMicrophoneAccess() async -> Bool { false }
    func isAccessibilityTrusted() -> Bool { trusted }
    func promptForAccessibilityAccess() {}
    func openSettings(_ pane: OnboardingSettingsPane) {}
}

@MainActor
private final class ReadinessSettings: OnboardingSettingsProviding {
    func onboardingShortcut(for action: ShortcutAction) -> String? { "⌥Space" }
    func onboardingShortcutRegistration(for action: ShortcutAction) -> ShortcutRegistration? { .registered }
    var onboardingPastesIntoOtherApps: Bool { true }
}

@MainActor
struct OnboardingReadinessTests {
    private let models = ReadinessModels()
    private let permissions = ReadinessPermissions()
    private let speechID = ModelCatalog.primarySpeech.id
    private let textID = ModelCatalog.primaryText.id

    private func makeModel() -> OnboardingModel {
        let model = OnboardingModel(models: models, permissions: permissions, settings: ReadinessSettings(),
                                    automaticPresentationAllowed: false)
        model.refreshPermissions()
        return model
    }

    // MARK: Done is gated on readiness

    @Test("Done is off until the speech model, microphone and Accessibility are all ready")
    func doneNeedsAllThree() {
        let model = makeModel()
        #expect(!model.canFinish)
        #expect(model.finishBlockers == [.speechModel, .microphone, .accessibility])

        models.installed = [speechID]
        model.refreshPermissions()
        #expect(model.finishBlockers == [.microphone, .accessibility])

        permissions.microphone = .authorized
        model.refreshPermissions()
        #expect(model.finishBlockers == [.accessibility])
        #expect(!model.canFinish)
        // Dictation itself already works at this point; only the Done button waits.
        #expect(model.isReadyToDictate)

        permissions.trusted = true
        model.refreshPermissions()
        #expect(model.finishBlockers.isEmpty)
        #expect(model.canFinish)
    }

    @Test("The optional text model and the shortcut never hold Done back")
    func optionalItemsDoNotBlock() {
        let model = makeModel()
        models.installed = [speechID]
        permissions.microphone = .authorized
        permissions.trusted = true
        model.refreshPermissions()
        #expect(model.missingRequirements.contains(.textModel))
        #expect(model.canFinish)
        models.installed = [speechID, textID]
        #expect(model.canFinish)
    }

    @Test("A denied or restricted microphone keeps Done off")
    func deniedMicrophoneBlocks() {
        let model = makeModel()
        models.installed = [speechID]
        permissions.trusted = true
        for status in [OnboardingMicrophoneStatus.notDetermined, .denied, .restricted] {
            permissions.microphone = status
            model.refreshPermissions()
            #expect(!model.canFinish)
            #expect(model.finishBlockers == [.microphone])
        }
    }

    @Test("A revoked permission turns Done off again")
    func revokedPermissionBlocksAgain() {
        let model = makeModel()
        models.installed = [speechID]
        permissions.microphone = .authorized
        permissions.trusted = true
        model.refreshPermissions()
        #expect(model.canFinish)
        permissions.trusted = false
        model.refreshPermissions()
        #expect(!model.canFinish)
    }

    @Test("Finishing records completion for scripted runs, and the gate is only for the button")
    func finishItselfDoesNotRefuse() {
        let suiteName = "Keystorm.OnboardingReadinessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = OnboardingModel(models: models, permissions: permissions, settings: ReadinessSettings(),
                                    defaults: defaults, automaticPresentationAllowed: false)
        #expect(!model.canFinish)
        model.finish()
        #expect(model.completion == .finished)
    }

    // MARK: Practice step

    @Test("The practice step is last, and counts as done once something was dictated into it")
    func practiceStep() {
        let model = makeModel()
        #expect(OnboardingStep.allCases.last == .practice)
        model.step = .shortcuts
        #expect(!model.isLastStep)
        model.goForward()
        #expect(model.step == .practice)
        #expect(model.isLastStep)

        #expect(model.status(of: .practice) == .optional)
        model.practiceText = "  \n "
        #expect(model.status(of: .practice) == .optional)
        model.practiceText = "Hello from Keystorm"
        #expect(model.status(of: .practice) == .complete)
        // Practice is never a requirement: it cannot hold Done back.
        #expect(!model.missingRequirements.map(\.step).contains(.practice))
    }

    @Test("Opening setup does not start on the practice step while something earlier is missing")
    func beginSkipsPractice() {
        let model = makeModel()
        model.step = .practice
        model.begin()
        #expect(model.step == .models)
    }

    // MARK: A failed model check is shown, not an endless "Checking"

    @Test("While the workspace is still reading, the models step says Checking")
    func stillChecking() {
        models.checked = false
        let model = makeModel()
        #expect(model.status(of: .models) == .checking)
        #expect(model.modelCheckFailure == nil)
    }

    @Test("A failed check puts the models step into Needs action, with the reason and a retry")
    func failedCheckIsShown() async {
        models.checked = false
        models.failure = "The disk is full."
        let model = makeModel()
        #expect(model.status(of: .models) == .actionNeeded)
        #expect(model.modelCheckFailure == "The disk is full.")
        model.step = .practice
        model.begin()
        #expect(model.step == .models)

        models.onRetry = { [models] in
            models.checked = true
            models.failure = nil
            models.installed = [ModelCatalog.primarySpeech.id]
        }
        await model.retryModelsCheck()
        #expect(models.retries == 1)
        #expect(model.modelCheckFailure == nil)
        #expect(model.state(of: .speech) == .installed)
        #expect(model.status(of: .models) != .checking)
    }

    @Test("Retry does nothing when nothing failed, and a stale failure is ignored once the models were read")
    func retryOnlyAfterFailure() async {
        let model = makeModel()
        await model.retryModelsCheck()
        #expect(models.retries == 0)
        models.checked = true
        models.failure = "Old problem."
        #expect(model.modelCheckFailure == nil)
        await model.retryModelsCheck()
        #expect(models.retries == 0)
    }

    // MARK: The real workspace

    @Test("The workspace reports a startup failure once it ends, and never before it begins")
    func workspaceReportsStartupFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-OnboardingReadiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file where the storage folder should be: the session store cannot be created.
        let blocker = directory.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocker)

        let workspace = WorkspaceModel(root: blocker)
        #expect(workspace.onboardingModelsCheckFailure == nil)
        #expect(!workspace.onboardingModelsChecked)

        await workspace.initialize()
        #expect(!workspace.onboardingModelsChecked)
        #expect(workspace.onboardingModelsCheckFailure != nil)

        let onboarding = OnboardingModel(models: workspace, permissions: permissions, settings: ReadinessSettings(),
                                         automaticPresentationAllowed: false)
        #expect(onboarding.status(of: .models) == .actionNeeded)
        #expect(onboarding.modelCheckFailure != nil)
        await workspace.stopForTermination()
    }

    @Test("A healthy workspace never reports a failure")
    func workspaceHealthyStartup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-OnboardingReadiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(root: directory)
        await workspace.initialize()
        #expect(workspace.onboardingModelsChecked)
        #expect(workspace.onboardingModelsCheckFailure == nil)
        await workspace.stopForTermination()
    }
}
