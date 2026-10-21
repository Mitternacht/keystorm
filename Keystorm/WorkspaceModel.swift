import AVFoundation
import CryptoKit
import Foundation
import Observation
import os

/// Coordinates durable capture and a single local inference phase. Construction does no I/O.
@MainActor
@Observable
final class WorkspaceModel {
    private(set) var sessions: [VoiceSession] = [] {
        didSet {
            reviewIssueCache = nil; pendingTakeCache = nil
            activeSessionCache = nil; trashedSessionCache = nil; recordingRowCache = [:]
        }
    }
    @ObservationIgnored private var reviewIssueCache: (sessionID: UUID, issues: [BriefReviewIssue])?
    @ObservationIgnored private var pendingTakeCache: (sessionID: UUID, takes: [BriefTake])?
    @ObservationIgnored private var activeSessionCache: [VoiceSession]?
    @ObservationIgnored private var trashedSessionCache: [VoiceSession]?
    @ObservationIgnored private var recordingRowCache: [UUID: [RecordingRow]] = [:]
    @ObservationIgnored private let takePlayer = RecordingPlaybackController()
    private(set) var isEditingRecording = false
    var activeSessions: [VoiceSession] {
        _ = sessions
        if let activeSessionCache { return activeSessionCache }
        let result = sessions.filter { $0.trashedAt == nil }
        activeSessionCache = result
        return result
    }
    var trashedSessions: [VoiceSession] {
        _ = sessions
        if let trashedSessionCache { return trashedSessionCache }
        let result = sessions.filter { $0.trashedAt != nil }
        trashedSessionCache = result
        return result
    }
    var recordings: [RecordingRow] {
        guard let selectedSession, selectedSession.trashedAt == nil else { return [] }
        return recordingRows(in: selectedSession).filter { $0.take.trashedAt == nil }
    }
    var trashedRecordings: [RecordingRow] {
        sessions.flatMap { session in
            recordingRows(in: session).filter { $0.take.trashedAt != nil }
        }
    }
    private var selectedSessionSelection: UUID?
    var selectedSessionID: UUID? {
        get { selectedSessionSelection }
        set {
            guard selectedSessionSelection != newValue, !isRecording, !isCaptureTransitioning,
                  !isEditingRecording else { return }
            if let newValue, sessions.first(where: { $0.id == newValue })?.trashedAt != nil { return }
            let previous = selectedSessionSelection
            selectedSessionSelection = newValue
            selectedBlockIDs = []
            pendingBriefIssue = nil
            if let previous { scheduleBriefSave(previous, immediate: true) }
            if let id = newValue { ensureBrief(id) }
        }
    }
    private(set) var dictationHistoryEntries: [DictationHistoryHeader] = []
    private(set) var historyHasMore = false
    private(set) var isLoadingHistory = false
    private(set) var isLoadingHistorySelection = false
    private(set) var historyError: String?
    private(set) var historyMaintenanceAvailable = false
    private(set) var isCheckingHistory = false
    private(set) var historyPendingRepairCount = 0
    @ObservationIgnored private var historyCursor: DictationHistoryCursor?
    @ObservationIgnored private var historyPageToken = UUID()
    @ObservationIgnored private var historyRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var historySelectionTask: Task<DictationSessionHydration, Error>?
    @ObservationIgnored private var historySelectionToken: UUID?
    @ObservationIgnored private var historyMaintenanceCursor: String?
    @ObservationIgnored private var hydratedUseOrder: [UUID] = []
    @ObservationIgnored private var legacyLibraryLoaded = false
    private(set) var isLoadingLegacyLibrary = false
    private(set) var isBusy = false
    private(set) var activity = "Ready"
    var error: String?
    private(set) var recoveryMessages: [String] = []
    private(set) var dictionary: [DictionaryEntry] = []
    private(set) var learningDictionary: LearningDictionaryController?
    @ObservationIgnored private var foregroundDictationTakes: Set<UUID> = []
    private(set) var installedModelIDs: Set<String> = []
    private(set) var installProgress: [String: Double] = [:]
    var selectedSpeechModelID = ModelCatalog.primarySpeech.id
    var detail: DetailLevel = .standard
    private(set) var memoryMeasurements: [String: UInt64] = [:]
    var selectedSectionKind: BriefSectionKind = .changes
    var selectedBlockIDs: [UUID] = []
    var selectedBlockID: UUID? {
        get { selectedBlockIDs.first }
        set { selectedBlockIDs = newValue.map { [$0] } ?? [] }
    }
    var captureIntent: CaptureIntent = .addMaterial
    private(set) var pendingBriefIssue: String?
    private(set) var performanceMeasurements: [RuntimeMeasurement] = []
    private var metricGeneration: UInt64 = 0
    @ObservationIgnored private var metricSamples = RuntimeMetricSamples()
    @ObservationIgnored private var metricSummaryCache: [RuntimeMetricSummary]?
    var performanceSummaries: [RuntimeMetricSummary] {
        _ = metricGeneration
        if let metricSummaryCache { return metricSummaryCache }
        let summaries = metricSamples.summaries
        metricSummaryCache = summaries
        return summaries
    }
    private(set) var recordingHUDSnapshot: RecordingHUDSnapshot?
    @ObservationIgnored private var recordingHUDSession: RecordingHUDSession?
    @ObservationIgnored private var recordingRequestStartedAt: ContinuousClock.Instant?
    // Reads only the existing capture clock; HUD ticks never traverse the session history.
    var recordingHUDElapsed: Double {
        isRecording ? recordingTakeElapsedBeforeInterval + capture.elapsed : recordingHUDPausedElapsed
    }
    private var recordingTakeElapsedBeforeInterval: Double = 0
    private var recordingHUDPausedElapsed: Double = 0

    @ObservationIgnored private var briefSaveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var dirtyBriefSessionIDs: Set<UUID> = []
    @ObservationIgnored private var typingBlockID: UUID?
    @ObservationIgnored private var typingLastChanged: Date?
    @ObservationIgnored private var speechIdleRelease: Task<Void, Never>?

    @ObservationIgnored private let storageRoot: URL?
    @ObservationIgnored private(set) var store: SessionStore?
    @ObservationIgnored private var inference: InferenceWorkerClient?
    private let capture = AudioCapture()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var workToken: UUID?
    @ObservationIgnored private var workKind: WorkspaceWorkKind = .general
    @ObservationIgnored private var textPrewarm: TextPrewarmController?
    /// Set by a dictation Start or Resume just before capture begins, then consumed by it.
    @ObservationIgnored private var pendingCaptureQuickMode: DictationQuickMode?
    @ObservationIgnored private var commitTail: Task<Void, Never>?
    @ObservationIgnored private var persistenceTail: Task<Void, Error>?
    @ObservationIgnored private var dictionaryTail: Task<Void, Error>?
    @ObservationIgnored private var recordingSessionID: UUID?
    @ObservationIgnored private var recordingStartTime: Double = 0
    @ObservationIgnored private var captureEpoch: UUID?
    @ObservationIgnored private var tailTranscriptionToken: UUID?
    @ObservationIgnored private var speechPhaseReady = true
    @ObservationIgnored private var livePreviewTask: Task<Void, Never>?
    @ObservationIgnored private var progressiveTranscriptionRequested = false
    @ObservationIgnored private var phaseTeardownTail: Task<Void, Never>?
    @ObservationIgnored private var installTokens: [String: UUID] = [:]
    @ObservationIgnored private var captureMailbox: CommittedAudioMailbox?
    @ObservationIgnored private var initializing = false
    private var changingCapture = false
    @ObservationIgnored private var changingSession = false
    private var captureStartInProgress = false
    @ObservationIgnored private var captureStartWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var capturePauseTask: Task<Void, Never>?
    @ObservationIgnored private var terminating = false

    var selectedSession: VoiceSession? { sessions.first { $0.id == selectedSessionID && $0.trashedAt == nil } }
    var currentBrief: BriefDocument? { selectedSession?.brief }
    var pendingBriefProposal: BriefProposal? { currentBrief?.pendingProposal }
    var briefReviewIssues: [BriefReviewIssue] {
        guard let session = selectedSession, let brief = session.brief else { return [] }
        if let cached = reviewIssueCache, cached.sessionID == session.id { return cached.issues }
        let issues = brief.reviewIssues(session: session)
        reviewIssueCache = (session.id, issues)
        return issues
    }
    var pendingBriefTakes: [BriefTake] {
        guard let session = selectedSession, let brief = session.brief else { return [] }
        if let cached = pendingTakeCache, cached.sessionID == session.id { return cached.takes }
        let takes = brief.takes.filter { $0.trashedAt == nil && [.recording, .paused, .pending, .failed].contains($0.status) }
        pendingTakeCache = (session.id, takes)
        return takes
    }
    var currentDraft: PromptRevision? { selectedSession?.drafts.last { $0.detail == detail } }
    #if DEBUG
    var debugAudioSourceStatus: String? {
        if let status = capture.debugAudioSourceStatus { return status }
        guard let configuration = try? DebugAudioValidationConfiguration.configuration() else { return nil }
        return "File validation · " + configuration.audio.lastPathComponent + " · Microphone disabled"
    }
    #endif
    var isRecording: Bool { capture.isRecording }
    var isCaptureTransitioning: Bool { changingCapture || captureStartInProgress || capture.isTransitioning }
    var elapsed: Double { isRecording ? recordingStartTime + capture.elapsed : (selectedSession?.recordedDuration ?? 0) }

    @ObservationIgnored private let modelDirectoryOverride: URL?
    @ObservationIgnored private let textPrewarmLoader: TextPrewarmController.Prewarm?
    /// `textPrewarmLoader` replaces the installed-model warm-up, so tests can use a fake.
    init(root: URL? = nil, modelDirectory: URL? = nil, textPrewarmLoader: TextPrewarmController.Prewarm? = nil) {
        storageRoot = root
        modelDirectoryOverride = modelDirectory
        self.textPrewarmLoader = textPrewarmLoader
    }

    /// Default startup reads indexed headers only; full loading is explicit legacy maintenance.
    func initialize(loadLibrary: Bool = false) async {
        guard store == nil, !initializing else { return }
        let initializedAt = ContinuousClock.now
        defer { recordPerformance(kind: "workspace.initialize", milliseconds: initializedAt.duration(to: .now).milliseconds) }
        initializing = true
        isBusy = true
        activity = "Checking saved sessions"
        defer {
            initializing = false; isBusy = false; activity = "Ready"
            if !terminating, !isRecording, foregroundDictationTakes.isEmpty { learningDictionary?.drainPending() }
        }
        do {
            let base = try storageRoot ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Keystorm", isDirectory: true)
            let localStore = try SessionStore(root: base)
            let models = modelDirectoryOverride ?? base.appendingPathComponent("Models", isDirectory: true)
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            let localInference = InferenceWorkerClient(modelDirectory: models)
            dictionary = try await localStore.loadDictionary()
            do {
                let learning = try LearningRepository(url: base.appendingPathComponent("Learning/dictionary-v1.json"))
                let controller = LearningDictionaryController(repository: learning) { [weak self] evidence in
                    guard let self else { throw CancellationError() }
                    return try await self.classifyLearningCorrection(evidence)
                }
                learningDictionary = controller
                await controller.refresh()
            } catch {
                recoveryMessages.append("The learning dictionary is unavailable: " + error.localizedDescription)
            }
            for model in ModelCatalog.models where model.installable {
                if await localInference.isInstalled(model) { installedModelIDs.insert(model.id) }
            }
            store = localStore
            inference = localInference
            if let textPrewarmLoader {
                textPrewarm = TextPrewarmController(prewarm: textPrewarmLoader)
            } else {
                textPrewarm = TextPrewarmController { [localInference] in await localInference.prewarmText() }
            }
            if loadLibrary {
                try await loadLegacySessions(from: localStore)
                legacyLibraryLoaded = true
                selectedSessionID = activeSessions.first?.id
                if activeSessions.isEmpty { await newSession() }
            } else {
                do {
                    let startup = try await localStore.prepareLazyStartup()
                    recoveryMessages.append(contentsOf: startup.reports)
                    applyHistoryPage(startup.page, replacing: true)
                    historyPendingRepairCount = startup.pendingRepairCount
                    historyMaintenanceAvailable = startup.maintenanceAvailable
                    if startup.totalSessionCount == 0 { await newSession() }
                } catch {
                    historyError = error.localizedDescription
                    historyMaintenanceAvailable = true
                    recoveryMessages.append("Saved source files are preserved. Use Check library to retry history recovery.")
                }
            }
        } catch { self.error = error.localizedDescription }
    }


    private func loadLegacySessions(from localStore: SessionStore) async throws {
            recoveryMessages.append(contentsOf: try await localStore.recover())
            sessions = try await localStore.loadSessions()
            for index in sessions.indices {
                if sessions[index].materializeLegacyRecordings() { try await localStore.save(sessions[index]) }
                guard var brief = sessions[index].brief else { continue }
                let interrupted = brief.takes.indices.filter { brief.takes[$0].trashedAt == nil && brief.takes[$0].status == .recording }
                guard !interrupted.isEmpty else { continue }
                for takeIndex in interrupted { brief.takes[takeIndex].status = .paused }
                brief.reviewedRevisionID = nil
                sessions[index].brief = brief
                if sessions[index].dictation != nil {
                    sessions[index].materializeDictationMetadata()
                    for metadataIndex in sessions[index].dictation!.recordings.indices
                    where sessions[index].dictation!.recordings[metadataIndex].state == .recording {
                        sessions[index].dictation!.recordings[metadataIndex].state = .paused
                    }
                }
                sessions[index].updatedAt = Date()
                try await localStore.save(sessions[index])
                recoveryMessages.append("\(sessions[index].title): interrupted takes are paused; resume explicitly or finish the take.")
            }
    }

    func loadLegacyLibrary() async -> Bool {
        guard let store, !terminating, !isRecording, !isCaptureTransitioning,
              !isEditingRecording, !changingSession else { return false }
        cancelHistorySelection()
        if learningDictionary?.isClassifying == true {
            learningDictionary?.cancelPendingClassification()
            await cancelProcessing()
            await learningDictionary?.waitUntilSettled()
        }
        await flushBriefEdits()
        guard !isBusy, !isRecording, !isCaptureTransitioning, !terminating else { return false }
        changingSession = true
        isLoadingLegacyLibrary = true
        isBusy = true
        defer { changingSession = false; isLoadingLegacyLibrary = false; isBusy = workTask != nil }
        do {
            try await loadLegacySessions(from: store)
            legacyLibraryLoaded = true
            if selectedSession == nil { selectedSessionID = activeSessions.first?.id }
            if activeSessions.isEmpty {
                // The legacy editor needs one editable document. Creation happens after unlocking.
                changingSession = false
                await newSession()
                changingSession = true
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func leaveLegacyLibrary() async {
        await flushBriefEdits()
        legacyLibraryLoaded = false
        pruneHydratedSessions()
        await refreshDictationHistory()
    }

    func refreshDictationHistory() async {
        guard let store, !terminating else { return }
        let token = UUID()
        historyPageToken = token
        isLoadingHistory = true
        defer { if historyPageToken == token { isLoadingHistory = false } }
        do {
            let requestedCount = max(50, dictationHistoryEntries.count)
            var entries: [DictationHistoryHeader] = []
            var cursor: DictationHistoryCursor?
            var generation: Int64?
            repeat {
                let page = try await store.historyPage(limit: 50, before: cursor)
                guard historyPageToken == token, !terminating else { return }
                if page.invalidated { scheduleHistoryRefresh(); return }
                if let generation, generation != page.generation { scheduleHistoryRefresh(); return }
                generation = page.generation
                entries.append(contentsOf: page.entries)
                cursor = page.nextCursor
            } while cursor != nil && entries.count < requestedCount
            dictationHistoryEntries = entries
            historyCursor = cursor
            historyHasMore = cursor != nil
            historyError = nil
        } catch { if historyPageToken == token { historyError = error.localizedDescription } }
    }

    func loadMoreDictationHistory() async {
        guard let store, let cursor = historyCursor, !isLoadingHistory, !terminating else { return }
        let token = UUID()
        historyPageToken = token
        isLoadingHistory = true
        defer { if historyPageToken == token { isLoadingHistory = false } }
        do {
            let page = try await store.historyPage(limit: 50, before: cursor)
            guard historyPageToken == token, !terminating else { return }
            if page.invalidated {
                isLoadingHistory = false
                await refreshDictationHistory()
            } else { applyHistoryPage(page, replacing: false) }
        } catch { if historyPageToken == token { historyError = error.localizedDescription } }
    }

    private func applyHistoryPage(_ page: DictationHistoryPage, replacing: Bool) {
        if replacing { dictationHistoryEntries = page.entries }
        else {
            let known = Set(dictationHistoryEntries.map(\.stableID))
            dictationHistoryEntries.append(contentsOf: page.entries.filter { !known.contains($0.stableID) })
        }
        historyCursor = page.nextCursor
        historyHasMore = page.nextCursor != nil
        historyError = nil
    }

    private func scheduleHistoryRefresh() {
        guard store != nil, !terminating else { return }
        historyRefreshTask?.cancel()
        historyRefreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.refreshDictationHistory()
        }
    }

    func checkHistoryForRecovery() async {
        guard let store, !isCheckingHistory, !isRecording, !isCaptureTransitioning,
              !isEditingRecording, !terminating else { return }
        isCheckingHistory = true
        defer { isCheckingHistory = false }
        do {
            let result = try await store.maintainHistory(limit: 16, afterDirectory: historyMaintenanceCursor)
            recoveryMessages.append(contentsOf: result.reports)
            historyMaintenanceCursor = result.nextDirectory
            historyMaintenanceAvailable = result.nextDirectory != nil
            let startup = try await store.prepareLazyStartup()
            historyPendingRepairCount = startup.pendingRepairCount
            await refreshDictationHistory()
        } catch { historyError = error.localizedDescription }
    }

    func cancelHistorySelection() {
        historySelectionToken = nil
        historySelectionTask?.cancel()
        historySelectionTask = nil
        isLoadingHistorySelection = false
    }

    func selectHistoryRecording(_ handle: DictationRecordingHandle) async throws {
        try Task.checkCancellation()
        if learningDictionary?.isClassifying == true {
            learningDictionary?.cancelPendingClassification()
            await cancelProcessing()
            await learningDictionary?.waitUntilSettled()
        }
        guard let store, !terminating, !isRecording, !isCaptureTransitioning,
              !isEditingRecording, !changingSession, !isBusy else {
            throw KeystormError.message("Finish the current operation before opening another recording.")
        }
        try Task.checkCancellation()
        cancelHistorySelection()
        let token = UUID()
        historySelectionToken = token
        isLoadingHistorySelection = true
        defer {
            if historySelectionToken == token {
                historySelectionTask = nil
                historySelectionToken = nil
                isLoadingHistorySelection = false
            }
        }
        if session(handle.sessionID) == nil {
            let hydration = Task { try await store.hydrateSession(handle.sessionID) }
            historySelectionTask = hydration
            let loaded = try await withTaskCancellationHandler {
                try await hydration.value
            } onCancel: {
                hydration.cancel()
            }
            guard historySelectionToken == token, !Task.isCancelled, !terminating,
                  !isRecording, !isCaptureTransitioning, !isEditingRecording, !changingSession, !isBusy else {
                throw CancellationError()
            }
            guard loaded.session.trashedAt == nil,
                  loaded.session.brief?.takes.contains(where: { $0.id == handle.takeID && $0.trashedAt == nil }) == true,
                  loaded.session.dictation?.recordings.contains(where: { $0.id == handle.takeID }) == true else {
                throw KeystormError.message("This saved recording is no longer available.")
            }
            // A delayed save may have rehydrated and updated this owner while recovery ran.
            if session(handle.sessionID) == nil { sessions.append(loaded.session) }
            recoveryMessages.append(contentsOf: loaded.reports)
        }
        try Task.checkCancellation()
        guard historySelectionToken == token, let snapshot = session(handle.sessionID),
              snapshot.trashedAt == nil,
              snapshot.brief?.takes.contains(where: { $0.id == handle.takeID && $0.trashedAt == nil }) == true,
              dictationMetadata(handle) != nil else {
            throw KeystormError.message("This saved recording is no longer available.")
        }
        selectedSessionID = handle.sessionID
        hydratedUseOrder.removeAll { $0 == handle.sessionID }
        hydratedUseOrder.append(handle.sessionID)
        pruneHydratedSessions()
        scheduleHistoryRefresh()
    }

    private func ensureSessionLoaded(_ id: UUID) async throws {
        if session(id) != nil { return }
        guard let store, !terminating else { throw KeystormError.message("The workspace is not ready.") }
        let loaded = try await store.hydrateSession(id)
        try Task.checkCancellation()
        if session(id) == nil { sessions.append(loaded.session) }
        recoveryMessages.append(contentsOf: loaded.reports)
        hydratedUseOrder.removeAll { $0 == id }
        hydratedUseOrder.append(id)
        pruneHydratedSessions(keeping: id)
    }

    private func pruneHydratedSessions(keeping id: UUID? = nil) {
        guard !legacyLibraryLoaded, !isEditingRecording, !changingSession else { return }
        var pinned = dirtyBriefSessionIDs
        for value in [selectedSessionID, recordingSessionID, id] { if let value { pinned.insert(value) } }
        if workTask != nil, let selectedSessionID { pinned.insert(selectedSessionID) }
        let recent = hydratedUseOrder.reversed().filter { !pinned.contains($0) }.prefix(max(0, 2 - pinned.count))
        let retained = pinned.union(recent)
        sessions.removeAll { !retained.contains($0.id) }
        hydratedUseOrder.removeAll { !retained.contains($0) }
    }

    func newSession() async {
        cancelHistorySelection()
        guard let store, !terminating, !isCaptureTransitioning, !changingSession else { return }
        changingSession = true
        defer { changingSession = false; pruneHydratedSessions() }
        if isRecording { await pauseRecording() }
        await flushBriefEdits()
        await cancelProcessing()
        var session = VoiceSession()
        session.brief = BriefDocument()
        session.title = Date().formatted(date: .abbreviated, time: .shortened)
        do {
            try await store.save(session)
            sessions.insert(session, at: 0)
            selectedSessionID = session.id
            hydratedUseOrder.append(session.id)
            pruneHydratedSessions()
            scheduleHistoryRefresh()
        } catch { self.error = error.localizedDescription }
    }

    var openTake: BriefTake? {
        selectedSession?.brief?.takes.last { $0.trashedAt == nil && [.recording, .paused].contains($0.status) }
    }
    var hasOpenTake: Bool { openTake != nil }
    var canResumeTake: Bool {
        !isRecording && !isCaptureTransitioning && openTake?.status == .paused && openTake?.activeAudioRevisionID == nil
    }
    var takeElapsed: Double {
        if isRecording { return recordingTakeElapsedBeforeInterval + capture.elapsed }
        guard let take = openTake, let session = selectedSession else { return 0 }
        return Self.recordedDuration(of: take, in: session)
    }

    /// The default recording action resumes the pinned take rather than silently creating another.
    func startRecording() async {
        if hasOpenTake { await resumeRecording() }
        else { await startCapture(resuming: nil) }
    }

    func resumeRecording() async {
        guard canResumeTake, let take = openTake else { return }
        await startCapture(resuming: take.id)
    }

    func startNewTake(intent: CaptureIntent? = nil) async {
        guard !isCaptureTransitioning, !changingSession, !terminating else { return }
        if isRecording { await pauseRecording() }
        if hasOpenTake { await finishTake() }
        guard !hasOpenTake, !isRecording else { return }
        if let intent { captureIntent = intent }
        await startCapture(resuming: nil)
    }

    /// Finishing makes all intervals eligible for the existing deliberate proposal flow.
    func finishTake() async {
        guard !isCaptureTransitioning, !changingSession, !terminating else { return }
        if isRecording { await pauseRecording() }
        guard !isRecording, !isCaptureTransitioning, let id = selectedSessionID, let take = openTake else { return }
        changingCapture = true
        // Work that survived Pause (a live request or a text prewarm) may end during this
        // transition and leave isBusy set; recompute it, as the other capture transitions do.
        // A session change or recording edit that began meanwhile keeps its own isBusy.
        defer { changingCapture = false; if !changingSession { isBusy = workTask != nil } }
        do {
            try await mutate(id) { session in
                guard let index = session.brief?.takes.firstIndex(where: { $0.id == take.id && $0.trashedAt == nil }),
                      session.brief?.takes[index].status == .paused else { return }
                session.brief?.takes[index].status = .pending
                session.brief?.reviewedRevisionID = nil
            }
            if recordingHUDSession?.sessionID == id {
                recordingHUDSession?.finish()
                recordingHUDSnapshot = recordingHUDSession?.snapshot
            }
        } catch { self.error = error.localizedDescription }
    }

    static func recordedDuration(of take: BriefTake, in session: VoiceSession) -> Double {
        let intervals = Set(take.captureIntervalIDs)
        return session.segments.lazy.filter { intervals.contains($0.intervalID) }.reduce(0) { $0 + $1.duration }
    }

    /// One durable transition owns each microphone interval. Selection changes cannot retarget a paused take.
    @discardableResult
    static func beginCaptureInterval(in session: inout VoiceSession, resuming takeID: UUID?, intervalID: UUID,
                                     intent: CaptureIntent, targetSection: BriefSectionKind,
                                     selectedBlockIDs: [UUID]) throws -> BriefTake {
        var brief = session.brief ?? BriefDocument.migrating(session: session)
        let index: Int
        if let takeID {
            guard let existing = brief.takes.firstIndex(where: { $0.id == takeID && $0.trashedAt == nil }),
                  brief.takes[existing].status == .paused, brief.takes[existing].activeAudioRevisionID == nil else {
                throw KeystormError.message("Only an unfinished original recording can resume. Start a new take instead.")
            }
            index = existing
            if !brief.takes[index].captureIntervalIDs.contains(intervalID) { brief.takes[index].intervalIDs.append(intervalID) }
            brief.takes[index].status = .recording
        } else {
            guard !brief.takes.contains(where: { $0.trashedAt == nil && [.recording, .paused].contains($0.status) }) else {
                throw KeystormError.message("Finish the paused take before starting another.")
            }
            brief.takes.append(BriefTake(intervalID: intervalID, intent: intent, targetSection: targetSection,
                expectedRevision: brief.revisionID, selectedBlockIDs: selectedBlockIDs, status: .recording))
            index = brief.takes.count - 1
        }
        let take = brief.takes[index]
        brief.reviewedRevisionID = nil
        session.brief = brief
        session.status = .recording
        session.intervals.append(CaptureInterval(id: intervalID))
        session.invalidateDerivedWork()
        return take
    }

    private func startCapture(resuming takeID: UUID?) async {
        // Only a dictation Start or Resume names its Finish mode. Consume it before any early return.
        let finishMode = pendingCaptureQuickMode
        pendingCaptureQuickMode = nil
        learningDictionary?.cancelPendingClassification()
        guard !isRecording, !isCaptureTransitioning, !changingSession, !terminating, let id = selectedSessionID, let store, let inference else { return }
        captureStartInProgress = true
        livePreviewTask?.cancel()
        livePreviewTask = nil
        progressiveTranscriptionRequested = false
        tailTranscriptionToken = nil
        defer {
            captureStartInProgress = false
            let waiters = captureStartWaiters
            captureStartWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        let requestedAt = ContinuousClock.now
        recordingRequestStartedAt = requestedAt
        speechIdleRelease?.cancel()
        speechIdleRelease = nil
        let epoch = UUID()
        captureEpoch = epoch
        textPrewarm?.arm(epoch: epoch, mode: finishMode ?? .verbatim,
            textModelInstalled: installedModelIDs.contains(ModelCatalog.primaryText.id))
        speechPhaseReady = false
        let previousWork = workTask
        previousWork?.cancel()
        let previousTeardown = phaseTeardownTail
        let teardown = Task {
            await previousTeardown?.value
            await previousWork?.value
            if previousWork != nil { await inference.releaseText() }
            else { await inference.finishTextJob() }
        }
        phaseTeardownTail = teardown
        changingCapture = true
        isBusy = true
        defer {
            if captureEpoch == epoch {
                changingCapture = false
                isBusy = workTask != nil
                if isRecording { activity = "Recording locally"; scheduleProgressiveTranscription(id) }
            }
        }
        stopPlayback()
        guard let snapshot = session(id) else { return }
        let intervalID = UUID()
        recordingTakeElapsedBeforeInterval = snapshot.brief?.takes.first(where: { $0.id == takeID })
            .map { Self.recordedDuration(of: $0, in: snapshot) } ?? 0
        var startedTake: BriefTake?
        let mailbox = CommittedAudioMailbox()
        captureMailbox = mailbox
        recordingSessionID = id
        recordingStartTime = snapshot.recordedDuration
        do {
            // Persist the logical session before the microphone can produce any audio.
            try await mutate(id) { session in
                startedTake = try Self.beginCaptureInterval(in: &session, resuming: takeID, intervalID: intervalID,
                    intent: self.captureIntent, targetSection: self.selectedSectionKind, selectedBlockIDs: self.selectedBlockIDs)
            }
            guard let take = startedTake, !terminating else { throw CancellationError() }
            let directory = try await store.audioDirectory(id)
            guard !terminating else { throw CancellationError() }
            let reference = WorkspaceReference(self)
            let interval = try await capture.start(directory: directory, startTime: snapshot.recordedDuration, intervalID: intervalID,
                enableLivePreview: installedModelIDs.contains(selectedSpeechModelID),
                onCommit: { [reference, mailbox] segment in
                    mailbox.append(segment)
                    Task { @MainActor in reference.value?.enqueueCommits(mailbox, sessionID: id) }
                }, onFailure: { [reference] message in
                    Task { @MainActor in await reference.value?.captureFailed(message, sessionID: id, intervalID: intervalID, epoch: epoch) }
                })
            guard !terminating else {
                try await capture.pause()
                await flushCommits(mailbox, sessionID: id)
                throw CancellationError()
            }
            recordingHUDSession = RecordingHUDSession(sessionID: id, intervalID: intervalID,
                title: "\(take.intent == .addMaterial ? "Add material" : "Edit brief") · \(take.targetSection.title)",
                hasSpeechModel: installedModelIDs.contains(selectedSpeechModelID), takeID: take.id)
            refreshRecordingHUDCoverage(sessionID: id)
            recordPerformance(kind: "capture.engineStart", milliseconds: requestedAt.duration(to: .now).milliseconds)
            try await mutate(id) { session in
                if let index = session.intervals.firstIndex(where: { $0.id == intervalID }) { session.intervals[index] = interval }
                if !self.capture.isRecording { session.status = .interrupted }
            }
            // Durable capture runs while cancelled inference drains. Pause remains available.
            changingCapture = false
            isBusy = workTask != nil
            activity = "Recording locally; finishing previous model phase"
            // Starting and stopping the microphone must not wait for model teardown.
            // Only progressive inference waits for the previous process/phase to exit.
            Task { @MainActor [weak self] in
                await teardown.value
                guard let self else { return }
                if self.captureEpoch == epoch { self.phaseTeardownTail = nil }
                guard self.captureEpoch == epoch, self.recordingSessionID == id,
                      self.capture.isRecording, !self.terminating else { return }
                let memory = await inference.memorySnapshot()
                guard self.captureEpoch == epoch, self.recordingSessionID == id,
                      self.capture.isRecording, !self.terminating else { return }
                self.memoryMeasurements = memory
                self.speechPhaseReady = true
                self.startLiveTranscription(sessionID: id, intervalID: intervalID, epoch: epoch)
            }
        } catch {
            self.error = error.localizedDescription
            if capture.isRecording { try? await capture.pause() }
            await flushCommits(mailbox, sessionID: id)
            try? await mutate(id) { session in
                session.status = .interrupted
                if let index = session.intervals.firstIndex(where: { $0.id == intervalID }) { session.intervals[index].endedAt = Date() }
                session.gaps.append(SessionGap(reason: "Recording could not continue: \(error.localizedDescription)"))
                if var brief = session.brief {
                    for index in brief.takes.indices where brief.takes[index].captureIntervalIDs.contains(intervalID) {
                        brief.takes[index].status = .paused
                    }
                    session.brief = brief
                }
            }
            recordingSessionID = nil
            captureMailbox = nil
            await teardown.value
            if captureEpoch == epoch { phaseTeardownTail = nil }
        }
    }

    func pauseRecording() async {
        if let capturePauseTask { await capturePauseTask.value; return }
        guard !changingCapture, let id = recordingSessionID else { return }
        await withCapturePause { [self] in await drainCaptureRecording(sessionID: id) }
    }

    /// Every caller joins the complete writer and catalog drain, even when its own
    /// task is cancelled. Termination must not outrun a pause already in progress.
    func withCapturePause(_ operation: @escaping @MainActor () async -> Void) async {
        if let capturePauseTask { await capturePauseTask.value; return }
        let task = Task { @MainActor [self] in
            await operation()
            capturePauseTask = nil
        }
        capturePauseTask = task
        await task.value
    }

    private func drainCaptureRecording(sessionID id: UUID) async {
        captureEpoch = nil
        // A prewarm already running finishes; one that never started is not started now.
        textPrewarm?.disarm()
        livePreviewTask?.cancel()
        livePreviewTask = nil
        let tailToken = UUID()
        tailTranscriptionToken = tailToken
        speechPhaseReady = false
        changingCapture = true
        isBusy = true
        defer { changingCapture = false; isBusy = workTask != nil; activity = workTask == nil ? "Paused" : activity }
        let stopStarted = ContinuousClock.now
        var failure: String?
        do { try await capture.pause() } catch { failure = error.localizedDescription; self.error = failure }
        recordingHUDPausedElapsed = recordingTakeElapsedBeforeInterval + capture.elapsed
        recordPerformance(kind: "capture.engineStop", milliseconds: capture.lastMicrophoneStopMilliseconds)
        recordPerformance(kind: "capture.drain", milliseconds: stopStarted.duration(to: .now).milliseconds)
        if let mailbox = captureMailbox { await flushCommits(mailbox, sessionID: id) }
        if recordingHUDSession?.sessionID == id {
            recordingHUDSession?.pause()
            if let failure { recordingHUDSession?.fail(failure) }
            recordingHUDSnapshot = recordingHUDSession?.snapshot
        }
        do {
            try await mutate(id) { session in
                session.status = failure == nil ? .paused : .interrupted
                for index in session.intervals.indices where session.intervals[index].endedAt == nil {
                    session.intervals[index].endedAt = Date()
                    session.intervals[index].hostTime = self.capture.hostTime
                }
                if let failure { session.gaps.append(SessionGap(reason: failure)) }
            }
        } catch { self.error = error.localizedDescription }
        recordingSessionID = nil
        captureMailbox = nil
        do {
            try await mutate(id) { session in
                guard var brief = session.brief else { return }
                for index in brief.takes.indices where brief.takes[index].status == .recording {
                    brief.takes[index].status = .paused
                    if let metadataIndex = session.dictation?.recordings.firstIndex(where: { $0.id == brief.takes[index].id }) {
                        session.dictation?.recordings[metadataIndex].state = .paused
                    }
                }
                session.brief = brief
            }
        } catch { self.error = error.localizedDescription }
        // Tail transcription starts after the recorder has drained. Preparing an edit remains deliberate.
        if installedModelIDs.contains(selectedSpeechModelID) {
            let previousWork = workTask
            let intervalID = recordingHUDSession?.intervalID
            Task { @MainActor [weak self] in
                await previousWork?.value
                guard let self, !self.isRecording, self.workTask == nil, !self.terminating,
                      self.tailTranscriptionToken == tailToken else { return }
                await self.performWork("Finishing this take", kind: .speech) {
                    try await self.runTranscription(id, retryIncomplete: false)
                }
                self.finishRecordingHUD(sessionID: id, intervalID: intervalID)
            }
        } else {
            recordingHUDSession?.finish()
            recordingHUDSnapshot = recordingHUDSession?.snapshot
            scheduleSpeechIdleRelease()
        }
    }

    private func captureFailed(_ message: String, sessionID id: UUID, intervalID: UUID? = nil, epoch: UUID? = nil) async {
        // Late callbacks retain the old gap, without changing a newly resumed recording.
        let currentCapture = epoch == nil || captureEpoch == epoch
        error = message
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            if currentCapture { sessions[index].status = .interrupted }
            if !sessions[index].gaps.contains(where: { $0.reason == message }) { sessions[index].gaps.append(SessionGap(reason: message)) }
            if var brief = sessions[index].brief {
                for takeIndex in brief.takes.indices where currentCapture && brief.takes[takeIndex].status == .recording &&
                    (intervalID.map { brief.takes[takeIndex].captureIntervalIDs.contains($0) } ?? true) {
                    brief.takes[takeIndex].status = .paused
                }
                brief.reviewedRevisionID = nil
                sessions[index].brief = brief
            }
            for interval in sessions[index].intervals.indices where sessions[index].intervals[interval].endedAt == nil && (intervalID == nil || sessions[index].intervals[interval].id == intervalID) {
                sessions[index].intervals[interval].endedAt = Date()
                if currentCapture, recordingSessionID == id { sessions[index].intervals[interval].hostTime = capture.hostTime }
            }
        }
        if currentCapture, let mailbox = captureMailbox, recordingSessionID == id { await flushCommits(mailbox, sessionID: id) }
        if currentCapture, recordingSessionID == id {
            recordingHUDPausedElapsed = recordingTakeElapsedBeforeInterval + capture.elapsed
            livePreviewTask?.cancel(); livePreviewTask = nil
            recordingSessionID = nil; captureMailbox = nil; captureEpoch = nil; speechPhaseReady = false
        }
        do { try await persist(id) } catch { self.error = "\(message) \(error.localizedDescription)" }
        if currentCapture, recordingHUDSession?.sessionID == id,
           intervalID == nil || recordingHUDSession?.intervalID == intervalID {
            recordingHUDSession?.pause()
            recordingHUDSession?.fail(message)
            recordingHUDSnapshot = recordingHUDSession?.snapshot
        }
        if currentCapture, workTask == nil { activity = "Recording interrupted" }
    }

    private func enqueueCommits(_ mailbox: CommittedAudioMailbox, sessionID id: UUID) {
        let previous = commitTail
        commitTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            let segments = mailbox.take().sorted { $0.startTime < $1.startTime }
            guard !segments.isEmpty else { return }
            do {
                guard !self.isEditingRecording, let store = self.store,
                      let index = self.sessions.firstIndex(where: { $0.id == id }) else {
                    throw KeystormError.message("The recording session is unavailable.")
                }
                var snapshot = self.sessions[index]
                let known = Dictionary(snapshot.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for segment in segments {
                    if let existing = known[segment.id], existing != segment {
                        throw KeystormError.message("A committed audio identity cannot change.")
                    }
                    if known[segment.id] == nil { snapshot.segments.append(segment) }
                }
                if let first = segments.first, let last = self.sessions[index].segments.last,
                   first.startTime < last.startTime { snapshot.segments.sort { $0.startTime < $1.startTime } }
                snapshot.invalidateDerivedWork()
                let updatedAt = snapshot.updatedAt
                // Publish to the in-memory authority before enqueueing, so any later full
                // checkpoint contains this source. Progressive ASR waits for SQL acknowledgement.
                self.sessions[index] = snapshot
                let previousWrite = self.persistenceTail
                let append = Task {
                    _ = try? await previousWrite?.value
                    for offset in stride(from: 0, to: segments.count, by: IncrementalSessionJournal.maximumSegmentsPerDelta) {
                        let end = min(segments.count, offset + IncrementalSessionJournal.maximumSegmentsPerDelta)
                        _ = try await store.appendCapturedSegments(sessionID: id,
                            segments: Array(segments[offset..<end]), updatedAt: updatedAt)
                    }
                }
                self.persistenceTail = append
                let started = ContinuousClock.now
                try await append.value
                self.recordPerformance(kind: "capture.persistence", milliseconds: started.duration(to: .now).milliseconds)
                self.scheduleHistoryRefresh()
                self.refreshRecordingHUDCoverage(sessionID: id)
                // Progressive processing sees only source material acknowledged by the store.
                self.progressiveTranscriptionRequested = true
                self.scheduleProgressiveTranscription(id)
            } catch {
                self.error = "Committed audio is retained on disk, but catalog persistence failed: \(error.localizedDescription)"
                if self.capture.isRecording { try? await self.capture.pause() }
                let message = self.error ?? "Catalog persistence failed."
                Task { @MainActor [weak self] in await self?.captureFailed(message, sessionID: id) }
            }
        }
    }

    private func flushCommits(_ mailbox: CommittedAudioMailbox, sessionID id: UUID) async {
        enqueueCommits(mailbox, sessionID: id)
        let tail = commitTail
        await tail?.value
    }

    func transcribePending() async {
        guard let id = selectedSessionID, inference != nil else { return }
        await cancelProcessing()
        await performWork("Transcribing saved audio", kind: .speech) { try await self.runTranscription(id, retryIncomplete: true) }
    }

    /// A single latest-only loop shares the speech worker with durable reconciliation.
    /// Capture never awaits this task; a slow model can only delay the provisional display.
    private func startLiveTranscription(sessionID id: UUID, intervalID: UUID, epoch: UUID) {
        guard livePreviewTask == nil, let inference,
              let model = ModelCatalog.models.first(where: { $0.id == selectedSpeechModelID }),
              installedModelIDs.contains(model.id) else { return }
        livePreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var sequence: Int64 = 0
            var receivedFirstText = false
            var previousDiscontinuities: Int64 = 0
            var retryAfter = ContinuousClock.now
            // Load concurrently with capture, before the first durable segment exists.
            if !Task.isCancelled, self.liveCaptureMatches(id, intervalID: intervalID, epoch: epoch), self.workTask == nil {
                await self.performLiveWork("Preparing live transcription", clearsError: false) {
                    do {
                        let started = ContinuousClock.now
                        try await inference.prepareSpeech(model: model)
                        self.recordPerformance(kind: "speech.previewPrepare", milliseconds: started.duration(to: .now).milliseconds)
                    } catch is CancellationError { }
                    catch {
                        self.reportPreviewFailure(error.localizedDescription, sessionID: id, intervalID: intervalID, epoch: epoch)
                        retryAfter = .now.advanced(by: .seconds(2))
                    }
                }
            }
            while !Task.isCancelled, self.liveCaptureMatches(id, intervalID: intervalID, epoch: epoch) {
                if self.workTask != nil || self.changingCapture {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                    continue
                }
                let cycleStarted = ContinuousClock.now
                if cycleStarted >= retryAfter,
                   let window = await self.capture.liveWindow(after: sequence),
                   self.liveCaptureMatches(id, intervalID: intervalID, epoch: epoch),
                   window.intervalID == intervalID, self.workTask == nil, !Task.isCancelled {
                    sequence = window.sequence
                    if window.discontinuityCount != previousDiscontinuities {
                        previousDiscontinuities = window.discontinuityCount
                        self.recordingHUDSession?.clearPreview()
                        if let issue = window.bufferIssue {
                            self.reportPreviewFailure(issue, sessionID: id, intervalID: intervalID, epoch: epoch)
                        }
                    }
                    await self.performLiveWork("Updating live transcript", clearsError: false) {
                        do {
                            let started = ContinuousClock.now
                            let preview = try await inference.transcribePreview(samples: window.samples, model: model)
                            try Task.checkCancellation()
                            guard self.liveCaptureMatches(id, intervalID: intervalID, epoch: epoch) else { return }
                            self.recordPerformance(kind: "speech.preview", milliseconds: started.duration(to: .now).milliseconds)
                            self.recordPerformance(kind: "speech.previewLag", milliseconds: max(0, self.capture.elapsed - window.endTime) * 1_000)
                            if !receivedFirstText, !preview.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                receivedFirstText = true
                                if let requested = self.recordingRequestStartedAt {
                                    self.recordPerformance(kind: "speech.firstLiveText", milliseconds: requested.duration(to: .now).milliseconds)
                                }
                            }
                            self.recordingHUDSession?.receivedPreview(text: preview.text, words: preview.words,
                                startTime: self.recordingTakeElapsedBeforeInterval + window.startTime,
                                endTime: self.recordingTakeElapsedBeforeInterval + window.endTime)
                            self.recordingHUDSnapshot = self.recordingHUDSession?.snapshot
                        } catch is CancellationError { }
                        catch {
                            self.reportPreviewFailure(error.localizedDescription, sessionID: id, intervalID: intervalID, epoch: epoch)
                            retryAfter = .now.advanced(by: .seconds(2))
                        }
                    }
                }
                guard !Task.isCancelled, self.liveCaptureMatches(id, intervalID: intervalID, epoch: epoch) else { break }
                // After the first live window, a Clean or Email take warms the text model once.
                // It holds the lane like any job, so previews wait instead of overlapping it.
                if sequence > 0 { self.startTextPrewarmIfDue(epoch: epoch) }
                if self.progressiveTranscriptionRequested, self.workTask == nil {
                    self.progressiveTranscriptionRequested = false
                    // One saved core per turn prevents either lane from starving the other.
                    await self.performLiveWork("Reconciling saved audio", clearsError: true) {
                        try await self.runTranscription(id, retryIncomplete: false, maximumCores: 1)
                    }
                }
                // Aim for two updates/second, without catch-up jobs or overlapping inference.
                let next = cycleStarted.advanced(by: .milliseconds(sequence == 0 ? 100 : 500))
                let remaining = ContinuousClock.now.duration(to: next)
                do { try await Task.sleep(for: max(.milliseconds(20), remaining)) } catch { break }
            }
        }
    }

    private func liveCaptureMatches(_ id: UUID, intervalID: UUID, epoch: UUID) -> Bool {
        !terminating && speechPhaseReady && captureEpoch == epoch && recordingSessionID == id &&
            capture.isRecording && recordingHUDSession?.intervalID == intervalID
    }

    private func reportPreviewFailure(_ message: String, sessionID id: UUID, intervalID: UUID, epoch: UUID) {
        guard liveCaptureMatches(id, intervalID: intervalID, epoch: epoch) else { return }
        recordingHUDSession?.previewUnavailable(message)
        recordingHUDSnapshot = recordingHUDSession?.snapshot
    }

    private func scheduleProgressiveTranscription(_ id: UUID) {
        // During live capture, one scheduler alternates the newest preview with saved-audio work.
        guard livePreviewTask == nil else { return }
        guard !terminating, speechPhaseReady, workTask == nil, !changingCapture, let inference,
              installedModelIDs.contains(selectedSpeechModelID), recordingSessionID == id, isRecording else { return }
        Task { @MainActor [weak self] in
            guard let self, self.workTask == nil else { return }
            await self.performWork("Transcribing saved audio", kind: .speech) {
                try await self.runTranscription(id, retryIncomplete: false)
            }
            _ = inference // Keep the initialized worker alive through this scheduled operation.
        }
    }

    static func transcriptionWindow(for core: AudioSegment, in ordered: [AudioSegment])
        -> (segments: [AudioSegment], hasRightContext: Bool)? {
        guard let index = ordered.firstIndex(where: { $0.id == core.id }) else { return nil }
        var window = [core]
        if index > 0 {
            let previous = ordered[index - 1]
            if previous.intervalID == core.intervalID, abs(previous.endTime - core.startTime) < 0.05 { window.insert(previous, at: 0) }
        }
        var hasRightContext = false
        if index + 1 < ordered.count {
            let next = ordered[index + 1]
            if next.intervalID == core.intervalID, abs(core.endTime - next.startTime) < 0.05 { window.append(next); hasRightContext = true }
        }
        // Live capture rotates after the buffer that reaches 5 s, so segments can run slightly long.
        // Shed context (right first) until the window fits the worker's cap; the core always stays.
        // hasRightContext still reports the neighbour so recording does not wait for a tail it has.
        while window.count > 1, window.reduce(0, { $0 + $1.duration }) > LocalInference.maximumWindowSeconds {
            if window.last?.id != core.id { window.removeLast() } else { window.removeFirst() }
        }
        return (window, hasRightContext)
    }

    private func runTranscription(_ id: UUID, retryIncomplete: Bool, maximumCores: Int = .max) async throws {
        guard let inference, let store, let model = ModelCatalog.models.first(where: { $0.id == selectedSpeechModelID }) else { throw KeystormError.message("Choose a local speech model.") }
        let configuration = try await inference.configuration(for: model)
        try await remember(configuration, in: id)
        let directory = try await store.audioDirectory(id)
        let initial = try requireSession(id)
        var attempted = Set(initial.currentTranscripts.filter { retryIncomplete ? $0.isComplete : true }.flatMap(\.segmentIDs))
        if !retryIncomplete {
            attempted.formUnion(initial.jobs.filter { $0.stage == .transcription && ($0.status == .failed || $0.status == .incomplete) }.flatMap(\.inputIDs))
        }
        let candidates = initial.availableSegments.filter { !attempted.contains($0.id) }
        var processedCores = 0
        for core in candidates {
            if processedCores >= maximumCores {
                progressiveTranscriptionRequested = true
                break
            }
            try Task.checkCancellation()
            let snapshot = try requireSession(id)
            let ordered = snapshot.availableSegments
            guard let context = Self.transcriptionWindow(for: core, in: ordered) else { continue }
            let window = context.segments
            // Closed intervals reconcile while a resumed interval records; only its active tail waits.
            if recordingSessionID == id, isRecording, recordingHUDSession?.intervalID == core.intervalID,
               !context.hasRightContext { continue }
            for segment in window { _ = try await store.audioURL(for: segment, in: id) }
            var job = ProcessingJob(stage: .transcription, status: .running, inputIDs: [core.id], configurationID: configuration.id, totalUnits: 1)
            try await mutate(id) { $0.jobs.append(job) }
            do {
                let startedAt = ContinuousClock.now
                let result = try await inference.transcribeWindow(segments: window, directory: directory, model: model)
                recordPerformance(kind: "speech.window", milliseconds: startedAt.duration(to: .now).milliseconds)
                try Task.checkCancellation()
                let validTimings = result.words.allSatisfy { $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime >= $0.startTime && $0.startTime >= window[0].startTime - 0.5 && $0.endTime <= window.last!.endTime + 0.5 }
                let canCrop = result.transcript.isComplete && validTimings && (!result.words.isEmpty || result.transcript.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                let owned = result.words.filter { word in
                    let midpoint = (word.startTime + word.endTime) / 2
                    return midpoint >= core.startTime && midpoint < core.endTime
                }
                var transcript = result.transcript
                transcript.segmentIDs = [core.id]
                transcript.startTime = core.startTime
                transcript.endTime = core.endTime
                transcript.text = canCrop ? owned.map(\.word).joined(separator: " ") : result.transcript.rawText
                // Dictation retains the owned ASR span, so adjacent context windows cannot duplicate raw output.
                if snapshot.dictation != nil, canCrop { transcript.rawText = transcript.text }
                transcript.isComplete = canCrop
                transcript.timingPrecision = .window
                transcript.replacesID = snapshot.currentTranscripts.last(where: { $0.segmentIDs == [core.id] && !$0.isComplete })?.id
                job.status = canCrop ? .completed : .incomplete
                job.completedUnits = canCrop ? 1 : 0
                job.error = canCrop ? nil : "Native word timing could not reconcile this window. Review the source and confirm a correction before extraction."
                let output = transcript
                let automatic = canCrop && snapshot.dictation == nil ? self.approvedCorrections(for: output, projectPath: snapshot.projectPath) : (revisions: [TranscriptRevision](), patches: [CorrectionPatch]())
                let finished = job
                try await mutate(id) { session in
                    session.transcripts.append(output)
                    session.transcripts.append(contentsOf: automatic.revisions)
                    session.corrections.append(contentsOf: automatic.patches)
                    if var brief = session.brief, let takeIndex = brief.takes.firstIndex(where: { $0.trashedAt == nil && $0.activeIntervalIDs.contains(core.intervalID) }) {
                        let currentID = automatic.revisions.last?.id ?? output.id
                        if !brief.takes[takeIndex].transcriptIDs.contains(currentID) {
                            brief.takes[takeIndex].transcriptIDs.append(currentID)
                        }
                        brief.reviewedRevisionID = nil
                        session.brief = brief
                    }
                    if let index = session.jobs.firstIndex(where: { $0.id == finished.id }) { session.jobs[index] = finished }
                    session.invalidateDerivedWork()
                }
                // A resumed take also owns delayed reconciliation of its earlier intervals.
                refreshRecordingHUDCoverage(sessionID: id, segment: core,
                    text: canCrop ? (automatic.revisions.last?.text ?? output.text) : "", isComplete: canCrop)
                if !canCrop { throw KeystormError.message(job.error!) }
                processedCores += 1
            } catch {
                let message = error.localizedDescription
                try? await mutate(id) { session in
                    guard let index = session.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                    if session.jobs[index].status == .running {
                        session.jobs[index].status = Task.isCancelled ? .cancelled : .failed
                        session.jobs[index].error = message
                    }
                }
                if recordingHUDSession?.sessionID == id, recordingHUDSession?.intervalID == core.intervalID,
                   !(error is CancellationError) {
                    recordingHUDSession?.fail(message)
                    recordingHUDSnapshot = recordingHUDSession?.snapshot
                }
                throw error
            }
        }
    }

    #if DEBUG
    /// An isolated visual fixture. It cannot open the microphone or run inference.
    func previewRecordingHUDForUITest() {
        guard storageRoot != nil,
              ProcessInfo.processInfo.environment["KEYSTORM_HUD_PREVIEW"] == "1",
              let id = selectedSessionID else { return }
        let intervalID = UUID()
        recordingHUDSession = RecordingHUDSession(sessionID: id, intervalID: intervalID,
            title: "Add material · Constraints", hasSpeechModel: true)
        // Show ephemeral text before any five-second segment has been acknowledged.
        recordingHUDSession?.receivedPreview(text: "Keep all processing local.",
            words: [], startTime: 0, endTime: 0.8)
        recordingHUDSnapshot = recordingHUDSession?.snapshot
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, self.recordingHUDSession?.intervalID == intervalID else { return }
            self.recordingHUDSession?.receivedPreview(
                text: "Keep all processing local. Use 256, not 512. Preserve every negation.",
                words: [], startTime: 0, endTime: 1.7)
            var snapshot = self.recordingHUDSession?.snapshot
            let status = (snapshot?.status ?? "") + " · Microphone is off"
            snapshot?.status = status
            self.recordingHUDSnapshot = snapshot
        }
    }
    #endif

    func dismissRecordingHUD() {
        guard !isRecording else { return }
        recordingHUDSession = nil
        recordingHUDSnapshot = nil
    }

    /// Runs on durable acknowledgments, never the 200 ms capture clock. Logical
    /// coordinates compact only this take's audio and exclude paused wall-clock time.
    static func recordingHUDCoverage(for take: BriefTake, in session: VoiceSession, segmentID: UUID? = nil)
        -> (saved: Double, transcribed: Double, segmentStart: Double?, segmentEnd: Double?) {
        let covered = Set(session.currentTranscripts.filter(\.isComplete).flatMap(\.segmentIDs))
        let unavailable = Set(session.unavailableSegmentIDs)
        var saved = 0.0, transcribed = 0.0, position = 0.0
        var savedBlocked = false, transcribedBlocked = false
        var segmentStart: Double?, segmentEnd: Double?
        for segment in session.takeSegments(take) {
            let end = position + segment.duration
            let available = !unavailable.contains(segment.id)
            if !savedBlocked && available { saved = end } else { savedBlocked = true }
            if !transcribedBlocked && available && covered.contains(segment.id) { transcribed = end }
            else { transcribedBlocked = true }
            if segment.id == segmentID { segmentStart = position; segmentEnd = end }
            position = end
        }
        return (saved, transcribed, segmentStart, segmentEnd)
    }

    private func refreshRecordingHUDCoverage(sessionID id: UUID, segment: AudioSegment? = nil,
                                             text: String = "", isComplete: Bool = true) {
        guard recordingHUDSession?.sessionID == id, let takeID = recordingHUDSession?.takeID,
              let snapshot = session(id), let take = snapshot.brief?.takes.first(where: { $0.id == takeID && $0.trashedAt == nil }) else { return }
        let coverage = Self.recordingHUDCoverage(for: take, in: snapshot, segmentID: segment?.id)
        if let segment, let start = coverage.segmentStart, let end = coverage.segmentEnd {
            recordingHUDSession?.receivedTranscript(segmentID: segment.id, startTime: start, endTime: end,
                text: text, isComplete: isComplete)
        }
        recordingHUDSession?.synchronizeCoverage(saved: coverage.saved, transcribed: coverage.transcribed)
        recordingHUDSnapshot = recordingHUDSession?.snapshot
    }

    private func finishRecordingHUD(sessionID: UUID, intervalID: UUID?) {
        guard recordingHUDSession?.sessionID == sessionID, recordingHUDSession?.intervalID == intervalID,
              !isRecording else { return }
        recordingHUDSession?.finish()
        recordingHUDSnapshot = recordingHUDSession?.snapshot
    }

    func preparePrompt() async {
        guard let id = selectedSessionID, let inference else { return }
        if isRecording {
            guard recordingSessionID == id else { error = "Pause the active recording before preparing another session."; return }
            await pauseRecording()
        }
        if hasOpenTake { await finishTake() }
        await cancelProcessing()
        await performWork("Preparing a source-linked prompt") {
            var snapshot = try self.requireSession(id)
            let covered = Set(snapshot.currentTranscripts.filter(\.isComplete).flatMap(\.segmentIDs))
            if snapshot.availableSegments.contains(where: { !covered.contains($0.id) }) { try await self.runTranscription(id, retryIncomplete: true) }
            await inference.releaseSpeech()
            self.memoryMeasurements = await inference.memorySnapshot()
            guard (self.memoryMeasurements["processFootprint"] ?? 0) < 6 * 1024 * 1024 * 1024 else {
                throw KeystormError.message("Speech has been released but the process is still over the provisional Mac memory budget. Audio is saved; retry after memory falls.")
            }
            try Task.checkCancellation()
            snapshot = try self.requireSession(id)
            let sourceIdentity = SourceIdentity(snapshot)
            guard snapshot.currentTranscripts.allSatisfy(\.isComplete) else { throw KeystormError.message("Review incomplete transcript windows before extracting requirements.") }
            let editTranscriptIDs = self.editTranscriptIDs(in: snapshot)
            let inputs = snapshot.currentTranscripts.filter { transcript in
                !editTranscriptIDs.contains(transcript.id) &&
                !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !snapshot.jobs.contains(where: { $0.stage == .extraction && $0.status == .completed && $0.inputIDs == [transcript.id] }) &&
                !self.hasManualCoverage(transcript, facts: snapshot.facts)
            }
            var textConfiguration: ProcessingConfiguration?
            if !inputs.isEmpty {
                let configuration = try await inference.configuration(for: ModelCatalog.primaryText)
                textConfiguration = configuration
                try await self.remember(configuration, in: id)
                for transcript in inputs {
                    try Task.checkCancellation()
                    var job = ProcessingJob(stage: .extraction, status: .running, inputIDs: [transcript.id], configurationID: configuration.id, totalUnits: 1)
                    try await self.mutate(id) { $0.jobs.append(job) }
                    do {
                        let current = try self.requireSession(id)
                        var contexts = current.contexts
                        if !current.taskDescription.isEmpty {
                            contexts.append(ContextSnapshot(title: "Selected task", content: current.taskDescription, sha256: Self.hash(current.taskDescription)))
                        }
                        let facts = try await inference.extract(transcripts: [transcript], contexts: contexts, config: configuration, priorFacts: LedgerValidation.currentFacts(in: current))
                        try Task.checkCancellation()
                        guard let latest = self.session(id), SourceIdentity(latest) == sourceIdentity,
                              latest.currentTranscripts.contains(where: { $0.id == transcript.id }) else {
                            throw KeystormError.message("The sources or selected context changed during extraction; stale output was not committed.")
                        }
                        try LedgerValidation.validate(current.facts + facts, transcripts: current.transcripts)
                        job.status = .completed
                        job.completedUnits = 1
                        let finished = job
                        try await self.mutate(id) { session in
                            session.facts.append(contentsOf: facts)
                            if let index = session.jobs.firstIndex(where: { $0.id == finished.id }) { session.jobs[index] = finished }
                            session.invalidateDerivedWork()
                        }
                    } catch {
                        let reason = error.localizedDescription
                        try? await self.mutate(id) { session in
                            if let index = session.jobs.firstIndex(where: { $0.id == job.id }) {
                                session.jobs[index].status = Task.isCancelled ? .cancelled : .incomplete
                                session.jobs[index].error = reason
                            }
                        }
                        throw error
                    }
                }
            }
            await inference.releaseText()
            try Task.checkCancellation()
            snapshot = try self.requireSession(id)
            guard SourceIdentity(snapshot) == sourceIdentity else { throw KeystormError.message("The session changed while preparing. Prepare again from its current sources.") }
            let draft = try PromptComposer.compose(session: snapshot, detail: self.detail, configurationID: textConfiguration?.id)
            var job = ProcessingJob(stage: .composition, status: .completed, inputIDs: snapshot.currentTranscripts.map(\.id), configurationID: textConfiguration?.id, completedUnits: 1, totalUnits: 1)
            job.error = nil
            try Task.checkCancellation()
            try await self.mutate(id) { session in session.drafts.append(draft); session.jobs.append(job) }
        }
    }

    // MARK: Persistent implementation brief

    func recordPerformance(kind: String, milliseconds: Double) {
        guard metricSamples.append(kind: kind, milliseconds: milliseconds) else { return }
        // Percentile sorting runs only when settings/reporting actually requests a summary.
        metricSummaryCache = nil
        metricGeneration &+= 1
        performanceMeasurements.append(RuntimeMeasurement(kind: kind, milliseconds: milliseconds))
        if performanceMeasurements.count > 100 { performanceMeasurements.removeFirst(performanceMeasurements.count - 100) }
    }

    /// Explicit export contains timings and system/model configuration, never document or audio content.
    func performanceReportData() throws -> Data {
        let process = ProcessInfo.processInfo
        #if DEBUG
        let configuration = "Debug; optimization disabled"
        #else
        let configuration = "Release"
        #endif
        let report = RuntimePerformanceReport(schemaVersion: 1, generatedAt: Date(),
            operatingSystem: process.operatingSystemVersionString, hardwareModel: RuntimePerformanceReport.hardwareModel,
            physicalMemoryBytes: process.physicalMemory, logicalProcessors: process.activeProcessorCount,
            thermalState: process.thermalState.rawValue, lowPowerMode: process.isLowPowerModeEnabled,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            configuration: configuration, selectedSpeechModelID: selectedSpeechModelID,
            textModelID: ModelCatalog.primaryText.id, installedModelIDs: installedModelIDs.sorted(),
            catalogModels: ModelCatalog.models.filter { installedModelIDs.contains($0.id) }.map { model in
                RuntimeCatalogModel(modelID: model.id, repository: model.repository, revision: model.revision,
                    runtime: model.runtime,
                    runtimeRevision: model.purpose == .speech ? ModelCatalog.fluidRevision : ModelCatalog.mlxRevision,
                    quantization: model.quantization, artifacts: model.artifacts)
            },
            summaries: performanceSummaries, recentMeasurements: performanceMeasurements,
            memorySnapshotBytes: memoryMeasurements,
            limitations: "Newest 128 observations per operation, at most 32 operations. Nearest-rank percentiles; small samples do not establish tail latency. Samples mix cold/warm conditions unless collected in separate app launches. Memory values are snapshots, not combined peak. Typing excludes layout/paint; startup begins at workspace initialization; capture start includes permission and persistence; stop separates microphone stop from writer drain. No natural-speech fidelity, sustained heat, battery, or 90-minute qualification is implied.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    func ensureBrief() async {
        guard let id = selectedSessionID else { return }
        ensureBrief(id)
        await flushBriefEdits()
    }

    private func ensureBrief(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].brief == nil else { return }
        sessions[index].brief = BriefDocument.migrating(session: sessions[index])
        dirtyBriefSessionIDs.insert(id)
        scheduleBriefSave(id)
    }

    /// Mutate the small document immediately; defer durable I/O to a 300 ms idle boundary.
    func updateBriefBlock(id blockID: UUID, text: String) {
        guard !isEditingRecording, let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }),
              var brief = sessions[index].brief, let block = brief.block(blockID),
              !block.text.utf8.elementsEqual(text.utf8) else { return }
        let editStarted = ContinuousClock.now
        defer { recordPerformance(kind: "brief.typing", milliseconds: editStarted.duration(to: .now).milliseconds) }
        do {
            let coalesce = typingBlockID == blockID && typingLastChanged.map { Date().timeIntervalSince($0) < 0.35 } == true
            try brief.apply([.replace(blockID: blockID, text: text, origin: .typed,
                sources: block.sources, allowExact: false)],
                expectedRevision: brief.revisionID, label: "Edit text", coalesce: coalesce)
            sessions[index].brief = brief
            sessions[index].updatedAt = Date()
            typingBlockID = blockID
            typingLastChanged = Date()
            dirtyBriefSessionIDs.insert(id)
            scheduleBriefSave(id)
        } catch { self.error = error.localizedDescription }
    }

    func appendBriefBlock(text: String, origin: BriefOrigin = .typed, exact: Bool = false, filePath: String? = nil) async {
        guard let id = selectedSessionID else { return }
        let targetSection = selectedSectionKind
        await flushBriefEdits()
        do {
            try await mutate(id) { session in
                var brief = session.brief ?? BriefDocument.migrating(session: session)
                var block = BriefBlock(text: text, origin: origin, exact: exact)
                if [.file, .clipboard].contains(origin) || filePath != nil {
                    let context = ContextSnapshot(title: filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Clipboard insertion",
                        content: text, sha256: Self.hash(text), filePath: filePath)
                    session.contexts.append(context)
                    block.contextIDs = [context.id]
                }
                try brief.apply([.append(section: targetSection, block: block)],
                    expectedRevision: brief.revisionID, label: exact ? "Insert exact reference" : "Add passage")
                session.brief = brief
                if self.selectedSessionID == id, self.selectedSectionKind == targetSection {
                    self.selectedBlockIDs = [block.id]
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func insertExactReference(text: String, filePath: String? = nil, origin: BriefOrigin = .clipboard) async {
        await appendBriefBlock(text: text, origin: filePath == nil ? origin : .file, exact: true, filePath: filePath)
    }

    func removeBriefBlock(id blockID: UUID) async {
        await applyBriefEdits([.remove(blockID: blockID, allowExact: false)], label: "Remove passage")
        if currentBrief?.block(blockID) == nil { selectedBlockIDs.removeAll { $0 == blockID } }
    }

    func unlockBriefBlock(id blockID: UUID) async {
        guard let block = currentBrief?.block(blockID) else { return }
        await applyBriefEdits([.replace(blockID: blockID, text: block.text, origin: block.origin,
            sources: block.sources, allowExact: true)], label: "Unlock exact reference")
    }

    func moveBriefBlock(id blockID: UUID, to section: BriefSectionKind, index: Int? = nil) async {
        await applyBriefEdits([.move(blockID: blockID, section: section, index: index)], label: "Move passage")
    }

    private func applyBriefEdits(_ edits: [BriefEdit], label: String) async {
        guard let id = selectedSessionID else { return }
        await flushBriefEdits()
        do {
            try await mutate(id) { session in
                var brief = session.brief ?? BriefDocument.migrating(session: session)
                try brief.apply(edits, expectedRevision: brief.revisionID, label: label)
                session.brief = brief
            }
        } catch { self.error = error.localizedDescription }
    }

    func undoBrief() async { await changeBriefHistory(forward: false) }
    func redoBrief() async { await changeBriefHistory(forward: true) }

    private func changeBriefHistory(forward: Bool) async {
        guard let id = selectedSessionID else { return }
        await flushBriefEdits()
        do {
            try await mutate(id) { session in
                guard var brief = session.brief else { return }
                if forward { try brief.redo() } else { try brief.undo() }
                session.brief = brief
            }
        } catch { self.error = error.localizedDescription }
    }

    /// A typed command follows precisely the same explicit Edit Brief path as a spoken command.
    func proposeBriefCommand(text: String) async {
        guard let id = selectedSessionID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await flushBriefEdits()
        do {
            try await mutate(id) { session in
                var brief = session.brief ?? BriefDocument.migrating(session: session)
                guard brief.pendingProposal == nil else { throw KeystormError.message("Apply or dismiss the current proposal first.") }
                let transcript = TranscriptRevision(rawText: text, text: text, origin: .imported, timingPrecision: .unavailable)
                session.transcripts.append(transcript)
                brief.takes.append(BriefTake(intent: .editBrief, targetSection: self.selectedSectionKind,
                    expectedRevision: brief.revisionID, selectedBlockIDs: self.selectedBlockIDs,
                    status: .pending, transcriptIDs: [transcript.id]))
                brief.reviewedRevisionID = nil
                session.brief = brief
            }
            await prepareBrief()
        } catch { self.error = error.localizedDescription; pendingBriefIssue = error.localizedDescription }
    }

    /// Proposed edits never replace the current document until deliberately accepted.
    func prepareBrief() async {
        guard let id = selectedSessionID, let inference else { return }
        let started = ContinuousClock.now
        if isRecording {
            guard recordingSessionID == id else { error = "Pause the active session first."; return }
            await pauseRecording()
        }
        if hasOpenTake { await finishTake() }
        await flushBriefEdits()
        await cancelProcessing()
        // Snapshot after prior work is drained, so its late proposal cannot count as this request's success.
        let previousProposalID = session(id)?.brief?.pendingProposal?.id
        pendingBriefIssue = nil
        await performWork("Preparing proposed brief changes") {
            let original = try self.requireSession(id)
            guard original.brief?.pendingProposal == nil else { throw KeystormError.message("Apply or dismiss the current proposal first.") }
            let covered = Set(original.currentTranscripts.filter(\.isComplete).flatMap(\.segmentIDs))
            if original.availableSegments.contains(where: { !covered.contains($0.id) }) {
                try await self.runTranscription(id, retryIncomplete: true)
            }
            await inference.releaseSpeech()
            self.memoryMeasurements = await inference.memorySnapshot()
            guard (self.memoryMeasurements["processFootprint"] ?? 0) < 6 * 1024 * 1024 * 1024 else {
                throw KeystormError.message("Speech has been released. Waiting for the Mac memory budget before text processing.")
            }
            var snapshot = try self.requireSession(id)
            guard let initialBrief = snapshot.brief else { throw KeystormError.message("Open a brief before preparing changes.") }
            let expectedRevision = initialBrief.revisionID
            let identity = SourceIdentity(snapshot)
            let pending = initialBrief.takes.filter { $0.trashedAt == nil && [.pending, .failed].contains($0.status) }
            guard !pending.isEmpty || !snapshot.facts.isEmpty else {
                throw KeystormError.message("Record a take, import a transcript, or type directly into the brief.")
            }
            let commandTake = pending.first { $0.intent == .editBrief }
            if let take = commandTake {
                guard take.expectedRevision == expectedRevision else { throw BriefDocumentError.staleRevision }
                let transcripts = self.currentTakeTranscripts(take, session: snapshot)
                guard !transcripts.isEmpty, transcripts.allSatisfy(\.isComplete) else {
                    throw KeystormError.message("Finish transcription for the edit take first.")
                }
                let command = transcripts.map(\.text).joined(separator: " ")
                let sources = transcripts.filter { !$0.text.isEmpty }.map(self.wholeSource)
                let proposal: BriefProposal
                do {
                    let parsed = try BriefVoiceParser.parse(command, document: initialBrief,
                        targetSection: take.targetSection, selectedBlockIDs: take.selectedBlockIDs, sources: sources)
                    switch parsed {
                    case .edits(let edits):
                        proposal = BriefProposal(expectedRevision: expectedRevision, edits: edits, takeIDs: [take.id], label: "Voice edit")
                    case .undo:
                        proposal = BriefProposal(expectedRevision: expectedRevision, edits: [], takeIDs: [take.id], label: "Undo last document change", action: .undo)
                    case .redo:
                        proposal = BriefProposal(expectedRevision: expectedRevision, edits: [], takeIDs: [take.id], label: "Redo document change", action: .redo)
                    }
                } catch BriefDocumentError.unsupportedCommand {
                    let config = try await inference.configuration(for: ModelCatalog.primaryText)
                    try await self.remember(config, in: id)
                    let edits = try await inference.proposeBriefEdits(command: command, document: initialBrief,
                        targetSection: take.targetSection, selectedBlockIDs: take.selectedBlockIDs, sources: sources, config: config)
                    proposal = BriefProposal(expectedRevision: expectedRevision, edits: edits, takeIDs: [take.id],
                        label: "Suggested voice edit", issues: ["Check meaning and unchanged constraints before accepting."])
                }
                guard let current = self.session(id), SourceIdentity(current) == identity,
                      current.brief?.revisionID == expectedRevision else { throw BriefDocumentError.staleRevision }
                try await self.mutate(id) { session in session.brief?.pendingProposal = proposal; session.brief?.reviewedRevisionID = nil }
                return
            }
            let materialTakes = pending.filter { $0.intent == .addMaterial }
            let allowedIDs = Set(materialTakes.flatMap { self.currentTakeTranscripts($0, session: snapshot).map(\.id) })
            let editTranscriptIDs = self.editTranscriptIDs(in: snapshot)
            let inputs = snapshot.currentTranscripts.filter { transcript in
                !editTranscriptIDs.contains(transcript.id) &&
                (allowedIDs.contains(transcript.id) || snapshot.brief?.takes.isEmpty == true) &&
                !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !snapshot.jobs.contains(where: { $0.stage == .extraction && $0.status == .completed && $0.inputIDs == [transcript.id] }) &&
                !self.hasManualCoverage(transcript, facts: snapshot.facts)
            }
            for transcript in inputs {
                guard transcript.isComplete else { throw KeystormError.message("Review incomplete transcript windows first.") }
                let config = try await inference.configuration(for: ModelCatalog.primaryText)
                try await self.remember(config, in: id)
                var job = ProcessingJob(stage: .extraction, status: .running, inputIDs: [transcript.id], configurationID: config.id, totalUnits: 1)
                try await self.mutate(id) { $0.jobs.append(job) }
                do {
                    snapshot = try self.requireSession(id)
                    let facts = try await inference.extract(transcripts: [transcript], contexts: snapshot.contexts,
                        config: config, priorFacts: snapshot.brief?.activeLedgerFacts(in: snapshot) ?? LedgerValidation.currentFacts(in: snapshot))
                    try Task.checkCancellation()
                    guard let current = self.session(id), SourceIdentity(current) == identity,
                          current.brief?.revisionID == expectedRevision else { throw BriefDocumentError.staleRevision }
                    try LedgerValidation.validate(snapshot.facts + facts, transcripts: snapshot.transcripts)
                    job.status = .completed
                    job.completedUnits = 1
                    let finished = job
                    try await self.mutate(id) { session in
                        session.facts.append(contentsOf: facts)
                        if let index = session.jobs.firstIndex(where: { $0.id == finished.id }) { session.jobs[index] = finished }
                        session.brief?.reviewedRevisionID = nil
                    }
                } catch {
                    let reason = error.localizedDescription
                    try? await self.mutate(id) { session in
                        if let index = session.jobs.firstIndex(where: { $0.id == job.id }) {
                            session.jobs[index].status = Task.isCancelled ? .cancelled : .incomplete
                            session.jobs[index].error = reason
                        }
                    }
                    throw error
                }
            }
            snapshot = try self.requireSession(id)
            guard SourceIdentity(snapshot) == identity, let brief = snapshot.brief,
                  brief.revisionID == expectedRevision else { throw BriefDocumentError.staleRevision }
            let represented = Set(brief.blocks.flatMap(\.factIDs)).union(brief.removedFactIDs)
            let candidates = LedgerValidation.currentFacts(in: snapshot).filter { fact in
                !represented.contains(fact.id) && fact.sources.allSatisfy { !editTranscriptIDs.contains($0.transcriptID) }
            }
            let edits = candidates.map { fact -> BriefEdit in
                let take = materialTakes.first { !Set($0.transcriptIDs).isDisjoint(with: fact.sources.map(\.transcriptID)) }
                let section: BriefSectionKind
                if fact.status != .confirmed { section = .questions }
                else if let take, take.targetSection != .changes { section = take.targetSection }
                else {
                    section = fact.kind == .goal ? .goal : fact.kind == .constraint ? .constraints :
                        fact.kind == .question ? .questions : .changes
                }
                return .append(section: section, block: BriefBlock(text: fact.text, origin: .speech,
                    sources: fact.sources, factIDs: [fact.id]))
            }
            if edits.isEmpty {
                try await self.mutate(id) { session in
                    guard var document = session.brief else { return }
                    for index in document.takes.indices where materialTakes.contains(where: { $0.id == document.takes[index].id }) {
                        document.takes[index].status = .applied
                    }
                    session.brief = document
                }
                return
            }
            let proposal = BriefProposal(expectedRevision: expectedRevision, edits: edits,
                takeIDs: materialTakes.map(\.id), label: "Add \(candidates.count) source-linked passages",
                issues: candidates.contains(where: { $0.status != .confirmed }) ? ["Uncertain material appears under Open questions."] : [])
            try await self.mutate(id) { $0.brief?.pendingProposal = proposal; $0.brief?.reviewedRevisionID = nil }
        }
        let elapsed = started.duration(to: .now).milliseconds
        recordPerformance(kind: "brief.prepareAttempt", milliseconds: elapsed)
        if let proposalID = session(id)?.brief?.pendingProposal?.id, proposalID != previousProposalID {
            recordPerformance(kind: "brief.proposal", milliseconds: elapsed)
        }
        if let error { pendingBriefIssue = error }
    }

    /// Recomputing is separate from rejecting: preserve the take and its unaccepted source facts.
    func refreshBriefProposal() async {
        guard let id = selectedSessionID, let proposalID = currentBrief?.pendingProposal?.id else { return }
        await flushBriefEdits()
        do {
            try await mutate(id) { session in
                guard var brief = session.brief, let proposal = brief.pendingProposal, proposal.id == proposalID else { return }
                for index in brief.takes.indices where proposal.takeIDs.contains(brief.takes[index].id) {
                    brief.takes[index].status = .pending
                    if brief.takes[index].intent == .editBrief { brief.takes[index].expectedRevision = brief.revisionID }
                }
                brief.pendingProposal = nil
                brief.reviewedRevisionID = nil
                session.brief = brief
            }
            pendingBriefIssue = nil
            await prepareBrief()
        } catch { self.error = error.localizedDescription }
    }

    func proposeBriefSupersession(factID: UUID) async {
        guard let id = selectedSessionID else { return }
        await flushBriefEdits()
        do {
            try await mutate(id) { session in
                guard var brief = session.brief else { return }
                guard brief.pendingProposal == nil else { throw KeystormError.message("Apply or reject the current proposal first.") }
                let edits = try brief.supersessionEdits(factID: factID, session: session)
                brief.pendingProposal = BriefProposal(expectedRevision: brief.revisionID, edits: edits,
                    takeIDs: [], label: "Use the explicit correction",
                    issues: ["Check the original instruction and correction before replacing the earlier passage."])
                brief.reviewedRevisionID = nil
                session.brief = brief
            }
        } catch { self.error = error.localizedDescription }
    }

    func acceptBriefProposal() async {
        guard let id = selectedSessionID else { return }
        await flushBriefEdits()
        do {
            try await mutate(id) { session in
                guard var brief = session.brief, let proposal = brief.pendingProposal else { return }
                guard proposal.expectedRevision == brief.revisionID else { throw BriefDocumentError.staleRevision }
                switch proposal.action {
                case .edits: try brief.apply(proposal.edits, expectedRevision: proposal.expectedRevision, label: proposal.label)
                case .undo: try brief.undo()
                case .redo: try brief.redo()
                }
                for index in brief.takes.indices where proposal.takeIDs.contains(brief.takes[index].id) {
                    brief.takes[index].status = .applied
                }
                brief.pendingProposal = nil
                session.brief = brief
                session.invalidateDerivedWork()
            }
            pendingBriefIssue = nil
        } catch { self.error = error.localizedDescription; pendingBriefIssue = error.localizedDescription }
    }

    func discardBriefProposal() async {
        guard let id = selectedSessionID else { return }
        await flushBriefEdits()
        do {
            try await mutate(id) { session in
                guard var brief = session.brief, let proposal = brief.pendingProposal else { return }
                for edit in proposal.edits {
                    if case .append(_, let block) = edit { brief.removedFactIDs.append(contentsOf: block.factIDs) }
                }
                for index in brief.takes.indices where proposal.takeIDs.contains(brief.takes[index].id) {
                    brief.takes[index].status = .discarded
                }
                brief.removedFactIDs = Array(Set(brief.removedFactIDs))
                brief.pendingProposal = nil
                brief.reviewedRevisionID = nil
                session.brief = brief
            }
            pendingBriefIssue = nil
        } catch { self.error = error.localizedDescription }
    }

    func dismissBriefTake(id takeID: UUID) async {
        guard let id = selectedSessionID else { return }
        do {
            try await mutate(id) { session in
                guard var brief = session.brief, let index = brief.takes.firstIndex(where: { $0.id == takeID }) else { return }
                guard brief.takes[index].status != .recording else { throw KeystormError.message("Pause this take first.") }
                let transcriptIDs = Set(brief.takes[index].transcriptIDs)
                brief.removedFactIDs.append(contentsOf: session.facts.filter { !transcriptIDs.isDisjoint(with: $0.sources.map(\.transcriptID)) }.map(\.id))
                brief.removedFactIDs = Array(Set(brief.removedFactIDs))
                brief.takes[index].status = .discarded
                brief.pendingProposal = nil
                brief.reviewedRevisionID = nil
                session.brief = brief
            }
            pendingBriefIssue = nil
        } catch { self.error = error.localizedDescription }
    }

    func reviewBrief() async {
        guard let id = selectedSessionID, let revision = currentBrief?.revisionID else { return }
        await flushBriefEdits()
        do {
            guard selectedSessionID == id, currentBrief?.revisionID == revision,
                  !dirtyBriefSessionIDs.contains(id) else { throw BriefDocumentError.staleRevision }
            try await mutate(id) { session in
                guard var brief = session.brief else { return }
                // Final approval deliberately acknowledges the visible omission list.
                let represented = Set(brief.blocks.flatMap(\.factIDs)).union(brief.removedFactIDs)
                brief.removedFactIDs.append(contentsOf: session.facts.filter { $0.status == .confirmed && !represented.contains($0.id) }.map(\.id))
                try brief.markReviewed(session: session)
                session.brief = brief
            }
        } catch { self.error = error.localizedDescription }
    }

    func reviewedBriefSnapshot() async throws -> ReviewedBriefSnapshot {
        guard let expectedID = selectedSessionID, let expectedRevision = currentBrief?.revisionID else {
            throw KeystormError.message("Review the current brief before copying or exporting it.")
        }
        await flushBriefEdits()
        guard selectedSessionID == expectedID, currentBrief?.revisionID == expectedRevision else {
            throw BriefDocumentError.staleRevision
        }
        guard !dirtyBriefSessionIDs.contains(expectedID) else {
            throw KeystormError.message("Recent changes could not be saved. Resolve the storage error before exporting.")
        }
        guard let session = selectedSession, let brief = session.brief, brief.isReviewed else {
            throw KeystormError.message("Review the current brief before copying or exporting it.")
        }
        try brief.validate(session: session)
        guard !brief.reviewIssues(session: session).contains(where: { $0.severity == .blocker }) else {
            throw KeystormError.message("Resolve the remaining review issues before exporting.")
        }
        return ReviewedBriefSnapshot(session: session, revisionID: brief.revisionID, text: brief.markdown(title: session.title))
    }

    func exportBrief(to destination: URL, includeProvenance: Bool = true) async throws {
        let snapshot = try await reviewedBriefSnapshot()
        let prepared = try await Task.detached(priority: .userInitiated) {
            try BriefTransfer.prepare(snapshot, to: destination, includeProvenance: includeProvenance)
        }.value
        guard isCurrentBrief(snapshot) else {
            BriefTransfer.discard(prepared)
            throw BriefDocumentError.staleRevision
        }
        try BriefTransfer.commit(prepared)
    }

    func isCurrentBrief(_ snapshot: ReviewedBriefSnapshot) -> Bool {
        selectedSessionID == snapshot.session.id && selectedSession?.brief?.revisionID == snapshot.revisionID &&
            selectedSession?.brief?.isReviewed == true
    }

    func flushBriefEdits() async {
        typingBlockID = nil
        typingLastChanged = nil
        let ids = Array(dirtyBriefSessionIDs)
        for id in ids {
            briefSaveTasks[id]?.cancel()
            briefSaveTasks.removeValue(forKey: id)
            guard let store, let snapshot = session(id) else { continue }
            do {
                try await durableSave(snapshot, to: store)
                if session(id)?.updatedAt == snapshot.updatedAt { dirtyBriefSessionIDs.remove(id) }
                pruneHydratedSessions()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func scheduleBriefSave(_ id: UUID, immediate: Bool = false) {
        guard store != nil else { return }
        briefSaveTasks[id]?.cancel()
        briefSaveTasks[id] = Task { @MainActor [weak self] in
            if !immediate {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            guard let self, !Task.isCancelled, let store = self.store,
                  self.dirtyBriefSessionIDs.contains(id), let snapshot = self.session(id) else { return }
            do {
                try await self.durableSave(snapshot, to: store)
                if self.session(id)?.updatedAt == snapshot.updatedAt { self.dirtyBriefSessionIDs.remove(id) }
                self.pruneHydratedSessions()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func scheduleSpeechIdleRelease() {
        speechIdleRelease?.cancel()
        speechIdleRelease = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !self.isRecording, self.workTask == nil else { return }
            await self.inference?.releaseSpeech()
            self.memoryMeasurements = await self.inference?.memorySnapshot() ?? [:]
        }
    }

    private func wholeSource(_ transcript: TranscriptRevision) -> SourceReference {
        SourceReference(transcriptID: transcript.id, startUTF8: 0, endUTF8: transcript.text.utf8.count, quote: transcript.text)
    }

    private func currentTakeTranscripts(_ take: BriefTake, session: VoiceSession) -> [TranscriptRevision] {
        let ids = transcriptIDs(for: [take], in: session)
        return session.currentTranscripts.filter { ids.contains($0.id) }
    }

    private func transcriptIDs(for takes: [BriefTake], in session: VoiceSession) -> Set<UUID> {
        var ids = Set(takes.flatMap(\.transcriptIDs))
        guard !takes.isEmpty else { return ids }
        let intervals = Set(takes.flatMap(\.activeIntervalIDs))
        let segments = Set(session.segments.filter { intervals.contains($0.intervalID) }.map(\.id))
        var children: [UUID: [UUID]] = [:]
        for transcript in session.transcripts {
            for previous in transcript.replacedRevisionIDs { children[previous, default: []].append(transcript.id) }
            if transcript.segmentIDs.contains(where: { segments.contains($0) }) { ids.insert(transcript.id) }
        }
        // Archives need not list corrections in topological order. Traverse each link once.
        var queue = Array(ids)
        var cursor = 0
        while cursor < queue.count {
            let parent = queue[cursor]
            cursor += 1
            for child in children[parent, default: []] where ids.insert(child).inserted { queue.append(child) }
        }
        return ids
    }

    private func editTranscriptIDs(in session: VoiceSession) -> Set<UUID> {
        transcriptIDs(for: (session.brief?.takes ?? []).filter { $0.intent == .editBrief }, in: session)
    }

    private func isContentTranscript(_ id: UUID, in session: VoiceSession) -> Bool {
        !editTranscriptIDs(in: session).contains(id)
    }

    func installModel(_ model: ModelDescriptor) async {
        guard !isRecording, let inference else { error = "Pause recording before installing a model."; return }
        await performWork("Installing \(model.displayName)") {
            let token = UUID()
            self.installTokens[model.id] = token
            self.installProgress[model.id] = 0
            defer {
                self.installTokens.removeValue(forKey: model.id)
                if self.installProgress[model.id] != 1 { self.installProgress.removeValue(forKey: model.id) }
            }
            do {
                let reference = WorkspaceReference(self)
                _ = try await inference.install(model) { [reference] progress in
                    Task { @MainActor in
                        guard let modelState = reference.value, modelState.installTokens[model.id] == token else { return }
                        modelState.installProgress[model.id] = progress
                    }
                }
                self.installedModelIDs.insert(model.id)
                self.installProgress[model.id] = 1
            } catch {
                self.installProgress.removeValue(forKey: model.id)
                self.installedModelIDs.remove(model.id)
                throw error
            }
        }
    }

    func importTranscript(text: String) async {
        guard let id = selectedSessionID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await cancelProcessing()
        let revision = TranscriptRevision(rawText: text, text: text, origin: .imported, timingPrecision: .unavailable)
        do {
            try await mutate(id) { session in
                session.transcripts.append(revision)
                var brief = session.brief ?? BriefDocument.migrating(session: session)
                brief.takes.append(BriefTake(intent: self.captureIntent, targetSection: self.selectedSectionKind,
                    expectedRevision: brief.revisionID, selectedBlockIDs: self.selectedBlockIDs,
                    status: .pending, transcriptIDs: [revision.id]))
                brief.reviewedRevisionID = nil
                session.brief = brief
                session.invalidateDerivedWork()
            }
        } catch { self.error = error.localizedDescription }
    }

    func correctTranscript(id transcriptID: UUID, text: String) async {
        guard let id = selectedSessionID else { return }
        await cancelProcessing()
        do {
            let snapshot = try requireSession(id)
            guard let original = snapshot.currentTranscripts.first(where: { $0.id == transcriptID }) else { throw KeystormError.message("Choose a current transcript revision.") }
            var revision = original
            revision.id = UUID()
            revision.createdAt = Date()
            revision.replacesID = original.id
            revision.replacesIDs = nil
            revision.text = text
            revision.isComplete = true
            let corrected = revision
            try await mutate(id) { session in
                session.transcripts.append(corrected)
                session.corrections.append(CorrectionPatch(originalRevisionID: original.id, correctedRevisionID: corrected.id, before: original.text, after: text))
                session.invalidateDerivedWork()
            }
        } catch { self.error = error.localizedDescription }
    }

    func undoLastCorrection() async {
        guard let id = selectedSessionID else { return }
        await cancelProcessing()
        do {
            let snapshot = try requireSession(id)
            let current = Set(snapshot.currentTranscripts.map(\.id))
            guard let patch = snapshot.corrections.last(where: { current.contains($0.correctedRevisionID) }), let source = snapshot.transcripts.first(where: { $0.id == patch.originalRevisionID }) else { throw KeystormError.message("There is no current correction to undo.") }
            let corrected = snapshot.transcripts.first { $0.id == patch.correctedRevisionID }
            let parents = corrected?.replacedRevisionIDs ?? [source.id]
            let originals = snapshot.transcripts.filter { parents.contains($0.id) }.sorted { $0.startTime < $1.startTime }
            let revisions = originals.map { original in
                var restored = original
                restored.id = UUID()
                restored.createdAt = Date()
                restored.replacesID = patch.correctedRevisionID
                restored.replacesIDs = nil
                return restored
            }
            try await mutate(id) { session in
                session.transcripts.append(contentsOf: revisions)
                session.invalidateDerivedWork()
            }
        } catch { self.error = error.localizedDescription }
    }

    func addDictionaryEntry(_ entry: DictionaryEntry) async {
        guard store != nil else { return }
        guard !entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "A dictionary entry needs its canonical spelling."; return }
        do {
            var entries = dictionary
            entries.append(entry)
            try await commitDictionary(entries)
        } catch { self.error = error.localizedDescription }
    }

    /// Approval changes apply only to subsequent transcription; existing patches remain immutable and undoable.
    func setDictionaryAutomatic(id: UUID, enabled: Bool) async {
        guard let index = dictionary.firstIndex(where: { $0.id == id }) else { error = "The dictionary entry is no longer available."; return }
        var entries = dictionary
        entries[index].automatic = enabled
        do { try await commitDictionary(entries) }
        catch { self.error = error.localizedDescription }
    }

    private func commitDictionary(_ entries: [DictionaryEntry]) async throws {
        guard let store else { throw KeystormError.message("The workspace is not ready.") }
        let previousEntries = dictionary
        dictionary = entries
        let previousWrite = dictionaryTail
        let write = Task {
            _ = try? await previousWrite?.value
            try await store.saveDictionary(entries)
        }
        dictionaryTail = write
        do { try await write.value }
        catch {
            if dictionary == entries { dictionary = previousEntries }
            throw error
        }
    }

    func addContext(title: String, content: String, filePath: String? = nil) async {
        guard let id = selectedSessionID else { return }
        await cancelProcessing()
        do {
            let context = ContextSnapshot(title: title, content: content, sha256: Self.hash(content), filePath: filePath)
            try await mutate(id) { session in session.contexts.append(context); session.invalidateDerivedWork() }
        } catch { self.error = error.localizedDescription }
    }

    func updateSession(title: String? = nil, task: String? = nil, project: String? = nil) async {
        guard let id = selectedSessionID else { return }
        await cancelProcessing()
        do {
            try await mutate(id) { session in
                if let title { session.title = title }
                if let task { session.taskDescription = task }
                if let project { session.projectPath = project.isEmpty ? nil : project }
                session.invalidateDerivedWork()
            }
        } catch { self.error = error.localizedDescription }
    }

    func updateFact(id factID: UUID, status: FactStatus, reviewed: Bool) async {
        guard let id = selectedSessionID else { return }
        await cancelProcessing()
        do {
            try await mutate(id) { session in
                guard let index = session.facts.firstIndex(where: { $0.id == factID }) else { return }
                for draft in session.drafts.indices { session.drafts[draft].stale = true }
                session.facts[index].status = status
                session.facts[index].reviewed = reviewed
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Explicit human classification. The quote is exact; a rewritten statement cites the whole revision.
    func addFact(transcriptID: UUID, text: String, kind: FactKind, status: FactStatus) async {
        guard let id = selectedSessionID else { return }
        await cancelProcessing()
        do {
            let snapshot = try requireSession(id)
            guard let transcript = snapshot.currentTranscripts.first(where: { $0.id == transcriptID }),
                  transcript.isComplete, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KeystormError.message("Review a complete current transcript before adding a fact.")
            }
            let match = transcript.text.range(of: text)
            let repeated = match.map { transcript.text.range(of: text, range: $0.upperBound..<transcript.text.endIndex) != nil } ?? false
            let range = (repeated ? nil : match) ?? transcript.text.startIndex..<transcript.text.endIndex
            let start = transcript.text[..<range.lowerBound].utf8.count
            let quote = String(transcript.text[range])
            guard !quote.isEmpty else { throw KeystormError.message("An empty transcript cannot support a fact.") }
            guard isContentTranscript(transcriptID, in: snapshot) else { throw KeystormError.message("Edit commands are retained as edit evidence and cannot become requirements.") }
            let fact = Fact(kind: kind, status: status, text: text,
                sources: [SourceReference(transcriptID: transcript.id, startUTF8: start, endUTF8: start + quote.utf8.count, quote: quote)], reviewed: true)
            try await mutate(id) { session in
                session.facts.append(fact)
                for index in session.drafts.indices { session.drafts[index].stale = true }
            }
        } catch { self.error = error.localizedDescription }
    }

    func amendDraft(text: String) async {
        guard let id = selectedSessionID, let existing = currentDraft else { return }
        var revision = existing
        revision.id = UUID()
        revision.createdAt = Date()
        revision.text = text
        revision.reviewed = false
        do { try await mutate(id) { $0.drafts.append(revision) } }
        catch { self.error = error.localizedDescription }
    }

    func reviewDraft() async {
        guard let id = selectedSessionID, let draft = currentDraft else { return }
        do {
            let snapshot = try requireSession(id)
            guard !draft.stale, draft.transcriptIDs == snapshot.currentTranscripts.map(\.id), draft.contextIDs == snapshot.contexts.map(\.id) else { throw KeystormError.message("Prepare a fresh draft before approving it.") }
            try LedgerValidation.validate(snapshot.facts, transcripts: snapshot.transcripts)
            guard LedgerValidation.currentFacts(in: snapshot).allSatisfy(\.reviewed) else { throw KeystormError.message("Review each source-linked fact before approving the draft.") }
            try await mutate(id) { session in
                if let index = session.drafts.firstIndex(where: { $0.id == draft.id }) { session.drafts[index].reviewed = true }
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Rows are indexed once per changed session snapshot; capture clock updates never rebuild them.
    private func recordingRows(in snapshot: VoiceSession) -> [RecordingRow] {
        if let cached = recordingRowCache[snapshot.id] { return cached }
        let takes = snapshot.brief?.takes ?? []
        var intervalOwners: [UUID: UUID] = [:]
        var transcriptOwners: [UUID: UUID] = [:]
        var activeIntervals: [UUID: Set<UUID>] = [:]
        for take in takes {
            for interval in take.allIntervalIDs { intervalOwners[interval] = take.id }
            for transcript in take.transcriptIDs { transcriptOwners[transcript] = take.id }
            activeIntervals[take.id] = Set(take.activeIntervalIDs)
        }
        var segmentOwners: [UUID: UUID] = [:]
        var segmentsByTake: [UUID: [AudioSegment]] = [:]
        for segment in snapshot.segments {
            if let owner = intervalOwners[segment.intervalID] {
                segmentOwners[segment.id] = owner
                if activeIntervals[owner]?.contains(segment.intervalID) == true {
                    segmentsByTake[owner, default: []].append(segment)
                }
            }
        }
        let selectedSegmentsByTake = segmentsByTake.mapValues { Set($0.map(\.id)) }
        let replaced = Set(snapshot.transcripts.flatMap(\.replacedRevisionIDs))
        let byID = Dictionary(snapshot.transcripts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var transcriptsByTake: [UUID: [TranscriptRevision]] = [:]
        for transcript in snapshot.transcripts where !replaced.contains(transcript.id) {
            let sourceOwner = transcript.segmentIDs.compactMap { segmentOwners[$0] }.first
            var owner = sourceOwner ?? transcriptOwners[transcript.id]
            var parent = transcript.replacesID
            var visited = Set<UUID>()
            while owner == nil, let id = parent, visited.insert(id).inserted {
                owner = transcriptOwners[id]
                parent = byID[id]?.replacesID
            }
            guard let owner else { continue }
            if !transcript.segmentIDs.isEmpty {
                let selected = selectedSegmentsByTake[owner] ?? []
                guard transcript.segmentIDs.allSatisfy(selected.contains) else { continue }
            }
            transcriptsByTake[owner, default: []].append(transcript)
        }
        let result = takes.sorted { $0.createdAt < $1.createdAt }.map { take in
            let segments = (segmentsByTake[take.id] ?? []).sorted { $0.startTime < $1.startTime }
            let transcripts = (transcriptsByTake[take.id] ?? []).sorted { $0.startTime < $1.startTime }
            return RecordingRow(id: take.id, sessionID: snapshot.id, sessionTitle: snapshot.title,
                parentIsTrashed: snapshot.trashedAt != nil, take: take,
                duration: segments.reduce(0) { $0 + $1.duration }, transcripts: transcripts,
                transcriptText: transcripts.map(\.text).joined(separator: " "), segments: segments)
        }
        recordingRowCache[snapshot.id] = result
        return result
    }

    /// Library changes serialize with pending saves and lock source mutations only for their commit.
    private func editLibrarySession(_ id: UUID, sourceChange: Bool = true,
                                    change: (inout VoiceSession) throws -> Void) async throws {
        guard !isRecording, !isCaptureTransitioning, !isEditingRecording, !changingSession else {
            throw KeystormError.message("Pause recording and wait for the current change to finish.")
        }
        tailTranscriptionToken = nil
        await cancelProcessing()
        await flushBriefEdits()
        guard !isRecording, !isCaptureTransitioning, !isEditingRecording, !changingSession,
              let store, let index = sessions.firstIndex(where: { $0.id == id }) else {
            throw KeystormError.message("The requested brief is no longer ready to change.")
        }
        error = nil
        var updated = sessions[index]
        try change(&updated)
        if sourceChange {
            updated.invalidateDerivedWork()
            updated.brief?.pendingProposal = nil
            updated.brief?.reviewedRevisionID = nil
        }
        updated.updatedAt = Date()
        isEditingRecording = true; changingSession = true; isBusy = true
        stopPlayback()
        defer { isEditingRecording = false; changingSession = false; isBusy = workTask != nil; activity = "Ready"; pruneHydratedSessions() }
        try await durableSave(updated, to: store)
        sessions[index] = updated
    }

    func renameSession(id: UUID, title: String) async {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4_096 else { error = "Enter a brief title under 4 KB."; return }
        do { try await editLibrarySession(id) { $0.title = value } }
        catch { self.error = error.localizedDescription }
    }
    func trashSession(id: UUID) async {
        do {
            try await editLibrarySession(id) { session in
                guard session.trashedAt == nil else { return }
                session.trashedAt = Date()
            }
            if selectedSessionID == id { selectedSessionID = activeSessions.first?.id }
        } catch { self.error = error.localizedDescription }
    }
    func restoreSession(id: UUID) async {
        do {
            try await editLibrarySession(id) { $0.trashedAt = nil }
            selectedSessionID = id
        } catch { self.error = error.localizedDescription }
    }
    func renameTake(id: UUID, title: String) async {
        guard let sessionID = selectedSessionID else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4_096 else { error = "Enter a recording name under 4 KB."; return }
        do {
            try await editLibrarySession(sessionID, sourceChange: false) { session in
                guard let index = session.brief?.takes.firstIndex(where: { $0.id == id }) else { throw KeystormError.message("This recording no longer exists.") }
                session.brief?.takes[index].name = value
            }
        } catch { self.error = error.localizedDescription }
    }
    func trashTake(id: UUID) async {
        guard let sessionID = selectedSessionID else { return }
        do {
            try await editLibrarySession(sessionID) { session in
                guard let index = session.brief?.takes.firstIndex(where: { $0.id == id }) else { throw KeystormError.message("This recording no longer exists.") }
                session.brief?.takes[index].trashedAt = Date()
            }
        } catch { self.error = error.localizedDescription }
    }
    func restoreTake(sessionID: UUID, takeID: UUID) async {
        do {
            try await editLibrarySession(sessionID) { session in
                guard session.trashedAt == nil else { throw KeystormError.message("Restore the containing brief first.") }
                guard let index = session.brief?.takes.firstIndex(where: { $0.id == takeID }) else { throw KeystormError.message("This recording no longer exists.") }
                if session.brief?.takes[index].status == .paused,
                   session.brief?.takes.contains(where: { $0.id != takeID && $0.trashedAt == nil && $0.status == .paused }) == true {
                    session.brief?.takes[index].status = .pending
                }
                session.brief?.takes[index].trashedAt = nil
            }
        } catch { self.error = error.localizedDescription }
    }
    func stopPlayback() { player?.stop(); player = nil; takePlayer.stop() }
    /// Recording tools are addressed by stable identities, never by whichever row is selected later.
    func dictationRecordingForTools(_ handle: DictationRecordingHandle) throws -> RecordingRow {
        guard let snapshot = session(handle.sessionID), snapshot.trashedAt == nil,
              let row = recordingRows(in: snapshot).first(where: { $0.id == handle.takeID && $0.take.trashedAt == nil }) else {
            throw KeystormError.message("This saved recording is no longer available.")
        }
        return row
    }

    private func selectRecordingForTools(_ handle: DictationRecordingHandle, requireAudio: Bool = true) throws -> RecordingRow {
        guard !terminating, !isRecording, !isCaptureTransitioning, !isBusy, !isEditingRecording, !changingSession else {
            throw KeystormError.message("Finish the current recording or processing operation before using recording tools.")
        }
        let row = try dictationRecordingForTools(handle)
        guard row.take.status != .recording, row.take.status != .paused else {
            throw KeystormError.message("Finish this paused recording before editing its saved audio.")
        }
        if requireAudio {
            guard !row.segments.isEmpty, row.duration.isFinite, row.duration > 0 else {
                throw KeystormError.message("This recording has no selected audio. Import replacement audio or restore an available version.")
            }
            let unavailable = Set(session(handle.sessionID)?.unavailableSegmentIDs ?? [])
            guard row.segments.allSatisfy({ !unavailable.contains($0.id) }) else {
                throw KeystormError.message("The selected audio is unavailable. Restore its source files before playing, editing, or exporting it.")
            }
        }
        try selectDictation(handle)
        return row
    }

    private func finishRecordingTool(_ handle: DictationRecordingHandle) throws {
        if let error { throw KeystormError.message(error) }
        guard !isRecording, !isCaptureTransitioning, selectedSessionID == handle.sessionID else {
            throw KeystormError.message("The recording selection changed. Reopen its tools before continuing.")
        }
        _ = try dictationRecordingForTools(handle)
    }

    func dictationPlayRecording(_ handle: DictationRecordingHandle) async throws {
        _ = try selectRecordingForTools(handle)
        error = nil
        await playTake(id: handle.takeID)
        try finishRecordingTool(handle)
    }

    func dictationTrimRecording(_ handle: DictationRecordingHandle, start: Double, end: Double) async throws {
        _ = try selectRecordingForTools(handle)
        error = nil
        await trimTake(id: handle.takeID, start: start, end: end)
        try finishRecordingTool(handle)
    }

    func dictationReplaceRecording(_ handle: DictationRecordingHandle, from source: URL) async throws {
        _ = try selectRecordingForTools(handle, requireAudio: false)
        error = nil
        await replaceTake(id: handle.takeID, from: source)
        try finishRecordingTool(handle)
    }

    func dictationRestoreRecording(_ handle: DictationRecordingHandle, revisionID: UUID?) async throws {
        _ = try selectRecordingForTools(handle, requireAudio: false)
        error = nil
        await restoreTakeAudioVersion(id: handle.takeID, revisionID: revisionID)
        try finishRecordingTool(handle)
    }

    /// Reuses the existing portable source archive, preserving all takes and versions in this session.
    func dictationExportRecordingArchive(_ handle: DictationRecordingHandle, to destination: URL) async throws {
        _ = try selectRecordingForTools(handle)
        error = nil
        guard let store else { throw KeystormError.message("Local recording storage is unavailable.") }
        let snapshot = try requireSession(handle.sessionID)
        isEditingRecording = true
        changingSession = true
        defer { isEditingRecording = false; changingSession = false; pruneHydratedSessions() }
        let audio = try await store.audioDirectory(handle.sessionID)
        try Task.checkCancellation()
        guard selectedSessionID == handle.sessionID else {
            throw KeystormError.message("The recording selection changed before export.")
        }
        try await Task.detached(priority: .userInitiated) {
            try SessionTransfer.exportArchive(session: snapshot, audioDirectory: audio, to: destination)
        }.value
        guard session(handle.sessionID)?.brief?.takes.contains(where: { $0.id == handle.takeID && $0.trashedAt == nil }) == true else {
            throw KeystormError.message("The exported recording is no longer in this library.")
        }
    }

    func playTake(id: UUID) async {
        guard !isRecording, !isCaptureTransitioning, let sessionID = selectedSessionID, let store,
              let row = recordings.first(where: { $0.id == id }), !row.segments.isEmpty else { return }
        do {
            let snapshot = try requireSession(sessionID)
            guard !row.segments.contains(where: { snapshot.unavailableSegmentIDs.contains($0.id) }) else {
                throw KeystormError.message("Restore unavailable audio before playing this recording.")
            }
            stopPlayback()
            let directory = try await store.audioDirectory(sessionID)
            guard !isRecording, !isCaptureTransitioning, !isEditingRecording, selectedSessionID == sessionID else { return }
            try takePlayer.play(segments: row.segments, directory: directory) { [weak self] message in self?.error = message }
        } catch { self.error = error.localizedDescription }
    }
    func correctTakeTranscript(id: UUID, text: String) async {
        guard let sessionID = selectedSessionID, text.utf8.count <= 1_048_576 else {
            error = "Keep a recording transcript under 1 MB."; return
        }
        do {
            try await editLibrarySession(sessionID) { session in
                guard let index = session.brief?.takes.firstIndex(where: { $0.id == id && $0.trashedAt == nil }),
                      let take = session.brief?.takes[index] else { throw KeystormError.message("Choose an active recording.") }
                let segments = session.takeSegments(take)
                guard let first = segments.first, let last = segments.last else { throw KeystormError.message("This recording has no audio to annotate.") }
                let ids = Set(segments.map(\.id))
                let current = session.currentTranscripts.filter { !$0.segmentIDs.isEmpty && $0.segmentIDs.allSatisfy(ids.contains) }
                if current.isEmpty {
                    let transcript = TranscriptRevision(rawText: "", text: text, segmentIDs: segments.map(\.id),
                        startTime: first.startTime, endTime: last.endTime, timingPrecision: .window)
                    session.transcripts.append(transcript)
                    session.brief?.takes[index].transcriptIDs.append(transcript.id)
                } else {
                    // A deliberate whole-recording correction names every replaced source window
                    // and covers the complete selected audio, retaining each original ASR revision.
                    var corrected = TranscriptRevision(rawText: current.map(\.rawText).joined(separator: " "), text: text,
                        segmentIDs: segments.map(\.id), startTime: first.startTime,
                        endTime: last.endTime, timingPrecision: .window)
                    corrected.replacesIDs = current.map(\.id)
                    corrected.replacesID = current.first?.id
                    session.transcripts.append(corrected)
                    for original in current {
                        session.corrections.append(CorrectionPatch(originalRevisionID: original.id, correctedRevisionID: corrected.id,
                            before: original.text, after: text))
                    }
                    session.brief?.takes[index].transcriptIDs.append(corrected.id)
                }
                if session.brief?.takes[index].status != .paused { session.brief?.takes[index].status = .pending }
            }
        } catch { self.error = error.localizedDescription }
    }
    func trimTake(id: UUID, start: Double, end: Double) async {
        await renderRecordingVersion(id: id, replacement: nil, trim: (start, end))
    }
    func replaceTake(id: UUID, from source: URL) async {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        await renderRecordingVersion(id: id, replacement: source, trim: nil)
    }
    private func renderRecordingVersion(id: UUID, replacement: URL?, trim: (Double, Double)?) async {
        guard !isRecording, !isCaptureTransitioning, !isBusy, !isEditingRecording, let sessionID = selectedSessionID else {
            error = "Pause recording and wait for processing before editing audio."; return
        }
        tailTranscriptionToken = nil
        await cancelProcessing()
        await flushBriefEdits()
        guard !isRecording, !isCaptureTransitioning, !isBusy, !isEditingRecording, !changingSession,
              selectedSessionID == sessionID,
              let store, let original = session(sessionID), original.trashedAt == nil,
              let takeIndex = original.brief?.takes.firstIndex(where: { $0.id == id && $0.trashedAt == nil }),
              let take = original.brief?.takes[takeIndex] else { error = "Choose an active recording."; return }
        guard (take.audioRevisions?.count ?? 0) < 100 else { error = "This recording already has 100 audio versions."; return }
        error = nil
        isEditingRecording = true; changingSession = true; isBusy = true
        activity = replacement == nil ? "Trimming recording" : "Importing replacement audio"
        stopPlayback()
        defer { isEditingRecording = false; changingSession = false; isBusy = workTask != nil; activity = "Ready" }
        var staging: URL?
        do {
            let sessionDirectory = try await store.sessionDirectory(sessionID)
            let directory = try await store.audioDirectory(sessionID)
            let stage = sessionDirectory.appendingPathComponent(".recording-edit-\(UUID().uuidString)", isDirectory: true)
            staging = stage
            let segments = original.takeSegments(take)
            guard replacement != nil || !segments.contains(where: { original.unavailableSegmentIDs.contains($0.id) }) else {
                throw KeystormError.message("Restore unavailable source audio before editing this recording.")
            }
            let rendered = try await Task.detached(priority: .userInitiated) {
                if let replacement { return try RecordingAudioEditor.replace(from: replacement, staging: stage, timelineStart: original.recordedDuration) }
                guard let trim else { throw KeystormError.message("Choose a trim range.") }
                return try RecordingAudioEditor.trim(segments: segments, audioDirectory: directory, staging: stage,
                    start: trim.0, end: trim.1, timelineStart: original.recordedDuration)
            }.value
            guard let index = sessions.firstIndex(where: { $0.id == sessionID }), sessions[index].updatedAt == original.updatedAt else {
                throw KeystormError.message("The brief changed while audio was being prepared. Retry the recording edit.")
            }
            var updated = original
            let revision = RecordingAudioRevision(label: replacement == nil ? "Trimmed recording" : "Replacement audio", intervalIDs: rendered.intervals.map(\.id))
            updated.segments.append(contentsOf: rendered.segments)
            updated.intervals.append(contentsOf: rendered.intervals)
            if updated.brief?.takes[takeIndex].audioRevisions == nil { updated.brief?.takes[takeIndex].audioRevisions = [] }
            updated.brief?.takes[takeIndex].audioRevisions?.append(revision)
            updated.brief?.takes[takeIndex].activeAudioRevisionID = revision.id
            updated.brief?.takes[takeIndex].status = .pending
            try updated.invalidateDictationOutput(takeID: id)
            updated.invalidateDerivedWork(); updated.brief?.pendingProposal = nil; updated.brief?.reviewedRevisionID = nil
            updated.updatedAt = Date()
            try await store.commitRecordingEdit(updated, stagedDirectory: rendered.directory, expectedUpdatedAt: original.updatedAt)
            sessions[index] = updated
            scheduleHistoryRefresh()
            if recordingHUDSession?.sessionID == sessionID, recordingHUDSession?.takeID == id {
                recordingHUDSession?.finish()
                recordingHUDSnapshot = recordingHUDSession?.snapshot
            }
        } catch {
            let publicationError = error.localizedDescription
            let hasJournal = staging.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("publication.json").path) } ?? false
            if let staging, !hasJournal {
                await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staging) }.value
            } else if hasJournal {
                // The synchronized snapshot can already be newer than SQLite when publication fails.
                // Reload it while the edit lock is held, so later saves cannot drop committed source.
                do {
                    guard let durable = try await store.loadSession(sessionID) else {
                        throw KeystormError.message("The durable brief could not be found.")
                    }
                    if let index = sessions.firstIndex(where: { $0.id == sessionID }),
                       durable.updatedAt >= sessions[index].updatedAt {
                        sessions[index] = durable
                    }
                    recoveryMessages.append("Recording edit publication was interrupted. Saved brief state was reloaded and original audio was retained; inspect the selected audio version before retrying.")
                } catch {
                    recoveryMessages.append("Saved state could not be reloaded after the recording edit: " + error.localizedDescription + " The edit journal and original audio were retained; reopen Keystorm to recover them before retrying.")
                }
            }
            self.error = publicationError
        }
    }
    func restoreTakeAudioVersion(id: UUID, revisionID: UUID?) async {
        guard !isRecording, !isCaptureTransitioning, !isEditingRecording, !changingSession,
              let sessionID = selectedSessionID,
              let take = selectedSession?.brief?.takes.first(where: { $0.id == id && $0.trashedAt == nil }) else { return }
        guard take.activeAudioRevisionID != revisionID else { error = nil; return }
        do {
            try await editLibrarySession(sessionID) { session in
                guard let index = session.brief?.takes.firstIndex(where: { $0.id == id && $0.trashedAt == nil }) else { throw KeystormError.message("Choose an active recording.") }
                if let revisionID, session.brief?.takes[index].audioRevisions?.contains(where: { $0.id == revisionID }) != true {
                    throw KeystormError.message("This audio version no longer exists.")
                }
                session.brief?.takes[index].activeAudioRevisionID = revisionID
                session.brief?.takes[index].status = .pending
                try session.invalidateDictationOutput(takeID: id)
            }
            if recordingHUDSession?.sessionID == sessionID, recordingHUDSession?.takeID == id {
                recordingHUDSession?.finish()
                recordingHUDSnapshot = recordingHUDSession?.snapshot
            }
        } catch { self.error = error.localizedDescription }
    }

    func playback(segment: AudioSegment) async {
        guard !isRecording, !isCaptureTransitioning, let id = selectedSessionID, let store else { return }
        do {
            guard session(id)?.unavailableSegmentIDs.contains(segment.id) == false else { throw KeystormError.message("This audio segment is unavailable. Inspect its recovery warning.") }
            stopPlayback()
            let url = try await store.audioURL(for: segment, in: id)
            guard !isRecording, !isCaptureTransitioning, !isEditingRecording, selectedSessionID == id else { return }
            player = try AVAudioPlayer(contentsOf: url)
            guard player?.play() == true else { throw KeystormError.message("The audio segment could not be played.") }
        } catch { self.error = error.localizedDescription }
    }

    func registerImportedSession(_ imported: VoiceSession) async throws {
        guard !isRecording, !isCaptureTransitioning, !isEditingRecording, !changingSession else {
            throw KeystormError.message("Pause recording and finish the current change before importing a brief.")
        }
        guard let store else { throw KeystormError.message("The workspace is not ready.") }
        guard try await !store.containsSession(imported.id) else { throw KeystormError.message("This session is already present.") }
        var registered = imported
        registered.materializeLegacyRecordings()
        try await store.save(registered)
        guard !isEditingRecording, !changingSession else { throw KeystormError.message("The imported brief was saved. Open it after the current recording change finishes.") }
        sessions.insert(registered, at: 0)
        selectedSessionID = registered.id
        hydratedUseOrder.append(registered.id)
        pruneHydratedSessions()
        scheduleHistoryRefresh()
    }

    func stopForTermination() async {
        terminating = true
        historyRefreshTask?.cancel()
        let historyTask = historySelectionTask
        cancelHistorySelection()
        _ = try? await historyTask?.value
        learningDictionary?.cancelPendingClassification()
        await learningDictionary?.waitUntilSettled()
        await flushBriefEdits()
        await waitForCaptureStart()
        await pauseRecording()
        await cancelProcessing()
        stopPlayback()
        speechIdleRelease?.cancel()
        await inference?.shutdown()
        await commitTail?.value
        _ = try? await persistenceTail?.value
        _ = try? await dictionaryTail?.value
    }

    private func waitForCaptureStart() async {
        guard captureStartInProgress else { return }
        await withCheckedContinuation { continuation in captureStartWaiters.append(continuation) }
    }

    private func approvedCorrections(for original: TranscriptRevision, projectPath: String?) -> (revisions: [TranscriptRevision], patches: [CorrectionPatch]) {
        let candidates = Terminology.suggestions(in: original.text, entries: dictionary.filter(\.automatic), projectPath: projectPath)
        let unambiguous = candidates.filter { candidate in
            !candidates.contains { other in
                other.id != candidate.id && max(other.startUTF8, candidate.startUTF8) < min(other.endUTF8, candidate.endUTF8)
            }
        }.sorted { $0.startUTF8 > $1.startUTF8 }
        var previous = original
        var revisions: [TranscriptRevision] = []
        var patches: [CorrectionPatch] = []
        for suggestion in unambiguous {
            guard let corrected = try? Terminology.applying(suggestion, to: previous.text), corrected != previous.text else { continue }
            var revision = previous
            revision.id = UUID()
            revision.createdAt = Date()
            revision.replacesID = previous.id
            revision.replacesIDs = nil
            revision.text = corrected
            patches.append(CorrectionPatch(originalRevisionID: previous.id, correctedRevisionID: revision.id, before: previous.text, after: corrected, dictionaryEntryID: suggestion.entryID))
            revisions.append(revision)
            previous = revision
        }
        return (revisions, patches)
    }

    private func hasManualCoverage(_ transcript: TranscriptRevision, facts: [Fact]) -> Bool {
        let sources = facts.flatMap(\.sources).filter { $0.transcriptID == transcript.id }
        var through = 0
        for source in sources.sorted(by: { $0.startUTF8 < $1.startUTF8 }) {
            if source.startUTF8 > through { return false }
            through = max(through, source.endUTF8)
        }
        return through >= transcript.text.utf8.count
    }

    func performWork(_ label: String, clearsError: Bool = true, allowsLearningAfter: Bool = true,
                     kind: WorkspaceWorkKind = .general, action: @escaping @MainActor () async throws -> Void) async {
        guard let task = beginWork(label, clearsError: clearsError, allowsLearningAfter: allowsLearningAfter,
                                   kind: kind, action: action) else { return }
        // Awaiting an unstructured task does not propagate the caller's cancellation.
        // Cancel this exact owned task and keep joining until inference cleanup drains.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Claims the single work lane synchronously and returns its owned task, or nil when busy.
    @discardableResult
    private func beginWork(_ label: String, clearsError: Bool = true, allowsLearningAfter: Bool = true,
                           kind: WorkspaceWorkKind = .general,
                           action: @escaping @MainActor () async throws -> Void) -> Task<Void, Never>? {
        guard workTask == nil, !terminating, !isEditingRecording else { error = "Wait for the current operation to finish."; return nil }
        let token = UUID()
        workToken = token
        isBusy = true
        activity = label
        if clearsError { error = nil }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded = false
            do {
                try Task.checkCancellation()
                try await action()
                succeeded = !Task.isCancelled
            }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            switch kind {
            case .speech:
                // Speech work never loads the text model. Cancelling a request in flight has
                // already ended the worker; otherwise both resident models keep their normal lease.
                await self.inference?.finishSpeechJob()
            case .general, .textPrewarm:
                if succeeded { await self.inference?.finishTextJob() }
                else { await self.inference?.releaseText() }
            }
            if !self.isRecording { self.scheduleSpeechIdleRelease() }
            guard self.workToken == token else { return }
            self.workTask = nil
            self.workToken = nil
            self.workKind = .general
            self.isBusy = self.changingCapture
            self.activity = self.isRecording ? "Recording locally" : "Ready"
            if succeeded, allowsLearningAfter, !self.isRecording, !self.isCaptureTransitioning,
               !self.terminating, self.foregroundDictationTakes.isEmpty {
                self.learningDictionary?.drainPending()
            }
        }
        workTask = task
        workKind = kind
        return task
    }

    /// Live-loop speech work. Pause stops the loop between jobs but lets a short request in
    /// flight finish, because cancelling it ends the worker process and every resident model.
    /// Cancel, termination and a new capture still cancel the work itself through `workTask`.
    private func performLiveWork(_ label: String, clearsError: Bool,
                                 action: @escaping @MainActor () async throws -> Void) async {
        guard let task = beginWork(label, clearsError: clearsError, kind: .speech, action: action) else { return }
        await task.value
    }

    /// One text-model load per Clean or Email take, started by the live loop after its first
    /// window. It takes the shared lane like any job, so it never overlaps a speech request,
    /// never runs during an install and never sets a user-visible error.
    private func startTextPrewarmIfDue(epoch: UUID) {
        guard let textPrewarm, textPrewarm.isArmed(for: epoch), workTask == nil, !terminating,
              !isEditingRecording, installTokens.isEmpty,
              installedModelIDs.contains(ModelCatalog.primaryText.id),
              textPrewarm.claim(epoch: epoch) else { return }
        beginTextPrewarm(textPrewarm)
    }

    @discardableResult
    private func beginTextPrewarm(_ controller: TextPrewarmController,
                                  completion: (@MainActor (TextPrewarmRun) -> Void)? = nil) -> Task<Void, Never>? {
        beginWork("Preparing the local text model", clearsError: false, allowsLearningAfter: false,
                  kind: .textPrewarm) { [weak self] in
            guard let run = await controller.run() else { return }
            if let milliseconds = run.metricMilliseconds {
                self?.recordPerformance(kind: TextPrewarmPolicy.metricKind, milliseconds: milliseconds)
            }
            completion?(run)
        }
    }

    /// Explicit warm-up through the shared lane, for example before a timed Finish. Returns nil
    /// without any user-visible error when the lane is busy or the workspace is not ready.
    @discardableResult
    func prewarmTextModel() async -> TextPrewarmRun? {
        guard let textPrewarm, workTask == nil, !terminating, !isEditingRecording, installTokens.isEmpty else { return nil }
        var result: TextPrewarmRun?
        guard let task = beginTextPrewarm(textPrewarm, completion: { result = $0 }) else { return nil }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return result
    }

    /// Finish needs the shared worker next. Speech work and a text prewarm already in flight
    /// finish instead of being cancelled, because cancelling a request in flight ends the
    /// worker process and both resident models. Returns false at the limit; the caller then
    /// cancels whatever is still running, as before.
    @discardableResult
    func joinModelWorkBeforeFinish(limit: Duration = TextPrewarmPolicy.finishJoinLimit) async -> Bool {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: limit)
        var waited = false
        defer {
            if waited {
                recordPerformance(kind: TextPrewarmPolicy.finishJoinMetricKind, milliseconds: started.duration(to: .now).milliseconds)
            }
        }
        var previous: Task<Void, Never>?
        while let task = workTask, workKind != .general {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard task != previous, !Task.isCancelled, remaining > .zero else { return false }
            previous = task
            waited = true
            guard await ModelWorkJoin.wait(for: task, within: remaining) else { return false }
        }
        return true
    }

    private func cancelProcessing() async {
        let cancelStarted = ContinuousClock.now
        let hadWork = workTask != nil || phaseTeardownTail != nil
        defer {
            if hadWork { recordPerformance(kind: "processing.cancel", milliseconds: cancelStarted.duration(to: .now).milliseconds) }
        }
        let task = workTask
        let kind = workKind
        task?.cancel()
        await task?.value
        await phaseTeardownTail?.value
        // Cancelled speech work never held the text model; a request in flight already ended the worker.
        if task != nil, kind != .speech { await inference?.releaseText() }
        else { await inference?.finishTextJob() }
        // Idle models remain bounded by the worker's residency lease.
        if !isRecording { scheduleSpeechIdleRelease() }
    }

    private func remember(_ configuration: ProcessingConfiguration, in id: UUID) async throws {
        guard session(id)?.configurations.contains(where: { $0.id == configuration.id }) != true else { return }
        try await mutate(id) { $0.configurations.append(configuration) }
    }

    private func session(_ id: UUID) -> VoiceSession? { sessions.first { $0.id == id } }

    private func requireSession(_ id: UUID) throws -> VoiceSession {
        guard let session = session(id) else { throw KeystormError.message("The target session is no longer available.") }
        return session
    }

    private func mutate(_ id: UUID, _ change: (inout VoiceSession) throws -> Void) async throws {
        guard !isEditingRecording else { throw KeystormError.message("Wait for the recording change to finish.") }
        guard let index = sessions.firstIndex(where: { $0.id == id }), let store else { throw KeystormError.message("The workspace is not ready.") }
        var copy = sessions[index]
        try change(&copy)
        if copy.transcripts != sessions[index].transcripts || copy.contexts != sessions[index].contexts ||
            copy.facts != sessions[index].facts || !copy.taskDescription.utf8.elementsEqual(sessions[index].taskDescription.utf8) ||
            copy.projectPath.map({ Data($0.utf8) }) != sessions[index].projectPath.map({ Data($0.utf8) }) ||
            !copy.title.utf8.elementsEqual(sessions[index].title.utf8) ||
            copy.gaps != sessions[index].gaps || copy.unavailableSegmentIDs != sessions[index].unavailableSegmentIDs {
            copy.brief?.reviewedRevisionID = nil
        }
        copy.updatedAt = Date()
        sessions[index] = copy
        dirtyBriefSessionIDs.insert(id)
        try await durableSave(copy, to: store)
        if session(id)?.updatedAt == copy.updatedAt { dirtyBriefSessionIDs.remove(id) }
        pruneHydratedSessions()
    }

    private func persist(_ id: UUID) async throws {
        guard let store else { return }
        try await durableSave(requireSession(id), to: store)
    }

    private func durableSave(_ snapshot: VoiceSession, to store: SessionStore) async throws {
        let saveStarted = ContinuousClock.now
        defer { recordPerformance(kind: "brief.persistence", milliseconds: saveStarted.duration(to: .now).milliseconds) }
        let previous = persistenceTail
        let write = Task {
            // A failed previous save does not discard a newer recoverable snapshot.
            _ = try? await previous?.value
            try await store.save(snapshot)
        }
        persistenceTail = write
        try await write.value
        scheduleHistoryRefresh()
    }

    private struct SourceIdentity: Equatable {
        var transcripts: [UUID]
        var contexts: [UUID]
        var segments: [UUID]
        var intervals: [UUID]
        var gaps: [UUID]
        var unavailable: [UUID]
        var task: Data
        var project: Data?
        var title: Data
        var status: SessionStatus
        var trashedAt: Date?
        var inactiveIntervals: Set<UUID>

        init(_ session: VoiceSession) {
            transcripts = session.currentTranscripts.map(\.id)
            contexts = session.contexts.map(\.id)
            segments = session.segments.map(\.id)
            intervals = session.intervals.map(\.id)
            gaps = session.gaps.map(\.id)
            unavailable = session.unavailableSegmentIDs
            task = Data(session.taskDescription.utf8)
            project = session.projectPath.map { Data($0.utf8) }
            title = Data(session.title.utf8)
            status = session.status
            trashedAt = session.trashedAt
            inactiveIntervals = session.inactiveRecordingIntervalIDs
        }
    }

    nonisolated private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A stable Sendable reference avoids mutable weak captures across nested callback tasks.
@MainActor
private final class WorkspaceReference {
    weak var value: WorkspaceModel?
    init(_ value: WorkspaceModel) { self.value = value }
}

/// The recorder deposits synchronously before dispatching a main-actor notification.
/// Pause can therefore drain committed audio even if its UI notification has not run yet.
private final class CommittedAudioMailbox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [AudioSegment]())
    func append(_ segment: AudioSegment) { lock.withLock { $0.append(segment) } }
    func take() -> [AudioSegment] { lock.withLock { segments in let result = segments; segments.removeAll(keepingCapacity: true); return result } }
}

/// What the single work lane is running, so Finish and cancellation can treat it correctly.
enum WorkspaceWorkKind {
    /// Text or mixed work. Cancellation or failure releases the text model, as before.
    case general
    /// Speech-only work. It never loads the text model; Finish joins it while in flight.
    case speech
    /// A best-effort text-model warm-up. Finish joins it; Cancel and termination cancel it.
    case textPrewarm
}

private extension Duration {
    var milliseconds: Double {
        let value = components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1_000_000_000_000_000
    }
}

#if DEBUG
/// A canvas-only document. Construction does no I/O and uses no personal application data.
extension WorkspaceModel {
    static func workspacePreview() -> WorkspaceModel {
        let model = WorkspaceModel(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-Preview", isDirectory: true))
        var brief = BriefDocument()
        brief.sections = [
            BriefSection(kind: .goal, blocks: [
                BriefBlock(text: "Turn a spoken idea into a clear implementation brief, with room to think before committing to a change.")
            ]),
            BriefSection(kind: .changes, blocks: [
                BriefBlock(text: "Give the writing workspace a calmer hierarchy. Keep the document central and recording controls within easy reach."),
                BriefBlock(text: "Review each proposed change before it becomes part of the brief.")
            ]),
            BriefSection(kind: .constraints, blocks: [
                BriefBlock(text: "Keep recording and processing on this Mac. Preserve original recordings and exact references."),
                BriefBlock(text: "maximumSavedTakes = 256", exact: true)
            ]),
            BriefSection(kind: .acceptance, blocks: [
                BriefBlock(text: "A new brief is ready to write in immediately. Recording, review, and export are easy to find.")
            ]),
            BriefSection(kind: .deferred),
            BriefSection(kind: .questions)
        ]
        var session = VoiceSession()
        session.title = "A calmer writing workspace"
        session.brief = brief
        model.sessions = [session]
        model.selectedSessionID = session.id
        return model
    }
}
#endif


extension WorkspaceModel: DictationRecordingBackend {
    func dictationBegin() async throws -> DictationRecordingHandle {
        try await dictationBegin(mode: .verbatim)
    }

    func dictationBegin(mode: DictationQuickMode) async throws -> DictationRecordingHandle {
        cancelHistorySelection()
        learningDictionary?.cancelPendingClassification()
        try await prepareDictationMode(mode)
        try Task.checkCancellation()
        guard store != nil, !terminating, !isRecording, !isCaptureTransitioning, !isEditingRecording else {
            throw KeystormError.message("Wait for the current recording operation to finish.")
        }
        guard installedModelIDs.contains(ModelCatalog.primarySpeech.id) else {
            throw KeystormError.message("Install the local multilingual speech model in Local Models before recording.")
        }
        let previous = selectedSessionID
        await newSession()
        guard let id = selectedSessionID, id != previous else {
            throw KeystormError.message(error ?? "A new dictation recording could not be created.")
        }
        try await mutate(id) { $0.dictation = DictationSession(); $0.title = "Dictation · " + Date().formatted(date: .abbreviated, time: .shortened) }
        selectedSpeechModelID = ModelCatalog.primarySpeech.id
        captureIntent = .addMaterial
        pendingCaptureQuickMode = mode
        await startRecording()
        pendingCaptureQuickMode = nil
        guard isRecording, let take = openTake else {
            throw KeystormError.message(error ?? "The microphone could not start. Check Microphone access in System Settings.")
        }
        let handle = DictationRecordingHandle(sessionID: id, takeID: take.id)
        do {
            try await mutate(id) { session in
                session.materializeDictationMetadata()
                guard let index = session.dictation?.recordings.firstIndex(where: { $0.id == take.id }) else {
                    throw KeystormError.message("The recording mode could not be saved.")
                }
                session.dictation?.recordings[index].captureMode = mode
            }
            try await dictationSave(handle, state: .recording, revision: nil, delivery: nil, failure: nil)
        }
        catch {
            await pauseRecording()
            throw error
        }
        return handle
    }

    func dictationMetadata(_ handle: DictationRecordingHandle) -> DictationRecordingMetadata? {
        session(handle.sessionID)?.dictation?.recordings.first { $0.id == handle.takeID }
    }

    func dictationCaptureStatus(_ handle: DictationRecordingHandle) -> DictationCaptureStatus? {
        guard let snapshot = session(handle.sessionID), snapshot.trashedAt == nil,
              let take = snapshot.brief?.takes.first(where: { $0.id == handle.takeID && $0.trashedAt == nil }) else { return nil }
        if recordingSessionID == handle.sessionID, isRecording, openTake?.id == handle.takeID { return .recording }
        if snapshot.status == .interrupted {
            return .interrupted(snapshot.gaps.last?.reason ?? "The audio device stopped.")
        }
        if take.status == .paused { return .paused }
        return nil
    }

    func dictationCancel(_ handle: DictationRecordingHandle) async throws {
        await waitForCaptureStart()
        if let capturePauseTask { await capturePauseTask.value }
        try selectDictation(handle)
        if isRecording, openTake?.id == handle.takeID { await pauseRecording() }
        guard !isRecording, !isCaptureTransitioning else {
            throw KeystormError.message("The microphone has not stopped. Try Cancel again before starting another recording.")
        }
        tailTranscriptionToken = nil
        await cancelProcessing()
        if openTake?.id == handle.takeID { await finishTake() }
        try await dictationSave(handle, state: .cancelled, revision: nil, delivery: nil, failure: nil)
        dismissRecordingHUD()
    }

    private func selectDictation(_ handle: DictationRecordingHandle) throws {
        guard !terminating, let snapshot = session(handle.sessionID), snapshot.trashedAt == nil,
              snapshot.brief?.takes.contains(where: { $0.id == handle.takeID && $0.trashedAt == nil }) == true else {
            throw KeystormError.message("This saved recording is no longer available.")
        }
        if selectedSessionID != handle.sessionID { selectedSessionID = handle.sessionID }
        guard selectedSessionID == handle.sessionID else {
            throw KeystormError.message("Finish the current recording before changing sessions.")
        }
    }

    func dictationPause(_ handle: DictationRecordingHandle) async throws {
        try selectDictation(handle)
        guard openTake?.id == handle.takeID else { throw KeystormError.message("The active recording changed.") }
        await pauseRecording()
        guard !isRecording, !isCaptureTransitioning else { throw KeystormError.message(error ?? "The recording could not pause.") }
        try await dictationSave(handle, state: .paused, revision: nil, delivery: nil, failure: nil)
    }

    private func prepareDictationMode(_ mode: DictationQuickMode) async throws {
        guard mode.transformsOnFinish else { return }
        guard let inference, installedModelIDs.contains(ModelCatalog.primaryText.id) else {
            throw KeystormError.message(mode == .email ?
                "Install the local text model before recording in Email mode, or choose Verbatim." :
                "Install the local text model before recording in Clean mode, or choose Verbatim.")
        }
        _ = try await inference.configuration(for: ModelCatalog.primaryText)
        try Task.checkCancellation()
    }

    func dictationResume(_ handle: DictationRecordingHandle) async throws {
        try selectDictation(handle)
        let mode = dictationMetadata(handle)?.captureMode ?? .verbatim
        try await prepareDictationMode(mode)
        try Task.checkCancellation()
        guard openTake?.id == handle.takeID, canResumeTake,
              installedModelIDs.contains(ModelCatalog.primarySpeech.id) else {
            throw KeystormError.message("This recording cannot resume, or its local speech model is unavailable.")
        }
        selectedSpeechModelID = ModelCatalog.primarySpeech.id
        pendingCaptureQuickMode = mode
        await resumeRecording()
        pendingCaptureQuickMode = nil
        guard isRecording else { throw KeystormError.message(error ?? "The microphone could not resume.") }
        do { try await dictationSave(handle, state: .recording, revision: nil, delivery: nil, failure: nil) }
        catch { await pauseRecording(); throw error }
    }

    func dictationComplete(_ handle: DictationRecordingHandle) async throws -> DictationTextRevision {
        try selectDictation(handle)
        if isRecording { try await dictationPause(handle) }
        guard !isCaptureTransitioning else { throw KeystormError.message("Wait for the audio to finish saving.") }
        if openTake?.id == handle.takeID { await finishTake() }
        // Disable delayed tail scheduling before joining the shared worker. No competing model phases.
        tailTranscriptionToken = nil
        // Speech or prewarm work already in flight finishes (bounded) rather than ending the worker.
        await joinModelWorkBeforeFinish()
        await cancelProcessing()
        guard !isRecording, !isCaptureTransitioning, !isBusy,
              installedModelIDs.contains(ModelCatalog.primarySpeech.id) else {
            throw KeystormError.message("The saved recording needs its local multilingual speech model before finishing.")
        }
        try Task.checkCancellation()
        selectedSpeechModelID = ModelCatalog.primarySpeech.id
        try await mutate(handle.sessionID) { session in
            guard let index = session.dictation?.recordings.firstIndex(where: { $0.id == handle.takeID }) else {
                throw DictationTransformError.staleSource
            }
            try session.dictation?.recordings[index].checkpointCurrentOutput()
            session.dictation?.recordings[index].state = .processing
            session.dictation?.recordings[index].failureMessage = nil
            session.dictation?.recordings[index].updatedAt = Date()
        }
        await performWork("Finishing local dictation", kind: .speech) {
            try await self.runTranscription(handle.sessionID, retryIncomplete: true)
        }
        try Task.checkCancellation()
        let snapshot = try requireSession(handle.sessionID)
        let revision = try Self.completeDictationText(in: snapshot, takeID: handle.takeID)
        try await dictationSave(handle, state: .ready, revision: revision, delivery: nil, failure: nil)
        let terms = await learningDictionary?.suggestions(for: revision.text,
            appBundleID: dictationMetadata(handle)?.captureAppBundleID) ?? []
        try Task.checkCancellation()
        let application = LearnedTermApplicator.apply(suggestions: terms, to: revision.text)
        if !application.termIDs.isEmpty {
            do {
                try await editLibrarySession(handle.sessionID, sourceChange: false) { session in
                    guard let index = session.dictation?.recordings.firstIndex(where: { $0.id == handle.takeID }) else {
                        throw DictationTransformError.staleSource
                    }
                    try session.dictation?.recordings[index].stageLearnedCorrection(source: revision, application: application)
                }
            } catch {
                // Learning is optional: preserve the already-durable raw completion on any limit/failure.
                recoveryMessages.append("A learned spelling could not be applied; the original transcript was kept.")
            }
        }
        dismissRecordingHUD()
        return dictationMetadata(handle)?.textRevision ?? revision
    }

    /// Never expose a partial window as a complete insertion candidate.
    static func completeDictationText(in snapshot: VoiceSession, takeID: UUID) throws -> DictationTextRevision {
        guard let take = snapshot.brief?.takes.first(where: { $0.id == takeID && $0.trashedAt == nil }) else {
            throw KeystormError.message("The recording is unavailable.")
        }
        let segments = snapshot.takeSegments(take)
        let ids = Set(segments.map(\.id))
        let selectedIntervals = Set(take.activeIntervalIDs)
        let knownSegments = Set(snapshot.segments.map(\.id))
        let knownIntervals = Set(snapshot.intervals.map(\.id))
        for gap in snapshot.gaps {
            let affectedSegments = Set(gap.segmentIDs ?? [])
            let affectedIntervals = Set(gap.intervalIDs ?? [])
            guard (!affectedSegments.isEmpty || !affectedIntervals.isEmpty),
                  affectedSegments.isSubset(of: knownSegments), affectedIntervals.isSubset(of: knownIntervals) else {
                throw KeystormError.message("A recovery gap has no reliable recording scope. Review the saved audio before completing this recording; nothing was inserted.")
            }
            guard affectedSegments.isDisjoint(with: ids), affectedIntervals.isDisjoint(with: selectedIntervals) else {
                throw KeystormError.message("Capture reported missing audio in this recording. The saved recording needs review; nothing was inserted.")
            }
        }
        guard !ids.isEmpty, Set(snapshot.unavailableSegmentIDs).isDisjoint(with: ids) else {
            throw KeystormError.message("This recording has no saved audio, or some audio is unavailable. Nothing was inserted.")
        }
        // Writer intervals must have contiguous owned audio. Pause downtime lives outside this timeline.
        for interval in take.activeIntervalIDs {
            let audio = segments.filter { $0.intervalID == interval }
            guard !audio.isEmpty else { throw KeystormError.message("An interval has no saved audio. Nothing was inserted.") }
            for pair in zip(audio, audio.dropFirst()) {
                guard abs(pair.0.endTime - pair.1.startTime) <= 1 / pair.0.sampleRate else {
                    throw KeystormError.message("There is a gap in the saved audio. Nothing was inserted.")
                }
            }
        }
        let transcripts = snapshot.currentTranscripts.filter {
            !$0.segmentIDs.isEmpty && !$0.segmentIDs.allSatisfy { !ids.contains($0) }
        }.sorted { $0.startTime < $1.startTime }
        guard Set(segments.map(\.id)).count == segments.count,
              transcripts.allSatisfy({ transcript in
                  let owned = segments.filter { transcript.segmentIDs.contains($0.id) }
                  guard let first = owned.first, let last = owned.last else { return false }
                  return transcript.isComplete && Set(transcript.segmentIDs).isSubset(of: ids) &&
                      Set(transcript.segmentIDs).count == transcript.segmentIDs.count &&
                      Set(owned.map(\.intervalID)).count == 1 &&
                      transcript.startTime.isFinite && transcript.endTime.isFinite &&
                      abs(transcript.startTime - first.startTime) <= 0.001 &&
                      abs(transcript.endTime - last.endTime) <= 0.001
              }),
              ids.allSatisfy({ id in transcripts.filter { $0.segmentIDs.contains(id) }.count == 1 }) else {
            throw KeystormError.message("Some saved audio has not been transcribed completely. Nothing was inserted; finish again to retry.")
        }
        let rawText = transcripts.map(\.rawText).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = transcripts.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw KeystormError.message("No speech was recognized. The original audio is saved.") }
        return DictationTextRevision(rawText: rawText, text: text, sourceTranscriptIDs: transcripts.map(\.id))
    }

    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode) async throws -> DictationTransformResult {
        try await dictationTransform(handle, source: source, mode: mode, context: nil)
    }

    func dictationTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                            mode: DictationOutputMode, context: DictationContextSnapshot?) async throws -> DictationTransformResult {
        learningDictionary?.cancelPendingClassification()
        await learningDictionary?.waitUntilSettled()
        try Task.checkCancellation()
        try selectDictation(handle)
        try context?.validate()
        if let context, !context.isFresh() { throw DictationTransformError.staleSource }
        guard !isRecording, !isCaptureTransitioning, !isBusy, !isEditingRecording,
              let inference, installedModelIDs.contains(ModelCatalog.primaryText.id) else {
            throw KeystormError.message("Install the local text model in Local Models, then wait for current processing to finish.")
        }
        guard source.text.utf8.count <= DictationTransformPolicy.maxSourceUTF8,
              let current = dictationMetadata(handle)?.textRevision, current == source,
              current.text.utf8.elementsEqual(source.text.utf8) else {
            throw KeystormError.message("The saved source changed or is too long for one preview. Your recording is unchanged.")
        }
        let configuration = try await inference.configuration(for: ModelCatalog.primaryText)
        try await remember(configuration, in: handle.sessionID)
        try Task.checkCancellation()
        guard !isRecording, !isCaptureTransitioning, !isBusy, !isEditingRecording, !terminating,
              dictationMetadata(handle)?.textRevision == source else { throw DictationTransformError.staleSource }
        let request = DictationTransformRequest(sourceRevisionID: source.id,
            sourceSHA256: DictationTransformPolicy.sourceDigest(source.text), mode: mode,
            sourceText: source.text, configuration: configuration, context: context)
        var output: DictationTransformResult?
        var failure: (any Error)?
        await performWork("Preparing local " + mode.displayTitle) {
            do { output = try await inference.transform(request) }
            catch { failure = error; throw error }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        guard let output, let current = dictationMetadata(handle)?.textRevision,
              current.id == source.id, current.text.utf8.elementsEqual(source.text.utf8) else {
            throw KeystormError.message("The source changed while generating. The current text is unchanged.")
        }
        try DictationTransformPolicy.validate(output, request: request)
        return output
    }

    func dictationApplyTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                 result: DictationTransformResult) async throws -> DictationRecordingMetadata {
        try await dictationApplyTransform(handle, source: source, result: result, context: nil)
    }

    func dictationApplyTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                 result: DictationTransformResult, context: DictationContextSnapshot?) async throws -> DictationRecordingMetadata {
        try selectDictation(handle)
        guard let configuration = session(handle.sessionID)?.configurations.first(where: { $0.id == result.configurationID }) else {
            throw KeystormError.message("The preview's local model configuration is unavailable. Generate a new preview.")
        }
        let request = DictationTransformRequest(jobID: result.jobID, sourceRevisionID: source.id,
            sourceSHA256: DictationTransformPolicy.sourceDigest(source.text), mode: result.mode,
            sourceText: source.text, configuration: configuration, context: context)
        try DictationTransformPolicy.validate(result, request: request)
        try Task.checkCancellation()
        try await editLibrarySession(handle.sessionID, sourceChange: false) { session in
            guard let index = session.dictation?.recordings.firstIndex(where: { $0.id == handle.takeID }) else {
                throw KeystormError.message("This recording is no longer available.")
            }
            try session.dictation?.recordings[index].stageTransform(source: source, result: result, context: context)
        }
        guard let metadata = dictationMetadata(handle) else { throw KeystormError.message("The saved output could not be reopened.") }
        return metadata
    }

    func dictationLongTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
        mode: DictationOutputMode) async throws -> LongDictationTransformResult {
        learningDictionary?.cancelPendingClassification()
        await learningDictionary?.waitUntilSettled()
        try Task.checkCancellation()
        try selectDictation(handle)
        guard !isRecording, !isCaptureTransitioning, !isBusy, !isEditingRecording,
              let inference, installedModelIDs.contains(ModelCatalog.primaryText.id),
              let metadata = dictationMetadata(handle), metadata.textRevision == source else {
            throw KeystormError.message("Install the local text model and finish the current operation before preparing a long preview.")
        }
        try metadata.preflightLongTransformHistory(source: source)
        let configuration = try await inference.configuration(for: ModelCatalog.primaryText)
        try Task.checkCancellation()
        guard !isRecording, !isCaptureTransitioning, !isBusy, !isEditingRecording,
              !terminating, dictationMetadata(handle)?.textRevision == source else {
            throw DictationTransformError.staleSource
        }
        let plan = try LongDictationTransformService.plan(source: source, mode: mode, configuration: configuration)
        try metadata.preflightLongTransformHistory(source: source, plan: plan)
        try await remember(configuration, in: handle.sessionID)
        try Task.checkCancellation()
        guard !isRecording, !isCaptureTransitioning, !isBusy, !isEditingRecording, !terminating,
              dictationMetadata(handle)?.textRevision == source else { throw DictationTransformError.staleSource }
        var output: LongDictationTransformResult?
        var failure: (any Error)?
        await performWork("Preparing long local " + mode.displayTitle) {
            do {
                output = try await LongDictationTransformService.run(source: source, mode: mode,
                    configuration: configuration,
                    onProgress: { [weak self] completed, total in
                        await self?.updateLongTransformProgress(completed, total: total)
                    },
                    transform: { request in try await inference.transform(request) })
            } catch { failure = error; throw error }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        guard let output, dictationMetadata(handle)?.textRevision == source else {
            throw DictationTransformError.staleSource
        }
        try LongDictationTransformService.validate(output, source: source, mode: mode, configuration: configuration)
        return output
    }

    private func updateLongTransformProgress(_ completed: Int, total: Int) {
        activity = "Preparing section " + String(completed) + " of " + String(total)
    }

    func dictationApplyLongTransform(_ handle: DictationRecordingHandle, source: DictationTextRevision,
        result: LongDictationTransformResult) async throws -> DictationRecordingMetadata {
        try selectDictation(handle)
        guard let configuration = session(handle.sessionID)?.configurations.first(where: { $0.id == result.configurationID }),
              configuration == result.plan.configuration else { throw LongDictationTransformError.invalidResult }
        try LongDictationTransformService.validate(result, source: source, configuration: configuration)
        try Task.checkCancellation()
        try await editLibrarySession(handle.sessionID, sourceChange: false) { session in
            guard let index = session.dictation?.recordings.firstIndex(where: { $0.id == handle.takeID }) else {
                throw DictationTransformError.staleSource
            }
            try session.dictation?.recordings[index].stageLongTransform(source: source, result: result)
        }
        guard let metadata = dictationMetadata(handle) else { throw DictationTransformError.invalidHistory }
        return metadata
    }

    func dictationSelectOutput(_ handle: DictationRecordingHandle, id: UUID) async throws -> DictationRecordingMetadata {
        try selectDictation(handle)
        try Task.checkCancellation()
        try await editLibrarySession(handle.sessionID, sourceChange: false) { session in
            guard let index = session.dictation?.recordings.firstIndex(where: { $0.id == handle.takeID }) else {
                throw KeystormError.message("This recording is no longer available.")
            }
            try session.dictation?.recordings[index].selectOutput(id: id)
        }
        guard let metadata = dictationMetadata(handle) else { throw KeystormError.message("The saved version could not be reopened.") }
        return metadata
    }

    func dictationSetPurpose(_ handle: DictationRecordingHandle, purpose: DictationRecordingPurpose) async throws {
        try await mutate(handle.sessionID) { session in
            guard let index = session.dictation?.recordings.firstIndex(where: { $0.id == handle.takeID }) else {
                throw KeystormError.message("The active recording is unavailable.")
            }
            session.dictation?.recordings[index].purpose = purpose
        }
    }

    func dictationSetLearningScope(_ handle: DictationRecordingHandle, appBundleID: String?) async throws {
        try selectDictation(handle)
        guard appBundleID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else {
            throw KeystormError.message("The recording application identity is invalid.")
        }
        try await mutate(handle.sessionID) { session in
            guard let index = session.dictation?.recordings.firstIndex(where: { $0.id == handle.takeID }) else {
                throw DictationTransformError.staleSource
            }
            session.dictation?.recordings[index].captureAppBundleID = appBundleID
        }
    }

    func dictationSetForegroundProcessing(_ handle: DictationRecordingHandle, active: Bool) {
        if active {
            foregroundDictationTakes.insert(handle.takeID)
            learningDictionary?.cancelPendingClassification()
        } else {
            foregroundDictationTakes.remove(handle.takeID)
            if foregroundDictationTakes.isEmpty, !isRecording, !isCaptureTransitioning, !isBusy, !terminating {
                learningDictionary?.drainPending()
            }
        }
    }

    var dictationExternalCorrectionConsentID: UUID? {
        guard !terminating, !isRecording, !isCaptureTransitioning, !isBusy, !isEditingRecording,
              !changingSession, foregroundDictationTakes.isEmpty,
              let learningDictionary, learningDictionary.isEnabled,
              learningDictionary.externalCorrectionsEnabled else { return nil }
        return learningDictionary.externalCorrectionConsentGeneration
    }

    func dictationObserveExternalCorrectionConsentChanges(_ onChange: @escaping @MainActor () -> Void) -> (any ExternalCorrectionCancellation)? {
        learningDictionary?.observeExternalCorrectionConsentChanges(onChange)
    }

    func dictationObservedExternalCorrection(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                                             observation: ExternalCorrectionObservation) async {
        guard !Task.isCancelled, dictationExternalCorrectionConsentID != nil,
              selectedSessionID == handle.sessionID, selectedSession?.trashedAt == nil,
              let metadata = dictationMetadata(handle), metadata.id == handle.takeID,
              metadata.state == .ready, metadata.purpose != .longRecording,
              metadata.textRevision == source, metadata.delivery?.state == .inserted,
              metadata.delivery?.requestID == observation.deliveryID,
              metadata.delivery?.textRevisionID == source.id,
              metadata.captureAppBundleID == observation.destination.bundleIdentifier,
              observation.destination.bundleIdentifier == ExternalCorrectionEvidencePolicy.supportedAppBundleID,
              observation.originalText.utf8.elementsEqual(source.text.utf8),
              observation.observedAt.timeIntervalSinceNow <= 1,
              Date().timeIntervalSince(observation.observedAt) <= ExternalCorrectionLease.lifetime,
              observation.observedAt >= observation.destination.capturedAt,
              let learningDictionary else { return }
        await learningDictionary.submitExternal(source: source, correctedText: observation.correctedText,
            sessionID: handle.sessionID, takeID: handle.takeID,
            appBundleID: observation.destination.bundleIdentifier,
            deliveryID: observation.deliveryID, observedAt: observation.observedAt)
    }

    func dictationUserEdited(_ handle: DictationRecordingHandle, source: DictationTextRevision,
                             edited: DictationTextRevision) async {
        guard !terminating, dictationMetadata(handle)?.textRevision == edited else { return }
        await learningDictionary?.submit(source: source, edited: edited,
            sessionID: handle.sessionID, takeID: handle.takeID,
            appBundleID: dictationMetadata(handle)?.captureAppBundleID)
    }

    private func classifyLearningCorrection(_ evidence: CorrectionEvidence) async throws -> CorrectionClassificationReceipt {
        guard !terminating, !isRecording, !isCaptureTransitioning, !isBusy, !isEditingRecording,
              foregroundDictationTakes.isEmpty,
              let inference, installedModelIDs.contains(ModelCatalog.primaryText.id) else {
            throw KeystormError.message("Local terminology review will resume when the text model is available and dictation is idle.")
        }
        try Task.checkCancellation()
        let configuration = try await inference.configuration(for: ModelCatalog.primaryText)
        try Task.checkCancellation()
        guard !isRecording, !isCaptureTransitioning, !isBusy, !isEditingRecording,
              foregroundDictationTakes.isEmpty, !terminating else { throw CancellationError() }
        let request = CorrectionClassificationRequest(evidence: evidence, configuration: configuration)
        var output: CorrectionClassificationResult?
        var failure: (any Error)?
        await performWork("Learning terminology locally", allowsLearningAfter: false) {
            do { output = try await inference.classifyCorrection(request) }
            catch { failure = error; throw error }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        guard let output else { throw CancellationError() }
        try CorrectionLearningPolicy.validate(output, request: request)
        return CorrectionClassificationReceipt(request: request, result: output)
    }

    func dictationSave(_ handle: DictationRecordingHandle, state: DictationRecordingState,
                       revision: DictationTextRevision?, delivery: DictationDelivery?, failure: String?) async throws {
        try Task.checkCancellation()
        try await ensureSessionLoaded(handle.sessionID)
        try await mutate(handle.sessionID) { session in
            session.materializeDictationMetadata()
            guard let index = session.dictation?.recordings.firstIndex(where: { $0.id == handle.takeID }) else {
                throw KeystormError.message("The dictation recording could not be found.")
            }
            session.dictation?.recordings[index].state = state
            session.dictation?.recordings[index].updatedAt = Date()
            session.dictation?.recordings[index].failureMessage = failure
            if let revision {
                if session.dictation?.recordings[index].textRevision?.id != revision.id {
                    session.dictation?.recordings[index].delivery = nil
                    session.dictation?.recordings[index].outputMode = .verbatim
                }
                session.dictation?.recordings[index].textRevision = revision
                if let active = session.dictation?.recordings[index].activeOutputID,
                   session.dictation?.recordings[index].outputHistory?.first(where: { $0.id == active })?.textRevision != revision {
                    session.dictation?.recordings[index].activeOutputID = nil
                }
            }
            if let delivery { session.dictation?.recordings[index].delivery = delivery }
        }
    }
}
