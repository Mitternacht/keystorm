import Foundation
import Testing
@testable import Keystorm

@MainActor
@Suite(.serialized)
struct DictationTransformCoordinatorTests {
    @Test("A byte-only Unicode edit creates and saves a new source revision")
    func normalizationOnlyEditIsSaved() async throws {
        let rig = TransformCoordinatorRig()
        let source = try #require(rig.backend.metadata.textRevision)
        let edited = source.text.replacingOccurrences(of: "Müller", with: "Mu\u{0308}ller")
        #expect(edited == source.text)
        #expect(!edited.utf8.elementsEqual(source.text.utf8))
        rig.coordinator.resultText = edited
        await rig.coordinator.waitUntilSettled()
        let saved = try #require(rig.backend.metadata.textRevision)
        #expect(saved.id != source.id)
        #expect(saved.text.utf8.elementsEqual(edited.utf8))
        #expect(saved.rawText.utf8.elementsEqual(source.rawText.utf8))
        rig.coordinator.restore(rig.backend.recording)
        #expect(rig.coordinator.resultText.utf8.elementsEqual(edited.utf8))
    }

    @Test("Applying after a transient save failure retires the older pending edit")
    func applyAfterSaveFailureSurvivesRestore() async throws {
        let rig = TransformCoordinatorRig()
        rig.backend.failNextSaveAfterMutation = true
        rig.coordinator.resultText = "äh bitte send die Rechnung to Müller, not today and keep 42 Dateien local"
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.failedSaveCount == 1)
        rig.coordinator.prepareTransform(.clean)
        await rig.coordinator.waitUntilSettled()
        let preview = try #require(rig.coordinator.transformPreview)
        rig.coordinator.applyTransformPreview()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.metadata.activeOutputID == preview.jobID)
        #expect(rig.coordinator.resultText.utf8.elementsEqual(preview.text.utf8))
        rig.coordinator.newDraft()
        rig.coordinator.restore(rig.backend.recording)
        #expect(rig.coordinator.resultText.utf8.elementsEqual(preview.text.utf8))
        #expect(rig.coordinator.activeOutputID == preview.jobID)
    }

    @Test("Selecting a saved version after a transient save failure retires the pending edit")
    func selectAfterSaveFailureSurvivesRestore() async throws {
        let rig = TransformCoordinatorRig()
        let original = try #require(rig.backend.metadata.textRevision)
        rig.coordinator.prepareTransform(.clean)
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.applyTransformPreview()
        await rig.coordinator.waitUntilSettled()
        try #require(rig.backend.metadata.outputHistory?.contains(where: { $0.id == original.id }) == true)
        let edit = "A manual correction after the saved rewrite."
        rig.backend.failNextSaveAfterMutation = true
        rig.coordinator.resultText = edit
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.failedSaveCount == 1)
        rig.coordinator.selectOutput(original.id)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.metadata.textRevision == original)
        #expect(rig.backend.metadata.outputHistory?.contains(where: { $0.textRevision.text == edit }) == true)
        rig.coordinator.newDraft()
        rig.coordinator.restore(rig.backend.recording)
        #expect(rig.coordinator.resultText.utf8.elementsEqual(original.text.utf8))
        #expect(rig.coordinator.activeOutputID == original.id)
    }

    @Test("Generation stages a preview while the saved transcript and capture stay unchanged")
    func generationOnlyStagesPreview() async throws {
        let rig = TransformCoordinatorRig()
        let original = rig.backend.metadata
        rig.backend.suspendGeneration = true
        rig.coordinator.prepareTransform(.clean)
        #expect(rig.coordinator.state == .ready)
        #expect(rig.coordinator.isTransforming)
        #expect(rig.coordinator.isTransitioning)
        #expect(rig.coordinator.reservesCapture)
        #expect(rig.coordinator.canCancelTransform)
        await rig.backend.waitForGeneration()
        rig.coordinator.toggle()
        rig.coordinator.newDraft()
        rig.coordinator.selectOutput(UUID())
        #expect(rig.backend.beginCount == 0)
        #expect(rig.backend.applyCount == 0)
        #expect(rig.backend.selectCount == 0)
        #expect(rig.coordinator.resultText == original.textRevision?.text)
        #expect(rig.backend.metadata == original)
        rig.backend.releaseGeneration()
        await rig.coordinator.waitUntilSettled()
        let preview = try #require(rig.coordinator.transformPreview)
        #expect(preview.text == rig.backend.cleanOutput)
        #expect(preview.sourceRevisionID == original.textRevision?.id)
        let sourceText = try #require(original.textRevision?.text)
        #expect(preview.sourceSHA256 == DictationTransformPolicy.sourceDigest(sourceText))
        #expect(rig.coordinator.resultText == original.textRevision?.text)
        #expect(rig.backend.metadata == original)
        #expect(rig.backend.saveCount == 0)
        #expect(!rig.coordinator.isTransforming)
        #expect(!rig.coordinator.isTransitioning)
        #expect(!rig.coordinator.reservesCapture)
        #expect(rig.coordinator.state == .ready)
        expectNoExternalActivity(rig)
    }

    @Test("Only explicit Apply saves a transformation and preserves original history and sources")
    func explicitApplyPreservesOriginalAndHistory() async throws {
        let rig = TransformCoordinatorRig()
        let source = try #require(rig.backend.metadata.textRevision)
        rig.coordinator.prepareTransform(.clean)
        await rig.coordinator.waitUntilSettled()
        let preview = try #require(rig.coordinator.transformPreview)
        #expect(rig.backend.metadata.textRevision == source)
        #expect(rig.backend.applyCount == 0)
        rig.coordinator.applyTransformPreview()
        #expect(rig.coordinator.isTransforming)
        #expect(!rig.coordinator.canCancelTransform)
        rig.coordinator.cancelTransform()
        await rig.coordinator.waitUntilSettled()
        let saved = try #require(rig.backend.metadata.textRevision)
        let history = try #require(rig.backend.metadata.outputHistory)
        #expect(rig.backend.applyCount == 1)
        #expect(rig.coordinator.transformPreview == nil)
        #expect(saved.text == preview.text)
        #expect(saved.rawText == source.rawText)
        #expect(saved.sourceTranscriptIDs == source.sourceTranscriptIDs)
        #expect(history.count >= 2)
        #expect(history.contains { $0.mode == .verbatim && $0.textRevision == source })
        let transformed = try #require(history.first { $0.mode == .clean && $0.textRevision == saved })
        #expect(transformed.id == preview.jobID)
        #expect(transformed.parentOutputID == source.id)
        #expect(transformed.sourceRevisionID == source.id)
        #expect(transformed.sourceSHA256 == DictationTransformPolicy.sourceDigest(source.text))
        #expect(transformed.configurationID == rig.backend.config.id)
        #expect(transformed.promptTemplateVersion == DictationTransformPolicy.templateVersion)
        #expect(transformed.promptTemplateSHA256 == DictationTransformPolicy.promptTemplateSHA256(for: .clean))
        #expect(history.allSatisfy { $0.textRevision.rawText == source.rawText })
        #expect(history.allSatisfy { $0.textRevision.sourceTranscriptIDs == source.sourceTranscriptIDs })
        #expect(rig.coordinator.outputVersions == history)
        #expect(rig.coordinator.activeOutputID == rig.backend.metadata.activeOutputID)
        #expect(rig.coordinator.resultText == preview.text)
        #expect(rig.coordinator.state == .ready)
        expectNoExternalActivity(rig)
    }

    @Test("Discarding a preview changes neither saved text nor output history")
    func discardDoesNotSaveOutput() async throws {
        let rig = TransformCoordinatorRig()
        let original = rig.backend.metadata
        rig.coordinator.prepareTransform(.organize)
        await rig.coordinator.waitUntilSettled()
        try #require(rig.coordinator.transformPreview != nil)
        rig.coordinator.discardTransformPreview()
        #expect(rig.coordinator.transformPreview == nil)
        #expect(rig.backend.metadata == original)
        #expect(rig.coordinator.resultText == original.textRevision?.text)
        #expect(rig.backend.applyCount == 0)
        #expect(rig.backend.saveCount == 0)
        #expect(rig.coordinator.outputVersions.isEmpty)
        expectNoExternalActivity(rig)
    }

    @Test("An edit made during generation prevents the older result from publishing")
    func staleGenerationCannotReplaceEditedSource() async throws {
        let rig = TransformCoordinatorRig()
        let raw = try #require(rig.backend.metadata.textRevision?.rawText)
        rig.backend.suspendGeneration = true
        rig.coordinator.prepareTransform(.clean)
        await rig.backend.waitForGeneration()
        let edited = "Please keep die Rechnung local, not tomorrow, and keep 42 Dateien."
        rig.coordinator.resultText = edited
        rig.backend.releaseGeneration()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(!rig.coordinator.isTransitioning)
        #expect(rig.coordinator.transformPreview == nil)
        #expect(rig.coordinator.resultText == edited)
        #expect(rig.backend.metadata.textRevision?.text == edited)
        #expect(rig.backend.metadata.textRevision?.rawText == raw)
        #expect(rig.backend.applyCount == 0)
        #expect(rig.coordinator.message.localizedCaseInsensitiveContains("changed"))
        expectNoExternalActivity(rig)
    }

    @Test("Cancelled generation cannot publish even if the backend returns late",
          arguments: [TransformCancellationBehavior.cooperative, .ignoresCancellation])
    func cancelledGenerationCannotPublish(_ behavior: TransformCancellationBehavior) async {
        let rig = TransformCoordinatorRig()
        let original = rig.backend.metadata
        rig.backend.suspendGeneration = true
        rig.backend.honorsCancellation = behavior == .cooperative
        rig.coordinator.prepareTransform(.clean)
        await rig.backend.waitForGeneration()
        rig.coordinator.cancelTransform()
        #expect(rig.coordinator.isTransitioning)
        rig.backend.releaseGeneration()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.transformPreview == nil)
        #expect(!rig.coordinator.isTransforming)
        #expect(!rig.coordinator.canCancelTransform)
        #expect(!rig.coordinator.reservesCapture)
        #expect(rig.coordinator.state == .ready)
        #expect(rig.backend.metadata == original)
        #expect(rig.backend.applyCount == 0)
        #expect(rig.coordinator.resultText == original.textRevision?.text)
        expectNoExternalActivity(rig)
    }

    @Test("A missing or unsupported local text model leaves the original ready and unchanged")
    func transformFailurePreservesReadySource() async {
        let rig = TransformCoordinatorRig()
        let original = rig.backend.metadata
        rig.backend.transformFailure = TransformFixtureError.unsupportedModel
        rig.coordinator.prepareTransform(.summarize)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.state == .ready)
        #expect(!rig.coordinator.isTransforming)
        #expect(!rig.coordinator.isTransitioning)
        #expect(rig.coordinator.transformPreview == nil)
        #expect(rig.backend.metadata == original)
        #expect(rig.coordinator.resultText == original.textRevision?.text)
        #expect(rig.coordinator.message == TransformFixtureError.unsupportedModel.localizedDescription)
        #expect(rig.backend.applyCount == 0)
        expectNoExternalActivity(rig)
    }

    @Test("Applying a preview after editing its source cannot overwrite the edit")
    func applyRejectsEditedPreviewSource() async throws {
        let rig = TransformCoordinatorRig()
        let raw = try #require(rig.backend.metadata.textRevision?.rawText)
        rig.coordinator.prepareTransform(.clean)
        await rig.coordinator.waitUntilSettled()
        try #require(rig.coordinator.transformPreview != nil)
        let edited = "Edited after preview: bitte keep 42 Dateien local."
        rig.coordinator.resultText = edited
        rig.coordinator.applyTransformPreview()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.applyCount == 0)
        #expect(rig.backend.metadata.textRevision?.text == edited)
        #expect(rig.backend.metadata.textRevision?.rawText == raw)
        #expect(rig.coordinator.resultText == edited)
        #expect(rig.coordinator.state == .ready)
        expectNoExternalActivity(rig)
    }

    @Test("A backend source revision change is rejected by the real history policy")
    func backendStaleSourceRejectsApply() async throws {
        let rig = TransformCoordinatorRig()
        let original = try #require(rig.backend.metadata.textRevision)
        rig.coordinator.prepareTransform(.clean)
        await rig.coordinator.waitUntilSettled()
        try #require(rig.coordinator.transformPreview != nil)
        var otherEdit = original
        otherEdit.id = UUID()
        otherEdit.text = "Another saved edit keeps 42 Dateien."
        rig.backend.metadata.textRevision = otherEdit
        rig.coordinator.applyTransformPreview()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.applyCount == 1)
        #expect(rig.backend.metadata.textRevision == otherEdit)
        #expect(rig.backend.metadata.outputHistory == nil)
        #expect(rig.coordinator.state == .ready)
        #expect(!rig.coordinator.isTransforming)
        #expect(rig.coordinator.message == DictationTransformError.staleSource.localizedDescription)
        expectNoExternalActivity(rig)
    }

    @Test("Choosing Original restores it without deleting any transformed version")
    func selectOriginalKeepsEveryVersion() async throws {
        let rig = TransformCoordinatorRig()
        let source = try #require(rig.backend.metadata.textRevision)
        rig.coordinator.prepareTransform(.clean)
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.applyTransformPreview()
        await rig.coordinator.waitUntilSettled()
        rig.coordinator.prepareTransform(.organize)
        await rig.coordinator.waitUntilSettled()
        try #require(rig.coordinator.transformPreview != nil)
        rig.coordinator.applyTransformPreview()
        await rig.coordinator.waitUntilSettled()
        let versions = try #require(rig.backend.metadata.outputHistory)
        try #require(versions.count >= 3)
        let original = try #require(versions.first { $0.mode == .verbatim && $0.textRevision == source })
        rig.coordinator.selectOutput(original.id)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.selectCount == 1)
        #expect(rig.backend.metadata.outputHistory == versions)
        #expect(rig.coordinator.outputVersions == versions)
        #expect(rig.backend.metadata.textRevision == source)
        #expect(rig.coordinator.resultText == source.text)
        #expect(rig.coordinator.activeOutputID == original.id)
        #expect(rig.backend.metadata.activeOutputID == original.id)
        #expect(rig.coordinator.outputMode == .verbatim)
        #expect(rig.coordinator.transformPreview == nil)
        #expect(rig.backend.metadata.textRevision?.rawText == source.rawText)
        #expect(rig.backend.metadata.textRevision?.sourceTranscriptIDs == source.sourceTranscriptIDs)
        expectNoExternalActivity(rig)
    }

    @Test("An immediate edit is durably saved before the transform receives its current source")
    func pendingEditIsSavedBeforeGeneration() async throws {
        let rig = TransformCoordinatorRig()
        let originalRaw = try #require(rig.backend.metadata.textRevision?.rawText)
        rig.backend.suspendGeneration = true
        let latest = "bitte send die Rechnung to Müller not today and keep 42 Dateien local"
        rig.coordinator.resultText = latest
        rig.coordinator.prepareTransform(.clean)
        await rig.backend.waitForGeneration()
        let request = try #require(rig.backend.requests.last)
        #expect(rig.backend.saveCount == 1)
        #expect(rig.backend.events.first == "save")
        #expect(rig.backend.events.last == "generate")
        #expect(request.sourceText == latest)
        #expect(request.sourceRevisionID == rig.backend.metadata.textRevision?.id)
        #expect(request.sourceSHA256 == DictationTransformPolicy.sourceDigest(latest))
        #expect(rig.backend.metadata.textRevision?.rawText == originalRaw)
        rig.backend.releaseGeneration()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.coordinator.transformPreview?.sourceRevisionID == request.sourceRevisionID)
        #expect(rig.backend.metadata.textRevision?.text == latest)
        #expect(rig.backend.applyCount == 0)
        expectNoExternalActivity(rig)
    }

    private func expectNoExternalActivity(_ rig: TransformCoordinatorRig) {
        #expect(rig.backend.beginCount == 0)
        #expect(rig.adapter.trustReads == 0)
        #expect(rig.adapter.frontmostReads == 0)
        #expect(rig.adapter.fieldReads == 0)
        #expect(rig.adapter.writeCount == 0)
        #expect(rig.adapter.permissionRequests == 0)
    }
}

enum TransformCancellationBehavior: Sendable { case cooperative, ignoresCancellation }
private enum TransformFixtureError: LocalizedError {
    case unsupportedModel, unsupportedCapture, saveFailed
    var errorDescription: String? {
        switch self {
        case .unsupportedModel: "The local text model is unavailable for this preview."
        case .unsupportedCapture: "This transform fixture never starts capture."
        case .saveFailed: "Injected transient save failure after the in-memory update."
        }
    }
}

@MainActor
private final class TransformCoordinatorBackend: DictationRecordingBackend {
    let recording = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    let cleanOutput = "Bitte send die Rechnung to Müller, not today, and keep 42 Dateien local."
    let config = ProcessingConfiguration(modelID: "coordinator-local-text-fixture", revision: "fixture",
        runtime: "pure coordinator adapter", quantization: "4-bit", thinking: false, inputLimit: 4_096, outputLimit: 512)
    var metadata: DictationRecordingMetadata
    var suspendGeneration = false
    var honorsCancellation = true
    var transformFailure: (any Error)?
    var requests: [DictationTransformRequest] = []
    var events: [String] = []
    var beginCount = 0
    var saveCount = 0
    var failNextSaveAfterMutation = false
    var failedSaveCount = 0
    var applyCount = 0
    var selectCount = 0
    private var generationGate: CheckedContinuation<Void, Never>?
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let text = "äh bitte send die Rechnung to Müller not today and keep 42 Dateien local"
        let source = DictationTextRevision(rawText: text, text: text, sourceTranscriptIDs: [UUID(), UUID()])
        metadata = DictationRecordingMetadata(id: recording.takeID, state: .ready, textRevision: source)
    }

    func waitForGeneration() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { generationWaiters.append($0) }
    }
    func releaseGeneration() {
        suspendGeneration = false
        generationGate?.resume()
        generationGate = nil
    }
    func dictationBegin() async throws -> DictationRecordingHandle {
        beginCount += 1
        throw TransformFixtureError.unsupportedCapture
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {}
    func dictationResume(_ handle: DictationRecordingHandle) async throws {}
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        throw TransformFixtureError.unsupportedCapture
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? {
        handle == recording ? metadata : nil
    }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        guard handle == recording else { throw DictationTransformError.staleSource }
        saveCount += 1
        events.append("save")
        metadata.state = state
        if let revision {
            metadata.textRevision = revision
            if let active = metadata.activeOutputID,
               metadata.outputHistory?.first(where: { $0.id == active })?.textRevision != revision {
                metadata.activeOutputID = nil
            }
        }
        if let delivery { metadata.delivery = delivery }
        metadata.failureMessage = failure
        if failNextSaveAfterMutation {
            failNextSaveAfterMutation = false
            failedSaveCount += 1
            throw TransformFixtureError.saveFailed
        }
    }
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode) async throws -> DictationTransformResult {
        guard handle == recording, metadata.textRevision == source else { throw DictationTransformError.staleSource }
        let request = DictationTransformRequest(sourceRevisionID: source.id,
            sourceSHA256: DictationTransformPolicy.sourceDigest(source.text), mode: mode,
            sourceText: source.text, configuration: config)
        requests.append(request)
        events.append("generate")
        let waiting = generationWaiters
        generationWaiters = []
        if suspendGeneration {
            await withCheckedContinuation { continuation in
                generationGate = continuation
                waiting.forEach { $0.resume() }
            }
        } else { waiting.forEach { $0.resume() } }
        if honorsCancellation { try Task.checkCancellation() }
        if let transformFailure { throw transformFailure }
        guard metadata.textRevision == source else { throw DictationTransformError.staleSource }
        let text: String
        switch mode {
        case .verbatim: text = source.text
        case .clean: text = cleanOutput
        case .summarize: text = "Keep 42 Dateien local."
        case .organize: text = "- " + source.text
        case .email: text = cleanOutput
        // A same-language copy is a structurally valid translation fixture.
        case .translateEnglish, .translateGerman: text = source.text
        }
        let result = DictationTransformResult(jobID: request.jobID, sourceRevisionID: source.id,
            sourceSHA256: request.sourceSHA256, mode: mode, text: text,
            generatedTokens: mode == .verbatim ? 0 : 32, configurationID: config.id,
            promptTemplateVersion: DictationTransformPolicy.templateVersion,
            promptTemplateSHA256: DictationTransformPolicy.promptTemplateSHA256(for: mode))
        try DictationTransformPolicy.validate(result, request: request)
        return result
    }
    func dictationApplyTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                 result: DictationTransformResult) async throws -> DictationRecordingMetadata {
        guard handle == recording else { throw DictationTransformError.staleSource }
        applyCount += 1
        guard let request = requests.first(where: { $0.jobID == result.jobID }) else {
            throw DictationTransformError.mismatchedResult
        }
        try DictationTransformPolicy.validate(result, request: request)
        try metadata.stageTransform(source: source, result: result)
        return metadata
    }
    func dictationSelectOutput(_ handle: DictationRecordingHandle, id: UUID) async throws -> DictationRecordingMetadata {
        guard handle == recording else { throw DictationTransformError.missingOutput }
        selectCount += 1
        try metadata.selectOutput(id: id)
        return metadata
    }
}

@MainActor
private final class TransformCoordinatorField: DictationDeliveryField {}

@MainActor
private final class TransformCoordinatorAdapter: DictationDeliveryAdapter {
    var trustReads = 0
    var isTrusted: Bool { trustReads += 1; return false }
    var frontmostReads = 0
    var fieldReads = 0
    var writeCount = 0
    var permissionRequests = 0
    func requestPermission() { permissionRequests += 1 }
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { frontmostReads += 1; return nil }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField {
        fieldReads += 1
        return TransformCoordinatorField()
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

@MainActor
private struct TransformCoordinatorRig {
    let backend: TransformCoordinatorBackend
    let adapter: TransformCoordinatorAdapter
    let coordinator: DictationCoordinator
    init() {
        let backend = TransformCoordinatorBackend()
        let adapter = TransformCoordinatorAdapter()
        self.backend = backend
        self.adapter = adapter
        coordinator = DictationCoordinator(backend: backend, delivery: DictationDeliveryService(adapter: adapter,
            ownBundleIdentifier: "test.Keystorm", ownProcessIdentifier: 999))
        coordinator.restore(backend.recording)
    }
}
