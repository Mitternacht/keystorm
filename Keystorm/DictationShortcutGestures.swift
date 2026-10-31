import Foundation

/// How the dictation shortcut behaves. `ShortcutManager` stores it; `tapOrHold` matches superwhisper's default.
enum DictationShortcutMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Each press starts or finishes. Releasing does nothing.
    case toggle
    /// Recording lasts only while the shortcut is held.
    case pushToTalk
    /// A quick tap starts recording and stays on until the next press. Holding past the threshold records only while held.
    case tapOrHold

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .toggle: "Press to start and finish"
        case .pushToTalk: "Hold to talk"
        case .tapOrHold: "Tap to toggle, hold to talk"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .toggle: "Press the shortcut to start dictating, and press it again to finish."
        case .pushToTalk: "Dictation records while you hold the shortcut and finishes when you let go."
        case .tapOrHold: "A quick tap starts dictation and the next press finishes it. Hold the shortcut to record only while it is held."
        }
    }
}

/// What the gesture machine asks the dictation flow to do.
enum DictationGestureCommand: Equatable, Sendable {
    case start, finish
}

/// Turns raw shortcut press and release edges into start and finish commands.
///
/// Pure value type: time is passed in, so tests can drive tap and hold without a clock. A press while dictation is
/// already active always finishes it (the toggle half of every mode) and swallows its own release.
struct DictationGestureMachine: Equatable, Sendable {
    /// Holding at least this long makes a press push-to-talk instead of a tap.
    static let defaultHoldThreshold: TimeInterval = 0.3

    var mode: DictationShortcutMode
    var holdThreshold: TimeInterval

    private enum Phase: Equatable {
        case up
        /// The key is down and this press started the recording.
        case down(since: TimeInterval)
        /// The key is down and its release must do nothing.
        case consumed
    }
    private var phase: Phase = .up

    init(mode: DictationShortcutMode = .tapOrHold, holdThreshold: TimeInterval = DictationGestureMachine.defaultHoldThreshold) {
        self.mode = mode
        self.holdThreshold = holdThreshold
    }

    var isKeyDown: Bool { phase != .up }

    /// `isActive` is true while a dictation is starting, recording or paused.
    mutating func press(at time: TimeInterval, isActive: Bool) -> DictationGestureCommand? {
        // Key repeat or a duplicate edge: the key is already down.
        guard phase == .up else { return nil }
        if isActive {
            phase = .consumed
            return .finish
        }
        phase = mode == .toggle ? .consumed : .down(since: time)
        return .start
    }

    mutating func release(at time: TimeInterval) -> DictationGestureCommand? {
        let previous = phase
        phase = .up
        guard case .down(let since) = previous else { return nil }
        switch mode {
        case .toggle: return nil
        case .pushToTalk: return .finish
        case .tapOrHold: return time - since >= holdThreshold ? .finish : nil
        }
    }

    /// Forgets a key that is held. Used when the shortcut is rebound, suspended or cancelled by Escape.
    mutating func reset() { phase = .up }
}

/// A physical modifier key, identified by its key code, for shortcuts made of one modifier alone.
enum ModifierKey: UInt16, CaseIterable, Codable, Sendable {
    case rightCommand = 54
    case leftCommand = 55
    case leftShift = 56
    case leftOption = 58
    case leftControl = 59
    case rightShift = 60
    case rightOption = 61
    case rightControl = 62
    case function = 63

    var label: String {
        switch self {
        case .rightCommand: "Right ⌘"
        case .leftCommand: "Left ⌘"
        case .leftShift: "Left ⇧"
        case .rightShift: "Right ⇧"
        case .leftOption: "Left ⌥"
        case .rightOption: "Right ⌥"
        case .leftControl: "Left ⌃"
        case .rightControl: "Right ⌃"
        case .function: "Fn"
        }
    }

    /// Shift taps are everyday typing, so shift alone is never offered as a shortcut.
    var isAllowedAlone: Bool { self != .leftShift && self != .rightShift }

    /// The device-dependent bit in `NSEvent.ModifierFlags.rawValue` that tells left from right (IOKit NX_DEVICE*KEYMASK).
    var deviceMask: UInt {
        switch self {
        case .leftControl: 0x0000_0001
        case .leftShift: 0x0000_0002
        case .rightShift: 0x0000_0004
        case .leftCommand: 0x0000_0008
        case .rightCommand: 0x0000_0010
        case .leftOption: 0x0000_0020
        case .rightOption: 0x0000_0040
        case .rightControl: 0x0000_2000
        case .function: 0
        }
    }

    /// The device-independent bit, equal to the matching `NSEvent.ModifierFlags` raw value.
    var classMask: UInt {
        switch self {
        case .leftShift, .rightShift: 1 << 17
        case .leftControl, .rightControl: 1 << 18
        case .leftOption, .rightOption: 1 << 19
        case .leftCommand, .rightCommand: 1 << 20
        case .function: 1 << 23
        }
    }

    private static let allDeviceMasks = ModifierKey.allCases.reduce(UInt(0)) { $0 | $1.deviceMask }

    /// The modifier keys that are down according to an event's raw flags.
    ///
    /// Left and right come from the device bits. If a source supplies none (some synthetic keyboards), only the key
    /// that the event itself reports can be attributed, which is why `eventKeyCode` is needed.
    static func down(in rawFlags: UInt, eventKeyCode: UInt16) -> Set<ModifierKey> {
        var result = Set<ModifierKey>()
        if rawFlags & allDeviceMasks != 0 {
            for key in allCases where key.deviceMask != 0 && rawFlags & key.deviceMask != 0 { result.insert(key) }
        } else if let eventKey = ModifierKey(rawValue: eventKeyCode), eventKey != .function, rawFlags & eventKey.classMask != 0 {
            result.insert(eventKey)
        }
        if rawFlags & ModifierKey.function.classMask != 0 { result.insert(.function) }
        return result
    }
}

/// Detects a shortcut that is one modifier key pressed and released on its own.
///
/// A chord such as Cmd+C must never count. A press is only reported once the key has been down for `confirmDelay`
/// with no other key, modifier or mouse button involved; a tap shorter than that is reported at release. A chord
/// that starts later, while the key is already confirmed as held, is ignored so a push-to-talk take is not broken.
/// Pure value type with injected time; `ModifierShortcutMonitor` feeds it live events.
struct ModifierOnlyDetector: Equatable, Sendable {
    enum Output: Equatable, Sendable {
        /// `at` is when the key physically went down, even if the press is confirmed later.
        case pressed(at: TimeInterval)
        case released(at: TimeInterval)
    }

    static let defaultConfirmDelay: TimeInterval = 0.15

    private(set) var target: ModifierKey
    var confirmDelay: TimeInterval

    private enum Phase: Equatable {
        case idle
        /// The target went down alone. Not reported yet, since a chord may follow.
        case pending(since: TimeInterval)
        /// The press was reported; the release will be too.
        case held
        /// A chord or a pre-held modifier. Nothing is reported until the target is released.
        case rejected
    }
    private var phase: Phase = .idle

    init(target: ModifierKey, confirmDelay: TimeInterval = ModifierOnlyDetector.defaultConfirmDelay) {
        self.target = target
        self.confirmDelay = confirmDelay
    }

    /// When `advance(now:)` must next run, or nil if nothing is waiting.
    var deadline: TimeInterval? {
        if case .pending(let since) = phase { return since + confirmDelay }
        return nil
    }

    mutating func retarget(_ key: ModifierKey) {
        target = key
        phase = .idle
    }

    mutating func reset() { phase = .idle }

    mutating func flagsChanged(keyCode: UInt16, rawFlags: UInt, at time: TimeInterval) -> [Output] {
        let down = ModifierKey.down(in: rawFlags, eventKeyCode: keyCode)
        let targetDown = down.contains(target)
        var others = down.subtracting([target])
        // The function bit rides along with arrow and function keys, so it only counts when Fn is the target.
        if target != .function { others.remove(.function) }
        switch phase {
        case .idle:
            // Only the target's own press edge arms it. A key that was already down is ignored until released.
            guard keyCode == target.rawValue, targetDown else { return [] }
            phase = others.isEmpty ? .pending(since: time) : .rejected
            return []
        case .pending(let since):
            if !targetDown {
                phase = .idle
                // Released before the confirm delay with nothing else involved: a tap.
                return others.isEmpty ? [.pressed(at: since), .released(at: time)] : []
            }
            if !others.isEmpty { phase = .rejected }
            return []
        case .held:
            guard !targetDown else { return [] }
            phase = .idle
            return [.released(at: time)]
        case .rejected:
            if !targetDown { phase = .idle }
            return []
        }
    }

    /// A key press or mouse button while the target is down makes it part of a chord.
    mutating func otherInput(at time: TimeInterval) {
        if case .pending = phase { phase = .rejected }
    }

    /// Confirms a press once it has stood alone for `confirmDelay`.
    mutating func advance(now: TimeInterval) -> [Output] {
        guard case .pending(let since) = phase, now - since >= confirmDelay else { return [] }
        phase = .held
        return [.pressed(at: since)]
    }
}

/// Captures a shortcut recorder's "tap one modifier key" gesture: a single modifier goes down and comes back up
/// with no other key, modifier or click in between.
struct ModifierOnlyRecorder: Equatable, Sendable {
    private var candidate: ModifierKey?
    private var rejected = false
    private var anyModifierDown = false

    /// Returns the key once every modifier is up again and the gesture stayed clean.
    mutating func flagsChanged(keyCode: UInt16, rawFlags: UInt) -> ModifierKey? {
        let down = ModifierKey.down(in: rawFlags, eventKeyCode: keyCode)
        anyModifierDown = !down.isEmpty
        if down.isEmpty {
            let result = rejected ? nil : candidate
            candidate = nil
            rejected = false
            return result
        }
        if down.count > 1 {
            rejected = true
            candidate = nil
        } else if !rejected, candidate == nil, let key = down.first, key.rawValue == keyCode {
            candidate = key
        }
        return nil
    }

    /// A regular key or click. It spoils a gesture that is in progress, and means nothing otherwise.
    mutating func otherInput() {
        guard anyModifierDown else { return }
        rejected = true
        candidate = nil
    }
}
