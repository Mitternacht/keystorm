import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Keystorm

@MainActor
struct ExternalCorrectionNativeTests {
    @Test("Opt-in: production TextEdit observer sees a disposable destination correction",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_EXTERNAL_CORRECTIONS"] == "1"))
    func nativeTextEditCorrectionObservation() async throws {
        let service = DictationDeliveryService()
        defer { service.stopCorrectionObservation() }
        guard service.isAccessibilityTrusted else {
            try Test.cancel("Native external correction was not run: this test host lacks existing Accessibility trust. No prompt was requested.")
        }
        guard CGPreflightPostEventAccess() else {
            try Test.cancel("Native external correction was not run: this test host cannot post events. No prompt was requested.")
        }

        let nonce = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-External-Correction-" + nonce)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixtureURL = folder.appendingPathComponent("External-correction-" + nonce + ".txt")
        let prefix = "Keystorm fixture " + nonce + " 👩🏽‍💻. "
        let suffix = " Ende."
        let original = "The Kubernettes deployment ist bereit in München."
        let corrected = "The Kubernetes deployment ist bereit in München."
        try (prefix + suffix).write(to: fixtureURL, atomically: true, encoding: .utf8)

        let existingPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").map(\.processIdentifier))
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        let appURL = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit"))
        let application = try await NSWorkspace.shared.open([fixtureURL], withApplicationAt: appURL, configuration: configuration)
        // A reused process may contain personal documents. Never mutate or terminate it.
        try #require(!existingPIDs.contains(application.processIdentifier), "A dedicated disposable TextEdit process is required.")
        defer {
            service.stopCorrectionObservation()
            _ = application.forceTerminate()
            _ = previousApplication?.activate(options: [])
        }

        var ownEditor: AXUIElement?
        for _ in 0..<30 {
            _ = application.activate(options: [])
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
               let candidate = try? focusedField(pid: application.processIdentifier),
               (try? string(kAXValueAttribute, of: candidate))?.utf8.elementsEqual((prefix + suffix).utf8) == true {
                ownEditor = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let editor = try #require(ownEditor, "The nonce-marked fixture did not become the focused TextEdit field.")
        try setCaret(prefix.utf16.count, in: editor)
        let target: DictationCapturedTarget
        switch service.captureTarget() {
        case .ready(let captured): target = captured
        case .unavailable(let failure):
            Issue.record("The native fixture could not be captured: \(failure.message)")
            return
        }
        let clipboardBefore = clipboardSnapshot()
        let deliveryID = UUID()
        let receipt = await service.deliver(original, to: target, deliveryID: deliveryID)
        try #require(receipt.outcome == .confirmed)
        #expect(clipboardBefore == clipboardSnapshot(), "Production delivery must restore all original clipboard representations.")
        try #require(try string(kAXValueAttribute, of: editor).utf8.elementsEqual((prefix + original + suffix).utf8))

        let observations = NativeExternalObservationBox()
        try #require(service.startCorrectionObservation(to: target, deliveredText: original, deliveryID: deliveryID,
            isEnabled: { true }, onObservation: { observations.values.append($0) }),
            "The qualified TextEdit field must support the required native AX notifications.")

        // This explicitly simulates an external edit. It does not prove human
        // authorship, keyboard input, ASR quality, or automatic learning safety.
        try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier)
        let stillFocused = try focusedField(pid: application.processIdentifier)
        try #require(CFEqual(stillFocused, editor))
        try #require(try string(kAXValueAttribute, of: editor).utf8.elementsEqual((prefix + original + suffix).utf8))
        try #require(AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString,
            (prefix + corrected + suffix) as CFString) == .success, "Only the disposable exact-match editor may be changed.")
        try setCaret(prefix.utf16.count + corrected.utf16.count, in: editor)

        for _ in 0..<60 {
            if !observations.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let observation = try #require(observations.values.first, "No native value-change callback produced an observation within three seconds.")
        #expect(observations.values.count == 1)
        #expect(observation.originalText == original)
        #expect(observation.correctedText == corrected)
        #expect(observation.destination.bundleIdentifier == "com.apple.TextEdit")
        #expect(observation.destination.processIdentifier == application.processIdentifier)
        #expect(observation.deliveryID == deliveryID)
        #expect(!service.hasActiveCorrectionObservation)
        try await Task.sleep(for: .milliseconds(150))
        #expect(observations.values.count == 1)

        let report = NativeExternalObservationReport(delivery: receipt.outcome.rawValue, observationCount: observations.values.count,
            originalText: observation.originalText, correctedText: observation.correctedText,
            authorship: "unverified external observation from a programmatic fixture edit",
            microphoneAndASRTested: false, automaticActivationTested: false,
            clipboardRestored: clipboardBefore == clipboardSnapshot(), observerStopped: !service.hasActiveCorrectionObservation)
        Attachment.record(try JSONEncoder().encode(report), named: "native-external-correction-observation.json")
        print("Native external-correction evidence: confirmed insertion, one observed EN/DE passage, programmatic fixture edit; authorship remains unverified.")
    }

    private func focusedField(pid: Int32) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { throw NativeExternalObservationError.unavailable }
        let element = unsafeBitCast(result, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    private func string(_ attribute: String, of element: AXUIElement) throws -> String {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success,
              let value = result as? String else { throw NativeExternalObservationError.unavailable }
        return value
    }

    private func setCaret(_ location: Int, in element: AXUIElement) throws {
        var range = CFRange(location: location, length: 0)
        let value = try #require(AXValueCreate(.cfRange, &range))
        try #require(AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success)
    }

    private func clipboardSnapshot() -> [[String: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        }
    }
}

private enum NativeExternalObservationError: Error { case unavailable }

@MainActor
private final class NativeExternalObservationBox {
    var values: [ExternalCorrectionObservation] = []
}

private struct NativeExternalObservationReport: Codable {
    let delivery: String
    let observationCount: Int
    let originalText: String
    let correctedText: String
    let authorship: String
    let microphoneAndASRTested: Bool
    let automaticActivationTested: Bool
    let clipboardRestored: Bool
    let observerStopped: Bool
}
