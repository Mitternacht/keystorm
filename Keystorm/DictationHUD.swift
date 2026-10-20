import AppKit
import Observation
import SwiftUI

/// Presents controls without taking focus from the field captured at the start of dictation.
/// Updates are supplied by the existing capture observer; this panel owns no timer or inference.
@MainActor
final class DictationHUDController {
    private let coordinator: DictationCoordinator
    private let showWorkspace: @MainActor @Sendable () -> Void
    private let presentation = DictationHUDPresentation()
    private var panel: DictationHUDPanel?

    init(coordinator: DictationCoordinator, showWorkspace: @escaping @MainActor @Sendable () -> Void) {
        self.coordinator = coordinator
        self.showWorkspace = showWorkspace
    }

    func update(elapsed: Double, preview: String) {
        guard coordinator.state != .idle else { hide(); return }
        presentation.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        presentation.preview = String(preview.suffix(500))
        let panel = panel ?? makePanel()
        guard !panel.isVisible else { return }
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> DictationHUDPanel {
        let panel = DictationHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 205),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("dictation.hud")
        panel.title = String(localized: "Local dictation")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = DictationHUDHostingView(rootView: DictationHUDView(
            coordinator: coordinator, presentation: presentation, showWorkspace: showWorkspace,
            dismiss: { [weak self] in self?.hide() }))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(560, max(300, visible.width - 48)), height: 205)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
            y: visible.minY + min(72, max(24, visible.height * 0.08))))
    }
}

@MainActor
final class DictationHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DictationHUDHostingView: NSHostingView<DictationHUDView> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor @Observable
private final class DictationHUDPresentation {
    var elapsed: Double = 0
    var preview = ""
}

private struct DictationHUDView: View {
    let coordinator: DictationCoordinator
    let presentation: DictationHUDPresentation
    let showWorkspace: @MainActor @Sendable () -> Void
    let dismiss: @MainActor @Sendable () -> Void

    private var modeTitle: LocalizedStringResource {
        if coordinator.hasActiveRecording { return coordinator.captureMode.title }
        return switch coordinator.outputMode {
        case .verbatim: "Verbatim"
        case .clean: "Clean"
        case .summarize: "Summarize"
        case .organize: "Organize"
        case .email: "Email"
        case .translateEnglish: "English translation"
        case .translateGerman: "German translation"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DictationHUDHeader(state: coordinator.state, destination: coordinator.destinationLabel,
                elapsed: presentation.elapsed, modeTitle: modeTitle,
                contextStatus: coordinator.contextProfile == nil ? nil : coordinator.contextStatus)
            DictationHUDPreview(preview: presentation.preview,
                isProvisional: coordinator.state == .recording || coordinator.state == .paused)
            DictationHUDActions(coordinator: coordinator,
                showWorkspace: { showWorkspace() }, dismiss: { dismiss() })
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(DictationHUDSurface())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictation.hud")
    }
}

private struct DictationHUDHeader: View {
    let state: DictationFlowState
    let destination: String
    let elapsed: Double
    let modeTitle: LocalizedStringResource
    var contextStatus: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state == .recording ? "waveform" : state == .paused ? "pause.fill" : "mic")
                .foregroundStyle(state == .recording ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(modeTitle).font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                        .accessibilityLabel("Dictation mode")
                        .accessibilityValue(Text(modeTitle))
                        .accessibilityIdentifier("dictation.hud.mode")
                }
                Text(destination).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let contextStatus {
                    Text(contextStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier("dictation.hud.context")
                }
            }
            Spacer()
            Text(Duration.seconds(elapsed), format: .time(pattern: .hourMinuteSecond))
                .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel("Recording duration")
                .accessibilityValue(Text(Duration.seconds(elapsed),
                    format: .units(allowed: [.hours, .minutes, .seconds], width: .wide)))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var title: LocalizedStringResource {
        switch state {
        case .idle: "Local dictation"
        case .starting: "Starting…"
        case .recording: "Recording locally"
        case .paused: "Recording paused"
        case .processing: "Transcribing locally…"
        case .ready: "Dictation ready"
        case .failed: "Needs attention"
        }
    }
}

private struct DictationHUDPreview: View {
    let preview: String
    let isProvisional: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !preview.isEmpty {
                Text(preview).font(.body).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("dictation.hud.preview")
                if isProvisional {
                    Text("Live preview · may change").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Your words stay on this Mac.")
                    .font(.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
    }
}

private struct DictationHUDActions: View {
    let coordinator: DictationCoordinator
    let showWorkspace: @MainActor @Sendable () -> Void
    let dismiss: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(coordinator.message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Button("Open") { showWorkspace() }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open dictation workspace")
                .accessibilityIdentifier("dictation.hud.open")
            if coordinator.hasActiveRecording {
                Button(action: coordinator.pauseResume) {
                    Image(systemName: coordinator.state == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(coordinator.state == .paused ? "Resume recording" : "Pause recording")
                .accessibilityIdentifier("dictation.hud.pause")
                .disabled(coordinator.isTransitioning)
                Button(action: coordinator.finish) {
                    Label("Finish", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("dictation.hud.finish")
                .disabled(coordinator.isTransitioning)
                Button(action: coordinator.cancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel dictation")
                .accessibilityIdentifier("dictation.hud.cancel")
                .help("Cancel dictation and keep the saved audio. Once insertion begins, it must finish.")
                .disabled(!coordinator.canCancel)
            } else {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss dictation panel")
                .accessibilityIdentifier("dictation.hud.close")
            }
        }
        .controlSize(.regular)
    }
}

private struct DictationHUDSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 24))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }
}


#if DEBUG
private struct DictationHUDDesignPreview: View {
    @State private var coordinator = DictationPreviewFixtures.coordinator(state: .paused)
    @State private var presentation = DictationHUDPresentation()
    let colorScheme: ColorScheme

    var body: some View {
        DictationHUDView(coordinator: coordinator, presentation: presentation,
            showWorkspace: {}, dismiss: {})
            .frame(width: 560, height: 205)
            .padding(24)
            .preferredColorScheme(colorScheme)
            .allowsHitTesting(false)
            .onAppear {
                presentation.elapsed = 86
                presentation.preview = "Please update die Datenschutzerklärung before Friday. Keep every recording on this Mac."
            }
    }
}

#Preview("Dictation panel · Light") { DictationHUDDesignPreview(colorScheme: .light) }
#Preview("Dictation panel · Dark") { DictationHUDDesignPreview(colorScheme: .dark) }
#endif
