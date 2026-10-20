import AppKit
import Observation
import SwiftUI

/// One block owns one native editor. SwiftUI never replaces the text storage on a timer tick.
struct NativeBriefEditor: NSViewRepresentable {
    let blockID: UUID
    let text: String
    let editable: Bool
    var highlight: NSRange?
    var accessibilityLabel = String(localized: "Brief paragraph")
    private let typography = NativeEditorTypography.shared
    let onChange: (String) -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView { makeEditor(coordinator: context.coordinator) }

    func makeEditor(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = BriefTextView(frame: .zero)
        view.onCommittedText = { [weak coordinator] view in coordinator?.deliverCommittedText(from: view) }
        view.isRichText = false
        view.isEditable = editable
        view.isSelectable = true
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.drawsBackground = false
        view.font = typography.font
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.delegate = coordinator
        view.string = text
        view.setAccessibilityLabel(accessibilityLabel)
        view.setAccessibilityHelp(editable ? String(localized: "Type to edit this passage.") :
            String(localized: "Protected exact reference. Select and copy text, or unlock it from Passage actions before editing."))
        view.setAccessibilityIdentifier("briefBlock-\(blockID.uuidString)")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { updateEditor(scroll, coordinator: context.coordinator) }

    func updateEditor(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.parent = self
        let wasProgrammatic = coordinator.programmaticChange
        coordinator.programmaticChange = true
        defer { coordinator.programmaticChange = wasProgrammatic }
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = editable
        view.setAccessibilityLabel(accessibilityLabel)
        view.setAccessibilityHelp(editable ? String(localized: "Type to edit this passage.") :
            String(localized: "Protected exact reference. Select and copy text, or unlock it from Passage actions before editing."))
        if view.font != typography.font {
            view.font = typography.font
            coordinator.invalidateMeasurement()
        }
        // A read-back highlight never bridges or scans NSTextView's entire backing string.
        // The coordinator already owns the last committed value, including native typing.
        if !view.hasMarkedText(), !Self.sameBytes(coordinator.lastDeliveredText, text) {
            if let previous = coordinator.highlight, NSMaxRange(previous) <= (view.textStorage?.length ?? 0) {
                view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: previous)
            }
            coordinator.highlight = nil
            Self.replaceText(in: view, scroll: scroll, with: text)
            view.undoManager?.removeAllActions()
            coordinator.lastDeliveredText = text
            coordinator.invalidateMeasurement()
        }
        let count = view.textStorage?.length ?? 0
        func valid(_ range: NSRange) -> Bool {
            range.location != NSNotFound && range.location >= 0 && range.length >= 0
                && range.location <= count && range.length <= count - range.location
        }
        if coordinator.highlight != highlight {
            if let previous = coordinator.highlight, valid(previous) {
                view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: previous)
            }
            if let highlight, valid(highlight) {
                view.layoutManager?.addTemporaryAttribute(.backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.28), forCharacterRange: highlight)
                coordinator.highlight = highlight
            } else { coordinator.highlight = nil }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? NSTextView,
              let container = view.textContainer, let layout = view.layoutManager else { return nil }
        return measureEditor(width: proposal.width ?? 600, view: view, container: container,
                             layout: layout, coordinator: context.coordinator)
    }

    func measureEditor(width proposedWidth: CGFloat, view: NSTextView, container: NSTextContainer,
                       layout: NSLayoutManager, coordinator: Coordinator) -> CGSize {
        let width = max(proposedWidth, 120)
        if let measured = coordinator.measuredSize, measured.width == width { return measured }
        container.containerSize = NSSize(width: max(width - 24, 80), height: .greatestFiniteMagnitude)
        // The paragraph viewport is capped. Measuring it need not lay out a 128 KB reference.
        layout.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: container.containerSize.width, height: 398),
                            in: container)
        let height = min(max(layout.usedRect(for: container).height + 22, 58), 420)
        let measured = CGSize(width: width, height: height)
        coordinator.measuredSize = measured
        coordinator.recordMeasurement()
        return measured
    }

    /// Keep byte fidelity while taking the constant-time shared-storage path for model echoes.
    static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        let contiguous: Bool? = lhs.utf8.withContiguousStorageIfAvailable { left in
            rhs.utf8.withContiguousStorageIfAvailable { right in
                guard left.count == right.count else { return false }
                if left.baseAddress == right.baseAddress { return true }
                return left.elementsEqual(right)
            }
        } ?? nil
        return contiguous ?? lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func replaceText(in view: NSTextView, scroll: NSScrollView, with text: String) {
        let old = Array(view.string.utf16)
        let new = Array(text.utf16)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        func isTrailingSurrogate(_ unit: UInt16) -> Bool { (0xDC00...0xDFFF).contains(unit) }
        if prefix > 0, (prefix < old.count && isTrailingSurrogate(old[prefix])) ||
            (prefix < new.count && isTrailingSurrogate(new[prefix])) { prefix -= 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        if suffix > 0, isTrailingSurrogate(old[old.count - suffix]) ||
            isTrailingSurrogate(new[new.count - suffix]) { suffix -= 1 }
        let replaced = NSRange(location: prefix, length: old.count - prefix - suffix)
        let replacementLength = new.count - prefix - suffix
        let inserted = (text as NSString).substring(with: NSRange(location: prefix, length: replacementLength))
        let selections = view.selectedRanges
        let affinity = view.selectionAffinity
        let origin = scroll.contentView.bounds.origin
        view.textStorage?.replaceCharacters(in: replaced, with: inserted)
        func mapped(_ offset: Int) -> Int {
            if replaced.length == 0, offset >= prefix { return offset + replacementLength }
            if offset <= prefix { return offset }
            if offset >= NSMaxRange(replaced) { return offset + replacementLength - replaced.length }
            return prefix + min(offset - prefix, replacementLength)
        }
        let mappedSelections = selections.map { value -> NSValue in
            let selection = value.rangeValue
            var start = min(max(mapped(selection.location), 0), new.count)
            var end = min(max(mapped(NSMaxRange(selection)), start), new.count)
            if start < new.count, isTrailingSurrogate(new[start]) { start -= 1 }
            if end < new.count, isTrailingSurrogate(new[end]) { end += 1 }
            return NSValue(range: NSRange(location: start, length: end - start))
        }
        view.setSelectedRanges(mappedSelections, affinity: affinity, stillSelecting: false)
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeBriefEditor
        var programmaticChange = false
        var highlight: NSRange?
        var lastDeliveredText: String
        var measuredSize: CGSize?
        private(set) var layoutMeasurementCount = 0
        init(parent: NativeBriefEditor) { self.parent = parent; lastDeliveredText = parent.text }
        func invalidateMeasurement() { measuredSize = nil }
        func recordMeasurement() { layoutMeasurementCount += 1 }

        func textDidChange(_ notification: Notification) {
            invalidateMeasurement()
            guard let view = notification.object as? NSTextView else { return }
            deliverCommittedText(from: view)
        }

        func deliverCommittedText(from view: NSTextView) {
            guard !programmaticChange, !view.hasMarkedText(),
                  (view as? BriefTextView)?.isProcessingInput != true,
                  !NativeBriefEditor.sameBytes(lastDeliveredText, view.string) else { return }
            let committed = view.string
            invalidateMeasurement()
            lastDeliveredText = committed
            parent.onChange(committed)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            deliverCommittedText(from: view)
        }

        func textDidBeginEditing(_ notification: Notification) { parent.onFocus() }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !programmaticChange,
                  let view = notification.object as? NSTextView,
                  view.window?.firstResponder === view else { return }
            parent.onFocus()
        }
    }
}

/// AppKit can commit marked text by unmarking without another text mutation notification.
@MainActor
private final class BriefTextView: NSTextView {
    var onCommittedText: ((NSTextView) -> Void)?
    private var inputDepth = 0
    var isProcessingInput: Bool { inputDepth > 0 }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard isEditable else { return }
        inputDepth += 1
        defer { inputDepth -= 1 }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        inputDepth += 1
        super.insertText(insertString, replacementRange: replacementRange)
        inputDepth -= 1
        if !isProcessingInput, !hasMarkedText() { onCommittedText?(self) }
    }

    override func unmarkText() {
        let wasMarked = hasMarkedText()
        super.unmarkText()
        if wasMarked, !isProcessingInput, !hasMarkedText() { onCommittedText?(self) }
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            if hasMarkedText() { unmarkText() }
            if !isProcessingInput { onCommittedText?(self) }
        }
        return accepted
    }
}

/// One observer serves every paragraph, including lazy editors in long documents.
@MainActor
@Observable
private final class NativeEditorTypography: NSObject {
    static let shared = NativeEditorTypography()
    private(set) var font = NSFont.preferredFont(forTextStyle: .body)

    private override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @objc private func displayOptionsChanged(_ notification: Notification) {
        font = NSFont.preferredFont(forTextStyle: .body)
    }
}
