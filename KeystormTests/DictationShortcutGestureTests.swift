import AppKit
import Foundation
import Testing
@testable import Keystorm

/// Raw `NSEvent.ModifierFlags` values as the keyboard reports them: the device-independent class bit plus the
/// device-dependent left/right bit.
private enum Raw {
    static let none: UInt = 0
    static let fn: UInt = 1 << 23
    static let leftShift: UInt = (1 << 17) | 0x02
    static let rightControl: UInt = (1 << 18) | 0x2000
    static let leftOption: UInt = (1 << 19) | 0x20
    static let rightOption: UInt = (1 << 19) | 0x40
    static let leftCommand: UInt = (1 << 20) | 0x08
    static let rightCommand: UInt = (1 << 20) | 0x10
}

/// Deadlines are sums of doubles, so compare them with a tolerance.
private func isNear(_ value: TimeInterval?, _ expected: TimeInterval) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < 1e-9
}

private let fnKey = ModifierKey.function.rawValue
private let rightOptionKey = ModifierKey.rightOption.rawValue
private let rightCommandKey = ModifierKey.rightCommand.rawValue
private let leftCommandKey = ModifierKey.leftCommand.rawValue
private let leftOptionKey = ModifierKey.leftOption.rawValue
private let leftShiftKey = ModifierKey.leftShift.rawValue

struct DictationGestureMachineTests {
    @Test func quickTapLatchesAndTheNextPressFinishes() {
        var machine = DictationGestureMachine(mode: .tapOrHold)
        #expect(machine.press(at: 10, isActive: false) == .start)
        #expect(machine.release(at: 10.1) == nil)
        #expect(machine.press(at: 15, isActive: true) == .finish)
        // The release of the finishing press must not do anything either.
        #expect(machine.release(at: 15.6) == nil)
        #expect(!machine.isKeyDown)
    }

    @Test func holdingPastTheThresholdFinishesOnRelease() {
        var machine = DictationGestureMachine(mode: .tapOrHold)
        #expect(machine.press(at: 10, isActive: false) == .start)
        #expect(machine.release(at: 10.8) == .finish)
    }

    @Test func thresholdIsInclusiveAndAdjustable() {
        var machine = DictationGestureMachine(mode: .tapOrHold, holdThreshold: 0.5)
        _ = machine.press(at: 0, isActive: false)
        #expect(machine.release(at: 0.49) == nil)
        _ = machine.press(at: 1, isActive: true)
        _ = machine.release(at: 1.1)
        _ = machine.press(at: 2, isActive: false)
        #expect(machine.release(at: 2.5) == .finish)
        #expect(DictationGestureMachine.defaultHoldThreshold == 0.3)
    }

    @Test func pushToTalkFinishesOnEveryRelease() {
        var machine = DictationGestureMachine(mode: .pushToTalk)
        #expect(machine.press(at: 1, isActive: false) == .start)
        #expect(machine.release(at: 1.01) == .finish)
        #expect(machine.press(at: 2, isActive: false) == .start)
        #expect(machine.release(at: 9) == .finish)
    }

    @Test func toggleIgnoresReleases() {
        var machine = DictationGestureMachine(mode: .toggle)
        #expect(machine.press(at: 1, isActive: false) == .start)
        #expect(machine.release(at: 30) == nil)
        #expect(machine.press(at: 31, isActive: true) == .finish)
        #expect(machine.release(at: 31.1) == nil)
    }

    @Test(arguments: [DictationShortcutMode.toggle, .pushToTalk, .tapOrHold])
    func pressWhileActiveFinishesAndSwallowsItsRelease(_ mode: DictationShortcutMode) {
        var machine = DictationGestureMachine(mode: mode)
        #expect(machine.press(at: 1, isActive: true) == .finish)
        #expect(machine.release(at: 5) == nil)
        // The next press after that starts again.
        #expect(machine.press(at: 6, isActive: false) == .start)
    }

    @Test func keyRepeatAndDuplicateEdgesAreIgnored() {
        var machine = DictationGestureMachine(mode: .tapOrHold)
        #expect(machine.press(at: 1, isActive: false) == .start)
        #expect(machine.press(at: 1.05, isActive: true) == nil)
        #expect(machine.press(at: 1.1, isActive: false) == nil)
        #expect(machine.release(at: 1.2) == nil)
        #expect(machine.release(at: 1.3) == nil)
    }

    @Test func resetForgetsAHeldKey() {
        var machine = DictationGestureMachine(mode: .pushToTalk)
        _ = machine.press(at: 1, isActive: false)
        machine.reset()
        #expect(!machine.isKeyDown)
        #expect(machine.release(at: 5) == nil)
    }

    @Test func aNonMonotonicClockCountsAsATap() {
        var machine = DictationGestureMachine(mode: .tapOrHold)
        _ = machine.press(at: 100, isActive: false)
        #expect(machine.release(at: 50) == nil)
    }
}

struct ModifierKeyDecodingTests {
    @Test func deviceBitsTellLeftFromRight() {
        #expect(ModifierKey.down(in: Raw.rightOption, eventKeyCode: rightOptionKey) == [.rightOption])
        #expect(ModifierKey.down(in: Raw.leftOption, eventKeyCode: leftOptionKey) == [.leftOption])
        #expect(ModifierKey.down(in: Raw.leftOption | Raw.rightOption, eventKeyCode: rightOptionKey) == [.leftOption, .rightOption])
        #expect(ModifierKey.down(in: Raw.rightCommand | Raw.leftShift, eventKeyCode: leftShiftKey) == [.rightCommand, .leftShift])
        #expect(ModifierKey.down(in: Raw.rightControl, eventKeyCode: ModifierKey.rightControl.rawValue) == [.rightControl])
        #expect(ModifierKey.down(in: Raw.fn, eventKeyCode: fnKey) == [.function])
        #expect(ModifierKey.down(in: Raw.none, eventKeyCode: fnKey).isEmpty)
    }

    @Test func withoutDeviceBitsOnlyTheEventKeyIsAttributed() {
        #expect(ModifierKey.down(in: 1 << 19, eventKeyCode: rightOptionKey) == [.rightOption])
        #expect(ModifierKey.down(in: 1 << 20, eventKeyCode: leftCommandKey) == [.leftCommand])
        // A key whose class bit is already clear was released.
        #expect(ModifierKey.down(in: 0, eventKeyCode: rightOptionKey).isEmpty)
    }

    @Test func everyKeyHasADistinctCodeAndLabel() {
        #expect(Set(ModifierKey.allCases.map(\.rawValue)).count == ModifierKey.allCases.count)
        #expect(Set(ModifierKey.allCases.map(\.label)).count == ModifierKey.allCases.count)
        #expect(!ModifierKey.leftShift.isAllowedAlone && !ModifierKey.rightShift.isAllowedAlone)
        #expect(ModifierKey.allCases.filter(\.isAllowedAlone).count == ModifierKey.allCases.count - 2)
    }
}

struct ModifierOnlyDetectorTests {
    @Test func aQuickTapIsReportedAtReleaseAsPressAndRelease() {
        var detector = ModifierOnlyDetector(target: .function)
        #expect(detector.flagsChanged(keyCode: fnKey, rawFlags: Raw.fn, at: 1.0).isEmpty)
        #expect(isNear(detector.deadline, 1.15))
        #expect(detector.flagsChanged(keyCode: fnKey, rawFlags: Raw.none, at: 1.05)
                == [.pressed(at: 1.0), .released(at: 1.05)])
        #expect(detector.deadline == nil)
    }

    @Test func aHoldConfirmsAfterTheDelayWithThePhysicalPressTime() {
        var detector = ModifierOnlyDetector(target: .rightCommand)
        _ = detector.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.rightCommand, at: 4.0)
        #expect(detector.advance(now: 4.1).isEmpty)
        #expect(detector.advance(now: 4.15) == [.pressed(at: 4.0)])
        // Confirmed once only.
        #expect(detector.advance(now: 5).isEmpty)
        #expect(detector.deadline == nil)
        #expect(detector.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.none, at: 6.0) == [.released(at: 6.0)])
    }

    @Test func aKeyPressedWhileWaitingMakesItAChord() {
        // Cmd+C: right Command goes down, then C, then both come up.
        var detector = ModifierOnlyDetector(target: .rightCommand)
        _ = detector.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.rightCommand, at: 1.0)
        detector.otherInput(at: 1.05)
        #expect(detector.deadline == nil)
        #expect(detector.advance(now: 5).isEmpty)
        #expect(detector.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.none, at: 1.2).isEmpty)
        // The next lone tap works again.
        _ = detector.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.rightCommand, at: 3.0)
        #expect(detector.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.none, at: 3.05)
                == [.pressed(at: 3.0), .released(at: 3.05)])
    }

    @Test func aClickWhileWaitingMakesItAChord() {
        var detector = ModifierOnlyDetector(target: .rightOption)
        _ = detector.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.rightOption, at: 1.0)
        detector.otherInput(at: 1.02)
        #expect(detector.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.none, at: 1.3).isEmpty)
    }

    @Test func aSecondModifierWhileWaitingMakesItAChord() {
        var detector = ModifierOnlyDetector(target: .rightCommand)
        _ = detector.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.rightCommand, at: 1.0)
        _ = detector.flagsChanged(keyCode: leftShiftKey, rawFlags: Raw.rightCommand | Raw.leftShift, at: 1.04)
        #expect(detector.advance(now: 5).isEmpty)
        #expect(detector.flagsChanged(keyCode: leftShiftKey, rawFlags: Raw.rightCommand, at: 1.1).isEmpty)
        #expect(detector.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.none, at: 1.2).isEmpty)
    }

    @Test func aModifierAlreadyHeldRejectsThePress() {
        var detector = ModifierOnlyDetector(target: .rightOption)
        // Left Command is down first; it is not the target, so it arms nothing.
        #expect(detector.flagsChanged(keyCode: leftCommandKey, rawFlags: Raw.leftCommand, at: 1.0).isEmpty)
        #expect(detector.deadline == nil)
        #expect(detector.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.leftCommand | Raw.rightOption, at: 1.1).isEmpty)
        #expect(detector.deadline == nil)
        #expect(detector.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.leftCommand, at: 1.2).isEmpty)
        _ = detector.flagsChanged(keyCode: leftCommandKey, rawFlags: Raw.none, at: 1.3)
        // After everything is up, a lone tap is a tap.
        _ = detector.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.rightOption, at: 2.0)
        #expect(detector.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.none, at: 2.05)
                == [.pressed(at: 2.0), .released(at: 2.05)])
    }

    @Test func aChordAfterConfirmationDoesNotBreakAHold() {
        var detector = ModifierOnlyDetector(target: .function)
        _ = detector.flagsChanged(keyCode: fnKey, rawFlags: Raw.fn, at: 1.0)
        #expect(detector.advance(now: 1.2) == [.pressed(at: 1.0)])
        detector.otherInput(at: 1.5)
        _ = detector.flagsChanged(keyCode: leftShiftKey, rawFlags: Raw.fn | Raw.leftShift, at: 1.6)
        #expect(detector.flagsChanged(keyCode: leftShiftKey, rawFlags: Raw.fn, at: 1.7).isEmpty)
        #expect(detector.flagsChanged(keyCode: fnKey, rawFlags: Raw.none, at: 2.0) == [.released(at: 2.0)])
    }

    @Test func theOtherSideOfTheSameModifierIsNotTheTarget() {
        var detector = ModifierOnlyDetector(target: .rightOption)
        #expect(detector.flagsChanged(keyCode: leftOptionKey, rawFlags: Raw.leftOption, at: 1.0).isEmpty)
        #expect(detector.deadline == nil)
        #expect(detector.flagsChanged(keyCode: leftOptionKey, rawFlags: Raw.none, at: 1.05).isEmpty)
    }

    @Test func leftHeldBeforeRightMakesAChord() {
        var detector = ModifierOnlyDetector(target: .rightOption)
        _ = detector.flagsChanged(keyCode: leftOptionKey, rawFlags: Raw.leftOption, at: 1.0)
        // Right Option goes down while left is held: a chord, nothing is reported.
        _ = detector.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.leftOption | Raw.rightOption, at: 1.1)
        #expect(detector.advance(now: 3).isEmpty)
        _ = detector.flagsChanged(keyCode: leftOptionKey, rawFlags: Raw.rightOption, at: 1.2)
        #expect(detector.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.none, at: 1.3).isEmpty)
    }

    @Test func theFunctionBitDoesNotRejectOtherTargets() {
        // Arrow and function keys set the function bit; only Fn itself cares about it.
        var detector = ModifierOnlyDetector(target: .rightOption)
        _ = detector.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.rightOption | Raw.fn, at: 1.0)
        #expect(isNear(detector.deadline, 1.15))
        #expect(detector.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.fn, at: 1.05)
                == [.pressed(at: 1.0), .released(at: 1.05)])
    }

    @Test func aKeyThatWasAlreadyDownIsIgnoredUntilReleased() {
        var detector = ModifierOnlyDetector(target: .rightOption)
        // The target bit is set but the event is about another key, as after a reset while the key is held.
        #expect(detector.flagsChanged(keyCode: leftCommandKey, rawFlags: Raw.rightOption | Raw.leftCommand, at: 1.0).isEmpty)
        #expect(detector.deadline == nil)
    }

    @Test func sourcesWithoutDeviceBitsStillWorkForTheEventKey() {
        var detector = ModifierOnlyDetector(target: .rightOption)
        _ = detector.flagsChanged(keyCode: rightOptionKey, rawFlags: 1 << 19, at: 1.0)
        #expect(isNear(detector.deadline, 1.15))
        #expect(detector.flagsChanged(keyCode: rightOptionKey, rawFlags: 0, at: 1.05)
                == [.pressed(at: 1.0), .released(at: 1.05)])
    }

    @Test func retargetAndResetDropAHeldKey() {
        var detector = ModifierOnlyDetector(target: .function)
        _ = detector.flagsChanged(keyCode: fnKey, rawFlags: Raw.fn, at: 1.0)
        detector.reset()
        #expect(detector.deadline == nil)
        #expect(detector.flagsChanged(keyCode: fnKey, rawFlags: Raw.none, at: 1.1).isEmpty)
        _ = detector.flagsChanged(keyCode: fnKey, rawFlags: Raw.fn, at: 2.0)
        detector.retarget(.rightCommand)
        #expect(detector.target == .rightCommand)
        #expect(detector.deadline == nil)
    }

    @Test func confirmationDelayIsConfigurable() {
        var detector = ModifierOnlyDetector(target: .function, confirmDelay: 0.4)
        _ = detector.flagsChanged(keyCode: fnKey, rawFlags: Raw.fn, at: 1.0)
        #expect(isNear(detector.deadline, 1.4))
        #expect(detector.advance(now: 1.3).isEmpty)
        #expect(detector.advance(now: 1.41) == [.pressed(at: 1.0)])
    }
}

struct ModifierOnlyRecorderTests {
    @Test func aLoneTapReturnsItsKeyAtRelease() {
        var recorder = ModifierOnlyRecorder()
        #expect(recorder.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.rightOption) == nil)
        #expect(recorder.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.none) == .rightOption)
        #expect(recorder.flagsChanged(keyCode: fnKey, rawFlags: Raw.fn) == nil)
        #expect(recorder.flagsChanged(keyCode: fnKey, rawFlags: Raw.none) == .function)
    }

    @Test func aKeyInBetweenSpoilsTheTap() {
        var recorder = ModifierOnlyRecorder()
        _ = recorder.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.rightCommand)
        recorder.otherInput()
        #expect(recorder.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.none) == nil)
    }

    @Test func twoModifiersSpoilTheTapEvenIfOneIsReleasedFirst() {
        var recorder = ModifierOnlyRecorder()
        _ = recorder.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.rightCommand)
        _ = recorder.flagsChanged(keyCode: leftShiftKey, rawFlags: Raw.rightCommand | Raw.leftShift)
        _ = recorder.flagsChanged(keyCode: leftShiftKey, rawFlags: Raw.rightCommand)
        #expect(recorder.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.none) == nil)
    }

    @Test func aKeyWithNoModifierDownDoesNotSpoilTheNextTap() {
        var recorder = ModifierOnlyRecorder()
        recorder.otherInput()
        _ = recorder.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.rightOption)
        #expect(recorder.flagsChanged(keyCode: rightOptionKey, rawFlags: Raw.none) == .rightOption)
    }

    @Test func aRecorderRecoversAfterASpoiledGesture() {
        var recorder = ModifierOnlyRecorder()
        _ = recorder.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.rightCommand)
        recorder.otherInput()
        _ = recorder.flagsChanged(keyCode: rightCommandKey, rawFlags: Raw.none)
        _ = recorder.flagsChanged(keyCode: rightControlKey, rawFlags: Raw.rightControl)
        #expect(recorder.flagsChanged(keyCode: rightControlKey, rawFlags: Raw.none) == .rightControl)
    }
}

private let rightControlKey = ModifierKey.rightControl.rawValue

// MARK: Shortcut validation and persistence

struct ModifierOnlyShortcutValueTests {
    @Test func aSingleModifierIsAValidShortcutWithAReadableName() throws {
        for key in ModifierKey.allCases where key.isAllowedAlone {
            let shortcut = GlobalShortcut(modifierKey: key)
            try shortcut.validate()
            #expect(shortcut.isModifierOnly)
            #expect(shortcut.modifierKey == key)
            #expect(shortcut.displayName == key.label)
        }
        #expect(GlobalShortcut(modifierKey: .rightOption).displayName == "Right ⌥")
        #expect(GlobalShortcut(modifierKey: .function).displayName == "Fn")
    }

    @Test func shiftAloneIsRejected() {
        #expect(throws: ShortcutError.self) { try GlobalShortcut(modifierKey: .leftShift).validate() }
        #expect(throws: ShortcutError.self) { try GlobalShortcut(modifierKey: .rightShift).validate() }
    }

    @Test func aModifierKeyWithOtherModifiersOrAPlainKeyIsNotModifierOnly() {
        #expect(!GlobalShortcut(keyCode: 61, modifiers: [.command], keyLabel: "Right ⌥").isModifierOnly)
        #expect(!GlobalShortcut(keyCode: 0, modifiers: [], keyLabel: "A").isModifierOnly)
        // Caps Lock toggles state rather than reporting a press, so it is not offered.
        #expect(!GlobalShortcut(keyCode: 57, modifiers: [], keyLabel: "Caps Lock").isModifierOnly)
        #expect(throws: ShortcutError.self) {
            try GlobalShortcut(keyCode: 57, modifiers: [], keyLabel: "Caps Lock").validate()
        }
        #expect(throws: ShortcutError.self) {
            try GlobalShortcut(keyCode: 61, modifiers: [.command], keyLabel: "Right ⌥").validate()
        }
    }

    @Test func aModifierOnlyShortcutSurvivesEncoding() throws {
        let shortcut = GlobalShortcut(modifierKey: .rightCommand)
        let decoded = try JSONDecoder().decode(GlobalShortcut.self, from: JSONEncoder().encode(shortcut))
        #expect(decoded == shortcut)
        #expect(decoded.modifierKey == .rightCommand)
    }

    @Test func aFreshInstallBindsNoDeveloperBriefShortcut() {
        let defaults = ShortcutPreferences.defaults.shortcuts
        #expect(defaults[ShortcutAction.toggleRecording.rawValue] == nil)
        #expect(defaults[ShortcutAction.recordEdit.rawValue] == nil)
        #expect(defaults[ShortcutAction.toggleDictation.rawValue] != nil)
        #expect(defaults[ShortcutAction.pauseResumeDictation.rawValue] != nil)
        #expect(defaults[ShortcutAction.showWorkspace.rawValue] != nil)
    }

    @Test func dictationShortcutModesHaveDistinctTitles() {
        #expect(Set(DictationShortcutMode.allCases.map { String(localized: $0.title) }).count == 3)
    }
}

// MARK: ShortcutManager

@MainActor
private final class FakeModifierMonitor: ModifierShortcutMonitoring {
    var onOutput: (@MainActor (ModifierOnlyDetector.Output) -> Void)?
    var result: ModifierMonitorStatus = .active
    private(set) var startedKeys: [ModifierKey] = []
    private(set) var stops = 0
    private(set) var resets = 0
    func start(key: ModifierKey) -> ModifierMonitorStatus { startedKeys.append(key); return result }
    func stop() { stops += 1 }
    func reset() { resets += 1 }
    func emit(_ output: ModifierOnlyDetector.Output) { onOutput?(output) }
}

@MainActor
private func makeDefaults() throws -> (UserDefaults, String) {
    let suite = "Keystorm.GestureTests.\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DictationShortcutManagerTests {
    @Test func theModeDefaultsToTapOrHoldAndPersists() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults, modifierMonitor: FakeModifierMonitor())
        #expect(manager.dictationShortcutMode == .tapOrHold)
        manager.setDictationShortcutMode(.pushToTalk)
        #expect(manager.dictationShortcutMode == .pushToTalk)
        #expect(ShortcutManager(defaults: defaults, modifierMonitor: FakeModifierMonitor()).dictationShortcutMode == .pushToTalk)
        defaults.set("not a mode", forKey: "Keystorm.dictationShortcutMode.v1")
        #expect(ShortcutManager(defaults: defaults, modifierMonitor: FakeModifierMonitor()).dictationShortcutMode == .tapOrHold)
    }

    @Test func aTapOnTheCarbonKeyStartsAndAHoldStartsThenFinishes() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults, modifierMonitor: FakeModifierMonitor())
        var commands: [DictationGestureCommand] = []
        manager.onDictationCommand = { commands.append($0) }
        let base = DispatchTime.now().uptimeNanoseconds
        manager.handleShortcut(.toggleDictation, pressed: true, enqueuedAt: base)
        manager.handleShortcut(.toggleDictation, pressed: false, enqueuedAt: base + 100_000_000)
        #expect(commands == [.start])
        manager.handleShortcut(.toggleDictation, pressed: true, enqueuedAt: base + 2_000_000_000)
        manager.handleShortcut(.toggleDictation, pressed: false, enqueuedAt: base + 2_800_000_000)
        #expect(commands == [.start, .start, .finish])
        #expect(manager.dispatchCount == 3)
    }

    @Test func aPressWhileDictatingFinishesInEveryMode() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults, modifierMonitor: FakeModifierMonitor())
        var commands: [DictationGestureCommand] = []
        manager.onDictationCommand = { commands.append($0) }
        manager.isDictationActive = { true }
        let base = DispatchTime.now().uptimeNanoseconds
        for mode in DictationShortcutMode.allCases {
            manager.setDictationShortcutMode(mode)
            commands.removeAll()
            manager.handleShortcut(.toggleDictation, pressed: true, enqueuedAt: base)
            manager.handleShortcut(.toggleDictation, pressed: false, enqueuedAt: base + 50_000_000)
            #expect(commands == [.finish], "mode \(mode.rawValue)")
        }
    }

    @Test func withoutAReceiverEveryCommandFallsBackToTheToggleAction() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults, modifierMonitor: FakeModifierMonitor())
        var actions: [ShortcutAction] = []
        manager.onAction = { actions.append($0) }
        let base = DispatchTime.now().uptimeNanoseconds
        manager.handleShortcut(.toggleDictation, pressed: true, enqueuedAt: base)
        manager.handleShortcut(.toggleDictation, pressed: false, enqueuedAt: base + 700_000_000)
        #expect(actions == [.toggleDictation, .toggleDictation])
    }

    @Test func suspendingForCaptureForgetsAHeldKey() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults, modifierMonitor: FakeModifierMonitor())
        var commands: [DictationGestureCommand] = []
        manager.onDictationCommand = { commands.append($0) }
        manager.setDictationShortcutMode(.pushToTalk)
        let base = DispatchTime.now().uptimeNanoseconds
        manager.handleShortcut(.toggleDictation, pressed: true, enqueuedAt: base)
        manager.suspendForShortcutCapture(true)
        manager.handleShortcut(.toggleDictation, pressed: false, enqueuedAt: base + 500_000_000)
        #expect(commands == [.start])
        manager.cancelDictationGesture()
        manager.suspendForShortcutCapture(false)
    }

    @Test func aModifierOnlyShortcutUsesTheMonitorAndNeverCarbon() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = FakeModifierMonitor()
        var carbonCalls = 0
        let manager = ShortcutManager(defaults: defaults, registerOperation: { _, _, _ in
            carbonCalls += 1
            return -9878
        }, modifierMonitor: monitor)
        for action in ShortcutAction.allCases { try manager.setShortcut(nil, for: action) }
        try manager.setShortcut(GlobalShortcut(modifierKey: .rightOption), for: .toggleDictation)
        manager.start()
        defer { manager.stop() }
        #expect(carbonCalls == 0)
        #expect(monitor.startedKeys == [.rightOption])
        #expect(manager.registration[.toggleDictation] == .registered)
        #expect(manager.modifierMonitorStatus == .active)
        // Persisted like any other shortcut.
        let relaunched = ShortcutManager(defaults: defaults, modifierMonitor: FakeModifierMonitor())
        #expect(relaunched.shortcut(for: .toggleDictation)?.modifierKey == .rightOption)
        // Changing it live moves the monitor, and clearing it stops the monitor.
        try manager.setShortcut(GlobalShortcut(modifierKey: .function), for: .toggleDictation)
        #expect(monitor.startedKeys == [.rightOption, .function])
        let stopsBeforeClear = monitor.stops
        try manager.setShortcut(nil, for: .toggleDictation)
        #expect(monitor.stops > stopsBeforeClear)
        #expect(manager.modifierMonitorStatus == .inactive)
        #expect(manager.registration[.toggleDictation] == .disabled)
    }

    @Test func monitorEdgesDriveTheGestureCommands() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = FakeModifierMonitor()
        let manager = ShortcutManager(defaults: defaults, registerOperation: { _, _, _ in -1 }, modifierMonitor: monitor)
        for action in ShortcutAction.allCases { try manager.setShortcut(nil, for: action) }
        try manager.setShortcut(GlobalShortcut(modifierKey: .function), for: .toggleDictation)
        manager.start()
        defer { manager.stop() }
        var commands: [DictationGestureCommand] = []
        manager.onDictationCommand = { commands.append($0) }
        var active = false
        manager.isDictationActive = { active }
        // A tap latches.
        monitor.emit(.pressed(at: 1.0)); monitor.emit(.released(at: 1.05))
        #expect(commands == [.start])
        // The next tap finishes it.
        active = true
        monitor.emit(.pressed(at: 3.0)); monitor.emit(.released(at: 3.05))
        #expect(commands == [.start, .finish])
        // A hold records while held.
        active = false
        monitor.emit(.pressed(at: 5.0)); monitor.emit(.released(at: 6.0))
        #expect(commands == [.start, .finish, .start, .finish])
    }

    @Test func monitorEdgesAreIgnoredWhileSuspendedOrStopped() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = FakeModifierMonitor()
        let manager = ShortcutManager(defaults: defaults, registerOperation: { _, _, _ in -1 }, modifierMonitor: monitor)
        for action in ShortcutAction.allCases { try manager.setShortcut(nil, for: action) }
        try manager.setShortcut(GlobalShortcut(modifierKey: .function), for: .toggleDictation)
        var commands: [DictationGestureCommand] = []
        manager.onDictationCommand = { commands.append($0) }
        // Not started: nothing is delivered.
        monitor.emit(.pressed(at: 1)); monitor.emit(.released(at: 1.05))
        #expect(commands.isEmpty)
        manager.start()
        manager.suspendForShortcutCapture(true)
        monitor.emit(.pressed(at: 2)); monitor.emit(.released(at: 2.05))
        #expect(commands.isEmpty)
        manager.suspendForShortcutCapture(false)
        monitor.emit(.pressed(at: 3)); monitor.emit(.released(at: 3.05))
        #expect(commands == [.start])
        manager.stop()
        monitor.emit(.pressed(at: 4)); monitor.emit(.released(at: 4.05))
        #expect(commands == [.start])
    }

    @Test func anUnavailableMonitorIsReportedAndRetryRecovers() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = FakeModifierMonitor()
        monitor.result = .unavailable("Needs Accessibility.")
        let manager = ShortcutManager(defaults: defaults, registerOperation: { _, _, _ in -1 }, modifierMonitor: monitor)
        for action in ShortcutAction.allCases { try manager.setShortcut(nil, for: action) }
        try manager.setShortcut(GlobalShortcut(modifierKey: .rightCommand), for: .toggleDictation)
        manager.start()
        defer { manager.stop() }
        #expect(manager.registration[.toggleDictation] == .unavailable("Needs Accessibility."))
        #expect(manager.modifierMonitorStatus == .unavailable("Needs Accessibility."))
        // Edges from an unavailable registration never act.
        var commands: [DictationGestureCommand] = []
        manager.onDictationCommand = { commands.append($0) }
        monitor.emit(.pressed(at: 1)); monitor.emit(.released(at: 1.05))
        #expect(commands.isEmpty)
        monitor.result = .active
        manager.retryRegistration()
        #expect(manager.registration[.toggleDictation] == .registered)
        #expect(manager.modifierMonitorStatus == .active)
    }

    @Test func onlyTheDictationShortcutCanBeASingleModifier() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults, modifierMonitor: FakeModifierMonitor())
        for action in ShortcutAction.allCases where action != .toggleDictation {
            #expect(throws: ShortcutError.self) {
                try manager.setShortcut(GlobalShortcut(modifierKey: .function), for: action)
            }
            #expect(manager.shortcut(for: action)?.isModifierOnly != true)
        }
        #expect(throws: ShortcutError.self) {
            try manager.setShortcut(GlobalShortcut(modifierKey: .leftShift), for: .toggleDictation)
        }
        try manager.setShortcut(GlobalShortcut(modifierKey: .function), for: .toggleDictation)
        #expect(manager.shortcut(for: .toggleDictation)?.modifierKey == .function)
    }

    @Test func savedBriefShortcutsOfExistingUsersAreUntouched() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = GlobalShortcut(keyCode: 49, modifiers: [.command, .shift], keyLabel: "Space")
        let edit = GlobalShortcut(keyCode: 14, modifiers: [.command, .option, .shift], keyLabel: "E")
        let saved = ShortcutPreferences(version: 2, shortcuts: [
            ShortcutAction.toggleRecording.rawValue: record,
            ShortcutAction.recordEdit.rawValue: edit
        ])
        defaults.set(try JSONEncoder().encode(saved), forKey: "Keystorm.globalShortcuts.v1")
        let manager = ShortcutManager(defaults: defaults, modifierMonitor: FakeModifierMonitor())
        #expect(manager.shortcut(for: .toggleRecording) == record)
        #expect(manager.shortcut(for: .recordEdit) == edit)
        let (fresh, freshSuite) = try makeDefaults()
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        let freshManager = ShortcutManager(defaults: fresh, modifierMonitor: FakeModifierMonitor())
        #expect(freshManager.shortcut(for: .toggleRecording) == nil)
        #expect(freshManager.shortcut(for: .recordEdit) == nil)
    }
}

// MARK: AppInteractionController: hold-to-talk and Escape

@MainActor
private final class FakeEscapeWatcher: EscapeKeyWatching {
    var onEscape: (@MainActor () -> Void)?
    private(set) var isActive = false
    private(set) var activations = 0
    func setActive(_ active: Bool) -> Bool {
        if active && !isActive { activations += 1 }
        isActive = active
        return true
    }
    /// What the system does: Escape reaches the app only while the hotkey exists.
    func press() { if isActive { onEscape?() } }
}

@MainActor
private final class GestureLegacyRecorder: LegacyRecordingBackend {
    var isRecording = false
    var isCaptureTransitioning = false
    var captureIntent: CaptureIntent = .editBrief
    var openTake: BriefTake?
    var hasOpenTake: Bool { openTake != nil }
    func startRecording() async {}
    func pauseRecording() async {}
    func resumeRecording() async {}
    func startNewTake(intent: CaptureIntent?) async {}
}

@MainActor
private final class GestureDictationBackend: DictationRecordingBackend {
    enum Failure: Error { case unsupported }
    let handle = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    func dictationBegin() async throws -> DictationRecordingHandle { handle }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {}
    func dictationResume(_ handle: DictationRecordingHandle) async throws {}
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        DictationTextRevision(rawText: "Hallo world.", text: "Hallo world.", sourceTranscriptIDs: [])
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? { nil }
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode) async throws -> DictationTransformResult {
        throw Failure.unsupported
    }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {}
}

@MainActor
private struct GestureUntrustedAdapter: DictationDeliveryAdapter {
    var isTrusted: Bool { false }
    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { nil }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField {
        throw GestureDictationBackend.Failure.unsupported
    }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { false }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        throw GestureDictationBackend.Failure.unsupported
    }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        throw GestureDictationBackend.Failure.unsupported
    }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        .rejected
    }
}

/// A controller wired to a private defaults suite, a fake backend, a private pasteboard and a fake Escape hotkey.
@MainActor
private struct GestureRig {
    let suite: String
    let defaults: UserDefaults
    let workspace: WorkspaceModel
    let manager: ShortcutManager
    let flow: DictationCoordinator
    let controller: AppInteractionController
    let escape = FakeEscapeWatcher()
    let base = DispatchTime.now().uptimeNanoseconds

    init() throws {
        suite = "Keystorm.GestureRig.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        workspace = WorkspaceModel(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-Gesture-" + UUID().uuidString))
        manager = ShortcutManager(defaults: defaults, modifierMonitor: FakeModifierMonitor())
        flow = DictationCoordinator(backend: GestureDictationBackend(),
            delivery: DictationDeliveryService(adapter: GestureUntrustedAdapter()))
        // Never touch the user's clipboard.
        flow.preferences.copyWhenNotInserted = false
        flow.pasteboard = NSPasteboard.withUniqueName()
        controller = AppInteractionController(shortcuts: manager)
        controller.escapeWatcher = escape
        controller.configure(workspace: workspace, showWorkspace: {}, dictation: flow,
                             legacyRecording: GestureLegacyRecorder(), startShortcuts: false)
    }

    /// The dictation key goes down or up `seconds` after the rig's start.
    func key(_ pressed: Bool, at seconds: Double) {
        manager.handleShortcut(.toggleDictation, pressed: pressed, enqueuedAt: base + UInt64(seconds * 1_000_000_000))
    }

    func close() async {
        await controller.shutdown()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DictationHoldToTalkTests {
    @Test func holdingTheShortcutRecordsOnlyWhileHeld() async throws {
        let rig = try GestureRig()
        rig.key(true, at: 0)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .recording)
        rig.key(false, at: 0.8)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .ready)
        await rig.close()
    }

    @Test func aQuickTapLatchesRecordingUntilTheNextPress() async throws {
        let rig = try GestureRig()
        rig.key(true, at: 0)
        await rig.flow.waitUntilSettled()
        rig.key(false, at: 0.1)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .recording)
        rig.key(true, at: 3)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .ready)
        // The finishing press's release changes nothing.
        rig.key(false, at: 3.05)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .ready)
        await rig.close()
    }

    @Test func releasingWhileTheMicrophoneOpensFinishesOnceRecordingBegins() async throws {
        let rig = try GestureRig()
        rig.manager.setDictationShortcutMode(.pushToTalk)
        rig.key(true, at: 0)
        // Released before the start task ran: state is still starting.
        #expect(rig.flow.state == .starting)
        rig.key(false, at: 0.05)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .ready)
        await rig.close()
    }

    @Test func pushToTalkFinishesOnEveryRelease() async throws {
        let rig = try GestureRig()
        rig.manager.setDictationShortcutMode(.pushToTalk)
        rig.key(true, at: 0)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .recording)
        rig.key(false, at: 0.1)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .ready)
        await rig.close()
    }

    @Test func toggleModeIgnoresTheRelease() async throws {
        let rig = try GestureRig()
        rig.manager.setDictationShortcutMode(.toggle)
        rig.key(true, at: 0)
        await rig.flow.waitUntilSettled()
        rig.key(false, at: 5)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .recording)
        rig.key(true, at: 6)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .ready)
        await rig.close()
    }

    @Test func aReleaseWithNoTakeNeverStartsOne() async throws {
        let rig = try GestureRig()
        rig.manager.setDictationShortcutMode(.pushToTalk)
        rig.key(false, at: 1)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .idle)
        await rig.close()
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DictationEscapeCancelTests {
    @Test func escapeIsWatchedOnlyWhileADictationIsStartingRecordingOrPaused() async throws {
        let rig = try GestureRig()
        rig.controller.syncEscapeWatcher()
        #expect(!rig.escape.isActive)
        rig.key(true, at: 0)
        #expect(rig.flow.state == .starting)
        rig.controller.syncEscapeWatcher()
        #expect(rig.escape.isActive)
        await rig.flow.waitUntilSettled()
        rig.key(false, at: 0.1)
        rig.controller.syncEscapeWatcher()
        #expect(rig.escape.isActive)
        rig.flow.pauseResume()
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .paused)
        rig.controller.syncEscapeWatcher()
        #expect(rig.escape.isActive)
        rig.key(true, at: 5)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .ready)
        rig.controller.syncEscapeWatcher()
        #expect(!rig.escape.isActive)
        await rig.close()
    }

    @Test func escapeCancelsARecordingAndKeepsTheKeyReleaseFromFinishing() async throws {
        let rig = try GestureRig()
        rig.key(true, at: 0)
        await rig.flow.waitUntilSettled()
        rig.controller.syncEscapeWatcher()
        #expect(rig.flow.state == .recording)
        rig.escape.press()
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .idle)
        rig.controller.syncEscapeWatcher()
        #expect(!rig.escape.isActive)
        // The user lets go of the held key after cancelling; that must not finish or restart anything.
        rig.key(false, at: 2)
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .idle)
        await rig.close()
    }

    @Test func escapeCancelsAPausedDictation() async throws {
        let rig = try GestureRig()
        rig.key(true, at: 0)
        await rig.flow.waitUntilSettled()
        rig.key(false, at: 0.1)
        rig.flow.pauseResume()
        await rig.flow.waitUntilSettled()
        rig.controller.syncEscapeWatcher()
        #expect(rig.flow.state == .paused)
        rig.escape.press()
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .idle)
        await rig.close()
    }

    @Test func escapeWhileIdleDoesNothingEvenIfDeliveredByMistake() async throws {
        let rig = try GestureRig()
        rig.controller.syncEscapeWatcher()
        // The watcher is off, so the system would not deliver Escape; a stray callback is still harmless.
        rig.escape.onEscape?()
        await rig.flow.waitUntilSettled()
        #expect(rig.flow.state == .idle)
        #expect(rig.escape.activations == 0)
        await rig.close()
    }

    @Test func shuttingDownReleasesEscape() async throws {
        let rig = try GestureRig()
        rig.key(true, at: 0)
        await rig.flow.waitUntilSettled()
        rig.controller.syncEscapeWatcher()
        #expect(rig.escape.isActive)
        await rig.controller.shutdown()
        #expect(!rig.escape.isActive)
        rig.defaults.removePersistentDomain(forName: rig.suite)
    }
}
