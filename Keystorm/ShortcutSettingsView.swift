import SwiftUI
import AppKit
import ServiceManagement

struct ShortcutSettingsView: View {
    @Bindable var manager: ShortcutManager
    @State private var capturingAction: ShortcutAction?

    var body: some View {
        Form {
            Section {
                Text("Shortcuts work while Keystorm is running, including when its window is closed. They register specific combinations with macOS; Accessibility and Input Monitoring are not requested.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Developer brief recording shortcut", selection: Binding(
                    get: { manager.recordingBehavior },
                    set: { manager.setRecordingBehavior($0) }
                )) {
                    ForEach(RecordingBehavior.allCases) { value in Text(value.title).tag(value) }
                }
                Text("Hold mode applies to developer brief recording. The dictation shortcut starts or finishes; pause/resume has a separate shortcut.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ShortcutAction.allCases) { action in
                    ShortcutSettingsRow(manager: manager, action: action, capturingAction: $capturingAction)
                }
            } header: { Text("Global shortcuts") }
            Section {
                Text("Use Command, Option, or Control. Assignments follow physical keys; review them after changing keyboard layouts. Some system shortcuts are unavailable. Escape cancels shortcut recording.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Retry registration") { manager.retryRegistration() }
                    Spacer()
                    Text("Last dispatch: \(Double(manager.lastDispatchNanoseconds) / 1_000_000, specifier: "%.2f") ms")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let error = manager.lastError { StatusMessage(.error, Text(error)) }
            } header: { Text("Registration") }
            LaunchAtLoginControl()
        }
        .formStyle(.grouped)
        .onChange(of: capturingAction) { _, action in manager.suspendForShortcutCapture(action != nil) }
        .onDisappear { capturingAction = nil; manager.suspendForShortcutCapture(false) }
        .accessibilityIdentifier("shortcutSettings")
    }
}

private struct LaunchAtLoginControl: View {
    @State private var enabled = false
    @State private var requiresApproval = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("Launch Keystorm at login", isOn: Binding(
                get: { enabled },
                set: { requested in Task { await setEnabled(requested) } }
            ))
            .disabled(busy)
            Text("Optional. Keeps your shortcuts available after signing in. Recording still starts only when you request it.")
                .font(.callout).foregroundStyle(.secondary)
            if requiresApproval {
                StatusMessage(.warning, Text("Allow Keystorm in System Settings → General → Login Items."))
                Button("Open Login Items settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error { StatusMessage(.error, Text(error)) }
            Button("Refresh login status") { refresh() }.disabled(busy)
        } header: { Text("Startup") }
        .task { refresh() }
    }

    private func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }

    private func setEnabled(_ requested: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false; refresh() }
        do {
            if requested { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct ShortcutSettingsRow: View {
    let manager: ShortcutManager
    let action: ShortcutAction
    @Binding var capturingAction: ShortcutAction?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(action.title)
                Spacer()
                if capturingAction == action {
                    ShortcutCaptureControl { event in
                        do {
                            let shortcut = try GlobalShortcut(event: event)
                            try manager.setShortcut(shortcut, for: action)
                            error = nil; capturingAction = nil
                        } catch {
                            let message = error.localizedDescription
                            // onChange(of: error) skips a repeated message; still speak each rejected key press.
                            if message == self.error { AccessibilityNotification.Announcement(message).post() }
                            self.error = message
                        }
                    } onCancel: { capturingAction = nil }
                } else {
                    Button(manager.shortcut(for: action)?.displayName ?? "Assign shortcut…") {
                        error = nil; capturingAction = action
                    }
                    .frame(minWidth: 150)
                    .accessibilityLabel(Text(action.title))
                    .accessibilityValue(manager.shortcut(for: action).map { Text($0.displayName) } ?? Text("Not assigned"))
                    .accessibilityHint("Starts recording a new shortcut.")
                }
                Button("Clear") {
                    do { try manager.setShortcut(nil, for: action); error = nil; capturingAction = nil }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(manager.shortcut(for: action) == nil)
                .accessibilityLabel("Clear \(action.title) shortcut")
            }
            if let error { StatusMessage(.error, Text(error)).font(.caption) }
            if let status = manager.registration[action] {
                if isUnavailable(status) {
                    StatusMessage(.error, Text(status.label)).font(.caption)
                } else {
                    Text(status.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        // Capture errors appear while keyboard focus stays in the recorder, so speak them.
        .onChange(of: error) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    private func isUnavailable(_ value: ShortcutRegistration) -> Bool {
        if case .unavailable = value { return true }
        return false
    }
}

/// Receives keyboard input only while this explicit, focused recorder is mounted.
private struct ShortcutCaptureControl: NSViewRepresentable {
    let onKey: @MainActor (NSEvent) -> Void
    let onCancel: @MainActor () -> Void
    func makeNSView(context: Context) -> ShortcutCaptureField {
        let view = ShortcutCaptureField()
        view.onKey = onKey; view.onCancel = onCancel
        return view
    }
    func updateNSView(_ view: ShortcutCaptureField, context: Context) {
        view.onKey = onKey; view.onCancel = onCancel
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutCaptureField, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

@MainActor
private final class ShortcutCaptureField: NSView {
    var onKey: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?
    private let prompt = String(localized: "Press shortcut…  Esc to cancel") as NSString
    private var promptAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor]
    }
    override var acceptsFirstResponder: Bool { true }
    /// At least 210×30, growing with the preferred body font so the prompt is never clipped.
    override var intrinsicContentSize: NSSize {
        let text = prompt.size(withAttributes: promptAttributes)
        return NSSize(width: max(210, ceil(text.width) + 16), height: max(30, ceil(text.height) + 14))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        setAccessibilityElement(true)
        setAccessibilityLabel(String(localized: "Press a shortcut. Escape cancels."))
        setAccessibilityRole(.textField)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        let attributes = promptAttributes
        let textHeight = prompt.size(withAttributes: attributes).height
        prompt.draw(at: NSPoint(x: 8, y: ((bounds.height - textHeight) / 2).rounded()), withAttributes: attributes)
    }
    override func keyDown(with event: NSEvent) { capture(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        capture(event)
        return true
    }
    override func resignFirstResponder() -> Bool {
        onCancel?()
        return super.resignFirstResponder()
    }
    private func capture(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { onCancel?() } else { onKey?(event) }
    }
}

/// Warning or error text kept at label color for contrast; only the symbol carries the status color,
/// and warnings and errors use different shapes so color is not the only cue.
private struct StatusMessage: View {
    enum Severity { case warning, error }
    let severity: Severity
    let text: Text
    init(_ severity: Severity, _ text: Text) { self.severity = severity; self.text = text }

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(severity == .error ? Color.red : Color.orange)
        }
    }
}

struct ReadbackSettingsView: View {
    @Bindable var readback: BriefReadback
    var body: some View {
        Form {
            Section {
                Picker("Installed English voice", selection: Binding(
                    get: { readback.voiceIdentifier ?? "" },
                    set: { readback.setVoiceIdentifier($0) }
                )) {
                    if readback.voiceIdentifier == nil { Text("Choose a voice").tag("") }
                    ForEach(readback.availableVoices) { voice in
                        Text("\(voice.name) — \(voice.language)").tag(voice.id)
                    }
                }
                if let selected = readback.voiceIdentifier, !readback.availableVoices.contains(where: { $0.id == selected }) {
                    StatusMessage(.warning, Text("The saved voice is unavailable. Choose another installed voice."))
                }
                HStack {
                    Text("Speech rate")
                    Slider(value: $readback.rate, in: 0.3...0.65, step: 0.025)
                    Text(readback.rate, format: .number.precision(.fractionLength(2))).monospacedDigit()
                }
                Text("Rate changes apply to the next utterance. Read-back stops before recording and whenever its source section changes.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Section read-back") }
            Section {
                Text("Keystorm uses installed Apple English voices exposed by macOS. It does not request voice downloads or use a cloud speech service.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Refresh installed voices") { readback.refreshVoices() }
                if let error = readback.error { StatusMessage(.error, Text(error)) }
            } header: { Text("Local voices") }
        }
        .formStyle(.grouped)
        .task { readback.refreshVoices() }
    }
}
