import AppKit
import Carbon
import Observation

enum ShortcutAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case toggleRecording, recordEdit, showWorkspace, readSection, pauseResumeReadback, undoBriefEdit, insertClipboard
    case toggleDictation, pauseResumeDictation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .toggleRecording: "Record / pause a take"
        case .recordEdit: "Record an editing instruction"
        case .showWorkspace: "Show workspace"
        case .readSection: "Read selected section"
        case .pauseResumeReadback: "Pause / resume read-back"
        case .undoBriefEdit: "Undo last brief edit"
        case .insertClipboard: "Insert clipboard exactly"
        case .toggleDictation: "Start / finish dictation"
        case .pauseResumeDictation: "Pause / resume dictation"
        }
    }
    var carbonID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
}

enum RecordingBehavior: String, CaseIterable, Codable, Identifiable {
    case toggle, hold
    var id: String { rawValue }
    var title: String { self == .toggle ? "Press to toggle recording" : "Hold to record" }
}

struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32
    static let command = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
    static let supported: Self = [.command, .option, .control, .shift]
    var carbon: UInt32 {
        (contains(.command) ? UInt32(cmdKey) : 0)
        | (contains(.option) ? UInt32(optionKey) : 0)
        | (contains(.control) ? UInt32(controlKey) : 0)
        | (contains(.shift) ? UInt32(shiftKey) : 0)
    }
    init(rawValue: UInt32) { self.rawValue = rawValue }
    init(flags: NSEvent.ModifierFlags) {
        var result: Self = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
        + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

struct GlobalShortcut: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: ShortcutModifiers
    /// Display only. Registration uses the physical key, not a character lookup.
    var keyLabel: String
    var displayName: String { modifiers.symbols + keyLabel }
    func matches(_ other: Self) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }

    func validate() throws {
        guard keyCode <= 126, !keyLabel.isEmpty, keyLabel.utf8.count <= 48,
              modifiers.subtracting(.supported).isEmpty else {
            throw ShortcutError.invalid("Unsupported key or modifier.")
        }
        guard !modifiers.intersection([.command, .option, .control]).isEmpty else {
            throw ShortcutError.invalid("Include Command, Option, or Control so normal typing stays available.")
        }
        let modifierKeys: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        guard !modifierKeys.contains(keyCode) else { throw ShortcutError.invalid("Choose a key as well as modifiers.") }
        // Protect system navigation and familiar editing/app commands.
        let commandKeys: Set<UInt32> = [0, 6, 7, 8, 9, 12, 13, 1, 3, 4, 31, 35, 45, 46, 18, 19, 20, 21, 22, 23, 43, 48]
        if modifiers == .command && commandKeys.contains(keyCode) {
            throw ShortcutError.invalid("That shortcut is reserved for normal Mac app commands.")
        }
        if keyCode == 49 && (modifiers == .command || modifiers == .control || modifiers == [.control, .command]) {
            throw ShortcutError.invalid("That shortcut is commonly used by macOS input or search.")
        }
        if modifiers.contains(.command) && keyCode == 48 {
            throw ShortcutError.invalid("Command–Tab combinations remain available for switching apps.")
        }
        if keyCode == 12 && (modifiers == [.command, .control] || modifiers == [.command, .shift] || modifiers == [.command, .option, .shift]) {
            throw ShortcutError.invalid("That combination is reserved for locking or signing out.")
        }
        if modifiers == [.command, .shift] && ([20, 21, 22, 23].contains(keyCode) || keyCode == 6) {
            throw ShortcutError.invalid("That combination is reserved for screenshots or standard redo.")
        }
        if keyCode == 49 && modifiers == [.command, .option] {
            throw ShortcutError.invalid("Option–Command–Space remains available for Finder search.")
        }
        if modifiers == .control && [123, 124, 125, 126].contains(keyCode) {
            throw ShortcutError.invalid("Control–Arrow remains available for system navigation.")
        }
        if keyCode == 53 || keyCode == 36 || keyCode == 76 || keyCode == 51 || keyCode == 117 {
            throw ShortcutError.invalid("Escape, Return, and Delete remain available to dialogs and editors.")
        }
    }

    @MainActor
    init(event: NSEvent) throws {
        guard !event.isARepeat else { throw ShortcutError.invalid("Release the keys and try again.") }
        keyCode = UInt32(event.keyCode)
        modifiers = .init(flags: event.modifierFlags)
        let special: [UInt16: String] = [49: "Space", 48: "Tab", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        keyLabel = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        try validate()
    }
    init(keyCode: UInt32, modifiers: ShortcutModifiers, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
}

enum ShortcutError: Error, LocalizedError, Equatable {
    case invalid(String), duplicate(String), registration(Int32)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .duplicate(let title): "Already assigned to “\(title)”."
        case .registration(let code): "macOS could not register this shortcut (\(code)). Another app or system feature may already use it."
        }
    }
}

enum ShortcutRegistration: Equatable {
    case disabled, registered, unavailable(String)
    var label: String {
        switch self { case .disabled: "Off"; case .registered: "Active globally"; case .unavailable(let error): error }
    }
}

struct ShortcutPreferences: Codable, Equatable {
    var version = 2
    var shortcuts: [String: GlobalShortcut]
    static let defaults = Self(shortcuts: [
        ShortcutAction.toggleRecording.rawValue: .init(keyCode: 49, modifiers: [.command, .shift], keyLabel: "Space"),
        ShortcutAction.recordEdit.rawValue: .init(keyCode: 14, modifiers: [.command, .option, .shift], keyLabel: "E"),
        ShortcutAction.showWorkspace.rawValue: .init(keyCode: 11, modifiers: [.command, .option, .shift], keyLabel: "B"),
        ShortcutAction.toggleDictation.rawValue: .init(keyCode: 2, modifiers: [.command, .option, .shift], keyLabel: "D"),
        ShortcutAction.pauseResumeDictation.rawValue: .init(keyCode: 35, modifiers: [.command, .option, .shift], keyLabel: "P")
    ])
}

/// Constant-time repeat suppression. The Carbon event callback never records keys or performs app work.
final class ShortcutPressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = Set<UInt32>()
    func accept(id: UInt32, pressed: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !pressed { held.remove(id); return false }
        return held.insert(id).inserted
    }
    func release(id: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return held.remove(id) != nil
    }
    func reset() { lock.lock(); held.removeAll(keepingCapacity: true); lock.unlock() }
}

private final class CarbonShortcutSink: @unchecked Sendable {
    let gate = ShortcutPressGate()
    let deliver: @Sendable (UInt32, Bool, UInt64) -> Void
    init(deliver: @escaping @Sendable (UInt32, Bool, UInt64) -> Void) { self.deliver = deliver }
}

private let keystormHotkeySignature: OSType = 0x4B53544D // KSTM
private let keystormHotkeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr, identifier.signature == keystormHotkeySignature else { return OSStatus(eventNotHandledErr) }
    let sink = Unmanaged<CarbonShortcutSink>.fromOpaque(userData).takeUnretainedValue()
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let accepted = pressed ? sink.gate.accept(id: identifier.id, pressed: true) : sink.gate.release(id: identifier.id)
    if accepted { sink.deliver(identifier.id, pressed, DispatchTime.now().uptimeNanoseconds) }
    return noErr
}

typealias ShortcutRegistrationOperation = @MainActor (GlobalShortcut, ShortcutAction, inout EventHotKeyRef?) -> OSStatus

@MainActor @Observable
final class ShortcutManager {
    private(set) var preferences: ShortcutPreferences
    private(set) var registration: [ShortcutAction: ShortcutRegistration] = [:]
    private(set) var lastError: String?
    private(set) var lastDispatchNanoseconds: UInt64 = 0
    private(set) var dispatchCount: UInt64 = 0
    private(set) var recordingBehavior: RecordingBehavior
    private(set) var isHoldingRecording = false
    @ObservationIgnored var onAction: (@MainActor (ShortcutAction) -> Void)?
    @ObservationIgnored var onHoldRecording: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let registerOperation: ShortcutRegistrationOperation
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    @ObservationIgnored private var references: [ShortcutAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var sink: CarbonShortcutSink?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var suspendedForCapture = false
    @ObservationIgnored private var dispatchNotBefore: UInt64 = 0
    private static let storageKey = "Keystorm.globalShortcuts.v1"

    init(defaults: UserDefaults = .standard,
         registerOperation: @escaping ShortcutRegistrationOperation = { shortcut, action, reference in
             RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers.carbon,
                 EventHotKeyID(signature: keystormHotkeySignature, id: action.carbonID),
                 GetApplicationEventTarget(), 0, &reference)
         }) {
        self.defaults = defaults
        self.registerOperation = registerOperation
        recordingBehavior = RecordingBehavior(rawValue: defaults.string(forKey: "Keystorm.recordingBehavior.v1") ?? "") ?? .toggle
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(ShortcutPreferences.self, from: data), (1...2).contains(decoded.version) {
            preferences = decoded
            // Add the new dictation actions without changing existing recording shortcuts.
            if decoded.version == 1 {
                for action in [ShortcutAction.toggleDictation, .pauseResumeDictation] {
                    if preferences.shortcuts[action.rawValue] == nil {
                        preferences.shortcuts[action.rawValue] = ShortcutPreferences.defaults.shortcuts[action.rawValue]
                    }
                }
                preferences.version = 2
                if let migrated = try? JSONEncoder().encode(preferences) { defaults.set(migrated, forKey: Self.storageKey) }
            }
        } else { preferences = .defaults }
    }

    isolated deinit {
        for reference in references.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    func shortcut(for action: ShortcutAction) -> GlobalShortcut? { preferences.shortcuts[action.rawValue] }

    func start() {
        guard !started else { return }
        started = true
        let newSink = CarbonShortcutSink { [weak self] identifier, pressed, enqueuedAt in
            Task { @MainActor [weak self] in
                guard let self, self.started, !self.suspendedForCapture,
                      enqueuedAt >= self.dispatchNotBefore,
                      let action = ShortcutAction.allCases.first(where: { $0.carbonID == identifier }),
                      self.registration[action] == .registered else { return }
                self.handleShortcut(action, pressed: pressed, enqueuedAt: enqueuedAt)
            }
        }
        sink = newSink
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), keystormHotkeyHandler,
                                        events.count, &events, Unmanaged.passUnretained(newSink).toOpaque(), &handler)
        guard status == noErr else {
            let message = ShortcutError.registration(status).localizedDescription
            lastError = message
            for action in ShortcutAction.allCases { registration[action] = .unavailable(message) }
            return
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemInterruption() }
        }
        registerConfigured()
    }

    func stop() {
        endHoldRecording()
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil; sink?.gate.reset(); sink = nil; started = false
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        for action in ShortcutAction.allCases { registration[action] = .disabled }
    }

    /// Shortcut recording temporarily unregisters our own keys so they can be captured by the focused control.
    func suspendForShortcutCapture(_ suspended: Bool) {
        guard suspendedForCapture != suspended else { return }
        suspendedForCapture = suspended
        endHoldRecording()
        dispatchNotBefore = DispatchTime.now().uptimeNanoseconds
        sink?.gate.reset()
        if suspended {
            for reference in references.values { UnregisterEventHotKey(reference) }
            references.removeAll()
        } else if started && handler != nil { registerConfigured() }
    }

    func setShortcut(_ shortcut: GlobalShortcut?, for action: ShortcutAction) throws {
        do {
            if let shortcut {
                try shortcut.validate()
                if let other = ShortcutAction.allCases.first(where: {
                    $0 != action && self.shortcut(for: $0)?.matches(shortcut) == true
                }) { throw ShortcutError.duplicate(other.title) }
            }
            if shortcut == self.shortcut(for: action) { lastError = nil; return }
            var newReference: EventHotKeyRef?
            if let shortcut, started, !suspendedForCapture, handler != nil {
                let result = registerOperation(shortcut, action, &newReference)
                guard result == noErr, newReference != nil else { throw ShortcutError.registration(result) }
            }
            if action == .toggleRecording { endHoldRecording() }
            dispatchNotBefore = DispatchTime.now().uptimeNanoseconds
            if let old = references.removeValue(forKey: action) { UnregisterEventHotKey(old) }
            if let newReference { references[action] = newReference }
            preferences.shortcuts[action.rawValue] = shortcut
            registration[action] = shortcut == nil ? .disabled : (newReference == nil ? .disabled : .registered)
            defaults.set(try JSONEncoder().encode(preferences), forKey: Self.storageKey)
            lastError = nil
        } catch { lastError = error.localizedDescription; throw error }
    }

    func retryRegistration() {
        guard started else { start(); return }
        guard handler != nil else { stop(); start(); return }
        registerConfigured()
    }

    func perform(_ action: ShortcutAction) {
        dispatch(action, enqueuedAt: DispatchTime.now().uptimeNanoseconds)
    }

    func setRecordingBehavior(_ value: RecordingBehavior) {
        guard value != recordingBehavior else { return }
        endHoldRecording()
        recordingBehavior = value
        defaults.set(value.rawValue, forKey: "Keystorm.recordingBehavior.v1")
    }

    // Called after Carbon registration/epoch validation. Shared with deterministic lifecycle tests.
    func handleShortcut(_ action: ShortcutAction, pressed: Bool, enqueuedAt: UInt64) {
        if action == .toggleRecording && recordingBehavior == .hold {
            if pressed {
                guard !isHoldingRecording else { return }
                isHoldingRecording = true
                lastDispatchNanoseconds = DispatchTime.now().uptimeNanoseconds &- enqueuedAt
                dispatchCount &+= 1
                onHoldRecording?(true)
            } else { endHoldRecording() }
        } else if pressed { dispatch(action, enqueuedAt: enqueuedAt) }
    }

    func handleSystemInterruption() {
        // Sleep can swallow a release event. Invalidate queued presses and relinquish an owned held take.
        dispatchNotBefore = DispatchTime.now().uptimeNanoseconds
        sink?.gate.reset()
        endHoldRecording()
    }

    func endHoldRecording() {
        guard isHoldingRecording else { return }
        isHoldingRecording = false
        onHoldRecording?(false)
    }

    private func dispatch(_ action: ShortcutAction, enqueuedAt: UInt64) {
        // Measures dispatch only. Audio startup/inference latency is measured separately by those subsystems.
        lastDispatchNanoseconds = DispatchTime.now().uptimeNanoseconds &- enqueuedAt
        dispatchCount &+= 1
        onAction?(action)
    }

    private func registerConfigured() {
        guard !suspendedForCapture else { return }
        endHoldRecording()
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll(); sink?.gate.reset()
        dispatchNotBefore = DispatchTime.now().uptimeNanoseconds
        var seen: [GlobalShortcut] = []
        for action in ShortcutAction.allCases {
            guard let shortcut = shortcut(for: action) else { registration[action] = .disabled; continue }
            do {
                try shortcut.validate()
                guard !seen.contains(where: { $0.matches(shortcut) }) else { throw ShortcutError.invalid("Duplicate stored shortcut. Assign a different combination.") }
                seen.append(shortcut)
                var reference: EventHotKeyRef?
                let status = registerOperation(shortcut, action, &reference)
                guard status == noErr, let reference else { throw ShortcutError.registration(status) }
                references[action] = reference; registration[action] = .registered
            } catch { registration[action] = .unavailable(error.localizedDescription) }
        }
    }
}
