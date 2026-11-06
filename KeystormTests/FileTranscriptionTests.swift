import AppKit
import Foundation
import Testing
@testable import Keystorm

@MainActor
struct FileTranscriptionTests {
    @Test("Without the speech model a file is refused with a clear message and nothing is saved")
    func refusedWithoutModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-FileTranscription-" + UUID().uuidString)
        let models = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-NoModels-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: models) }
        let model = WorkspaceModel(root: root, modelDirectory: models)
        await model.initialize()
        let file = root.appendingPathComponent("note.txt")
        try "not audio".write(to: file, atomically: true, encoding: .utf8)
        let before = model.sessions.count
        await #expect(throws: KeystormError.self) { _ = try await model.transcribeMediaFile(file) }
        #expect(model.sessions.count == before)
        await model.stopForTermination()
    }

    @Test("The coordinator reports a refused file as a failure the user can read, and stays usable")
    func coordinatorReportsRefusal() async throws {
        let flow = DictationCoordinator(backend: RefusingBackend(),
            delivery: DictationDeliveryService(adapter: RefusingAdapter()))
        flow.pasteboard = NSPasteboard.withUniqueName()
        flow.transcribeFile(URL(fileURLWithPath: "/nonexistent/example.m4a"))
        #expect(flow.state == .processing)
        await flow.waitUntilSettled()
        #expect(flow.state == .failed)
        #expect(flow.message.contains("cannot transcribe"))
        flow.newDraft()
        #expect(flow.state == .idle)
    }

    /// Real models, a real file. Point `KEYSTORM_FILE_TRANSCRIPTION_PATH` at any audio or video file, and optionally
    /// `KEYSTORM_FILE_TRANSCRIPTION_REFERENCE` at a text file with what is said, to score it.
    @Test("An installed-model transcription of a real audio or video file completes and persists",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_FILE_TRANSCRIPTION"] == "1"),
          .exclusiveModelUse,
          .timeLimit(.minutes(20)))
    func installedModelTranscribesFile() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["KEYSTORM_FILE_TRANSCRIPTION_PATH"],
            "Set KEYSTORM_FILE_TRANSCRIPTION_PATH to an audio or video file.")
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-FileTranscription-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(root: root, modelDirectory: models)
        await model.initialize()
        try #require(model.installedModelIDs.contains(ModelCatalog.primarySpeech.id))
        let started = ContinuousClock.now
        let handle = try await model.transcribeMediaFile(URL(fileURLWithPath: path))
        let elapsed = started.duration(to: .now).components
        let metadata = try #require(model.dictationMetadata(handle))
        #expect(metadata.state == .ready)
        #expect(metadata.purpose == .longRecording)
        let text = try #require(metadata.textRevision?.text)
        #expect(!text.isEmpty)
        print("FILE_TRANSCRIPTION seconds=\(Double(elapsed.seconds)) words=\(text.split(separator: " ").count)")
        if let referencePath = ProcessInfo.processInfo.environment["KEYSTORM_FILE_TRANSCRIPTION_REFERENCE"] {
            try text.write(toFile: referencePath + ".hypothesis.txt", atomically: true, encoding: .utf8)
            if let session = model.sessions.first(where: { $0.id == handle.sessionID }) {
                let rows = session.currentTranscripts.sorted { $0.startTime < $1.startTime }.map {
                    ["start": $0.startTime, "end": $0.endTime, "complete": $0.isComplete, "text": $0.text] as [String: Any]
                }
                try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
                    .write(to: URL(fileURLWithPath: referencePath + ".windows.json"))
            }
        }
        await model.stopForTermination()
    }
}

@MainActor
private final class RefusingBackend: DictationRecordingBackend {
    func dictationBegin() async throws -> DictationRecordingHandle { throw KeystormError.message("unused") }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {}
    func dictationResume(_ handle: DictationRecordingHandle) async throws {}
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision { throw KeystormError.message("unused") }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? { nil }
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode) async throws -> DictationTransformResult { throw KeystormError.message("unused") }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {}
}

@MainActor
private struct RefusingAdapter: DictationDeliveryAdapter {
    var isTrusted: Bool { false }
    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { nil }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField { throw KeystormError.message("unused") }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { false }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata { throw KeystormError.message("unused") }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot { throw KeystormError.message("unused") }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment { .rejected }
}
