import AppKit
import Observation
import SwiftUI

/// A bounded presentation value. Audio and full transcript ownership stay in the workspace.
struct RecordingHUDSnapshot: Equatable {
    var isRecording: Bool
    var title: String
    var transcript: String
    var status: String
    var elapsed: String
}

/// Keeps one nonactivating window alive across takes. Updates arrive from capture/transcript
/// changes; the panel has no polling loop, clock, waveform, or inference work of its own.
@MainActor
final class RecordingHUDController {
    private let state = RecordingHUDState()
    private let onStop: @MainActor () -> Void
    private let onOpenBrief: @MainActor () -> Void
    private var panel: RecordingHUDPanel?

    init(
        onStop: @escaping @MainActor () -> Void,
        onOpenBrief: @escaping @MainActor () -> Void
    ) {
        self.onStop = onStop
        self.onOpenBrief = onOpenBrief
    }

    func update(_ snapshot: RecordingHUDSnapshot) {
        if state.snapshot != snapshot { state.snapshot = snapshot }
        let panel = panel ?? makePanel()
        guard !panel.isVisible else { return }
        position(panel)
        // Showing a take must not move keyboard focus away from the user's current app.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> RecordingHUDPanel {
        let panel = RecordingHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("recordingHUD")
        panel.title = String(localized: "Live recording")
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
        let host = RecordingHUDHostingView(
            rootView: RecordingHUDView(state: state, onStop: onStop, onOpenBrief: onOpenBrief)
        )
        // Fixed-size panel: see `DictationHUDController.makePanel`.
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(600, max(280, visible.width - 48))
        let size = NSSize(width: width, height: 220)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + min(72, max(24, visible.height * 0.08))
        ))
    }
}

@MainActor
private final class RecordingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RecordingHUDHostingView: NSHostingView<RecordingHUDView> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
@Observable
private final class RecordingHUDState {
    var snapshot = RecordingHUDSnapshot(
        isRecording: false, title: "", transcript: "", status: "", elapsed: ""
    )
}

/// Layout constants on an 8-pt rhythm. The panel is 600 x 220; the glass pieces fill it with an even outer inset so
/// Liquid Glass keeps room for its own edge highlight and depth.
private enum RecordingHUDMetrics {
    static let outerInset: CGFloat = 8
    static let rowSpacing: CGFloat = 8
    /// Smaller than the 8-pt layout spacing, so neighbouring glass shapes stay separate at rest and only blend
    /// while a state change morphs them.
    static let glassMergeSpacing: CGFloat = 6
    static let cardCornerRadius: CGFloat = 24
    static let cardHorizontalInset: CGFloat = 16
    static let cardVerticalInset: CGFloat = 12
}

/// Identities that let the glass pieces morph when a take stops: Stop becomes Dismiss in place.
private enum RecordingHUDGlassID: Hashable, Sendable {
    case card, status, openBrief, primary
}

private struct RecordingHUDView: View {
    let state: RecordingHUDState
    let onStop: @MainActor () -> Void
    let onOpenBrief: @MainActor () -> Void
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One container for every glass piece (transcript card, status plate, buttons), so they render together
        // and morph into each other. The pieces are siblings; glass is never nested.
        GlassEffectContainer(spacing: RecordingHUDMetrics.glassMergeSpacing) {
            VStack(spacing: RecordingHUDMetrics.rowSpacing) {
                RecordingHUDCard(
                    isRecording: state.snapshot.isRecording,
                    title: state.snapshot.title,
                    elapsed: state.snapshot.elapsed,
                    transcript: state.snapshot.transcript,
                    namespace: glassNamespace
                )
                RecordingHUDFooter(
                    isRecording: state.snapshot.isRecording,
                    status: state.snapshot.status,
                    namespace: glassNamespace,
                    onStop: { onStop() },
                    onOpenBrief: { onOpenBrief() }
                )
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: state.snapshot.isRecording)
        .padding(RecordingHUDMetrics.outerInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordingHUD")
    }
}

/// The text card: take title and clock above the live transcript. It is the one regular-glass plate that carries
/// text, so it reads over any wallpaper.
private struct RecordingHUDCard: View {
    let isRecording: Bool
    let title: String
    let elapsed: String
    let transcript: String
    let namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: RecordingHUDMetrics.rowSpacing) {
            RecordingHUDHeader(isRecording: isRecording, title: title, elapsed: elapsed)
            RecordingHUDTranscript(transcript: transcript)
        }
        .padding(.horizontal, RecordingHUDMetrics.cardHorizontalInset)
        .padding(.vertical, RecordingHUDMetrics.cardVerticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: RecordingHUDMetrics.cardCornerRadius))
        .glassEffectID(RecordingHUDGlassID.card, in: namespace)
    }
}

private struct RecordingHUDHeader: View {
    let isRecording: Bool
    let title: String
    let elapsed: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Decorative: the word beside it carries the state. Red only while the microphone is open.
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(isRecording ? Color.red : Color.secondary)
                        .symbolEffect(.pulse, isActive: isRecording && !reduceMotion)
                        .accessibilityHidden(true)
                    Text(isRecording ? LocalizedStringKey("Recording") : LocalizedStringKey("Recorded take"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(elapsed)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Elapsed time: \(elapsed)")
        }
    }
}

private struct RecordingHUDTranscript: View {
    let transcript: String
    @ScaledMetric(relativeTo: .title3) private var viewportHeight: CGFloat = 78

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if transcript.isEmpty {
                        Text("Listening…")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("recordingHUDTranscript")
                    } else {
                        Text(transcript)
                            .accessibilityIdentifier("recordingHUDTranscript")
                    }
                    Color.clear.frame(height: 1).id("transcriptEnd")
                }
                .font(.title3)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: viewportHeight)
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .onChange(of: transcript) { _, _ in
                proxy.scrollTo("transcriptEnd", anchor: .bottom)
            }
        }
    }
}

/// The floating controls: a status plate and glass buttons, siblings of the transcript card in the same container.
/// Stop is the one prominent button and is red while the microphone is open; once the take has stopped the same
/// slot becomes a plain glass Dismiss.
private struct RecordingHUDFooter: View {
    let isRecording: Bool
    let status: String
    let namespace: Namespace.ID
    let onStop: @MainActor () -> Void
    let onOpenBrief: @MainActor () -> Void
    @ScaledMetric(relativeTo: .body) private var rowMinHeight: CGFloat = 32

    var body: some View {
        HStack(spacing: RecordingHUDMetrics.rowSpacing) {
            Text(status)
                .font(.caption)
                .lineLimit(2)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: rowMinHeight / 2))
                .glassEffectID(RecordingHUDGlassID.status, in: namespace)
            Button("Open brief") { onOpenBrief() }
                .buttonStyle(.glass)
                .accessibilityIdentifier("recordingHUDOpenBrief")
                .glassEffectID(RecordingHUDGlassID.openBrief, in: namespace)
            if isRecording {
                Button(action: { onStop() }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(Color.red)
                .accessibilityIdentifier("recordingHUDStop")
                .glassEffectID(RecordingHUDGlassID.primary, in: namespace)
            } else {
                Button(action: { onStop() }) {
                    Label("Dismiss", systemImage: "xmark")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("recordingHUDStop")
                .glassEffectID(RecordingHUDGlassID.primary, in: namespace)
            }
        }
        .controlSize(.large)
    }
}

#Preview("Live transcript") {
    let state = RecordingHUDState()
    state.snapshot = RecordingHUDSnapshot(
        isRecording: true,
        title: "Add material · Constraints",
        transcript: "Keep all processing local. The recording needs to survive a restart, and I want to review the exact changes before adding them to the brief. Use 256, not 512.",
        status: "Live preview · may change · Saved through 0:24",
        elapsed: "00:26"
    )
    return RecordingHUDView(state: state, onStop: {}, onOpenBrief: {})
        .frame(width: 600, height: 220)
        .padding(24)
}
