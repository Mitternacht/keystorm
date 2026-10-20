import Foundation
import XCTest

/// A bounded OS-key entry probe against already running, manually prepared apps.
/// It never launches, terminates, resets, types a transcript, or simulates delivery.
///
/// Default off. Opt in with `KEYSTORM_RUN_EXISTING_VIDEO_HOTKEY=1` (TextEdit only), or by writing exactly
/// one scenario keyword into the disposable flag file: `textedit`, `stickies-paste`, `stickies-copy`, `dictionary-paste`,
/// `safari-paste` or `safari-copy`.
final class ExistingVideoHotkeyUITests: XCTestCase {
    private static let optInFlag = "/tmp/Keystorm-UI-run-existing-hotkey.flag"
    private static let textEditMarker = "BEGIN VIDEO TEST\n\nEND VIDEO TEST"
    private static let safariMarker = "BEGIN PASTE TEST\n\nEND PASTE TEST"

    private enum Expectation { case inserted, unchanged }

    private static func scenario() -> String? {
        if ProcessInfo.processInfo.environment["KEYSTORM_RUN_EXISTING_VIDEO_HOTKEY"] == "1" { return "textedit" }
        guard let data = FileManager.default.contents(atPath: optInFlag), data.count <= 64 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    func testExistingVideoHotkeyEntry() throws {
        try XCTSkipUnless(Self.scenario() == "textedit",
            "Opt in only with an existing isolated file-audio app and disposable TextEdit document.")
        let receiver = XCUIApplication(bundleIdentifier: "com.apple.TextEdit")
        try runExistingAppEntry(receiver: receiver, marker: Self.textEditMarker, expectation: .inserted) {
            receiver.textViews.firstMatch
        }
    }

    /// Safari is not a qualified Accessibility-text adapter; it uses the validated paste fallback.
    @MainActor
    func testExistingVideoHotkeyPasteIntoSafari() throws {
        try XCTSkipUnless(Self.scenario() == "safari-paste",
            "Opt in only with an existing isolated file-audio app and a disposable local Safari textarea.")
        let receiver = XCUIApplication(bundleIdentifier: "com.apple.Safari")
        try runExistingAppEntry(receiver: receiver, marker: Self.safariMarker, expectation: .inserted) {
            receiver.webViews.firstMatch.descendants(matching: .textView).firstMatch
        }
    }

    /// A native app other than TextEdit (a disposable Stickies note) exercises the validated paste fallback
    /// without browser or IDE automation.
    @MainActor
    func testExistingVideoHotkeyPasteIntoStickies() throws {
        try XCTSkipUnless(Self.scenario() == "stickies-paste",
            "Opt in only with an existing isolated file-audio app and a disposable frontmost Stickies note.")
        let receiver = XCUIApplication(bundleIdentifier: "com.apple.Stickies")
        try runExistingAppEntry(receiver: receiver, marker: Self.safariMarker, expectation: .inserted) {
            receiver.windows.firstMatch.textViews.firstMatch
        }
    }

    /// A single-line native search field (Dictionary) exercises the paste fallback for AXSearchField.
    /// The field starts empty; the integrator verifies the exact bytes from the durable receipt.
    @MainActor
    func testExistingVideoHotkeyPasteIntoDictionarySearch() throws {
        try XCTSkipUnless(Self.scenario() == "dictionary-paste",
            "Opt in only with an existing isolated file-audio app and an empty Dictionary search field.")
        let receiver = XCUIApplication(bundleIdentifier: "com.apple.Dictionary")
        try runExistingAppEntry(receiver: receiver, marker: "", expectation: .inserted) {
            receiver.searchFields.firstMatch
        }
    }

    /// With "Paste into other apps" turned off, the Stickies note must stay unchanged and the result stays copyable.
    @MainActor
    func testExistingVideoHotkeyStickiesCopyFallback() throws {
        try XCTSkipUnless(Self.scenario() == "stickies-copy",
            "Opt in only with paste fallback disabled, an isolated file-audio app and a disposable frontmost Stickies note.")
        let receiver = XCUIApplication(bundleIdentifier: "com.apple.Stickies")
        try runExistingAppEntry(receiver: receiver, marker: Self.safariMarker, expectation: .unchanged) {
            receiver.windows.firstMatch.textViews.firstMatch
        }
    }

    /// With "Paste into other apps" turned off, Safari must stay unchanged and the result stays copyable.
    @MainActor
    func testExistingVideoHotkeySafariCopyFallback() throws {
        try XCTSkipUnless(Self.scenario() == "safari-copy",
            "Opt in only with paste fallback disabled, an isolated file-audio app and a disposable Safari textarea.")
        let receiver = XCUIApplication(bundleIdentifier: "com.apple.Safari")
        try runExistingAppEntry(receiver: receiver, marker: Self.safariMarker, expectation: .unchanged) {
            receiver.webViews.firstMatch.descendants(matching: .textView).firstMatch
        }
    }

    @MainActor
    private func runExistingAppEntry(receiver: XCUIApplication, marker: String, expectation: Expectation,
                                     field: () -> XCUIElement) throws {
        continueAfterFailure = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/tmp/Keystorm-UI-audio-validation.json"))
        let product = XCUIApplication(bundleIdentifier: "dev.mitternacht.Keystorm")
        XCTAssertTrue(product.state == .runningForeground || product.state == .runningBackground,
            "Keystorm must already be running; this helper must not launch it.")
        XCTAssertTrue(receiver.state == .runningForeground || receiver.state == .runningBackground,
            "The receiver must already be running with its disposable document.")
        let indicator = product.descendants(matching: .any)
            .matching(identifier: "dictation.fileValidation").firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5),
            "The existing product must visibly use isolated file audio, never the microphone.")
        XCTAssertTrue(product.buttons["dictation.start"].exists,
            "Begin from idle, so one shortcut cannot finish or pause an unrelated take.")
        receiver.activate()
        XCTAssertEqual(receiver.state, .runningForeground)
        let target = field()
        XCTAssertTrue(target.waitForExistence(timeout: 5), "The disposable receiver field must exist.")
        XCTAssertEqual(target.value as? String, marker,
            "The receiver must be the disposable marker document before any key is sent.")
        target.click()
        receiver.typeKey(.upArrow, modifierFlags: .command)
        receiver.typeKey(.downArrow, modifierFlags: [])
        XCTAssertEqual(target.value as? String, marker)
        receiver.typeKey("d", modifierFlags: [.command, .option, .shift])
        let pause = product.buttons["dictation.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 6),
            "The actual global shortcut must enter recording; key dispatch alone is not a pass.")
        XCTAssertEqual(pause.label, "Pause")
        attach("Product destination and status during recording", product.debugDescription)
        // Finish through the same OS-key route while keeping the receiver focused.
        // Full-file pause/resume is checked separately by the desktop run.
        Thread.sleep(forTimeInterval: 8)
        receiver.activate()
        receiver.typeKey("d", modifierFlags: [.command, .option, .shift])
        XCTAssertTrue(product.buttons["dictation.copy"].waitForExistence(timeout: 30),
            "Normal Finish must complete local transcription before this helper ends.")
        // Delivery confirmation and clipboard restoration run after the result becomes copyable.
        Thread.sleep(forTimeInterval: 3)
        attach("Product status after Finish", product.debugDescription)
        let actual = field().value as? String ?? ""
        attach("Actual disposable receiver after Finish", actual)
        switch expectation {
        case .inserted:
            XCTAssertTrue(actual.hasPrefix(String(marker.prefix(while: { $0 != "\n" }))))
            XCTAssertTrue(actual.hasSuffix(String(marker.split(separator: "\n").last ?? "")))
            XCTAssertGreaterThan(actual.count, marker.count)
        case .unchanged:
            XCTAssertEqual(actual, marker, "Copy fallback must never write into the receiver.")
        }
    }

    private func attach(_ name: String, _ text: String) {
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(string: text)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }
}
