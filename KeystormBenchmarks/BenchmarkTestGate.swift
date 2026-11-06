import Testing

/// One process-wide lease across benchmark suites, including GPU and disk workloads.
/// Suite serialization alone does not prevent another suite from starting concurrently.
actor BenchmarkTestGate {
    static let shared = BenchmarkTestGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func withLease(_ operation: @concurrent @Sendable () async throws -> Void) async throws {
        if busy { await withCheckedContinuation { waiting.append($0) } }
        else { busy = true }
        do {
            try Task.checkCancellation()
            try await operation()
        } catch { release(); throw error }
        release()
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

struct ExclusiveBenchmarkUseTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @concurrent @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        try await BenchmarkTestGate.shared.withLease(function)
    }
}

extension Trait where Self == ExclusiveBenchmarkUseTrait {
    static var exclusiveBenchmarkUse: Self { Self() }
}

@Suite(.exclusiveBenchmarkUse)
struct BenchmarkTestGateTests {
    @Test("Concurrent workloads remain exclusive and a thrown operation releases its lease",
          .timeLimit(.minutes(1)))
    func concurrentAndThrowingLeases() async throws {
        // A private instance avoids recursively acquiring this suite's global lease.
        let gate = BenchmarkTestGate()
        let probe = BenchmarkLeaseProbe()
        let outcomes = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 0..<8 {
                group.addTask {
                    do {
                        try await gate.withLease {
                            await probe.enter()
                            do { try await Task.sleep(for: .milliseconds(2)) }
                            catch { await probe.leave(); throw error }
                            await probe.leave()
                            if index == 3 { throw BenchmarkLeaseFailure.expected }
                        }
                        return index
                    } catch BenchmarkLeaseFailure.expected { return index == 3 ? -1 : -2 }
                    catch { return -2 }
                }
            }
            var result: [Int] = []
            for await value in group { result.append(value) }
            return result
        }
        #expect(outcomes.sorted() == [-1, 0, 1, 2, 4, 5, 6, 7])
        try await gate.withLease { await probe.enter(); await probe.leave() }
        let observed = await probe.snapshot()
        #expect(observed.entries == 9)
        #expect(observed.peak == 1)
        #expect(observed.active == 0)
    }
}

private enum BenchmarkLeaseFailure: Error { case expected }
private actor BenchmarkLeaseProbe {
    private var entries = 0
    private var active = 0
    private var peak = 0
    func enter() { entries += 1; active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
    func snapshot() -> (entries: Int, peak: Int, active: Int) { (entries, peak, active) }
}
