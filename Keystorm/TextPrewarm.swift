import Foundation

/// Outcome of one best-effort text-model prewarm. Every outcome is quiet: nothing is
/// thrown or shown, and the real Clean or Email transform still loads on demand.
nonisolated enum TextPrewarmOutcome: String, Codable, CaseIterable, Sendable {
    /// This request loaded the installed text model and its grammar resources.
    case loaded
    /// The worker already held the text model; nothing was loaded again.
    case alreadyResident
    /// The text model is not installed. No worker started.
    case unavailable
    /// A model install was in progress. No worker started.
    case installing
    /// Another worker job was running. Warming never queues behind or interrupts it.
    case busy
    /// Loading failed, for example without headroom to keep it beside the speech model.
    case failed
    case cancelled
}

/// Fixed prewarm parameters shared by the client, the workspace and the metrics report.
nonisolated enum TextPrewarmPolicy {
    /// Runtime metric for a load this prewarm performed. Other outcomes did no model work.
    static let metricKind = "text.prewarm"
    /// Runtime metric for how long Finish waited for speech or prewarm work already in flight.
    static let finishJoinMetricKind = "finish.workJoin"
    /// The 2026-10-19 residency run measured about 1.6 s to load and 0.8 s for grammar
    /// resources. A stuck warm-up ends the worker long before the transform's own limit.
    static let workerTimeoutSeconds: UInt64 = 60
    /// Finish joins in-flight speech or prewarm work for at most this long, then cancels it as before.
    static let finishJoinLimit: Duration = .seconds(8)

    /// Only a Finish that runs the text model benefits. Verbatim never loads it.
    static func warmsText(for mode: DictationQuickMode, textModelInstalled: Bool) -> Bool {
        mode.transformsOnFinish && textModelInstalled
    }
}

nonisolated struct TextPrewarmRun: Codable, Equatable, Sendable {
    let outcome: TextPrewarmOutcome
    let milliseconds: Double

    /// Only a load this request performed is a timing sample; other outcomes did no model work.
    var metricMilliseconds: Double? { outcome == .loaded ? milliseconds : nil }
}

/// At most one prewarm per armed capture, run by the owner's single work lane. Only this
/// bookkeeping lives on the main actor; the load runs on the inference client's actor and
/// in the worker process.
@MainActor
final class TextPrewarmController {
    typealias Prewarm = @Sendable () async -> TextPrewarmOutcome

    private let prewarm: Prewarm
    private var armedEpoch: UUID?
    private(set) var isRunning = false
    private(set) var lastRun: TextPrewarmRun?

    init(prewarm: @escaping Prewarm) {
        self.prewarm = prewarm
    }

    /// Arms exactly one prewarm for this capture when its Finish will run the text model.
    func arm(epoch: UUID, mode: DictationQuickMode, textModelInstalled: Bool) {
        armedEpoch = TextPrewarmPolicy.warmsText(for: mode, textModelInstalled: textModelInstalled) ? epoch : nil
    }

    func disarm() { armedEpoch = nil }

    func isArmed(for epoch: UUID) -> Bool { armedEpoch == epoch && !isRunning }

    /// Consumes the armed capture. A second claim for the same capture returns false.
    func claim(epoch: UUID) -> Bool {
        guard isArmed(for: epoch) else { return false }
        armedEpoch = nil
        return true
    }

    /// Never throws; cancellation is an outcome. Returns nil only while another run is in flight.
    func run() async -> TextPrewarmRun? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        let started = ContinuousClock.now
        let outcome = await prewarm()
        let elapsed = started.duration(to: .now).components
        let run = TextPrewarmRun(outcome: outcome,
            milliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000)
        lastRun = run
        return run
    }
}

/// Waits for model work already in flight without cancelling it. Cancelling an in-flight
/// worker request ends the worker process and every resident model, so Finish joins first.
@MainActor
enum ModelWorkJoin {
    /// Returns true when `task` finished within `limit`. Otherwise the task keeps running.
    static func wait(for task: Task<Void, Never>, within limit: Duration) async -> Bool {
        let gate = ModelWorkJoinGate()
        Task { @MainActor in
            await task.value
            gate.finish(true)
        }
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: limit) } catch { return }
            gate.finish(false)
        }
        // The gate accepts the first result whether it arrives before or after installation.
        let finished: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                gate.install(continuation)
            }
        } onCancel: {
            Task { @MainActor in gate.finish(false) }
        }
        timer.cancel()
        return finished
    }
}

@MainActor
private final class ModelWorkJoinGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        if let result { continuation.resume(returning: result) } else { self.continuation = continuation }
    }

    func finish(_ value: Bool) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}
