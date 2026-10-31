import AppKit
import Foundation
import Testing
@testable import Keystorm

/// Undo of the last insertion, and capture of web and rich-text editors.
/// The fake adapter only substitutes external Accessibility and event I/O; every decision runs through the
/// production service. No real pasteboard, application or hardware is touched.
@MainActor
@Suite(.serialized)
struct DictationUndoAndWebEditorTests {
    // MARK: Undo, qualified field (exact range replacement)

    @Test("Undo restores the text a dictation replaced, and selects it again")
    func undoRestoresReplacedSelection() async throws {
        let adapter = UndoFakeAdapter(text: "Hello world", selection: NSRange(location: 6, length: 5))
        let service = makeService(adapter)
        let target = try readyTarget(service)
        let delivered = await service.deliver("Welt", to: target, deliveryID: UUID())
        #expect(delivered.outcome == .confirmed)
        #expect(adapter.text == "Hello Welt")
        #expect(service.canUndoLastInsertion)
        #expect(service.undoState.isAvailable)
        #expect(service.undoState.destinationName == "TextEdit")

        let receipt = await service.undoLastInsertion()
        #expect(receipt.outcome == .undone)
        #expect(adapter.text == "Hello world")
        #expect(adapter.selection == NSRange(location: 6, length: 5))
        #expect(adapter.rangeReplacements.count == 1)
        #expect(adapter.rangeReplacements.first?.range == NSRange(location: 6, length: 4))
        #expect(!service.canUndoLastInsertion)
        #expect(!service.undoState.isAvailable)
    }

    @Test("Undo removes an insertion at a caret")
    func undoRemovesCaretInsertion() async throws {
        let adapter = UndoFakeAdapter(text: "Dear Anna, ", selection: NSRange(location: 11, length: 0))
        let service = makeService(adapter)
        let target = try readyTarget(service)
        _ = await service.deliver("bis morgen 👩🏽‍💻", to: target, deliveryID: UUID())
        #expect(adapter.text == "Dear Anna, bis morgen 👩🏽‍💻")
        let receipt = await service.undoLastInsertion()
        #expect(receipt.outcome == .undone)
        #expect(adapter.text == "Dear Anna, ")
        #expect(adapter.selection == NSRange(location: 11, length: 0))
    }

    @Test("Text typed after the dictation is kept: only the inserted range is replaced")
    func undoLeavesLaterTypingAlone() async throws {
        let adapter = UndoFakeAdapter(text: "Hello world", selection: NSRange(location: 6, length: 5))
        let service = makeService(adapter)
        _ = await service.deliver("Welt", to: try readyTarget(service), deliveryID: UUID())
        adapter.type(" and more")
        let receipt = await service.undoLastInsertion()
        #expect(receipt.outcome == .undone)
        #expect(adapter.text == "Hello world and more")
    }

    @Test("Text typed before the dictation shifts it, so nothing is changed")
    func undoRefusesWhenTextShifted() async throws {
        let adapter = UndoFakeAdapter(text: "Hello world", selection: NSRange(location: 6, length: 5))
        let service = makeService(adapter)
        _ = await service.deliver("Welt", to: try readyTarget(service), deliveryID: UUID())
        adapter.text = "Oh! " + adapter.text
        adapter.selection = NSRange(location: adapter.text.utf16.count, length: 0)
        let receipt = await service.undoLastInsertion()
        #expect(receipt.outcome == .refused)
        #expect(receipt.message.contains("Nothing was changed"))
        #expect(adapter.text == "Oh! Hello Welt")
        #expect(adapter.rangeReplacements.isEmpty)
        #expect(service.canUndoLastInsertion, "A refusal keeps the record, so returning to the field can still undo.")
    }

    @Test("A different field or app, lost access and a newly excluded app all refuse without writing",
          arguments: UndoRefusal.allCases)
    func undoRefusesWhenDestinationChanged(_ refusal: UndoRefusal) async throws {
        let adapter = UndoFakeAdapter(text: "Hello world", selection: NSRange(location: 6, length: 5))
        let service = makeService(adapter)
        let original = adapter.field
        _ = await service.deliver("Welt", to: try readyTarget(service), deliveryID: UUID())
        var exclusions = DictationUserExclusions.empty
        switch refusal {
        case .otherField: adapter.field = UndoFakeField()
        case .otherApp: adapter.app.bundleIdentifier = "com.apple.Notes"
        case .noAccess: adapter.isTrusted = false
        case .excludedApp: exclusions.applications = ["com.apple.TextEdit"]
        case .readOnly: adapter.fieldMetadata.selectedTextIsSettable = false
        }
        let receipt = await service.undoLastInsertion(exclusions: exclusions)
        #expect(receipt.outcome == .refused)
        #expect(adapter.text == "Hello Welt")
        #expect(adapter.rangeReplacements.isEmpty)
        // Back in the original place, the same record still works.
        adapter.field = original
        adapter.app.bundleIdentifier = "com.apple.TextEdit"
        adapter.isTrusted = true
        adapter.fieldMetadata.selectedTextIsSettable = true
        #expect(await service.undoLastInsertion().outcome == .undone)
        #expect(adapter.text == "Hello world")
    }

    @Test("A refused range write keeps the record and changes nothing")
    func undoRejectedByField() async throws {
        let adapter = UndoFakeAdapter(text: "Hello world", selection: NSRange(location: 6, length: 5))
        let service = makeService(adapter)
        _ = await service.deliver("Welt", to: try readyTarget(service), deliveryID: UUID())
        adapter.rejectsRangeReplacement = true
        let receipt = await service.undoLastInsertion()
        #expect(receipt.outcome == .refused)
        #expect(adapter.text == "Hello Welt")
        #expect(service.canUndoLastInsertion)
    }

    @Test("An undo is single-use and nothing is on offer before any insertion")
    func undoIsSingleUse() async throws {
        let adapter = UndoFakeAdapter(text: "Hello world", selection: NSRange(location: 6, length: 5))
        let service = makeService(adapter)
        #expect(await service.undoLastInsertion().outcome == .nothingToUndo)
        #expect(!service.canUndoLastInsertion)
        _ = await service.deliver("Welt", to: try readyTarget(service), deliveryID: UUID())
        #expect(await service.undoLastInsertion().outcome == .undone)
        #expect(await service.undoLastInsertion().outcome == .nothingToUndo)
        #expect(adapter.rangeReplacements.count == 1)
    }

    @Test("Only the newest insertion can be undone")
    func newDeliverySupersedesOlderRecord() async throws {
        let adapter = UndoFakeAdapter(text: "One", selection: NSRange(location: 3, length: 0))
        let service = makeService(adapter)
        _ = await service.deliver(" two", to: try readyTarget(service), deliveryID: UUID())
        let afterFirst = adapter.text
        _ = await service.deliver(" three", to: try readyTarget(service), deliveryID: UUID())
        #expect(adapter.text == "One two three")
        #expect(await service.undoLastInsertion().outcome == .undone)
        #expect(adapter.text == afterFirst)
        #expect(await service.undoLastInsertion().outcome == .nothingToUndo)
    }

    @Test("The offer lapses after its maximum age")
    func undoExpires() async throws {
        let adapter = UndoFakeAdapter(text: "Hello world", selection: NSRange(location: 6, length: 5))
        let service = makeService(adapter)
        let clock = UndoClock()
        service.undoClock = { clock.now }
        _ = await service.deliver("Welt", to: try readyTarget(service), deliveryID: UUID())
        #expect(service.canUndoLastInsertion)
        clock.now = clock.now.addingTimeInterval(DictationDeliveryService.undoMaximumAge + 1)
        #expect(!service.canUndoLastInsertion)
        #expect(!service.undoState.isAvailable)
        #expect(await service.undoLastInsertion().outcome == .nothingToUndo)
        #expect(adapter.text == "Hello Welt")
    }

    // MARK: Undo, paste fallback (the app's own Command-Z)

    @Test("A paste is undone with one Command-Z while the caret is where the paste left it")
    func undoPasteFallbackWithShortcut() async throws {
        let adapter = UndoFakeAdapter(text: "Dear Anna, ", selection: NSRange(location: 11, length: 0), app: .notes)
        let service = makeService(adapter)
        let delivered = await service.deliver("see you soon", to: try readyFallbackTarget(service), deliveryID: UUID())
        #expect(delivered.outcome == .pasted)
        #expect(adapter.text == "Dear Anna, see you soon")
        #expect(service.canUndoLastInsertion)
        let receipt = await service.undoLastInsertion()
        #expect(receipt.outcome == .undone)
        #expect(adapter.undoShortcuts == 1)
        #expect(adapter.text == "Dear Anna, ")
        #expect(adapter.rangeReplacements.isEmpty, "The fallback never rewrites a range or reads field text.")
        #expect(adapter.snapshotReads == 0)
        #expect(await service.undoLastInsertion().outcome == .nothingToUndo)
        #expect(adapter.undoShortcuts == 1, "A second Command-Z would undo something else.")
    }

    @Test("A moved caret means the user kept typing, so Command-Z is not sent")
    func fallbackUndoRefusesAfterTyping() async throws {
        let adapter = UndoFakeAdapter(text: "Dear Anna, ", selection: NSRange(location: 11, length: 0), app: .notes)
        let service = makeService(adapter)
        _ = await service.deliver("see you soon", to: try readyFallbackTarget(service), deliveryID: UUID())
        adapter.type(" tomorrow")
        let receipt = await service.undoLastInsertion()
        #expect(receipt.outcome == .refused)
        #expect(adapter.undoShortcuts == 0)
        #expect(adapter.text == "Dear Anna, see you soon tomorrow")
        #expect(service.canUndoLastInsertion)
    }

    @Test("Without a readable caret after the paste, Undo cannot verify and does nothing")
    func fallbackUndoNeedsCaret() async throws {
        let adapter = UndoFakeAdapter(text: "Dear Anna, ", selection: NSRange(location: 11, length: 0), app: .notes)
        // A plain text field may be captured without a readable selection; then the paste leaves no known caret.
        adapter.selectionIsReadable = false
        let service = makeService(adapter)
        let delivered = await service.deliver("see you soon", to: try readyFallbackTarget(service), deliveryID: UUID())
        #expect(delivered.outcome == .pasted)
        let receipt = await service.undoLastInsertion()
        #expect(receipt.outcome == .refused)
        #expect(receipt.message.contains("could not confirm"))
        #expect(adapter.undoShortcuts == 0)
        #expect(adapter.text == "Dear Anna, see you soon")
    }

    @Test("A caret that becomes unreadable after the paste also refuses")
    func fallbackUndoRefusesWhenCaretUnreadable() async throws {
        let adapter = UndoFakeAdapter(text: "Dear Anna, ", selection: NSRange(location: 11, length: 0), app: .notes)
        let service = makeService(adapter)
        _ = await service.deliver("see you soon", to: try readyFallbackTarget(service), deliveryID: UUID())
        adapter.selectionIsReadable = false
        #expect(await service.undoLastInsertion().outcome == .refused)
        #expect(adapter.undoShortcuts == 0)
    }

    @Test("A Command-Z with no visible effect is reported as unconfirmed and spent")
    func fallbackUndoUnconfirmed() async throws {
        let adapter = UndoFakeAdapter(text: "Dear Anna, ", selection: NSRange(location: 11, length: 0), app: .notes)
        let service = makeService(adapter)
        _ = await service.deliver("see you soon", to: try readyFallbackTarget(service), deliveryID: UUID())
        adapter.undoShortcutHasEffect = false
        let receipt = await service.undoLastInsertion()
        #expect(receipt.outcome == .uncertain)
        #expect(adapter.undoShortcuts == 1)
        #expect(!service.canUndoLastInsertion)
    }

    @Test("Undo never posts an event without event access")
    func fallbackUndoNeedsEventAccess() async throws {
        let adapter = UndoFakeAdapter(text: "Dear Anna, ", selection: NSRange(location: 11, length: 0), app: .notes)
        let service = makeService(adapter)
        _ = await service.deliver("see you soon", to: try readyFallbackTarget(service), deliveryID: UUID())
        adapter.canPostPasteEvents = false
        #expect(await service.undoLastInsertion().outcome == .refused)
        #expect(adapter.undoShortcuts == 0)
    }

    // MARK: Web and rich-text editors

    @Test("A web area, group or role-less element is a paste target only with explicit editable evidence")
    func webEditorEvidence() {
        func metadata(_ role: String) -> DictationFieldMetadata {
            DictationFieldMetadata(processIdentifier: 1, role: role, subrole: nil, isEnabled: true, isProtected: false,
                                   selectedTextIsSettable: false, valueIsSettable: false)
        }
        // A plain web page: its selection range is settable, but nothing says it is editable.
        var page = metadata("AXWebArea")
        page.selectionRangeIsSettable = true
        #expect(!page.acceptsPasteFallback)
        // Mail's compose body and contenteditable regions.
        var compose = page
        compose.isMarkedEditable = true
        #expect(compose.acceptsPasteFallback)
        #expect(compose.usesWebEditorPath)
        var settableValue = page
        settableValue.valueIsSettable = true
        #expect(settableValue.acceptsPasteFallback)
        // Without a settable caret, even a marked element is refused.
        var noCaret = compose
        noCaret.selectionRangeIsSettable = false
        #expect(!noCaret.acceptsPasteFallback)
        // A group needs a web area around it, or the marker.
        var group = metadata("AXGroup")
        group.selectionRangeIsSettable = true
        group.valueIsSettable = true
        #expect(!group.acceptsPasteFallback)
        group.hasWebAreaAncestor = true
        #expect(group.acceptsPasteFallback)
        // Static text must be marked editable itself.
        var text = metadata("AXStaticText")
        text.selectionRangeIsSettable = true
        text.valueIsSettable = true
        text.hasWebAreaAncestor = true
        #expect(!text.acceptsPasteFallback)
        text.isMarkedEditable = true
        #expect(text.acceptsPasteFallback)
        // An element that reports no role.
        var unknown = metadata("AXUnknown")
        unknown.selectionRangeIsSettable = true
        unknown.isMarkedEditable = true
        #expect(unknown.acceptsPasteFallback)
        // Buttons and other roles never qualify, whatever else they report.
        var button = metadata("AXButton")
        button.selectionRangeIsSettable = true
        button.isMarkedEditable = true
        button.hasWebAreaAncestor = true
        button.valueIsSettable = true
        #expect(!button.acceptsPasteFallback)
        // Text-entry roles behave as before and do not use the web-editor path.
        let field = metadata("AXTextArea")
        #expect(!field.acceptsPasteFallback)
        var editable = field
        editable.valueIsSettable = true
        #expect(editable.acceptsPasteFallback)
        #expect(!editable.usesWebEditorPath)
    }

    @Test("Secure, terminal, disabled and unknown-subrole web editors stay refused")
    func webEditorSafetyMarkersStillWin() {
        var editor = DictationFieldMetadata(processIdentifier: 1, role: "AXWebArea", subrole: nil, isEnabled: true,
            isProtected: false, selectedTextIsSettable: true, valueIsSettable: true)
        editor.selectionRangeIsSettable = true
        editor.isMarkedEditable = true
        #expect(editor.acceptsPasteFallback)
        var secureLabel = editor
        secureLabel.hasSecureLabel = true
        #expect(!secureLabel.acceptsPasteFallback)
        var protected = editor
        protected.isProtected = true
        #expect(!protected.acceptsPasteFallback)
        var secureInput = editor
        secureInput.secureEventInput = true
        #expect(!secureInput.acceptsPasteFallback)
        var terminal = editor
        terminal.isTerminalInput = true
        #expect(!terminal.acceptsPasteFallback)
        var disabled = editor
        disabled.isEnabled = false
        #expect(!disabled.acceptsPasteFallback)
        var subrole = editor
        subrole.subrole = "AXDescriptionList"
        #expect(!subrole.acceptsPasteFallback)
    }

    @Test("Mail's compose body is captured as a paste destination with a readable caret")
    func mailComposeBodyIsCaptured() throws {
        let adapter = UndoFakeAdapter(text: "", selection: NSRange(location: 0, length: 0), app: .mail)
        adapter.fieldMetadata = DictationFieldMetadata(processIdentifier: 77, role: "AXWebArea", subrole: nil,
            isEnabled: true, isProtected: false, selectedTextIsSettable: false, valueIsSettable: false,
            selectionRangeIsSettable: true, isMarkedEditable: true, hasWebAreaAncestor: true)
        let target = try readyFallbackTarget(makeService(adapter))
        #expect(target.strategy == .pasteFallback)
        #expect(target.descriptor.bundleIdentifier == "com.apple.mail")
        #expect(adapter.snapshotReads == 0, "A web editor is never read for text.")
    }

    @Test("A web editor without a readable caret stays Copy-only")
    func webEditorNeedsCaret() {
        let adapter = UndoFakeAdapter(text: "", selection: NSRange(location: 0, length: 0), app: .mail)
        adapter.fieldMetadata = DictationFieldMetadata(processIdentifier: 77, role: "AXWebArea", subrole: nil,
            isEnabled: true, isProtected: false, selectedTextIsSettable: false, valueIsSettable: false,
            selectionRangeIsSettable: true, isMarkedEditable: true, hasWebAreaAncestor: true)
        adapter.selectionIsReadable = false
        guard case .unavailable(let failure) = makeService(adapter).captureTarget(pasteIntoOtherApps: true) else {
            Issue.record("A web editor with no readable caret must not become a destination.")
            return
        }
        #expect(failure == .unsupportedField)
    }

    @Test("A secure field, terminal input or terminal app is refused even when it looks like an editor")
    func webEditorNeverOverridesSafetyRules() {
        let editor = DictationFieldMetadata(processIdentifier: 77, role: "AXWebArea", subrole: nil, isEnabled: true,
            isProtected: false, selectedTextIsSettable: false, valueIsSettable: false,
            selectionRangeIsSettable: true, isMarkedEditable: true, hasWebAreaAncestor: true)
        func failure(_ adapter: UndoFakeAdapter) -> DictationCaptureFailure? {
            guard case .unavailable(let failure) = makeService(adapter).captureTarget(pasteIntoOtherApps: true) else { return nil }
            return failure
        }
        let secure = UndoFakeAdapter(text: "", selection: NSRange(location: 0, length: 0), app: .mail)
        secure.fieldMetadata = editor
        secure.fieldMetadata.hasSecureLabel = true
        #expect(failure(secure) == .secureField)
        let terminalInput = UndoFakeAdapter(text: "", selection: NSRange(location: 0, length: 0), app: .mail)
        terminalInput.fieldMetadata = editor
        terminalInput.fieldMetadata.isTerminalInput = true
        #expect(failure(terminalInput) == .copyOnlyApplication)
        let terminal = UndoFakeAdapter(text: "", selection: NSRange(location: 0, length: 0), app: .mail)
        terminal.fieldMetadata = editor
        terminal.app.bundleIdentifier = "com.apple.Terminal"
        #expect(failure(terminal) == .copyOnlyApplication)
        #expect(terminal.focusReads == 0)
        let blocked = UndoFakeAdapter(text: "", selection: NSRange(location: 0, length: 0), app: .mail)
        blocked.fieldMetadata = editor
        blocked.app.bundleIdentifier = "com.1password.1password"
        #expect(failure(blocked) == .excludedApplication)
        #expect(blocked.focusReads == 0)
    }

    @Test("A web editor paste lands only while the caret is unchanged, then can be undone")
    func webEditorPasteAndUndo() async throws {
        let adapter = UndoFakeAdapter(text: "Hi ", selection: NSRange(location: 3, length: 0), app: .mail)
        adapter.fieldMetadata = DictationFieldMetadata(processIdentifier: 77, role: "AXWebArea", subrole: nil,
            isEnabled: true, isProtected: false, selectedTextIsSettable: false, valueIsSettable: false,
            selectionRangeIsSettable: true, isMarkedEditable: true, hasWebAreaAncestor: true)
        let service = makeService(adapter)
        let moved = try readyFallbackTarget(service)
        adapter.selection = NSRange(location: 0, length: 0)
        let refused = await service.deliver("Anna", to: moved, deliveryID: UUID())
        #expect(refused.outcome == .targetChanged)
        #expect(adapter.text == "Hi ")
        adapter.selection = NSRange(location: 3, length: 0)
        let delivered = await service.deliver("Anna", to: try readyFallbackTarget(service), deliveryID: UUID())
        #expect(delivered.outcome == .pasted)
        #expect(adapter.text == "Hi Anna")
        #expect(await service.undoLastInsertion().outcome == .undone)
        #expect(adapter.text == "Hi ")
    }

    // MARK: Helpers

    private func makeService(_ adapter: UndoFakeAdapter) -> DictationDeliveryService {
        DictationDeliveryService(adapter: adapter, ownBundleIdentifier: "test.keystorm", ownProcessIdentifier: 900,
            pasteTiming: DictationPasteTiming(evidenceTimeout: .milliseconds(60), settleDelay: .milliseconds(2),
                                              pollInterval: .milliseconds(5)))
    }

    private func readyTarget(_ service: DictationDeliveryService) throws -> DictationCapturedTarget {
        guard case .ready(let target) = service.captureTarget() else { throw UndoTestError.captureFailed }
        return target
    }

    private func readyFallbackTarget(_ service: DictationDeliveryService) throws -> DictationCapturedTarget {
        guard case .ready(let target) = service.captureTarget(pasteIntoOtherApps: true) else { throw UndoTestError.captureFailed }
        return target
    }
}

enum UndoRefusal: Sendable, CaseIterable { case otherField, otherApp, noAccess, excludedApp, readOnly }
private enum UndoTestError: Error { case captureFailed }

@MainActor private final class UndoFakeField: DictationDeliveryField {}

@MainActor private final class UndoClock {
    var now = Date()
}

@MainActor
private final class UndoFakeAdapter: DictationDeliveryAdapter {
    enum Host {
        case textEdit, notes, mail
        var application: DictationDeliveryApplication {
            switch self {
            case .textEdit: DictationDeliveryApplication(processIdentifier: 77, bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
            case .notes: DictationDeliveryApplication(processIdentifier: 77, bundleIdentifier: "com.apple.Notes", name: "Notes")
            case .mail: DictationDeliveryApplication(processIdentifier: 77, bundleIdentifier: "com.apple.mail", name: "Mail")
            }
        }
    }

    var isTrusted = true
    var canPostPasteEvents = true
    var app: DictationDeliveryApplication
    var field = UndoFakeField()
    var text: String
    var selection: NSRange
    var fieldMetadata: DictationFieldMetadata
    var selectionIsReadable = true
    var rejectsRangeReplacement = false
    var undoShortcutHasEffect = true
    var rangeReplacements: [(range: NSRange, text: String)] = []
    var undoShortcuts = 0
    var snapshotReads = 0
    var focusReads = 0
    /// What the app's own undo stack holds: the text and selection before each paste.
    private var undoStack: [(text: String, selection: NSRange)] = []

    init(text: String, selection: NSRange, app host: Host = .textEdit) {
        self.text = text
        self.selection = selection
        app = host.application
        fieldMetadata = DictationFieldMetadata(processIdentifier: 77, role: "AXTextArea", subrole: nil,
            isEnabled: true, isProtected: false, selectedTextIsSettable: host == .textEdit,
            valueIsSettable: host != .textEdit)
    }

    /// The user typing at the end of the field.
    func type(_ typed: String) {
        text += typed
        selection = NSRange(location: text.utf16.count, length: 0)
    }

    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { app }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField {
        focusReads += 1
        return field
    }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { lhs === rhs }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata { fieldMetadata }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        snapshotReads += 1
        return DictationFieldSnapshot(text: text, selection: selection)
    }
    func replaceSelectedText(_ replacement: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        text = (text as NSString).replacingCharacters(in: selection, with: replacement)
        selection = NSRange(location: selection.location + replacement.utf16.count, length: 0)
        return .accepted
    }
    func selectedTextRange(of field: any DictationDeliveryField) -> NSRange? { selectionIsReadable ? selection : nil }

    func replaceRange(_ range: NSRange, with replacement: String, finalSelection: NSRange,
                      in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        guard !rejectsRangeReplacement else { return .rejected }
        rangeReplacements.append((range, replacement))
        text = (text as NSString).replacingCharacters(in: range, with: replacement)
        selection = finalSelection
        return .accepted
    }

    func prepareFallbackPaste(_ pasted: String, processIdentifier: Int32) throws -> any DictationPasteOperation {
        UndoFakePasteOperation { [self] in
            undoStack.append((text, selection))
            text = (text as NSString).replacingCharacters(in: selection, with: pasted)
            selection = NSRange(location: selection.location + pasted.utf16.count, length: 0)
        }
    }

    func postUndoShortcut(processIdentifier: Int32) -> Bool {
        undoShortcuts += 1
        if undoShortcutHasEffect, let previous = undoStack.popLast() {
            text = previous.text
            selection = previous.selection
        }
        return true
    }
}

@MainActor
private final class UndoFakePasteOperation: DictationPasteOperation {
    private let action: () -> Void
    private var performed = false
    private(set) var stagedTextWasRead = false

    init(action: @escaping () -> Void) { self.action = action }

    func perform() -> Bool {
        guard !performed else { return false }
        performed = true
        action()
        stagedTextWasRead = true
        return true
    }

    func restoreIfOwned() {}
    func leaveStagedTextOnPasteboard() -> Bool { true }
}
