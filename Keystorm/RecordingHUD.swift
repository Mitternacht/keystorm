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
        panel.contentView = RecordingHUDHostingView(
            rootView: RecordingHUDView(state: state, onStop: onStop, onOpenBrief: onOpenBrief)
        )
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

private struct RecordingHUDView: View {
    let state: RecordingHUDState
    let onStop: @MainActor () -> Void
    let onOpenBrief: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecordingHUDHeader(
                isRecording: state.snapshot.isRecording,
                title: state.snapshot.title,
                elapsed: state.snapshot.elapsed
            )
            RecordingHUDTranscript(transcript: state.snapshot.transcript)
            RecordingHUDFooter(
                isRecording: state.snapshot.isRecording,
                status: state.snapshot.status,
                onStop: { onStop() },
                onOpenBrief: { onOpenBrief() }
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(RecordingHUDSurface())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordingHUD")
    }
}

private struct RecordingHUDHeader: View {
    let isRecording: Bool
    let title: String
    let elapsed: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isRecording ? Color.red : Color.secondary)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(isRecording ? LocalizedStringKey("Recording") : LocalizedStringKey("Recorded take"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.callout.weight(.semibold))
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
            .frame(height: 78)
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .onChange(of: transcript) { _, _ in
                proxy.scrollTo("transcriptEnd", anchor: .bottom)
            }
        }
    }
}

private struct RecordingHUDFooter: View {
    let isRecording: Bool
    let status: String
    let onStop: @MainActor () -> Void
    let onOpenBrief: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open brief") { onOpenBrief() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("recordingHUDOpenBrief")
            Button(action: { onStop() }) {
                Label(
                    isRecording ? LocalizedStringKey("Stop") : LocalizedStringKey("Dismiss"),
                    systemImage: isRecording ? "stop.fill" : "xmark"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(isRecording ? Color.red : Color.accentColor)
            .accessibilityIdentifier("recordingHUDStop")
        }
        .controlSize(.regular)
    }
}

private struct RecordingHUDSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 24))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
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
