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
    private let levelMeter: InputLevelMeter
    private var panel: DictationHUDPanel?
    private var meterTask: Task<Void, Never>?

    init(coordinator: DictationCoordinator, showWorkspace: @escaping @MainActor @Sendable () -> Void,
         levelMeter: InputLevelMeter = .shared) {
        self.coordinator = coordinator
        self.showWorkspace = showWorkspace
        self.levelMeter = levelMeter
    }

    func update(elapsed: Double, preview: String) {
        guard coordinator.state != .idle else { hide(); return }
        presentation.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        presentation.preview = String(preview.suffix(500))
        updateMeter()
        let panel = panel ?? makePanel()
        guard !panel.isVisible else { return }
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        stopMeter()
        panel?.orderOut(nil)
    }

    /// The level loop runs only while the microphone is open and the panel is up: about 30 updates a second,
    /// each one a lock read and a little arithmetic. It writes the view's level only when the bar would move.
    private func updateMeter() {
        guard coordinator.state == .recording else { stopMeter(); return }
        guard meterTask == nil else { return }
        let presentation = presentation
        let meter = levelMeter
        meterTask = Task { @MainActor in
            var smoother = LevelSmoother()
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                let now = ContinuousClock.now
                let components = previous.duration(to: now).components
                let elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
                previous = now
                let level = Double(smoother.step(target: meter.read().meterTarget, elapsed: elapsed))
                if abs(level - presentation.level) > 0.002 || (level == 0 && presentation.level != 0) {
                    presentation.level = level
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
        if presentation.level != 0 { presentation.level = 0 }
    }

    /// Dismiss keeps the panel hidden for this take; the next Start shows it again.
    private func dismiss() {
        coordinator.dismissRecordingHUD()
        hide()
    }

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
        let host = DictationHUDHostingView(rootView: DictationHUDView(
            coordinator: coordinator, presentation: presentation, showWorkspace: showWorkspace,
            dismiss: { [weak self] in self?.dismiss() }))
        // The panel's size is set by `position`. Letting the content set the window's size limits made AppKit
        // re-run constraint updates inside SwiftUI's own layout pass while the glass pieces morphed, which can
        // end in "too many Update Constraints passes" and a crash.
        host.sizingOptions = []
        panel.contentView = host
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
    /// Smoothed microphone level, 0...1. Written only by the controller's level loop and read only by
    /// `DictationHUDLevelMeter`, so a level tick redraws that one view.
    var level: Double = 0
}

/// Layout constants on an 8-pt rhythm. The panel is 560 x 205; the glass pieces fill it with an even outer inset so
/// Liquid Glass keeps room for its own edge highlight and depth.
private enum DictationHUDMetrics {
    static let outerInset: CGFloat = 8
    static let rowSpacing: CGFloat = 8
    /// Smaller than the 8-pt layout spacing, so neighbouring glass shapes stay separate at rest and only blend
    /// while a state change morphs them.
    static let glassMergeSpacing: CGFloat = 6
    static let cardCornerRadius: CGFloat = 24
    static let cardHorizontalInset: CGFloat = 16
    static let cardVerticalInset: CGFloat = 12
}

/// Identities that let the glass pieces morph into each other as the flow moves between states: the primary action
/// becomes Finish, Copy or Retry in place, and the circular secondary buttons trade places.
private enum DictationHUDGlassID: Hashable, Sendable {
    case card, message, open, secondary, primary, dismiss
}

private struct DictationHUDView: View {
    let coordinator: DictationCoordinator
    let presentation: DictationHUDPresentation
    let showWorkspace: @MainActor @Sendable () -> Void
    let dismiss: @MainActor @Sendable () -> Void
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // One container for every glass piece (text card, message, buttons), so they render together and
        // morph into each other when the state changes. Glass sits only on the floating layer; the glass pieces
        // are siblings and never nested.
        GlassEffectContainer(spacing: DictationHUDMetrics.glassMergeSpacing) {
            VStack(spacing: DictationHUDMetrics.rowSpacing) {
                DictationHUDCard(state: coordinator.state, processingPhase: coordinator.processingPhase,
                    presentation: presentation, destination: coordinator.destinationLabel,
                    modeTitle: modeTitle,
                    contextStatus: coordinator.contextProfile == nil ? nil : coordinator.contextStatus,
                    // A finished result shows the final text, not the last live preview.
                    preview: coordinator.state == .ready ?
                        String(coordinator.resultText.prefix(500)) : presentation.preview,
                    isFinal: coordinator.state == .ready,
                    isProvisional: coordinator.state == .recording || coordinator.state == .paused,
                    namespace: glassNamespace)
                DictationHUDActions(coordinator: coordinator, namespace: glassNamespace,
                    showWorkspace: { showWorkspace() }, dismiss: { dismiss() })
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: coordinator.state)
        .padding(DictationHUDMetrics.outerInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictation.hud")
    }
}

/// The text card: state, destination, timer and level above the live or final text. It is the one regular-glass
/// plate that carries text, so it reads over any wallpaper.
private struct DictationHUDCard: View {
    let state: DictationFlowState
    let processingPhase: DictationProcessingPhase
    let presentation: DictationHUDPresentation
    let destination: String
    let modeTitle: LocalizedStringResource
    let contextStatus: String?
    let preview: String
    let isFinal: Bool
    let isProvisional: Bool
    let namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: DictationHUDMetrics.rowSpacing) {
            DictationHUDHeader(state: state, processingPhase: processingPhase,
                presentation: presentation, destination: destination,
                modeTitle: modeTitle, contextStatus: contextStatus)
            DictationHUDPreview(preview: preview, isFinal: isFinal, isProvisional: isProvisional)
        }
        .padding(.horizontal, DictationHUDMetrics.cardHorizontalInset)
        .padding(.vertical, DictationHUDMetrics.cardVerticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: DictationHUDMetrics.cardCornerRadius))
        .glassEffectID(DictationHUDGlassID.card, in: namespace)
    }
}

private struct DictationHUDHeader: View {
    let state: DictationFlowState
    let processingPhase: DictationProcessingPhase
    let presentation: DictationHUDPresentation
    let destination: String
    let modeTitle: LocalizedStringResource
    var contextStatus: String? = nil

    var body: some View {
        // Read here, not in the parent, so the once-a-second clock invalidates only this header.
        let elapsed = presentation.elapsed
        HStack(spacing: 8) {
            DictationHUDStatusIcon(state: state, processingPhase: processingPhase)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    Text(modeTitle).font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
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
            Spacer(minLength: 8)
            if state == .recording || state == .paused {
                DictationHUDLevelMeter(presentation: presentation, isLive: state == .recording)
            }
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
        case .processing: processingTitle
        case .ready: "Dictation ready"
        case .failed: "Needs attention"
        }
    }

    private var processingTitle: LocalizedStringResource {
        switch processingPhase {
        case .transcribing: "Transcribing…"
        case .cleaning: "Cleaning up…"
        case .inserting: "Inserting…"
        }
    }
}

/// The state symbol. It is decorative (the title beside it says the same in words), so it is hidden from
/// accessibility; color and motion only reinforce the state: red while the microphone is open, green once ready.
private struct DictationHUDStatusIcon: View {
    let state: DictationFlowState
    let processingPhase: DictationProcessingPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title3) private var width: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, isActive: (state == .starting || state == .recording) && !reduceMotion)
            .symbolEffect(.variableColor.iterative, isActive: state == .processing && !reduceMotion)
            .frame(width: width)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .idle, .starting: "mic"
        case .recording: "waveform"
        case .paused: "pause.fill"
        case .processing:
            switch processingPhase {
            case .transcribing: "waveform"
            case .cleaning: "sparkles"
            case .inserting: "text.insert"
            }
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .recording: .red
        case .ready: .green
        case .failed: .orange
        case .processing: .accentColor
        case .idle, .starting, .paused: .secondary
        }
    }
}

/// A live microphone level. It reads `presentation.level` itself, so only this view redraws at the meter's rate.
/// The fill is red while the microphone is open and turns orange near clipping; the track is a quiet fill.
private struct DictationHUDLevelMeter: View {
    let presentation: DictationHUDPresentation
    let isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var width: CGFloat = 64
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 6

    var body: some View {
        let level = isLive ? min(1, max(0, presentation.level)) : 0
        Capsule()
            .fill(.quaternary)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(level > 0.92 ? Color.orange : Color.red)
                    .frame(width: width * level)
            }
            // The loop already smooths attack and release; this only interpolates between its ~30 Hz steps.
            .animation(reduceMotion ? nil : .linear(duration: 0.08), value: level)
            .accessibilityElement()
            .accessibilityLabel("Microphone level")
            .accessibilityValue(Text(AudioLevelScale.description(level: level)))
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("dictation.hud.level")
    }
}

/// Live words are body text with a "may change" note; the finished result steps up one text style so the two
/// are told apart by size as well as by the note.
private struct DictationHUDPreview: View {
    let preview: String
    var isFinal = false
    let isProvisional: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !preview.isEmpty {
                Text(preview).font(isFinal ? .title3 : .body).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("dictation.hud.preview")
                if isProvisional {
                    Text("Live preview · may change").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Your words stay on this Mac.")
                    .font(.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The floating controls: a message plate and glass buttons, siblings of the text card in the same container.
/// Finish, Copy and Retry share one glass identity so the primary action morphs in place between states; it is
/// the one prominent button. Recording is red; everything else uses the accent or plain glass.
private struct DictationHUDActions: View {
    let coordinator: DictationCoordinator
    let namespace: Namespace.ID
    let showWorkspace: @MainActor @Sendable () -> Void
    let dismiss: @MainActor @Sendable () -> Void
    @ScaledMetric(relativeTo: .body) private var rowMinHeight: CGFloat = 32

    var body: some View {
        HStack(spacing: DictationHUDMetrics.rowSpacing) {
            Text(coordinator.message).font(.caption)
                .lineLimit(2)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: rowMinHeight / 2))
                .glassEffectID(DictationHUDGlassID.message, in: namespace)
            Button("Open") { showWorkspace() }
                .buttonStyle(.glass)
                .accessibilityLabel("Open dictation workspace")
                .accessibilityIdentifier("dictation.hud.open")
                .glassEffectID(DictationHUDGlassID.open, in: namespace)
            if coordinator.hasActiveRecording {
                Button(action: coordinator.pauseResume) {
                    Image(systemName: coordinator.state == .paused ? "play.fill" : "pause.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(coordinator.state == .paused ? "Resume recording" : "Pause recording")
                .accessibilityIdentifier("dictation.hud.pause")
                .disabled(coordinator.isTransitioning)
                .glassEffectID(DictationHUDGlassID.secondary, in: namespace)
                Button(action: coordinator.finish) {
                    Label("Finish", systemImage: "stop.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(coordinator.state == .recording ? Color.red : Color.accentColor)
                .accessibilityIdentifier("dictation.hud.finish")
                .disabled(coordinator.isTransitioning)
                .glassEffectID(DictationHUDGlassID.primary, in: namespace)
                Button(action: coordinator.cancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Cancel dictation")
                .accessibilityIdentifier("dictation.hud.cancel")
                .help("Cancel dictation and keep the saved audio. Once insertion begins, it must finish.")
                .disabled(!coordinator.canCancel)
                .glassEffectID(DictationHUDGlassID.dismiss, in: namespace)
            } else {
                if coordinator.state == .ready, !coordinator.deliveredOnFinish {
                    Button(action: coordinator.copyResult) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel("Copy dictation text")
                    .accessibilityIdentifier("dictation.hud.copy")
                    .disabled(coordinator.isTransitioning || coordinator.resultText.allSatisfy(\.isWhitespace))
                    .glassEffectID(DictationHUDGlassID.primary, in: namespace)
                } else if coordinator.state == .failed, coordinator.handle != nil {
                    // The same retry as the workspace: Finish again on the failed recording.
                    Button(action: coordinator.finish) {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel("Retry transcription")
                    .accessibilityIdentifier("dictation.hud.retry")
                    .disabled(coordinator.isTransitioning)
                    .glassEffectID(DictationHUDGlassID.primary, in: namespace)
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Dismiss dictation panel")
                .accessibilityIdentifier("dictation.hud.close")
                .glassEffectID(DictationHUDGlassID.dismiss, in: namespace)
            }
        }
        .controlSize(.large)
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
