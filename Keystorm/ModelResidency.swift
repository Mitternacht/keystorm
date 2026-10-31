import Foundation

/// How long the private inference worker keeps its speech and text models resident after
/// its last job. A resident model makes the first dictation after a pause as fast as the
/// tenth; an unloaded one costs seconds of load time. Memory pressure always wins.
nonisolated enum ModelResidencyPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Keep the models until the Mac runs short of memory, the user quits or models change.
    case always
    /// The default: enough to cover a normal work session between dictations.
    case fifteenMinutes
    /// The previous behaviour, for Macs where memory matters more than latency.
    case untilIdle

    var id: Self { self }

    static let storageKey = "inference.keepModelLoaded.v1"
    static let defaultPolicy: ModelResidencyPolicy = .fifteenMinutes
    /// The lease of `.fifteenMinutes`. Change it here to retune the default.
    static let longLease: Duration = .seconds(15 * 60)
    /// The lease of `.untilIdle`.
    static let shortLease: Duration = .seconds(30)

    var title: LocalizedStringResource {
        switch self {
        case .always: "Always"
        case .fifteenMinutes: "15 minutes"
        case .untilIdle: "Until idle (30 seconds)"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .always: "Keep the speech and text models in memory until your Mac needs the memory back. Fastest, but it holds several gigabytes while Keystorm runs."
        case .fifteenMinutes: "Keep the models in memory for 15 minutes after you last dictated. A good balance between speed and memory."
        case .untilIdle: "Unload the models 30 seconds after you stop dictating. Frees memory sooner; the next dictation loads them again."
        }
    }

    /// How long a worker may sit idle before it is unloaded. Nil means it never expires by time.
    var lease: Duration? {
        switch self {
        case .always: nil
        case .fifteenMinutes: Self.longLease
        case .untilIdle: Self.shortLease
        }
    }

    /// A missing or unreadable value means the default. `nil` defaults read the default too.
    static func stored(in defaults: UserDefaults?) -> ModelResidencyPolicy {
        defaults?.string(forKey: storageKey).flatMap(ModelResidencyPolicy.init(rawValue:)) ?? defaultPolicy
    }

    func store(in defaults: UserDefaults?) {
        defaults?.set(rawValue, forKey: Self.storageKey)
    }
}

nonisolated enum ModelMemoryPressure: Sendable, Equatable {
    case warning, critical
}

nonisolated enum ModelPressureAction: Sendable, Equatable {
    /// The pressure does not justify losing a recently used model.
    case keep
    /// No job is running; unload the worker now.
    case unloadNow
    /// A job is running; unload as soon as it finishes, never in the middle of it.
    case unloadAfterJob
}

/// Pure idle-lease bookkeeping for the worker. Callers pass instants from an injectable clock,
/// so expiry, policy changes and memory-pressure decisions are all testable without waiting.
nonisolated struct ModelResidencyLease: Sendable {
    /// Longest sleep before the owner re-reads the policy, so a Settings change takes effect
    /// within this long even while a 15 minute timer is pending.
    static let recheckInterval: Duration = .seconds(30)
    /// A warning (as opposed to critical) unloads only a worker that has been idle at least this long.
    static let warningIdleThreshold: Duration = .seconds(60)

    var policy: ModelResidencyPolicy
    /// Replaces the policy's lease. Tests use it to expire a worker in milliseconds.
    let leaseOverride: Duration?
    private(set) var lastActivity: ContinuousClock.Instant

    init(policy: ModelResidencyPolicy = .defaultPolicy, leaseOverride: Duration? = nil, now: ContinuousClock.Instant) {
        self.policy = policy
        self.leaseOverride = leaseOverride.map { max(.zero, $0) }
        lastActivity = now
    }

    /// The effective lease; nil means the worker is kept until memory pressure.
    var lease: Duration? { leaseOverride ?? policy.lease }

    /// Any job start, job end or explicit finish counts as use.
    mutating func touch(at now: ContinuousClock.Instant) {
        // A clock that appears to run backwards must not shorten an existing lease.
        if now > lastActivity { lastActivity = now }
    }

    func idleDuration(at now: ContinuousClock.Instant) -> Duration {
        max(.zero, lastActivity.duration(to: now))
    }

    /// Time left on the lease, clamped at zero. Nil when the lease never expires.
    func remaining(at now: ContinuousClock.Instant) -> Duration? {
        guard let lease else { return nil }
        return max(.zero, lease - idleDuration(at: now))
    }

    func isExpired(at now: ContinuousClock.Instant) -> Bool {
        guard let remaining = remaining(at: now) else { return false }
        return remaining == .zero
    }

    /// How long an owner should sleep before it looks again. Never longer than `recheckInterval`,
    /// and a lease that never expires still polls, so switching to a timed policy takes effect.
    func nextCheck(at now: ContinuousClock.Instant) -> Duration {
        min(remaining(at: now) ?? Self.recheckInterval, Self.recheckInterval)
    }

    func action(for pressure: ModelMemoryPressure, hasPendingJob: Bool,
                at now: ContinuousClock.Instant) -> ModelPressureAction {
        switch pressure {
        case .critical:
            return hasPendingJob ? .unloadAfterJob : .unloadNow
        case .warning:
            guard !hasPendingJob, idleDuration(at: now) >= Self.warningIdleThreshold else { return .keep }
            return .unloadNow
        }
    }
}
