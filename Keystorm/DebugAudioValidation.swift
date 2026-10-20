#if DEBUG
import AppKit
import AVFoundation
import Foundation

/// Opt-in, isolated file audio for manual desktop validation. Absent in release builds.
struct DebugAudioValidationConfiguration: Sendable {
    let root: URL
    let audio: URL
    let sha256: String

    private struct Manifest: Decodable {
        let version: Int
        let root: String
        let audio: String
        let sha256: String
    }

    private static let loaded: Result<DebugAudioValidationConfiguration?, any Error> = Result {
        let manifestURL = URL(fileURLWithPath: "/tmp/Keystorm-UI-audio-validation.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 16_384 else {
            throw KeystormError.message("The audio validation manifest is too large.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let root = URL(fileURLWithPath: manifest.root, isDirectory: true).standardizedFileURL
        let prefix = "Keystorm-UI-"
        let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        guard manifest.version == 1,
              root.deletingLastPathComponent().resolvingSymlinksInPath() == temporary,
              root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
              root.resolvingSymlinksInPath() == temporary.appendingPathComponent(root.lastPathComponent),
              manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw KeystormError.message("Invalid isolated audio validation configuration.")
        }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        let audio = URL(fileURLWithPath: manifest.audio).standardizedFileURL.resolvingSymlinksInPath()
        let values = try audio.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard rootValues.isDirectory == true,
              audio.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= 32 * 1_024 * 1_024,
              try CaptureDurability.sha256(audio) == manifest.sha256 else {
            throw KeystormError.message("The isolated audio validation fixture is invalid or changed.")
        }
        return DebugAudioValidationConfiguration(root: root, audio: audio, sha256: manifest.sha256)
    }

    static func configuration() throws -> DebugAudioValidationConfiguration? { try loaded.get() }

    func validateCaptureDirectory(_ directory: URL) throws {
        guard directory.standardizedFileURL.resolvingSymlinksInPath().path
            .hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              try CaptureDurability.sha256(audio) == sha256 else {
            throw KeystormError.message("File audio validation requires its isolated store and unchanged fixture.")
        }
    }

    func log(_ event: String, fields: [String: Any] = [:]) {
        var object = fields
        object["event"] = event
        object["time"] = Date().formatted(.iso8601)
        object["processID"] = ProcessInfo.processInfo.processIdentifier
        object["sourceFile"] = audio.lastPathComponent
        object["sourceSHA256"] = sha256
        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0A)
            let url = root.appendingPathComponent("audio-validation-events.jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .withoutOverwriting)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.synchronize()
            }
        } catch {
            NSLog("Audio validation event could not be saved: %@", error.localizedDescription)
        }
    }

    func logPermissions() {
        log("app-start", fields: [
            "accessibilityTrusted": AXIsProcessTrusted(),
            "postEventAccess": CGPreflightPostEventAccess()
        ])
    }
}
#endif
