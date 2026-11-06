import Foundation

/// Paces preview starts from measured decode cost. Saved transcription and Finish keep
/// at least half the inference lane even when a preview takes several seconds.
nonisolated enum LivePreviewPacing {
    static let firstWindowInterval: Duration = .milliseconds(100)
    static let steadyInterval: Duration = .milliseconds(500)
    static let maximumWorkerShare = 0.5

    static func interval(sequence: Int64, lastDecode: Duration) -> Duration {
        guard sequence > 0 else { return firstWindowInterval }
        return max(steadyInterval, max(.zero, lastDecode) * (1 / maximumWorkerShare))
    }

    /// Failures and cancellation consume the same worker time as successful recognition.
    /// Recording in defer keeps retry scheduling from using a previous, shorter decode.
    @MainActor
    static func measureAttempt<Result>(
        now: () -> ContinuousClock.Instant = { .now },
        recordDuration: (Duration) -> Void,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        let started = now()
        defer { recordDuration(started.duration(to: now())) }
        return try await operation()
    }
}

/// Bounded, provisional word reuse. The last four seconds remain revisable, with half a
/// second of acoustic context. Saved-audio recognition remains the only durable authority.
/// Missing timings, gaps and interval changes fall back to the complete available ring.
nonisolated struct IncrementalPreviewTranscript {
    struct Plan: Sendable {
        let window: LiveAudioWindow
        fileprivate let originalStart: Double
        fileprivate let replaceFrom: Double
        fileprivate let prefix: [TimedSpeechWord]
        /// Retained words that the cropped acoustic context must independently confirm.
        fileprivate let overlap: [String]
    }

    struct Result: Sendable {
        let text: String
        /// Relative to startTime, as RecordingHUDSession expects.
        let words: [TimedSpeechWord]
        let startTime: Double
        let endTime: Double
    }

    private var intervalID: UUID?
    private var discontinuities: Int64 = -1
    private var sequence: Int64 = -1
    private var endTime: Double = 0
    private var absoluteWords: [TimedSpeechWord] = []
    private var canReuse = false
    private static let tailSeconds = 4.0
    private static let contextSeconds = 0.5

    func plan(for window: LiveAudioWindow) -> Plan {
        let full = Plan(window: window, originalStart: window.startTime,
                        replaceFrom: window.startTime, prefix: [], overlap: [])
        guard canReuse, intervalID == window.intervalID,
              discontinuities == window.discontinuityCount, window.sequence > sequence,
              window.endTime > endTime, window.startTime <= endTime,
              window.endTime - endTime <= Self.tailSeconds,
              window.endTime - window.startTime > Self.tailSeconds + Self.contextSeconds else { return full }
        var boundary = max(window.startTime, window.endTime - Self.tailSeconds)
        // Never split a word already known to cross the nominal revision boundary.
        if let crossing = absoluteWords.first(where: { $0.startTime < boundary && $0.endTime > boundary }) {
            boundary = crossing.startTime
        }
        // A zero-duration word exactly on the boundary belongs only to the revisable tail.
        let prefix = absoluteWords.filter {
            $0.startTime >= window.startTime && $0.startTime < boundary && $0.endTime <= boundary
        }
        guard !prefix.isEmpty else { return full }
        let ordinaryStart = max(window.startTime, boundary - Self.contextSeconds)
        var croppedStart = ordinaryStart
        if !prefix.contains(where: { $0.endTime >= ordinaryStart }), let anchor = prefix.last {
            // Two empty overlap lists prove nothing: a retained word can shift by
            // more than the half-second context and appear again in the new tail.
            // Include a complete retained word plus context, or decode the full ring
            // when a long silence would make the extra cropped work unbounded.
            croppedStart = max(window.startTime, anchor.startTime - Self.contextSeconds)
            guard ordinaryStart - croppedStart <= 2 else { return full }
        }
        let offset = max(0, Int(((croppedStart - window.startTime) * 16_000).rounded(.down)))
        guard offset > 0, offset < window.samples.count else { return full }
        let suffix = LiveAudioWindow(intervalID: window.intervalID, sequence: window.sequence,
            startTime: window.startTime + Double(offset) / 16_000, endTime: window.endTime,
            samples: Array(window.samples.dropFirst(offset)), droppedBuffers: window.droppedBuffers,
            discontinuityCount: window.discontinuityCount, bufferIssue: window.bufferIssue)
        let overlap = prefix.filter { $0.endTime >= suffix.startTime }.map { Self.normalized($0.word) }
        return Plan(window: suffix, originalStart: window.startTime, replaceFrom: boundary,
                    prefix: prefix, overlap: overlap)
    }

    /// Nil preserves the displayed preview while the next cycle retries the complete ring.
    mutating func accept(text: String, words: [TimedSpeechWord], plan: Plan) -> Result? {
        let window = plan.window
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = window.endTime - window.startTime
        var previousStart = -1.0
        let valid = words.count <= 150 && words.allSatisfy { word in
            defer { previousStart = word.startTime }
            return !word.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && word.startTime.isFinite && word.endTime.isFinite
                && word.startTime >= 0 && word.startTime >= previousStart
                && word.endTime >= word.startTime && word.endTime <= duration + 0.5
        } && words.reduce(0, { $0 + $1.word.count + 1 }) <= 2_400
        // Do not freeze text that was absent from the native word timings.
        let timedText = words.map(\.word).joined(separator: " ")
        let completeTimings = valid && (value.isEmpty ? words.isEmpty :
            !words.isEmpty && Self.normalized(value) == Self.normalized(timedText))
        let fresh = words.map {
            TimedSpeechWord(word: $0.word, startTime: window.startTime + $0.startTime,
                            endTime: window.startTime + $0.endTime)
        }
        // Confirm the overlap acoustically before retaining old words. A word may shift
        // wholly across the boundary without straddling it: timestamp-only filtering would
        // then duplicate a retained word or erase a revisable one. Changed or missing overlap
        // is ambiguous, so keep the current display and retry the complete ring.
        let freshOverlap = fresh.filter {
            $0.startTime < plan.replaceFrom && $0.endTime <= plan.replaceFrom
        }.map { Self.normalized($0.word) }
        if !plan.prefix.isEmpty && (!completeTimings || freshOverlap != plan.overlap || fresh.contains(where: {
            $0.startTime < plan.replaceFrom && $0.endTime > plan.replaceFrom
        })) {
            if intervalID != window.intervalID || window.sequence > sequence {
                intervalID = window.intervalID
                discontinuities = window.discontinuityCount
                sequence = window.sequence
                endTime = window.endTime
                canReuse = false
            }
            return nil
        }
        let combined = completeTimings
            ? plan.prefix + fresh.filter { $0.startTime >= plan.replaceFrom }
            : []
        var bounded = Array(combined.suffix(150))
        while bounded.reduce(0, { $0 + $1.word.count + 1 }) > 2_400 { bounded.removeFirst() }
        let start = plan.prefix.isEmpty || !completeTimings ? window.startTime : plan.originalStart
        let rendered = completeTimings
            ? String(bounded.map(\.word).joined(separator: " ").suffix(2_400))
            : String(value.suffix(2_400))
        // A late result may be displayed only by the caller's own epoch guard; it must
        // never replace the state used to plan a newer window.
        if intervalID != window.intervalID || window.sequence > sequence {
            intervalID = window.intervalID
            discontinuities = window.discontinuityCount
            sequence = window.sequence
            endTime = window.endTime
            absoluteWords = bounded
            canReuse = completeTimings && !bounded.isEmpty
        }
        return Result(text: rendered, words: bounded.map {
            TimedSpeechWord(word: $0.word, startTime: max(0, $0.startTime - start),
                            endTime: max(0, $0.endTime - start))
        }, startTime: start, endTime: window.endTime)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
