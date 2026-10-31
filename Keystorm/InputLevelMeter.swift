import Foundation
import os

/// One buffer's loudness, as linear amplitude (0...1 of full scale).
struct AudioLevel: Equatable, Sendable {
    var rms: Float
    var peak: Float

    static let silent = AudioLevel(rms: 0, peak: 0)

    /// What a meter should chase, 0...1 on a decibel scale. RMS carries the body of the
    /// signal; the peak adds a little so plosives register without the bar flickering.
    var meterTarget: Float {
        let value = AudioLevelScale.normalized(amplitude: rms) * 0.65
            + AudioLevelScale.normalized(amplitude: peak) * 0.35
        return min(1, max(0, value))
    }
}

/// Maps amplitude to a meter position. Speech into a laptop microphone sits around -35 to -20 dBFS,
/// so the scale spans -50 dBFS (empty) to -8 dBFS (full) rather than the whole 96 dB range.
enum AudioLevelScale {
    static let floorDecibels: Float = -50
    static let ceilingDecibels: Float = -8

    static func decibels(amplitude: Float) -> Float {
        guard amplitude.isFinite, amplitude > 0 else { return -.infinity }
        return 20 * log10(amplitude)
    }

    static func normalized(amplitude: Float) -> Float {
        let decibels = decibels(amplitude: amplitude)
        guard decibels.isFinite else { return 0 }
        let span = ceilingDecibels - floorDecibels
        return min(1, max(0, (decibels - floorDecibels) / span))
    }

    /// A coarse spoken description. VoiceOver reads this instead of a value that changes 30 times a second.
    static func description(level: Double) -> LocalizedStringResource {
        switch level {
        case ..<0.04: "No sound"
        case ..<0.25: "Quiet"
        case ..<0.85: "Good"
        default: "Loud"
        }
    }
}

/// Fast attack, slow release, so a bar rises with the voice and falls without jitter.
/// Pure arithmetic: callers supply the elapsed time of each step.
struct LevelSmoother: Equatable, Sendable {
    let attack: Double
    let release: Double
    private(set) var value: Float = 0

    init(attack: Double = 0.035, release: Double = 0.22) {
        self.attack = max(0.001, attack)
        self.release = max(0.001, release)
    }

    @discardableResult
    mutating func step(target: Float, elapsed: Double) -> Float {
        let goal = target.isFinite ? min(1, max(0, target)) : 0
        guard elapsed.isFinite, elapsed > 0 else { return value }
        let current = Double(value)
        let constant = Double(goal) > current ? attack : release
        let next = current + (Double(goal) - current) * (1 - exp(-elapsed / constant))
        // Settle on exact silence instead of decaying forever, so an idle meter stops invalidating the view.
        value = goal == 0 && next < 0.003 ? 0 : Float(min(1, max(0, next)))
        return value
    }

    mutating func reset() { value = 0 }
}

/// Latest microphone loudness, written from the live-audio queue and read by the HUD about 30 times a second.
/// A level older than `staleAfter` reads as silence, so a stalled or closed capture never leaves a bar stuck.
final class InputLevelMeter: Sendable {
    static let shared = InputLevelMeter()

    private struct State {
        var level = AudioLevel.silent
        var pendingPeak: Float = 0
        var updatedAt: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let staleAfterNanoseconds: UInt64

    init(staleAfterNanoseconds: UInt64 = 400_000_000) {
        self.staleAfterNanoseconds = staleAfterNanoseconds
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func publish(rms: Float, peak: Float, at time: UInt64 = InputLevelMeter.now()) {
        let rms = rms.isFinite ? min(1, max(0, rms)) : 0
        let peak = peak.isFinite ? min(1, max(0, peak)) : 0
        state.withLock { state in
            state.level = AudioLevel(rms: rms, peak: max(rms, peak))
            state.pendingPeak = max(state.pendingPeak, peak)
            state.updatedAt = time
        }
    }

    /// The latest RMS and the loudest peak since the previous read.
    func read(at time: UInt64 = InputLevelMeter.now()) -> AudioLevel {
        state.withLock { state in
            defer { state.pendingPeak = 0 }
            guard state.updatedAt != 0, time >= state.updatedAt,
                  time - state.updatedAt <= staleAfterNanoseconds else { return .silent }
            return AudioLevel(rms: state.level.rms, peak: max(state.pendingPeak, state.level.rms))
        }
    }

    func reset() {
        state.withLock { $0 = State() }
    }
}
