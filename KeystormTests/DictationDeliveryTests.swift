import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Keystorm

@MainActor
struct DictationDeliveryTests {
    @Test("A mixed English/German insertion preserves the field's emoji and surrounding text")
    func mixedLanguageInsertionUsesUTF16Selection() async throws {
        let adapter = DeliveryTestAdapter(text: "Hello 👩🏽‍💻, replace this. Danke!")
        adapter.state.selection = (adapter.state.text as NSString).range(of: "replace this")
        let service = makeService(adapter)
        let target = try readyTarget(service)
        let receipt = await service.deliver("morgen ist das meeting in München", to: target, deliveryID: UUID())
        #expect(receipt.outcome == .confirmed)
        #expect(adapter.state.text == "Hello 👩🏽‍💻, morgen ist das meeting in München. Danke!")
        #expect(adapter.writeCount == 1)
        #expect(adapter.lastInsertedText == "morgen ist das meeting in München")
    }

    @Test("Focus, field identity, selection, and text changes prevent insertion", arguments: [
        DeliveryTestMutation.application, .process, .field, .selection, .text, .unicodeRepresentation
    ])
    func changedDestinationIsNeverWritten(_ mutation: DeliveryTestMutation) async throws {
        let adapter = DeliveryTestAdapter(text: "Keep café and 👩🏽‍💻.")
        let service = makeService(adapter)
        let target = try readyTarget(service)
        switch mutation {
        case .application: adapter.app.bundleIdentifier = "com.apple.Notes"
        case .process: adapter.app.processIdentifier += 1
        case .field: adapter.field = DeliveryTestField()
        case .selection: adapter.state.selection.location = 0
        case .text: adapter.state.text = "New! café and 👩🏽‍💻."
        case .unicodeRepresentation: adapter.state.text = "Keep cafe\u{301} and 👩🏽‍💻."
        }
        let receipt = await service.deliver("new dictation", to: target, deliveryID: UUID())
        #expect(receipt.outcome == .targetChanged)
        #expect(adapter.writeCount == 0)
    }

    @Test("Copy-only, excluded, and unknown apps are classified before any field access", arguments: [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.1password.1password", "com.agilebits.onepassword7", "com.example.Unknown", "com.apple.Safari"
    ])
    func deniedApplicationsAreNotInspected(_ identifier: String) {
        let adapter = DeliveryTestAdapter(text: "private content")
        adapter.app.bundleIdentifier = identifier
        let service = makeService(adapter)
        guard case .unavailable(let failure) = service.captureTarget() else {
            Issue.record("An unqualified application must not become a destination.")
            return
        }
        let terminal = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable"].contains(identifier)
        let passwordManager = ["com.1password.1password", "com.agilebits.onepassword7"].contains(identifier)
        #expect(failure == (terminal ? .copyOnlyApplication : (passwordManager ? .excludedApplication : .unsupportedApplication)))
        #expect(failure.blocksRecording == passwordManager)
        #expect(adapter.focusReads == 0)
        #expect(adapter.metadataReads == 0)
        #expect(adapter.snapshotReads == 0)
    }


    @Test("An explicitly excluded terminal still blocks local recording without inspecting its field")
    func explicitlyExcludedTerminalBlocksRecording() {
        let adapter = DeliveryTestAdapter(text: "private shell content")
        adapter.app.bundleIdentifier = "com.apple.Terminal"
        adapter.isTrusted = false
        let service = DictationDeliveryService(adapter: adapter, ownBundleIdentifier: "test.keystorm",
            ownProcessIdentifier: 900, excludedBundleIdentifiers: ["com.apple.Terminal"])
        guard case .unavailable(let failure) = service.captureTarget() else {
            Issue.record("Explicit exclusions must refuse capture.")
            return
        }
        #expect(failure == .excludedApplication)
        #expect(failure.blocksRecording)
        #expect(adapter.focusReads == 0)
        #expect(adapter.snapshotReads == 0)
    }

    @Test("Terminals allow local dictation with manual copy and never inspect shell text",
          arguments: ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable"])
    func terminalDictationIsCopyOnly(_ identifier: String) async {
        let adapter = DeliveryTestAdapter(text: "private shell content")
        adapter.app.bundleIdentifier = identifier
        let backend = DeliveryTestRecordingBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: makeService(adapter))
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .recording)
        #expect(coordinator.destinationLabel == "Copy after recording")
        #expect(backend.beginCount == 1)
        #expect(adapter.focusReads == 0)
        #expect(adapter.metadataReads == 0)
        #expect(adapter.snapshotReads == 0)
        #expect(adapter.writeCount == 0)
    }

    @Test("Password managers block recording even when Accessibility is off",
          arguments: ["com.1password.1password", "com.agilebits.onepassword7"])
    func passwordManagerCannotStartRecording(_ identifier: String) async {
        let adapter = DeliveryTestAdapter(text: "private vault content")
        adapter.app.bundleIdentifier = identifier
        adapter.isTrusted = false
        let backend = DeliveryTestRecordingBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: makeService(adapter))
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .failed)
        #expect(backend.beginCount == 0)
        #expect(adapter.focusReads == 0)
        #expect(adapter.snapshotReads == 0)
        #expect(adapter.writeCount == 0)
    }

    @Test("A secure field is refused before reading any text")
    func secureFieldIsNotRead() {
        let adapter = DeliveryTestAdapter(text: "secret")
        adapter.fieldMetadata.subrole = "AXSecureTextField"
        let service = makeService(adapter)
        guard case .unavailable(let failure) = service.captureTarget() else {
            Issue.record("Secure field capture must fail.")
            return
        }
        #expect(failure == .secureField)
        #expect(failure.blocksRecording)
        #expect(adapter.snapshotReads == 0)
        #expect(adapter.writeCount == 0)
    }

    @Test("Missing Accessibility access never requests consent or inspects a target")
    func untrustedCaptureIsNonPrompting() {
        let adapter = DeliveryTestAdapter(text: "private")
        adapter.isTrusted = false
        let service = makeService(adapter)
        guard case .unavailable(let failure) = service.captureTarget() else {
            Issue.record("Untrusted capture must fail.")
            return
        }
        #expect(failure == .accessibilityPermission)
        #expect(!failure.blocksRecording)
        #expect(adapter.permissionRequests == 0)
        #expect(adapter.focusReads == 0)
        service.requestAccessibilityPermission()
        #expect(adapter.permissionRequests == 1)
    }

    @Test("Read-only, disabled, and unknown-role fields are refused before text access", arguments: [
        DeliveryUnsupportedField.readOnly, .disabled, .unknownRole
    ])
    func unsupportedCapabilitiesAreNotRead(_ reason: DeliveryUnsupportedField) {
        let adapter = DeliveryTestAdapter(text: "preserve me")
        switch reason {
        case .readOnly: adapter.fieldMetadata.selectedTextIsSettable = false
        case .disabled: adapter.fieldMetadata.isEnabled = false
        case .unknownRole: adapter.fieldMetadata.role = "AXGroup"
        }
        let service = makeService(adapter)
        guard case .unavailable(let failure) = service.captureTarget() else {
            Issue.record("Unsupported fields must not become destinations.")
            return
        }
        #expect(failure == .unsupportedField)
        #expect(adapter.snapshotReads == 0)
    }

    @Test("The same delivery UUID and a second attempt on a captured field never insert twice")
    func deliveryIsAtMostOnce() async throws {
        let adapter = DeliveryTestAdapter(text: "Start ")
        let service = makeService(adapter)
        let target = try readyTarget(service)
        let id = UUID()
        let first = await service.deliver("Hallo", to: target, deliveryID: id)
        let replay = await service.deliver("different text", to: target, deliveryID: id)
        #expect(replay == first)
        #expect(first.outcome == .confirmed)
        #expect(await service.deliver("Hallo again", to: target, deliveryID: UUID()).outcome == .failed)
        #expect(adapter.state.text == "Start Hallo")
        #expect(adapter.writeCount == 1)
    }

    @Test("An unknown acknowledgment stays uncertain when insertion cannot be verified")
    func uncertainDeliveryNeverBlindlyRetries() async throws {
        let adapter = DeliveryTestAdapter(text: "Keep ")
        adapter.acknowledgment = .unknown
        adapter.applyWrite = false
        let service = makeService(adapter)
        let target = try readyTarget(service)
        let id = UUID()
        let receipt = await service.deliver("Hallo", to: target, deliveryID: id)
        #expect(receipt.outcome == .uncertain)
        #expect(await service.deliver("Hallo", to: target, deliveryID: id) == receipt)
        #expect(await service.deliver("Hallo", to: target, deliveryID: UUID()).outcome == .failed)
        #expect(adapter.writeCount == 1)
        #expect(adapter.state.text == "Keep ")
    }

    @Test("A timed-out write can be confirmed only by observing the exact expected text")
    func unknownAcknowledgmentWithVerifiedTextIsConfirmed() async throws {
        let adapter = DeliveryTestAdapter(text: "Keep ")
        adapter.acknowledgment = .unknown
        let service = makeService(adapter)
        let receipt = await service.deliver("Grüße aus Berlin", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .confirmed)
        #expect(adapter.writeCount == 1)
    }

    @Test("A successful AX return without the expected field change stays uncertain")
    func acceptedButUnobservedWriteIsUncertain() async throws {
        let adapter = DeliveryTestAdapter(text: "Keep ")
        adapter.applyWrite = false
        let service = makeService(adapter)
        let receipt = await service.deliver("result", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .uncertain)
        #expect(adapter.writeCount == 1)
    }

    @Test("Protected state or permission revoked after capture prevents a write")
    func permissionsAndSecurityAreRevalidated() async throws {
        let adapter = DeliveryTestAdapter(text: "Keep ")
        let service = makeService(adapter)
        let target = try readyTarget(service)
        adapter.fieldMetadata.isProtected = true
        #expect(await service.deliver("result", to: target, deliveryID: UUID()).outcome == .targetChanged)
        #expect(adapter.writeCount == 0)

        adapter.fieldMetadata.isProtected = false
        let anotherTarget = try readyTarget(service)
        adapter.isTrusted = false
        #expect(await service.deliver("result", to: anotherTarget, deliveryID: UUID()).outcome == .failed)
        #expect(adapter.writeCount == 0)
    }

    @Test("Invalid UTF-16 ranges and oversized fields fail closed")
    func malformedOrOversizedSnapshotsAreRefused() {
        let adapter = DeliveryTestAdapter(text: "😀")
        let service = makeService(adapter)
        adapter.state.selection = NSRange(location: 1, length: 0)
        guard case .unavailable(.unavailableField) = service.captureTarget() else {
            Issue.record("A range splitting a surrogate pair must fail.")
            return
        }
        adapter.state.text = String(repeating: "a", count: DictationDeliveryService.maximumFieldUTF16 + 1)
        adapter.state.selection = NSRange(location: 0, length: 0)
        guard case .unavailable(.unavailableField) = service.captureTarget() else {
            Issue.record("Oversized fields must fail.")
            return
        }
        #expect(adapter.writeCount == 0)
    }

    @Test("The serializable destination and receipt contain no field content")
    func persistedDescriptorContainsOnlyApplicationMetadata() throws {
        let marker = "never persist this field content"
        let adapter = DeliveryTestAdapter(text: marker)
        let service = makeService(adapter)
        let target = try readyTarget(service)
        let data = try JSONEncoder().encode(target.descriptor)
        #expect(!String(decoding: data, as: UTF8.self).contains(marker))
        #expect(try JSONDecoder().decode(DictationDestinationDescriptor.self, from: data) == target.descriptor)
        #expect(target.contextExcerpt.utf16.count <= 256)
    }


    @Test("A cancelled delivery task never changes the destination")
    func cancellationPreventsInsertion() async throws {
        let adapter = DeliveryTestAdapter(text: "Keep ")
        let service = makeService(adapter)
        let target = try readyTarget(service)
        let task = Task { @MainActor in
            await service.deliver("Hallo", to: target, deliveryID: UUID())
        }
        task.cancel()
        let receipt = await task.value
        #expect(receipt.outcome == .failed)
        #expect(adapter.writeCount == 0)
        #expect(adapter.state.text == "Keep ")
    }

    @Test("The qualified paste route revalidates the field after clipboard staging")
    func pastePreparationCannotBypassTargetValidation() async throws {
        let adapter = DeliveryTestAdapter(text: "Keep ")
        adapter.fieldMetadata.selectedTextIsSettable = false
        adapter.fieldMetadata.supportsPaste = true
        adapter.changeTextDuringPastePreparation = true
        let service = makeService(adapter)
        let receipt = await service.deliver("Hallo", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .targetChanged)
        #expect(adapter.writeCount == 0)
        #expect(adapter.pasteOperation?.restoreCount == 1)
    }

    @Test("A qualified paste restores its lease after observing the exact insertion")
    func confirmedPasteRestoresClipboard() async throws {
        let adapter = DeliveryTestAdapter(text: "Keep ")
        adapter.fieldMetadata.selectedTextIsSettable = false
        adapter.fieldMetadata.supportsPaste = true
        let service = makeService(adapter)
        let receipt = await service.deliver("Grüße", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .confirmed)
        #expect(adapter.writeCount == 1)
        #expect(adapter.pasteOperation?.restoreCount == 1)
    }

    @Test("Lost clipboard ownership prevents any paste event")
    func lostLeaseNeverPastes() async throws {
        let adapter = DeliveryTestAdapter(text: "Keep ")
        adapter.fieldMetadata.selectedTextIsSettable = false
        adapter.fieldMetadata.supportsPaste = true
        adapter.pasteCanPerform = false
        let service = makeService(adapter)
        let receipt = await service.deliver("Hallo", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .failed)
        #expect(adapter.writeCount == 0)
        #expect(adapter.pasteOperation?.restoreCount == 1)
    }

    @Test("An uncertain queued paste keeps its staged result instead of restoring unrelated data")
    func uncertainPasteDoesNotRestoreClipboardPrematurely() async throws {
        let adapter = DeliveryTestAdapter(text: "Keep ")
        adapter.fieldMetadata.selectedTextIsSettable = false
        adapter.fieldMetadata.supportsPaste = true
        adapter.applyWrite = false
        let service = makeService(adapter)
        let receipt = await service.deliver("Hallo", to: try readyTarget(service), deliveryID: UUID())
        #expect(receipt.outcome == .uncertain)
        #expect(adapter.writeCount == 1)
        #expect(adapter.pasteOperation?.restoreCount == 0)
    }

    @Test("Clipboard leases preserve all item representations and respect newer user copies")
    func realNamedClipboardLeaseRestoresWithoutClobbering() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Keystorm-Delivery-Test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("test.keystorm.binary")
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        original.setData(Data([0, 1, 2, 255]), forType: customType)
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([original]))
        let lease = try #require(DictationClipboardLease(text: "Hallo 👋", pasteboard: pasteboard))
        #expect(lease.isOwned)
        #expect(pasteboard.string(forType: .string) == "Hallo 👋")
        lease.restoreIfOwned()
        #expect(pasteboard.string(forType: .string) == "original")
        #expect(pasteboard.data(forType: customType) == Data([0, 1, 2, 255]))

        let nextLease = try #require(DictationClipboardLease(text: "second dictation", pasteboard: pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)
        #expect(!nextLease.isOwned)
        nextLease.restoreIfOwned()
        #expect(pasteboard.string(forType: .string) == "new user copy")
    }

    @Test("Oversized clipboard backups are refused before mutation")
    func oversizedClipboardIsPreserved() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Keystorm-Delivery-Test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let binary = NSPasteboard.PasteboardType("test.keystorm.large")
        pasteboard.clearContents()
        let data = Data(repeating: 7, count: DictationClipboardLease.maximumBackupBytes + 1)
        pasteboard.setData(data, forType: binary)
        let originalCount = pasteboard.changeCount
        #expect(DictationClipboardLease(text: "dictation", pasteboard: pasteboard) == nil)
        #expect(pasteboard.changeCount == originalCount)
        #expect(pasteboard.data(forType: binary) == data)
    }


    @Test("Opt-in: real TextEdit insertion through the production Accessibility/clipboard adapter",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_DICTATION_DELIVERY"] == "1"))
    func nativeTextEditInsertionAndClipboardRestoration() async throws {
        let service = DictationDeliveryService()
        guard service.isAccessibilityTrusted else {
            try Test.cancel("Native delivery was not run: the Keystorm test host lacks existing Accessibility permission. No permission prompt was requested.")
        }
        guard CGPreflightPostEventAccess() else {
            try Test.cancel("Native delivery was not run: this test host cannot post events. No event-access prompt was requested.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-TextEdit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixtureURL = folder.appendingPathComponent("Dictation-delivery-" + UUID().uuidString + ".txt")
        let prefix = "Keep 👩🏽‍💻. "
        try prefix.write(to: fixtureURL, atomically: true, encoding: .utf8)
        let existingPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").map(\.processIdentifier))
        let previouslyFrontmost = NSWorkspace.shared.frontmostApplication
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        let textEditURL = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit"))
        let application = try await NSWorkspace.shared.open([fixtureURL], withApplicationAt: textEditURL, configuration: configuration)
        // A reused process may contain personal windows: never write to or terminate it.
        try #require(!existingPIDs.contains(application.processIdentifier), "TextEdit must launch a dedicated disposable instance.")
        defer {
            _ = application.forceTerminate()
            _ = previouslyFrontmost?.activate(options: [])
        }
        var field: AXUIElement?
        for _ in 0..<30 {
            _ = application.activate(options: [])
            if let candidate = try? nativeFocusedField(processIdentifier: application.processIdentifier),
               (try? nativeString(kAXValueAttribute, of: candidate)) == prefix {
                field = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let editor = try #require(field, "The disposable TextEdit document did not become a readable focused editor.")
        var range = CFRange(location: prefix.utf16.count, length: 0)
        let axRange = try #require(AXValueCreate(.cfRange, &range))
        try #require(AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, axRange) == .success,
                     "The fixture must set its own caret before capture.")
        let captured: DictationCapturedTarget
        switch service.captureTarget() {
        case .ready(let target): captured = target
        case .unavailable(let failure):
            Issue.record("Native TextEdit capture failed: \(failure.message)")
            return
        }
        let text: String
        if let path = ProcessInfo.processInfo.environment["KEYSTORM_DICTATION_DELIVERY_TEXT_PATH"] {
            text = try String(contentsOfFile: path, encoding: .utf8)
            print("Native delivery input: supplied ASR output fixture; this test qualifies delivery, not audio capture.")
        } else {
            text = "Please verschiebe das Meeting auf morgen. Grüße aus München! 👋"
            print("Native delivery input: literal mixed English/German/emoji fixture; no ASR claim.")
        }
        let clipboardBefore = nativeClipboardSnapshot()
        let receipt = await service.deliver(text, to: captured, deliveryID: UUID())
        #expect(receipt.outcome == .confirmed, "Production delivery must observe the exact TextEdit result.")
        let value = try nativeString(kAXValueAttribute, of: editor)
        #expect(value.utf8.elementsEqual((prefix + text).utf8))
        let clipboardRestored = clipboardBefore == nativeClipboardSnapshot()
        #expect(clipboardRestored, "All original clipboard item representations must be restored after confirmed insertion.")
        print("Native delivery evidence: outcome=\(receipt.outcome.rawValue), UTF16=\(text.utf16.count), clipboardRestored=\(clipboardRestored)")
    }

    private func nativeFocusedField(processIdentifier: Int32) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw DeliveryTestError.unexpectedCaptureFailure }
        let field = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(field, 0.25)
        return field
    }

    private func nativeString(_ attribute: String, of field: AXUIElement) throws -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, attribute as CFString, &value) == .success,
              let text = value as? String else { throw DeliveryTestError.unexpectedCaptureFailure }
        return text
    }

    private func nativeClipboardSnapshot() -> [[String: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        }
    }

    private func makeService(_ adapter: DeliveryTestAdapter) -> DictationDeliveryService {
        DictationDeliveryService(adapter: adapter, ownBundleIdentifier: "test.keystorm", ownProcessIdentifier: 900)
    }

    private func readyTarget(_ service: DictationDeliveryService) throws -> DictationCapturedTarget {
        guard case .ready(let target) = service.captureTarget() else {
            throw DeliveryTestError.unexpectedCaptureFailure
        }
        return target
    }
}

enum DeliveryTestMutation: Sendable { case application, process, field, selection, text, unicodeRepresentation }
enum DeliveryUnsupportedField: Sendable { case readOnly, disabled, unknownRole }
private enum DeliveryTestError: Error { case unexpectedCaptureFailure }


@MainActor
private final class DeliveryTestRecordingBackend: DictationRecordingBackend {
    var beginCount = 0
    func dictationBegin() async throws -> DictationRecordingHandle {
        beginCount += 1
        return DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {}
    func dictationResume(_ handle: DictationRecordingHandle) async throws {}
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        throw DeliveryTestError.unexpectedCaptureFailure
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? { nil }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {}
}

@MainActor private final class DeliveryTestField: DictationDeliveryField {}

/// Exercises the service's production validation; this adapter only substitutes external AX I/O.
@MainActor
private final class DeliveryTestAdapter: DictationDeliveryAdapter {
    var isTrusted = true
    var app = DictationDeliveryApplication(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
    var field = DeliveryTestField()
    var state: DictationFieldSnapshot
    var fieldMetadata = DictationFieldMetadata(processIdentifier: 42, role: "AXTextArea", subrole: nil,
        isEnabled: true, isProtected: false, selectedTextIsSettable: true)
    var acknowledgment: DictationReplacementAcknowledgment = .accepted
    var applyWrite = true
    var focusReads = 0
    var metadataReads = 0
    var snapshotReads = 0
    var permissionRequests = 0
    var writeCount = 0
    var lastInsertedText: String?
    var changeTextDuringPastePreparation = false
    var pasteCanPerform = true
    var pasteOperation: DeliveryTestPasteOperation?

    init(text: String) {
        state = DictationFieldSnapshot(text: text, selection: NSRange(location: text.utf16.count, length: 0))
    }

    func requestPermission() { permissionRequests += 1 }
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { app }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField {
        focusReads += 1
        return field
    }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { lhs === rhs }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        metadataReads += 1
        return fieldMetadata
    }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        snapshotReads += 1
        return state
    }
    func preparePaste(_ text: String, in field: any DictationDeliveryField, processIdentifier: Int32) throws -> any DictationPasteOperation {
        if changeTextDuringPastePreparation { state.text += "changed" }
        let operation = DeliveryTestPasteOperation(canPerform: pasteCanPerform) { [self] in
            _ = replaceSelectedText(text, in: field)
        }
        pasteOperation = operation
        return operation
    }

    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        writeCount += 1
        lastInsertedText = text
        if applyWrite && acknowledgment != .rejected {
            state.text = (state.text as NSString).replacingCharacters(in: state.selection, with: text)
            state.selection = NSRange(location: state.selection.location + text.utf16.count, length: 0)
        }
        return acknowledgment
    }
}

@MainActor
private final class DeliveryTestPasteOperation: DictationPasteOperation {
    let canPerform: Bool
    let action: () -> Void
    var restoreCount = 0
    private var performed = false
    init(canPerform: Bool, action: @escaping () -> Void) {
        self.canPerform = canPerform
        self.action = action
    }
    func perform() -> Bool {
        guard canPerform, !performed else { return false }
        performed = true
        action()
        return true
    }
    func restoreIfOwned() { restoreCount += 1 }
    func leaveStagedTextOnPasteboard() -> Bool { true }
}
