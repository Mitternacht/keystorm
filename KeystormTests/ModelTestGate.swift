import Testing

/// Hands out one slot at a time to the opt-in tests that load the speech and text models.
///
/// Swift Testing runs suites in parallel. Every model test starts its own worker process with both models resident,
/// so four of them at once need more than this Mac's 16 GB: macOS swaps, and jobs end with "The local worker exceeded
/// this job's time limit". With the gate they run one after another, each worker released before the next starts.
actor ModelTestGate {
    static let shared = ModelTestGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if busy { await withCheckedContinuation { waiting.append($0) } }
        else { busy = true }
    }

    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

/// Runs each test case of the annotated test while holding the model gate. Disabled tests never reach it.
struct ExclusiveModelUseTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @concurrent @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        await ModelTestGate.shared.acquire()
        do { try await function() } catch { await ModelTestGate.shared.release(); throw error }
        await ModelTestGate.shared.release()
    }
}

extension Trait where Self == ExclusiveModelUseTrait {
    /// Serializes model-loading tests across suites. See `ModelTestGate`.
    static var exclusiveModelUse: Self { Self() }
}
