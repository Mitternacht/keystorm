import Foundation
import Testing
@testable import Keystorm

@MainActor
struct WorkspaceCancellationTests {
    @Test("Cancelling a work caller reaches its owned inference task and joins teardown",
          .timeLimit(.minutes(1)))
    func callerCancellationReachesOwnedWork() async {
        let model = WorkspaceModel()
        let probe = WorkspaceCancellationProbe()
        let caller = Task {
            await model.performWork("Cancellation regression") {
                probe.entered = true
                do { try await Task.sleep(for: .seconds(30)) }
                catch is CancellationError { probe.cancelled = true }
                await probe.waitForTeardown()
            }
            probe.callerReturned = true
        }
        await waitUntil { probe.entered }
        #expect(model.isBusy)
        caller.cancel()
        await waitUntil { probe.cancelled }
        let propagatedBeforeFallback = probe.cancelled
        #expect(propagatedBeforeFallback)
        #expect(model.isBusy)
        #expect(!probe.callerReturned)
        // Release even on failure, then explicitly cancel to keep a failing regression bounded.
        probe.releaseTeardown()
        await model.stopForTermination()
        await caller.value
        #expect(!model.isBusy)
        #expect(probe.callerReturned)
        #expect(model.error == nil)
    }

    @Test("An already cancelled caller cannot start a fresh inference action",
          .timeLimit(.minutes(1)))
    func cancelledCallerCannotStartWork() async {
        let model = WorkspaceModel()
        let probe = WorkspaceCancellationProbe()
        let caller = Task {
            await probe.waitForTeardown()
            await model.performWork("Already cancelled") { probe.entered = true }
        }
        caller.cancel()
        probe.releaseTeardown()
        await caller.value
        #expect(!probe.entered)
        #expect(!model.isBusy)
        await model.stopForTermination()
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
    }
}

@MainActor
private final class WorkspaceCancellationProbe {
    var entered = false
    var cancelled = false
    var callerReturned = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func waitForTeardown() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func releaseTeardown() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
