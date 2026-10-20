import Foundation
import Testing
@testable import Keystorm

/// Deterministic signal/timing checks only. These do not claim that RMS is a
/// speech classifier, and they never execute a model or change a transcript.
struct SpeechGapRecoveryTests {
    @Test("Silence and subthreshold noise never request a decoder repair")
    func silenceAndQuietNoiseAreIgnored() {
        #expect(SpeechGapRecovery.uncoveredSpeechRanges(samples: [Float](repeating: 0, count: 32_000),
            words: []).isEmpty)
        #expect(SpeechGapRecovery.uncoveredSpeechRanges(samples: pcm(seconds: 2, active: [0..<2], amplitude: 0.001),
            words: []).isEmpty)
    }

    @Test("Speech already covered by word timings never produces an uncovered range")
    func coveredSpeechDoesNotRepeat() {
        let samples = pcm(seconds: 2, active: [0..<2])
        let words = [word(0, 0.7), word(0.7, 1.4), word(1.4, 2)]
        #expect(SpeechGapRecovery.uncoveredSpeechRanges(samples: samples, words: words).isEmpty)
    }

    @Test("An interior acoustic omission uses exact adjacent word boundaries")
    func interiorSpeechGap() {
        let samples = pcm(seconds: 2, active: [0.1..<0.4, 0.7..<1.1, 1.6..<1.9])
        let gaps = SpeechGapRecovery.uncoveredSpeechRanges(samples: samples,
            words: [word(0.1, 0.5), word(1.5, 1.9)])
        #expect(gaps == [0.5..<1.5])
    }

    @Test("Leading and trailing acoustic omissions remain within the supplied audio")
    func boundarySpeechGaps() {
        let samples = pcm(seconds: 2.2, active: [0.1..<0.6, 0.95..<1.15, 1.5..<2.0])
        let gaps = SpeechGapRecovery.uncoveredSpeechRanges(samples: samples, words: [word(0.9, 1.2)])
        #expect(gaps == [0..<0.9, 1.2..<2.2])
        #expect(gaps.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= 2.2 })
    }

    @Test("A wholly omitted bounded spoken window can be recovered")
    func completeOmissionHasOneBoundedRange() {
        let samples = pcm(seconds: 1.4, active: [0.2..<1.1])
        #expect(SpeechGapRecovery.uncoveredSpeechRanges(samples: samples, words: []) == [0..<1.4])
    }

    @Test("Short gaps and brief acoustic transients do not create repairs")
    func shortGapsAndTransientsAreIgnored() {
        let short = pcm(seconds: 2, active: [0.6..<0.9])
        #expect(SpeechGapRecovery.uncoveredSpeechRanges(samples: short,
            words: [word(0, 0.5), word(1.14, 2)]).isEmpty)
        let transient = pcm(seconds: 2, active: [0.7..<0.86])
        #expect(SpeechGapRecovery.uncoveredSpeechRanges(samples: transient,
            words: [word(0, 0.5), word(1.5, 2)]).isEmpty)
    }

    @Test("Disjoint omissions are ordered and capped at four decoder repairs")
    func disjointSpeechGapsAreBounded() {
        let boundaries: [Range<Double>] = [0.2..<0.9, 1.1..<1.8, 2.0..<2.7, 2.9..<3.6, 3.8..<4.5]
        let samples = pcm(seconds: 4.7, active: boundaries.map { ($0.lowerBound + 0.1)..<($0.upperBound - 0.1) })
        let words = [word(0, 0.2), word(0.9, 1.1), word(1.8, 2.0),
            word(2.7, 2.9), word(3.6, 3.8), word(4.5, 4.7)]
        let gaps = SpeechGapRecovery.uncoveredSpeechRanges(samples: samples, words: words)
        #expect(gaps == Array(boundaries.prefix(4)))
    }

    @Test("Invalid sample rates cannot produce repair ranges", arguments: [0.0, -16_000, .nan, .infinity])
    func invalidRatesAreSafe(_ rate: Double) {
        #expect(SpeechGapRecovery.uncoveredSpeechRanges(samples: pcm(seconds: 1, active: [0..<1]),
            words: [], sampleRate: rate).isEmpty)
    }

    @Test("Empty or nonfinite PCM cannot produce repair ranges")
    func malformedPCMIsSafe() {
        #expect(SpeechGapRecovery.uncoveredSpeechRanges(samples: [], words: []).isEmpty)
        var nanSamples = pcm(seconds: 1, active: [0..<1])
        nanSamples[8_000] = .nan
        #expect(SpeechGapRecovery.uncoveredSpeechRanges(samples: nanSamples, words: []).isEmpty)
        var infiniteSamples = pcm(seconds: 1, active: [0..<1])
        infiniteSamples[8_000] = .infinity
        #expect(SpeechGapRecovery.uncoveredSpeechRanges(samples: infiniteSamples, words: []).isEmpty)
    }

    @Test("Malformed timing evidence never authorizes a repair", arguments: [
        GapTimingFault.negativeStart, .reversed, .nonfiniteStart, .nonfiniteEnd, .pastAudioEnd
    ])
    func malformedTimingIsSafe(_ fault: GapTimingFault) {
        let words: [TimedSpeechWord]
        switch fault {
        case .negativeStart: words = [word(-0.1, 0.2)]
        case .reversed: words = [word(0.6, 0.3)]
        case .nonfiniteStart: words = [word(.nan, 0.3)]
        case .nonfiniteEnd: words = [word(0.1, .infinity)]
        case .pastAudioEnd: words = [word(0.1, 2.1)]
        }
        #expect(SpeechGapRecovery.uncoveredSpeechRanges(samples: pcm(seconds: 2, active: [0..<2]),
            words: words).isEmpty)
    }

    @Test("Valid unordered and overlapping decoder timings merge into one coverage union")
    func nativeTimingOverlapAndOrderingAreHandled() {
        let unsorted = SpeechGapRecovery.uncoveredSpeechRanges(
            samples: pcm(seconds: 2, active: [0.8..<1.3]),
            words: [word(1.5, 1.8), word(0.2, 0.6)])
        #expect(unsorted == [0.6..<1.5])
        let overlapping = SpeechGapRecovery.uncoveredSpeechRanges(
            samples: pcm(seconds: 2, active: [0.9..<1.2]),
            words: [word(0, 0.5), word(0.4, 0.7), word(1.5, 2)])
        #expect(overlapping == [0.7..<1.5])
    }

    private func word(_ start: Double, _ end: Double) -> TimedSpeechWord {
        TimedSpeechWord(word: "recognized", startTime: start, endTime: end)
    }

    private func pcm(seconds: Double, active: [Range<Double>], amplitude: Float = 0.05) -> [Float] {
        let rate = 16_000.0
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        for range in active {
            let lower = max(0, min(samples.count, Int(ceil(range.lowerBound * rate))))
            let upper = max(lower, min(samples.count, Int(floor(range.upperBound * rate))))
            for index in lower..<upper { samples[index] = index.isMultiple(of: 2) ? amplitude : -amplitude }
        }
        return samples
    }
}

enum GapTimingFault: Sendable {
    case negativeStart, reversed, nonfiniteStart, nonfiniteEnd, pastAudioEnd
}
