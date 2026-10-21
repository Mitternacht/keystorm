import Foundation
import Testing
@testable import Keystorm

/// Delivery safety rows: mislabelled secure fields, excluded apps at Start and Finish, and moved-element races.
/// The fake adapter substitutes only external Accessibility, clipboard and event I/O; every decision runs through
/// the production delivery service and coordinator.
@MainActor
@Suite(.serialized)
struct DeliverySafetyTests {
    // MARK: (a) Mislabelled secure fields

    @Test("A field whose role says text field but carries any secure hint is refused at Start, before text or selection is read",
          arguments: DeliverySafetyPath.allCases, DeliverySafetySecureHint.allCases)
    func secureHintIsRefusedAtStart(_ path: DeliverySafetyPath, _ hint: DeliverySafetySecureHint) throws {
        let adapter = DeliverySafetyAdapter(path)
        hint.apply(to: &adapter.fieldMetadata)
        #expect(adapter.fieldMetadata.isSecure)
        let capture = DeliverySafetyAdapter.service(adapter)
            .captureForStart(contextSettings: .init(mode: .nearbyText), pasteIntoOtherApps: true)
        let failure = try #require(deliverySafetyFailure(capture.target), "A secure hint must refuse the destination.")
        #expect(failure == hint.expectedFailure)
        #expect(failure.blocksRecording, "Known secure targets refuse recording before the microphone starts.")
        #expect(capture.context == nil)
        #expect(adapter.snapshotReads == 0)
        #expect(adapter.selectionReads == 0)
        #expect(adapter.writes == 0)
    }

    @Test("Each role a text-entry element may report is refused once its subrole says secure text field",
          arguments: ["AXTextField", "AXTextArea", "AXComboBox"])
    func secureSubroleOnAnyTextRole(_ role: String) throws {
        for path in DeliverySafetyPath.allCases {
            let adapter = DeliverySafetyAdapter(path)
            adapter.fieldMetadata.role = role
            adapter.fieldMetadata.subrole = "AXSecureTextField"
            let failure = try #require(deliverySafetyFailure(DeliverySafetyAdapter.service(adapter)
                .captureTarget(pasteIntoOtherApps: true)))
            #expect(failure == .secureField)
            #expect(adapter.snapshotReads == 0)
            #expect(adapter.selectionReads == 0)
        }
    }

    @Test("A field that turns secure between Start and Finish is never written",
          arguments: DeliverySafetyPath.allCases, DeliverySafetySecureHint.allCases)
    func fieldTurningSecureIsNotWritten(_ path: DeliverySafetyPath, _ hint: DeliverySafetySecureHint) async throws {
        let adapter = DeliverySafetyAdapter(path)
        let service = DeliverySafetyAdapter.service(adapter)
        let target = try adapter.readyTarget(service)
        hint.apply(to: &adapter.fieldMetadata)
        let receipt = await service.deliver("Grüße aus München", to: target, deliveryID: UUID())
        #expect(receipt.outcome == .targetChanged)
        #expect(adapter.writes == 0)
        #expect(adapter.fallbackPreparations == 0, "The clipboard is never staged for a secure field.")
    }

    @Test("The coordinator refuses to record while secure keyboard entry is on, and says why")
    func secureKeyboardEntryBlocksRecording() async {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        adapter.fieldMetadata.secureEventInput = true
        let backend = DeliverySafetyBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: DeliverySafetyAdapter.service(adapter))
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .failed)
        #expect(coordinator.message == DictationCaptureFailure.secureInput.message)
        #expect(backend.beginModes.isEmpty)
        #expect(adapter.selectionReads == 0)
    }

    // MARK: (b) Excluded apps

    @Test("Built-in and user-blocked apps are refused at Start before any Accessibility access, with no context",
          arguments: [
            DeliverySafetyExclusion(bundle: "com.1password.1password", userBlocked: false),
            DeliverySafetyExclusion(bundle: "com.apple.Passwords", userBlocked: false),
            DeliverySafetyExclusion(bundle: "com.example.Vault", userBlocked: true),
            DeliverySafetyExclusion(bundle: "com.apple.TextEdit", userBlocked: true),
            DeliverySafetyExclusion(bundle: "com.apple.Terminal", userBlocked: true)
          ])
    func excludedAppRefusedAtStart(_ exclusion: DeliverySafetyExclusion) throws {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        adapter.app.bundleIdentifier = exclusion.bundle
        adapter.isTrusted = false
        let exclusions = DictationUserExclusions(applications: exclusion.userBlocked ? [exclusion.bundle] : [])
        let capture = DeliverySafetyAdapter.service(adapter).captureForStart(contextSettings: .init(mode: .nearbyText),
            pasteIntoOtherApps: true, exclusions: exclusions)
        let failure = try #require(deliverySafetyFailure(capture.target))
        #expect(failure == .excludedApplication)
        #expect(failure.blocksRecording)
        #expect(capture.context == nil)
        #expect(capture.applicationBundleIdentifier == nil, "No preset applies to an app that cannot record.")
        #expect(adapter.focusRequests.isEmpty)
        #expect(adapter.metadataReads == 0)
        #expect(adapter.webLookups == 0)
    }

    @Test("Without the user's block, the same app is an ordinary destination")
    func unblockedAppIsCaptured() throws {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        adapter.app.bundleIdentifier = "com.example.Vault"
        let target = try adapter.readyTarget(DeliverySafetyAdapter.service(adapter))
        #expect(target.descriptor.bundleIdentifier == "com.example.Vault")
    }

    @Test("Focus that moved into an excluded app by Finish is refused from its identity alone; nothing reaches that app",
          arguments: DeliverySafetyPath.allCases, [
            DeliverySafetyExclusion(bundle: "com.1password.1password", userBlocked: false),
            DeliverySafetyExclusion(bundle: "com.example.Vault", userBlocked: true)
          ])
    func focusMovedIntoExcludedAppAtFinish(_ path: DeliverySafetyPath, _ exclusion: DeliverySafetyExclusion) async throws {
        let adapter = DeliverySafetyAdapter(path)
        let service = DeliverySafetyAdapter.service(adapter)
        let target = try adapter.readyTarget(service)
        let focusRequests = adapter.focusRequests.count
        let metadataReads = adapter.metadataReads
        adapter.app = DictationDeliveryApplication(processIdentifier: 501, bundleIdentifier: exclusion.bundle, name: "Vault")
        let exclusions = DictationUserExclusions(applications: exclusion.userBlocked ? [exclusion.bundle] : [])
        let id = UUID()
        let receipt = await service.deliver("Grüße aus München", to: target, deliveryID: id, exclusions: exclusions)
        #expect(receipt.outcome == .targetChanged)
        #expect(receipt.message.contains("dictation is excluded"))
        #expect(adapter.focusRequests.count == focusRequests, "No Accessibility request reaches any app at Finish.")
        #expect(!adapter.focusRequests.contains(exclusion.bundle))
        #expect(adapter.metadataReads == metadataReads)
        #expect(adapter.writes == 0)
        #expect(adapter.fallbackPreparations == 0)
        // At most once: a replay returns the refusal and a new attempt never writes either.
        #expect(await service.deliver("again", to: target, deliveryID: id, exclusions: exclusions) == receipt)
        adapter.app = adapter.capturedApp
        #expect(await service.deliver("again", to: target, deliveryID: UUID()).outcome == .failed)
        #expect(adapter.writes == 0)
    }

    @Test("A destination the user blocks during the recording is refused at Finish without being touched",
          arguments: DeliverySafetyPath.allCases)
    func destinationBlockedDuringRecording(_ path: DeliverySafetyPath) async throws {
        let adapter = DeliverySafetyAdapter(path)
        let service = DeliverySafetyAdapter.service(adapter)
        let target = try adapter.readyTarget(service)
        let focusRequests = adapter.focusRequests.count
        let exclusions = DictationUserExclusions(applications: [adapter.app.bundleIdentifier])
        let receipt = await service.deliver("Hallo", to: target, deliveryID: UUID(), exclusions: exclusions)
        #expect(receipt.outcome == .failed)
        #expect(receipt.message.hasPrefix("Dictation is now excluded in \(adapter.app.name)."))
        #expect(adapter.focusRequests.count == focusRequests)
        #expect(adapter.writes == 0)
        #expect(adapter.fallbackPreparations == 0)
    }

    @Test("The coordinator refuses to record in an app the user blocked and never inspects it")
    func coordinatorRefusesUserBlockedApp() async {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        let preferences = DictationPreferences()
        preferences.blockApplication(bundleIdentifier: adapter.app.bundleIdentifier, name: adapter.app.name)
        let backend = DeliverySafetyBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: DeliverySafetyAdapter.service(adapter),
                                               preferences: preferences)
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .failed)
        #expect(coordinator.message == DictationCaptureFailure.excludedApplication.message)
        #expect(coordinator.contextProfile == nil)
        #expect(backend.beginModes.isEmpty)
        #expect(adapter.focusRequests.isEmpty)
        #expect(backend.deliveries.isEmpty)
    }

    @Test("Finish in the coordinator: blocking the destination or moving focus into an excluded app saves a refusal, never a write",
          arguments: [DeliverySafetyFinishExclusion.blockedDuringRecording, .focusMovedToPasswordManager, .focusMovedToUserBlockedApp])
    func coordinatorRefusesExcludedAppAtFinish(_ scenario: DeliverySafetyFinishExclusion) async {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        let preferences = DictationPreferences()
        // Only the refusal receipt is under test; Copy when not inserted is covered in DictationCoordinatorTests.
        preferences.copyWhenNotInserted = false
        let backend = DeliverySafetyBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: DeliverySafetyAdapter.service(adapter),
                                               preferences: preferences)
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .recording)
        #expect(coordinator.destinationLabel == "Paste into Notes")
        switch scenario {
        case .blockedDuringRecording:
            preferences.blockApplication(bundleIdentifier: "com.apple.Notes", name: "Notes")
        case .focusMovedToPasswordManager:
            adapter.app = DictationDeliveryApplication(processIdentifier: 501, bundleIdentifier: "com.bitwarden.desktop",
                                                       name: "Bitwarden")
        case .focusMovedToUserBlockedApp:
            preferences.blockApplication(bundleIdentifier: "com.example.Vault", name: "Vault")
            adapter.app = DictationDeliveryApplication(processIdentifier: 501, bundleIdentifier: "com.example.Vault", name: "Vault")
        }
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .ready)
        #expect(adapter.writes == 0)
        #expect(adapter.fallbackPreparations == 0)
        let expected: DictationDeliveryState = scenario == .blockedDuringRecording ? .failed : .targetChanged
        #expect(backend.deliveries.map(\.state) == [.pending, expected])
        #expect(coordinator.message.contains("Nothing was inserted"))
    }

    @Test("Nearby text read before the user blocked the destination never reaches the text model at Finish",
          arguments: [false, true])
    func blockedDestinationGetsNoContextAtFinish(_ blockedDuringRecording: Bool) async throws {
        let adapter = DeliverySafetyAdapter(.qualified)
        let preferences = DictationPreferences()
        preferences.mode = .clean
        preferences.contextMode = .nearbyText
        // Keeps the user's clipboard untouched; Copy when not inserted is covered in DictationCoordinatorTests.
        preferences.copyWhenNotInserted = false
        let backend = DeliverySafetyBackend()
        backend.reportsMetadata = true
        let coordinator = DictationCoordinator(backend: backend, delivery: DeliverySafetyAdapter.service(adapter),
                                               preferences: preferences)
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .recording)
        #expect(coordinator.contextStatus == "Nearby text")
        if blockedDuringRecording {
            preferences.blockApplication(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
        }
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        let context = try #require(backend.transformContexts.first, "Clean Finish reaches the text model.")
        #expect(backend.transformContexts.count == 1)
        if blockedDuringRecording {
            #expect(context == nil)
        } else {
            #expect(context?.availability == .nearbyText)
        }
        #expect(adapter.writes == 0, "The transform fails, so nothing is delivered.")
    }

    // MARK: (c) Moved-element races

    @Test("TextEdit: any change of app, process, element, role, selection or text between Start and Finish prevents the write",
          arguments: DeliverySafetyMove.allCases)
    func qualifiedMoveIsNeverWritten(_ move: DeliverySafetyMove) async throws {
        try await expectMoveRefused(move, path: .qualified)
    }

    @Test("Paste fallback: any change of app, process, element, role or selection between Start and Finish prevents the paste",
          arguments: DeliverySafetyMove.allCases.filter { $0 != .textChanged })
    func pasteMoveIsNeverPasted(_ move: DeliverySafetyMove) async throws {
        try await expectMoveRefused(move, path: .pasteFallback)
    }

    private func expectMoveRefused(_ move: DeliverySafetyMove, path: DeliverySafetyPath) async throws {
        let adapter = DeliverySafetyAdapter(path)
        let service = DeliverySafetyAdapter.service(adapter)
        let target = try adapter.readyTarget(service)
        move.apply(to: adapter)
        let textBeforeFinish = adapter.state.text
        let id = UUID()
        let receipt = await service.deliver("Grüße aus München", to: target, deliveryID: id)
        #expect([DictationDeliveryOutcome.targetChanged, .failed].contains(receipt.outcome))
        #expect(adapter.writes == 0)
        #expect(adapter.fallbackPreparations == 0)
        #expect(adapter.state.text == textBeforeFinish, "The destination text is untouched.")
        // At most once: the same request returns the same receipt, and restoring the original state does not
        // make the spent destination writable again.
        #expect(await service.deliver("Grüße aus München", to: target, deliveryID: id) == receipt)
        adapter.restore()
        #expect(await service.deliver("Grüße aus München", to: target, deliveryID: UUID()).outcome == .failed)
        #expect(adapter.writes == 0)
    }

    @Test("Leaving and returning to the very same field before Finish still delivers once, into that field",
          arguments: DeliverySafetyPath.allCases)
    func returnToSameFieldDeliversOnce(_ path: DeliverySafetyPath) async throws {
        let adapter = DeliverySafetyAdapter(path)
        let service = DeliverySafetyAdapter.service(adapter)
        let target = try adapter.readyTarget(service)
        adapter.app = DictationDeliveryApplication(processIdentifier: 78, bundleIdentifier: "com.apple.Safari", name: "Safari")
        adapter.app = adapter.capturedApp
        let receipt = await service.deliver("Hallo", to: target, deliveryID: UUID())
        #expect(receipt.outcome == (path == .qualified ? .confirmed : .pasted))
        #expect(adapter.writes == 1)
        if path == .qualified { #expect(adapter.state.text == "Before Hallo after") }
    }

    @Test("A change while the clipboard is staged prevents the paste and restores the clipboard",
          arguments: [DeliverySafetyMove.appSwitched, .elementDestroyed, .roleChanged, .selectionMoved, .elementInOtherProcess])
    func moveDuringStagingIsNotPasted(_ move: DeliverySafetyMove) async throws {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        let service = DeliverySafetyAdapter.service(adapter)
        let target = try adapter.readyTarget(service)
        adapter.onPrepare = { move.apply(to: adapter) }
        let receipt = await service.deliver("Hallo", to: target, deliveryID: UUID())
        #expect(receipt.outcome == .targetChanged)
        #expect(adapter.fallbackPreparations == 1)
        #expect(adapter.performCount == 0)
        #expect(adapter.pasteOperation?.restoreCount == 1)
        #expect(adapter.pasteOperation?.leaveCount == 0)
    }

    @Test("Focus moving away right after the write never causes a second write", arguments: DeliverySafetyPath.allCases)
    func moveAfterWriteNeverWritesAgain(_ path: DeliverySafetyPath) async throws {
        let adapter = DeliverySafetyAdapter(path)
        let service = DeliverySafetyAdapter.service(adapter)
        let target = try adapter.readyTarget(service)
        adapter.onWrite = { DeliverySafetyMove.appSwitched.apply(to: adapter) }
        let receipt = await service.deliver("Hallo", to: target, deliveryID: UUID())
        #expect(adapter.writes == 1)
        // TextEdit cannot confirm the write once focus left, so it stays uncertain; the paste was already read.
        #expect(receipt.outcome == (path == .qualified ? .uncertain : .pasted))
        adapter.restore()
        #expect(await service.deliver("Hallo", to: target, deliveryID: UUID()).outcome == .failed)
        #expect(adapter.writes == 1)
    }

    @Test("Two deliveries racing for the same captured field write at most once", arguments: DeliverySafetyPath.allCases)
    func racingDeliveriesWriteOnce(_ path: DeliverySafetyPath) async throws {
        let adapter = DeliverySafetyAdapter(path)
        adapter.readsOnPerform = false
        let service = DeliverySafetyAdapter.service(adapter)
        let target = try adapter.readyTarget(service)
        async let first = service.deliver("Hallo", to: target, deliveryID: UUID())
        async let second = service.deliver("Hallo", to: target, deliveryID: UUID())
        let outcomes = await [first.outcome, second.outcome]
        #expect(adapter.writes == 1)
        #expect(outcomes.contains(.failed))
    }
}

// MARK: - Fixtures

enum DeliverySafetyPath: CaseIterable, Sendable, CustomTestStringConvertible {
    /// The qualified TextEdit adapter: fingerprinted text, exact confirmation.
    case qualified
    /// Any other app with Paste into other apps on: metadata only, one Command-V.
    case pasteFallback
    var testDescription: String { self == .qualified ? "TextEdit" : "paste fallback" }
}

enum DeliverySafetySecureHint: CaseIterable, Sendable, CustomTestStringConvertible {
    case secureSubrole, secureSubroleOddSpelling, customPasswordRole, protectedContent
    case passwordLabel, germanPasswordLabel, secureKeyboardEntry

    var testDescription: String {
        switch self {
        case .secureSubrole: "text field role with AXSecureTextField subrole"
        case .secureSubroleOddSpelling: "subrole \" axsecuretextfield \""
        case .customPasswordRole: "custom AXPasswordField role"
        case .protectedContent: "AXProtectedContent"
        case .passwordLabel: "label \"Password\""
        case .germanPasswordLabel: "placeholder \"Kennwort eingeben\""
        case .secureKeyboardEntry: "secure keyboard entry on"
        }
    }

    var expectedFailure: DictationCaptureFailure {
        self == .secureKeyboardEntry ? .secureInput : .secureField
    }

    func apply(to metadata: inout DictationFieldMetadata) {
        switch self {
        case .secureSubrole: metadata.subrole = "AXSecureTextField"
        case .secureSubroleOddSpelling: metadata.subrole = " axsecuretextfield "
        case .customPasswordRole: metadata.role = "AXPasswordField"
        case .protectedContent: metadata.isProtected = true
        case .passwordLabel: metadata.hasSecureLabel = DictationFieldMetadata.isSecureLabel(["Password"])
        case .germanPasswordLabel: metadata.hasSecureLabel = DictationFieldMetadata.isSecureLabel(["Kennwort eingeben"])
        case .secureKeyboardEntry: metadata.secureEventInput = true
        }
    }
}

struct DeliverySafetyExclusion: Sendable, CustomTestStringConvertible {
    var bundle: String
    var userBlocked: Bool
    var testDescription: String { "\(bundle) (\(userBlocked ? "user-blocked" : "built-in"))" }
}

enum DeliverySafetyFinishExclusion: Sendable {
    case blockedDuringRecording, focusMovedToPasswordManager, focusMovedToUserBlockedApp
}

enum DeliverySafetyMove: CaseIterable, Sendable, CustomTestStringConvertible {
    case appSwitched, appQuit, processRelaunched, fieldReplaced, elementDestroyed, metadataUnreadable
    case roleChanged, elementInOtherProcess, selectionMoved, selectionUnreadable, textChanged

    var testDescription: String { "\(self)" }

    @MainActor
    func apply(to adapter: DeliverySafetyAdapter) {
        switch self {
        case .appSwitched:
            adapter.app = DictationDeliveryApplication(processIdentifier: 78, bundleIdentifier: "com.apple.Safari", name: "Safari")
        case .appQuit: adapter.frontmostIsNil = true
        case .processRelaunched: adapter.app.processIdentifier += 1000
        case .fieldReplaced: adapter.field = DeliverySafetyField()
        case .elementDestroyed: adapter.focusThrows = true
        case .metadataUnreadable: adapter.metadataThrows = true
        case .roleChanged: adapter.fieldMetadata.role = adapter.fieldMetadata.role == "AXTextArea" ? "AXTextField" : "AXTextArea"
        case .elementInOtherProcess: adapter.fieldMetadata.processIdentifier += 1000
        case .selectionMoved:
            adapter.selection = NSRange(location: 0, length: 3)
            adapter.state.selection = NSRange(location: 0, length: 3)
        case .selectionUnreadable:
            adapter.selection = nil
            adapter.state.selection = NSRange(location: 0, length: 0)
        case .textChanged: adapter.state.text = "Before! after"
        }
    }
}

@MainActor func deliverySafetyFailure(_ result: DictationCaptureResult) -> DictationCaptureFailure? {
    guard case .unavailable(let failure) = result else { return nil }
    return failure
}

enum DeliverySafetyError: Error { case unavailable, notReady }

@MainActor final class DeliverySafetyField: DictationDeliveryField {}

/// Substitutes external Accessibility, clipboard and event I/O only. Records which app every Accessibility
/// request addressed, so tests can prove an excluded app was never touched.
@MainActor
final class DeliverySafetyAdapter: DictationDeliveryAdapter {
    static let initialText = "Before  after"
    let path: DeliverySafetyPath
    let capturedApp: DictationDeliveryApplication
    private let capturedField: DeliverySafetyField
    private let capturedMetadata: DictationFieldMetadata

    var isTrusted = true
    var canPostPasteEvents = true
    var app: DictationDeliveryApplication
    var frontmostIsNil = false
    var field: DeliverySafetyField
    var fieldMetadata: DictationFieldMetadata
    var state: DictationFieldSnapshot
    var selection: NSRange? = NSRange(location: 7, length: 0)
    var focusThrows = false
    var metadataThrows = false
    var webLookup: DictationWebDocumentLookup = .notWebContent
    var readsOnPerform = true
    var onPrepare: (() -> Void)?
    /// Runs right after the external write or the posted paste.
    var onWrite: (() -> Void)?

    private(set) var focusRequests: [String] = []
    private(set) var metadataReads = 0
    private(set) var snapshotReads = 0
    private(set) var selectionReads = 0
    private(set) var webLookups = 0
    private(set) var textWrites = 0
    private(set) var fallbackPreparations = 0
    private(set) var pasteOperation: DeliverySafetyPasteOperation?
    var performCount: Int { pasteOperation?.performCount ?? 0 }
    var writes: Int { textWrites + performCount }

    init(_ path: DeliverySafetyPath) {
        let application: DictationDeliveryApplication
        let metadata: DictationFieldMetadata
        switch path {
        case .qualified:
            application = DictationDeliveryApplication(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit",
                                                       name: "TextEdit")
            metadata = DictationFieldMetadata(processIdentifier: 42, role: "AXTextArea", subrole: nil,
                isEnabled: true, isProtected: false, selectedTextIsSettable: true)
        case .pasteFallback:
            application = DictationDeliveryApplication(processIdentifier: 77, bundleIdentifier: "com.apple.Notes",
                                                       name: "Notes")
            metadata = DictationFieldMetadata(processIdentifier: 77, role: "AXTextArea", subrole: nil,
                isEnabled: true, isProtected: false, selectedTextIsSettable: false, valueIsSettable: true)
        }
        let initialField = DeliverySafetyField()
        self.path = path
        app = application
        capturedApp = application
        fieldMetadata = metadata
        capturedMetadata = metadata
        field = initialField
        capturedField = initialField
        state = DictationFieldSnapshot(text: Self.initialText, selection: NSRange(location: 7, length: 0))
    }

    /// Puts app, element, metadata and selection back exactly as they were at Start.
    func restore() {
        app = capturedApp
        frontmostIsNil = false
        field = capturedField
        fieldMetadata = capturedMetadata
        focusThrows = false
        metadataThrows = false
        selection = NSRange(location: 7, length: 0)
        state = DictationFieldSnapshot(text: Self.initialText, selection: NSRange(location: 7, length: 0))
    }

    static func service(_ adapter: DeliverySafetyAdapter) -> DictationDeliveryService {
        DictationDeliveryService(adapter: adapter, ownBundleIdentifier: "test.keystorm", ownProcessIdentifier: 900,
            pasteTiming: DictationPasteTiming(evidenceTimeout: .milliseconds(150), settleDelay: .milliseconds(5),
                                              pollInterval: .milliseconds(5)),
            accessibilityWarmUp: DictationAccessibilityWarmUp(timeout: .zero))
    }

    func readyTarget(_ service: DictationDeliveryService,
                     exclusions: DictationUserExclusions = .empty) throws -> DictationCapturedTarget {
        guard case .ready(let target) = service.captureTarget(pasteIntoOtherApps: true, exclusions: exclusions) else {
            throw DeliverySafetyError.notReady
        }
        return target
    }

    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { frontmostIsNil ? nil : app }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField {
        focusRequests.append(application.bundleIdentifier)
        if focusThrows { throw DeliverySafetyError.unavailable }
        return field
    }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { lhs === rhs }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        metadataReads += 1
        if metadataThrows { throw DeliverySafetyError.unavailable }
        return fieldMetadata
    }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        snapshotReads += 1
        return state
    }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        textWrites += 1
        state.text = (state.text as NSString).replacingCharacters(in: state.selection, with: text)
        state.selection = NSRange(location: state.selection.location + text.utf16.count, length: 0)
        onWrite?()
        return .accepted
    }
    func selectedTextRange(of field: any DictationDeliveryField) -> NSRange? {
        selectionReads += 1
        return selection
    }
    func prepareFallbackPaste(_ text: String, processIdentifier: Int32) throws -> any DictationPasteOperation {
        fallbackPreparations += 1
        let operation = DeliverySafetyPasteOperation(readsOnPerform: readsOnPerform, onPerform: onWrite)
        pasteOperation = operation
        onPrepare?()
        return operation
    }
    func webDocumentURLs(containing field: any DictationDeliveryField) -> DictationWebDocumentLookup {
        webLookups += 1
        return webLookup
    }
}

@MainActor
final class DeliverySafetyPasteOperation: DictationPasteOperation {
    let readsOnPerform: Bool
    let onPerform: (() -> Void)?
    private(set) var performCount = 0
    private(set) var restoreCount = 0
    private(set) var leaveCount = 0
    private(set) var stagedTextWasRead = false

    init(readsOnPerform: Bool, onPerform: (() -> Void)?) {
        self.readsOnPerform = readsOnPerform
        self.onPerform = onPerform
    }

    func perform() -> Bool {
        guard performCount == 0 else { return false }
        performCount += 1
        if readsOnPerform { stagedTextWasRead = true }
        onPerform?()
        return true
    }
    func restoreIfOwned() { restoreCount += 1 }
    func leaveStagedTextOnPasteboard() -> Bool {
        leaveCount += 1
        return true
    }
}

@MainActor
final class DeliverySafetyBackend: DictationRecordingBackend {
    let handle = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    let revision = DictationTextRevision(rawText: "Grüße aus München.", text: "Grüße aus München.", sourceTranscriptIDs: [])
    /// The Quick mode of every microphone start requested so far.
    private(set) var beginModes: [DictationQuickMode] = []
    private(set) var deliveries: [DictationDelivery] = []
    /// Opt-in: reports the completed revision as saved, so a Clean or Email Finish reaches the text model.
    var reportsMetadata = false
    /// The context each Finish transform received. The transform then fails, so nothing is ever delivered.
    private(set) var transformContexts: [DictationContextSnapshot?] = []

    func dictationBegin() async throws -> DictationRecordingHandle {
        try await dictationBegin(mode: .verbatim)
    }
    func dictationBegin(mode: DictationQuickMode) async throws -> DictationRecordingHandle {
        beginModes.append(mode)
        return handle
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {}
    func dictationResume(_ handle: DictationRecordingHandle) async throws {}
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision { revision }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? {
        reportsMetadata ? DictationRecordingMetadata(id: handle.takeID, state: .ready, textRevision: revision) : nil
    }
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode, context: DictationContextSnapshot?) async throws -> DictationTransformResult {
        transformContexts.append(context)
        throw DeliverySafetyError.unavailable
    }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        if let delivery { deliveries.append(delivery) }
    }
}
