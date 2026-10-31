import Foundation

/// When the live preview loop decodes its next window. The preview re-decodes the whole
/// recent-audio ring (up to 12 s) each time, so on a slow Mac a fixed 500 ms cadence would keep
/// the single inference worker busy all the time, and the saved-audio transcription and the
/// Finish job would queue behind it. Pacing by the last decode time bounds that share.
///
/// What this deliberately does not do is decode only the audio added since the last window. The
/// HUD shows one replaceable span from a complete window decode, with word timings relative to
/// that window; a tail-only decode would need prefix-commit and stitching logic in the HUD
/// session to avoid flicker and mis-timed words, and could not be checked without a microphone.
nonisolated enum LivePreviewPacing {
    /// The very first window is polled quickly so text appears as soon as there is something to say.
    static let firstWindowInterval: Duration = .milliseconds(100)
    /// The target cadence on a Mac that decodes quickly: two updates per second.
    static let steadyInterval: Duration = .milliseconds(500)
    /// A preview may occupy at most this share of the worker. The rest stays free for saved-audio
    /// transcription and for the Finish job, which is what the user is actually waiting for.
    static let maximumWorkerShare = 0.5
    /// Even a very slow decode refreshes the preview at least this often.
    static let maximumInterval: Duration = .seconds(2)

    /// The time from the start of one preview cycle to the start of the next.
    /// `sequence` is the newest window sequence already shown (zero before the first).
    static func interval(sequence: Int64, lastDecode: Duration) -> Duration {
        guard sequence > 0 else { return firstWindowInterval }
        let decode = max(.zero, lastDecode)
        let paced = decode * (1 / maximumWorkerShare)
        return min(maximumInterval, max(steadyInterval, paced))
    }
}
