import AppKit
import Carbon

/// Watches Escape for as long as it is switched on, and never otherwise.
@MainActor
protocol EscapeKeyWatching: AnyObject {
    var onEscape: (@MainActor () -> Void)? { get set }
    var isActive: Bool { get }
    /// Starts or stops watching. Returns whether the watcher is in the requested state afterwards.
    @discardableResult func setActive(_ active: Bool) -> Bool
}

private final class EscapeSink: @unchecked Sendable {
    let deliver: @Sendable () -> Void
    init(deliver: @escaping @Sendable () -> Void) { self.deliver = deliver }
}

private let keystormEscapeSignature: OSType = 0x4B53_4553 // KSES
private let keystormEscapeHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr, identifier.signature == keystormEscapeSignature else { return OSStatus(eventNotHandledErr) }
    if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
        Unmanaged<EscapeSink>.fromOpaque(userData).takeUnretainedValue().deliver()
    }
    return noErr
}

/// A Carbon hotkey for bare Escape that exists only while a dictation is recording or paused.
/// It needs no permission. While it exists Escape belongs to the dictation, so it is released the moment the
/// dictation ends and Escape reaches every other app as usual.
@MainActor
final class EscapeCancelHotkey: EscapeKeyWatching {
    var onEscape: (@MainActor () -> Void)?
    private(set) var isActive = false
    private var handler: EventHandlerRef?
    private var reference: EventHotKeyRef?
    private var sink: EscapeSink?

    isolated deinit { remove() }

    @discardableResult
    func setActive(_ active: Bool) -> Bool {
        guard active != isActive else { return true }
        if active { return install() }
        remove()
        return true
    }

    private func install() -> Bool {
        let newSink = EscapeSink { [weak self] in
            Task { @MainActor [weak self] in self?.onEscape?() }
        }
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        var newHandler: EventHandlerRef?
        guard InstallEventHandler(GetApplicationEventTarget(), keystormEscapeHandler, events.count, &events,
                                  Unmanaged.passUnretained(newSink).toOpaque(), &newHandler) == noErr,
              let newHandler else { return false }
        var newReference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0,
            EventHotKeyID(signature: keystormEscapeSignature, id: 1),
            GetApplicationEventTarget(), 0, &newReference)
        guard status == noErr, let newReference else {
            RemoveEventHandler(newHandler)
            return false
        }
        sink = newSink; handler = newHandler; reference = newReference
        isActive = true
        return true
    }

    private func remove() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil; handler = nil; sink = nil
        isActive = false
    }
}
