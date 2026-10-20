import AppKit
import Foundation
import Observation

struct DictationRecordingHandle: Equatable, Sendable {
    var sessionID: UUID
    var takeID: UUID
}

enum DictationFlowState: String, Sendable {
    case idle, starting, recording, paused, processing, ready, failed
}

enum DictationCaptureStatus: Equatable, Sendable {
    case recording, paused
    case interrupted(String)
}

@MainActor
protocol DictationRecordingBackend: AnyObject {
    func dictationBegin() async throws -> DictationRecordingHandle
    func dictationBegin(mode: DictationQuickMode) async throws -> DictationRecordingHandle
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode, context: DictationContextSnapshot?) async throws -> DictationTransformResult
    func dictationApplyTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                 result: DictationTransformResult, context: DictationContextSnapshot?) async throws -> DictationRecordingMetadata
    func dictationLongTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
        mode: DictationOutputMode) async throws -> LongDictationTransformResult
    func dictationApplyLongTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
        result: LongDictationTransformResult) async throws -> DictationRecordingMetadata
    func dictationPause(_ handle: DictationRecordingHandle) async throws
    func dictationResume(_ handle: DictationRecordingHandle) async throws
    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision
    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata?
    func dictationCaptureStatus(_ handle: DictationRecordingHandle) -> DictationCaptureStatus?
    func dictationCancel(_ handle: DictationRecordingHandle) async throws
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode) async throws -> DictationTransformResult
    func dictationApplyTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                 result: DictationTransformResult) async throws -> DictationRecordingMetadata
    func dictationSelectOutput(_ handle: DictationRecordingHandle, id: UUID) async throws -> DictationRecordingMetadata
    func dictationSetLearningScope(_ handle: DictationRecordingHandle, appBundleID: String?) async throws
    func dictationSetPurpose(_ handle: DictationRecordingHandle, purpose: DictationRecordingPurpose) async throws
    func dictationSetForegroundProcessing(_ handle: DictationRecordingHandle, active: Bool)
    var dictationExternalCorrectionConsentID: UUID? { get }
    func dictationObserveExternalCorrectionConsentChanges(_ onChange: @escaping @MainActor () -> Void) -> (any ExternalCorrectionCancellation)?
    func dictationObservedExternalCorrection(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                             observation: ExternalCorrectionObservation) async
    func dictationUserEdited(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                             edited: DictationTextRevision) async
    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws
}

extension DictationRecordingBackend {
    var dictationExternalCorrectionConsentID: UUID? { nil }
    func dictationObserveExternalCorrectionConsentChanges(_ onChange: @escaping @MainActor () -> Void) -> (any ExternalCorrectionCancellation)? { nil }
    func dictationObservedExternalCorrection(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                             observation: ExternalCorrectionObservation) async { }
    func dictationLongTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
        mode: DictationOutputMode) async throws -> LongDictationTransformResult {
        throw KeystormError.message("Long local previews are unavailable for this recording.")
    }
    func dictationApplyLongTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
        result: LongDictationTransformResult) async throws -> DictationRecordingMetadata {
        throw KeystormError.message("Long output versions are unavailable for this recording.")
    }
    func dictationSetLearningScope(_ handle: DictationRecordingHandle, appBundleID: String?) async throws { }
    func dictationSetPurpose(_ handle: DictationRecordingHandle, purpose: DictationRecordingPurpose) async throws { }
    func dictationSetForegroundProcessing(_ handle: DictationRecordingHandle, active: Bool) { }
    func dictationUserEdited(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                             edited: DictationTextRevision) async { }
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode, context: DictationContextSnapshot?) async throws -> DictationTransformResult {
        try await dictationTransform(handle, source: source, mode: mode)
    }
    func dictationApplyTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                 result: DictationTransformResult, context: DictationContextSnapshot?) async throws -> DictationRecordingMetadata {
        try await dictationApplyTransform(handle, source: source, result: result)
    }
    func dictationBegin(mode: DictationQuickMode) async throws -> DictationRecordingHandle {
        try await dictationBegin()
    }
    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode) async throws -> DictationTransformResult {
        throw KeystormError.message("Local AI previews are unavailable for this recording.")
    }
    func dictationApplyTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                 result: DictationTransformResult) async throws -> DictationRecordingMetadata {
        throw KeystormError.message("This recording does not support saved output versions.")
    }
    func dictationSelectOutput(_ handle: DictationRecordingHandle, id: UUID) async throws -> DictationRecordingMetadata {
        throw KeystormError.message("This recording does not support saved output versions.")
    }
    func dictationCaptureStatus(_ handle: DictationRecordingHandle) -> DictationCaptureStatus? { nil }
    func dictationCancel(_ handle: DictationRecordingHandle) async throws {
        try await dictationPause(handle)
        try await dictationSave(handle, state: .cancelled, revision: nil, delivery: nil, failure: nil)
    }
}

/// One serialized capture -> durable transcription -> at-most-once delivery operation.
@MainActor @Observable
final class DictationCoordinator {
    private(set) var state: DictationFlowState = .idle {
        didSet { announceStateChange(from: oldValue) }
    }
    var resultText = "" {
        didSet { saveEditedResult() }
    }
    private(set) var message = "Ready for local dictation." {
        didSet { messageRevision &+= 1 }
    }
    /// Advances on every `message` assignment, so views can announce a repeated identical status
    /// such as a second Copy. Paths that may re-run without a user action must not reassign an unchanged message.
    private(set) var messageRevision = 0
    /// The message revision this coordinator already spoke itself; views skip it so it is heard once.
    private(set) var spokenMessageRevision: Int?
    private(set) var destinationLabel = "Copy after recording"
    private(set) var handle: DictationRecordingHandle?
    private(set) var wantsRecordingHUD = false
    let preferences: DictationPreferences
    private(set) var contextStatus = "Context off"
    private(set) var contextProfile: DictationContextProfile?
    @ObservationIgnored private var capturedContext: DictationContextSnapshot?
    private(set) var captureMode: DictationQuickMode = .verbatim
    private(set) var recordingPurpose: DictationRecordingPurpose = .quick
    private(set) var outputMode: DictationOutputMode = .verbatim
    private(set) var outputVersions: [DictationOutputRevision] = []
    private(set) var activeOutputID: UUID?
    private(set) var transformPreview: DictationTransformResult?
    private(set) var longTransformPreview: LongDictationTransformResult?
    var hasTransformPreview: Bool { transformPreview != nil || longTransformPreview != nil }
    private(set) var isTransforming = false
    private var transformCancellable = false
    @ObservationIgnored private var transformTask: Task<Void, Never>?
    @ObservationIgnored private var transformGeneration = UUID()
    @ObservationIgnored private var previewSource: DictationTextRevision?
    var canCancelTransform: Bool { isTransforming && transformCancellable }
    var reservesCapture: Bool { hasActiveRecording || isTransforming }
    @ObservationIgnored private let backend: any DictationRecordingBackend
    @ObservationIgnored private let deliveryService: DictationDeliveryService
    @ObservationIgnored private var target: DictationCapturedTarget?
    @ObservationIgnored private var revision: DictationTextRevision?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var correctionGeneration = UUID()
    @ObservationIgnored private var correctionSubmission: Task<Void, Never>?
    @ObservationIgnored private var correctionConsentObservation: (any ExternalCorrectionCancellation)?
    @ObservationIgnored private var transition = false
    private var cancelling = false
    private var delivering = false
    private var committingOutput = false
    @ObservationIgnored private var captureInterruption: String?
    @ObservationIgnored private var pendingEdits: [UUID: DictationTextRevision] = [:]
    @ObservationIgnored private var editLearningSources: [UUID: DictationTextRevision] = [:]
    @ObservationIgnored private var editSaves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var editSaveTokens: [UUID: UUID] = [:]
    /// Speaks flow status for VoiceOver; replaceable so tests can observe announcements.
    @ObservationIgnored var announceStatus: @MainActor (String) -> Void = DictationCoordinator.postStatusAnnouncement
    @ObservationIgnored private var announcesStateChanges = true
    @ObservationIgnored private var announcesCancellation = false
    /// Set immediately before a failure settles into `.ready` or `.failed`, so that one transition
    /// speaks the complete final message (the reason) instead of the bare state name.
    @ObservationIgnored private var announcesSettleMessage = false
    var hasActiveRecording: Bool { cancelling || [.starting, .recording, .paused, .processing].contains(state) }
    var canCancel: Bool { hasActiveRecording && !cancelling && !delivering }
    var isTransitioning: Bool { transition || cancelling || isTransforming || state == .starting || state == .processing }

    init(backend: any DictationRecordingBackend, delivery: DictationDeliveryService? = nil,
         preferences: DictationPreferences? = nil) {
        self.backend = backend
        self.preferences = preferences ?? DictationPreferences()
        deliveryService = delivery ?? DictationDeliveryService()
    }

    /// VoiceOver focus never reaches the nonactivating HUD while the user dictates into another app,
    /// so each real flow transition is spoken once. Message updates and clock ticks never announce.
    private func announceStateChange(from previous: DictationFlowState) {
        // A settle request covers only the assignment that follows it, spoken or not.
        let settleMessage = announcesSettleMessage && !message.isEmpty
        announcesSettleMessage = false
        // Intermediate states while cancelling stay silent; the cancel outcome is spoken once below.
        guard announcesStateChanges, !cancelling else { return }
        let cancelled = announcesCancellation
        announcesCancellation = false
        let announcement: String
        if cancelled {
            // A cancel that could not finish keeps the recording active.
            announcement = state == .recording ?
                String(localized: "Cancellation needs attention",
                       comment: "VoiceOver announcement when cancelling a dictation did not finish") :
                String(localized: "Dictation cancelled", comment: "VoiceOver announcement after a dictation is cancelled")
        } else {
            guard state != previous else { return }
            switch state {
            case .idle: return
            case .starting:
                announcement = String(localized: "Starting", comment: "VoiceOver announcement while dictation is starting")
            case .recording:
                announcement = String(localized: "Recording", comment: "VoiceOver announcement when dictation records or resumes")
            case .paused:
                announcement = captureInterruption == nil ?
                    String(localized: "Paused", comment: "VoiceOver announcement when dictation recording pauses") :
                    String(localized: "Recording interrupted and paused",
                           comment: "VoiceOver announcement when the microphone stops unexpectedly and the recording pauses")
            case .processing:
                announcement = String(localized: "Transcribing", comment: "VoiceOver announcement while saved audio is transcribed")
            case .ready:
                // During delivery the message already holds the outcome, such as "Pasted into Notes."
                if delivering && !message.isEmpty {
                    announcement = message
                } else if settleMessage {
                    announcement = String(localized: "Ready to copy. \(message)",
                        comment: "VoiceOver announcement when a dictation step failed but saved text is ready. The placeholder is the complete reason and next step.")
                } else {
                    announcement = String(localized: "Ready to copy", comment: "VoiceOver announcement when transcribed text is ready")
                }
            case .failed:
                announcement = settleMessage ?
                    String(localized: "Dictation failed. \(message)",
                           comment: "VoiceOver announcement when dictation fails. The placeholder is the reason.") :
                    String(localized: "Dictation failed", comment: "VoiceOver announcement when dictation fails")
            }
        }
        announceStatus(announcement)
    }

    /// Settles a failure with its complete message already in place, so the transition is spoken once
    /// with the reason and the status line does not repeat it after the state changed.
    private func settleFailure(_ state: DictationFlowState) {
        announcesSettleMessage = true
        self.state = state
        announcesSettleMessage = false
    }

    /// Drops the captured destination without delivering it. A captured paste-fallback destination may hold
    /// accessibility mode Keystorm turned on for that app; releasing turns it off again. Delivery releases
    /// its own target, so a target handed to `deliver` is never released here.
    private func releaseTarget() {
        guard let target else { return }
        self.target = nil
        deliveryService.releaseCapturedTarget(target)
    }

    private static func postStatusAnnouncement(_ text: String) {
        // Unit tests may run without an application object.
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    private func clearCapturedContext() {
        capturedContext = nil
        contextProfile = nil
        contextStatus = "Context off"
    }

    func newDraft() {
        guard !hasActiveRecording, !isTransitioning else { return }
        stopExternalCorrectionObservation()
        clearCapturedContext()
        state = .idle
        wantsRecordingHUD = false
        transformPreview=nil; longTransformPreview=nil; previewSource=nil
        outputMode = .verbatim; outputVersions = []; activeOutputID = nil
        recordingPurpose = .quick
        handle = nil
        revision = nil
        releaseTarget()
        resultText = ""
        destinationLabel = "Copy after recording"
        message = "Ready for local dictation."
    }

    func toggle() {
        switch state {
        case .idle, .ready, .failed: start()
        case .recording, .paused: finish()
        case .starting, .processing: break
        }
    }

    func startLongRecording() { start(longRecording: true) }

    private func start(longRecording: Bool = false) {
        guard !reservesCapture, !isTransitioning else { return }
        stopExternalCorrectionObservation()
        // Capture before presenting UI or requesting microphone permission changes focus.
        releaseTarget()
        recordingPurpose = longRecording ? .longRecording : .quick
        let startCapture = longRecording ? DictationStartCapture(target: .unavailable(.unsupportedApplication), context: nil) :
            deliveryService.captureForStart(contextSettings: preferences.contextSettings,
                                            pasteIntoOtherApps: preferences.pasteIntoOtherApps,
                                            exclusions: preferences.userExclusions)
        capturedContext = startCapture.context
        contextProfile = capturedContext?.profile
        contextStatus = capturedContext == nil ?
            (preferences.contextMode == .off ? "Context off" : "Context unavailable") :
            (capturedContext?.availability == .nearbyText ? "Nearby text" : "App context")
        switch startCapture.target {
        case .ready(let captured):
            target = captured
            switch captured.strategy {
            case .qualifiedTextEdit:
                destinationLabel = captured.descriptor.appName
                message = "Recording locally. Finish to insert in \(destinationLabel)."
            case .pasteFallback:
                destinationLabel = "Paste into \(captured.descriptor.appName)"
                message = "Recording locally. Finish to paste into \(captured.descriptor.appName)."
            }
        case .unavailable(let reason):
            destinationLabel = "Copy after recording"
            message = reason.message
            if reason.blocksRecording {
                if state == .idle {
                    wantsRecordingHUD = true
                    settleFailure(.failed)
                } else {
                    // A settled result keeps its state, so no transition would speak. Announce the reason
                    // once here. A refused attempt never asks for the HUD; a Ready HUD would present the earlier
                    // result ("Dictation ready") as this attempt's outcome, so it is withdrawn. A Needs attention
                    // HUD keeps showing, now with this reason.
                    if state == .ready { wantsRecordingHUD = false }
                    if announcesStateChanges {
                        spokenMessageRevision = messageRevision
                        announceStatus(message)
                    }
                }
                clearCapturedContext()
                return
            }
        }
        // Presented only after observation runs, which is after the destination was captured above.
        wantsRecordingHUD = true
        if longRecording {
            destinationLabel = "Editor after recording"
            message = "Recording locally. Finish opens the transcript in this editor."
            clearCapturedContext()
        }
        state = .starting
        // A per-app preset applies to this recording only, chosen by the app in front at Start; the Next recording
        // choice stays as it is. Presets hold Quick modes only, so translation never starts automatically.
        let preset = longRecording ? nil : preferences.appPreset(for: startCapture.applicationBundleIdentifier)
        captureMode = longRecording ? .verbatim : (preset?.mode ?? preferences.mode)
        if let preset {
            message += " " + String(localized: "Using the \(String(localized: preset.mode.title)) preset for \(preset.name).",
                comment: "Appended to the recording status when an app preset chose the dictation mode. Placeholders: mode name, app name.")
        }
        let requestedMode = captureMode
        transformPreview=nil; longTransformPreview=nil; previewSource=nil
        outputMode = .verbatim; outputVersions = []; activeOutputID = nil
        captureInterruption = nil
        resultText = ""
        revision = nil
        handle = nil
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                self.handle = try await self.backend.dictationBegin(mode: requestedMode)
                if let handle = self.handle {
                    try await self.backend.dictationSetLearningScope(handle, appBundleID: self.target?.descriptor.bundleIdentifier)
                    try await self.backend.dictationSetPurpose(handle, purpose: self.recordingPurpose)
                }
                guard !Task.isCancelled, !self.cancelling else { return }
                self.state = .recording
            } catch {
                guard !self.cancelling else { return }
                let failure = error.localizedDescription
                if let handle = self.handle { try? await self.backend.dictationCancel(handle) }
                self.clearCapturedContext()
                self.releaseTarget()
                self.message = failure
                self.settleFailure(.failed)
            }
        }
    }

    func pauseResume() {
        guard !isTransitioning, let handle, state == .recording || state == .paused else { return }
        let resuming = state == .paused
        if resuming { wantsRecordingHUD = true }
        transition = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.transition = false }
            do {
                if resuming { try await self.backend.dictationResume(handle) }
                else { try await self.backend.dictationPause(handle) }
                guard !Task.isCancelled, !self.cancelling else { return }
                if resuming { self.captureInterruption = nil }
                self.state = resuming ? .recording : .paused
                self.message = resuming ? "Recording locally." : "Paused. Resume continues the same recording."
            } catch { self.message = error.localizedDescription }
        }
    }

    func finish() {
        guard !isTransitioning, let handle, state == .recording || state == .paused || state == .failed else { return }
        let requestedMode = captureMode
        backend.dictationSetForegroundProcessing(handle, active: true)
        // An app blocked during the recording gets no context, like one blocked at Start: what was read from it
        // then never reaches the text model now.
        let destinationBlocked = target.map {
            preferences.userExclusions.applications.contains($0.descriptor.bundleIdentifier)
        } ?? false
        let context = !destinationBlocked && capturedContext?.isFresh() == true ? capturedContext : nil
        if capturedContext != nil && context == nil {
            clearCapturedContext()
            contextStatus = destinationBlocked ? "Context unavailable" : "Context expired"
        }
        state = .processing
        message = "Finishing the saved audio on this Mac…"
        operation = Task { [weak self] in
            guard let self else { return }
            var deliveryAttempted = false
            var observationContext: (DictationCapturedTarget, DictationTextRevision, UUID)?
            do {
                defer {
                    self.delivering = false; self.committingOutput = false
                    self.clearCapturedContext()
                    self.backend.dictationSetForegroundProcessing(handle, active: false)
                }
                let source = try await self.backend.dictationComplete(handle)
                if self.captureInterruption == nil {
                    self.revision = source
                    self.resultText = source.text
                }
                try Task.checkCancellation()
                var output = source
                if requestedMode.transformsOnFinish {
                    // Clean and Email share one durable path: raw text is already saved; the
                    // transform must match every provenance field and pass its strict lexical
                    // validator before Original/output versions commit and delivery may start.
                    let finishMode = requestedMode.outputMode
                    try self.requireCurrentOutput(source, handle: handle)
                    self.message = finishMode == .email ?
                        "Formatting the saved transcript as an email on this Mac…" :
                        "Cleaning the saved transcript on this Mac…"
                    let cleaned = try await self.backend.dictationTransform(handle, source: source, mode: finishMode, context: context)
                    try Task.checkCancellation()
                    guard finishMode.preservesLexicalSequence,
                          cleaned.mode == finishMode, cleaned.sourceRevisionID == source.id,
                          cleaned.sourceSHA256 == DictationTransformPolicy.sourceDigest(source.text),
                          cleaned.promptTemplateVersion == DictationTransformPolicy.templateVersion,
                          cleaned.promptTemplateSHA256 == DictationTransformPolicy.promptTemplateSHA256(for: finishMode, context: context),
                          cleaned.contextSHA256 == context?.digest,
                          cleaned.generatedTokens > 0,
                          cleaned.generatedTokens < DictationTransformPolicy.maxGeneratedTokens else {
                        throw DictationTransformError.mismatchedResult
                    }
                    try DictationTransformPolicy.validateText(cleaned.text, source: source.text, mode: finishMode)
                    try self.requireCurrentOutput(source, handle: handle)
                    self.committingOutput = true
                    let metadata = try await self.backend.dictationApplyTransform(handle, source: source, result: cleaned, context: context)
                    self.committingOutput = false
                    try Task.checkCancellation()
                    try metadata.validateOutputHistory()
                    guard metadata.id == handle.takeID,
                          let saved = metadata.textRevision, saved.id == cleaned.jobID,
                          metadata.activeOutputID == saved.id, metadata.outputMode == finishMode,
                          saved.text.utf8.elementsEqual(cleaned.text.utf8),
                          saved.rawText.utf8.elementsEqual(source.rawText.utf8),
                          saved.sourceTranscriptIDs == source.sourceTranscriptIDs,
                          let entry = metadata.outputHistory?.first(where: { $0.id == saved.id }),
                          entry.sourceRevisionID == source.id, entry.sourceSHA256 == cleaned.sourceSHA256,
                          entry.configurationID == cleaned.configurationID,
                          entry.promptTemplateVersion == cleaned.promptTemplateVersion,
                          entry.promptTemplateSHA256 == cleaned.promptTemplateSHA256,
                          entry.contextSHA256 == cleaned.contextSHA256 else {
                        throw DictationTransformError.mismatchedResult
                    }
                    try self.requireCurrentOutput(saved, handle: handle)
                    output = saved
                    self.loadOutputMetadata(metadata)
                    self.revision = saved
                    self.resultText = saved.text
                }
                if let target = self.target {
                    let requestID = UUID()
                    let pending = DictationDelivery(requestID: requestID, textRevisionID: output.id,
                        targetLabel: target.descriptor.appName)
                    // Completed output and a durable intent precede the external write.
                    try await self.backend.dictationSave(handle, state: .ready, revision: output, delivery: pending, failure: nil)
                    try Task.checkCancellation()
                    if requestedMode.transformsOnFinish { try self.requireCurrentOutput(output, handle: handle) }
                    deliveryAttempted = true
                    self.delivering = true
                    // Delivery owns the destination from here and releases it itself, so an interruption or
                    // shutdown during the write never releases a target mid-delivery.
                    self.target = nil
                    self.message = (target.strategy == .pasteFallback ? "Pasting into " : "Confirming insertion in ") +
                        target.descriptor.appName + "…"
                    // Exclusions as they are now: an app or website blocked during the recording is never written to.
                    let receipt = await self.deliveryService.deliver(output.text, to: target, deliveryID: requestID,
                                                                     exclusions: self.preferences.userExclusions)
                    let status: DictationDeliveryState
                    switch receipt.outcome {
                    case .confirmed: status = .inserted
                    case .failed: status = .failed
                    case .uncertain: status = .uncertain
                    case .targetChanged: status = .targetChanged
                    case .pasted: status = .pasted
                    }
                    self.message = receipt.message
                    let attempted = DictationDelivery(requestID: requestID, textRevisionID: output.id,
                        targetLabel: receipt.destination.appName, state: status, detail: receipt.message)
                    // The write was already attempted, so its receipt must become durable even if this operation is
                    // cancelled now; otherwise the record stays pending. An unstructured task does not inherit
                    // cancellation. The operation still honours its own cancellation once the receipt is saved.
                    try await Task { @MainActor [output] in
                        try await self.backend.dictationSave(handle, state: .ready, revision: output,
                            delivery: attempted, failure: nil)
                    }.value
                    try Task.checkCancellation()
                    if receipt.outcome == .confirmed { observationContext = (target, output, requestID) }
                } else {
                    self.message = requestedMode.transformsOnFinish ?
                        (requestedMode == .email ? "Email text" : "Clean text") +
                        " saved locally. The original is in Versions. Review or copy when ready." :
                        "Saved locally. Review or edit the text, then copy it."
                }
                self.state = .ready
            } catch {
                // Only a destination never handed to delivery is still held here.
                self.releaseTarget()
                if !deliveryAttempted { self.destinationLabel = "Copy after recording" }
                guard !self.cancelling else { return }
                if let interruption = self.captureInterruption {
                    self.state = .paused
                    self.message = interruption
                    return
                }
                if requestedMode.transformsOnFinish, let metadata = self.backend.dictationMetadata(handle),
                   let saved = metadata.textRevision {
                    self.loadOutputMetadata(metadata)
                    self.revision = saved
                    self.resultText = saved.text
                }
                var failureMessage = error.localizedDescription
                if self.revision != nil, requestedMode.transformsOnFinish {
                    failureMessage += deliveryAttempted ?
                        " The text is saved. Check the destination before copying again." :
                        " Saved text is available to review or copy; nothing was inserted automatically."
                }
                // The complete message precedes the settle, so its single announcement includes the reason.
                self.message = failureMessage
                self.settleFailure(self.revision == nil ? .failed : .ready)
                if self.revision == nil {
                    try? await self.backend.dictationSave(handle, state: .failed, revision: nil, delivery: nil,
                        failure: error.localizedDescription)
                }
            }
            if let (destination, source, deliveryID) = observationContext {
                self.observeExternalCorrections(to: destination, source: source, handle: handle, deliveryID: deliveryID)
            }
        }
    }

    private func stopExternalCorrectionObservation() {
        correctionGeneration = UUID()
        correctionConsentObservation?.cancel(); correctionConsentObservation = nil
        deliveryService.stopCorrectionObservation()
        correctionSubmission?.cancel()
    }

    private func observeExternalCorrections(to target: DictationCapturedTarget, source: DictationTextRevision,
                                            handle: DictationRecordingHandle, deliveryID: UUID) {
        guard !Task.isCancelled, self.handle == handle, state == .ready, !isTransitioning,
              revision == source, resultText.utf8.elementsEqual(source.text.utf8),
              let consentID = backend.dictationExternalCorrectionConsentID,
              let metadata = backend.dictationMetadata(handle), metadata.textRevision == source,
              metadata.delivery?.state == .inserted, metadata.delivery?.requestID == deliveryID,
              metadata.delivery?.textRevisionID == source.id else { return }
        let generation = correctionGeneration
        let destinationBundleIdentifier = target.descriptor.bundleIdentifier
        let armed = deliveryService.startCorrectionObservation(to: target, deliveredText: source.text,
            deliveryID: deliveryID, isEnabled: { [weak self] in
                guard let self else { return false }
                // Blocking the app ends observation too, not just future dictation.
                return self.correctionGeneration == generation && self.handle == handle &&
                    !self.preferences.userExclusions.applications.contains(destinationBundleIdentifier) &&
                    self.state == .ready && !self.isTransitioning &&
                    self.revision == source && self.resultText.utf8.elementsEqual(source.text.utf8) &&
                    self.backend.dictationExternalCorrectionConsentID == consentID
            }, onObservation: { [weak self] observation in
                guard let self, self.correctionGeneration == generation,
                      self.handle == handle, self.state == .ready, !self.isTransitioning,
                      self.revision == source, self.backend.dictationExternalCorrectionConsentID == consentID else { return }
                self.correctionSubmission = Task { [weak self] in
                    guard let self, !Task.isCancelled, self.correctionGeneration == generation,
                          self.handle == handle, self.state == .ready, !self.isTransitioning,
                          self.revision == source, self.backend.dictationExternalCorrectionConsentID == consentID else { return }
                    await self.backend.dictationObservedExternalCorrection(handle, source: source, observation: observation)
                }
            })
        if armed {
            correctionConsentObservation = backend.dictationObserveExternalCorrectionConsentChanges { [weak self] in
                self?.stopExternalCorrectionObservation()
            }
            message += " Corrections in TextEdit can be collected briefly for Dictionary review."
        }
    }

    private func requireCurrentOutput(_ expected: DictationTextRevision, handle: DictationRecordingHandle) throws {
        guard let metadata = backend.dictationMetadata(handle), metadata.id == handle.takeID,
              metadata.textRevision == expected else {
            throw DictationTransformError.staleSource
        }
    }

    func restore(_ handle: DictationRecordingHandle) {
        guard !reservesCapture, !isTransitioning, let metadata = backend.dictationMetadata(handle) else { return }
        stopExternalCorrectionObservation()
        wantsRecordingHUD = false
        transformPreview=nil; longTransformPreview=nil; previewSource=nil
        loadOutputMetadata(metadata)
        self.handle = handle
        captureMode = metadata.captureMode ?? .verbatim
        recordingPurpose = metadata.purpose ?? .quick
        clearCapturedContext()
        releaseTarget()
        revision = pendingEdits[handle.takeID] ?? metadata.textRevision
        if pendingEdits[handle.takeID] != nil { activeOutputID = nil }
        resultText = revision?.text ?? ""
        destinationLabel = "Copy after recording"
        // Opening a saved recording is a selection in the focused workspace, not a live transition.
        let announces = announcesStateChanges
        announcesStateChanges = false
        switch metadata.state {
        case .recording, .paused: state = .paused
        case .ready: state = .ready
        default: state = .failed
        }
        announcesStateChanges = announces
        message = state == .paused ? "Saved recording paused. Resume or finish when ready." :
            (metadata.failureMessage ?? metadata.delivery?.detail ?? "Saved on this Mac.")
    }

    /// Audio tools operate only after the latest manual correction has reached durable storage.
    func flushForRecordingTools() async -> Bool {
        guard !reservesCapture, !isTransitioning, let handle else { return false }
        await editSaves[handle.takeID]?.value
        return self.handle == handle && !reservesCapture && !isTransitioning &&
            pendingEdits[handle.takeID] == nil
    }

    func audioSourceDidChange() {
        guard !reservesCapture, !isTransitioning, let handle else { return }
        pendingEdits[handle.takeID] = nil
        editLearningSources[handle.takeID] = nil
        restore(handle)
        message = "Audio version saved. Transcribe it to create a new current transcript. Earlier outputs remain in Versions."
    }

    /// Reprocessing saved audio stages a result in the editor, with no captured destination.
    func retranscribeSavedRecording() {
        guard !reservesCapture, !isTransitioning, let handle else { return }
        releaseTarget()
        stopExternalCorrectionObservation()
        clearCapturedContext()
        transformPreview=nil; longTransformPreview=nil; previewSource=nil
        state = .processing
        message = "Transcribing the selected audio on this Mac…"
        backend.dictationSetForegroundProcessing(handle, active: true)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.backend.dictationSetForegroundProcessing(handle, active: false) }
            do {
                await self.editSaves[handle.takeID]?.value
                try Task.checkCancellation()
                guard self.handle == handle, self.pendingEdits[handle.takeID] == nil else {
                    throw KeystormError.message("Save the current edit before transcribing this recording.")
                }
                let completed = try await self.backend.dictationComplete(handle)
                try Task.checkCancellation()
                guard self.handle == handle else { throw DictationTransformError.staleSource }
                self.revision = completed
                if let metadata = self.backend.dictationMetadata(handle) { self.loadOutputMetadata(metadata) }
                self.resultText = completed.text
                self.destinationLabel = "Copy after recording"
                self.wantsRecordingHUD = false
                self.message = "Transcript saved. Review, edit, transform, or copy it here."
                self.state = .ready
            } catch {
                self.message = error.localizedDescription
                self.settleFailure(.failed)
            }
        }
    }

    func prepareTransform(_ mode: DictationOutputMode) {
        guard state == .ready, !isTransitioning, let handle, let source = revision,
              !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stopExternalCorrectionObservation()
        wantsRecordingHUD = false
        transformPreview=nil; longTransformPreview=nil
        previewSource = nil
        isTransforming = true
        transformCancellable = true
        let generation = UUID()
        transformGeneration = generation
        message = "Preparing " + mode.displayTitle + " on this Mac…"
        backend.dictationSetForegroundProcessing(handle, active: true)
        transformTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.backend.dictationSetForegroundProcessing(handle, active: false)
                if self.transformGeneration == generation {
                    self.isTransforming = false
                    self.transformCancellable = false
                    self.transformTask = nil
                }
            }
            do {
                await self.editSaves[handle.takeID]?.value
                try Task.checkCancellation()
                guard self.handle == handle, self.revision?.id == source.id,
                      self.resultText.utf8.elementsEqual(source.text.utf8) else {
                    throw KeystormError.message("The source changed. Start a new preview from the current text.")
                }
                if source.text.utf8.count > DictationTransformPolicy.maxSourceUTF8 {
                    // Fail before any model load for modes that have no long, sectioned form.
                    guard LongDictationTransformService.supports(mode) else {
                        throw LongDictationTransformError.unsupportedMode
                    }
                    let result = try await self.backend.dictationLongTransform(handle, source: source, mode: mode)
                    try Task.checkCancellation()
                    guard self.transformGeneration == generation, self.handle == handle,
                          self.revision == source, self.resultText.utf8.elementsEqual(source.text.utf8),
                          result.sourceRevisionID == source.id, result.mode == mode,
                          result.sourceSHA256 == DictationTransformPolicy.sourceDigest(source.text) else {
                        throw DictationTransformError.staleSource
                    }
                    self.previewSource = source
                    self.longTransformPreview = result
                    self.message = "Section previews ready. Review all sections before applying; the original remains saved."
                } else {
                    let result = try await self.backend.dictationTransform(handle, source: source, mode: mode)
                    try Task.checkCancellation()
                    guard self.transformGeneration == generation, self.handle == handle,
                          self.revision?.id == source.id,
                          self.resultText.utf8.elementsEqual(source.text.utf8),
                          result.sourceRevisionID == source.id,
                          result.sourceSHA256 == DictationTransformPolicy.sourceDigest(source.text),
                          result.mode == mode else {
                        throw KeystormError.message("The source changed while generating. The saved text is unchanged.")
                    }
                    self.previewSource = source
                    self.transformPreview = result
                    self.message = "Preview ready. Review it before applying; your saved text is unchanged."
                }
            } catch is CancellationError {
                if self.transformGeneration == generation { self.message = "Preview cancelled. Your saved text is unchanged." }
            } catch {
                if self.transformGeneration == generation { self.message = error.localizedDescription }
            }
        }
    }

    func cancelTransform() {
        guard canCancelTransform else { return }
        transformTask?.cancel()
        message = "Cancelling the local preview…"
    }

    func discardTransformPreview() {
        guard !isTransforming else { return }
        transformPreview=nil; longTransformPreview=nil
        previewSource = nil
        message = "Preview dismissed. Your saved text is unchanged."
    }

    func applyTransformPreview() {
        guard state == .ready, !isTransitioning, let handle, let source = previewSource,
              hasTransformPreview, revision?.id == source.id,
              resultText.utf8.elementsEqual(source.text.utf8) else { return }
        stopExternalCorrectionObservation()
        isTransforming = true
        transformCancellable = false
        message = "Saving the reviewed output…"
        let shortResult = transformPreview
        let longResult = longTransformPreview
        transformTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isTransforming = false; self.transformTask = nil }
            do {
                await self.editSaves[handle.takeID]?.value
                let metadata: DictationRecordingMetadata
                if let longResult {
                    metadata = try await self.backend.dictationApplyLongTransform(handle, source: source, result: longResult)
                } else if let shortResult {
                    metadata = try await self.backend.dictationApplyTransform(handle, source: source, result: shortResult)
                } else { throw DictationTransformError.staleSource }
                if self.pendingEdits[handle.takeID]?.id == source.id {
                    self.pendingEdits[handle.takeID] = nil
                    self.editLearningSources[handle.takeID] = nil
                }
                self.loadOutputMetadata(metadata)
                self.revision = metadata.textRevision
                self.resultText = metadata.textRevision?.text ?? ""
                self.transformPreview=nil; self.longTransformPreview=nil
                self.previewSource = nil
                self.message = "Applied. The original and earlier versions are available in Versions."
            } catch { self.message = error.localizedDescription }
        }
    }

    func selectOutput(_ id: UUID) {
        guard state == .ready, !isTransitioning, let handle else { return }
        stopExternalCorrectionObservation()
        wantsRecordingHUD = false
        isTransforming = true
        transformCancellable = false
        message = "Restoring the saved version…"
        let pendingRevisionID = pendingEdits[handle.takeID]?.id
        transformTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isTransforming = false; self.transformTask = nil }
            do {
                await self.editSaves[handle.takeID]?.value
                let metadata = try await self.backend.dictationSelectOutput(handle, id: id)
                if self.pendingEdits[handle.takeID]?.id == pendingRevisionID {
                    self.pendingEdits[handle.takeID] = nil
                    self.editLearningSources[handle.takeID] = nil
                }
                self.loadOutputMetadata(metadata)
                self.revision = metadata.textRevision
                self.resultText = metadata.textRevision?.text ?? ""
                self.transformPreview=nil; self.longTransformPreview=nil
                self.previewSource = nil
                self.message = "Restored. All saved versions are kept."
            } catch { self.message = error.localizedDescription }
        }
    }

    private func loadOutputMetadata(_ metadata: DictationRecordingMetadata) {
        outputMode = metadata.outputMode
        outputVersions = metadata.outputHistory ?? []
        activeOutputID = metadata.activeOutputID
    }

    func copyResult() {
        guard state == .ready, !isTransitioning, let handle, let revision,
              resultText.utf8.elementsEqual(revision.text.utf8),
              !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stopExternalCorrectionObservation()
        transition = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.transition = false }
            do {
                // Save edits first so the clipboard never becomes the only copy.
                await self.editSaves[handle.takeID]?.value
                try await self.backend.dictationSave(handle, state: .ready, revision: revision, delivery: nil, failure: nil)
                if self.pendingEdits[handle.takeID]?.id == revision.id { self.pendingEdits[handle.takeID] = nil }
                try Task.checkCancellation()
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(revision.text, forType: .string) else {
                    throw KeystormError.message("The clipboard could not be written. Your text is saved locally.")
                }
                self.revision = revision
                self.message = "Copied. Your edited text is saved locally."
                try await self.backend.dictationSave(handle, state: .ready, revision: revision,
                    delivery: DictationDelivery(requestID: UUID(), textRevisionID: revision.id, targetLabel: "Clipboard", state: .copied), failure: nil)
            } catch { self.message = error.localizedDescription }
        }
    }

    /// Cancel never deletes acknowledged audio and drops the insertion capability immediately.
    func cancel() {
        guard canCancel else { return }
        stopExternalCorrectionObservation()
        cancelling = true
        announcesCancellation = true
        clearCapturedContext()
        releaseTarget()
        destinationLabel = "Copy after recording"
        message = "Cancelling. Keeping saved audio…"
        let previous = operation
        previous?.cancel()
        let existingHandle = handle
        let interruptProcessing = state == .processing && !committingOutput
        operation = Task { [weak self] in
            guard let self else { return }
            var failure: String?
            if interruptProcessing, let existingHandle {
                do { try await self.backend.dictationCancel(existingHandle) }
                catch { failure = error.localizedDescription }
            }
            await previous?.value
            if !interruptProcessing || existingHandle == nil, let startedHandle = self.handle {
                do { try await self.backend.dictationCancel(startedHandle) }
                catch { failure = error.localizedDescription }
            }
            if let handle = self.handle {
                do { try await self.backend.dictationSave(handle, state: .cancelled, revision: nil, delivery: nil, failure: failure) }
                catch { failure = error.localizedDescription }
                if let metadata = self.backend.dictationMetadata(handle), let saved = metadata.textRevision {
                    self.loadOutputMetadata(metadata)
                    self.revision = saved
                    self.resultText = saved.text
                }
            }
            self.transition = false
            self.cancelling = false
            if failure != nil { self.state = .recording }
            else { self.state = self.revision == nil ? .idle : .ready }
            self.message = failure.map { "Cancellation needs attention: " + $0 } ??
                "Cancelled. Saved audio is kept in History; nothing was inserted."
        }
    }

    /// Consume only the selected recording's backend status, outside observation tracking.
    func reconcileCaptureStatus(_ status: DictationCaptureStatus?) {
        guard let status, !cancelling, !transition,
              state == .recording || state == .paused || state == .processing else { return }
        switch status {
        case .recording:
            // A processing operation owns its transitions, never a clock/metadata observer.
            if state == .paused { state = .recording; message = "Recording locally." }
        case .paused:
            if state == .recording {
                releaseTarget()
                destinationLabel = "Copy after recording"
                state = .paused
                message = "Recording stopped. Saved audio is paused; resume explicitly."
            }
        case .interrupted(let reason):
            clearCapturedContext()
            releaseTarget()
            destinationLabel = "Copy after recording"
            let detail = "Recording interrupted: " + reason + " Saved audio is kept; automatic insertion is disabled."
            captureInterruption = detail
            // This observer re-runs without user action; reassigning the same text would be a new status.
            if message != detail { message = detail }
            if state == .processing {
                // Keep the transition owned until its cancelled task has drained.
                operation?.cancel()
            } else {
                state = .paused
            }
        }
    }

    func cancelForShutdown() {
        // The app is quitting; cancelled operations settling into failed or ready must not speak.
        announcesStateChanges = false
        stopExternalCorrectionObservation()
        clearCapturedContext()
        transformTask?.cancel()
        releaseTarget()
        operation?.cancel()
    }

    func requestAccessibilityPermission() { deliveryService.requestAccessibilityPermission() }
    func openAccessibilitySettings() { deliveryService.openAccessibilitySettings() }

    /// Explicit test/termination join; UI actions never overlap another transition.
    func waitUntilSettled() async {
        await operation?.value
        await transformTask?.value
        await correctionSubmission?.value
        let pendingEdits = Array(editSaves.values)
        for save in pendingEdits { await save.value }
    }

    private func saveEditedResult() {
        guard state == .ready, let handle, var revision,
              !resultText.utf8.elementsEqual(revision.text.utf8) else { return }
        stopExternalCorrectionObservation()
        if editLearningSources[handle.takeID] == nil { editLearningSources[handle.takeID] = revision }
        let learningSource = editLearningSources[handle.takeID] ?? revision
        revision.id = UUID()
        revision.text = resultText
        revision.createdAt = Date()
        self.revision = revision
        activeOutputID = nil
        pendingEdits[handle.takeID] = revision
        editSaves[handle.takeID]?.cancel()
        let token = UUID()
        editSaveTokens[handle.takeID] = token
        editSaves[handle.takeID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.editSaveTokens[handle.takeID] == token {
                    self.editSaves[handle.takeID] = nil
                    self.editSaveTokens[handle.takeID] = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await self.backend.dictationSave(handle, state: .ready, revision: revision, delivery: nil, failure: nil)
                if self.pendingEdits[handle.takeID]?.id == revision.id {
                    self.pendingEdits[handle.takeID] = nil
                    self.editLearningSources[handle.takeID] = nil
                    await self.backend.dictationUserEdited(handle, source: learningSource, edited: revision)
                }
            } catch is CancellationError { }
            catch {
                if self.handle == handle { self.message = "Your edit could not be saved: " + error.localizedDescription }
            }
        }
    }
}
