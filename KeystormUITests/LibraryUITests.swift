import Foundation
import XCTest

final class LibraryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// Exercises persistent brief CRUD through the native library without starting capture.
    @MainActor
    func testBriefTrashRestoreAndRecordingsEmptyState() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("Keystorm-UI-\(UUID().uuidString)", isDirectory: true)
        let app = XCUIApplication()
        app.launchEnvironment["KEYSTORM_UI_TEST_ROOT"] = root.path
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        app.launch()
        app.openDeveloperBriefsIfNeeded()
        XCTAssertTrue(app.buttons["recordPause"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["recordPause"].label, "Record take")

        let title = "Library brief \(UUID().uuidString.prefix(8))"
        app.buttons["Rename"].click()
        let name = app.textFields["briefTitle"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replaceText(name, with: title)
        app.buttons["Save title"].click()
        let row = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
            "briefSession-", title, title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let rowID = row.identifier
        let sessionID = String(rowID.dropFirst("briefSession-".count))
        XCTAssertNotNil(UUID(uuidString: sessionID))

        let requirement = "Preserve this paragraph through Trash and restore. Use 256, never 512."
        app.buttons["addPassage"].click()
        let passageSheet = app.sheets.firstMatch
        let text = passageSheet.textViews["newPassageText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.click(); text.typeText(requirement)
        passageSheet.buttons["confirmPassage"].click()
        XCTAssertTrue(passageSheet.waitForNonExistence(timeout: 5))

        app.buttons["openRecordings"].click()
        let recordings = app.sheets.firstMatch
        XCTAssertTrue(recordings.waitForExistence(timeout: 5))
        XCTAssertTrue(recordings.staticTexts["No recordings yet"].waitForExistence(timeout: 5))
        recordings.buttons["Done"].click()
        XCTAssertTrue(recordings.waitForNonExistence(timeout: 5))

        // Keep a second active brief so soft-deleting the first has a clear selection fallback.
        app.buttons["newBrief"].click()
        let saved = app.descendants(matching: .any).matching(identifier: rowID).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.click()
        saved.rightClick()
        XCTAssertTrue(app.menuItems["Rename…"].waitForExistence(timeout: 5))
        app.menuItems["Rename…"].click()
        let renamedTitle = title + " renamed"
        let renameField = app.textFields["briefTitle"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        replaceText(renameField, with: renamedTitle)
        app.buttons["Save title"].click()
        let heading = app.descendants(matching: .any).matching(identifier: "briefTitleHeading").firstMatch
        XCTAssertTrue(heading.wait(for: \.label, toEqual: renamedTitle, timeout: 5))

        saved.rightClick()
        let trash = app.menuItems["Move to Trash"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.click()
        XCTAssertTrue(saved.waitForNonExistence(timeout: 5), "A trashed brief leaves the active sidebar immediately.")
        app.buttons["openTrash"].click()
        let trashSheet = app.sheets.firstMatch
        XCTAssertTrue(trashSheet.waitForExistence(timeout: 5))
        let restore = trashSheet.buttons["restoreBrief-" + sessionID]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.click()
        XCTAssertTrue(restore.waitForNonExistence(timeout: 5))
        trashSheet.buttons["Done"].click()
        XCTAssertTrue(trashSheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.click()
        XCTAssertTrue(heading.wait(for: \.label, toEqual: renamedTitle, timeout: 5))
        let paragraph = app.textViews.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND value == %@", "briefBlock-", requirement)).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5), "Restore must recover the original editable document.")
        XCTAssertEqual(app.buttons["recordPause"].label, "Record take")
        XCTAssertFalse(app.buttons["finishTake"].isEnabled)

        app.terminate(); app.launch()
        app.openDeveloperBriefsIfNeeded()
        XCTAssertTrue(app.buttons["recordPause"].waitForExistence(timeout: 15))
        let reopened = app.descendants(matching: .any).matching(identifier: rowID).firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        reopened.click()
        XCTAssertTrue(heading.wait(for: \.label, toEqual: renamedTitle, timeout: 5))
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["recordPause"].label, "Record take", "Library operations must not start microphone capture.")
    }

    @MainActor
    private func replaceText(_ element: XCUIElement, with text: String) {
        element.click(); element.typeKey("a", modifierFlags: .command); element.typeText(text)
    }
}
