import Foundation
import XCTest

/// The default workspace is exercised through the same navigation shown to users.
/// Isolated storage contains no models, so these checks never request microphone access.
final class DictationWorkspaceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testLocalDictationIsTheDefaultWorkspace() throws {
        let fixture = launchIsolated()
        defer { fixture.app.terminate(); try? FileManager.default.removeItem(at: fixture.root) }
        let app = fixture.app
        XCTAssertTrue(app.buttons["dictation.start"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["English + Deutsch"].exists)
        XCTAssertTrue(app.staticTexts["Verbatim"].exists)
        XCTAssertTrue(app.staticTexts["History"].exists)
        XCTAssertTrue(app.buttons["dictation.openLegacy"].exists)
        XCTAssertFalse(app.buttons["dictation.pause"].exists)
        XCTAssertFalse(app.buttons["dictation.finish"].exists)
        XCTAssertFalse(app.buttons["dictation.copy"].exists)
        let result = app.textViews["dictation.result"]
        XCTAssertTrue(result.exists)
        XCTAssertFalse(result.isEnabled)
        XCTAssertEqual(result.value as? String ?? "", "")
        XCTAssertFalse(app.buttons["recordPause"].exists)
        try assertNoCapture(in: fixture.root)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Default local dictation workspace"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testDeveloperBriefsAreAnExplicitRoundTrip() throws {
        let fixture = launchIsolated()
        defer { fixture.app.terminate(); try? FileManager.default.removeItem(at: fixture.root) }
        let app = fixture.app
        XCTAssertTrue(app.buttons["dictation.openLegacy"].waitForExistence(timeout: 20))
        app.buttons["dictation.openLegacy"].click()
        XCTAssertTrue(app.buttons["recordPause"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["recordPause"].label, "Record take")
        XCTAssertTrue(app.buttons["dictation.back"].exists)
        app.buttons["dictation.back"].click()
        XCTAssertTrue(app.buttons["dictation.start"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["recordPause"].exists)
        XCTAssertTrue(app.buttons["dictation.openLegacy"].exists)
        try assertNoCapture(in: fixture.root)
    }

    @MainActor
    func testMissingLocalModelFailsBeforeMicrophoneCapture() throws {
        let fixture = launchIsolated()
        defer { fixture.app.terminate(); try? FileManager.default.removeItem(at: fixture.root) }
        let app = fixture.app
        let start = app.buttons["dictation.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.click()
        let actionable = app.descendants(matching: .any).matching(NSPredicate(format:
            "(label CONTAINS %@ OR value CONTAINS %@) AND (label CONTAINS %@ OR value CONTAINS %@)",
            "local multilingual speech model", "local multilingual speech model", "Local Models", "Local Models")).firstMatch
        XCTAssertTrue(actionable.waitForExistence(timeout: 10))
        XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        XCTAssertFalse(app.buttons["dictation.pause"].exists)
        XCTAssertFalse(app.buttons["dictation.finish"].exists)
        XCTAssertFalse(app.buttons["dictation.copy"].exists)
        XCTAssertTrue(app.buttons["Local models"].exists)
        try assertNoCapture(in: fixture.root)
    }

    @MainActor
    private func launchIsolated() -> (app: XCUIApplication, root: URL) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("Keystorm-UI-\(UUID().uuidString)", isDirectory: true)
        let app = XCUIApplication()
        app.launchEnvironment["KEYSTORM_UI_TEST_ROOT"] = root.path
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return (app, root)
    }

    private func assertNoCapture(in root: URL) throws {
        let sessions = root.appendingPathComponent("Sessions", isDirectory: true)
        let directories = try FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)
        XCTAssertFalse(directories.isEmpty)
        for directory in directories {
            let url = directory.appendingPathComponent("session.json")
            let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let session = try XCTUnwrap(snapshot["session"] as? [String: Any])
            XCTAssertEqual((session["intervals"] as? [Any])?.count, 0)
            XCTAssertEqual((session["segments"] as? [Any])?.count, 0)
            XCTAssertNotEqual(session["status"] as? String, "recording")
        }
    }
}

extension XCUIApplication {
    /// Existing brief tests enter through the real product navigation after each launch.
    @MainActor
    func openDeveloperBriefsIfNeeded() {
        if buttons["recordPause"].exists { return }
        let open = buttons["dictation.openLegacy"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.click()
    }
}
