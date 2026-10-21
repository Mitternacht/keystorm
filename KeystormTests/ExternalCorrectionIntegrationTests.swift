import ApplicationServices
import Foundation
import Testing
@testable import Keystorm

@MainActor @Suite(.serialized)
struct ExternalCorrectionIntegrationTests {
    @Test("Confirmed saved dictation observes an external EN/DE edit without altering the transcript")
    func confirmedDeliveryFeedsTheBackendOnce() async throws {
        let rig = ExternalCoordinatorRig()
        await rig.deliver()
        #expect(rig.service.hasActiveCorrectionObservation)
        #expect(rig.backend.foreground == false)
        #expect(rig.backend.metadata.delivery?.state == .inserted)
        rig.correct()
        await rig.coordinator.waitUntilSettled()
        let event = try #require(rig.backend.observations.first)
        #expect(rig.backend.observations.count == 1)
        #expect(event.originalText == rig.backend.source.text)
        #expect(event.correctedText == "The Kubernetes deployment ist bereit.")
        #expect(event.deliveryID == rig.backend.metadata.delivery?.requestID)
        #expect(rig.coordinator.resultText == rig.backend.source.text)
        #expect(rig.backend.metadata.textRevision == rig.backend.source)
        #expect(rig.adapter.writeCount == 1)
        #expect(!rig.service.hasActiveCorrectionObservation)
        rig.adapter.emitLate(.valueChanged)
        rig.clock.fireCancelledActions()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.observations.count == 1)
    }

    @Test("Default-off, unsupported, failed or unpersisted delivery never starts correction capture",
          arguments: [0, 1, 2, 3, 4])
    func unqualifiedDeliveryNeverArms(_ kind: Int) async throws {
        let rig = ExternalCoordinatorRig()
        switch kind {
        case 0: rig.backend.consentID = nil
        case 1: rig.adapter.supportsObservation = false
        case 2: rig.adapter.acknowledgment = .rejected
        case 3: rig.backend.failReceipt = true
        default: rig.adapter.app.bundleIdentifier = "com.example.Unsupported"
        }
        await rig.deliver()
        #expect(!rig.service.hasActiveCorrectionObservation)
        rig.correct()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.observations.isEmpty)
    }

    @Test("New UI work cancels a queued external correction", arguments: [0, 1, 2, 3, 4, 5])
    func uiTransitionsInvalidateExternalLease(_ kind: Int) async throws {
        let rig = ExternalCoordinatorRig()
        await rig.deliver()
        try #require(rig.service.hasActiveCorrectionObservation)
        rig.adapter.setText("Prefix. The Kubernetes deployment ist bereit. Ende.")
        rig.adapter.emit(.valueChanged)
        switch kind {
        case 0: rig.coordinator.newDraft()
        case 1: rig.coordinator.restore(rig.backend.handle)
        case 2: rig.coordinator.resultText = "Edited inside Keystorm."
        case 3: rig.coordinator.prepareTransform(.clean)
        case 4: rig.coordinator.toggle()
        default: rig.coordinator.cancelForShutdown()
        }
        #expect(!rig.service.hasActiveCorrectionObservation)
        rig.clock.fireCancelledActions()
        rig.clock.advance(by: 2)
        await rig.coordinator.waitUntilSettled()
        #expect(rig.backend.observations.isEmpty)
        rig.coordinator.cancelForShutdown()
        await rig.coordinator.waitUntilSettled()
    }

    @Test("Consent off then on invalidates the old lease before reading")
    func preferenceCycleCannotReviveObservation() async throws {
        let rig = ExternalCoordinatorRig()
        await rig.deliver()
        let reads = rig.adapter.snapshotReads
        rig.backend.consentID = nil
        #expect(!rig.service.hasActiveCorrectionObservation)
        rig.backend.consentID = UUID()
        rig.correct()
        await rig.coordinator.waitUntilSettled()
        #expect(rig.adapter.snapshotReads == reads)
        #expect(rig.backend.observations.isEmpty)
    }

    @Test("Workspace requires matching saved delivery, source, scope and consent",
          arguments: Array(0...9))
    func workspaceValidatesDeliveryProvenance(_ fault: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-External-Integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "The Kubernettes deployment ist bereit."
        let transcript = TranscriptRevision(rawText: original, text: original, origin: .imported, timingPrecision: .unavailable)
        var source = DictationTextRevision(rawText: original, text: original, sourceTranscriptIDs: [transcript.id])
        var session = VoiceSession()
        let take = BriefTake(expectedRevision: UUID(), status: .pending, transcriptIDs: [transcript.id])
        var brief = BriefDocument(); brief.takes = [take]
        session.brief = brief; session.transcripts = [transcript]
        let handle = DictationRecordingHandle(sessionID: session.id, takeID: take.id)
        let requestID = UUID()
        var metadata = DictationRecordingMetadata(id: take.id, state: .ready, textRevision: source)
        metadata.captureAppBundleID = "com.apple.TextEdit"
        metadata.delivery = DictationDelivery(requestID: requestID, textRevisionID: source.id, targetLabel: "TextEdit", state: .inserted)
        if fault == 2 { metadata.delivery?.state = .uncertain }
        if fault == 3 { metadata.delivery?.requestID = UUID() }
        if fault == 4 { metadata.delivery?.textRevisionID = UUID() }
        if fault == 5 { metadata.captureAppBundleID = "com.example.Other" }
        if fault == 9 { metadata.purpose = .longRecording }
        session.dictation = DictationSession(recordings: [metadata])
        let store = try SessionStore(root: root)
        try await store.save(session)
        let model = WorkspaceModel(root: root, modelDirectory: root.appendingPathComponent("NoModels"))
        await model.initialize(loadLibrary: true)
        do {
            let dictionary = try #require(model.learningDictionary)
            await dictionary.setEnabled(true)
            if fault != 1 { await dictionary.setExternalCorrectionsEnabled(true) }
            if fault == 6 { source.id = UUID() }
            let now = Date()
            let event = ExternalCorrectionObservation(originalText: fault == 7 ? "Unrelated" : original,
                correctedText: "The Kubernetes deployment ist bereit.",
                destination: DictationDestinationDescriptor(appName: "TextEdit", bundleIdentifier: "com.apple.TextEdit",
                    processIdentifier: 42, capturedAt: now.addingTimeInterval(-5)),
                deliveryID: requestID, observedAt: fault == 8 ? now.addingTimeInterval(-60) : now)
            await model.dictationObservedExternalCorrection(handle, source: source, observation: event)
            await dictionary.waitUntilSettled()
            await model.stopForTermination()
            let learned = try LearningRepository(url: root.appendingPathComponent("Learning/dictionary-v1.json"))
            let snapshot = await learned.snapshot()
            #expect(snapshot.evidence.count == (fault == 0 ? 1 : 0))
            if fault == 0 {
                let evidence = try #require(snapshot.evidence.first?.evidence)
                #expect(evidence.origin?.attribution == .unverified)
                #expect(evidence.origin?.deliveryID == requestID)
                #expect(evidence.sourceOutputID == source.id)
                #expect(await learned.suggestions(appBundleID: "com.apple.TextEdit").isEmpty)
            }
            let reopened = try await SessionStore(root: root).loadSessions()
            #expect(reopened.first(where: { $0.id == session.id })?.dictation?.recordings.first?.textRevision?.text == original)
        } catch {
            await model.stopForTermination()
            throw error
        }
    }

    @Test("Native Accessibility availability is recorded without prompting for permission")
    func nativeObservationAvailability() throws {
        let trusted = AXIsProcessTrusted()
        Attachment.record(Data("Accessibility trusted: \(trusted)\nNative event/insertion qualification requires existing trust.".utf8),
                          named: "external-correction-native-availability.txt")
    }
}

@MainActor
private final class ExternalCoordinatorBackend: DictationRecordingBackend {
    let handle = DictationRecordingHandle(sessionID: UUID(), takeID: UUID())
    let source = DictationTextRevision(rawText: "The Kubernettes deployment ist bereit.",
        text: "The Kubernettes deployment ist bereit.", sourceTranscriptIDs: [UUID()])
    var metadata = DictationRecordingMetadata(id: UUID())
    var consentID: UUID? = UUID() { didSet { consentChanged?() } }
    private var consentChanged: (@MainActor () -> Void)?
    var foreground = false
    var failReceipt = false
    var observations: [ExternalCorrectionObservation] = []
    var dictationExternalCorrectionConsentID: UUID? { foreground ? nil : consentID }
    func dictationObserveExternalCorrectionConsentChanges(_ onChange: @escaping @MainActor () -> Void) -> (any ExternalCorrectionCancellation)? {
        consentChanged = onChange
        return ExternalObservationTestCancellation { [weak self] in self?.consentChanged = nil }
    }
    func dictationBegin() async throws -> DictationRecordingHandle {
        metadata = DictationRecordingMetadata(id: handle.takeID, state: .recording)
        return handle
    }
    func dictationPause(_ handle: DictationRecordingHandle) async throws {}
    func dictationResume(_ handle: DictationRecordingHandle) async throws {}
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        metadata.state = .ready; metadata.textRevision = source
        return source
    }
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? { metadata }
    func dictationSetForegroundProcessing(_ handle: DictationRecordingHandle, active: Bool) { foreground = active }
    func dictationObservedExternalCorrection(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                             observation: ExternalCorrectionObservation) async {
        observations.append(observation)
    }
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        if delivery?.state == .inserted && failReceipt { throw CoordinatorFailure.persistence }
        metadata.state = state
        if let revision { metadata.textRevision = revision }
        if let delivery { metadata.delivery = delivery }
    }
}

@MainActor
private struct ExternalCoordinatorRig {
    let backend = ExternalCoordinatorBackend()
    let adapter = ExternalObservationTestAdapter(text: "Prefix.  Ende.")
    let clock = ExternalObservationTestScheduler()
    let service: DictationDeliveryService
    let coordinator: DictationCoordinator
    init() {
        adapter.state.selection = NSRange(location: 8, length: 0)
        service = DictationDeliveryService(adapter: adapter, ownBundleIdentifier: "test.keystorm", ownProcessIdentifier: 999,
            correctionObservationScheduler: clock)
        coordinator = DictationCoordinator(backend: backend, delivery: service)
        // Keeps the user's clipboard untouched; Copy when not inserted is covered in DictationCoordinatorTests.
        coordinator.preferences.copyWhenNotInserted = false
    }
    func deliver() async {
        coordinator.toggle(); await coordinator.waitUntilSettled()
        coordinator.finish(); await coordinator.waitUntilSettled()
    }
    func correct() {
        adapter.setText("Prefix. The Kubernetes deployment ist bereit. Ende.")
        adapter.emit(.valueChanged)
        clock.advance(by: 1)
    }
}
