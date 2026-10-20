import AppKit
import Foundation
import Testing
@testable import Keystorm

@MainActor
struct NativeBriefEditorTests {
    @Test func modelEchoPreservesNativeSelectionAndTypingUndo() throws {
        let fixture = try NativeEditorFixture(text: "Keep /src/café.swift and 256.")
        defer { fixture.close() }
        let undo = try #require(fixture.view.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        fixture.view.setSelectedRange(NSRange(location: 0, length: 0))
        fixture.view.insertText("Never discard. ", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        let typed = fixture.view.string
        #expect(fixture.changes.last?.utf8.elementsEqual(typed.utf8) == true)
        #expect(undo.canUndo)
        let selected = NSRange(location: 6, length: 7)
        fixture.view.setSelectedRange(selected)
        fixture.echo(text: typed)
        #expect(fixture.view.selectedRange() == selected)
        #expect(undo.canUndo)
        undo.undo()
        #expect(fixture.view.string.utf8.elementsEqual(fixture.originalText.utf8))
    }

    @Test func externalCanonicalUnicodeChangeReachesTextStorageByteExactly() throws {
        let composed = "Keep café.swift and 👩🏽‍💻 at 256."
        let decomposed = "Keep cafe\u{301}.swift and 👩🏽‍💻 at 256."
        #expect(composed == decomposed)
        #expect(!composed.utf8.elementsEqual(decomposed.utf8))
        let fixture = try NativeEditorFixture(text: composed)
        defer { fixture.close() }
        fixture.view.setSelectedRange(NSRange(location: (composed as NSString).length, length: 0))
        fixture.echo(text: decomposed)
        #expect(fixture.view.string.utf8.elementsEqual(decomposed.utf8))
        #expect(fixture.changes.isEmpty)
        #expect(fixture.view.selectedRange().location <= (decomposed as NSString).length)
        fixture.echo(text: "Short")
        #expect(fixture.view.selectedRange() == NSRange(location: 5, length: 0))
    }

    @Test func externalShorteningSafelyClearsAnOldReadbackHighlight() throws {
        let fixture = try NativeEditorFixture(text: String(repeating: "Source material. ", count: 20))
        defer { fixture.close() }
        fixture.echo(text: fixture.originalText, highlight: NSRange(location: 180, length: 8))
        #expect(fixture.coordinator.highlight == NSRange(location: 180, length: 8))
        fixture.echo(text: "Short", highlight: nil)
        #expect(fixture.view.string == "Short")
        #expect(fixture.coordinator.highlight == nil)
        #expect(fixture.changes.isEmpty)
    }

    @Test func externalInsertionPreservesTheSelectedPassageAndViewport() throws {
        let text = (0..<80).map { "Paragraph \($0): Keep 👩🏽‍💻 and /tmp/cache.swift unchanged." }.joined(separator: "\n")
        let fixture = try NativeEditorFixture(text: text)
        defer { fixture.close() }
        _ = try fixture.measure()
        fixture.view.setFrameSize(NSSize(width: 600, height: 2_000))
        fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        let origin = fixture.scroll.contentView.bounds.origin
        let selected = (text as NSString).range(of: "/tmp/cache.swift")
        fixture.view.setSelectedRange(selected)
        let inserted = "New introduction.\n"
        fixture.echo(text: inserted + text)
        #expect(fixture.view.selectedRange() == NSRange(location: selected.location + (inserted as NSString).length,
                                                       length: selected.length))
        #expect(fixture.scroll.contentView.bounds.origin == origin)
        #expect(fixture.view.string.utf8.elementsEqual((inserted + text).utf8))
        #expect(fixture.changes.isEmpty)
    }

    @Test func externalEmojiReplacementPreservesUnicodeAndSuffixSelection() throws {
        let original = "Keep 🧑‍💻 and /tmp/café.swift."
        let replacement = "Keep 🧑‍🔬 and /tmp/cafe\u{301}.swift."
        let fixture = try NativeEditorFixture(text: original)
        defer { fixture.close() }
        fixture.view.setSelectedRange((original as NSString).range(of: "swift"))
        fixture.echo(text: replacement)
        #expect(fixture.view.string.utf8.elementsEqual(replacement.utf8))
        #expect(fixture.view.selectedRange() == (replacement as NSString).range(of: "swift"))
        #expect(fixture.changes.isEmpty)
    }

    @Test func readbackTicksReuseParagraphMeasurementUntilTextOrWidthChanges() throws {
        let fixture = try NativeEditorFixture(text: String(repeating: "Keep the document responsive.\n", count: 500))
        defer { fixture.close() }
        let originalSize = try fixture.measure()
        #expect(originalSize.height == 420)
        let initialCount = fixture.coordinator.layoutMeasurementCount
        for location in 0..<20 {
            fixture.echo(text: fixture.originalText, highlight: NSRange(location: location, length: 1))
            #expect(try fixture.measure() == originalSize)
        }
        #expect(fixture.coordinator.layoutMeasurementCount == initialCount)
        fixture.view.insertText("Another constraint.\n",
            replacementRange: NSRange(location: (fixture.view.string as NSString).length, length: 0))
        _ = try fixture.measure()
        #expect(fixture.coordinator.layoutMeasurementCount == initialCount + 1)
        #expect(try fixture.measure(width: 300).width == 300)
        #expect(fixture.coordinator.layoutMeasurementCount == initialCount + 2)
    }

    @Test func protectedExactReferenceRejectsNativeTypingButRemainsSelectable() throws {
        let literal = "  /tmp/e\u{301}/Q8_0.swift\n\tNever change 256.\n"
        let fixture = try NativeEditorFixture(text: literal, editable: false)
        defer { fixture.close() }
        #expect(!fixture.view.isEditable)
        #expect(fixture.view.isSelectable)
        fixture.view.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(fixture.view.selectedRange() == NSRange(location: 0, length: 4))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        fixture.view.keyDown(with: event)
        #expect(fixture.view.string.utf8.elementsEqual(literal.utf8))
        #expect(fixture.changes.isEmpty)
    }

    @Test func markedTextSurvivesAnOldModelEchoAndCommitsToTheModel() throws {
        let fixture = try NativeEditorFixture(text: "Goal: ")
        defer { fixture.close() }
        fixture.view.setSelectedRange(NSRange(location: 6, length: 0))
        fixture.view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(fixture.view.hasMarkedText())
        #expect(fixture.changes.isEmpty)
        let composition = fixture.view.string
        let selection = fixture.view.selectedRange()
        fixture.echo(text: fixture.originalText)
        #expect(fixture.view.string.utf8.elementsEqual(composition.utf8))
        #expect(fixture.view.selectedRange() == selection)
        fixture.view.insertText("日本語", replacementRange: fixture.view.markedRange())
        #expect(!fixture.view.hasMarkedText())
        #expect(fixture.view.string == "Goal: 日本語")
        #expect(fixture.changes.last == "Goal: 日本語")
    }

    @Test func cancelledMarkedInsertionCannotClearTheExistingPassage() throws {
        let fixture = try NativeEditorFixture(text: "Keep the original constraint.")
        defer { fixture.close() }
        fixture.view.setSelectedRange(NSRange(location: (fixture.originalText as NSString).length, length: 0))
        fixture.view.setMarkedText("取り消し", selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: fixture.view.markedRange())
        fixture.view.unmarkText()
        fixture.window.makeFirstResponder(nil)
        #expect(fixture.view.string.utf8.elementsEqual(fixture.originalText.utf8))
        #expect(fixture.changes.isEmpty)
    }

    @Test func unmarkOnlyCompositionCommitReachesModelOnFocusChange() throws {
        let fixture = try NativeEditorFixture(text: "Goal: ")
        defer { fixture.close() }
        fixture.view.setSelectedRange(NSRange(location: 6, length: 0))
        fixture.view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(fixture.view.hasMarkedText())
        fixture.view.unmarkText()
        fixture.window.makeFirstResponder(nil)
        #expect(!fixture.view.hasMarkedText())
        #expect(fixture.view.string == "Goal: かな")
        #expect(fixture.changes.last == "Goal: かな")
    }
}

/// Uses production construction/update methods and real AppKit input/undo. No microphone or model dependency.
@MainActor
private final class NativeEditorFixture {
    let originalText: String
    let blockID = UUID()
    let window: NSWindow
    let scroll: NSScrollView
    let view: NSTextView
    let coordinator: NativeBriefEditor.Coordinator
    private(set) var changes: [String] = []

    init(text: String, editable: Bool = true) throws {
        originalText = text
        let editor = NativeBriefEditor(blockID: blockID, text: text, editable: editable, highlight: nil,
            onChange: { _ in }, onFocus: {})
        coordinator = editor.makeCoordinator()
        scroll = editor.makeEditor(coordinator: coordinator)
        view = try #require(scroll.documentView as? NSTextView)
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 640, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeFirstResponder(view)
        scroll.layoutSubtreeIfNeeded()
        coordinator.parent = NativeBriefEditor(blockID: blockID, text: text, editable: editable, highlight: nil,
            onChange: { [weak self] in self?.changes.append($0) }, onFocus: {})
    }

    func echo(text: String, highlight: NSRange? = nil) {
        let update = NativeBriefEditor(blockID: blockID, text: text, editable: view.isEditable, highlight: highlight,
            onChange: { [weak self] in self?.changes.append($0) }, onFocus: {})
        update.updateEditor(scroll, coordinator: coordinator)
    }

    func measure(width: CGFloat = 600) throws -> CGSize {
        let container = try #require(view.textContainer)
        let layout = try #require(view.layoutManager)
        return coordinator.parent.measureEditor(width: width, view: view, container: container,
                                                layout: layout, coordinator: coordinator)
    }

    func close() {
        window.makeFirstResponder(nil)
        view.delegate = nil
        window.close()
    }
}

