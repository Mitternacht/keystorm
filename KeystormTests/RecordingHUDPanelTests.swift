import AppKit
import Testing
@testable import Keystorm

@Suite(.serialized)
@MainActor
struct RecordingHUDPanelTests {
    @Test func panelIsReusedWithoutTakingKeyboardFocus() throws {
        let controller = RecordingHUDController(onStop: {}, onOpenBrief: {})
        defer { controller.hide() }
        let initial = RecordingHUDSnapshot(isRecording: true, title: "Add material",
            transcript: "Keep all processing local.", status: "Transcribing locally", elapsed: "0:10")
        controller.update(initial)
        let panel = try #require(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == "recordingHUD" && $0.isVisible
        } as? NSPanel)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isOpaque)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))

        var changed = initial
        changed.transcript = "Use 256, not 512."
        changed.elapsed = "0:15"
        controller.update(changed)
        let updated = try #require(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == "recordingHUD" && $0.isVisible
        })
        #expect(updated === panel)
        controller.hide()
        #expect(!panel.isVisible)
        controller.update(changed)
        #expect(panel.isVisible)
        #expect(NSApplication.shared.windows.filter {
            $0.identifier?.rawValue == "recordingHUD" && $0.isVisible
        }.count == 1)
    }
}
