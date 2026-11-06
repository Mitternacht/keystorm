import Foundation
import AppKit
import Testing
@testable import Keystorm

@MainActor
struct MenuBarStatusTests {
    private let flowStates: [DictationFlowState] = [.idle, .starting, .recording, .paused, .processing, .ready, .failed]

    // MARK: Coordinator state to icon

    @Test("Each coordinator state maps to the icon state a person would expect")
    func flowMapping() {
        let expected: [DictationFlowState: MenuBarState] = [
            .idle: .idle, .starting: .recording, .recording: .recording, .paused: .paused,
            .processing: .processing, .ready: .ready, .failed: .failed,
        ]
        for state in flowStates {
            #expect(MenuBarState.resolve(flow: state, briefRecording: false) == expected[state])
        }
        #expect(MenuBarState.resolve(flow: nil, briefRecording: false) == .idle)
    }

    @Test("A developer-brief recording shows as recording unless a dictation is itself in progress")
    func briefRecordingMapping() {
        #expect(MenuBarState.resolve(flow: nil, briefRecording: true) == .recording)
        #expect(MenuBarState.resolve(flow: .idle, briefRecording: true) == .recording)
        #expect(MenuBarState.resolve(flow: .ready, briefRecording: true) == .recording)
        #expect(MenuBarState.resolve(flow: .failed, briefRecording: true) == .recording)
        #expect(MenuBarState.resolve(flow: .paused, briefRecording: true) == .paused)
        #expect(MenuBarState.resolve(flow: .processing, briefRecording: true) == .processing)
    }

    @Test("Every icon state has its own symbol and a title")
    func symbolsAreDistinct() {
        let states: [MenuBarState] = [.idle, .recording, .paused, .processing, .ready, .failed]
        #expect(Set(states.map(\.symbolName)).count == states.count)
        #expect(states.allSatisfy { !String(localized: $0.title).isEmpty })
        #expect(states.filter(\.isTransient) == [.ready, .failed])
    }

    // MARK: Display state

    @Test("The icon follows the coordinator at once")
    func followsImmediately() {
        let status = MenuBarStatus(readyHold: .seconds(60), failedHold: .seconds(60))
        #expect(status.state == .idle)
        status.apply(.recording)
        #expect(status.state == .recording)
        status.apply(.paused)
        #expect(status.state == .paused)
        status.apply(.processing)
        #expect(status.state == .processing)
        status.apply(.idle)
        #expect(status.state == .idle)
    }

    @Test("A finished take shows ready, then the icon returns to idle by itself")
    func readyExpires() async {
        let status = MenuBarStatus(readyHold: .milliseconds(40), failedHold: .seconds(60))
        status.apply(.ready)
        #expect(status.state == .ready)
        #expect(await eventually { status.state == .idle })
    }

    @Test("A failed take stays visible longer, then also returns to idle")
    func failedExpires() async {
        let status = MenuBarStatus(readyHold: .milliseconds(10), failedHold: .milliseconds(120))
        status.apply(.failed)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(status.state == .failed)
        #expect(await eventually { status.state == .idle })
    }

    @Test("A new take cancels the pending fall back to idle")
    func newStateCancelsExpiry() async {
        let status = MenuBarStatus(readyHold: .milliseconds(40), failedHold: .seconds(60))
        status.apply(.ready)
        status.apply(.recording)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(status.state == .recording)
    }

    @Test("Seeing ready again without a change does not restart or revive it")
    func repeatedStateIsIgnored() async {
        let status = MenuBarStatus(readyHold: .milliseconds(40), failedHold: .seconds(60))
        status.apply(.ready)
        #expect(await eventually { status.state == .idle })
        status.apply(.ready)
        #expect(status.state == .idle)
    }

    // MARK: Menu text

    @Test("The last-result line is one short line, or nothing")
    func previewText() {
        #expect(MenuBarText.preview(of: "") == nil)
        #expect(MenuBarText.preview(of: " \n\t ") == nil)
        #expect(MenuBarText.preview(of: "Hello\n\n  there   world") == "Hello there world")
        let long = String(repeating: "word ", count: 40)
        let preview = MenuBarText.preview(of: long, limit: 20)
        #expect(preview?.hasSuffix("…") == true)
        #expect((preview?.count ?? 0) <= 21)
    }

    // MARK: Recovery notices

    @Test("Notices hide once dismissed and never repeat")
    func recoveryNotices() {
        let notices = RecoveryNotices()
        let messages = ["A", "B", "A", "C"]
        #expect(notices.visible(from: messages) == ["A", "B", "C"])
        notices.dismiss("B")
        #expect(notices.visible(from: messages) == ["A", "C"])
        // A message that arrives later is new.
        #expect(notices.visible(from: messages + ["D"]) == ["A", "C", "D"])
        notices.dismissAll(["A", "C", "D"])
        #expect(notices.visible(from: messages + ["D"]).isEmpty)
        #expect(notices.visible(from: []).isEmpty)
    }

    // MARK: Dock icon

    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let suiteName = "Keystorm.MenuBarStatusTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test("A new install is menu-bar only")
    func newInstallHidesDockIcon() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        #expect(AppPresentationPreferences(defaults: defaults).resolvedShowInDock() == false)
        #expect(defaults.object(forKey: AppPresentationPreferences.showInDockKey) as? Bool == false)
    }

    @Test("An install that already finished setup keeps its Dock icon")
    func existingInstallKeepsDockIcon() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("finished", forKey: OnboardingModel.completionKey)
        #expect(AppPresentationPreferences(defaults: defaults).resolvedShowInDock() == true)
    }

    @Test("Finishing setup later does not turn a new install into an old one")
    func decisionIsStoredOnFirstRead() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let preferences = AppPresentationPreferences(defaults: defaults)
        #expect(preferences.resolvedShowInDock() == false)
        defaults.set("finished", forKey: OnboardingModel.completionKey)
        #expect(preferences.resolvedShowInDock() == false)
        preferences.setShowInDock(true)
        #expect(preferences.resolvedShowInDock() == true)
    }

    @Test("Switching Show in Dock persists and changes the activation policy")
    func togglingAppliesPolicy() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        var policies: [NSApplication.ActivationPolicy] = []
        var activations = 0
        let presentation = AppPresentation(preferences: AppPresentationPreferences(defaults: defaults),
            applyPolicy: { policies.append($0) }, activate: { activations += 1 })
        #expect(!presentation.showInDock)
        presentation.applyCurrentPolicy()
        #expect(policies == [.accessory])

        presentation.showInDock = true
        #expect(policies == [.accessory, .regular])
        #expect(activations == 1)
        #expect(AppPresentationPreferences(defaults: defaults).resolvedShowInDock())

        presentation.showInDock = true
        #expect(policies.count == 2)
        presentation.showInDock = false
        #expect(policies == [.accessory, .regular, .accessory])
        #expect(activations == 1)
        #expect(!AppPresentationPreferences(defaults: defaults).resolvedShowInDock())
    }

    @Test("Isolated runs keep a regular app and never switch the policy")
    func isolatedRunKeepsRegularPolicy() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        var policies: [NSApplication.ActivationPolicy] = []
        let presentation = AppPresentation(preferences: AppPresentationPreferences(defaults: defaults),
            managesPolicy: false, applyPolicy: { policies.append($0) }, activate: {})
        presentation.applyCurrentPolicy()
        #expect(policies.isEmpty)
    }

    @Test("The workspace opens at launch for Dock apps and isolated runs, not for a menu-bar app")
    func launchPresentation() {
        #expect(AppPresentation.presentsWorkspaceAtLaunch(showInDock: true, isolatedRun: false))
        #expect(AppPresentation.presentsWorkspaceAtLaunch(showInDock: false, isolatedRun: true))
        #expect(!AppPresentation.presentsWorkspaceAtLaunch(showInDock: false, isolatedRun: false))
    }

    // MARK: Helpers

    /// Polls on the main actor until the condition holds, for at most two seconds.
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}
