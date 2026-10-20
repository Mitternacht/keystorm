import AppKit
import Carbon
import Foundation
import Testing
@testable import Keystorm

/// Validated paste fallback for apps without a qualified insertion adapter.
/// The fake adapter only substitutes external AX/event I/O; every decision runs through the production service.
@MainActor
@Suite(.serialized)
struct DictationPasteFallbackTests {
    // MARK: Capture

    @Test("A generic app field is captured from metadata alone: no field text, fingerprint or nearby context")
    func genericAppCaptureNeverReadsFieldText() throws {
        let adapter = PasteFallbackTestAdapter()
        let service = makeService(adapter)
        let capture = service.captureForStart(contextSettings: .init(mode: .nearbyText), pasteIntoOtherApps: true)
        guard case .ready(let target) = capture.target else {
            Issue.record("A qualified text field in another app must become a paste fallback destination.")
            return
        }
        #expect(target.strategy == .pasteFallback)
        #expect(target.contextExcerpt.isEmpty)
        #expect(target.descriptor.bundleIdentifier == "com.apple.Notes")
        #expect(capture.context?.availability == .application)
        #expect(capture.context?.nearbyText == nil)
        #expect(adapter.snapshotReads == 0)
        #expect(adapter.textWrites == 0)
        #expect(adapter.qualifiedPastePreparations == 0)
        #expect(adapter.fallbackPreparations == 0)
        #expect(adapter.manualAccessibilityReads == 0, "A directly exposed field never touches the app's accessibility mode.")
        #expect(adapter.manualAccessibilityWrites.isEmpty)
        #expect(adapter.selectionReads == 1)
    }

    @Test("Text-entry roles from native, web and Electron fields qualify", arguments: [
        PasteFallbackRole(role: "AXTextArea", subrole: nil, bundle: "com.tinyspeck.slackmacgap"),
        PasteFallbackRole(role: "AXTextField", subrole: nil, bundle: "com.apple.Safari"),
        PasteFallbackRole(role: "AXTextField", subrole: "AXSearchField", bundle: "com.google.Chrome"),
        PasteFallbackRole(role: "AXComboBox", subrole: nil, bundle: "com.apple.mail")
    ])
    func textEntryRolesQualify(_ fixture: PasteFallbackRole) throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.app.bundleIdentifier = fixture.bundle
        adapter.fieldMetadata.role = fixture.role
        adapter.fieldMetadata.subrole = fixture.subrole
        let target = try readyTarget(makeService(adapter))
        #expect(target.strategy == .pasteFallback)
        #expect(adapter.snapshotReads == 0)
    }

    @Test("With the setting off, other apps stay Copy-only and are not inspected")
    func settingOffKeepsCopyOnly() {
        let adapter = PasteFallbackTestAdapter()
        let service = makeService(adapter)
        guard case .unavailable(let failure) = service.captureTarget(pasteIntoOtherApps: false) else {
            Issue.record("The paste fallback must stay off when the setting is off.")
            return
        }
        #expect(failure == .unsupportedApplication)
        #expect(failure.message.contains("Paste into other apps"))
        #expect(!failure.blocksRecording)
        #expect(adapter.focusReads == 0)
        #expect(adapter.metadataReads == 0)
        #expect(adapter.manualAccessibilityReads == 0)
        #expect(adapter.manualAccessibilityWrites.isEmpty)
        #expect(adapter.snapshotReads == 0)
    }

    @Test("Terminals stay Copy-only and are never inspected, even with paste enabled", arguments: [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio",
        // Electron terminals.
        "com.termius-dmg.mac", "com.termius.mac", "dev.commandline.waveterm"
    ])
    func terminalsAreCopyOnly(_ identifier: String) {
        let adapter = PasteFallbackTestAdapter()
        adapter.app.bundleIdentifier = identifier
        let service = makeService(adapter)
        guard case .unavailable(let failure) = service.captureTarget(pasteIntoOtherApps: true) else {
            Issue.record("A terminal must never receive a paste.")
            return
        }
        #expect(failure == .copyOnlyApplication)
        #expect(adapter.focusReads == 0)
        #expect(adapter.metadataReads == 0)
        #expect(adapter.manualAccessibilityReads == 0)
        #expect(adapter.manualAccessibilityWrites.isEmpty)
    }

    @Test("Excluded apps block recording before any field access, even with paste enabled")
    func excludedAppIsNotInspected() {
        let adapter = PasteFallbackTestAdapter()
        adapter.app.bundleIdentifier = "com.1password.1password"
        let service = makeService(adapter)
        guard case .unavailable(let failure) = service.captureTarget(pasteIntoOtherApps: true) else {
            Issue.record("Excluded apps must refuse capture.")
            return
        }
        #expect(failure == .excludedApplication)
        #expect(failure.blocksRecording)
        #expect(adapter.focusReads == 0)
        #expect(adapter.metadataReads == 0)
    }

    @Test("Password managers are excluded by default and block recording before any field access", arguments: [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "in.sinew.Enpass-Desktop",
        "me.proton.pass.electron", "com.agilebits.onepassword-osx", "com.agilebits.onepassword4"
    ])
    func passwordManagersAreExcluded(_ identifier: String) {
        let adapter = PasteFallbackTestAdapter()
        adapter.app.bundleIdentifier = identifier
        let capture = makeService(adapter).captureForStart(contextSettings: .init(mode: .nearbyText), pasteIntoOtherApps: true)
        guard case .unavailable(let failure) = capture.target else {
            Issue.record("A password manager must refuse capture.")
            return
        }
        #expect(failure == .excludedApplication)
        #expect(failure.blocksRecording)
        #expect(capture.context == nil)
        #expect(adapter.focusReads == 0)
        #expect(adapter.metadataReads == 0)
        #expect(adapter.manualAccessibilityReads == 0)
        #expect(adapter.manualAccessibilityWrites.isEmpty)
        #expect(DictationDeliveryService.passwordManagerBundleIdentifiers.isSuperset(of: [
            "com.1password.1password", "com.agilebits.onepassword7"
        ]))
    }

    @Test("Secure fields block recording without reading text or selection", arguments: [
        PasteFallbackSecureField.subrole, .role, .protectedContent
    ])
    func secureFieldIsRefused(_ variant: PasteFallbackSecureField) {
        let adapter = PasteFallbackTestAdapter()
        switch variant {
        case .subrole: adapter.fieldMetadata.role = "AXTextField"; adapter.fieldMetadata.subrole = "AXSecureTextField"
        case .role: adapter.fieldMetadata.role = "AXSecureTextField"
        case .protectedContent: adapter.fieldMetadata.isProtected = true
        }
        let service = makeService(adapter)
        guard case .unavailable(let failure) = service.captureTarget(pasteIntoOtherApps: true) else {
            Issue.record("A secure field must never become a paste destination.")
            return
        }
        #expect(failure == .secureField)
        #expect(failure.blocksRecording)
        #expect(adapter.snapshotReads == 0)
        #expect(adapter.selectionReads == 0)
    }

    @Test("Non-text, disabled, read-only and unknown-subrole elements stay Copy-only", arguments: [
        PasteFallbackUnsupported.group, .webArea, .button, .disabled, .notEditable, .unknownSubrole, .otherProcess
    ])
    func unsupportedElementsAreRefused(_ reason: PasteFallbackUnsupported) {
        let adapter = PasteFallbackTestAdapter()
        switch reason {
        case .group: adapter.fieldMetadata.role = "AXGroup"
        case .webArea: adapter.fieldMetadata.role = "AXWebArea"
        case .button: adapter.fieldMetadata.role = "AXButton"
        case .disabled: adapter.fieldMetadata.isEnabled = false
        case .notEditable:
            adapter.fieldMetadata.valueIsSettable = false
            adapter.fieldMetadata.selectedTextIsSettable = false
        case .unknownSubrole: adapter.fieldMetadata.subrole = "AXDescriptionList"
        case .otherProcess: adapter.fieldMetadata.processIdentifier += 1
        }
        let service = makeService(adapter)
        guard case .unavailable(let failure) = service.captureTarget(pasteIntoOtherApps: true) else {
            Issue.record("Unsupported elements must not become destinations.")
            return
        }
        #expect(failure == .unsupportedField)
        #expect(!failure.blocksRecording)
        #expect(adapter.snapshotReads == 0)
    }

    @Test("Missing Accessibility or event access never inspects or prompts", arguments: [false, true])
    func missingPermissionsAreCopyOnly(_ trustedWithoutEvents: Bool) {
        let adapter = PasteFallbackTestAdapter()
        if trustedWithoutEvents { adapter.canPostPasteEvents = false } else { adapter.isTrusted = false }
        let service = makeService(adapter)
        guard case .unavailable(let failure) = service.captureTarget(pasteIntoOtherApps: true) else {
            Issue.record("Capture must fail without the required permissions.")
            return
        }
        #expect(failure == .accessibilityPermission)
        #expect(adapter.permissionRequests == 0)
        #expect(adapter.snapshotReads == 0)
        if !trustedWithoutEvents {
            #expect(adapter.focusReads == 0)
            #expect(adapter.manualAccessibilityReads == 0)
            #expect(adapter.manualAccessibilityWrites.isEmpty)
        }
    }

    @Test("No focused element means Copy, never an app-level paste")
    func missingFocusedElementIsUnavailable() {
        let adapter = PasteFallbackTestAdapter()
        adapter.focusThrows = true
        let service = makeService(adapter)
        guard case .unavailable(let failure) = service.captureTarget(pasteIntoOtherApps: true) else {
            Issue.record("A missing focused element must not become a destination.")
            return
        }
        #expect(failure == .unavailableField)
        // Asked for once, polled for the bounded wait, and turned off again because the capture still failed:
        // one direct attempt, one immediate poll, then one poll per waited interval.
        #expect(adapter.manualAccessibilityReads == 1)
        #expect(adapter.manualAccessibilityWrites == [true, false])
        #expect(adapter.focusReads == 2 + DictationAccessibilityWarmUp.standard.maximumWaitedPolls)
    }

    @Test("TextEdit keeps its qualified adapter when paste is enabled")
    func textEditKeepsQualifiedPath() throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.app = DictationDeliveryApplication(processIdentifier: 77, bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
        adapter.fieldMetadata.selectedTextIsSettable = true
        let target = try readyTarget(makeService(adapter))
        #expect(target.strategy == .qualifiedTextEdit)
        #expect(adapter.snapshotReads > 0)
        #expect(adapter.manualAccessibilityReads == 0)
        #expect(adapter.manualAccessibilityWrites.isEmpty)
        #expect(adapter.selectionReads == 0)
    }

    // MARK: Embedded terminals

    @Test("An xterm.js terminal input inside an editor or web app is Copy-only at Start, without touching the app",
          arguments: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.google.Chrome"])
    func embeddedTerminalInputIsCopyOnly(_ identifier: String) throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.app.bundleIdentifier = identifier
        adapter.fieldMetadata.isTerminalInput = true
        #expect(!adapter.fieldMetadata.acceptsPasteFallback)
        let capture = makeService(adapter).captureForStart(contextSettings: .init(mode: .nearbyText), pasteIntoOtherApps: true)
        let failure = try #require(captureFailure(capture.target), "A terminal input must never become a destination.")
        #expect(failure == .copyOnlyApplication)
        #expect(!failure.blocksRecording, "Dictating into a terminal stays useful with manual copy.")
        #expect(capture.context?.nearbyText == nil)
        #expect(adapter.snapshotReads == 0)
        #expect(adapter.selectionReads == 0)
        #expect(adapter.fallbackPreparations == 0)
        #expect(adapter.manualAccessibilityReads == 0)
        #expect(adapter.manualAccessibilityWrites.isEmpty)
    }

    @Test("Terminal inputs are recognised by xterm.js's DOM class or exact label only", arguments: [
        TerminalMarkers(classes: ["xterm-helper-textarea"], labels: [], isTerminal: true),
        TerminalMarkers(classes: ["monaco-editor", "xterm-helper-textarea focus"], labels: [], isTerminal: true),
        TerminalMarkers(classes: [], labels: ["Terminal input"], isTerminal: true),
        TerminalMarkers(classes: [], labels: ["", " terminal input\n"], isTerminal: true),
        TerminalMarkers(classes: ["xterm", "xterm-screen", "xterm-helper-textarea-like"], labels: [], isTerminal: false),
        TerminalMarkers(classes: ["inputarea"], labels: ["Editor content", "Terminal input history"], isTerminal: false),
        TerminalMarkers(classes: [], labels: [], isTerminal: false)
    ])
    func terminalInputMarkers(_ markers: TerminalMarkers) {
        #expect(DictationFieldMetadata.isTerminalInput(domClassList: markers.classes, labels: markers.labels) == markers.isTerminal)
    }

    // MARK: AXManualAccessibility

    @Test("A directly exposed field never reads or writes AXManualAccessibility, through delivery and release")
    func directFieldLeavesManualAccessibilityAlone() async throws {
        let adapter = PasteFallbackTestAdapter()
        let service = makeService(adapter)
        let target = try readyTarget(service)
        #expect(await service.deliver("Hallo", to: target, deliveryID: UUID()).outcome == .pasted)
        service.releaseCapturedTarget(target)
        #expect(adapter.manualAccessibilityReads == 0)
        #expect(adapter.manualAccessibilityWrites.isEmpty)
    }

    @Test("When the request still exposes no destination, the capture fails and turns AXManualAccessibility off again",
          arguments: [ManualAccessibilityRetry.noField, .unsupportedField, .secureField, .terminalInput])
    func failedRetryRestoresManualAccessibility(_ retry: ManualAccessibilityRetry) {
        let adapter = PasteFallbackTestAdapter()
        adapter.focusThrows = true
        adapter.onManualAccessibilityWrite = { enabled in
            guard enabled else { return }
            switch retry {
            case .noField: break
            case .unsupportedField: adapter.focusThrows = false; adapter.fieldMetadata.role = "AXWebArea"
            case .secureField: adapter.focusThrows = false; adapter.fieldMetadata.subrole = "AXSecureTextField"
            case .terminalInput: adapter.focusThrows = false; adapter.fieldMetadata.isTerminalInput = true
            }
        }
        let clock = WarmUpTestClock()
        let service = makeService(adapter, warmUp: clock.warmUp())
        #expect(captureFailure(service.captureTarget(pasteIntoOtherApps: true)) == retry.expectedFailure)
        #expect(adapter.manualAccessibilityReads == 1)
        #expect(adapter.manualAccessibilityWrites == [true, false])
        #expect(adapter.manualAccessibilityValue == false)
        let waitedPolls = retry.endsWaitAtOnce ? 0 : DictationAccessibilityWarmUp.standard.maximumWaitedPolls
        #expect(clock.sleeps.count == waitedPolls, "A secure field or terminal input ends the wait at once.")
        #expect(adapter.focusReads == 2 + waitedPolls, "One direct attempt, one immediate poll, one per wait.")
        #expect(adapter.snapshotReads == 0)
    }

    @Test("An app that already reports AXManualAccessibility on, or rejects the request, is not retried, reset or waited for",
          arguments: [true, false])
    func manualAccessibilityAlreadyOnOrRejectedIsLeftAlone(_ alreadyOn: Bool) {
        let adapter = PasteFallbackTestAdapter()
        adapter.fieldMetadata.role = "AXWebArea"
        if alreadyOn { adapter.manualAccessibilityValue = true } else { adapter.manualAccessibilityWriteSucceeds = false }
        let clock = WarmUpTestClock()
        let service = makeService(adapter, warmUp: clock.warmUp())
        #expect(captureFailure(service.captureTarget(pasteIntoOtherApps: true)) == .unsupportedField)
        #expect(adapter.manualAccessibilityReads == 1)
        #expect(adapter.manualAccessibilityWrites == (alreadyOn ? [] : [true]), "Never written back to false.")
        #expect(adapter.focusReads == 1)
        #expect(clock.sleeps.isEmpty, "Only a write Keystorm made itself may wait.")
    }

    @Test("A field exposed only on request keeps AXManualAccessibility on until its delivery ends, whatever the outcome",
          arguments: [DictationDeliveryOutcome.pasted, .uncertain, .targetChanged, .failed])
    func deliveryRestoresManualAccessibility(_ outcome: DictationDeliveryOutcome) async throws {
        let adapter = PasteFallbackTestAdapter()
        let service = makeService(adapter)
        let target = try grantedTarget(service, adapter)
        #expect(target.strategy == .pasteFallback)
        #expect(adapter.manualAccessibilityWrites == [true])
        switch outcome {
        case .uncertain: adapter.readsOnPerform = false
        case .targetChanged: adapter.selection = NSRange(location: 0, length: 2)
        case .failed: adapter.prepareThrows = true
        default: break
        }
        #expect(await service.deliver("Hallo", to: target, deliveryID: UUID()).outcome == outcome)
        #expect(adapter.manualAccessibilityWrites == [true, false])
        service.releaseCapturedTarget(target)
        #expect(adapter.manualAccessibilityWrites == [true, false], "Restoration happens at most once.")
    }

    @Test("Discarding a capture without delivery turns AXManualAccessibility off once")
    func releasingCaptureRestoresOnce() async throws {
        let adapter = PasteFallbackTestAdapter()
        let service = makeService(adapter)
        let target = try grantedTarget(service, adapter)
        service.releaseCapturedTarget(target)
        service.releaseCapturedTarget(target)
        #expect(adapter.manualAccessibilityWrites == [true, false])
        // The app no longer exposes the field, so a late delivery refuses without writing again.
        #expect(await service.deliver("Hallo", to: target, deliveryID: UUID()).outcome == .targetChanged)
        #expect(adapter.performCount == 0)
        #expect(adapter.manualAccessibilityWrites == [true, false])
    }

    @Test("A capture dropped without delivery or release still turns AXManualAccessibility off")
    func droppedCaptureRestoresManualAccessibility() async throws {
        let adapter = PasteFallbackTestAdapter()
        let service = makeService(adapter)
        weak var dropped: DictationCapturedTarget?
        do {
            let target = try grantedTarget(service, adapter)
            dropped = target
            #expect(adapter.manualAccessibilityWrites == [true])
        }
        for _ in 0..<1_000 where dropped != nil || adapter.manualAccessibilityWrites.count < 2 { await Task.yield() }
        #expect(dropped == nil)
        #expect(adapter.manualAccessibilityWrites == [true, false])
    }

    @Test("Captures that rely on the same AXManualAccessibility request keep it on until the last one ends")
    func sharedManualAccessibilityEndsWithLastCapture() throws {
        let adapter = PasteFallbackTestAdapter()
        let service = makeService(adapter)
        let first = try grantedTarget(service, adapter)
        let second = try readyTarget(service)
        #expect(adapter.manualAccessibilityReads == 1, "The second capture finds the field directly.")
        #expect(adapter.manualAccessibilityWrites == [true])
        service.releaseCapturedTarget(first)
        #expect(adapter.manualAccessibilityWrites == [true])
        service.releaseCapturedTarget(second)
        #expect(adapter.manualAccessibilityWrites == [true, false])
    }

    @Test("While an earlier request is still in effect, a capture that finds no field neither asks again nor turns it off")
    func activeManualAccessibilityIsNotRequestedTwice() throws {
        let adapter = PasteFallbackTestAdapter()
        let clock = WarmUpTestClock()
        let service = makeService(adapter, warmUp: clock.warmUp())
        let first = try grantedTarget(service, adapter)
        adapter.focusThrows = true
        #expect(captureFailure(service.captureTarget(pasteIntoOtherApps: true)) == .unavailableField)
        #expect(adapter.manualAccessibilityReads == 1)
        #expect(adapter.manualAccessibilityWrites == [true], "The earlier capture still relies on it.")
        #expect(clock.sleeps.isEmpty, "A capture sharing an earlier grant never waits.")
        service.releaseCapturedTarget(first)
        #expect(adapter.manualAccessibilityWrites == [true, false])
    }

    @Test("A delivery refused because another one is in flight still ends its own AXManualAccessibility request")
    func refusedConcurrentDeliveryReleasesItsCapture() async throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.readsOnPerform = false
        let service = makeService(adapter, timing: DictationPasteTiming(evidenceTimeout: .milliseconds(300),
            settleDelay: .milliseconds(5), pollInterval: .milliseconds(5)))
        let direct = try readyTarget(service)
        let inFlight = Task { @MainActor in await service.deliver("Hallo", to: direct, deliveryID: UUID()) }
        for _ in 0..<10_000 where adapter.performCount == 0 { await Task.yield() }
        try #require(adapter.performCount == 1, "The first delivery must be waiting for evidence after one paste.")
        let granted = try grantedTarget(service, adapter)
        #expect(adapter.manualAccessibilityWrites == [true])
        let refused = await service.deliver("Hallo", to: granted, deliveryID: UUID())
        #expect(refused.outcome == .failed)
        #expect(refused.message.hasPrefix("Another insertion is still being confirmed."))
        // Still referenced here, so only the refused delivery itself can have turned it off.
        withExtendedLifetime(granted) {
            #expect(adapter.manualAccessibilityWrites == [true, false])
        }
        #expect(await inFlight.value.outcome == .uncertain)
        #expect(adapter.performCount == 1)
        #expect(adapter.manualAccessibilityWrites == [true, false])
    }

    // MARK: Waiting for a requested field

    // Polls are numbered from the AXManualAccessibility write: poll 1 runs at once, each later one after a wait.

    @Test("A field exposed directly is captured at once: no poll, no wait and no AXManualAccessibility access",
          arguments: ["com.apple.Notes", "com.tinyspeck.slackmacgap"])
    func directFieldNeverWaits(_ identifier: String) throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.app.bundleIdentifier = identifier
        let clock = WarmUpTestClock()
        let target = try readyTarget(makeService(adapter, warmUp: clock.warmUp()))
        #expect(target.strategy == .pasteFallback)
        #expect(clock.sleeps.isEmpty)
        #expect(adapter.metadataReads == 1, "The direct attempt only.")
        #expect(adapter.manualAccessibilityReads == 0)
        #expect(adapter.manualAccessibilityWrites.isEmpty)
    }

    @Test("A field the app exposes while it builds its tree is captured on that poll, and AXManualAccessibility stays on until release")
    func fieldExposedDuringWarmUpIsCaptured() throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.app = DictationDeliveryApplication(processIdentifier: 77, bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
        adapter.fieldMetadata.role = "AXWebArea"
        let clock = WarmUpTestClock()
        // Polls 1 and 2 still see the web area; the text area is in the tree by poll 3.
        clock.onSleep = { sleeps in if sleeps == 2 { adapter.fieldMetadata.role = "AXTextArea" } }
        let service = makeService(adapter, warmUp: clock.warmUp())
        let target = try readyTarget(service)
        #expect(target.strategy == .pasteFallback)
        #expect(target.descriptor.bundleIdentifier == "com.tinyspeck.slackmacgap")
        #expect(clock.sleeps == Array(repeating: DictationAccessibilityWarmUp.standardPollInterval, count: 2),
                "The wait ends on the poll that finds the field.")
        #expect(adapter.metadataReads == 1 + 3, "One direct attempt, then three polls.")
        #expect(adapter.manualAccessibilityReads == 1)
        #expect(adapter.snapshotReads == 0)
        #expect(adapter.manualAccessibilityWrites == [true])
        #expect(adapter.manualAccessibilityValue == true, "Kept on while the capture is live.")
        service.releaseCapturedTarget(target)
        #expect(adapter.manualAccessibilityWrites == [true, false])
        #expect(adapter.manualAccessibilityWritePIDs == [77, 77])
    }

    @Test("When the app never exposes a field, the wait stays bounded, Start falls back to Copy and AXManualAccessibility is turned off again",
          arguments: [WarmUpBound.standard, .clippedAtDeadline, .stalledClock, .zeroInterval, .zeroTimeout])
    func warmUpWithoutFieldIsBounded(_ bound: WarmUpBound) throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.fieldMetadata.role = "AXWebArea"
        let clock = WarmUpTestClock()
        clock.stalls = bound.clockStalls
        let service = makeService(adapter, warmUp: clock.warmUp(pollInterval: bound.pollInterval, timeout: bound.timeout))
        let capture = service.captureForStart(contextSettings: .init(mode: .nearbyText), pasteIntoOtherApps: true)
        let failure = try #require(captureFailure(capture.target))
        #expect(failure == .unsupportedField)
        #expect(!failure.blocksRecording, "Recording continues with Copy.")
        #expect(capture.context?.availability == .application)
        #expect(clock.sleeps == bound.expectedSleeps)
        #expect(clock.sleeps.reduce(Duration.zero, +) <= bound.timeout)
        #expect(adapter.metadataReads == 2 + bound.expectedSleeps.count,
                "One direct attempt, one immediate poll, one poll per wait.")
        #expect(adapter.manualAccessibilityWrites == [true, false])
        #expect(adapter.manualAccessibilityValue == false)
        #expect(adapter.selectionReads == 0)
        #expect(adapter.snapshotReads == 0)
    }

    @Test("A secure field or terminal input that appears during the wait ends it at once and is refused",
          arguments: [ManualAccessibilityRetry.secureField, .terminalInput])
    func refusedFieldDuringWarmUpEndsWait(_ retry: ManualAccessibilityRetry) throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.fieldMetadata.role = "AXWebArea"
        let clock = WarmUpTestClock()
        clock.onSleep = { sleeps in
            guard sleeps == 2 else { return }
            adapter.fieldMetadata.role = "AXTextArea"
            switch retry {
            case .secureField: adapter.fieldMetadata.subrole = "AXSecureTextField"
            case .terminalInput: adapter.fieldMetadata.isTerminalInput = true
            case .noField, .unsupportedField: Issue.record("Only a refused field ends the wait early.")
            }
        }
        let failure = try #require(captureFailure(makeService(adapter, warmUp: clock.warmUp())
            .captureTarget(pasteIntoOtherApps: true)))
        #expect(failure == retry.expectedFailure)
        #expect(failure.blocksRecording == (retry == .secureField), "A secure field still blocks recording.")
        #expect(clock.sleeps.count == 2)
        #expect(adapter.metadataReads == 1 + 3, "No poll after the refused field.")
        #expect(adapter.manualAccessibilityWrites == [true, false])
        #expect(adapter.selectionReads == 0)
        #expect(adapter.snapshotReads == 0)
        #expect(adapter.fallbackPreparations == 0)
    }

    @Test("Switching apps during the wait ends it with Target changed and turns AXManualAccessibility off in the app it was turned on in",
          arguments: [WarmUpFrontmostChange.application, .process])
    func frontmostChangeDuringWarmUpEndsWait(_ change: WarmUpFrontmostChange) throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.fieldMetadata.role = "AXWebArea"
        let clock = WarmUpTestClock()
        // The original app never exposes a field, so only the frontmost check can end the wait early.
        clock.onSleep = { sleeps in
            guard sleeps == 2 else { return }
            switch change {
            case .application:
                adapter.app = DictationDeliveryApplication(processIdentifier: 78, bundleIdentifier: "com.apple.Safari", name: "Safari")
            case .process: adapter.app.processIdentifier = 78
            }
        }
        let failure = try #require(captureFailure(makeService(adapter, warmUp: clock.warmUp())
            .captureTarget(pasteIntoOtherApps: true)))
        #expect(failure == .targetChanged)
        #expect(!failure.blocksRecording)
        #expect(clock.sleeps.count == 2)
        #expect(adapter.metadataReads == 1 + 2, "No poll after the switch.")
        #expect(adapter.manualAccessibilityWrites == [true, false])
        #expect(adapter.manualAccessibilityWritePIDs == [77, 77])
        #expect(adapter.selectionReads == 0)
    }

    @Test("Start finishes the wait before it presents anything or begins the microphone, then pastes and turns the mode off")
    func coordinatorWaitsBeforeRecording() async {
        let adapter = PasteFallbackTestAdapter()
        adapter.app = DictationDeliveryApplication(processIdentifier: 77, bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
        adapter.fieldMetadata.role = "AXWebArea"
        let clock = WarmUpTestClock()
        let backend = PasteFallbackRecordingBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: makeService(adapter, warmUp: clock.warmUp()))
        var duringWait: [(state: DictationFlowState, hud: Bool, begins: Int)] = []
        clock.onSleep = { [weak coordinator] sleeps in
            guard let coordinator else { return }
            duringWait.append((coordinator.state, coordinator.wantsRecordingHUD, backend.begins))
            if sleeps == 2 { adapter.fieldMetadata.role = "AXTextArea" }
        }
        coordinator.toggle()
        #expect(duringWait.count == 2)
        #expect(duringWait.allSatisfy { $0.state == .idle && !$0.hud && $0.begins == 0 })
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .recording)
        #expect(coordinator.destinationLabel == "Paste into Slack")
        #expect(backend.begins == 1)
        #expect(adapter.manualAccessibilityWrites == [true])
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.message == "Pasted into Slack.")
        #expect(adapter.performCount == 1)
        #expect(adapter.manualAccessibilityWrites == [true, false])
        #expect(clock.sleeps.count == 2, "Delivery never waits for the tree again.")
    }

    // MARK: Delivery validation

    @Test("App, process, field, role, security, terminal and selection changes prevent any paste", arguments: [
        PasteFallbackMutation.application, .process, .field, .role, .secure, .disabled, .terminalInput,
        .selection, .selectionUnavailable
    ])
    func changedDestinationIsNeverPasted(_ mutation: PasteFallbackMutation) async throws {
        let adapter = PasteFallbackTestAdapter()
        let service = makeService(adapter)
        let target = try readyTarget(service)
        switch mutation {
        case .application: adapter.app.bundleIdentifier = "com.apple.Safari"
        case .process: adapter.app.processIdentifier += 1
        case .field: adapter.field = PasteFallbackField()
        case .role: adapter.fieldMetadata.role = "AXTextField"
        case .secure: adapter.fieldMetadata.isProtected = true
        case .disabled: adapter.fieldMetadata.isEnabled = false
        case .terminalInput: adapter.fieldMetadata.isTerminalInput = true
        case .selection: adapter.selection = NSRange(location: 0, length: 3)
        case .selectionUnavailable: adapter.selection = nil
        }
        let receipt = await service.deliver("Grüße aus München", to: target, deliveryID: UUID())
        #expect(receipt.outcome == .targetChanged)
        #expect(adapter.fallbackPreparations == 0)
        #expect(adapter.performCount == 0)
        #expect(adapter.snapshotReads == 0)
        #expect(adapter.textWrites == 0)
    }

    @Test("A destination change while the clipboard is staged prevents the paste and restores it")
    func changeDuringStagingIsNotPasted() async throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.onPrepare = { adapter.selection = NSRange(location: 1, length: 0) }
        let service = makeService(adapter)
        let receipt = await service.deliver("Hallo", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .targetChanged)
        #expect(adapter.fallbackPreparations == 1)
        #expect(adapter.performCount == 0)
        #expect(adapter.pasteOperation?.restoreCount == 1)
        #expect(adapter.pasteOperation?.leaveCount == 0)
    }

    @Test("A field that never reported a selection is still validated by identity, role and security")
    func missingSelectionStillValidatesIdentity() async throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.selection = nil
        let service = makeService(adapter)
        let target = try readyTarget(service)
        adapter.selection = NSRange(location: 3, length: 0)
        #expect(await service.deliver("Hallo", to: target, deliveryID: UUID()).outcome == .pasted)
        #expect(adapter.performCount == 1)
    }

    @Test("The same delivery UUID returns the original receipt; a second attempt never pastes again")
    func deliveryIsAtMostOnce() async throws {
        let adapter = PasteFallbackTestAdapter()
        let service = makeService(adapter)
        let target = try readyTarget(service)
        let id = UUID()
        let first = await service.deliver("Hallo", to: target, deliveryID: id)
        let replay = await service.deliver("different text", to: target, deliveryID: id)
        #expect(first.outcome == .pasted)
        #expect(replay == first)
        #expect(await service.deliver("Hallo again", to: target, deliveryID: UUID()).outcome == .failed)
        #expect(adapter.performCount == 1)
        #expect(adapter.fallbackPreparations == 1)
    }

    @Test("A concurrent delivery while waiting for paste evidence never pastes twice")
    func reentrantDeliveryDuringEvidenceWaitIsRefused() async throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.readsOnPerform = false
        let service = makeService(adapter, timing: DictationPasteTiming(evidenceTimeout: .milliseconds(300),
            settleDelay: .milliseconds(5), pollInterval: .milliseconds(5)))
        let target = try readyTarget(service)
        let id = UUID()
        let first = Task { @MainActor in await service.deliver("Hallo", to: target, deliveryID: id) }
        for _ in 0..<10_000 where adapter.performCount == 0 { await Task.yield() }
        try #require(adapter.performCount == 1, "The first delivery must be waiting for evidence after one paste.")
        let sameID = await service.deliver("Hallo", to: target, deliveryID: id)
        let newID = await service.deliver("Hallo", to: target, deliveryID: UUID())
        #expect(sameID.outcome == .uncertain)
        #expect(newID.outcome == .failed)
        #expect(await first.value.outcome == .uncertain)
        #expect(adapter.performCount == 1)
    }

    @Test("Read evidence reports Pasted and restores the clipboard after the settle delay")
    func readEvidenceIsPasted() async throws {
        let adapter = PasteFallbackTestAdapter()
        let service = makeService(adapter)
        let receipt = await service.deliver("Hallo", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .pasted)
        #expect(receipt.message == "Pasted into Notes.")
        #expect(adapter.performCount == 1)
        #expect(adapter.pasteOperation?.restoreCount == 1)
        #expect(adapter.pasteOperation?.leaveCount == 0)
        #expect(adapter.textWrites == 0)
        #expect(adapter.snapshotReads == 0)
    }

    @Test("Without read evidence the paste stays uncertain and the result is left on the clipboard, never restored")
    func missingEvidenceLeavesResult() async throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.readsOnPerform = false
        let service = makeService(adapter)
        let receipt = await service.deliver("Hallo", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .uncertain)
        #expect(receipt.message == "Paste was sent to Notes but could not be confirmed. " +
                "The result is on the clipboard. Check Notes before pasting again. " +
                "Your previous clipboard was not restored.")
        #expect(adapter.performCount == 1)
        #expect(adapter.pasteOperation?.leaveCount == 1)
        #expect(adapter.pasteOperation?.restoreCount == 0)
    }

    @Test("An unconfirmed paste whose result was replaced by a newer copy does not claim it is on the clipboard")
    func missingEvidenceWithoutOwnershipSaysReadyToCopy() async throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.readsOnPerform = false
        adapter.leaveResult = false
        let service = makeService(adapter)
        let receipt = await service.deliver("Hallo", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .uncertain)
        #expect(receipt.message == "Paste was sent to Notes but could not be confirmed. " +
                "Check Notes before pasting again; the result is ready to copy.")
        #expect(adapter.pasteOperation?.leaveCount == 1)
        #expect(adapter.pasteOperation?.restoreCount == 0)
    }

    @Test("Cancellation after the paste was posted leaves the result instead of restoring the clipboard")
    func cancellationAfterPostingLeavesResult() async throws {
        let adapter = PasteFallbackTestAdapter()
        adapter.readsOnPerform = false
        let service = makeService(adapter, timing: DictationPasteTiming(evidenceTimeout: .seconds(30),
            settleDelay: .milliseconds(5), pollInterval: .milliseconds(5)))
        let target = try readyTarget(service)
        let started = ContinuousClock.now
        let delivery = Task { @MainActor in await service.deliver("Hallo", to: target, deliveryID: UUID()) }
        for _ in 0..<10_000 where adapter.performCount == 0 { await Task.yield() }
        try #require(adapter.performCount == 1, "The delivery must be waiting for evidence after one paste.")
        delivery.cancel()
        let receipt = await delivery.value
        #expect(ContinuousClock.now - started < .seconds(10), "Cancellation must end the evidence wait early.")
        #expect(receipt.outcome == .uncertain)
        #expect(receipt.message.contains("The result is on the clipboard."))
        #expect(adapter.pasteOperation?.leaveCount == 1)
        #expect(adapter.pasteOperation?.restoreCount == 0)
    }

    @Test("Cancellation after staging but before posting restores the original clipboard and sends nothing",
          arguments: [false, true])
    func cancellationBeforePostingRestores(_ realLease: Bool) async throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        let adapter = PasteFallbackTestAdapter()
        if realLease { adapter.leasePasteboard = pasteboard.board }
        // Runs at the end of staging, on the delivery task: the clipboard is staged, no event is posted yet.
        adapter.onPrepare = { withUnsafeCurrentTask { $0?.cancel() } }
        let service = makeService(adapter)
        let target = try readyTarget(service)
        let receipt = await Task { @MainActor in await service.deliver("Hallo", to: target, deliveryID: UUID()) }.value
        #expect(receipt.outcome == .failed)
        #expect(receipt.message == "Insertion was cancelled before any text was sent.")
        #expect(adapter.fallbackPreparations == 1)
        #expect(adapter.performCount == 0)
        if realLease {
            pasteboard.expectOriginal()
        } else {
            #expect(adapter.pasteOperation?.restoreCount == 1)
            #expect(adapter.pasteOperation?.leaveCount == 0)
        }
    }

    @Test("Lost clipboard ownership or event access sends nothing", arguments: [true, false])
    func failedPerformOrPreparationSendsNothing(_ preparationFails: Bool) async throws {
        let adapter = PasteFallbackTestAdapter()
        if preparationFails { adapter.prepareThrows = true } else { adapter.performSucceeds = false }
        let service = makeService(adapter)
        let receipt = await service.deliver("Hallo", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .failed)
        #expect(adapter.performCount == 0)
        if !preparationFails {
            #expect(adapter.pasteOperation?.restoreCount == 1)
            #expect(adapter.pasteOperation?.leaveCount == 0)
        }
    }

    @Test("Revoked Accessibility, empty text and cancellation fail before the clipboard is touched")
    func genericGuardsStillApply() async throws {
        let adapter = PasteFallbackTestAdapter()
        let service = makeService(adapter)
        #expect(await service.deliver("", to: try readyTarget(service), deliveryID: UUID()).outcome == .failed)
        let untrusted = try readyTarget(service)
        adapter.isTrusted = false
        #expect(await service.deliver("Hallo", to: untrusted, deliveryID: UUID()).outcome == .failed)
        adapter.isTrusted = true
        let cancelledTarget = try readyTarget(service)
        let task = Task { @MainActor in await service.deliver("Hallo", to: cancelledTarget, deliveryID: UUID()) }
        task.cancel()
        #expect(await task.value.outcome == .failed)
        #expect(adapter.fallbackPreparations == 0)
        #expect(adapter.performCount == 0)
    }

    @Test("A paste fallback never arms external-correction observation")
    func pastedTargetsAreNotObserved() async throws {
        let adapter = PasteFallbackTestAdapter()
        let service = makeService(adapter)
        let target = try readyTarget(service)
        let id = UUID()
        #expect(await service.deliver("Hallo", to: target, deliveryID: id).outcome == .pasted)
        let armed = service.startCorrectionObservation(to: target, deliveredText: "Hallo", deliveryID: id,
            isEnabled: { true }, onObservation: { _ in })
        #expect(!armed)
        #expect(!service.hasActiveCorrectionObservation)
        #expect(adapter.snapshotReads == 0)
    }

    // MARK: Real clipboard lease

    @Test("Reading .string in-process asks the lazy provider; marker checks and pre-arm reads are not evidence")
    func lazyLeaseProviderIsCalledInProcess() throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        let lease = try #require(DictationClipboardLease(text: "Hallo 👋 München", pasteboard: pasteboard.board,
                                                         providesTextLazily: true))
        #expect(pasteboard.board.types?.contains(.string) == true)
        #expect(lease.isOwned)
        lease.armReadEvidence()
        #expect(lease.isOwned)
        #expect(!lease.stagedTextWasRead, "Ownership checks read only the eager marker.")
        #expect(pasteboard.board.string(forType: .string) == "Hallo 👋 München")
        #expect(lease.stagedTextWasRead, "An in-process read must reach the lazy provider.")
        lease.restoreIfOwned()
        pasteboard.expectOriginal()
    }

    @Test("A read before arming never counts as paste evidence")
    func preArmReadIsNotEvidence() throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        let lease = try #require(DictationClipboardLease(text: "dictation", pasteboard: pasteboard.board,
                                                         providesTextLazily: true))
        #expect(pasteboard.board.string(forType: .string) == "dictation")
        lease.armReadEvidence()
        #expect(!lease.stagedTextWasRead)
        lease.restoreIfOwned()
        pasteboard.expectOriginal()
    }

    @Test("An eagerly staged lease, as used by TextEdit, never reports read evidence")
    func eagerLeaseHasNoEvidence() throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        let lease = try #require(DictationClipboardLease(text: "eager", pasteboard: pasteboard.board))
        lease.armReadEvidence()
        #expect(pasteboard.board.string(forType: .string) == "eager")
        #expect(!lease.stagedTextWasRead)
        lease.restoreIfOwned()
        pasteboard.expectOriginal()
    }

    @Test("A lazy lease never overwrites a newer user clipboard, and restores itself if released while owned")
    func lazyLeaseRespectsNewerClipboardAndDeinit() throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        let lease = try #require(DictationClipboardLease(text: "dictation", pasteboard: pasteboard.board,
                                                         providesTextLazily: true))
        pasteboard.board.clearContents()
        pasteboard.board.setString("new user copy", forType: .string)
        #expect(!lease.isOwned)
        lease.restoreIfOwned()
        #expect(pasteboard.board.string(forType: .string) == "new user copy")

        pasteboard.writeOriginal()
        do {
            let abandoned = DictationClipboardLease(text: "abandoned", pasteboard: pasteboard.board, providesTextLazily: true)
            #expect(abandoned?.isOwned == true)
        }
        pasteboard.expectOriginal()
    }

    @Test("End to end: a destination read reports Pasted and restores every original representation")
    func realLeaseReadIsPastedAndRestored() async throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        let adapter = PasteFallbackTestAdapter()
        adapter.leasePasteboard = pasteboard.board
        let service = makeService(adapter)
        let text = "Bitte verschiebe das Meeting auf morgen. 👋"
        let receipt = await service.deliver(text, to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .pasted)
        #expect(adapter.leaseOperation?.pastedText == text)
        pasteboard.expectOriginal()
    }

    @Test("End to end: no destination read stays uncertain and leaves an eager copy of the result, even after release")
    func realLeaseWithoutReadLeavesEagerResult() async throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        let adapter = PasteFallbackTestAdapter()
        adapter.leasePasteboard = pasteboard.board
        adapter.readsOnPerform = false
        let service = makeService(adapter)
        let text = "Bitte verschiebe das Meeting auf morgen. 👋"
        let receipt = await service.deliver(text, to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .uncertain)
        #expect(receipt.message.contains("The result is on the clipboard."))
        weak var handedOffLease: DictationClipboardLease?
        do {
            let operation = try #require(adapter.leaseOperation)
            handedOffLease = operation.lease
            #expect(operation.performCount == 1)
            #expect(operation.lease.isOwned, "The handed-off copy still carries the lease marker.")
            pasteboard.expectStagedResult(text)
            #expect(!operation.stagedTextWasRead, "The handed-off copy is eager, so reading it never reaches the provider.")
        }
        // Releasing the lease must not restore the original clipboard behind a late paste.
        adapter.leaseOperation = nil
        #expect(handedOffLease == nil, "The lease must be released, so its release-time restoration has run.")
        pasteboard.expectStagedResult(text)
    }

    @Test("End to end: a user copy after an unconfirmed paste is never overwritten or restored over")
    func realLeaseWithoutReadKeepsNewerUserClipboard() async throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        let adapter = PasteFallbackTestAdapter()
        adapter.leasePasteboard = pasteboard.board
        adapter.readsOnPerform = false
        adapter.onLeasePerform = { board in
            board.clearContents()
            board.setString("copied by the user meanwhile", forType: .string)
        }
        let service = makeService(adapter)
        let receipt = await service.deliver("Hallo", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .uncertain)
        #expect(receipt.message.hasSuffix("the result is ready to copy."))
        adapter.leaseOperation = nil
        #expect(pasteboard.board.string(forType: .string) == "copied by the user meanwhile")
        #expect(pasteboard.board.data(forType: PrivatePasteboard.customType) == nil)
    }

    @Test("Handing off a lazy lease writes the same text eagerly with its hints and disarms every restoration")
    func leaseHandOffIsEagerAndFinal() throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        do {
            let lease = try #require(DictationClipboardLease(text: "Grüße 👋", pasteboard: pasteboard.board,
                                                             providesTextLazily: true))
            lease.armReadEvidence()
            let stagedChangeCount = pasteboard.board.changeCount
            #expect(lease.leaveStagedTextOnPasteboard())
            #expect(pasteboard.board.changeCount != stagedChangeCount, "The lazy item is replaced by a new eager one.")
            #expect(lease.isOwned)
            pasteboard.expectStagedResult("Grüße 👋")
            #expect(!lease.stagedTextWasRead)
            lease.restoreIfOwned()
            pasteboard.expectStagedResult("Grüße 👋")
            #expect(lease.leaveStagedTextOnPasteboard(), "A repeated hand-off reports the same ownership.")
        }
        pasteboard.expectStagedResult("Grüße 👋")
    }

    @Test("Handing off a lease that lost ownership leaves the newer clipboard alone and reports it")
    func leaseHandOffWithoutOwnershipIsInert() throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        do {
            let lease = try #require(DictationClipboardLease(text: "dictation", pasteboard: pasteboard.board,
                                                             providesTextLazily: true))
            pasteboard.board.clearContents()
            pasteboard.board.setString("new user copy", forType: .string)
            let changeCount = pasteboard.board.changeCount
            #expect(!lease.leaveStagedTextOnPasteboard())
            #expect(pasteboard.board.changeCount == changeCount)
            lease.restoreIfOwned()
        }
        #expect(pasteboard.board.string(forType: .string) == "new user copy")
    }

    // MARK: Pasteboard privacy

    @Test("Only a denied pasteboard refuses a backup; Ask and the default may prompt once and keep working", arguments: [
        (NSPasteboard.AccessBehavior.default, true), (.ask, true), (.alwaysAllow, true), (.alwaysDeny, false)
    ])
    func accessBehaviorDecidesBackup(_ behavior: NSPasteboard.AccessBehavior, _ canBackUp: Bool) {
        #expect(DictationClipboardLease.canBackUp(accessBehavior: behavior) == canBackUp)
    }

    @Test("A denied pasteboard is never staged or cleared, eager or lazy", arguments: [false, true])
    func deniedPasteboardIsNotStaged(_ lazily: Bool) throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        let changeCount = pasteboard.board.changeCount
        #expect(DictationClipboardLease(text: "dictation", pasteboard: pasteboard.board, providesTextLazily: lazily,
                                        accessBehavior: .alwaysDeny) == nil)
        #expect(pasteboard.board.changeCount == changeCount)
        pasteboard.expectOriginal()
        let asking = try #require(DictationClipboardLease(text: "dictation", pasteboard: pasteboard.board,
                                                          providesTextLazily: lazily, accessBehavior: .ask))
        asking.restoreIfOwned()
        pasteboard.expectOriginal()
    }

    @Test("End to end: a denied pasteboard fails as an unprepared clipboard and sends nothing")
    func deniedPasteboardFailsBeforePasting() async throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        let adapter = PasteFallbackTestAdapter()
        adapter.leasePasteboard = pasteboard.board
        adapter.leaseAccessBehavior = .alwaysDeny
        let service = makeService(adapter)
        let receipt = await service.deliver("Hallo", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .failed)
        #expect(receipt.message == "The clipboard could not be prepared safely. Nothing was pasted; copy the result instead.")
        #expect(adapter.fallbackPreparations == 1)
        #expect(adapter.performCount == 0)
        pasteboard.expectOriginal()
    }

    // MARK: Layout-aware paste key

    @Test("The paste key is the one typing \"v\" with Command held, falling back to kVK_ANSI_V", arguments: [
        PasteKeyLayout(name: "QWERTY", keys: [9: "v", 47: "."], expected: 9),
        PasteKeyLayout(name: "Dvorak", keys: [9: "k", 47: "v"], expected: 47),
        PasteKeyLayout(name: "No key types v", keys: [9: "м"], expected: 9),
        PasteKeyLayout(name: "Layout data unavailable", keys: nil, expected: 9),
        PasteKeyLayout(name: "kVK_ANSI_V wins a tie", keys: [3: "v", 9: "v"], expected: 9),
        PasteKeyLayout(name: "Lowest key code otherwise", keys: [40: "v", 20: "v"], expected: 20),
        PasteKeyLayout(name: "Codes from 128 are ignored", keys: [130: "v"], expected: 9),
        PasteKeyLayout(name: "Exact lowercase only", keys: [47: "V", 30: "vv"], expected: 9)
    ])
    func pasteKeyResolution(_ layout: PasteKeyLayout) {
        let translate: ((UInt16) -> String?)? = layout.keys.map { keys in { keys[$0] } }
        #expect(DictationPasteKeyCode.resolve(translate: translate) == layout.expected)
    }

    @Test("Installed layouts resolve through UCKeyTranslate without being selected", arguments: [
        ("com.apple.keylayout.US", CGKeyCode(kVK_ANSI_V)), ("com.apple.keylayout.Dvorak", CGKeyCode(kVK_ANSI_Period)),
        ("com.apple.keylayout.DVORAK-QWERTYCMD", CGKeyCode(kVK_ANSI_V)), ("com.apple.keylayout.Russian", CGKeyCode(kVK_ANSI_V))
    ])
    func installedLayoutsResolve(_ identifier: String, _ expected: CGKeyCode) throws {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
        let source = try #require(sources.first, "\(identifier) ships with macOS.")
        #expect(DictationPasteKeyCode.virtualKey(in: source) == expected)
    }

    @Test("The current layout yields a key code in the virtual key range")
    func currentLayoutPasteKeyIsInRange() {
        #expect(DictationPasteKeyCode.candidates.contains(DictationPasteKeyCode.current()))
    }

    @Test("End to end: a user copy during the paste window is never overwritten")
    func realLeaseKeepsNewerUserClipboard() async throws {
        let pasteboard = PrivatePasteboard()
        defer { pasteboard.release() }
        pasteboard.writeOriginal()
        let adapter = PasteFallbackTestAdapter()
        adapter.leasePasteboard = pasteboard.board
        adapter.onLeasePerform = { board in
            board.clearContents()
            board.setString("copied by the user meanwhile", forType: .string)
        }
        let service = makeService(adapter)
        let receipt = await service.deliver("Hallo", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .pasted)
        #expect(pasteboard.board.string(forType: .string) == "copied by the user meanwhile")
        #expect(pasteboard.board.data(forType: PrivatePasteboard.customType) == nil)
    }

    // MARK: Coordinator, preferences and persistence

    @Test("The coordinator labels, pastes and saves a Pasted receipt without correction observation")
    func coordinatorPastesIntoOtherApp() async throws {
        let adapter = PasteFallbackTestAdapter()
        let backend = PasteFallbackRecordingBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: makeService(adapter))
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .recording)
        #expect(coordinator.destinationLabel == "Paste into Notes")
        #expect(coordinator.message == "Recording locally. Finish to paste into Notes.")
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .ready)
        #expect(coordinator.message == "Pasted into Notes.")
        #expect(adapter.performCount == 1)
        #expect(adapter.snapshotReads == 0)
        let saved = backend.deliveries.map(\.state)
        #expect(saved == [.pending, .pasted])
        #expect(backend.deliveries.last?.targetLabel == "Notes")
    }

    @Test("The coordinator keeps Copy wording when the setting is off")
    func coordinatorHonorsSettingOff() async throws {
        let adapter = PasteFallbackTestAdapter()
        let preferences = DictationPreferences()
        preferences.pasteIntoOtherApps = false
        let backend = PasteFallbackRecordingBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: makeService(adapter), preferences: preferences)
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .recording)
        #expect(coordinator.destinationLabel == "Copy after recording")
        #expect(coordinator.message.contains("Turn on Paste into other apps in Settings"))
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(adapter.focusReads == 0)
        #expect(adapter.performCount == 0)
        #expect(backend.deliveries.isEmpty)
    }

    @Test("The coordinator records in an embedded terminal with Copy wording and never pastes")
    func coordinatorKeepsEmbeddedTerminalCopyOnly() async {
        let adapter = PasteFallbackTestAdapter()
        adapter.app = DictationDeliveryApplication(processIdentifier: 77, bundleIdentifier: "com.microsoft.VSCode", name: "Code")
        adapter.fieldMetadata.isTerminalInput = true
        let backend = PasteFallbackRecordingBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: makeService(adapter))
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .recording)
        #expect(coordinator.destinationLabel == "Copy after recording")
        #expect(coordinator.message == DictationCaptureFailure.copyOnlyApplication.message)
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .ready)
        #expect(adapter.fallbackPreparations == 0)
        #expect(adapter.performCount == 0)
        #expect(adapter.snapshotReads == 0)
        #expect(backend.deliveries.isEmpty)
    }

    @Test("Paste into other apps defaults on, persists explicitly, and restores from the store")
    func preferenceDefaultsOnAndPersists() throws {
        let suiteName = "Keystorm.DictationPasteFallbackTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(DictationPreferences().pasteIntoOtherApps)
        let preferences = DictationPreferences(defaults: defaults)
        #expect(preferences.pasteIntoOtherApps)
        #expect(defaults.object(forKey: DictationPreferences.pasteIntoOtherAppsKey) == nil)
        preferences.pasteIntoOtherApps = false
        #expect(defaults.object(forKey: DictationPreferences.pasteIntoOtherAppsKey) as? Bool == false)
        #expect(!DictationPreferences(defaults: defaults).pasteIntoOtherApps)
        preferences.pasteIntoOtherApps = true
        #expect(DictationPreferences(defaults: defaults).pasteIntoOtherApps)
    }

    @Test("Pasted receipts round-trip with a stable raw value")
    func pastedStateIsCodable() throws {
        #expect(DictationDeliveryState.pasted.rawValue == "pasted")
        #expect(DictationDeliveryOutcome.pasted.rawValue == "pasted")
        let delivery = DictationDelivery(requestID: UUID(), textRevisionID: UUID(), targetLabel: "Notes",
                                         state: .pasted, detail: "Pasted into Notes.")
        let data = try JSONEncoder().encode(delivery)
        #expect(String(decoding: data, as: UTF8.self).contains("\"pasted\""))
        #expect(try JSONDecoder().decode(DictationDelivery.self, from: data) == delivery)
    }

    // MARK: Helpers

    /// The AXManualAccessibility wait always runs on a virtual clock here, so no test sleeps on wall time.
    private func makeService(_ adapter: PasteFallbackTestAdapter,
                             timing: DictationPasteTiming = DictationPasteTiming(evidenceTimeout: .milliseconds(150),
                                 settleDelay: .milliseconds(5), pollInterval: .milliseconds(5)),
                             warmUp: DictationAccessibilityWarmUp? = nil) -> DictationDeliveryService {
        DictationDeliveryService(adapter: adapter, ownBundleIdentifier: "test.keystorm", ownProcessIdentifier: 900,
                                 pasteTiming: timing, accessibilityWarmUp: warmUp ?? WarmUpTestClock().warmUp())
    }

    private func readyTarget(_ service: DictationDeliveryService) throws -> DictationCapturedTarget {
        guard case .ready(let target) = service.captureTarget(pasteIntoOtherApps: true) else {
            throw PasteFallbackTestError.unexpectedCaptureFailure
        }
        return target
    }

    /// Like a Chromium or Electron app: the field is exposed only while AXManualAccessibility is on.
    private func grantedTarget(_ service: DictationDeliveryService,
                               _ adapter: PasteFallbackTestAdapter) throws -> DictationCapturedTarget {
        adapter.fieldMetadata.role = "AXWebArea"
        adapter.onManualAccessibilityWrite = { enabled in adapter.fieldMetadata.role = enabled ? "AXTextArea" : "AXWebArea" }
        return try readyTarget(service)
    }

    private func captureFailure(_ result: DictationCaptureResult) -> DictationCaptureFailure? {
        guard case .unavailable(let failure) = result else { return nil }
        return failure
    }
}

struct PasteFallbackRole: Sendable, CustomTestStringConvertible {
    var role: String
    var subrole: String?
    var bundle: String
    var testDescription: String { "\(bundle) \(role)\(subrole.map { "/" + $0 } ?? "")" }
}
enum PasteFallbackSecureField: Sendable { case subrole, role, protectedContent }
enum PasteFallbackUnsupported: Sendable { case group, webArea, button, disabled, notEditable, unknownSubrole, otherProcess }
enum PasteFallbackMutation: Sendable {
    case application, process, field, role, secure, disabled, terminalInput, selection, selectionUnavailable
}
/// What a Chromium or Electron app exposes once AXManualAccessibility is on, when that still is no destination.
enum ManualAccessibilityRetry: Sendable {
    case noField, unsupportedField, secureField, terminalInput
    var expectedFailure: DictationCaptureFailure {
        switch self {
        case .noField: .unavailableField
        case .unsupportedField: .unsupportedField
        case .secureField: .secureField
        case .terminalInput: .copyOnlyApplication
        }
    }
    /// A refused field is a final answer; an absent or unsupported one may still be replaced as the tree builds.
    var endsWaitAtOnce: Bool { self == .secureField || self == .terminalInput }
}
/// How the bounded AXManualAccessibility wait is configured, and the virtual sleeps it must take.
struct WarmUpBound: Sendable, CustomTestStringConvertible {
    var name: String
    var pollInterval: Duration
    var timeout: Duration
    var clockStalls = false
    var expectedSleeps: [Duration]
    var testDescription: String { name }

    static let standard = WarmUpBound(name: "standard", pollInterval: DictationAccessibilityWarmUp.standardPollInterval,
        timeout: DictationAccessibilityWarmUp.standardTimeout,
        expectedSleeps: Array(repeating: DictationAccessibilityWarmUp.standardPollInterval, count: 8))
    static let clippedAtDeadline = WarmUpBound(name: "last sleep clipped at the deadline", pollInterval: .milliseconds(50),
        timeout: .milliseconds(120), expectedSleeps: [.milliseconds(50), .milliseconds(50), .milliseconds(20)])
    static let stalledClock = WarmUpBound(name: "stalled clock", pollInterval: .milliseconds(50),
        timeout: .milliseconds(400), clockStalls: true,
        expectedSleeps: Array(repeating: .milliseconds(50), count: 8))
    static let zeroInterval = WarmUpBound(name: "zero-length interval", pollInterval: .zero,
        timeout: .milliseconds(400), expectedSleeps: [])
    static let zeroTimeout = WarmUpBound(name: "zero timeout", pollInterval: .milliseconds(50),
        timeout: .zero, expectedSleeps: [])
}
/// The user switches away while the app is still building its tree.
enum WarmUpFrontmostChange: Sendable { case application, process }
struct TerminalMarkers: Sendable, CustomTestStringConvertible {
    var classes: [String]
    var labels: [String]
    var isTerminal: Bool
    var testDescription: String { "classes \(classes), labels \(labels)" }
}
/// A fake keyboard layout: what each virtual key types with Command held; nil means no layout data.
struct PasteKeyLayout: Sendable, CustomTestStringConvertible {
    var name: String
    var keys: [UInt16: String]?
    var expected: CGKeyCode
    var testDescription: String { name }
}
private enum PasteFallbackTestError: Error { case unexpectedCaptureFailure, unsupported }

/// A uniquely named pasteboard; the general clipboard is never touched.
@MainActor
private struct PrivatePasteboard {
    static let customType = NSPasteboard.PasteboardType("test.keystorm.paste-fallback.binary")
    let board = NSPasteboard(name: NSPasteboard.Name("Keystorm-PasteFallback-Test-" + UUID().uuidString))

    func writeOriginal() {
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([0, 1, 2, 255]), forType: Self.customType)
        board.clearContents()
        #expect(board.writeObjects([item]))
    }

    func expectOriginal(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(board.string(forType: .string) == "original", sourceLocation: sourceLocation)
        #expect(board.data(forType: Self.customType) == Data([0, 1, 2, 255]), sourceLocation: sourceLocation)
    }

    /// The staged result replaced the original, and still carries the clipboard-manager hints.
    func expectStagedResult(_ text: String, fileID: String = #fileID, filePath: String = #filePath,
                            line: Int = #line, column: Int = #column) {
        let location = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        #expect(board.string(forType: .string) == text, sourceLocation: location)
        #expect(board.data(forType: Self.customType) == nil, sourceLocation: location)
        let types = Set(board.types ?? [])
        for hint in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            #expect(types.contains(NSPasteboard.PasteboardType(hint)), "Missing \(hint)", sourceLocation: location)
        }
    }

    func release() { board.releaseGlobally() }
}

@MainActor private final class PasteFallbackField: DictationDeliveryField {}

/// Virtual time for the AXManualAccessibility wait: it advances only when the service sleeps, so the bound
/// is asserted exactly and nothing waits on wall time.
@MainActor
private final class WarmUpTestClock {
    private let origin = ContinuousClock.now
    private var elapsed: Duration = .zero
    /// Every requested sleep, in order.
    private(set) var sleeps: [Duration] = []
    /// When true, `now` never advances, as if the clock stalled; only the poll cap can end the wait.
    var stalls = false
    /// Runs after each sleep with the number of sleeps so far, for example to expose a field once the tree is built.
    var onSleep: ((Int) -> Void)?

    func warmUp(pollInterval: Duration = DictationAccessibilityWarmUp.standardPollInterval,
                timeout: Duration = DictationAccessibilityWarmUp.standardTimeout) -> DictationAccessibilityWarmUp {
        DictationAccessibilityWarmUp(pollInterval: pollInterval, timeout: timeout,
            now: { [self] in origin.advanced(by: elapsed) },
            sleep: { [self] duration in sleep(for: duration) })
    }

    private func sleep(for duration: Duration) {
        sleeps.append(duration)
        if !stalls { elapsed += duration }
        onSleep?(sleeps.count)
    }
}

@MainActor
private final class PasteFallbackTestAdapter: DictationDeliveryAdapter {
    var isTrusted = true
    var canPostPasteEvents = true
    var app = DictationDeliveryApplication(processIdentifier: 77, bundleIdentifier: "com.apple.Notes", name: "Notes")
    var field = PasteFallbackField()
    var fieldMetadata = DictationFieldMetadata(processIdentifier: 77, role: "AXTextArea", subrole: nil,
        isEnabled: true, isProtected: false, selectedTextIsSettable: false, valueIsSettable: true)
    var selection: NSRange? = NSRange(location: 5, length: 0)
    var focusThrows = false
    var prepareThrows = false
    var performSucceeds = true
    var readsOnPerform = true
    /// What the fake operation reports from `leaveStagedTextOnPasteboard()` (false: a newer copy replaced it).
    var leaveResult = true
    var onPrepare: (() -> Void)?
    /// When set, staging uses a real lazily provided lease on this private pasteboard.
    var leasePasteboard: NSPasteboard?
    /// Overrides the private pasteboard's privacy setting, which is always `.alwaysAllow`.
    var leaseAccessBehavior: NSPasteboard.AccessBehavior?
    var onLeasePerform: ((NSPasteboard) -> Void)?
    /// AXManualAccessibility as the app reports it; nil when it cannot be read.
    var manualAccessibilityValue: Bool? = false
    var manualAccessibilityWriteSucceeds = true
    /// Runs after an accepted write, for example to expose a field once a Chromium tree is on.
    var onManualAccessibilityWrite: ((Bool) -> Void)?

    var focusReads = 0
    var metadataReads = 0
    var snapshotReads = 0
    var selectionReads = 0
    var permissionRequests = 0
    var manualAccessibilityReads = 0
    /// Every AXManualAccessibility write, in order, including rejected ones.
    var manualAccessibilityWrites: [Bool] = []
    /// The process each of those writes addressed.
    var manualAccessibilityWritePIDs: [Int32] = []
    var textWrites = 0
    var qualifiedPastePreparations = 0
    var fallbackPreparations = 0
    var pasteOperation: PasteFallbackTestOperation?
    var leaseOperation: LeaseBackedPasteOperation?
    var performCount: Int { (pasteOperation?.performCount ?? 0) + (leaseOperation?.performCount ?? 0) }

    func requestPermission() { permissionRequests += 1 }
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { app }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField {
        focusReads += 1
        if focusThrows { throw PasteFallbackTestError.unsupported }
        return field
    }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { lhs === rhs }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        metadataReads += 1
        return fieldMetadata
    }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        snapshotReads += 1
        return DictationFieldSnapshot(text: "Before after", selection: NSRange(location: 6, length: 0))
    }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        textWrites += 1
        return .rejected
    }
    func preparePaste(_ text: String, in field: any DictationDeliveryField, processIdentifier: Int32) throws -> any DictationPasteOperation {
        qualifiedPastePreparations += 1
        throw PasteFallbackTestError.unsupported
    }
    func manualAccessibility(in application: DictationDeliveryApplication) -> Bool? {
        manualAccessibilityReads += 1
        return manualAccessibilityValue
    }
    func setManualAccessibility(_ enabled: Bool, in application: DictationDeliveryApplication) -> Bool {
        manualAccessibilityWrites.append(enabled)
        manualAccessibilityWritePIDs.append(application.processIdentifier)
        guard manualAccessibilityWriteSucceeds else { return false }
        manualAccessibilityValue = enabled
        onManualAccessibilityWrite?(enabled)
        return true
    }
    func selectedTextRange(of field: any DictationDeliveryField) -> NSRange? {
        selectionReads += 1
        return selection
    }
    func prepareFallbackPaste(_ text: String, processIdentifier: Int32) throws -> any DictationPasteOperation {
        fallbackPreparations += 1
        #expect(processIdentifier == app.processIdentifier)
        if prepareThrows { throw PasteFallbackTestError.unsupported }
        defer { onPrepare?() }
        if let leasePasteboard {
            // Mirrors the native adapter: a lease that cannot back up the clipboard is a preparation failure.
            guard let lease = DictationClipboardLease(text: text, pasteboard: leasePasteboard, providesTextLazily: true,
                                                      accessBehavior: leaseAccessBehavior) else {
                throw PasteFallbackTestError.unsupported
            }
            let operation = LeaseBackedPasteOperation(lease: lease, pasteboard: leasePasteboard,
                destinationReads: readsOnPerform, onPerform: onLeasePerform)
            leaseOperation = operation
            return operation
        }
        let operation = PasteFallbackTestOperation(succeeds: performSucceeds, readsOnPerform: readsOnPerform,
                                                   leaveResult: leaveResult)
        pasteOperation = operation
        return operation
    }
}

@MainActor
private final class PasteFallbackTestOperation: DictationPasteOperation {
    let succeeds: Bool
    let readsOnPerform: Bool
    let leaveResult: Bool
    var performCount = 0
    var restoreCount = 0
    var leaveCount = 0
    private(set) var stagedTextWasRead = false

    init(succeeds: Bool, readsOnPerform: Bool, leaveResult: Bool) {
        self.succeeds = succeeds
        self.readsOnPerform = readsOnPerform
        self.leaveResult = leaveResult
    }

    func perform() -> Bool {
        guard succeeds, performCount == 0 else { return false }
        performCount += 1
        if readsOnPerform { stagedTextWasRead = true }
        return true
    }

    func restoreIfOwned() { restoreCount += 1 }

    func leaveStagedTextOnPasteboard() -> Bool {
        leaveCount += 1
        return leaveResult
    }
}

/// Mirrors the native operation without posting events: "the destination" reads the private pasteboard.
@MainActor
private final class LeaseBackedPasteOperation: DictationPasteOperation {
    let lease: DictationClipboardLease
    let pasteboard: NSPasteboard
    let destinationReads: Bool
    let onPerform: ((NSPasteboard) -> Void)?
    private(set) var performCount = 0
    private(set) var pastedText: String?

    init(lease: DictationClipboardLease, pasteboard: NSPasteboard, destinationReads: Bool,
         onPerform: ((NSPasteboard) -> Void)?) {
        self.lease = lease
        self.pasteboard = pasteboard
        self.destinationReads = destinationReads
        self.onPerform = onPerform
    }

    func perform() -> Bool {
        guard performCount == 0, lease.isOwned else { return false }
        performCount += 1
        lease.armReadEvidence()
        if destinationReads { pastedText = pasteboard.string(forType: .string) }
        onPerform?(pasteboard)
        return true
    }

    func restoreIfOwned() { lease.restoreIfOwned() }
    func leaveStagedTextOnPasteboard() -> Bool { lease.leaveStagedTextOnPasteboard() }
    var stagedTextWasRead: Bool { lease.stagedTextWasRead }
}

@MainActor
private final class PasteFallbackRecordingBackend: DictationRecordingBackend {
    let handle = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    let revision = DictationTextRevision(rawText: "Grüße aus München.", text: "Grüße aus München.", sourceTranscriptIDs: [])
    var deliveries: [DictationDelivery] = []
    /// Microphone starts requested so far.
    private(set) var begins = 0

    func dictationBegin() async throws -> DictationRecordingHandle {
        begins += 1
        return handle
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {}
    func dictationResume(_ handle: DictationRecordingHandle) async throws {}
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision { revision }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? { nil }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        if let delivery { deliveries.append(delivery) }
    }
}
