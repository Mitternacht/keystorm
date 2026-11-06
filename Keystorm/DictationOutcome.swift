import Foundation

/// A take that held no recognizable speech: a tap on the hotkey, a silent pause, background noise. This is an
/// empty result, not a failure, so the coordinator dismisses it quietly instead of showing "Needs attention".
struct DictationNoSpeechError: LocalizedError, Equatable, Sendable {
    var errorDescription: String? { "No speech was recognized. The original audio is saved." }
}
