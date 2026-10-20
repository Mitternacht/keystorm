import Foundation
import Testing
@testable import Keystorm

/// Actual installed-model and durable-store integration. The seeded source is explicitly
/// imported test text: this does not substitute a transcript for an audio/ASR acceptance test.
@MainActor
@Suite(.serialized)
struct DictationTransformIntegrationTests {
    @Test("Installed Qwen previews, explicitly applies, and restores a persisted original through the workspace",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_DICTATION_TRANSFORM_INTEGRATION"] == "1"),
          .timeLimit(.minutes(10)))
    func actualLocalPreviewApplyReopenAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-TransformIntegration-Store-\(UUID().uuidString)", isDirectory: true)
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let sourceText = "please send die Rechnung to Müller not today and keep 42 Dateien local"
        let imported = TranscriptRevision(rawText: sourceText, text: sourceText, origin: .imported,
            timingPrecision: .unavailable)
        let source = DictationTextRevision(rawText: sourceText, text: sourceText, sourceTranscriptIDs: [imported.id])
        var brief = BriefDocument()
        let take = BriefTake(expectedRevision: brief.revisionID, status: .pending, transcriptIDs: [imported.id])
        brief.takes = [take]
        var seed = VoiceSession()
        seed.title = "Imported bilingual transform integration fixture"
        seed.brief = brief
        seed.transcripts = [imported]
        seed.dictation = DictationSession(recordings: [
            DictationRecordingMetadata(id: take.id, state: .ready, textRevision: source)
        ])
        let handle = DictationRecordingHandle(sessionID: seed.id, takeID: take.id)
        let adapter = TransformIntegrationAdapter()
        var workspaces: [WorkspaceModel] = []
        var coordinators: [DictationCoordinator] = []
        var report = TransformIntegrationReport(source: source, importedTranscript: imported,
            recordingID: take.id, sessionID: seed.id)
        do {
            let store = try SessionStore(root: root)
            try await store.save(seed)
            let workspace = WorkspaceModel(root: root, modelDirectory: models)
            workspaces.append(workspace)
            await workspace.initialize(loadLibrary: true)
            try #require(workspace.error == nil, "\(workspace.error ?? "")")
            try #require(workspace.installedModelIDs.contains(ModelCatalog.primaryText.id),
                "Install the pinned Qwen model explicitly before this opt-in test; no model is downloaded.")
            let coordinator = makeCoordinator(workspace, adapter: adapter)
            coordinators.append(coordinator)
            coordinator.restore(handle)
            #expect(coordinator.state == .ready)
            #expect(coordinator.resultText == source.text)
            #expect(coordinator.outputVersions.isEmpty)
            #expect(!workspace.isRecording)
            let previewStarted = ContinuousClock.now
            coordinator.prepareTransform(.clean)
            #expect(coordinator.state == .ready)
            #expect(coordinator.isTransforming)
            #expect(coordinator.isTransitioning)
            #expect(coordinator.reservesCapture)
            await coordinator.waitUntilSettled()
            report.previewMilliseconds = milliseconds(previewStarted.duration(to: .now))
            report.coordinatorMessage = coordinator.message
            let preview = try #require(coordinator.transformPreview,
                "Actual local preview failed: \(coordinator.message); workspace: \(workspace.error ?? "")")
            report.preview = preview
            try #require(preview.generatedTokens > 0, "The preview must come from actual local generation.")
            #expect(preview.mode == .clean)
            #expect(preview.sourceRevisionID == source.id)
            #expect(preview.sourceSHA256 == DictationTransformPolicy.sourceDigest(source.text))
            #expect(preview.promptTemplateVersion == DictationTransformPolicy.templateVersion)
            #expect(preview.promptTemplateSHA256 == DictationTransformPolicy.promptTemplateSHA256(for: .clean))
            #expect(preview.text != source.text)
            let last = preview.text.trimmingCharacters(in: .whitespacesAndNewlines).last
            #expect(last.map { ".!?".contains($0) } == true,
                "The unpunctuated fixture requires a generated sentence ending.")
            for anchor in ["Rechnung", "Müller", "not", "42", "Dateien"] {
                #expect(preview.text.localizedCaseInsensitiveContains(anchor))
            }
            let generatedSession = try snapshot(workspace, sessionID: seed.id)
            let configuration = try #require(generatedSession.configurations.first { $0.id == preview.configurationID })
            report.configuration = configuration
            #expect(configuration.modelID == ModelCatalog.primaryText.id)
            #expect(configuration.revision == ModelCatalog.primaryText.revision)
            #expect(!configuration.thinking)
            #expect(!configuration.artifactHashes.isEmpty)
            let request = DictationTransformRequest(jobID: preview.jobID, sourceRevisionID: source.id,
                sourceSHA256: DictationTransformPolicy.sourceDigest(source.text), mode: .clean,
                sourceText: source.text, configuration: configuration)
            try DictationTransformPolicy.validate(preview, request: request)
            #expect(workspace.dictationMetadata(handle)?.textRevision == source)
            #expect(workspace.dictationMetadata(handle)?.outputHistory == nil)
            #expect(coordinator.resultText == source.text)
            #expect(coordinator.state == .ready)
            #expect(!coordinator.isTransforming)
            expectNoExternalActivity(adapter)

            // Applying is a separate user action after the actual preview completed.
            coordinator.applyTransformPreview()
            await coordinator.waitUntilSettled()
            report.coordinatorMessage = coordinator.message
            let applied = try #require(workspace.dictationMetadata(handle))
            report.applied = applied
            let appliedRevision = try #require(applied.textRevision)
            let history = try #require(applied.outputHistory)
            let original = try #require(history.first { $0.mode == .verbatim && $0.textRevision == source })
            let transformed = try #require(history.first { $0.id == preview.jobID })
            #expect(history.count == 2)
            #expect(appliedRevision.text == preview.text)
            #expect(appliedRevision.rawText == source.rawText)
            #expect(appliedRevision.sourceTranscriptIDs == source.sourceTranscriptIDs)
            #expect(applied.activeOutputID == transformed.id)
            #expect(transformed.sourceRevisionID == source.id)
            #expect(transformed.configurationID == configuration.id)
            #expect(transformed.promptTemplateSHA256 == preview.promptTemplateSHA256)
            #expect(coordinator.transformPreview == nil)
            #expect(coordinator.outputVersions == history)
            try applied.validateOutputHistory()
            expectNoExternalActivity(adapter)
            coordinator.cancelForShutdown()
            await workspace.stopForTermination()
            await coordinator.waitUntilSettled()

            // A new workspace constructs a new SessionStore and reads the persisted result.
            let reopened = WorkspaceModel(root: root, modelDirectory: models)
            workspaces.append(reopened)
            await reopened.initialize(loadLibrary: true)
            try #require(reopened.error == nil, "\(reopened.error ?? "")")
            let afterReopen = try #require(reopened.dictationMetadata(handle))
            report.reopenedApplied = afterReopen
            #expect(afterReopen == applied)
            #expect(afterReopen.outputHistory == history)
            #expect(afterReopen.textRevision == appliedRevision)
            #expect(afterReopen.activeOutputID == transformed.id)
            let restoredCoordinator = makeCoordinator(reopened, adapter: adapter)
            coordinators.append(restoredCoordinator)
            restoredCoordinator.restore(handle)
            #expect(restoredCoordinator.resultText == preview.text)
            #expect(restoredCoordinator.outputVersions == history)
            restoredCoordinator.selectOutput(original.id)
            await restoredCoordinator.waitUntilSettled()
            let selected = try #require(reopened.dictationMetadata(handle))
            report.restoredOriginal = selected
            #expect(selected.textRevision == source)
            #expect(selected.activeOutputID == original.id)
            #expect(selected.outputMode == .verbatim)
            #expect(selected.outputHistory == history)
            #expect(restoredCoordinator.resultText == source.text)
            #expect(restoredCoordinator.activeOutputID == original.id)
            try selected.validateOutputHistory()
            restoredCoordinator.cancelForShutdown()
            await reopened.stopForTermination()
            await restoredCoordinator.waitUntilSettled()

            let finalWorkspace = WorkspaceModel(root: root, modelDirectory: models)
            workspaces.append(finalWorkspace)
            await finalWorkspace.initialize(loadLibrary: true)
            try #require(finalWorkspace.error == nil, "\(finalWorkspace.error ?? "")")
            let finalMetadata = try #require(finalWorkspace.dictationMetadata(handle))
            let finalSession = try snapshot(finalWorkspace, sessionID: seed.id)
            report.reopenedOriginal = finalMetadata
            #expect(finalMetadata == selected)
            #expect(finalMetadata.textRevision == source)
            #expect(finalMetadata.outputHistory == history)
            #expect(finalMetadata.activeOutputID == original.id)
            #expect(finalSession.transcripts == [imported])
            #expect(finalSession.brief?.takes == seed.brief?.takes)
            #expect(finalSession.segments.isEmpty)
            #expect(finalSession.intervals.isEmpty)
            #expect(!finalWorkspace.isRecording)
            #expect(!finalWorkspace.hasOpenTake)
            try finalSession.validateDictationMetadata()
            await finalWorkspace.stopForTermination()
            expectNoExternalActivity(adapter)
            report.coordinatorMessage = restoredCoordinator.message
            try persist(report)
            try FileManager.default.removeItem(at: root)
        } catch {
            report.failure = error.localizedDescription
            report.coordinatorMessage = coordinators.last?.message
            try? persist(report)
            // Cancel capabilities first, then drain capture/worker, then join every editor.
            coordinators.forEach { $0.cancelForShutdown() }
            for workspace in workspaces { await workspace.stopForTermination() }
            for coordinator in coordinators { await coordinator.waitUntilSettled() }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func makeCoordinator(_ workspace: WorkspaceModel, adapter: TransformIntegrationAdapter) -> DictationCoordinator {
        DictationCoordinator(backend: workspace, delivery: DictationDeliveryService(adapter: adapter,
            ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999))
    }

    private func snapshot(_ workspace: WorkspaceModel, sessionID: UUID) throws -> VoiceSession {
        try #require(workspace.sessions.first { $0.id == sessionID })
    }

    private func expectNoExternalActivity(_ adapter: TransformIntegrationAdapter) {
        #expect(adapter.trustReads == 0)
        #expect(adapter.applicationReads == 0)
        #expect(adapter.fieldReads == 0)
        #expect(adapter.writeCount == 0)
        #expect(adapter.permissionRequests == 0)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1_000_000_000_000_000
    }

    private func persist(_ report: TransformIntegrationReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        Attachment.record(data, named: "dictation-transform-workspace-integration.json")
        let parent = ProcessInfo.processInfo.environment["KEYSTORM_DICTATION_TRANSFORM_REPORT_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-TransformIntegrationReports", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = parent.appendingPathComponent("\(report.runID.uuidString).json")
        try data.write(to: url, options: .atomic)
        print("DICTATION_TRANSFORM_INTEGRATION_REPORT \(url.path)")
    }
}

private struct TransformIntegrationReport: Encodable {
    let purpose = "Actual installed Qwen through production WorkspaceModel and DictationCoordinator with explicit Apply, durable store reopen, Original selection and another reopen. Imported synthetic text only; no microphone, ASR or cross-app insertion claim."
    let runID = UUID()
    let source: DictationTextRevision
    let importedTranscript: TranscriptRevision
    let recordingID: UUID
    let sessionID: UUID
    var preview: DictationTransformResult?
    var configuration: ProcessingConfiguration?
    var previewMilliseconds: Double?
    var applied: DictationRecordingMetadata?
    var reopenedApplied: DictationRecordingMetadata?
    var restoredOriginal: DictationRecordingMetadata?
    var reopenedOriginal: DictationRecordingMetadata?
    var coordinatorMessage: String?
    var failure: String?
}

@MainActor
private final class TransformIntegrationField: DictationDeliveryField {}

@MainActor
private final class TransformIntegrationAdapter: DictationDeliveryAdapter {
    var trustReads = 0
    var isTrusted: Bool { trustReads += 1; return false }
    var applicationReads = 0
    var fieldReads = 0
    var writeCount = 0
    var permissionRequests = 0
    func requestPermission() { permissionRequests += 1 }
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { applicationReads += 1; return nil }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField {
        fieldReads += 1
        return TransformIntegrationField()
    }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { lhs === rhs }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        DictationFieldMetadata(processIdentifier: 42, role: "AXTextArea", subrole: nil,
            isEnabled: true, isProtected: false, selectedTextIsSettable: true)
    }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        DictationFieldSnapshot(text: "untouched", selection: NSRange(location: 0, length: 0))
    }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        writeCount += 1
        return .rejected
    }
}
