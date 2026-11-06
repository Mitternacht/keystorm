import AppKit
import AVFoundation
import CryptoKit
import Foundation
import XCTest

/// A bounded OS-key entry probe against manually prepared disposable receivers.
/// TextEdit may launch an absent product only after validating its isolated file-audio manifest.
/// Only that test-owned launch is terminated; no transcript is typed or delivery simulated.
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
        continueAfterFailure = false
        let fixture = try isolatedTextEditFixture()
        let receiver = XCUIApplication(bundleIdentifier: "com.apple.TextEdit")
        // A named file in the validated temporary root, never the first personal document.
        let window = receiver.windows[fixture.receiver.lastPathComponent]
        try runExistingAppEntry(receiver: receiver, marker: Self.textEditMarker, expectation: .inserted,
                                validation: fixture) {
            window.textViews.firstMatch
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
                                     validation: TextEditFixture? = nil,
                                     field: () -> XCUIElement) throws {
        continueAfterFailure = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/tmp/Keystorm-UI-audio-validation.json"))
        let product = XCUIApplication(bundleIdentifier: "dev.mitternacht.Keystorm")
        if validation != nil, product.state == .notRunning {
            // The manifest was fully validated before this method. Its nonnil root also prevents
            // the app's hosted-unit-test suppression from hiding the real shortcut lifecycle.
            // XCTest key synthesis can hold a chord for seconds. Use the real toggle mode
            // through the volatile argument domain; the persisted user preference is untouched.
            product.launchArguments += ["-Keystorm.dictationShortcutMode.v1", "toggle"]
            product.launchEnvironment.removeValue(forKey: "KEYSTORM_UI_TEST_ROOT")
            XCTAssertNil(product.launchEnvironment["KEYSTORM_UI_TEST_ROOT"],
                "The ordinary UI-test root flag disables real global shortcut registration.")
            product.launch()
            addTeardownBlock { @MainActor in product.terminate() }
        }
        XCTAssertTrue(product.state == .runningForeground || product.state == .runningBackground,
            "Only the validated TextEdit scenario may launch an absent product.")
        XCTAssertTrue(receiver.state == .runningForeground || receiver.state == .runningBackground,
            "The receiver must already be running with its disposable document.")
        let indicator = product.descendants(matching: .any)
            .matching(identifier: "dictation.fileValidation").firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5),
            "The existing product must visibly use isolated file audio, never the microphone.")
        XCTAssertTrue(product.buttons["dictation.start"].exists,
            "Begin from idle, so one shortcut cannot finish or pause an unrelated take.")
        if validation != nil {
            product.activate()
            product.typeKey(",", modifierFlags: .command)
            let shortcuts = product.descendants(matching: .any).matching(identifier: "shortcutSettings").firstMatch
            if !shortcuts.waitForExistence(timeout: 2) {
                let shortcutsTab = product.toolbars.buttons["Shortcuts"]
                XCTAssertTrue(shortcutsTab.waitForExistence(timeout: 5),
                    "The macOS Settings tabs are toolbar buttons.")
                shortcutsTab.click()
            }
            XCTAssertTrue(shortcuts.waitForExistence(timeout: 5))
            XCTAssertEqual(product.popUpButtons["dictationShortcutMode"].value as? String,
                "Press to start and finish", "This bounded automated probe uses the launch-only toggle mode.")
            XCTAssertEqual(product.buttons["Start / finish dictation"].value as? String, "⌥⇧⌘D")
            XCTAssertEqual(product.buttons["Show workspace"].value as? String, "⌥⇧⌘B")
            XCTAssertEqual(product.buttons["Pause / resume dictation"].value as? String, "⌥⇧⌘P")
            XCTAssertEqual(product.staticTexts.matching(identifier: "Active globally").count, 3,
                "All three configured default shortcuts must be registered before sending a key.")
            attach("Actual global shortcut registration before key delivery", product.debugDescription)
            product.typeKey("w", modifierFlags: .command)
        }
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
        let previousRecordingIDs = try validation.map { fixture in
            Set(try savedTakes(in: fixture.root).map { $0.recording.id })
        } ?? Set<UUID>()
        let clipboardBefore = validation == nil ? nil : try clipboardContents()
        let clipboardChangeCount = NSPasteboard.general.changeCount
        defer {
            if let validation, let clipboardBefore {
                try? restoreClipboardIfOwned(clipboardBefore, previousChangeCount: clipboardChangeCount,
                    root: validation.root, previousRecordingIDs: previousRecordingIDs)
            }
        }
        if validation != nil {
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, "com.apple.TextEdit")
        }
        let startRequested = ContinuousClock.now
        receiver.typeKey("d", modifierFlags: [.command, .option, .shift])
        let floatingHUD = validation == nil ? nil : try observeFloatingHUD(product: product, receiver: receiver)
        let pause = product.buttons["dictation.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 6),
            "The actual global shortcut must enter recording; key dispatch alone is not a pass.")
        XCTAssertEqual(pause.label, "Pause")
        let recordingUIObserved = ContinuousClock.now
        attach("Product destination and status during recording", product.debugDescription)
        // Finish through the same OS-key route while keeping the receiver focused.
        // Full-file pause/resume is checked separately by the desktop run.
        Thread.sleep(forTimeInterval: validation.map { $0.durationSeconds + 0.5 } ?? 8)
        receiver.activate()
        let finishRequested = ContinuousClock.now
        receiver.typeKey("d", modifierFlags: [.command, .option, .shift])
        XCTAssertTrue(product.buttons["dictation.copy"].waitForExistence(timeout: 30),
            "Normal Finish must complete local transcription before this helper ends.")
        let copyUIObserved = ContinuousClock.now
        if let validation {
            try verifyExactTextEditDelivery(validation, previousRecordingIDs: previousRecordingIDs,
                field: field, startRequested: startRequested, recordingUIObserved: recordingUIObserved,
                floatingHUD: try XCTUnwrap(floatingHUD),
                finishRequested: finishRequested, copyUIObserved: copyUIObserved)
        } else {
            // Paste fallback confirmation and clipboard restoration may follow copy readiness.
            Thread.sleep(forTimeInterval: 3)
        }
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


    private struct FloatingHUDObservation {
        let observedAt: ContinuousClock.Instant
        let frame: CGRect
    }

    /// Queries and captures the real floating panel without clicking it or activating Keystorm.
    /// The timestamp is an XCTest observation upper bound, including key synthesis and AX waits.
    @MainActor
    private func observeFloatingHUD(product: XCUIApplication, receiver: XCUIApplication) throws -> FloatingHUDObservation {
        let hud = product.descendants(matching: .any).matching(identifier: "dictation.hud").firstMatch
        XCTAssertTrue(hud.waitForExistence(timeout: 6), "The global shortcut must show the floating dictation HUD.")
        let pause = hud.buttons["dictation.hud.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: pause)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed,
            "The floating HUD pause control must be visible and hittable above TextEdit.")
        XCTAssertTrue(pause.isHittable)
        XCTAssertEqual(pause.label, "Pause recording")
        let frame = hud.frame
        XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0)
        XCTAssertTrue(frame.contains(pause.frame), "The pause control must fit inside the floating HUD.")
        XCTAssertEqual(receiver.state, .runningForeground)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, "com.apple.TextEdit",
            "Showing the nonactivating HUD must preserve the receiver's focus.")
        let observedAt = ContinuousClock.now
        let screenshot = XCTAttachment(screenshot: hud.screenshot())
        screenshot.name = "Floating dictation HUD — TextEdit remains frontmost"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(receiver.state, .runningForeground)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, "com.apple.TextEdit")
        return FloatingHUDObservation(observedAt: observedAt, frame: frame)
    }

    private struct TextEditFixture {
        let root: URL
        let receiver: URL
        let audio: URL
        let sha256: String
        let frames: Int64
        let durationSeconds: Double
    }

    private struct ValidationManifest: Decodable {
        let version: Int
        let root: String
        let audio: String
        let sha256: String
    }

    private struct SavedSnapshot: Decodable {
        let version: Int
        let session: SavedSession
    }
    private struct SavedSession: Decodable {
        let id: UUID
        let dictation: SavedDictation?
        let segments: [SavedSegment]
    }
    private struct SavedDictation: Decodable { let recordings: [SavedRecording] }
    private struct SavedRecording: Decodable {
        let id: UUID
        let state: String
        let captureMode: String?
        let outputMode: String
        let textRevision: SavedRevision?
        let delivery: SavedDelivery?
        let failureMessage: String?
    }
    private struct SavedRevision: Decodable { let id: UUID; let text: String }
    private struct SavedDelivery: Decodable {
        let requestID: UUID
        let textRevisionID: UUID?
        let targetLabel: String
        let state: String
    }
    private struct SavedSegment: Decodable {
        let frameCount: Int64
        let sampleRate: Double
        let channelCount: Int
    }
    private struct SavedTake {
        let sessionID: UUID
        let recording: SavedRecording
        let segments: [SavedSegment]
    }

    /// Reads only the manifest's validated disposable root. No personal store or document is enumerated.
    private func isolatedTextEditFixture() throws -> TextEditFixture {
        let manifestURL = URL(fileURLWithPath: "/tmp/Keystorm-UI-audio-validation.json")
        let manifest = try JSONDecoder().decode(ValidationManifest.self,
            from: boundedData(at: manifestURL, maximumBytes: 16_384))
        let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        let suppliedRoot = URL(fileURLWithPath: manifest.root, isDirectory: true).standardizedFileURL
        let root = suppliedRoot.resolvingSymlinksInPath()
        let prefix = "Keystorm-UI-"
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(root.deletingLastPathComponent(), temporary)
        XCTAssertEqual(root, temporary.appendingPathComponent(suppliedRoot.lastPathComponent, isDirectory: true))
        XCTAssertTrue(root.lastPathComponent.hasPrefix(prefix))
        XCTAssertNotNil(UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))))
        let audio = URL(fileURLWithPath: manifest.audio).standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertTrue(audio.path.hasPrefix(root.path + "/"))
        let bytes = try boundedData(at: audio, maximumBytes: 32 * 1_024 * 1_024)
        XCTAssertEqual(Self.sha256(bytes), manifest.sha256)
        let file = try AVAudioFile(forReading: audio)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertLessThanOrEqual(file.length, 16_000 * 15, "Keep this UI probe short and bounded.")
        let receiver = root.appendingPathComponent("hotkey-receiver.txt")
        XCTAssertEqual(receiver.resolvingSymlinksInPath(), receiver)
        XCTAssertEqual(try boundedData(at: receiver, maximumBytes: 1_024), Data(Self.textEditMarker.utf8),
            "Create and open only this disposable marker file before running the helper.")
        return TextEditFixture(root: root, receiver: receiver, audio: audio, sha256: manifest.sha256,
            frames: file.length, durationSeconds: Double(file.length) / 16_000)
    }

    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        XCTAssertTrue(values.isRegularFile == true && values.isSymbolicLink != true)
        XCTAssertLessThanOrEqual(try XCTUnwrap(values.fileSize), maximumBytes)
        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, maximumBytes)
        return data
    }

    private func savedTakes(in root: URL) throws -> [SavedTake] {
        let sessions = root.appendingPathComponent("Sessions", isDirectory: true)
        XCTAssertEqual(sessions.resolvingSymlinksInPath(), sessions)
        guard FileManager.default.fileExists(atPath: sessions.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(at: sessions,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        XCTAssertLessThanOrEqual(directories.count, 100, "Use a fresh disposable validation root.")
        var result: [SavedTake] = []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            // FileManager may enumerate /private/tmp while URL canonicalization returns /tmp.
            // Check the directory itself and its listed parent, not those equivalent spellings.
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            XCTAssertTrue(values.isDirectory == true && values.isSymbolicLink != true)
            XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL.path,
                sessions.standardizedFileURL.path)
            let file = directory.appendingPathComponent("session.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let snapshot = try JSONDecoder().decode(SavedSnapshot.self,
                from: boundedData(at: file, maximumBytes: 64 * 1_024 * 1_024))
            XCTAssertEqual(snapshot.version, 1)
            XCTAssertEqual(snapshot.session.id, id)
            result += (snapshot.session.dictation?.recordings ?? []).map {
                SavedTake(sessionID: id, recording: $0, segments: snapshot.session.segments)
            }
        }
        return result
    }

    @MainActor
    private func verifyExactTextEditDelivery(_ fixture: TextEditFixture, previousRecordingIDs: Set<UUID>,
        field: () -> XCUIElement, startRequested: ContinuousClock.Instant,
        recordingUIObserved: ContinuousClock.Instant, floatingHUD: FloatingHUDObservation,
        finishRequested: ContinuousClock.Instant, copyUIObserved: ContinuousClock.Instant) throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var newTakes: [SavedTake] = []
        repeat {
            newTakes = try savedTakes(in: fixture.root).filter { !previousRecordingIDs.contains($0.recording.id) }
            if newTakes.count == 1, newTakes[0].recording.delivery?.state == "inserted" { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while ContinuousClock.now < deadline
        XCTAssertEqual(newTakes.count, 1, "One hotkey take must create exactly one new saved recording.")
        let take = try XCTUnwrap(newTakes.first)
        let recording = take.recording
        let revision = try XCTUnwrap(recording.textRevision)
        let delivery = try XCTUnwrap(recording.delivery)
        XCTAssertEqual(recording.state, "ready")
        XCTAssertNil(recording.failureMessage)
        XCTAssertFalse(revision.text.isEmpty)
        XCTAssertEqual(delivery.state, "inserted")
        XCTAssertEqual(delivery.targetLabel, "TextEdit")
        XCTAssertEqual(delivery.textRevisionID, revision.id)
        if let mode = recording.captureMode, mode == "clean" || mode == "email" {
            XCTAssertEqual(recording.outputMode, mode, "A raw fallback does not qualify a transforming-mode run.")
        }
        let expected = "BEGIN VIDEO TEST\n" + revision.text + "\nEND VIDEO TEST"
        let actual = try XCTUnwrap(field().value as? String)
        XCTAssertEqual(Data(actual.utf8), Data(expected.utf8),
            "The receiver must contain the saved revision exactly once, with both marker lines unchanged.")
        let exactDeliveryObserved = ContinuousClock.now
        XCTAssertTrue(take.segments.allSatisfy { $0.sampleRate == 16_000 && $0.channelCount == 1 && $0.frameCount > 0 })
        let savedFrames = take.segments.reduce(Int64(0)) { $0 + $1.frameCount }
        XCTAssertEqual(savedFrames, fixture.frames, "Finish must drain the complete fixture.")
        XCTAssertEqual(Self.sha256(try boundedData(at: fixture.audio, maximumBytes: 32 * 1_024 * 1_024)), fixture.sha256)
        let report: [String: Any] = [
            "schemaVersion": 2, "kind": "file-audio-hotkey-textedit-ui-v2",
            "generatedAt": Date().formatted(.iso8601), "passed": true,
            "configuration": "Debug file-audio validation", "fixtureSHA256": fixture.sha256,
            "shortcutMode": "toggle", "shortcutModeScope": "Launch-only UserDefaults argument override; persisted preference unchanged. XCTest key duration is not controlled.",
            "fixtureFrames": fixture.frames, "savedFrames": savedFrames,
            "sessionID": take.sessionID.uuidString, "recordingID": recording.id.uuidString,
            "textRevisionID": revision.id.uuidString, "deliveryRequestID": delivery.requestID.uuidString,
            "captureMode": recording.captureMode ?? "verbatim", "outputMode": recording.outputMode,
            "deliveryState": delivery.state, "exactReceiverUTF8Match": true,
            "receiverPath": fixture.receiver.path, "receiverText": actual, "savedRevisionText": revision.text,
            "startKeyRequestToFloatingHUDHittableObservedMilliseconds": Self.milliseconds(startRequested, floatingHUD.observedAt),
            "floatingHUDFrame": ["x": Double(floatingHUD.frame.origin.x), "y": Double(floatingHUD.frame.origin.y),
                "width": Double(floatingHUD.frame.width), "height": Double(floatingHUD.frame.height)],
            "floatingHUDPauseHittable": true, "textEditFrontmostAtHUDObservations": true,
            "floatingHUDScreenshotAttachment": "Floating dictation HUD — TextEdit remains frontmost",
            "floatingHUDTimingScope": "XCTest key-request-to-hittable-HUD observation upper bound; includes synthetic key dispatch, accessibility queries and waits. Not physical key-to-visible-frame latency or a Release percentile.",
            "startKeyRequestToRecordingUIObservedMilliseconds": Self.milliseconds(startRequested, recordingUIObserved),
            "finishKeyRequestToCopyUIObservedMilliseconds": Self.milliseconds(finishRequested, copyUIObserved),
            "finishKeyRequestToExactDeliveryObservedMilliseconds": Self.milliseconds(finishRequested, exactDeliveryObserved),
            "limitations": "One Debug sample; real OS shortcut and TextEdit Accessibility delivery, file PCM source. Timing includes XCTest key synthesis, idle waits and accessibility queries, so it is an observed upper bound, not physical key-to-frame latency, a Release budget qualification, or microphone evidence."
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        // The UI runner is sandboxed. Preserve evidence through XCTest, without asking for
        // write access to the app-owned fixture root or changing any sandbox entitlement.
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "hotkey-validation-" + recording.id.uuidString + ".json"
        attachment.lifetime = .keepAlways
        add(attachment)
        attach("Exact TextEdit delivery and observed UI latency", String(decoding: data, as: UTF8.self))
        let compact = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("KEYSTORM_HOTKEY_EXACT_DELIVERY_JSON " + String(decoding: compact, as: UTF8.self))
        print("KEYSTORM_HOTKEY_EXACT_DELIVERY_COMPLETED " + recording.id.uuidString)
    }

    /// Back up representations without printing personal clipboard contents. The helper writes only its
    /// own saved output back to the previous clipboard; a different later clipboard remains untouched.
    @MainActor
    private func clipboardContents() throws -> [[String: Data]] {
        let items = NSPasteboard.general.pasteboardItems ?? []
        XCTAssertLessThanOrEqual(items.count, 64)
        var bytes = 0
        return try items.map { item in
            XCTAssertLessThanOrEqual(item.types.count, 128)
            var result: [String: Data] = [:]
            for type in item.types {
                let data = try XCTUnwrap(item.data(forType: type), "Clipboard backup must retain every representation.")
                bytes += data.count
                XCTAssertLessThanOrEqual(bytes, 8 * 1_024 * 1_024, "This optional UI probe needs a bounded clipboard backup.")
                result[type.rawValue] = data
            }
            return result
        }
    }

    @MainActor
    private func restoreClipboardIfOwned(_ backup: [[String: Data]], previousChangeCount: Int,
        root: URL, previousRecordingIDs: Set<UUID>) throws {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != previousChangeCount,
              let current = pasteboard.string(forType: .string) else { return }
        let outputs = try savedTakes(in: root)
            .filter { !previousRecordingIDs.contains($0.recording.id) }
            .compactMap { $0.recording.textRevision?.text }
        guard outputs.contains(where: { $0.utf8.elementsEqual(current.utf8) }) else { return }
        let observedChangeCount = pasteboard.changeCount
        let restoredItems = backup.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: .init(type)) }
            return item
        }
        guard pasteboard.changeCount == observedChangeCount else { return }
        pasteboard.clearContents()
        if !restoredItems.isEmpty { XCTAssertTrue(pasteboard.writeObjects(restoredItems)) }
        XCTAssertTrue(try clipboardContents() == backup, "The prior clipboard representations must be restored.")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000
    }

    private func attach(_ name: String, _ text: String) {
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(string: text)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }
}
