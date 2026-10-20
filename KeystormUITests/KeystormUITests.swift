import Foundation
import XCTest

final class KeystormUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// Uses only deliberate text entry. No microphone, model download, clipboard mutation, or export.
    /// Every mutation lives in the DEBUG-only isolated root, never in personal application data.
    @MainActor
    func testImplementationBriefEditingReviewAndPersistence() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("Keystorm-UI-\(UUID().uuidString)", isDirectory: true)
        let app = XCUIApplication()
        app.launchEnvironment["KEYSTORM_UI_TEST_ROOT"] = root.path
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launch()
        app.openDeveloperBriefsIfNeeded()
        let record = app.buttons["recordPause"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        XCTAssertEqual(record.label, "Record take")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.sqlite").path),
                      "The app must initialize the isolated test root before any mutation.")

        let title = "UI brief \(UUID().uuidString.prefix(8))"
        XCTContext.runActivity(named: "Name the brief and add an ordinary editable paragraph") { _ in
            app.buttons["Rename"].click()
            let name = app.textFields["briefTitle"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            replaceText(in: name, with: title)
            app.buttons["Save title"].click()
        }
        // A combined sidebar row speaks its title, date, and duration as one element.
        // Capture its durable session identity instead of depending on the incidental AX role.
        let namedSession = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
            "briefSession-", title, title)).firstMatch
        XCTAssertTrue(namedSession.waitForExistence(timeout: 5))
        let sessionIdentifier = namedSession.identifier
        XCTAssertNotNil(UUID(uuidString: String(sessionIdentifier.dropFirst("briefSession-".count))))
        let heading = app.descendants(matching: .any).matching(identifier: "briefTitleHeading").firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.wait(for: \.label, toEqual: title, timeout: 5),
                      "The selectable accessibility heading must reflect a renamed brief.")
        let requirement = "Use 256, not 512. Never overwrite /tmp/Keystorm_v2."
        app.buttons["section-changes"].click()
        addPassage(requirement, exact: false, app: app)
        let originalEditor = paragraph(containing: requirement, in: app)
        XCTAssertTrue(originalEditor.waitForExistence(timeout: 5))
        let originalIdentifier = originalEditor.identifier
        let blockID = String(originalIdentifier.dropFirst("briefBlock-".count))
        XCTAssertNotNil(UUID(uuidString: blockID))

        let literal = "  let cacheLimit = 256;\n\t// Never overwrite /tmp/Keystorm_v2.\n"
        XCTContext.runActivity(named: "Insert exact code with preserved whitespace") { _ in
            addPassage(literal, exact: true, app: app)
            let exact = paragraph(containing: literal, in: app)
            XCTAssertTrue(exact.waitForExistence(timeout: 5))
            XCTAssertEqual(Array(exact.textValue.utf8), Array(literal.utf8))
            XCTAssertTrue(app.staticTexts["Exact reference"].exists)
        }

        XCTContext.runActivity(named: "Preview a targeted move without changing the document, then apply it") { _ in
            target(blockID: blockID, in: app)
            preview("move selected to constraints", app: app)
            XCTAssertTrue(app.staticTexts["Move to Constraints"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textViews[originalIdentifier].textValue, requirement,
                           "A preview must preserve the existing document until accepted.")
            applyProposal(in: app)
            app.buttons["section-constraints"].click()
            XCTAssertTrue(app.textViews[originalIdentifier].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["section-constraints"].label.contains("1"),
                          "The requirement must now belong to Constraints.")
        }

        let replacement = "Use 128 for the cache only. Never overwrite /tmp/Keystorm_v2."
        XCTContext.runActivity(named: "Replace the selected passage, then undo the accepted command") { _ in
            target(blockID: blockID, in: app)
            preview("replace selected with " + replacement, app: app)
            XCTAssertEqual(app.textViews[originalIdentifier].textValue, requirement)
            applyProposal(in: app)
            XCTAssertTrue(app.textViews[originalIdentifier].wait(for: \.textValue, toEqual: replacement, timeout: 5))
            app.buttons["undoBrief"].click()
            XCTAssertTrue(app.textViews[originalIdentifier].wait(for: \.textValue, toEqual: requirement, timeout: 5))
        }

        XCTContext.runActivity(named: "Exact references reject rewriting until explicitly unlocked") { _ in
            app.buttons["section-changes"].click()
            let exact = paragraph(containing: literal, in: app)
            XCTAssertTrue(exact.waitForExistence(timeout: 5))
            let exactID = String(exact.identifier.dropFirst("briefBlock-".count))
            let actions = app.descendants(matching: .any).matching(identifier: "passageActions-" + exactID).firstMatch
            XCTAssertTrue(actions.waitForExistence(timeout: 5))
            actions.click()
            XCTAssertTrue(app.menuItems["Unlock exact reference for editing"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.menuItems["Remove reference"].exists)
            XCTAssertFalse(app.menuItems["Remove passage"].exists,
                           "A protected reference must be explicitly unlocked before removal.")
            app.typeKey(.escape, modifierFlags: [])
            target(blockID: exactID, in: app)
            preview("replace selected with This must not replace an exact reference.", app: app)
            app.buttons["applyBriefChange"].click()
            let alert = app.sheets.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                "Unlock it deliberately", "Unlock it deliberately")).firstMatch.exists)
            alert.buttons["OK"].click()
            XCTAssertEqual(Array(exact.textValue.utf8), Array(literal.utf8))
            let discard = app.buttons["discardBriefChange"]
            XCTAssertTrue(discard.waitForExistence(timeout: 5))
            discard.click()
            XCTAssertTrue(discard.waitForNonExistence(timeout: 5))
        }

        let copy = app.buttons["copyBrief"]
        let save = app.buttons["saveBrief"]
        XCTAssertFalse(copy.isEnabled)
        XCTAssertFalse(save.isEnabled)
        XCTContext.runActivity(named: "One focused final review enables deliberate handoff") { _ in
            app.buttons["reviewBrief"].click()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5))
            let confirmation = sheet.checkBoxes["confirmBriefReview"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
            XCTAssertEqual(sheet.checkBoxes.count, 1, "Finishing a brief must not require checking every ledger fact.")
            let approve = sheet.buttons["approveBrief"]
            XCTAssertFalse(approve.isEnabled)
            confirmation.click()
            XCTAssertTrue(approve.wait(for: \.isEnabled, toEqual: true, timeout: 5))
            approve.click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
            XCTAssertTrue(copy.wait(for: \.isEnabled, toEqual: true, timeout: 5))
            XCTAssertTrue(save.isEnabled)
        }

        let edited = requirement + " Preserve quoted identifiers."
        XCTContext.runActivity(named: "Further typing revokes review and survives switching and relaunch") { _ in
            app.buttons["section-constraints"].click()
            let editor = app.textViews[originalIdentifier]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            replaceText(in: editor, with: edited)
            XCTAssertTrue(editor.wait(for: \.textValue, toEqual: edited, timeout: 5))
            XCTAssertTrue(copy.wait(for: \.isEnabled, toEqual: false, timeout: 5))
            XCTAssertFalse(save.isEnabled)
            app.buttons["newBrief"].click()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
            let changedHeading = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == TRUE AND label != %@ AND label != %@", title, ""), object: heading)
            XCTAssertEqual(XCTWaiter.wait(for: [changedHeading], timeout: 5), .completed,
                           "A new brief must not retain the old accessibility heading.")
            let savedSession = app.descendants(matching: .any).matching(identifier: sessionIdentifier).firstMatch
            XCTAssertTrue(savedSession.waitForExistence(timeout: 5))
            XCTAssertTrue(savedSession.label.contains(title) || savedSession.textValue.contains(title))
            savedSession.click()
            XCTAssertTrue(heading.wait(for: \.label, toEqual: title, timeout: 5))
            app.buttons["section-constraints"].click()
            XCTAssertTrue(app.textViews[originalIdentifier].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textViews[originalIdentifier].textValue, edited)

            // Switching briefs is an explicit flush boundary before terminate/relaunch.
            app.buttons["newBrief"].click()
            XCTAssertTrue(app.textViews[originalIdentifier].waitForNonExistence(timeout: 5))
            app.terminate()
            app.launch()
            app.openDeveloperBriefsIfNeeded()
            XCTAssertTrue(app.buttons["recordPause"].waitForExistence(timeout: 15))
            let reopened = app.descendants(matching: .any).matching(identifier: sessionIdentifier).firstMatch
            XCTAssertTrue(reopened.waitForExistence(timeout: 5))
            XCTAssertTrue(reopened.label.contains(title) || reopened.textValue.contains(title),
                          "The same named brief must survive relaunch with its durable session identity.")
            reopened.click()
            XCTAssertTrue(heading.wait(for: \.label, toEqual: title, timeout: 5))
            app.buttons["section-constraints"].click()
            XCTAssertTrue(app.textViews[originalIdentifier].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textViews[originalIdentifier].textValue, edited)
            XCTAssertFalse(app.buttons["copyBrief"].isEnabled)
            XCTAssertFalse(app.buttons["saveBrief"].isEnabled)
        }
        XCTAssertEqual(app.buttons["recordPause"].label, "Record take",
                       "This workflow must never start microphone capture.")
    }

    @MainActor
    private func addPassage(_ text: String, exact: Bool, app: XCUIApplication) {
        if exact {
            let menu = app.descendants(matching: .any).matching(identifier: "insertExactReferenceMenu").firstMatch
            if menu.waitForExistence(timeout: 2) { menu.click() }
            else { app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Exact reference")).firstMatch.click() }
            let insert = app.menuItems["Insert exact text…"]
            XCTAssertTrue(insert.waitForExistence(timeout: 5))
            insert.click()
        } else {
            app.buttons["addPassage"].click()
        }
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let entry = sheet.textViews["newPassageText"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.click()
        entry.typeText(text)
        let confirm = sheet.buttons["confirmPassage"]
        XCTAssertTrue(confirm.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        confirm.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func paragraph(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "briefBlock-", text)).firstMatch
    }

    @MainActor
    private func target(blockID: String, in app: XCUIApplication) {
        let target = app.buttons["target-" + blockID]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.click()
    }

    @MainActor
    private func preview(_ command: String, app: XCUIApplication) {
        let field = app.textFields["briefCommand"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replaceText(in: field, with: command)
        XCTAssertTrue(field.wait(for: \.textValue, toEqual: command, timeout: 5),
                      "The edit field must receive the complete literal command before proposing a change. Actual input: \(field.textValue)")
        let preview = app.buttons["previewBriefEdit"]
        XCTAssertTrue(preview.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        preview.click()
        XCTAssertTrue(app.buttons["applyBriefChange"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func applyProposal(in app: XCUIApplication) {
        let apply = app.buttons["applyBriefChange"]
        XCTAssertTrue(apply.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        apply.click()
        XCTAssertTrue(apply.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func replaceText(in element: XCUIElement, with text: String) {
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(text)
    }
}

private extension XCUIElement {
    var textValue: String { value as? String ?? "" }
}
