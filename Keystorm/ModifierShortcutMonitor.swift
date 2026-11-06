import AppKit
import ApplicationServices

enum ModifierMonitorStatus: Equatable {
    case inactive, active, unavailable(String)
}

/// Observes one modifier key. A seam so `ShortcutManager` tests need no keyboard or Accessibility access.
@MainActor
protocol ModifierShortcutMonitoring: AnyObject {
    var onOutput: (@MainActor (ModifierOnlyDetector.Output) -> Void)? { get set }
    func start(key: ModifierKey) -> ModifierMonitorStatus
    func stop()
    /// Forgets a key that is down, for example after sleep swallowed its release.
    func reset()
}

/// One input event reduced to plain values, so it can leave the AppKit callback without carrying an `NSEvent`.
struct ModifierInputEvent: Sendable, Equatable {
    enum Kind: Sendable { case flagsChanged, keyDown, pointerDown }
    var kind: Kind
    var keyCode: UInt16
    var rawFlags: UInt
    var timestamp: TimeInterval

    init(kind: Kind, keyCode: UInt16 = 0, rawFlags: UInt = 0, timestamp: TimeInterval) {
        self.kind = kind; self.keyCode = keyCode; self.rawFlags = rawFlags; self.timestamp = timestamp
    }

    init?(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            self.init(kind: .flagsChanged, keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue,
                      timestamp: event.timestamp)
        case .keyDown:
            self.init(kind: .keyDown, keyCode: event.keyCode, timestamp: event.timestamp)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            self.init(kind: .pointerDown, timestamp: event.timestamp)
        default:
            return nil
        }
    }
}

/// Watches system-wide flags-changed events for a single-modifier shortcut (Fn, right Command, ...).
///
/// Uses a global plus a local `NSEvent` monitor. The global one only reports key events once the app is trusted for
/// Accessibility, so `start` says so instead of silently never firing. Both monitors are passive: they never change
/// or swallow an event, so a chord such as Cmd+C reaches its app untouched.
@MainActor
final class ModifierShortcutMonitor: ModifierShortcutMonitoring {
    var onOutput: (@MainActor (ModifierOnlyDetector.Output) -> Void)?
    private var detector = ModifierOnlyDetector(target: .function)
    private var monitors: [Any] = []
    private var timer: Task<Void, Never>?
    private let isTrusted: @MainActor () -> Bool
    private let clock: @MainActor () -> TimeInterval

    init(isTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
         clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.isTrusted = isTrusted
        self.clock = clock
    }

    isolated deinit {
        timer?.cancel()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
    }

    func start(key: ModifierKey) -> ModifierMonitorStatus {
        stop()
        guard isTrusted() else {
            return .unavailable(String(localized: "Single-modifier shortcuts need Accessibility access. Allow Keystorm in System Settings → Privacy & Security → Accessibility, then choose Retry registration."))
        }
        detector = ModifierOnlyDetector(target: key)
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        // AppKit calls both handlers on the main thread, in event order.
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let input = ModifierInputEvent(event) else { return }
            MainActor.assumeIsolated { self?.handle(input) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if let input = ModifierInputEvent(event) {
                MainActor.assumeIsolated { self?.handle(input) }
            }
            return event
        }
        guard let global else {
            if let local { NSEvent.removeMonitor(local) }
            return .unavailable(String(localized: "macOS did not allow Keystorm to watch modifier keys. Check Accessibility access, then choose Retry registration."))
        }
        monitors = [global]
        if let local { monitors.append(local) }
        return .active
    }

    func stop() {
        timer?.cancel(); timer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        detector.reset()
    }

    func reset() {
        timer?.cancel(); timer = nil
        detector.reset()
    }

    /// Single entry point for live and test events.
    func handle(_ input: ModifierInputEvent) {
        let outputs: [ModifierOnlyDetector.Output]
        switch input.kind {
        case .flagsChanged:
            outputs = detector.flagsChanged(keyCode: input.keyCode, rawFlags: input.rawFlags, at: input.timestamp)
        case .keyDown, .pointerDown:
            detector.otherInput(at: input.timestamp)
            outputs = []
        }
        deliver(outputs)
        scheduleConfirmation()
    }

    private func deliver(_ outputs: [ModifierOnlyDetector.Output]) {
        for output in outputs { onOutput?(output) }
    }

    /// Wakes once, when a lone press has stood long enough to be told apart from a chord.
    private func scheduleConfirmation() {
        timer?.cancel(); timer = nil
        guard let deadline = detector.deadline else { return }
        let delay = max(0.001, deadline - clock())
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.deliver(self.detector.advance(now: self.clock()))
            // A wake-up slightly before the deadline leaves the press pending, so wait again.
            self.scheduleConfirmation()
        }
    }
}
