import Darwin
import Foundation

/// A synchronous lock makes the current combined-budget allowance visible to the
/// independent process watchdog even while the model actor is busy. Sampling is
/// a fail-stop backstop, not a claim of an instantaneous OS allocation quota.
final class InferenceWorkerFootprintGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var ceiling: UInt64 = 6 * 1_024 * 1_024 * 1_024
    private var peak: UInt64 = 0
    private var requestPeak: UInt64 = 0
    private var samples: UInt64 = 0
    private var requestID: UUID?

    func setCeiling(_ value: UInt64) {
        lock.lock()
        ceiling = value
        lock.unlock()
    }

    func setRequest(_ id: UUID) {
        lock.lock()
        requestID = id
        requestPeak = 0
        lock.unlock()
    }

    func statistics() -> [String: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return ["workerPeakFootprint": peak, "workerRequestPeakFootprint": requestPeak,
                "workerMemoryCeiling": ceiling, "workerFootprintSamples": samples]
    }

    func failureReplyIfExceeded(by footprint: UInt64, processID: Int32) -> InferenceWorkerReply? {
        lock.lock()
        defer { lock.unlock() }
        peak = max(peak, footprint)
        requestPeak = max(requestPeak, footprint)
        samples += 1
        guard footprint >= ceiling, let requestID else { return nil }
        return InferenceWorkerReply(id: requestID, succeeded: false,
            error: "The local worker exceeded its parent-subtracted memory ceiling. Saved sources are preserved.",
            processID: processID, memory: ["processFootprint": footprint,
                "workerPeakFootprint": peak, "workerRequestPeakFootprint": requestPeak,
                "workerMemoryCeiling": ceiling, "workerFootprintSamples": samples])
    }

    func exceeded(by footprint: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return footprint >= ceiling
    }
}

/// Private startup mode of the same signed executable. It never constructs the UI,
/// records audio, downloads files, opens a socket, or executes coding instructions.
enum InferenceWorkerDaemon {
    static let argument = "--inference-worker"

    static func run() async {
        guard let index = CommandLine.arguments.firstIndex(of: "--model-directory"),
              CommandLine.arguments.indices.contains(index + 1) else { return }
        let models = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        // Keep a dedicated protocol descriptor. All framework/stdout logging goes to
        // stderr, which the parent redirects to /dev/null rather than an unbounded pipe.
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { return }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let parent = getppid()
        guard parent > 1 else { return }
        let footprintGuard = InferenceWorkerFootprintGuard()
        let watchdog = Task.detached {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                if getppid() != parent { Darwin.exit(0) }
                // This sampler remains runnable while a synchronous Metal/Core ML job
                // occupies the engine actor. Exceeding the shared ceiling kills only
                // this disposable child; capture and durable files live in the parent.
                if let failure = footprintGuard.failureReplyIfExceeded(by: LocalInference.processFootprint(), processID: getpid()) {
                    // This source-free diagnostic frame stays below PIPE_BUF. It is
                    // emitted only at fail-stop, while no normal reply is pending.
                    if let frame = try? InferenceWorkerCodec.frame(failure) { try? output.write(contentsOf: frame) }
                    Darwin.exit(75)
                }
            }
        }
        defer { watchdog.cancel(); try? output.close() }
        let engine = LocalInference(modelDirectory: models)
        let reader = InferenceWorkerFrameReader(file: .standardInput)
        while !Task.isCancelled {
            do {
                guard let line = try await Task.detached(priority: .userInitiated, operation: {
                    try reader.nextLine()
                }).value else { break }
                let request = try InferenceWorkerCodec.decode(InferenceWorkerRequest.self, from: line)
                guard request.version == 1 else { break }
                footprintGuard.setRequest(request.id)
                var reply = InferenceWorkerReply(id: request.id, processID: getpid())
                do {
                    if [.prepareSpeech, .prepareText, .speechPreview, .speech, .extraction, .edit, .transform, .classifyCorrection].contains(request.operation) {
                        let budget: UInt64 = 6 * 1_024 * 1_024 * 1_024
                        guard request.parentFootprint > 0, request.parentFootprint < budget else {
                            throw KeystormError.message("Cannot establish sufficient combined app/worker memory headroom.")
                        }
                        let ceiling = budget - request.parentFootprint
                        footprintGuard.setCeiling(ceiling)
                        try await engine.setMemoryCeiling(Int(ceiling))
                    }
                    switch request.operation {
                    case .ping, .memory: break
                    #if DEBUG
                    case .debugWait: try await Task.sleep(for: .seconds(30))
                    #endif
                    case .prepareSpeech:
                        guard let id = request.modelID,
                              let model = ModelCatalog.models.first(where: { $0.id == id && $0.purpose == .speech }),
                              request.previewPCM == nil else {
                            throw KeystormError.message("Invalid speech preparation request.")
                        }
                        try await engine.prepareSpeech(model: model)
                    case .prepareText:
                        guard request.transform == nil, request.previewPCM == nil else {
                            throw KeystormError.message("Invalid local text preparation request.")
                        }
                        try await engine.prepareText()
                    case .speechPreview:
                        guard let id = request.modelID,
                              let model = ModelCatalog.models.first(where: { $0.id == id && $0.purpose == .speech }),
                              let pcm = request.previewPCM else {
                            throw KeystormError.message("Invalid bounded speech-preview request.")
                        }
                        // Validate bytes before loading the model; decode never trusts
                        // alignment, declared length, or Float32 finiteness.
                        let samples = try LiveSpeechPreviewPCM.decode(pcm)
                        reply.speechPreview = try await engine.transcribePreview(samples: samples, model: model)
                    case .speech:
                        guard let id = request.modelID,
                              let model = ModelCatalog.models.first(where: { $0.id == id && $0.purpose == .speech }),
                              let directory = request.audioDirectory, request.segments.count <= 3 else {
                            throw KeystormError.message("Invalid bounded speech-worker request.")
                        }
                        reply.speech = try await engine.transcribeWindow(segments: request.segments,
                            directory: directory, model: model)
                    case .transform:
                        guard let transform = request.transform,
                              transform.sourceText.utf8.count <= DictationTransformPolicy.maxSourceUTF8 else {
                            throw KeystormError.message("Invalid bounded dictation-transform request.")
                        }
                        reply.transform = try await engine.transform(transform)
                    case .classifyCorrection:
                        guard let correction = request.correction else {
                            throw KeystormError.message("Invalid local correction classification request.")
                        }
                        reply.correction = try await engine.classifyCorrection(correction)
                    case .extraction:
                        guard let configuration = request.configuration, request.transcripts.count <= 4,
                              request.contexts.count <= 32, request.priorFacts.count <= 128 else {
                            throw KeystormError.message("Invalid bounded extraction-worker request.")
                        }
                        reply.facts = try await engine.extract(transcripts: request.transcripts,
                            contexts: request.contexts, config: configuration, priorFacts: request.priorFacts)
                    case .edit:
                        guard let command = request.command, let document = request.document,
                              let section = request.targetSection, let configuration = request.configuration else {
                            throw KeystormError.message("Invalid bounded edit-worker request.")
                        }
                        reply.edits = try await engine.proposeBriefEdits(command: command, document: document,
                            targetSection: section, selectedBlockIDs: request.selectedBlockIDs,
                            sources: request.sources, config: configuration)
                    }
                } catch {
                    reply.succeeded = false
                    reply.error = String(error.localizedDescription.prefix(2_048))
                    reply.transformFailure = error as? DictationTransformGenerationFailure
                }
                reply.memory = await engine.memorySnapshot()
                reply.memory.merge(footprintGuard.statistics()) { _, value in value }
                reply.memory["integrityVerificationCount"] = UInt64(await engine.integrityVerificationCount)
                try output.write(contentsOf: InferenceWorkerCodec.frame(reply))
            } catch { break }
        }
        await engine.releaseSpeech()
        await engine.releaseText()
    }
}
