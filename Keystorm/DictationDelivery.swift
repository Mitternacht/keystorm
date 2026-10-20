import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import CryptoKit
import Foundation
import Synchronization

/// Safe to keep in local history. Field contents and Accessibility objects never enter this descriptor.
struct DictationDestinationDescriptor: Codable, Equatable, Sendable {
    var appName: String
    var bundleIdentifier: String
    var processIdentifier: Int32
    var capturedAt: Date
}

enum DictationDeliveryOutcome: String, Codable, Sendable {
    case confirmed, failed, uncertain, targetChanged
    /// Paste fallback only: one Command-V was sent and something read the staged text.
    /// This is clipboard read evidence, never a verified field change.
    case pasted
}

/// How a captured destination may be written. Chosen once at Start; never upgraded later.
enum DictationDeliveryStrategy: String, Equatable, Sendable {
    /// Qualified TextEdit adapter: fingerprinted field text and exact post-insertion confirmation.
    case qualifiedTextEdit
    /// Other apps: no field text is read; one directed Command-V with clipboard read evidence.
    case pasteFallback
}

struct DictationDeliveryReceipt: Codable, Equatable, Sendable {
    var deliveryID: UUID
    var outcome: DictationDeliveryOutcome
    var message: String
    var destination: DictationDestinationDescriptor
}

enum DictationCaptureFailure: Equatable, Sendable {
    case accessibilityPermission, noExternalApplication, excludedApplication, copyOnlyApplication, unsupportedApplication
    case secureField, unsupportedField, unavailableField, targetChanged
    /// Secure keyboard entry is on system-wide, as it is while a password field has focus.
    case secureInput
    /// The focused field is in a page on a website the user blocked.
    case excludedWebsite
    /// Websites are blocked, but the address of the page around the focused field could not be read.
    case unverifiedWebsite

    var blocksRecording: Bool {
        [.secureField, .secureInput, .excludedApplication, .excludedWebsite].contains(self)
    }

    /// Refusals that also withhold every kind of context, including the app-level formatting profile.
    var withholdsContext: Bool {
        blocksRecording || [.targetChanged, .noExternalApplication, .unverifiedWebsite].contains(self)
    }

    var message: String {
        switch self {
        case .accessibilityPermission: "Accessibility access is off. Record locally, then copy the result."
        case .noExternalApplication: "Select a text field in another app to capture an insertion destination."
        case .excludedApplication: "Dictation is excluded in this app."
        case .copyOnlyApplication: "Record locally, then copy the result and paste it manually into this app."
        case .unsupportedApplication: "Automatic insertion is off for this app. Turn on Paste into other apps in Settings, or copy the result."
        case .secureField: "Dictation is unavailable in a protected text field."
        case .unsupportedField: "This field does not support safe selected-text insertion. The result will be available to copy."
        case .unavailableField: "The text field could not be read safely. The result will be available to copy."
        case .targetChanged: "The destination changed while it was being captured. The result will be available to copy."
        case .secureInput: "Secure keyboard entry is on, as it is in password fields, so dictation is unavailable here."
        case .excludedWebsite: "Dictation is excluded on this website."
        case .unverifiedWebsite: "This page's address couldn't be checked against your blocked websites. The result will be available to copy."
        }
    }
}

@MainActor
enum DictationCaptureResult {
    case ready(DictationCapturedTarget)
    case unavailable(DictationCaptureFailure)
}

@MainActor
struct DictationStartCapture {
    let target: DictationCaptureResult
    let context: DictationContextSnapshot?
    /// The app in front at Start, for its Quick-mode preset. Nil when no other app was in front (Keystorm itself
    /// included) and when that app is excluded, since nothing records there.
    let applicationBundleIdentifier: String?

    init(target: DictationCaptureResult, context: DictationContextSnapshot?, applicationBundleIdentifier: String? = nil) {
        self.target = target
        self.context = context
        self.applicationBundleIdentifier = applicationBundleIdentifier
    }
}

/// Opaque, ephemeral destination. Never encode this object or persist its context excerpt.
@MainActor
final class DictationCapturedTarget {
    let descriptor: DictationDestinationDescriptor
    let contextExcerpt: String
    let strategy: DictationDeliveryStrategy
    fileprivate let field: any DictationDeliveryField
    fileprivate let ownerID: UUID
    fileprivate let selection: NSRange
    fileprivate let fingerprint: SHA256.Digest
    fileprivate let textLength: Int
    /// Qualified adapter only: the field's role at Start. A role change on the same element refuses delivery.
    fileprivate let qualifiedRole: String?
    /// Paste fallback only: the accepted role and the numeric selected range seen at Start, never field text.
    fileprivate let pasteRole: String?
    fileprivate let pasteSelection: NSRange?
    fileprivate var attemptedReceipt: DictationDeliveryReceipt?
    fileprivate var confirmedCorrectionAnchor: ExternalCorrectionAnchor?
    fileprivate var confirmedCorrectionDeliveryID: UUID?
    /// Paste fallback only: AXManualAccessibility that Keystorm itself turned on to find this field.
    private var manualAccessibilityGrant: DictationManualAccessibilityGrant?

    fileprivate init(descriptor: DictationDestinationDescriptor, field: any DictationDeliveryField,
                     ownerID: UUID, role: String, snapshot: DictationFieldSnapshot) {
        self.descriptor = descriptor
        self.field = field
        self.ownerID = ownerID
        strategy = .qualifiedTextEdit
        selection = snapshot.selection
        fingerprint = SHA256.hash(data: Data(snapshot.text.utf8))
        textLength = snapshot.text.utf16.count
        contextExcerpt = DictationContextPolicy.excerpt(text: snapshot.text, selection: selection)
        qualifiedRole = role
        pasteRole = nil
        pasteSelection = nil
    }

    /// The fallback never reads field text, so there is no fingerprint and no nearby-text context.
    fileprivate init(pasteFallback descriptor: DictationDestinationDescriptor, field: any DictationDeliveryField,
                     ownerID: UUID, role: String, selection: NSRange?,
                     manualAccessibilityGrant: DictationManualAccessibilityGrant?) {
        self.descriptor = descriptor
        self.field = field
        self.ownerID = ownerID
        strategy = .pasteFallback
        self.selection = NSRange(location: NSNotFound, length: 0)
        fingerprint = SHA256.hash(data: Data())
        textLength = 0
        contextExcerpt = ""
        qualifiedRole = nil
        pasteRole = role
        pasteSelection = selection
        manualAccessibilityGrant?.acquire()
        self.manualAccessibilityGrant = manualAccessibilityGrant
    }

    /// Safety net: a capture dropped without delivery or an explicit release never leaves the app's
    /// accessibility mode switched on.
    isolated deinit { releaseManualAccessibility() }

    /// Idempotent. Turns AXManualAccessibility off again once no other live capture relies on it.
    fileprivate func releaseManualAccessibility() {
        guard let grant = manualAccessibilityGrant else { return }
        manualAccessibilityGrant = nil
        grant.release()
    }
}

/// AXManualAccessibility that Keystorm turned on for one Chromium or Electron app, because no
/// acceptable focused field was exposed without it. Never created when the app already reported it on.
/// Captures that rely on it share it; the last one to be delivered, released or dropped turns it off,
/// so the app does not stay in accessibility mode (or VS Code in Screen Reader Optimized mode).
@MainActor
private final class DictationManualAccessibilityGrant {
    let processIdentifier: Int32
    private let application: DictationDeliveryApplication
    private let adapter: any DictationDeliveryAdapter
    private var holders = 0
    private(set) var isRestored = false

    init(application: DictationDeliveryApplication, adapter: any DictationDeliveryAdapter) {
        processIdentifier = application.processIdentifier
        self.application = application
        self.adapter = adapter
    }

    isolated deinit { restore() }

    func acquire() {
        guard !isRestored else { return }
        holders += 1
    }

    func release() {
        guard holders > 0 else { return }
        holders -= 1
        if holders == 0 { restore() }
    }

    /// Idempotent: writes `false` at most once.
    func restore() {
        guard !isRestored else { return }
        isRestored = true
        _ = adapter.setManualAccessibility(false, in: application)
    }
}

private struct WeakManualAccessibilityGrant {
    weak var grant: DictationManualAccessibilityGrant?
}

struct DictationDeliveryApplication: Equatable {
    var processIdentifier: Int32
    var bundleIdentifier: String
    var name: String
}

/// Adapter-only types intentionally stay on the main actor; AX objects cannot cross tasks.
@MainActor protocol DictationDeliveryField: AnyObject {}

struct DictationFieldMetadata {
    var processIdentifier: Int32
    var role: String
    var subrole: String?
    var isEnabled: Bool
    var isProtected: Bool
    var selectedTextIsSettable: Bool
    var supportsPaste: Bool = false
    /// Capability query only (AXUIElementIsAttributeSettable); the value itself is never read.
    var valueIsSettable: Bool = false
    /// The hidden input of an xterm.js terminal inside an editor, Electron app or web console. It reports
    /// an editable text area, but a multi-line paste there runs as shell input, so it stays Copy-only.
    var isTerminalInput: Bool = false
    /// The element's accessible label, title or placeholder names a password (see `isSecureLabel`).
    /// Catches a password field whose role was mislabelled, such as a "show password" toggle that turned
    /// a web password input into a plain text field. Labels only, never the value.
    var hasSecureLabel: Bool = false
    /// Secure keyboard entry was on when the metadata was read (`IsSecureEventInputEnabled`). macOS turns it on
    /// while a password field has focus, including browser password inputs, whatever their Accessibility role says.
    var secureEventInput: Bool = false

    static let pasteFallbackRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    /// Matched case-insensitively inside labels, titles and placeholders (English and German).
    static let secureLabelTerms = ["password", "passwort", "kennwort", "passcode", "passphrase"]

    static func isSecureLabel(_ labels: [String]) -> Bool {
        labels.contains { label in
            let folded = label.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                       locale: nil).lowercased()
            return secureLabelTerms.contains { folded.contains($0) }
        }
    }

    /// A role or subrole that names a secure or password element, compared without regard to case or surrounding
    /// spaces: "AXSecureTextField" as either, and custom spellings of it.
    static func isSecureRoleName(_ name: String?) -> Bool {
        guard let name else { return false }
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folded.contains("secure") || folded.contains("password")
    }

    /// Optional security markers (subrole, AXProtectedContent). An absent attribute means "not set". Any other
    /// Accessibility error (timeout, failure, invalid element) means unknown, and unknown fails closed instead of
    /// passing as "not secure".
    static func optionalAttributeIsKnown(status: AXError) -> Bool {
        switch status {
        case .success, .attributeUnsupported, .noValue: true
        default: false
        }
    }
    /// xterm.js: `<textarea class="xterm-helper-textarea" aria-label="Terminal input">`.
    static let terminalInputDOMClass = "xterm-helper-textarea"
    static let terminalInputLabel = "Terminal input"

    /// Metadata only: the element's DOM class list and accessible labels, never its value.
    static func isTerminalInput(domClassList: [String], labels: [String]) -> Bool {
        domClassList.contains { entry in
            entry.split(whereSeparator: \.isWhitespace).contains { $0 == terminalInputDOMClass }
        } || labels.contains { label in
            label.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(terminalInputLabel) == .orderedSame
        }
    }

    /// AXEnabled is optional. NSTextView-based editors such as TextEdit do not expose it at all, which was
    /// observed on the desktop on 2026-10-20 as the only failing capability. An explicit false still
    /// disables the field; an unsupported or absent attribute defers to the settable-capability checks;
    /// every other Accessibility error (timeout, failure, invalid element) fails closed.
    static func resolvedEnabled(status: AXError, value: CFTypeRef?) -> Bool {
        switch status {
        case .success: (value as? NSNumber)?.boolValue ?? false
        case .attributeUnsupported, .noValue: true
        default: false
        }
    }

    /// Why this element must never become a destination or a context source, or nil when nothing marks it as
    /// sensitive. Any one marker is enough: a field whose role says text field but whose subrole, protection,
    /// label or the system's secure keyboard entry says password is refused.
    var secureFailure: DictationCaptureFailure? {
        if isProtected || Self.isSecureRoleName(role) || Self.isSecureRoleName(subrole) || hasSecureLabel {
            return .secureField
        }
        return secureEventInput ? .secureInput : nil
    }

    var isSecure: Bool { secureFailure != nil }

    var supportsInsertion: Bool {
        !isSecure && isEnabled && (selectedTextIsSettable || supportsPaste) &&
            (role == "AXTextArea" || role == "AXTextField") &&
            (subrole == nil || subrole == "" || subrole == "AXSearchField")
    }

    /// Paste fallback: an enabled, editable text-entry element. Web and Electron editors qualify only
    /// when they report one of these roles; groups, web areas, unknown subroles and terminal inputs
    /// stay Copy-only.
    var acceptsPasteFallback: Bool {
        !isSecure && !isTerminalInput && isEnabled && (selectedTextIsSettable || valueIsSettable) &&
            Self.pasteFallbackRoles.contains(role) &&
            (subrole == nil || subrole == "" || subrole == "AXSearchField")
    }
}

struct DictationFieldSnapshot {
    var text: String
    var selection: NSRange

    func isValid(maximumUTF16: Int) -> Bool {
        let count = text.utf16.count
        guard count <= maximumUTF16, selection.location >= 0, selection.length >= 0,
              selection.location <= count, selection.length <= count - selection.location else { return false }
        // Foundation may form String.Index values inside a surrogate pair. Validate UTF-16 explicitly.
        let units = Array(text.utf16)
        func isScalarBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < units.count else { return true }
            return !(0xD800...0xDBFF).contains(units[offset - 1]) || !(0xDC00...0xDFFF).contains(units[offset])
        }
        return isScalarBoundary(selection.location) && isScalarBoundary(selection.location + selection.length) &&
            Range(selection, in: text) != nil
    }
}

enum DictationReplacementAcknowledgment {
    case accepted, rejected, unknown
}

@MainActor
protocol DictationDeliveryAdapter {
    var isTrusted: Bool { get }
    func requestPermission()
    func openSettings()
    func frontmostApplication() -> DictationDeliveryApplication?
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment
    func observeChanges(of field: any DictationDeliveryField, processIdentifier: Int32,
                        onEvent: @escaping @MainActor (DictationFieldObservationEvent) -> Void) -> (any ExternalCorrectionCancellation)?
    func preparePaste(_ text: String, in field: any DictationDeliveryField, processIdentifier: Int32) throws -> any DictationPasteOperation
    /// Paste fallback: the app's AXManualAccessibility flag (Chromium and Electron), or nil when unreadable.
    func manualAccessibility(in application: DictationDeliveryApplication) -> Bool?
    /// Paste fallback, best effort: writes AXManualAccessibility, which makes Chromium and Electron apps
    /// expose their accessibility tree. Returns whether the app accepted the write.
    func setManualAccessibility(_ enabled: Bool, in application: DictationDeliveryApplication) -> Bool
    /// Paste fallback: the numeric selected UTF-16 range only; never any field text.
    func selectedTextRange(of field: any DictationDeliveryField) -> NSRange?
    /// Whether one synthetic Command-V may be posted.
    var canPostPasteEvents: Bool { get }
    /// Paste fallback: a lazily provided clipboard lease plus one directed Command-V.
    func prepareFallbackPaste(_ text: String, processIdentifier: Int32) throws -> any DictationPasteOperation
    /// Website exclusions only, and only while a website is blocked: the addresses of the web documents that
    /// contain the field. Ancestor roles and a web area's AXURL only; never any field's value.
    func webDocumentURLs(containing field: any DictationDeliveryField) -> DictationWebDocumentLookup
}

@MainActor
protocol DictationPasteOperation: AnyObject {
    func perform() -> Bool
    func restoreIfOwned()
    /// Hand-off after a paste that was sent but never confirmed: a late paste must never read a restored,
    /// unrelated clipboard. While the operation still owns the clipboard, the result stays on it as concrete
    /// data; afterwards nothing restores, not even on release. Returns whether the result is on the clipboard;
    /// false when a newer copy replaced it, which is left untouched.
    @discardableResult func leaveStagedTextOnPasteboard() -> Bool
    /// True once something requested the staged text after `perform()`.
    /// Evidence that the paste was read, not proof of what the destination inserted.
    var stagedTextWasRead: Bool { get }
}

extension DictationPasteOperation {
    var stagedTextWasRead: Bool { false }
}

extension DictationDeliveryAdapter {
    /// Existing adapters remain unsupported until their notifications are qualified.
    func observeChanges(of field: any DictationDeliveryField, processIdentifier: Int32,
                        onEvent: @escaping @MainActor (DictationFieldObservationEvent) -> Void) -> (any ExternalCorrectionCancellation)? { nil }

    func preparePaste(_ text: String, in field: any DictationDeliveryField, processIdentifier: Int32) throws -> any DictationPasteOperation {
        throw DictationAXError.unsupported
    }

    // Adapters without these capabilities never qualify for the paste fallback.
    func manualAccessibility(in application: DictationDeliveryApplication) -> Bool? { nil }
    func setManualAccessibility(_ enabled: Bool, in application: DictationDeliveryApplication) -> Bool { false }
    func selectedTextRange(of field: any DictationDeliveryField) -> NSRange? { nil }
    var canPostPasteEvents: Bool { false }
    func prepareFallbackPaste(_ text: String, processIdentifier: Int32) throws -> any DictationPasteOperation {
        throw DictationAXError.unsupported
    }
    /// An adapter that cannot tell where a field is fails safe: with any website blocked, it is unverified.
    func webDocumentURLs(containing field: any DictationDeliveryField) -> DictationWebDocumentLookup { .unavailable }
}

/// Paste fallback timing. Injectable so tests need not wait for real clipboard readers.
struct DictationPasteTiming: Sendable {
    /// How long to wait for the destination to request the staged text.
    var evidenceTimeout: Duration = .seconds(2)
    /// Delay after the first read before the clipboard is restored.
    var settleDelay: Duration = .milliseconds(300)
    var pollInterval: Duration = .milliseconds(20)

    static let standard = DictationPasteTiming()
}

/// Paste fallback: the bounded wait for a Chromium or Electron app to expose its focused field after
/// Keystorm itself turned AXManualAccessibility on. Those apps build the accessibility tree
/// asynchronously after the write, so a single immediate retry usually still finds nothing; without this
/// wait every Start in Slack, VS Code, Discord or Chrome would turn the mode on, fail, and turn it off again.
///
/// Why the wait blocks instead of suspending: capture is synchronous on the main actor. The coordinator
/// calls it inside `start()` before it presents any UI, before `.starting`, and before its operation task
/// begins the microphone, and it does not await around it. An asynchronous capture would add an in-between
/// state that Start's reentrancy guards, `reservesCapture` (also checked by brief hold-to-record), cancel,
/// shutdown and New Draft would all have to handle, and every synchronous caller would change. So the poll
/// sleeps on the main thread, and only here.
///
/// Accepted Start-latency cost, in this case only: at most `timeout` (400 ms) of sleeping, measured on a
/// monotonic clock from the write, plus the AX round trip of the poll in progress at the deadline (each AX
/// call is bounded by the 0.25 s messaging timeout). The wait stops at the first acceptable field, secure
/// field, terminal input or change of frontmost app. Native apps, fields exposed without the write, apps that
/// already report the mode on, and captures that share an earlier grant never wait at all.
struct DictationAccessibilityWarmUp: Sendable {
    static let standardPollInterval: Duration = .milliseconds(50)
    static let standardTimeout: Duration = .milliseconds(400)

    /// Wait between polls. The first poll runs immediately after the write, as the single retry did.
    var pollInterval: Duration = Self.standardPollInterval
    /// Total sleeping allowed after the write. Zero keeps the single immediate retry.
    var timeout: Duration = Self.standardTimeout
    /// Monotonic time for the deadline. Tests inject a virtual clock that advances only when `sleep` runs.
    var now: @MainActor @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    /// Blocks the calling thread, which is the main thread during Start.
    var sleep: @MainActor @Sendable (Duration) -> Void = { duration in
        let components = duration.components
        Thread.sleep(forTimeInterval: Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    /// Waited polls at most: the timeout split into whole intervals, rounded up. This caps the loop even if
    /// `now` stalls, so the sleeping requested never exceeds `timeout` plus less than one interval.
    var maximumWaitedPolls: Int {
        guard pollInterval > .zero, timeout > .zero else { return 0 }
        return Int((timeout / pollInterval).rounded(.up))
    }

    static let standard = DictationAccessibilityWarmUp()
}

/// All cross-app writes go through one validated, at-most-once selected-text operation.
/// It never activates apps, writes AXValue, changes selection, or submits text.
/// Qualified TextEdit fields may use a leased clipboard and a single directed Command-V.
@MainActor
final class DictationDeliveryService {
    static let maximumFieldUTF16 = 65_536
    static let maximumInsertionUTF16 = 65_536
    /// Password managers: capture and recording are refused before any field access.
    /// Unknown identifiers are inert, so retired and alternate-distribution IDs stay listed.
    nonisolated static let passwordManagerBundleIdentifiers: Set<String> = [
        // 1Password 8, 7, and the legacy 6 (App Store) and 4–6 (direct) builds.
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx", "com.agilebits.onepassword4",
        // Apple Passwords and Keychain Access.
        "com.apple.Passwords", "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.lastpass.LastPass",
        // Dashlane: App Store build and direct-download build.
        "com.dashlane.dashlanephonefinal", "com.dashlane.Dashlane",
        "in.sinew.Enpass-Desktop",
        "me.proton.pass.electron"
    ]
    private let adapter: any DictationDeliveryAdapter
    private let ownerID = UUID()
    private let ownBundleIdentifier: String
    private let ownProcessIdentifier: Int32
    private let excludedBundleIdentifiers: Set<String>
    private var receipts: [UUID: DictationDeliveryReceipt] = [:]
    private var inFlightDeliveryID: UUID?
    private let correctionScheduler: any ExternalCorrectionScheduling
    private var correctionLease: ExternalCorrectionLease?
    private let pasteTiming: DictationPasteTiming
    private let accessibilityWarmUp: DictationAccessibilityWarmUp
    /// Live AXManualAccessibility grants by process; weak, so only captures keep them alive.
    private var manualAccessibilityGrants: [Int32: WeakManualAccessibilityGrant] = [:]

    init(adapter: (any DictationDeliveryAdapter)? = nil,
         ownBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "Keystorm",
         ownProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
         correctionObservationScheduler: (any ExternalCorrectionScheduling)? = nil,
         excludedBundleIdentifiers: Set<String> = DictationDeliveryService.passwordManagerBundleIdentifiers,
         pasteTiming: DictationPasteTiming = .standard,
         accessibilityWarmUp: DictationAccessibilityWarmUp = .standard) {
        self.adapter = adapter ?? NativeDictationDeliveryAdapter()
        correctionScheduler = correctionObservationScheduler ?? SystemExternalCorrectionScheduler()
        self.ownBundleIdentifier = ownBundleIdentifier
        self.ownProcessIdentifier = ownProcessIdentifier
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.pasteTiming = pasteTiming
        self.accessibilityWarmUp = accessibilityWarmUp
    }

    isolated deinit { correctionLease?.stop() }

    var isAccessibilityTrusted: Bool { adapter.isTrusted }
    func requestAccessibilityPermission() { adapter.requestPermission() }
    func openAccessibilitySettings() { adapter.openSettings() }

    func captureTarget(pasteIntoOtherApps: Bool = false,
                       exclusions: DictationUserExclusions = .empty) -> DictationCaptureResult {
        captureForStart(contextSettings: DictationContextSettings(), pasteIntoOtherApps: pasteIntoOtherApps,
                        exclusions: exclusions).target
    }

    /// True for the built-in password managers and for apps the user blocked.
    func isExcluded(_ bundleIdentifier: String, exclusions: DictationUserExclusions) -> Bool {
        excludedBundleIdentifiers.contains(bundleIdentifier) || exclusions.applications.contains(bundleIdentifier)
    }

    /// Snapshots the starting app identity, then revalidates the qualified destination.
    /// Nearby text comes solely from the already-qualified
    /// destination snapshot; enabling context never adds Accessibility reads or app support.
    /// `pasteIntoOtherApps` allows the validated paste fallback outside TextEdit; it never reads field text.
    /// `exclusions` adds the user's blocked apps (checked like the built-in password managers, before any field
    /// access) and blocked websites (checked from the focused field's page address once the field is known).
    func captureForStart(contextSettings: DictationContextSettings,
                         pasteIntoOtherApps: Bool = false,
                         exclusions: DictationUserExclusions = .empty) -> DictationStartCapture {
        stopCorrectionObservation()
        guard let app = adapter.frontmostApplication(),
              app.processIdentifier != ownProcessIdentifier,
              app.bundleIdentifier != ownBundleIdentifier else {
            return DictationStartCapture(target: .unavailable(.noExternalApplication), context: nil)
        }
        // Built-in and user-blocked apps alike: no capture, no context and no field access of any kind.
        guard !isExcluded(app.bundleIdentifier, exclusions: exclusions) else {
            return DictationStartCapture(target: .unavailable(.excludedApplication), context: nil)
        }
        if DictationContextPolicy.terminalBundleIdentifiers.contains(app.bundleIdentifier) {
            return DictationStartCapture(target: .unavailable(.copyOnlyApplication), context: nil,
                                         applicationBundleIdentifier: app.bundleIdentifier)
        }
        let target = captureTarget(in: app, pasteIntoOtherApps: pasteIntoOtherApps, websites: exclusions.websites)
        guard contextSettings.mode != .off else {
            return DictationStartCapture(target: target, context: nil, applicationBundleIdentifier: app.bundleIdentifier)
        }
        if case .unavailable(let failure) = target, failure.withholdsContext {
            return DictationStartCapture(target: target, context: nil, applicationBundleIdentifier: app.bundleIdentifier)
        }
        let profile = contextSettings.profile.resolved(for: app.bundleIdentifier)
        let context: DictationContextSnapshot
        // Paste fallback targets stay app-level: their field text is never read.
        if contextSettings.mode == .nearbyText, case .ready(let captured) = target,
           captured.strategy == .qualifiedTextEdit, !captured.contextExcerpt.isEmpty {
            context = DictationContextSnapshot(profile: profile, availability: .nearbyText,
                nearbyText: captured.contextExcerpt, capturedAt: captured.descriptor.capturedAt)
        } else {
            context = DictationContextSnapshot(profile: profile, availability: .application)
        }
        guard (try? context.validate()) != nil else {
            return DictationStartCapture(target: target, context: nil, applicationBundleIdentifier: app.bundleIdentifier)
        }
        return DictationStartCapture(target: target, context: context, applicationBundleIdentifier: app.bundleIdentifier)
    }

    /// Website exclusions for one field. Looks nothing up while no website is blocked.
    private func websiteVerdict(for field: any DictationDeliveryField, websites: [String]) -> DictationWebsiteVerdict {
        guard !websites.isEmpty else { return .notChecked }
        return DictationWebsiteExclusion.verdict(adapter.webDocumentURLs(containing: field), blockedDomains: websites)
    }

    private func captureTarget(in app: DictationDeliveryApplication, pasteIntoOtherApps: Bool,
                               websites: [String]) -> DictationCaptureResult {
        if DictationContextPolicy.terminalBundleIdentifiers.contains(app.bundleIdentifier) {
            // Terminal dictation is useful, but context reads and automatic delivery remain disabled.
            return .unavailable(.copyOnlyApplication)
        }
        guard adapter.isTrusted else { return .unavailable(.accessibilityPermission) }
        // Qualify app adapters explicitly. Unknown/browser fields are never inspected for context.
        guard app.bundleIdentifier == "com.apple.TextEdit" else {
            guard pasteIntoOtherApps else { return .unavailable(.unsupportedApplication) }
            return capturePasteFallback(in: app, websites: websites)
        }
        do {
            let field = try adapter.focusedField(in: app)
            let metadata = try adapter.metadata(for: field)
            if let secure = metadata.secureFailure { return .unavailable(secure) }
            guard metadata.processIdentifier == app.processIdentifier, metadata.supportsInsertion else {
                #if DEBUG
                // Isolated file-audio validation only: capability flags, never field text.
                try? DebugAudioValidationConfiguration.configuration()?.log("capture-unsupported-field", fields: [
                    "role": metadata.role, "subrole": metadata.subrole ?? "", "enabled": metadata.isEnabled,
                    "selectedTextSettable": metadata.selectedTextIsSettable, "supportsPaste": metadata.supportsPaste,
                    "valueSettable": metadata.valueIsSettable,
                    "samePID": metadata.processIdentifier == app.processIdentifier
                ])
                #endif
                return .unavailable(.unsupportedField)
            }
            // Before any field text is read.
            switch websiteVerdict(for: field, websites: websites) {
            case .blocked: return .unavailable(.excludedWebsite)
            case .unverified: return .unavailable(.unverifiedWebsite)
            case .notChecked, .notWebContent, .allowed: break
            }
            let snapshot = try adapter.snapshot(of: field, maximumUTF16: Self.maximumFieldUTF16)
            guard snapshot.isValid(maximumUTF16: Self.maximumFieldUTF16) else { return .unavailable(.unavailableField) }
            guard isStillFocused(field, application: app) else { return .unavailable(.targetChanged) }
            return .ready(DictationCapturedTarget(
                descriptor: DictationDestinationDescriptor(appName: app.name, bundleIdentifier: app.bundleIdentifier,
                    processIdentifier: app.processIdentifier, capturedAt: Date()),
                field: field, ownerID: ownerID, role: metadata.role, snapshot: snapshot))
        } catch {
            return .unavailable(.unavailableField)
        }
    }

    /// Qualifies the focused element by metadata alone. No AXValue, AXStringForRange or fingerprint:
    /// only role, subrole, labels, enabled/protected state, settable capabilities, terminal markers, the
    /// numeric selected range and, while a website is blocked, the containing page's address.
    ///
    /// App state is left alone whenever possible: AXManualAccessibility is written only when no acceptable
    /// field is exposed without it and the app does not already report it on. Keystorm then turns it
    /// off again when this capture fails, or once the capture is delivered, released or dropped.
    ///
    /// Only the path that writes the attribute may wait: everything before the write returns at once.
    private func capturePasteFallback(in app: DictationDeliveryApplication, websites: [String]) -> DictationCaptureResult {
        // A capture made while an earlier capture's grant is still in effect shares that grant.
        let existing = activeManualAccessibilityGrant(for: app.processIdentifier)
        let first = pasteFallbackAttempt(in: app, grant: existing, websites: websites)
        guard case .notFound(let failure) = first else { return first.result }
        // Chromium and Electron build their tree only on request. Never write when the app already reports
        // it on (VoiceOver, another assistive app, or an earlier capture of ours), or when the write fails.
        guard existing == nil, adapter.manualAccessibility(in: app) != true,
              adapter.setManualAccessibility(true, in: app) else { return .unavailable(failure) }
        let grant = DictationManualAccessibilityGrant(application: app, adapter: adapter)
        let result = pollForRequestedField(in: app, grant: grant, websites: websites)
        guard case .ready = result else {
            grant.restore()
            return result
        }
        manualAccessibilityGrants[app.processIdentifier] = WeakManualAccessibilityGrant(grant: grant)
        return result
    }

    /// After Keystorm turned AXManualAccessibility on: polls with the same metadata checks as the first
    /// attempt, immediately and then every `pollInterval`, until `timeout` of sleeping is spent (see
    /// `DictationAccessibilityWarmUp` for why this blocks and what it costs). Any final answer ends the wait
    /// at once: an acceptable field, a secure field or blocked website (both still block recording), a terminal
    /// input (Copy-only), missing event access or a focus change. So does a change of frontmost app or process,
    /// which is never waited out. An unreadable page address keeps polling, since it may become readable as the
    /// tree is built. Otherwise the last not-found failure is returned, and the caller turns the mode off again.
    private func pollForRequestedField(in app: DictationDeliveryApplication,
                                       grant: DictationManualAccessibilityGrant,
                                       websites: [String]) -> DictationCaptureResult {
        let warmUp = accessibilityWarmUp
        let deadline = warmUp.now().advanced(by: warmUp.timeout)
        var attempt = pasteFallbackAttempt(in: app, grant: grant, websites: websites)
        var waitedPolls = 0
        while case .notFound = attempt, waitedPolls < warmUp.maximumWaitedPolls {
            let remaining = warmUp.now().duration(to: deadline)
            guard remaining > .zero else { break }
            warmUp.sleep(min(warmUp.pollInterval, remaining))
            waitedPolls += 1
            // The user may have switched apps while the tree was being built. Never keep polling, or capture,
            // a destination they left; the field check alone would still find the old app's focused element.
            guard let front = adapter.frontmostApplication(),
                  front.processIdentifier == app.processIdentifier,
                  front.bundleIdentifier == app.bundleIdentifier else { return .unavailable(.targetChanged) }
            attempt = pasteFallbackAttempt(in: app, grant: grant, websites: websites)
        }
        return attempt.result
    }

    private enum PasteFallbackAttempt {
        case final(DictationCaptureResult)
        /// No acceptable focused element was exposed; a Chromium or Electron app may expose one on request.
        case notFound(DictationCaptureFailure)

        var result: DictationCaptureResult {
            switch self {
            case .final(let result): result
            case .notFound(let failure): .unavailable(failure)
            }
        }
    }

    private func pasteFallbackAttempt(in app: DictationDeliveryApplication,
                                      grant: DictationManualAccessibilityGrant?,
                                      websites: [String]) -> PasteFallbackAttempt {
        let field: any DictationDeliveryField
        let metadata: DictationFieldMetadata
        do {
            // No focused element means no destination: never an app-level blind paste.
            field = try adapter.focusedField(in: app)
            metadata = try adapter.metadata(for: field)
        } catch {
            return .notFound(.unavailableField)
        }
        if let secure = metadata.secureFailure { return .final(.unavailable(secure)) }
        // Never look through another process's element tree, not even for its page address.
        guard metadata.processIdentifier == app.processIdentifier else { return .notFound(.unsupportedField) }
        // A blocked website blocks recording whatever the focused element is, terminal inputs included.
        let website = websiteVerdict(for: field, websites: websites)
        if website == .blocked { return .final(.unavailable(.excludedWebsite)) }
        // Terminals are Copy-only, also inside editors and web apps: a multi-line paste can run as shell input.
        guard !metadata.isTerminalInput else { return .final(.unavailable(.copyOnlyApplication)) }
        // Fails safe: no paste and no context. Not final, because the address may appear as the tree is built.
        guard website != .unverified else { return .notFound(.unverifiedWebsite) }
        guard metadata.acceptsPasteFallback else { return .notFound(.unsupportedField) }
        guard adapter.canPostPasteEvents else { return .final(.unavailable(.accessibilityPermission)) }
        let selection = adapter.selectedTextRange(of: field).flatMap { range in
            range.location >= 0 && range.length >= 0 && range.location != NSNotFound ? range : nil
        }
        guard isStillFocused(field, application: app) else { return .final(.unavailable(.targetChanged)) }
        return .final(.ready(DictationCapturedTarget(pasteFallback: DictationDestinationDescriptor(
                appName: app.name, bundleIdentifier: app.bundleIdentifier,
                processIdentifier: app.processIdentifier, capturedAt: Date()),
            field: field, ownerID: ownerID, role: metadata.role, selection: selection,
            manualAccessibilityGrant: grant)))
    }

    private func activeManualAccessibilityGrant(for processIdentifier: Int32) -> DictationManualAccessibilityGrant? {
        manualAccessibilityGrants = manualAccessibilityGrants.filter { $0.value.grant?.isRestored == false }
        return manualAccessibilityGrants[processIdentifier]?.grant
    }

    /// Call when a captured destination is discarded without delivery. Turns off AXManualAccessibility if
    /// Keystorm turned it on for this capture and no other live capture relies on it. Idempotent; delivery
    /// does the same, and so does releasing the target. The target itself is not invalidated.
    func releaseCapturedTarget(_ target: DictationCapturedTarget) {
        target.releaseManualAccessibility()
    }

    /// `exclusions` are the user's exclusions as they are now, at Finish: an app or website blocked during the
    /// recording is never written to, and neither is an excluded app that focus moved into.
    func deliver(_ text: String, to target: DictationCapturedTarget, deliveryID: UUID,
                 exclusions: DictationUserExclusions = .empty) async -> DictationDeliveryReceipt {
        // Return the original acknowledgment for a duplicate UUID; never write twice.
        if let existing = receipts[deliveryID] { return existing }
        stopCorrectionObservation()
        if target.attemptedReceipt != nil {
            return record(.failed, "This destination has already been attempted. Check the destination before starting a new dictation.",
                          target: target, deliveryID: deliveryID)
        }
        // Whatever the outcome, accessibility mode Keystorm turned on for this capture ends with its delivery.
        // Placed after the attempted check: a target whose own delivery is still in flight is already marked
        // attempted (before any await), so only that delivery releases it. Every later exit makes this target
        // unusable, including the in-flight and ownership refusals below, which never concern the in-flight one.
        defer { target.releaseManualAccessibility() }
        guard inFlightDeliveryID == nil else {
            return record(.failed, "Another insertion is still being confirmed. Check the destination before starting again.", target: target, deliveryID: deliveryID)
        }
        inFlightDeliveryID = deliveryID
        defer { inFlightDeliveryID = nil }
        guard target.ownerID == ownerID else {
            return record(.failed, "This destination belongs to another dictation session.", target: target, deliveryID: deliveryID)
        }
        guard !Task.isCancelled else {
            return record(.failed, "Insertion was cancelled before any text was sent.", target: target, deliveryID: deliveryID)
        }
        guard !text.isEmpty, text.utf16.count <= Self.maximumInsertionUTF16 else {
            return record(.failed, "The result is empty or too large for automatic insertion. Copy it instead.",
                          target: target, deliveryID: deliveryID)
        }
        if let refusal = exclusionRefusal(for: target, exclusions: exclusions) {
            return record(refusal.outcome, refusal.message, target: target, deliveryID: deliveryID)
        }
        guard adapter.isTrusted else {
            return record(.failed, "Accessibility access is unavailable. Copy the result instead.", target: target, deliveryID: deliveryID)
        }
        let app = DictationDeliveryApplication(processIdentifier: target.descriptor.processIdentifier,
            bundleIdentifier: target.descriptor.bundleIdentifier, name: target.descriptor.appName)
        if target.strategy == .pasteFallback {
            return await deliverPasteFallback(text, to: target, application: app, deliveryID: deliveryID,
                                              websites: exclusions.websites)
        }
        guard isStillFocused(target.field, application: app) else {
            return record(.targetChanged, "The destination app or text field changed. Copy the result instead.",
                          target: target, deliveryID: deliveryID)
        }
        do {
            let metadata = try adapter.metadata(for: target.field)
            guard metadata.processIdentifier == app.processIdentifier, metadata.supportsInsertion,
                  metadata.role == target.qualifiedRole else {
                return record(.targetChanged, "The destination no longer supports safe insertion.", target: target, deliveryID: deliveryID)
            }
            if let refusal = websiteRefusal(for: target.field, websites: exclusions.websites) {
                return record(refusal.outcome, refusal.message, target: target, deliveryID: deliveryID)
            }
            let current = try adapter.snapshot(of: target.field, maximumUTF16: Self.maximumFieldUTF16)
            guard current.isValid(maximumUTF16: Self.maximumFieldUTF16),
                  current.selection == target.selection,
                  current.text.utf16.count == target.textLength,
                  SHA256.hash(data: Data(current.text.utf8)) == target.fingerprint else {
                return record(.targetChanged, "The text or selection changed. Copy the result instead.",
                              target: target, deliveryID: deliveryID)
            }
            let expected = (current.text as NSString).replacingCharacters(in: current.selection, with: text)
            guard expected.utf16.count <= Self.maximumFieldUTF16 else {
                return record(.failed, "The destination would exceed the safe insertion limit. Copy the result instead.",
                              target: target, deliveryID: deliveryID)
            }
            guard isStillFocused(target.field, application: app) else {
                return record(.targetChanged, "Focus changed before insertion. Copy the result instead.",
                              target: target, deliveryID: deliveryID)
            }
            var paste: (any DictationPasteOperation)?
            var mayRestoreClipboard = true
            defer { if mayRestoreClipboard { paste?.restoreIfOwned() } }
            if !metadata.selectedTextIsSettable {
                guard metadata.supportsPaste else {
                    return record(.failed, "This field has no supported insertion method.", target: target, deliveryID: deliveryID)
                }
                paste = try adapter.preparePaste(text, in: target.field, processIdentifier: app.processIdentifier)
                // Clipboard providers can take time to materialize. Validate the complete target again after staging.
                let latest = try adapter.snapshot(of: target.field, maximumUTF16: Self.maximumFieldUTF16)
                let latestMetadata = try adapter.metadata(for: target.field)
                guard latestMetadata.processIdentifier == app.processIdentifier, latestMetadata.supportsInsertion,
                      latestMetadata.role == target.qualifiedRole,
                      latest.isValid(maximumUTF16: Self.maximumFieldUTF16), latest.selection == target.selection,
                      SHA256.hash(data: Data(latest.text.utf8)) == target.fingerprint,
                      isStillFocused(target.field, application: app) else {
                    return record(.targetChanged, "The destination changed before pasting. Copy the result instead.",
                                  target: target, deliveryID: deliveryID)
                }
            }
            guard !Task.isCancelled else {
                return record(.failed, "Insertion was cancelled before any text was sent.", target: target, deliveryID: deliveryID)
            }
            // Mark the attempt before any await: reentrant calls must never issue another write.
            let pending = record(.uncertain, "Insertion was attempted. Check the destination before copying or retrying.",
                                 target: target, deliveryID: deliveryID)
            if let paste {
                guard paste.perform() else {
                    return record(.failed, "Paste was not sent because clipboard ownership or event access changed.",
                                  target: target, deliveryID: deliveryID)
                }
                // A delayed paste must never read a restored, unrelated clipboard.
                mayRestoreClipboard = false
            } else {
                let acknowledgment = adapter.replaceSelectedText(text, in: target.field)
                if acknowledgment == .rejected {
                    return record(.failed, "The destination refused insertion. Copy the result instead.",
                                  target: target, deliveryID: deliveryID)
                }
            }
            for check in 0..<20 {
                guard isStillFocused(target.field, application: app) else { break }
                if let after = try? adapter.snapshot(of: target.field, maximumUTF16: Self.maximumFieldUTF16),
                   after.isValid(maximumUTF16: Self.maximumFieldUTF16),
                   after.text.utf8.elementsEqual(expected.utf8) {
                    mayRestoreClipboard = true
                    target.confirmedCorrectionAnchor = ExternalCorrectionAnchor(fieldText: expected,
                        insertedRange: NSRange(location: current.selection.location, length: text.utf16.count), originalText: text)
                    target.confirmedCorrectionDeliveryID = deliveryID
                    return record(.confirmed, "Inserted into \(target.descriptor.appName).", target: target, deliveryID: deliveryID)
                }
                guard check < 19, !Task.isCancelled else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if paste != nil {
                return record(.uncertain, "Paste was sent but could not be confirmed. Check TextEdit before retrying. The result may remain on the clipboard.",
                              target: target, deliveryID: deliveryID)
            }
            return pending
        } catch {
            return record(.failed, "The destination could not be validated. Copy the result instead.", target: target, deliveryID: deliveryID)
        }
    }

    /// One directed Command-V into the field captured at Start, validated by identity, role and
    /// numeric selection only. Never presses Return, never retries, never reads the field's text.
    /// The caller has already applied the generic at-most-once, ownership, size and trust guards.
    private func deliverPasteFallback(_ text: String, to target: DictationCapturedTarget,
                                      application app: DictationDeliveryApplication,
                                      deliveryID: UUID, websites: [String]) async -> DictationDeliveryReceipt {
        guard isStillFocused(target.field, application: app) else {
            return record(.targetChanged, "The destination app or text field changed. Copy the result instead.",
                          target: target, deliveryID: deliveryID)
        }
        guard pasteFallbackFieldIsUnchanged(target, application: app) else {
            return record(.targetChanged, "The destination field or its selection changed. Copy the result instead.",
                          target: target, deliveryID: deliveryID)
        }
        if let refusal = websiteRefusal(for: target.field, websites: websites) {
            return record(refusal.outcome, refusal.message, target: target, deliveryID: deliveryID)
        }
        guard adapter.canPostPasteEvents else {
            return record(.failed, "Paste events are unavailable. Nothing was pasted; copy the result instead.",
                          target: target, deliveryID: deliveryID)
        }
        let paste: any DictationPasteOperation
        do {
            paste = try adapter.prepareFallbackPaste(text, processIdentifier: app.processIdentifier)
        } catch {
            return record(.failed, "The clipboard could not be prepared safely. Nothing was pasted; copy the result instead.",
                          target: target, deliveryID: deliveryID)
        }
        // Until a Command-V is posted, and after a confirmed read, every exit restores the user's clipboard,
        // and only while the lease still owns it. A sent but unconfirmed paste hands the result over instead.
        var restoresClipboard = true
        defer { if restoresClipboard { paste.restoreIfOwned() } }
        // Staging can take time. Revalidate the complete target once more before any event is posted.
        guard isStillFocused(target.field, application: app), pasteFallbackFieldIsUnchanged(target, application: app) else {
            return record(.targetChanged, "The destination changed before pasting. Copy the result instead.",
                          target: target, deliveryID: deliveryID)
        }
        if let refusal = websiteRefusal(for: target.field, websites: websites) {
            return record(refusal.outcome, refusal.message, target: target, deliveryID: deliveryID)
        }
        guard !Task.isCancelled else {
            return record(.failed, "Insertion was cancelled before any text was sent.", target: target, deliveryID: deliveryID)
        }
        // Mark the attempt before posting and before any await: reentrant calls must never paste again.
        _ = record(.uncertain, "Paste was attempted. Check the destination before copying or retrying.",
                   target: target, deliveryID: deliveryID)
        guard paste.perform() else {
            return record(.failed, "Paste was not sent because clipboard ownership or event access changed.",
                          target: target, deliveryID: deliveryID)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: pasteTiming.evidenceTimeout)
        while !paste.stagedTextWasRead, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: pasteTiming.pollInterval)
        }
        if paste.stagedTextWasRead {
            // Let the destination finish reading before the original clipboard returns.
            try? await Task.sleep(for: pasteTiming.settleDelay)
            return record(.pasted, "Pasted into \(target.descriptor.appName).", target: target, deliveryID: deliveryID)
        }
        // Sent, but no read evidence by the deadline (or cancelled after posting). The destination may still
        // paste late, and it must never read a restored, unrelated clipboard: leave the result there instead,
        // so the user can simply press Command-V. Nothing restores the original clipboard after this point.
        restoresClipboard = false
        let name = target.descriptor.appName
        guard paste.leaveStagedTextOnPasteboard() else {
            // A newer copy replaced the staged result; it is left untouched.
            return record(.uncertain, "Paste was sent to \(name) but could not be confirmed. " +
                          "Check \(name) before pasting again; the result is ready to copy.",
                          target: target, deliveryID: deliveryID)
        }
        return record(.uncertain, "Paste was sent to \(name) but could not be confirmed. " +
                      "The result is on the clipboard. Check \(name) before pasting again. " +
                      "Your previous clipboard was not restored.",
                      target: target, deliveryID: deliveryID)
    }

    private struct DeliveryRefusal {
        let outcome: DictationDeliveryOutcome
        let message: String
    }

    /// Finish-time app exclusions, decided from app identity alone (NSWorkspace, not Accessibility): an excluded
    /// app that focus moved into is refused before any of its elements could be read or written.
    private func exclusionRefusal(for target: DictationCapturedTarget,
                                  exclusions: DictationUserExclusions) -> DeliveryRefusal? {
        let destination = target.descriptor
        if isExcluded(destination.bundleIdentifier, exclusions: exclusions) {
            return DeliveryRefusal(outcome: .failed, message: "Dictation is now excluded in \(destination.appName). " +
                "Nothing was inserted; the result is ready to copy.")
        }
        if let front = adapter.frontmostApplication(),
           front.processIdentifier != destination.processIdentifier || front.bundleIdentifier != destination.bundleIdentifier,
           isExcluded(front.bundleIdentifier, exclusions: exclusions) {
            return DeliveryRefusal(outcome: .targetChanged, message: "The destination changed to an app where dictation " +
                "is excluded. Nothing was inserted; the result is ready to copy.")
        }
        return nil
    }

    /// Finish-time website exclusions, against the blocked websites as they are now. An address that can no longer
    /// be read is refused like a blocked one.
    private func websiteRefusal(for field: any DictationDeliveryField, websites: [String]) -> DeliveryRefusal? {
        switch websiteVerdict(for: field, websites: websites) {
        case .blocked:
            return DeliveryRefusal(outcome: .failed, message: "Dictation is excluded on this website. " +
                "Nothing was inserted; the result is ready to copy.")
        case .unverified:
            return DeliveryRefusal(outcome: .failed, message: "This page's address couldn't be checked against your " +
                "blocked websites. Nothing was inserted; the result is ready to copy.")
        case .notChecked, .notWebContent, .allowed:
            return nil
        }
    }

    private func pasteFallbackFieldIsUnchanged(_ target: DictationCapturedTarget,
                                               application app: DictationDeliveryApplication) -> Bool {
        guard let metadata = try? adapter.metadata(for: target.field),
              metadata.processIdentifier == app.processIdentifier, !metadata.isSecure,
              metadata.acceptsPasteFallback, metadata.role == target.pasteRole else { return false }
        guard let captured = target.pasteSelection else { return true }
        return adapter.selectedTextRange(of: target.field) == captured
    }

    var hasActiveCorrectionObservation: Bool { correctionLease?.isActive == true }

    /// Arms only an already-confirmed, qualified insertion. No fallback polling.
    @discardableResult
    func startCorrectionObservation(to target: DictationCapturedTarget, deliveredText: String, deliveryID: UUID,
                                    isEnabled: @escaping @MainActor () -> Bool,
                                    onObservation: @escaping @MainActor (ExternalCorrectionObservation) -> Void) -> Bool {
        stopCorrectionObservation()
        // Single handoff: the captured destination never keeps observation data.
        defer {
            target.confirmedCorrectionAnchor = nil
            target.confirmedCorrectionDeliveryID = nil
        }
        guard !Task.isCancelled, isEnabled(), adapter.isTrusted, target.ownerID == ownerID,
              target.strategy == .qualifiedTextEdit,
              target.descriptor.bundleIdentifier == "com.apple.TextEdit",
              !excludedBundleIdentifiers.contains(target.descriptor.bundleIdentifier),
              target.confirmedCorrectionDeliveryID == deliveryID,
              receipts[deliveryID]?.outcome == .confirmed,
              target.attemptedReceipt?.deliveryID == deliveryID,
              target.attemptedReceipt?.outcome == .confirmed,
              let anchor = target.confirmedCorrectionAnchor,
              anchor.originalText.utf8.elementsEqual(deliveredText.utf8) else { return false }
        let app = DictationDeliveryApplication(processIdentifier: target.descriptor.processIdentifier,
            bundleIdentifier: target.descriptor.bundleIdentifier, name: target.descriptor.appName)
        let read: @MainActor () -> DictationFieldSnapshot? = { [weak self] in
            guard let self, self.adapter.isTrusted, self.isStillFocused(target.field, application: app),
                  let metadata = try? self.adapter.metadata(for: target.field),
                  metadata.processIdentifier == app.processIdentifier, metadata.supportsInsertion,
                  let snapshot = try? self.adapter.snapshot(of: target.field, maximumUTF16: Self.maximumFieldUTF16),
                  snapshot.isValid(maximumUTF16: Self.maximumFieldUTF16),
                  // Revalidate focus after the cross-process read too.
                  self.isStillFocused(target.field, application: app) else { return nil }
            return snapshot
        }
        guard let initial = read(), case .unchanged = anchor.change(in: initial.text) else { return false }
        let lease = ExternalCorrectionLease(anchor: anchor, destination: target.descriptor, deliveryID: deliveryID,
            scheduler: correctionScheduler, isEnabled: isEnabled, read: read, onObservation: onObservation)
        correctionLease = lease
        guard let observation = adapter.observeChanges(of: target.field, processIdentifier: app.processIdentifier,
            onEvent: { [weak lease] event in lease?.receive(event) }) else {
            stopCorrectionObservation()
            return false
        }
        lease.attach(observation)
        // Reject a registration race rather than attributing an unobserved edit.
        guard lease.isActive, isEnabled(), let armed = read(), case .unchanged = anchor.change(in: armed.text) else {
            stopCorrectionObservation()
            return false
        }
        return true
    }

    func stopCorrectionObservation() {
        correctionLease?.stop()
        correctionLease = nil
    }

    private func isStillFocused(_ field: any DictationDeliveryField, application: DictationDeliveryApplication) -> Bool {
        guard let front = adapter.frontmostApplication(),
              front.processIdentifier == application.processIdentifier,
              front.bundleIdentifier == application.bundleIdentifier,
              let focused = try? adapter.focusedField(in: application) else { return false }
        return adapter.sameField(field, focused)
    }

    private func record(_ outcome: DictationDeliveryOutcome, _ message: String,
                        target: DictationCapturedTarget, deliveryID: UUID) -> DictationDeliveryReceipt {
        let receipt = DictationDeliveryReceipt(deliveryID: deliveryID, outcome: outcome, message: message,
                                              destination: target.descriptor)
        receipts[deliveryID] = receipt
        target.attemptedReceipt = receipt
        return receipt
    }
}

private enum DictationAXError: Error { case unavailable, unsupported, exceedsLimit }

@MainActor
private final class NativeDictationDeliveryField: DictationDeliveryField {
    let element: AXUIElement
    init(_ element: AXUIElement) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, 0.25)
    }
}

@MainActor
private final class NativeDictationDeliveryAdapter: DictationDeliveryAdapter {
    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func frontmostApplication() -> DictationDeliveryApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, let identifier = app.bundleIdentifier else { return nil }
        return DictationDeliveryApplication(processIdentifier: app.processIdentifier,
            bundleIdentifier: identifier, name: app.localizedName ?? identifier)
    }

    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField {
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let value = try attribute(kAXFocusedUIElementAttribute, of: app)
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw DictationAXError.unavailable }
        return NativeDictationDeliveryField(unsafeBitCast(value, to: AXUIElement.self))
    }

    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool {
        guard let a = lhs as? NativeDictationDeliveryField, let b = rhs as? NativeDictationDeliveryField else { return false }
        return CFEqual(a.element, b.element)
    }

    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        let element = try native(field)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let role = try attribute(kAXRoleAttribute, of: element) as? String else { throw DictationAXError.unavailable }
        // Security markers: absent means not set, but an unreadable marker is unknown and fails closed. A subrole
        // lost to a timeout must never let a secure text field pass as a plain one.
        let subroleValue = try optionalAttribute(kAXSubroleAttribute, of: element)
        guard subroleValue == nil || subroleValue is String else { throw DictationAXError.unavailable }
        let subrole = subroleValue as? String
        let protectedValue = try optionalAttribute("AXProtectedContent", of: element)
        // A value of an unexpected type is treated as protected.
        let protected = protectedValue.map { ($0 as? NSNumber)?.boolValue ?? true } ?? false
        // Labels only (aria-label, title, placeholder); a label that cannot be read is simply absent.
        let labels = [kAXDescriptionAttribute, kAXTitleAttribute].compactMap { (try? attribute($0, of: element)) as? String }
        let placeholder = (try? attribute("AXPlaceholderValue", of: element)) as? String
        let sensitivity = DictationFieldMetadata(processIdentifier: pid, role: role, subrole: subrole,
            isEnabled: false, isProtected: protected, selectedTextIsSettable: false,
            hasSecureLabel: DictationFieldMetadata.isSecureLabel(labels + [placeholder].compactMap { $0 }),
            secureEventInput: IsSecureEventInputEnabled())
        // Do not even query insertion capabilities for secure elements.
        if sensitivity.isSecure { return sensitivity }
        var enabledValue: CFTypeRef?
        let enabledStatus = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue)
        let enabled = DictationFieldMetadata.resolvedEnabled(status: enabledStatus, value: enabledValue)
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        var valueSettable = DarwinBoolean(false)
        let editable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success && valueSettable.boolValue
        let qualifiedPaste = role == "AXTextArea" && editable && CGPreflightPostEventAccess() &&
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.TextEdit"
        return DictationFieldMetadata(processIdentifier: pid, role: role, subrole: subrole,
            isEnabled: enabled, isProtected: false, selectedTextIsSettable: status == .success && settable.boolValue,
            supportsPaste: qualifiedPaste, valueIsSettable: editable,
            isTerminalInput: isTerminalInput(element, labels: labels))
    }

    /// xterm.js marks its hidden input with a DOM class (Chromium and Electron expose `AXDOMClassList`) and
    /// labels it "Terminal input" (the aria-label becomes `AXDescription`). Metadata only, never AXValue.
    private func isTerminalInput(_ element: AXUIElement, labels: [String]) -> Bool {
        let classes = ((try? attribute("AXDOMClassList", of: element)) as? [Any])?.compactMap { $0 as? String } ?? []
        if DictationFieldMetadata.isTerminalInput(domClassList: classes, labels: []) { return true }
        return DictationFieldMetadata.isTerminalInput(domClassList: [], labels: labels)
    }

    /// The deepest element chain this walks. Each step is one bounded Accessibility call, and the first error
    /// (including a 0.25 s messaging timeout) ends the walk as unavailable.
    private static let maximumWebAncestry = 256

    /// Walks AXParent from the field to the application, collecting each AXWebArea's AXURL on the way.
    /// Reads roles and document addresses only; never AXValue, selection or any text.
    func webDocumentURLs(containing field: any DictationDeliveryField) -> DictationWebDocumentLookup {
        guard var element = try? native(field) else { return .unavailable }
        var documents: [URL?] = []
        for _ in 0..<Self.maximumWebAncestry {
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
                  let role = roleValue as? String else { return .unavailable }
            if role == "AXWebArea" { documents.append(documentURL(of: element)) }
            var parentValue: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) {
            case .success:
                guard let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return .unavailable }
                element = unsafeBitCast(parentValue, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(element, 0.25)
            case .noValue, .attributeUnsupported:
                // The top of the tree.
                return documents.isEmpty ? .notWebContent : .webContent(documents)
            default:
                return .unavailable
            }
        }
        return .unavailable
    }

    private func documentURL(of webArea: AXUIElement) -> URL? {
        guard let value = try? attribute("AXURL", of: webArea) else { return nil }
        if let url = value as? URL { return url }
        return (value as? String).flatMap { URL(string: $0) }
    }

    /// nil when the attribute is absent; throws when its state is unknown.
    private func optionalAttribute(_ name: String, of element: AXUIElement) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard DictationFieldMetadata.optionalAttributeIsKnown(status: status) else { throw DictationAXError.unavailable }
        return status == .success ? value : nil
    }

    func manualAccessibility(in application: DictationDeliveryApplication) -> Bool? {
        ((try? attribute("AXManualAccessibility", of: applicationElement(application))) as? NSNumber)?.boolValue
    }

    func setManualAccessibility(_ enabled: Bool, in application: DictationDeliveryApplication) -> Bool {
        // Chromium and Electron build their tree on request. Failure is expected for other apps.
        AXUIElementSetAttributeValue(applicationElement(application), "AXManualAccessibility" as CFString,
                                     enabled ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    private func applicationElement(_ application: DictationDeliveryApplication) -> AXUIElement {
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return app
    }

    func selectedTextRange(of field: any DictationDeliveryField) -> NSRange? {
        guard let element = try? native(field) else { return nil }
        return try? selection(of: element)
    }

    var canPostPasteEvents: Bool { CGPreflightPostEventAccess() }

    func prepareFallbackPaste(_ text: String, processIdentifier: Int32) throws -> any DictationPasteOperation {
        guard CGPreflightPostEventAccess(),
              let operation = NativeDictationPasteOperation(text: text, processIdentifier: processIdentifier,
                                                            providesTextLazily: true) else {
            throw DictationAXError.unsupported
        }
        return operation
    }

    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        let element = try native(field)
        let beforeSelection = try selection(of: element)
        let count = try characterCount(of: element, maximum: maximumUTF16)
        guard beforeSelection.location >= 0, beforeSelection.length >= 0, beforeSelection.location <= count,
              beforeSelection.length <= count - beforeSelection.location else { throw DictationAXError.unavailable }
        let text: String
        if count == 0 {
            text = ""
        } else {
            var range = CFRange(location: 0, length: count)
            guard let parameter = AXValueCreate(.cfRange, &range) else { throw DictationAXError.unavailable }
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                parameter, &value) == .success, let result = value as? String,
                result.utf16.count == count else { throw DictationAXError.unavailable }
            text = result
        }
        guard try characterCount(of: element, maximum: maximumUTF16) == count,
              try selection(of: element) == beforeSelection else { throw DictationAXError.unavailable }
        return DictationFieldSnapshot(text: text, selection: beforeSelection)
    }

    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        guard let element = try? native(field) else { return .rejected }
        // Never substitute a whole-field AXValue write or a synthetic paste for this operation.
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        switch result {
        case .success: return .accepted
        case .cannotComplete, .failure: return .unknown
        default: return .rejected
        }
    }

    func observeChanges(of field: any DictationDeliveryField, processIdentifier: Int32,
                        onEvent: @escaping @MainActor (DictationFieldObservationEvent) -> Void) -> (any ExternalCorrectionCancellation)? {
        guard let element = try? native(field),
              let observation = NativeDictationFieldObservation(element: element, processIdentifier: processIdentifier, onEvent: onEvent),
              observation.start() else { return nil }
        return observation
    }

    func preparePaste(_ text: String, in field: any DictationDeliveryField, processIdentifier: Int32) throws -> any DictationPasteOperation {
        _ = try native(field)
        guard CGPreflightPostEventAccess(), let operation = NativeDictationPasteOperation(text: text, processIdentifier: processIdentifier) else {
            throw DictationAXError.unsupported
        }
        return operation
    }

    private func native(_ field: any DictationDeliveryField) throws -> AXUIElement {
        guard let native = field as? NativeDictationDeliveryField else { throw DictationAXError.unsupported }
        return native.element
    }

    private func attribute(_ name: String, of element: AXUIElement) throws -> CFTypeRef {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success,
              let result else { throw DictationAXError.unavailable }
        return result
    }

    private func characterCount(of element: AXUIElement, maximum: Int) throws -> Int {
        guard let number = try attribute(kAXNumberOfCharactersAttribute, of: element) as? NSNumber else {
            throw DictationAXError.unavailable
        }
        let count = number.intValue
        guard count >= 0, count <= maximum else { throw DictationAXError.exceedsLimit }
        return count
    }

    private func selection(of element: AXUIElement) throws -> NSRange {
        let value = try attribute(kAXSelectedTextRangeAttribute, of: element)
        guard CFGetTypeID(value) == AXValueGetTypeID() else { throw DictationAXError.unavailable }
        let rangeValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range) else {
            throw DictationAXError.unavailable
        }
        return NSRange(location: range.location, length: range.length)
    }
}


/// AX callbacks are installed only on the main run loop. The callback context
/// stays retained until registrations and the run-loop source have been removed.
@MainActor
private final class NativeDictationObservationContext {
    var onEvent: (@MainActor (DictationFieldObservationEvent) -> Void)?
    init(_ onEvent: @escaping @MainActor (DictationFieldObservationEvent) -> Void) { self.onEvent = onEvent }
    func receive(_ notification: CFString) {
        onEvent?((notification as String) == kAXValueChangedNotification ? .valueChanged : .invalidated)
    }
}

@MainActor
private final class NativeDictationFieldObservation: ExternalCorrectionCancellation {
    private let element: AXUIElement
    private let application: AXUIElement
    private let processIdentifier: Int32
    private var observer: AXObserver?
    private var context: NativeDictationObservationContext?
    private var registrations: [(AXUIElement, CFString)] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false

    init?(element: AXUIElement, processIdentifier: Int32,
          onEvent: @escaping @MainActor (DictationFieldObservationEvent) -> Void) {
        self.element = element
        self.processIdentifier = processIdentifier
        application = AXUIElementCreateApplication(processIdentifier)
        context = NativeDictationObservationContext(onEvent)
        AXUIElementSetMessagingTimeout(application, 0.25)
    }

    isolated deinit { cancel() }

    func start() -> Bool {
        guard !started, let context else { return false }
        var created: AXObserver?
        let status = AXObserverCreate(processIdentifier, { _, _, notification, refcon in
            guard let refcon else { return }
            // This source is added exclusively to CFRunLoopGetMain().
            MainActor.assumeIsolated {
                let context = Unmanaged<NativeDictationObservationContext>.fromOpaque(refcon).takeUnretainedValue()
                context.receive(notification)
            }
        }, &created)
        guard status == .success, let created else { cancel(); return false }
        observer = created
        let requested: [(AXUIElement, CFString)] = [
            (element, kAXValueChangedNotification as CFString),
            (application, kAXFocusedUIElementChangedNotification as CFString),
            (element, kAXUIElementDestroyedNotification as CFString)
        ]
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        for (field, notification) in requested {
            guard AXObserverAddNotification(created, field, notification, refcon) == .success else {
                cancel()
                return false
            }
            registrations.append((field, notification))
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.processIdentifier == self.processIdentifier else { return }
                    self.context?.onEvent?(.invalidated)
                }
            })
        }
        return true
    }

    func cancel() {
        // Invalidate first: a callback already on the main stack becomes inert.
        context?.onEvent = nil
        if let observer {
            for (field, notification) in registrations {
                _ = AXObserverRemoveNotification(observer, field, notification)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        registrations.removeAll()
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObservers.removeAll()
        observer = nil
        context = nil
        started = false
    }
}


/// Backs up every advertised representation, or refuses to stage anything. No lossy string-only restoration.
@MainActor
final class DictationClipboardLease {
    static let maximumBackupBytes = 8 * 1_024 * 1_024
    private static let markerType = NSPasteboard.PasteboardType("dev.mitternacht.Keystorm.dictation.clipboard-lease")
    /// macOS treats these hints as advisory; destination and system clipboard behavior remain outside our control.
    private static let hintTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                    "org.nspasteboard.AutoGeneratedType"].map(NSPasteboard.PasteboardType.init(rawValue:))
    private let pasteboard: NSPasteboard
    private let original: [[NSPasteboard.PasteboardType: Data]]
    private let marker = Data(UUID().uuidString.utf8)
    private let text: String
    private var stagedChangeCount: Int = -1
    /// Present only for a lazily provided lease. Held strongly while the item may be on the pasteboard.
    private let textProvider: DictationClipboardTextProvider?
    /// Set once the staged result was handed to the user; nothing restores the original after that.
    private var leftOnPasteboard = false

    /// Whether a pasteboard's contents may be backed up for later restoration.
    /// `.alwaysDeny` refuses programmatic reads (only user-originated pastes are allowed), so a backup
    /// could come back empty or partial and "restoring" it would silently destroy the user's clipboard.
    /// `.default` and `.ask` keep working: the backup read may show the system's pasteboard access alert
    /// once, and a denial there makes the read fail, so nothing is staged.
    nonisolated static func canBackUp(accessBehavior: NSPasteboard.AccessBehavior) -> Bool {
        switch accessBehavior {
        case .default, .ask, .alwaysAllow: true
        case .alwaysDeny: false
        @unknown default: false
        }
    }

    var isOwned: Bool {
        pasteboard.changeCount == stagedChangeCount && pasteboard.data(forType: Self.markerType) == marker
    }

    /// True once the staged text was requested after `armReadEvidence()`. Reads before arming
    /// (for example by a clipboard manager) never count. Always false for an eagerly staged lease.
    var stagedTextWasRead: Bool { textProvider?.wasReadWhileArmed ?? false }

    /// Call immediately before posting the paste event.
    func armReadEvidence() { textProvider?.arm() }

    /// `providesTextLazily` keeps the marker and clipboard hints eager but supplies the `.string`
    /// representation on request, which makes a destination's read observable.
    /// `accessBehavior` overrides the pasteboard's own privacy setting for tests; nil reads the pasteboard.
    init?(text: String, pasteboard: NSPasteboard = .general, providesTextLazily: Bool = false,
          accessBehavior: NSPasteboard.AccessBehavior? = nil) {
        // Checked before any read or write: no backup means no staging, never a lossy restoration.
        guard Self.canBackUp(accessBehavior: accessBehavior ?? pasteboard.accessBehavior) else { return nil }
        self.pasteboard = pasteboard
        self.text = text
        textProvider = providesTextLazily ? DictationClipboardTextProvider(text: text) : nil
        let originalChangeCount = pasteboard.changeCount
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        var totalBytes = 0
        // nil is a retrieval error, not an empty clipboard (which is an empty array).
        guard let items = pasteboard.pasteboardItems else { return nil }
        for item in items {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                guard data.count <= Self.maximumBackupBytes - totalBytes else { return nil }
                totalBytes += data.count
                representations[type] = data
            }
            saved.append(representations)
        }
        guard pasteboard.changeCount == originalChangeCount else { return nil }
        original = saved
        guard let item = Self.stagedItem(text: text, provider: textProvider, marker: marker) else { return nil }
        let cleared = pasteboard.clearContents()
        guard pasteboard.changeCount == cleared else { return nil }
        guard pasteboard.writeObjects([item]) else {
            if pasteboard.changeCount == cleared { restoreOriginal() }
            return nil
        }
        stagedChangeCount = pasteboard.changeCount
    }

    /// A lazy item must not outlive its provider on the pasteboard. Eager leases keep their
    /// existing behavior: an uncertain qualified paste intentionally leaves its staged result.
    /// After `leaveStagedTextOnPasteboard()` the result is concrete data and this restores nothing.
    isolated deinit {
        if textProvider != nil { restoreIfOwned() }
    }

    func restoreIfOwned() {
        guard !leftOnPasteboard, isOwned else { return }
        restoreOriginal()
        stagedChangeCount = -1
    }

    /// Hands the staged result to the user after a paste that was sent but never confirmed.
    /// A lazily provided item is replaced, only while this lease still owns the pasteboard, by an eagerly
    /// written copy of the same text with the same marker and hints, so it outlives this lease and the app.
    /// Disarms every later restoration, including the release-time one. Returns whether the result is on
    /// the pasteboard; a newer copy is never overwritten.
    @discardableResult
    func leaveStagedTextOnPasteboard() -> Bool {
        guard !leftOnPasteboard else { return isOwned }
        leftOnPasteboard = true
        guard isOwned else { return false }
        // An eager lease already holds concrete data.
        guard textProvider != nil else { return true }
        guard let item = Self.stagedItem(text: text, provider: nil, marker: marker) else { return false }
        let cleared = pasteboard.clearContents()
        guard pasteboard.changeCount == cleared, pasteboard.writeObjects([item]) else { return false }
        stagedChangeCount = pasteboard.changeCount
        return true
    }

    /// The staged item: `.string` (lazily when a provider is given), the lease marker and the clipboard hints.
    private static func stagedItem(text: String, provider: DictationClipboardTextProvider?,
                                   marker: Data) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        if let provider {
            guard item.setDataProvider(provider, forTypes: [.string]) else { return nil }
        } else {
            guard item.setString(text, forType: .string) else { return nil }
        }
        item.setData(marker, forType: markerType)
        for type in hintTypes { item.setData(Data(), forType: type) }
        return item
    }

    private func restoreOriginal() {
        let items = original.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        let cleared = pasteboard.clearContents()
        guard pasteboard.changeCount == cleared else { return }
        if !items.isEmpty { _ = pasteboard.writeObjects(items) }
    }
}

/// Supplies the staged `.string` on request. Pasteboard callbacks are nonisolated and may arrive
/// on any thread, so the only shared state is a lock-protected pair of flags.
final class DictationClipboardTextProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private struct State {
        var armed = false
        var readWhileArmed = false
    }
    private let text: String
    private let state = Mutex(State())

    init(text: String) {
        self.text = text
    }

    func arm() { state.withLock { $0.armed = true } }

    var wasReadWhileArmed: Bool { state.withLock { $0.readWhileArmed } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .string else { return }
        item.setString(text, forType: .string)
        state.withLock { if $0.armed { $0.readWhileArmed = true } }
    }
}

@MainActor
private final class NativeDictationPasteOperation: DictationPasteOperation {
    private let processIdentifier: Int32
    private let down: CGEvent
    private let up: CGEvent
    private let lease: DictationClipboardLease
    private var performed = false

    init?(text: String, processIdentifier: Int32, providesTextLazily: Bool = false) {
        // Resolved once per paste, on the main actor: Text Input Sources must not be queried off the main thread.
        let pasteKey = DictationPasteKeyCode.current()
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: pasteKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: pasteKey, keyDown: false),
              let lease = DictationClipboardLease(text: text, providesTextLazily: providesTextLazily) else { return nil }
        source.localEventsSuppressionInterval = 0
        self.processIdentifier = processIdentifier
        self.down = down
        self.up = up
        self.lease = lease
        down.flags = .maskCommand
        up.flags = .maskCommand
    }

    func perform() -> Bool {
        guard !performed, lease.isOwned, CGPreflightPostEventAccess() else { return false }
        performed = true
        lease.armReadEvidence()
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
        return true
    }

    func restoreIfOwned() { lease.restoreIfOwned() }

    func leaveStagedTextOnPasteboard() -> Bool { lease.leaveStagedTextOnPasteboard() }

    var stagedTextWasRead: Bool { lease.stagedTextWasRead }
}

/// The virtual key that types "v" with Command held in the current keyboard layout, so the one synthetic
/// Command-V is the user's paste shortcut. A fixed kVK_ANSI_V would send Command-K on Dvorak.
/// The Command modifier state matters: "Dvorak - QWERTY ⌘" types "v" on kVK_ANSI_Period without modifiers,
/// but Command switches it to QWERTY, where that key is Command-period. Non-Latin layouts map Command to
/// QWERTY too, so their unmodified tables contain no "v" at all.
enum DictationPasteKeyCode {
    static let fallback = CGKeyCode(kVK_ANSI_V)
    static let candidates: Range<UInt16> = 0..<128

    /// Pure resolution. `translate` returns what a virtual key types with Command held, or nil when it types
    /// nothing; a nil `translate` means the layout data is unavailable. kVK_ANSI_V wins whenever it qualifies,
    /// otherwise the lowest qualifying key code. Anything else falls back to kVK_ANSI_V.
    static func resolve(translate: ((UInt16) -> String?)?) -> CGKeyCode {
        guard let translate else { return fallback }
        if translate(UInt16(fallback)) == "v" { return fallback }
        return candidates.first { translate($0) == "v" } ?? fallback
    }

    /// Reads the current keyboard layout. Some input methods expose no Unicode layout data; they get kVK_ANSI_V.
    @MainActor
    static func current() -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return resolve(translate: nil)
        }
        return virtualKey(in: source)
    }

    /// Resolves against one keyboard layout input source without selecting it.
    @MainActor
    static func virtualKey(in source: TISInputSource) -> CGKeyCode {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return resolve(translate: nil)
        }
        // The layout data follows the Get rule: it lives as long as `source`.
        return withExtendedLifetime(source) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
                  let bytes = CFDataGetBytePtr(data) else { return resolve(translate: nil) }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            let keyboardType = UInt32(LMGetKbdType())
            let commandState = UInt32((cmdKey >> 8) & 0xFF)
            return resolve { keyCode in
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), commandState, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                            characters.count, &length, &characters)
                guard status == noErr, length > 0 else { return nil }
                return String(decoding: characters.prefix(length), as: UTF16.self)
            }
        }
    }
}
