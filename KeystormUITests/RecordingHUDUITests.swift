import Foundation
import XCTest

final class RecordingHUDUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// Exercises the real panel and observation path using a bounded DEBUG-only fixture.
    /// No microphone, model, or personal application data is used.
    @MainActor
    func testLivePanelUpdatesAndCanRestoreClosedBrief() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("Keystorm-UI-\(UUID().uuidString)", isDirectory: true)
        let app = XCUIApplication()
        app.launchEnvironment["KEYSTORM_UI_TEST_ROOT"] = root.path
        app.launchEnvironment["KEYSTORM_HUD_PREVIEW"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launch()
        app.openDeveloperBriefsIfNeeded()
        let transcript = app.staticTexts["recordingHUDTranscript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        let update = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
            "Use 256, not 512. Preserve every negation.", "Use 256, not 512. Preserve every negation.")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: update, object: transcript)], timeout: 8), .completed)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Liquid Glass recording panel — synthetic transcript"
        attachment.lifetime = .keepAlways
        add(attachment)
        let previewStatus = app.staticTexts.matching(NSPredicate(format:
            "(label CONTAINS %@ OR value CONTAINS %@) AND (label CONTAINS %@ OR value CONTAINS %@)",
            "Live preview", "Live preview", "Microphone is off", "Microphone is off")).firstMatch
        XCTAssertTrue(previewStatus.exists, "Provisional words must be visible before any saved segment.")
        XCTAssertEqual(app.buttons["recordPause"].label, "Record take")

        let workspace = app.windows["Keystorm"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(transcript.exists, "Closing the workspace must leave the recording panel available.")
        app.buttons["recordingHUDOpenBrief"].click()
        XCTAssertTrue(app.buttons["recordPause"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["recordPause"].label, "Record take",
                       "Restoring the brief must not start a recording.")

        app.buttons["recordingHUDStop"].click()
        XCTAssertTrue(transcript.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["recordPause"].label, "Record take")
    }
}
