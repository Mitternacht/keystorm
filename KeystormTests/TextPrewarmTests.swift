import Foundation
import Testing
@testable import Keystorm

/// Fakes only: no worker process, model, microphone or Accessibility access.
@MainActor
struct TextPrewarmTests {
    @Test("Only a Finish that runs the text model warms it", arguments: DictationQuickMode.allCases, [true, false])
    func policyFollowsFinishMode(mode: DictationQuickMode, textModelInstalled: Bool) {
        let expected = textModelInstalled && (mode == .clean || mode == .email)
        #expect(TextPrewarmPolicy.warmsText(for: mode, textModelInstalled: textModelInstalled) == expected)
    }

    @Test("Each armed capture can be claimed exactly once")
    func armingIsOncePerCapture() {
        let controller = TextPrewarmController { .loaded }
        let epoch = UUID()
        controller.arm(epoch: epoch, mode: .verbatim, textModelInstalled: true)
        #expect(!controller.claim(epoch: epoch))
        controller.arm(epoch: epoch, mode: .clean, textModelInstalled: false)
        #expect(!controller.claim(epoch: epoch))
        controller.arm(epoch: epoch, mode: .clean, textModelInstalled: true)
        #expect(!controller.claim(epoch: UUID()))
        #expect(controller.isArmed(for: epoch))
        #expect(controller.claim(epoch: epoch))
        #expect(!controller.claim(epoch: epoch))
        let email = UUID()
        controller.arm(epoch: email, mode: .email, textModelInstalled: true)
        controller.disarm()
        #expect(!controller.claim(epoch: email))
    }

    @Test("A run reports its outcome, and only a load it performed is a timing sample",
          arguments: TextPrewarmOutcome.allCases)
    func runReportsOutcome(_ outcome: TextPrewarmOutcome) async throws {
        let controller = TextPrewarmController { outcome }
        let run = try #require(await controller.run())
        #expect(run.outcome == outcome)
        #expect(run.milliseconds >= 0)
        #expect((run.metricMilliseconds != nil) == (outcome == .loaded))
        #expect(controller.lastRun == run)
        #expect(!controller.isRunning)
    }

    @Test("An overlapping run never starts a second load, and cancellation is a quiet outcome")
    func overlappingAndCancelledRuns() async throws {
        let probe = PrewarmProbe(outcome: .loaded, holds: true)
        let controller = TextPrewarmController { await probe.prewarm() }
        let first = Task { await controller.run() }
        await waitUntil { await probe.isWaiting }
        #expect(controller.isRunning)
        #expect(await controller.run() == nil)
        #expect(await probe.calls == 1)
        first.cancel()
        let cancelled = try #require(await first.value)
        #expect(cancelled.outcome == .cancelled)
        #expect(cancelled.metricMilliseconds == nil)
        #expect(await probe.observedCancellation)
        #expect(!controller.isRunning)
    }

    @Test("The Finish join waits for work in flight without cancelling it")
    func boundedJoinNeverCancels() async throws {
        let probe = PrewarmProbe(outcome: .loaded, holds: true)
        let work = Task { @MainActor in _ = await probe.prewarm() }
        await waitUntil { await probe.isWaiting }
        let finishedWithinLimit = await ModelWorkJoin.wait(for: work, within: .milliseconds(50))
        #expect(!finishedWithinLimit)
        #expect(await probe.isWaiting)
        #expect(!work.isCancelled)
        let joined = Task { await ModelWorkJoin.wait(for: work, within: .seconds(10)) }
        await probe.release()
        #expect(await joined.value)
        #expect(await !probe.observedCancellation)
        let finished = Task { @MainActor in }
        await finished.value
        #expect(await ModelWorkJoin.wait(for: finished, within: .milliseconds(10)))
    }
}

/// The production workspace lane with a fake loader in place of the inference worker.
@MainActor
@Suite(.serialized)
struct WorkspaceTextPrewarmTests {
    @Test("An explicit prewarm runs in the shared lane and records only a real load")
    func prewarmRecordsLoad() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = PrewarmProbe(outcome: .loaded)
        let model = WorkspaceModel(root: root, modelDirectory: root.appendingPathComponent("Models", isDirectory: true),
            textPrewarmLoader: { await probe.prewarm() })
        await model.initialize()
        try #require(model.error == nil, "\(model.error ?? "")")
        let run = try #require(await model.prewarmTextModel())
        #expect(run.outcome == .loaded)
        #expect(await probe.calls == 1)
        #expect(model.error == nil)
        #expect(!model.isBusy)
        #expect(model.performanceSummaries.first { $0.kind == TextPrewarmPolicy.metricKind }?.count == 1)
        await model.stopForTermination()
    }

    @Test("A resident or missing model is quiet and adds no timing sample",
          arguments: [TextPrewarmOutcome.alreadyResident, .unavailable, .failed])
    func quietOutcomesAddNoSample(_ outcome: TextPrewarmOutcome) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = PrewarmProbe(outcome: outcome)
        let model = WorkspaceModel(root: root, modelDirectory: root.appendingPathComponent("Models", isDirectory: true),
            textPrewarmLoader: { await probe.prewarm() })
        await model.initialize()
        let run = try #require(await model.prewarmTextModel())
        #expect(run.outcome == outcome)
        #expect(model.error == nil)
        #expect(model.performanceSummaries.first { $0.kind == TextPrewarmPolicy.metricKind } == nil)
        await model.stopForTermination()
    }

    @Test("Finish joins an in-flight prewarm within its limit instead of cancelling it")
    func finishJoinsInFlightPrewarm() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = PrewarmProbe(outcome: .loaded, holds: true)
        let model = WorkspaceModel(root: root, modelDirectory: root.appendingPathComponent("Models", isDirectory: true),
            textPrewarmLoader: { await probe.prewarm() })
        await model.initialize()
        let prewarm = Task { await model.prewarmTextModel() }
        await waitUntil { await probe.isWaiting }
        #expect(model.isBusy)
        // A second request while the lane is busy neither loads again nor reports an error.
        #expect(await model.prewarmTextModel() == nil)
        #expect(model.error == nil)
        #expect(await probe.calls == 1)
        let limited = await model.joinModelWorkBeforeFinish(limit: .milliseconds(50))
        #expect(!limited)
        #expect(await probe.isWaiting)
        let joined = Task { await model.joinModelWorkBeforeFinish(limit: .seconds(10)) }
        await probe.release()
        #expect(await joined.value)
        let run = try #require(await prewarm.value)
        #expect(run.outcome == .loaded)
        #expect(await !probe.observedCancellation)
        #expect(!model.isBusy)
        #expect(model.performanceSummaries.first { $0.kind == TextPrewarmPolicy.finishJoinMetricKind } != nil)
        #expect(await model.joinModelWorkBeforeFinish(limit: .milliseconds(10)))
        await model.stopForTermination()
    }

    @Test("Termination cancels an in-flight prewarm quietly")
    func terminationCancelsPrewarm() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = PrewarmProbe(outcome: .loaded, holds: true)
        let model = WorkspaceModel(root: root, modelDirectory: root.appendingPathComponent("Models", isDirectory: true),
            textPrewarmLoader: { await probe.prewarm() })
        await model.initialize()
        let prewarm = Task { await model.prewarmTextModel() }
        await waitUntil { await probe.isWaiting }
        await model.stopForTermination()
        let run = try #require(await prewarm.value)
        #expect(run.outcome == .cancelled)
        #expect(await probe.observedCancellation)
        #expect(model.error == nil)
        #expect(!model.isBusy)
        #expect(model.performanceSummaries.first { $0.kind == TextPrewarmPolicy.metricKind } == nil)
        #expect(await model.prewarmTextModel() == nil)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-TextPrewarm-\(UUID().uuidString)", isDirectory: true)
    }
}

/// Holds a fake load open until released or cancelled.
private actor PrewarmProbe {
    private let outcome: TextPrewarmOutcome
    private let holds: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var calls = 0
    private(set) var observedCancellation = false

    init(outcome: TextPrewarmOutcome, holds: Bool = false) {
        self.outcome = outcome
        self.holds = holds
    }

    var isWaiting: Bool { waiter != nil }

    func prewarm() async -> TextPrewarmOutcome {
        calls += 1
        if holds {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if released { continuation.resume() } else { waiter = continuation }
                }
            } onCancel: {
                Task { await self.release() }
            }
        }
        if Task.isCancelled {
            observedCancellation = true
            return .cancelled
        }
        return outcome
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private func waitUntil(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
