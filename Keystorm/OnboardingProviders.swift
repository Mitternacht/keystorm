import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// Setup reuses the workspace's model status and `installModel`; it adds no install path.
extension WorkspaceModel: OnboardingModelInstalling {
    /// Startup assigns `store` before it clears `isBusy`. Reading `isBusy` keeps an observing
    /// view current, because `store` itself is not observed.
    var onboardingModelsChecked: Bool {
        _ = isBusy
        return store != nil
    }

    var onboardingCanInstall: Bool {
        onboardingModelsChecked && !isBusy && !isRecording && !isCaptureTransitioning
    }

    func onboardingIsInstalled(_ id: String) -> Bool { installedModelIDs.contains(id) }

    func onboardingInstallProgress(_ id: String) -> Double? { installProgress[id] }

    func onboardingInstall(_ descriptor: ModelDescriptor) async -> String? {
        await installModel(descriptor)
        if installedModelIDs.contains(descriptor.id) { return nil }
        // installModel reports failures through `error`, which the workspace window also shows.
        return error
    }
}

extension AppInteractionController: OnboardingSettingsProviding {
    func onboardingShortcut(for action: ShortcutAction) -> String? {
        shortcuts.shortcut(for: action)?.displayName
    }

    func onboardingShortcutRegistration(for action: ShortcutAction) -> ShortcutRegistration? {
        shortcuts.registration[action]
    }

    /// Before dictation is configured, read the same stored preference without writing it.
    var onboardingPastesIntoOtherApps: Bool {
        dictation?.preferences.pasteIntoOtherApps ?? DictationPreferences(defaults: .standard).pasteIntoOtherApps
    }
}

/// Reads permission status with the standard APIs. Requests run only from explicit setup buttons.
@MainActor
final class SystemOnboardingPermissions: OnboardingPermissionProviding {
    func microphoneStatus() -> OnboardingMicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func isAccessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    func promptForAccessibilityAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openSettings(_ pane: OnboardingSettingsPane) {
        guard let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }
}
