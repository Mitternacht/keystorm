import SwiftUI
import AppKit
import ServiceManagement

struct ShortcutSettingsView: View {
    @Bindable var manager: ShortcutManager
    @State private var capturingAction: ShortcutAction?

    var body: some View {
        Form {
            Section {
                Picker("Dictation shortcut behavior", selection: Binding(
                    get: { manager.dictationShortcutMode },
                    set: { manager.setDictationShortcutMode($0) }
                )) {
                    ForEach(DictationShortcutMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .accessibilityIdentifier("dictationShortcutMode")
            } header: { Text("Dictation shortcut") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(manager.dictationShortcutMode.detail)
                    Text("Press Esc while dictating to cancel and keep the saved audio.")
                }
            }
            Section {
                Picker("Developer brief recording shortcut", selection: Binding(
                    get: { manager.recordingBehavior },
                    set: { manager.setRecordingBehavior($0) }
                )) {
                    ForEach(RecordingBehavior.allCases) { value in Text(value.title).tag(value) }
                }
                ForEach(ShortcutAction.allCases) { action in
                    ShortcutSettingsRow(manager: manager, action: action, capturingAction: $capturingAction)
                }
            } header: { Text("Global shortcuts") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shortcuts work while Keystorm is running, including when its window is closed. Key combinations register with macOS and need no permission. A single modifier key such as Fn or right ⌘ is watched through Accessibility, which Keystorm already asks for to insert text.")
                    Text("Hold mode applies to developer brief recording. How the dictation shortcut reacts is set above; pause/resume has a separate shortcut.")
                }
            }
            Section {
                if case .unavailable(let message) = manager.modifierMonitorStatus {
                    StatusMessage(.warning, Text(message))
                    Button("Open Accessibility settings") { Self.openAccessibilitySettings() }
                }
                HStack {
                    Button("Retry registration") { manager.retryRegistration() }
                    Spacer()
                    Text("Last dispatch: \(Double(manager.lastDispatchNanoseconds) / 1_000_000, specifier: "%.2f") ms")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let error = manager.lastError { StatusMessage(.error, Text(error)) }
            } header: { Text("Registration") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use Command, Option, or Control. Assignments follow physical keys; review them after changing keyboard layouts. Some system shortcuts are unavailable. Escape cancels shortcut recording.")
                    Text("For the dictation shortcut you can also tap one modifier key while recording: Fn, right Option, right Command, or a Control key. Chords like ⌘C never trigger it. On a Mac with a Globe key, set “Press 🌐 to” to “Do Nothing” in System Settings → Keyboard so macOS does not act on it too.")
                }
            }
            LaunchAtLoginControl()
        }
        .formStyle(.grouped)
        .onChange(of: capturingAction) { _, action in manager.suspendForShortcutCapture(action != nil) }
        .onDisappear { capturingAction = nil; manager.suspendForShortcutCapture(false) }
        .accessibilityIdentifier("shortcutSettings")
    }

    /// Opens the pane only; the grant itself is always the person's to give.
    private static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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
            if requiresApproval {
                StatusMessage(.warning, Text("Allow Keystorm in System Settings → General → Login Items."))
                Button("Open Login Items settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error { StatusMessage(.error, Text(error)) }
            Button("Refresh login status") { refresh() }.disabled(busy)
        } header: { Text("Startup") } footer: {
            Text("Optional. Keeps your shortcuts available after signing in. Recording still starts only when you request it.")
        }
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
                    ShortcutRecorderChrome {
                        ShortcutCaptureControl(onKey: { event in
                            assign { try GlobalShortcut(event: event) }
                        }, onModifierKey: modifierCapture, onCancel: { capturingAction = nil })
                    }
                } else {
                    // The idle keycap is a standard bordered button; only the recorder takes the glass treatment.
                    Button(manager.shortcut(for: action)?.displayName ?? "Assign shortcut…") {
                        error = nil; capturingAction = action
                    }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 210)
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
            if let error { StatusMessage(.error, Text(error)).font(.footnote) }
            if let status = manager.registration[action] {
                switch status {
                case .unavailable:
                    StatusMessage(.error, Text(status.label)).font(.footnote)
                case .registered:
                    StatusMessage(.ready, Text(status.label)).font(.footnote)
                case .disabled:
                    Text(status.label).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        // Capture errors appear while keyboard focus stays in the recorder, so speak them.
        .onChange(of: error) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    /// Only the dictation shortcut can be one modifier key, so only its recorder listens for a modifier tap.
    private var modifierCapture: (@MainActor (ModifierKey) -> Void)? {
        guard action == .toggleDictation else { return nil }
        return { key in assign { GlobalShortcut(modifierKey: key) } }
    }

    private func assign(_ makeShortcut: () throws -> GlobalShortcut) {
        do {
            let shortcut = try makeShortcut()
            try manager.setShortcut(shortcut, for: action)
            error = nil; capturingAction = nil
        } catch {
            let message = error.localizedDescription
            // onChange(of: error) skips a repeated message; still speak each rejected key press.
            if message == self.error { AccessibilityNotification.Announcement(message).post() }
            self.error = message
        }
    }

    private func isUnavailable(_ value: ShortcutRegistration) -> Bool {
        if case .unavailable = value { return true }
        return false
    }
}

/// The "listening" state of a shortcut field: accent-tinted glass with a pulsing keyboard symbol, plus a solid
/// accent outline so the state still reads when Reduce Transparency or Increase Contrast make glass opaque.
/// Not interactive glass: the field receives key presses, not pointer taps.
private struct ShortcutRecorderChrome<Content: View>: View {
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "keyboard")
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: !reduceMotion)
                .accessibilityHidden(true)
            content
        }
        .padding(.leading, 10)
        .glassEffect(.regular.tint(Color.accentColor.opacity(0.3)), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        }
    }
}

/// Receives keyboard input only while this explicit, focused recorder is mounted.
private struct ShortcutCaptureControl: NSViewRepresentable {
    let onKey: @MainActor (NSEvent) -> Void
    /// Set when tapping a lone modifier key is a valid shortcut for this recorder.
    let onModifierKey: (@MainActor (ModifierKey) -> Void)?
    let onCancel: @MainActor () -> Void
    func makeNSView(context: Context) -> ShortcutCaptureField {
        let view = ShortcutCaptureField()
        view.onKey = onKey; view.onModifierKey = onModifierKey; view.onCancel = onCancel
        return view
    }
    func updateNSView(_ view: ShortcutCaptureField, context: Context) {
        view.onKey = onKey; view.onModifierKey = onModifierKey; view.onCancel = onCancel
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutCaptureField, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

@MainActor
private final class ShortcutCaptureField: NSView {
    var onKey: ((NSEvent) -> Void)?
    var onModifierKey: ((ModifierKey) -> Void)?
    var onCancel: (() -> Void)?
    private var modifierRecorder = ModifierOnlyRecorder()
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
        // The tinted glass and outline behind this field come from ShortcutRecorderChrome.
        let attributes = promptAttributes
        let textHeight = prompt.size(withAttributes: attributes).height
        prompt.draw(at: NSPoint(x: 8, y: ((bounds.height - textHeight) / 2).rounded()), withAttributes: attributes)
    }
    override func keyDown(with event: NSEvent) { capture(event) }
    /// A modifier pressed and released alone, with no key or click between, becomes a single-modifier shortcut.
    override func flagsChanged(with event: NSEvent) {
        guard onModifierKey != nil else { super.flagsChanged(with: event); return }
        if let key = modifierRecorder.flagsChanged(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue) {
            onModifierKey?(key)
        }
    }
    override func mouseDown(with event: NSEvent) {
        modifierRecorder.otherInput()
        super.mouseDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        capture(event)
        return true
    }
    override func resignFirstResponder() -> Bool {
        onCancel?()
        return super.resignFirstResponder()
    }
    private func capture(_ event: NSEvent) {
        modifierRecorder.otherInput()
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { onCancel?() } else { onKey?(event) }
    }
}

/// Status text kept at label color for contrast; only the symbol carries the status color (green ready,
/// orange needs action, red blocked), and each severity has its own shape so color is not the only cue.
/// System colors adapt under Increase Contrast.
private struct StatusMessage: View {
    enum Severity { case ready, warning, error }
    let severity: Severity
    let text: Text
    init(_ severity: Severity, _ text: Text) { self.severity = severity; self.text = text }

    private var symbol: String {
        switch severity {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch severity {
        case .ready: .green
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        Label {
            text.fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
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
            } header: { Text("Section read-back") } footer: {
                Text("Rate changes apply to the next utterance. Read-back stops before recording and whenever its source section changes.")
            }
            Section {
                Button("Refresh installed voices") { readback.refreshVoices() }
                if let error = readback.error { StatusMessage(.error, Text(error)) }
            } header: { Text("Local voices") } footer: {
                Text("Keystorm uses installed Apple English voices exposed by macOS. It does not request voice downloads or use a cloud speech service.")
            }
        }
        .formStyle(.grouped)
        .task { readback.refreshVoices() }
    }
}
