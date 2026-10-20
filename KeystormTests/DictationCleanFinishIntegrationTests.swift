import Foundation
import Testing
@testable import Keystorm

@MainActor
@Suite(.serialized)
struct DictationCleanFinishIntegrationTests {
    /// Synthetic source text is injected at the speech boundary. The Qwen worker,
    /// WorkspaceModel transformation/history, SessionStore and Finish delivery state
    /// machine are production implementations. The external field is a memory adapter.
    /// This test makes no microphone, ASR accuracy or real Accessibility claim.
    @Test("Installed Qwen Clean Finish persists the original and delivers only its committed output",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_CLEAN_FINISH"] == "1"),
          .timeLimit(.minutes(5)))
    func installedQwenCleanFinishAndReopen() async throws {
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let fixtures = [
            ("english-base", "please keep die Rechnung local not today and keep 42 Dateien"),
            ("german-base", "äh bitte send the invoice an Müller nicht heute und behalte 42 Dateien lokal")
        ]
        var evidence: [CleanFinishIntegrationEvidence] = []
        for (name, text) in fixtures {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Keystorm-CleanFinish-\(UUID().uuidString)", isDirectory: true)
            let store = try SessionStore(root: root)
            let transcript = TranscriptRevision(rawText: text, text: text, origin: .imported)
            let source = DictationTextRevision(rawText: text, text: text, sourceTranscriptIDs: [transcript.id])
            var seed = VoiceSession()
            seed.title = "Synthetic \(name) Clean Finish fixture"
            seed.transcripts = [transcript]
            var brief = BriefDocument()
            brief.takes = [BriefTake(expectedRevision: brief.revisionID, status: .pending, transcriptIDs: [transcript.id])]
            seed.brief = brief
            let takeID = try #require(brief.takes.first?.id)
            var metadata = DictationRecordingMetadata(id: takeID, state: .captured)
            metadata.captureMode = .clean
            seed.dictation = DictationSession(recordings: [metadata])
            try await store.save(seed)
            let handle = DictationRecordingHandle(sessionID: seed.id, takeID: takeID)
            let model = WorkspaceModel(root: root, modelDirectory: models)
            var recovered: WorkspaceModel?
            do {
                await model.initialize(loadLibrary: true)
                try #require(model.error == nil, "\(model.error ?? "")")
                try #require(model.installedModelIDs.contains(ModelCatalog.primaryText.id),
                    "Install the pinned Qwen model explicitly before this opt-in test; no download is performed.")
                let trace = CleanFinishTrace()
                let adapter = CleanFinishAdapter(trace: trace)
                let backend = ProductionCleanFinishBackend(model: model, handle: handle, source: source)
                let preferences = DictationPreferences()
                preferences.mode = .clean
                let coordinator = DictationCoordinator(backend: backend,
                    delivery: DictationDeliveryService(adapter: adapter,
                        ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999),
                    preferences: preferences)
                coordinator.toggle()
                await coordinator.waitUntilSettled()
                try #require(coordinator.state == .recording)
                let start = ContinuousClock.now
                coordinator.finish()
                await coordinator.waitUntilSettled()
                let elapsed = start.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
                #expect(coordinator.state == .ready)
                let saved = try #require(model.dictationMetadata(handle))
                let output = try #require(saved.textRevision)
                let history = try #require(saved.outputHistory)
                #expect(saved.captureMode == .clean)
                #expect(saved.outputMode == .clean)
                #expect(saved.activeOutputID == output.id)
                #expect(saved.delivery?.state == .inserted)
                #expect(history.count == 2)
                #expect(history.first?.textRevision == source)
                #expect(history.last?.textRevision == output)
                #expect(output.rawText.utf8.elementsEqual(text.utf8))
                #expect(output.sourceTranscriptIDs == [transcript.id])
                #expect(adapter.writes == [output.text])
                #expect(output.text.last.map { ".!?".contains($0) } == true)
                try DictationTransformPolicy.validateText(output.text, source: source.text, mode: .clean)
                let transform = try #require(backend.result)
                #expect(transform.generatedTokens > 0)
                #expect(transform.sourceRevisionID == source.id)
                #expect(transform.sourceSHA256 == DictationTransformPolicy.sourceDigest(source.text))
                let session = try #require(model.sessions.first(where: { $0.id == handle.sessionID }))
                let configuration = try #require(session.configurations.first(where: { $0.id == transform.configurationID }))
                #expect(configuration.modelID == ModelCatalog.primaryText.id)
                #expect(configuration.revision == ModelCatalog.primaryText.revision)
                #expect(configuration.thinking == false)
                coordinator.finish()
                await coordinator.waitUntilSettled()
                #expect(adapter.writes == [output.text])
                await model.stopForTermination()

                let reopened = WorkspaceModel(root: root, modelDirectory: models)
                recovered = reopened
                await reopened.initialize(loadLibrary: true)
                try #require(reopened.error == nil, "\(reopened.error ?? "")")
                #expect(reopened.dictationMetadata(handle) == saved)
                let restored = DictationCoordinator(backend: reopened,
                    delivery: DictationDeliveryService(adapter: adapter,
                        ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999),
                    preferences: preferences)
                restored.restore(handle)
                #expect(restored.state == .ready)
                #expect(restored.resultText.utf8.elementsEqual(output.text.utf8))
                #expect(restored.destinationLabel == "Copy after recording")
                #expect(adapter.writes == [output.text])
                await reopened.stopForTermination()
                evidence.append(CleanFinishIntegrationEvidence(fixture: name, source: source,
                    output: output, transform: transform, configuration: configuration,
                    delivery: saved.delivery, history: history, elapsedMilliseconds: milliseconds,
                    externalWriteCount: adapter.writes.count, reopenedExactly: reopened.dictationMetadata(handle) == saved))
                try FileManager.default.removeItem(at: root)
            } catch {
                await model.stopForTermination()
                await recovered?.stopForTermination()
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        Attachment.record(try encoder.encode(evidence), named: "clean-finish-installed-qwen.json")
    }
}

@MainActor
private final class ProductionCleanFinishBackend: DictationRecordingBackend {
    let model: WorkspaceModel
    let handle: DictationRecordingHandle
    let source: DictationTextRevision
    var result: DictationTransformResult?
    init(model: WorkspaceModel, handle: DictationRecordingHandle, source: DictationTextRevision) {
        self.model = model
        self.handle = handle
        self.source = source
    }
    func dictationBegin(mode: DictationQuickMode) async throws -> DictationRecordingHandle {
        guard mode == .clean else { throw DictationTransformError.invalidRequest }
        return try await dictationBegin()
    }
    func dictationBegin() async throws -> DictationRecordingHandle {
        // Imported text stands in for captured speech; never request microphone access.
        try await model.dictationSave(handle, state: .recording, revision: nil, delivery: nil, failure: nil)
        return handle
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws { throw DictationTransformError.invalidRequest }
    func dictationResume(_ handle: DictationRecordingHandle) async throws { throw DictationTransformError.invalidRequest }
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        try await model.dictationSave(handle, state: .ready, revision: source, delivery: nil, failure: nil)
        return source
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? {
        model.dictationMetadata(handle)
    }
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode) async throws -> DictationTransformResult {
        let generated = try await model.dictationTransform(handle, source: source, mode: mode)
        result = generated
        return generated
    }
    func dictationApplyTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                 result: DictationTransformResult) async throws -> DictationRecordingMetadata {
        try await model.dictationApplyTransform(handle, source: source, result: result)
    }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        try await model.dictationSave(handle, state: state, revision: revision, delivery: delivery, failure: failure)
    }
}

private struct CleanFinishIntegrationEvidence: Encodable {
    let purpose = "Synthetic source text through actual installed Qwen and production transformation/history/storage/coordinator delivery, using a memory field adapter. No microphone, ASR accuracy or live Accessibility qualification."
    let fixture: String
    let source: DictationTextRevision
    let output: DictationTextRevision
    let transform: DictationTransformResult
    let configuration: ProcessingConfiguration
    let delivery: DictationDelivery?
    let history: [DictationOutputRevision]
    let elapsedMilliseconds: Double
    let externalWriteCount: Int
    let reopenedExactly: Bool
}
