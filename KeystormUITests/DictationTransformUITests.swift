import Foundation
import XCTest

private extension XCUIElement {
    var rewriteText: String { value as? String ?? "" }
}

/// Uses saved local text only. No microphone, model, clipboard, or external app is involved.
final class DictationTransformUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSavedVersionsRestoreOriginalAndRewriteWithoutStartingCapture() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("Keystorm-UI-" + UUID().uuidString, isDirectory: true)
        let app = XCUIApplication()
        app.launchEnvironment["KEYSTORM_UI_TEST_ROOT"] = root.path
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        app.launch()
        XCTAssertTrue(app.buttons["dictation.start"].waitForExistence(timeout: 20))
        app.terminate()
        let fixture = try seedSavedVersions(in: root)
        app.launch()
        let history = app.descendants(matching: .any)
            .matching(identifier: "dictation.history." + fixture.takeID).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 20))
        history.click()
        let result = app.textViews["dictation.result"]
        XCTAssertTrue(result.wait(for: \.rewriteText, toEqual: fixture.cleaned, timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "dictation.rewrite").firstMatch.exists)
        XCTAssertFalse(app.buttons["dictation.applyPreview"].exists)
        XCTAssertFalse(app.buttons["dictation.cancelTransform"].exists)

        selectVersion(fixture.originalID, in: app)
        XCTAssertTrue(result.wait(for: \.rewriteText, toEqual: fixture.original, timeout: 5))
        selectVersion(fixture.cleanedID, in: app)
        XCTAssertTrue(result.wait(for: \.rewriteText, toEqual: fixture.cleaned, timeout: 5))
        XCTAssertFalse(app.buttons["dictation.pause"].exists)
        XCTAssertFalse(app.buttons["dictation.finish"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(history.waitForExistence(timeout: 20))
        history.click()
        XCTAssertTrue(result.wait(for: \.rewriteText, toEqual: fixture.cleaned, timeout: 5))
        let snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.snapshotURL)) as? [String: Any]
        let session = try XCTUnwrap(snapshot?["session"] as? [String: Any])
        XCTAssertEqual((session["segments"] as? [Any])?.count, 0)
        XCTAssertEqual((session["intervals"] as? [Any])?.count, 0)
        let sources = try XCTUnwrap(session["transcripts"] as? [[String: Any]])
        XCTAssertEqual(sources.first?["rawText"] as? String, fixture.original)
        XCTAssertEqual(sources.first?["text"] as? String, fixture.original)
    }

    @MainActor
    private func selectVersion(_ id: String, in app: XCUIApplication) {
        let versions = app.descendants(matching: .any).matching(identifier: "dictation.versions").firstMatch
        XCTAssertTrue(versions.waitForExistence(timeout: 5))
        versions.click()
        let version = app.descendants(matching: .any).matching(identifier: "dictation.version." + id).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        version.click()
    }

    private struct Fixture {
        let takeID: String
        let originalID: String
        let cleanedID: String
        let original: String
        let cleaned: String
        let snapshotURL: URL
    }

    /// Edits only the app-created isolated fixture while the app is terminated.
    /// Increasing its durable revision uses normal SessionStore snapshot recovery.
    private func seedSavedVersions(in root: URL) throws -> Fixture {
        let sessions = root.appendingPathComponent("Sessions", isDirectory: true)
        let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: sessions,
            includingPropertiesForKeys: nil).first)
        let snapshotURL = directory.appendingPathComponent("session.json")
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any])
        var session = try XCTUnwrap(snapshot["session"] as? [String: Any])
        var brief = try XCTUnwrap(session["brief"] as? [String: Any])
        let revisionID = try XCTUnwrap(brief["revisionID"] as? String)
        let takeID = UUID().uuidString
        let sourceID = UUID().uuidString
        let originalID = UUID().uuidString
        let cleanedID = UUID().uuidString
        let original = "Um please send die Rechnung tomorrow. Keep 256, not 512."
        let cleaned = "Please send die Rechnung tomorrow. Keep 256, not 512."
        let now = Date().timeIntervalSinceReferenceDate
        let originalRevision: [String: Any] = [
            "id": originalID, "rawText": original, "text": original,
            "sourceTranscriptIDs": [sourceID], "createdAt": now
        ]
        let cleanedRevision: [String: Any] = [
            "id": cleanedID, "rawText": original, "text": cleaned,
            "sourceTranscriptIDs": [sourceID], "createdAt": now + 1
        ]
        brief["takes"] = [[
            "id": takeID, "intent": "addMaterial", "targetSection": "changes",
            "expectedRevision": revisionID, "selectedBlockIDs": [], "status": "pending",
            "transcriptIDs": [sourceID], "intervalIDs": [], "createdAt": now
        ]] as [[String: Any]]
        session["brief"] = brief
        session["title"] = "Saved rewrite fixture"
        session["status"] = "ready"
        session["updatedAt"] = now + 1
        session["transcripts"] = [[
            "id": sourceID, "rawText": original, "text": original, "origin": "imported",
            "segmentIDs": [], "startTime": 0, "endTime": 0, "timingPrecision": "unavailable",
            "isComplete": true, "createdAt": now
        ]] as [[String: Any]]
        session["dictation"] = [
            "schemaVersion": 1,
            "recordings": [[
                "id": takeID, "state": "ready", "languagePolicy": "mixedEnglishGerman",
                "outputMode": "clean", "textRevision": cleanedRevision, "createdAt": now,
                "updatedAt": now + 1, "activeOutputID": cleanedID,
                "outputHistory": [
                    ["id": originalID, "mode": "verbatim", "textRevision": originalRevision, "createdAt": now],
                    ["id": cleanedID, "mode": "clean", "textRevision": cleanedRevision,
                     "parentOutputID": originalID, "createdAt": now + 1]
                ]
            ]]
        ] as [String: Any]
        snapshot["session"] = session
        snapshot["revision"] = (snapshot["revision"] as? Int ?? 1) + 1
        try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]).write(to: snapshotURL, options: .atomic)
        return Fixture(takeID: takeID, originalID: originalID, cleanedID: cleanedID,
                       original: original, cleaned: cleaned, snapshotURL: snapshotURL)
    }
}
