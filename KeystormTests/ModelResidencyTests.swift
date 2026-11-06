import Foundation
import Testing
@testable import Keystorm

/// Pure logic and a private UserDefaults suite only: no worker process, model or real preferences.
struct ModelResidencyTests {
    private let start = ContinuousClock.now

    private func privateDefaults() throws -> (UserDefaults, String) {
        let name = "Keystorm-Residency-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test("The default keeps models for fifteen minutes and every policy has the lease it names")
    func policyLeases() {
        #expect(ModelResidencyPolicy.defaultPolicy == .fifteenMinutes)
        #expect(ModelResidencyPolicy.fifteenMinutes.lease == .seconds(900))
        #expect(ModelResidencyPolicy.untilIdle.lease == .seconds(30))
        #expect(ModelResidencyPolicy.always.lease == nil)
        #expect(ModelResidencyPolicy.allCases.count == 3)
    }

    @Test("The preference round-trips, and anything unreadable falls back to the default")
    func preferenceStorage() throws {
        let (defaults, name) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ModelResidencyPolicy.stored(in: defaults) == .fifteenMinutes)
        #expect(ModelResidencyPolicy.stored(in: nil) == .fifteenMinutes)
        for policy in ModelResidencyPolicy.allCases {
            policy.store(in: defaults)
            #expect(ModelResidencyPolicy.stored(in: defaults) == policy)
        }
        defaults.set("forever", forKey: ModelResidencyPolicy.storageKey)
        #expect(ModelResidencyPolicy.stored(in: defaults) == .fifteenMinutes)
        defaults.set(42, forKey: ModelResidencyPolicy.storageKey)
        #expect(ModelResidencyPolicy.stored(in: defaults) == .fifteenMinutes)
    }

    @MainActor
    @Test("DictationPreferences persists Keep model loaded and reads it back")
    func preferencesPersist() throws {
        let (defaults, name) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = DictationPreferences(defaults: defaults)
        #expect(preferences.keepModelLoaded == .fifteenMinutes)
        preferences.keepModelLoaded = .always
        #expect(DictationPreferences(defaults: defaults).keepModelLoaded == .always)
        #expect(ModelResidencyPolicy.stored(in: defaults) == .always)
    }

    @Test("A lease expires exactly when its time has passed, and not before")
    func expiry() {
        let lease = ModelResidencyLease(policy: .fifteenMinutes, now: start)
        #expect(lease.remaining(at: start) == .seconds(900))
        #expect(!lease.isExpired(at: start.advanced(by: .seconds(899))))
        #expect(lease.remaining(at: start.advanced(by: .seconds(899))) == .seconds(1))
        #expect(lease.isExpired(at: start.advanced(by: .seconds(900))))
        #expect(lease.remaining(at: start.advanced(by: .seconds(5_000))) == .zero)
    }

    @Test("Using the worker restarts the lease, and a backwards clock never shortens it")
    func touchRestartsLease() {
        var lease = ModelResidencyLease(policy: .untilIdle, now: start)
        lease.touch(at: start.advanced(by: .seconds(20)))
        #expect(!lease.isExpired(at: start.advanced(by: .seconds(49))))
        #expect(lease.isExpired(at: start.advanced(by: .seconds(50))))
        lease.touch(at: start.advanced(by: .seconds(10)))
        #expect(lease.lastActivity == start.advanced(by: .seconds(20)))
        #expect(lease.idleDuration(at: start.advanced(by: .seconds(5))) == .zero)
    }

    @Test("Always never expires by time, however long the worker idles")
    func alwaysNeverExpires() {
        let lease = ModelResidencyLease(policy: .always, now: start)
        #expect(lease.remaining(at: start.advanced(by: .seconds(86_400))) == nil)
        #expect(!lease.isExpired(at: start.advanced(by: .seconds(86_400))))
        #expect(lease.nextCheck(at: start) == ModelResidencyLease.recheckInterval)
    }

    @Test("A changed policy applies to the time already idle")
    func policyChangeApplies() {
        var lease = ModelResidencyLease(policy: .fifteenMinutes, now: start)
        let later = start.advanced(by: .seconds(120))
        #expect(!lease.isExpired(at: later))
        lease.policy = .untilIdle
        #expect(lease.isExpired(at: later))
        lease.policy = .always
        #expect(!lease.isExpired(at: later))
    }

    @Test("A test override replaces the policy's lease and is never negative")
    func overrideReplacesPolicy() {
        let lease = ModelResidencyLease(policy: .always, leaseOverride: .milliseconds(150), now: start)
        #expect(lease.lease == .milliseconds(150))
        #expect(!lease.isExpired(at: start.advanced(by: .milliseconds(149))))
        #expect(lease.isExpired(at: start.advanced(by: .milliseconds(150))))
        let negative = ModelResidencyLease(policy: .fifteenMinutes, leaseOverride: .seconds(-5), now: start)
        #expect(negative.lease == .zero)
        #expect(negative.isExpired(at: start))
    }

    @Test("The owner never sleeps longer than the recheck interval, so a Settings change takes effect")
    func nextCheckIsBounded() {
        let lease = ModelResidencyLease(policy: .fifteenMinutes, now: start)
        #expect(lease.nextCheck(at: start) == ModelResidencyLease.recheckInterval)
        #expect(lease.nextCheck(at: start.advanced(by: .seconds(890))) == .seconds(10))
        #expect(lease.nextCheck(at: start.advanced(by: .seconds(900))) == .zero)
        let short = ModelResidencyLease(policy: .untilIdle, now: start)
        #expect(short.nextCheck(at: start.advanced(by: .seconds(10))) == .seconds(20))
    }

    @Test("Critical pressure unloads at once when idle and after the job when busy")
    func criticalPressure() {
        let lease = ModelResidencyLease(policy: .fifteenMinutes, now: start)
        #expect(lease.action(for: .critical, hasPendingJob: false, at: start) == .unloadNow)
        #expect(lease.action(for: .critical, hasPendingJob: true, at: start) == .unloadAfterJob)
    }

    @Test("A warning never interrupts a job or evicts a worker that was just used")
    func warningPressure() {
        let lease = ModelResidencyLease(policy: .always, now: start)
        let threshold = ModelResidencyLease.warningIdleThreshold
        #expect(lease.action(for: .warning, hasPendingJob: true, at: start.advanced(by: .seconds(600))) == .keep)
        #expect(lease.action(for: .warning, hasPendingJob: false, at: start) == .keep)
        #expect(lease.action(for: .warning, hasPendingJob: false, at: start.advanced(by: threshold - .seconds(1))) == .keep)
        #expect(lease.action(for: .warning, hasPendingJob: false, at: start.advanced(by: threshold)) == .unloadNow)
    }

    @Test("A client with no executable keeps nothing, and lease and pressure calls are quiet no-ops")
    func clientWithoutWorker() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-ResidencyClient-\(UUID().uuidString)")
        let client = InferenceWorkerClient(modelDirectory: directory, executableURL: nil,
                                           residencyPolicy: { .untilIdle }, clock: { ContinuousClock.now })
        await client.releaseIfLeaseExpired()
        await client.simulateMemoryPressureForTesting(.critical)
        #expect(await client.memorySnapshot()["workerPID"] == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await client.shutdown()
    }
}

struct LivePreviewPacingTests {
    @Test("The first window is polled quickly, then previews settle at two a second")
    func steadyCadence() {
        #expect(LivePreviewPacing.interval(sequence: 0, lastDecode: .zero) == .milliseconds(100))
        #expect(LivePreviewPacing.interval(sequence: 0, lastDecode: .seconds(3)) == .milliseconds(100))
        #expect(LivePreviewPacing.interval(sequence: 5, lastDecode: .zero) == .milliseconds(500))
        #expect(LivePreviewPacing.interval(sequence: 5, lastDecode: .milliseconds(100)) == .milliseconds(500))
    }

    @Test("A slow decode backs the loop off so previews take at most half of the worker")
    func slowDecodeBacksOff() {
        #expect(LivePreviewPacing.interval(sequence: 5, lastDecode: .milliseconds(400)) == .milliseconds(800))
        #expect(LivePreviewPacing.interval(sequence: 5, lastDecode: .milliseconds(900)) == .milliseconds(1_800))
        #expect(LivePreviewPacing.interval(sequence: 5, lastDecode: .seconds(10)) == .seconds(20))
        #expect(LivePreviewPacing.interval(sequence: 5, lastDecode: .seconds(-1)) == .milliseconds(500))
    }
}
