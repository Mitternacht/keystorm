import CryptoKit
import Darwin
import Foundation

/// Parent-side metadata stays cheap. All model execution occurs in a restartable
/// child of the same signed app; terminating a job cannot interrupt audio capture.
actor InferenceWorkerClient {
    private enum Phase { case none, speech, text }
    private struct Pending {
        let generation: UUID
        let continuation: CheckedContinuation<InferenceWorkerReply, any Error>
        var timeout: Task<Void, Never>?
    }

    private let modelDirectory: URL
    private let executableURL: URL?
    private let metadata: LocalInference
    private var worker: InferenceWorkerProcess?
    private var readerTask: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var pending: [UUID: Pending] = [:]
    private var phase: Phase = .none
    private var lastWorkerMemory: [String: UInt64] = [:]
    private var lastFailureMemory: [String: UInt64] = [:]
    private var lastWorkerTerminationStatus: UInt64 = 0
    private var idleRelease: Task<Void, Never>?
    private let idleRetention: Duration
    /// Warming never starts while artifacts may change on disk.
    private var installsInProgress = 0

    init(modelDirectory: URL, executableURL: URL? = Bundle.main.executableURL,
         idleRetention: Duration = .seconds(45)) {
        self.modelDirectory = modelDirectory
        self.executableURL = executableURL
        self.idleRetention = max(.zero, min(idleRetention, .seconds(45)))
        metadata = LocalInference(modelDirectory: modelDirectory)
    }

    deinit {
        idleRelease?.cancel()
        readerTask?.cancel()
        if let worker {
            if worker.process.isRunning { worker.process.terminate() }
            try? worker.input.fileHandleForWriting.close()
        }
    }

    func isInstalled(_ model: ModelDescriptor) async -> Bool { await metadata.isInstalled(model) }

    func configuration(for model: ModelDescriptor) async throws -> ProcessingConfiguration {
        try await metadata.configuration(for: model)
    }

    func verifiedConfiguration(for model: ModelDescriptor) async throws -> ProcessingConfiguration? {
        try await metadata.verifiedConfiguration(for: model)
    }

    var integrityVerificationCount: Int { Int(lastWorkerMemory["integrityVerificationCount"] ?? 0) }

    func install(_ model: ModelDescriptor, progress: @escaping @Sendable (Double) -> Void) async throws -> ProcessingConfiguration {
        installsInProgress += 1
        defer { installsInProgress -= 1 }
        await shutdown()
        return try await metadata.install(model, progress: progress)
    }

    func prepareSpeech(model: ModelDescriptor) async throws {
        _ = try await configuration(for: model)
        await transition(to: .speech)
        _ = try await call(InferenceWorkerRequest(operation: .prepareSpeech, modelID: model.id), timeoutSeconds: 180)
    }

    /// Loads only audited files already installed on this Mac. This call never
    /// opens the microphone, downloads a model, or starts a generation job.
    func prepareText() async throws {
        _ = try await configuration(for: ModelCatalog.primaryText)
        await transition(to: .text)
        _ = try await call(InferenceWorkerRequest(operation: .prepareText), timeoutSeconds: 180)
    }

    /// Best-effort warming before a Clean or Email Finish. Every outcome is quiet: nothing is
    /// thrown or shown, and the real transform still loads on demand. It never queues behind
    /// or interrupts another job, never reloads a resident model, never runs during an install,
    /// and never opens the microphone or network. The worker also refuses to evict a resident
    /// speech model for it. Cancelling an in-flight warm-up ends the worker, like any job.
    func prewarmText() async -> TextPrewarmOutcome {
        guard !Task.isCancelled else { return .cancelled }
        if let stopping { await stopping.value }
        guard installsInProgress == 0 else { return .installing }
        guard await metadata.isInstalled(ModelCatalog.primaryText) else { return .unavailable }
        // Actor state may have changed across the suspensions above.
        guard installsInProgress == 0 else { return .installing }
        if worker?.process.isRunning == true, lastWorkerMemory["textModelLoaded"] == 1 { return .alreadyResident }
        guard pending.isEmpty else { return .busy }
        await transition(to: .text)
        do {
            _ = try await call(InferenceWorkerRequest(operation: .prepareText),
                               timeoutSeconds: TextPrewarmPolicy.workerTimeoutSeconds)
            return .loaded
        } catch {
            return Task.isCancelled || error is CancellationError ? .cancelled : .failed
        }
    }

    func transcribePreview(samples: [Float], model: ModelDescriptor) async throws -> LiveSpeechPreviewResult {
        // Reject malformed/big input before launching a worker or switching phases.
        let pcm = try LiveSpeechPreviewPCM.encode(samples)
        _ = try await configuration(for: model)
        await transition(to: .speech)
        let request = InferenceWorkerRequest(operation: .speechPreview, modelID: model.id, previewPCM: pcm)
        let reply = try await call(request, timeoutSeconds: 30)
        guard let result = reply.speechPreview else {
            throw KeystormError.message("The speech worker returned no ephemeral preview.")
        }
        try result.validate(sampleCount: samples.count)
        return result
    }

    func transcribe(segments: [AudioSegment], directory: URL, model: ModelDescriptor) async throws -> TranscriptRevision {
        try await transcribeWindow(segments: segments, directory: directory, model: model).transcript
    }

    func transcribeWindow(segments: [AudioSegment], directory: URL, model: ModelDescriptor) async throws -> SpeechWindowResult {
        _ = try await configuration(for: model)
        await transition(to: .speech)
        let request = InferenceWorkerRequest(operation: .speech, modelID: model.id,
            audioDirectory: directory, segments: segments)
        let reply = try await call(request, timeoutSeconds: 180)
        guard let result = reply.speech else { throw KeystormError.message("The speech worker returned no complete result.") }
        return result
    }

    func transform(_ request: DictationTransformRequest) async throws -> DictationTransformResult {
        try LocalInference.validateTransformRequest(request)
        try Task.checkCancellation()
        if request.mode == .verbatim { return try LocalInference.verbatimTransform(request) }
        let installed = try await configuration(for: ModelCatalog.primaryText)
        guard installed == request.configuration else {
            throw KeystormError.message("The installed text-model configuration changed. Select its current revision again.")
        }
        await transition(to: .text)
        let reply = try await call(InferenceWorkerRequest(operation: .transform, transform: request), timeoutSeconds: 180)
        try Task.checkCancellation()
        guard let result = reply.transform else {
            throw KeystormError.message("The local worker returned no complete dictation transform.")
        }
        try LocalInference.validateTransformReply(result, request: request)
        return result
    }

    /// The caller queues learning only while capture is idle and cancels this task
    /// before starting a new take. It shares the same one-job worker admission guard.
    func classifyCorrection(_ request: CorrectionClassificationRequest) async throws -> CorrectionClassificationResult {
        try LocalInference.validateCorrectionRequest(request)
        try Task.checkCancellation()
        let installed = try await configuration(for: ModelCatalog.primaryText)
        guard installed == request.configuration else {
            throw KeystormError.message("The installed correction model configuration changed.")
        }
        await transition(to: .text)
        let reply = try await call(InferenceWorkerRequest(operation: .classifyCorrection, correction: request), timeoutSeconds: 90)
        try Task.checkCancellation()
        guard let result = reply.correction else {
            throw KeystormError.message("The local worker returned no complete correction classification.")
        }
        try CorrectionLearningPolicy.validate(result, request: request)
        return result
    }

    func extract(transcripts: [TranscriptRevision], contexts: [ContextSnapshot],
                 config: ProcessingConfiguration, priorFacts: [Fact] = []) async throws -> [Fact] {
        await transition(to: .text)
        let source = transcripts.map(\.text).joined(separator: "\n")
        let excerpt = LocalInference.contextExcerpt(for: source, from: contexts, byteLimit: 8_000)
        let digest = SHA256.hash(data: Data(excerpt.utf8)).map { String(format: "%02x", $0) }.joined()
        let boundedContext = excerpt.isEmpty ? [] : [ContextSnapshot(title: "Explicitly selected reference excerpts", content: excerpt, sha256: digest)]
        let boundedFacts = Array(LocalInference.relevantFacts(for: source, from: priorFacts, byteLimit: 12_000).prefix(128))
        let request = InferenceWorkerRequest(operation: .extraction, transcripts: transcripts,
            contexts: boundedContext, configuration: config, priorFacts: boundedFacts)
        let reply = try await call(request, timeoutSeconds: 300)
        guard let facts = reply.facts else { throw KeystormError.message("The extraction worker returned no complete facts.") }
        return facts
    }

    func proposeBriefEdits(command: String, document: BriefDocument, targetSection: BriefSectionKind,
                           selectedBlockIDs: [UUID], sources: [SourceReference],
                           config: ProcessingConfiguration) async throws -> [BriefEdit] {
        await transition(to: .text)
        // Carry only the explicitly selected section. Document history is never an LLM prompt.
        var bounded = BriefDocument()
        bounded.revisionID = document.revisionID
        bounded.sections = BriefSectionKind.allCases.map { kind in
            BriefSection(kind: kind, blocks: kind == targetSection ? document.section(kind).blocks.filter {
                selectedBlockIDs.isEmpty || selectedBlockIDs.contains($0.id)
            } : [])
        }
        let request = InferenceWorkerRequest(operation: .edit, configuration: config,
            command: command, document: bounded, targetSection: targetSection,
            selectedBlockIDs: selectedBlockIDs, sources: sources)
        let reply = try await call(request, timeoutSeconds: 300)
        guard let edits = reply.edits else { throw KeystormError.message("The edit worker returned no complete proposal.") }
        return edits
    }

    /// Successful jobs retain their model and immutable grammar resources briefly.
    /// One child owns both models; every actual inference job remains serialized.
    func finishTextJob() { scheduleIdleRelease() }
    func finishSpeechJob() { scheduleIdleRelease() }

    /// A process exit provides a stronger teardown boundary than releasing model references.
    func releaseSpeech() async {
        if phase == .speech || lastWorkerMemory["speechModelLoaded"] == 1 { await stopWorker(reason: CancellationError()) }
        else if let stopping { await stopping.value }
    }

    func releaseText() async {
        if phase == .text || lastWorkerMemory["textModelLoaded"] == 1 { await stopWorker(reason: CancellationError()) }
        else if let stopping { await stopping.value }
    }

    func shutdown() async { await stopWorker(reason: CancellationError()) }

    func memorySnapshot() async -> [String: UInt64] {
        if let stopping { await stopping.value }
        let parent = LocalInference.processFootprint()
        if worker != nil, pending.isEmpty,
           let reply = try? await call(InferenceWorkerRequest(operation: .memory), timeoutSeconds: 10) {
            lastWorkerMemory = reply.memory
        }
        let child = worker == nil ? 0 : (lastWorkerMemory["processFootprint"] ?? 0)
        var measurements: [String: UInt64] = [
            "processFootprint": parent + child,
            "parentFootprint": parent,
            "workerFootprint": child,
            "workerPID": worker.map { UInt64($0.process.processIdentifier) } ?? 0,
            "mlxActive": lastWorkerMemory["mlxActive"] ?? 0,
            "mlxCache": lastWorkerMemory["mlxCache"] ?? 0,
            "mlxPeak": lastWorkerMemory["mlxPeak"] ?? 0,
            "integrityVerificationCount": lastWorkerMemory["integrityVerificationCount"] ?? 0,
            "workerMemoryIsCached": pending.isEmpty ? 0 : 1,
            "lastWorkerTerminationStatus": lastWorkerTerminationStatus
        ]
        measurements.merge(lastWorkerMemory.filter {
            $0.key.hasPrefix("grammar") || $0.key.hasPrefix("textModel") || $0.key.hasPrefix("speechModel") ||
            ["workerPeakFootprint", "workerRequestPeakFootprint", "workerMemoryCeiling", "workerFootprintSamples"].contains($0.key)
        }) { _, new in new }
        for (key, value) in lastFailureMemory { measurements["lastFailure." + key] = value }
        return measurements
    }

    func ping() async throws -> InferenceWorkerIdentity {
        let reply = try await call(InferenceWorkerRequest(operation: .ping), timeoutSeconds: 10)
        return InferenceWorkerIdentity(processID: reply.processID, protocolVersion: reply.version)
    }

    #if DEBUG
    /// Exercises worker-side validation independently of the public samples encoder.
    func sendPreviewPCMForTesting(_ pcm: Data, model: ModelDescriptor) async throws -> LiveSpeechPreviewResult {
        await transition(to: .speech)
        let request = InferenceWorkerRequest(operation: .speechPreview, modelID: model.id, previewPCM: pcm)
        let reply = try await call(request, timeoutSeconds: 30)
        guard let result = reply.speechPreview else { throw KeystormError.message("No test preview was returned.") }
        return result
    }

    func waitInWorkerForTesting() async throws {
        _ = try await call(InferenceWorkerRequest(operation: .debugWait), timeoutSeconds: 60)
    }

    /// Holds the install guard without touching any model files.
    func beginInstallForTesting() { installsInProgress += 1 }
    func endInstallForTesting() { installsInProgress = max(0, installsInProgress - 1) }

    /// Integration-test fault injection affects only this client's private worker.
    func simulateWorkerCrashForTesting() async {
        guard let worker else { return }
        _ = kill(worker.process.processIdentifier, SIGKILL)
        await stopWorker(reason: KeystormError.message("Injected worker failure."))
    }
    #endif

    private func transition(to next: Phase) async {
        if let stopping { await stopping.value }
        // Phase is the last requested priority, not permission for concurrent work.
        // The single pending-job guard below still owns all model computation.
        if pending.isEmpty { phase = next }
    }

    private func call(_ original: InferenceWorkerRequest, timeoutSeconds: UInt64) async throws -> InferenceWorkerReply {
        try Task.checkCancellation()
        if let stopping { await stopping.value }
        guard pending.isEmpty else { throw KeystormError.message("Wait for the current local worker job to finish.") }
        idleRelease?.cancel()
        idleRelease = nil
        let box = try ensureWorker()
        var request = original
        request.parentFootprint = LocalInference.processFootprint()
        let frame = try InferenceWorkerCodec.frame(request)
        let requestID = request.id
        let generation = box.generation
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
                    await self?.requestTimedOut(requestID, generation: generation)
                }
                pending[requestID] = Pending(generation: generation, continuation: continuation, timeout: timeout)
                Task.detached(priority: .userInitiated) { [weak self] in
                    do { try box.input.fileHandleForWriting.write(contentsOf: frame) }
                    catch { await self?.transportFailed(generation: generation) }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.requestCancelled(requestID, generation: generation) }
        }
    }

    private func ensureWorker() throws -> InferenceWorkerProcess {
        if let worker, worker.process.isRunning { return worker }
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path),
              executableURL.lastPathComponent == "Keystorm" else {
            throw KeystormError.message("The installed Keystorm executable is unavailable for local inference.")
        }
        let box = InferenceWorkerProcess()
        box.process.executableURL = executableURL
        box.process.arguments = [InferenceWorkerDaemon.argument, "--model-directory", modelDirectory.path]
        // Test injection and DYLD overrides must never bootstrap a test runner in the child.
        box.process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("XCTest") && !$0.key.hasPrefix("XCInject") && !$0.key.hasPrefix("DYLD_")
        }
        box.process.standardInput = box.input
        box.process.standardOutput = box.output
        box.process.standardError = FileHandle.nullDevice
        guard fcntl(box.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw KeystormError.message("Cannot create a safe local worker pipe.")
        }
        let generation = box.generation
        box.process.terminationHandler = { [weak self] _ in
            Task { await self?.processExited(generation: generation) }
        }
        try box.process.run()
        worker = box
        let reader = InferenceWorkerFrameReader(file: box.output.fileHandleForReading)
        readerTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                while let line = try reader.nextLine() {
                    // Any very early runtime output is ignored unless it has our exact prefix.
                    guard line.starts(with: InferenceWorkerCodec.prefix) else { continue }
                    let reply = try InferenceWorkerCodec.decode(InferenceWorkerReply.self, from: line)
                    await self?.receive(reply, generation: generation)
                }
                await self?.transportFailed(generation: generation)
            } catch { await self?.transportFailed(generation: generation) }
        }
        return box
    }

    private func receive(_ reply: InferenceWorkerReply, generation: UUID) async {
        guard worker?.generation == generation, reply.version == 1,
              let waiting = pending.removeValue(forKey: reply.id), waiting.generation == generation else { return }
        waiting.timeout?.cancel()
        lastWorkerMemory = reply.memory
        if !reply.succeeded { lastFailureMemory = reply.memory }
        scheduleIdleRelease()
        let sampledRequestExceeded = (reply.memory["workerRequestPeakFootprint"] ?? 0) >=
            (reply.memory["workerMemoryCeiling"] ?? UInt64.max)
        if sampledRequestExceeded || LocalInference.processFootprint() + (reply.memory["processFootprint"] ?? 0) >= 6 * 1_024 * 1_024 * 1_024 {
            lastFailureMemory = reply.memory
            let parentMiB = LocalInference.processFootprint() / 1_048_576
            let childMiB = (reply.memory["processFootprint"] ?? 0) / 1_048_576
            let ceilingMiB = (reply.memory["workerMemoryCeiling"] ?? 0) / 1_048_576
            let error = KeystormError.message("The combined app and inference worker exceeded the provisional Mac memory budget (parent \(parentMiB) MiB, worker \(childMiB) MiB, worker ceiling \(ceilingMiB) MiB). Saved sources are preserved.")
            waiting.continuation.resume(throwing: error)
            await stopWorker(reason: error)
            return
        }
        if reply.succeeded { waiting.continuation.resume(returning: reply) }
        else {
            if let failure = reply.transformFailure,
               failure.message.utf8.count <= 8_192,
               failure.generatedEnvelope.utf8.count <= DictationTransformPolicy.maxOutputUTF8 * 6 + 1024,
               (0...2048).contains(failure.generatedTokens) {
                waiting.continuation.resume(throwing: failure)
            } else {
                waiting.continuation.resume(throwing: KeystormError.message(reply.error ?? "The local model job failed. Saved audio is preserved."))
            }
        }
    }

    private func requestCancelled(_ id: UUID, generation: UUID) async {
        guard pending[id]?.generation == generation else { return }
        await stopWorker(reason: CancellationError())
    }

    private func requestTimedOut(_ id: UUID, generation: UUID) async {
        guard pending[id]?.generation == generation else { return }
        await stopWorker(reason: KeystormError.message("The local worker exceeded this job's time limit. Saved sources are preserved; retry a smaller section."))
    }

    private func transportFailed(generation: UUID) async {
        guard worker?.generation == generation else { return }
        await stopWorker(reason: KeystormError.message("The local inference worker stopped. Saved audio and document changes are preserved. Retry to start a fresh worker."))
    }

    private func processExited(generation: UUID) async { await transportFailed(generation: generation) }

    private func scheduleIdleRelease() {
        idleRelease?.cancel()
        idleRelease = nil
        guard let generation = worker?.generation, pending.isEmpty else { return }
        let retention = idleRetention
        idleRelease = Task { [weak self] in
            do { try await Task.sleep(for: retention) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.releaseIdleWorker(generation: generation)
        }
    }

    private func releaseIdleWorker(generation: UUID) async {
        guard worker?.generation == generation, pending.isEmpty else { return }
        await stopWorker(reason: CancellationError())
    }

    private func stopWorker(reason: any Error) async {
        idleRelease?.cancel()
        idleRelease = nil
        if let stopping { await stopping.value; return }
        guard let box = worker else { phase = .none; return }
        worker = nil
        phase = .none
        lastWorkerMemory = [:]
        readerTask?.cancel()
        readerTask = nil
        for entry in pending.values {
            entry.timeout?.cancel()
            entry.continuation.resume(throwing: reason)
        }
        pending.removeAll()
        let stop = Task.detached {
            try? box.input.fileHandleForWriting.close()
            if box.process.isRunning { box.process.terminate() }
            let killFallback = Task.detached {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if box.process.isRunning { _ = kill(box.process.processIdentifier, SIGKILL) }
            }
            box.process.waitUntilExit()
            killFallback.cancel()
            try? box.output.fileHandleForReading.close()
        }
        stopping = stop
        await stop.value
        lastWorkerTerminationStatus = UInt64(max(0, box.process.terminationStatus))
        stopping = nil
    }
}

/// Process and pipe handles are touched only by the client actor, the one pipe
/// writer/reader, and Foundation's termination callback. Their lifetimes are shared.
private final class InferenceWorkerProcess: @unchecked Sendable {
    let generation = UUID()
    let process = Process()
    let input = Pipe()
    let output = Pipe()
}
