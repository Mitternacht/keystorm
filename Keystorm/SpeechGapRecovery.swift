import Foundation

/// Finds substantial audible regions omitted by a decoder's native word timeline.
/// This is an omission check, not language identification or a general speech-quality score.
enum SpeechGapRecovery {
    /// Validate the decoder's original repair-relative evidence before any clipping can hide a fault.
    static func validatedRepairWords(_ words: [TimedSpeechWord], repairStart: Double,
                                     repairDuration: Double, ownedGap: Range<Double>) throws -> [TimedSpeechWord] {
        guard repairStart.isFinite, repairStart >= 0, repairDuration.isFinite,
              (0.3...15).contains(repairDuration),
              ownedGap.lowerBound.isFinite, ownedGap.upperBound.isFinite,
              ownedGap.lowerBound >= repairStart - 0.000_001,
              ownedGap.upperBound <= repairStart + repairDuration + 0.000_001,
              ownedGap.lowerBound < ownedGap.upperBound,
              words.allSatisfy({
                  !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.word.utf8.count <= 4_096 &&
                  $0.startTime.isFinite && $0.endTime.isFinite &&
                  $0.startTime >= -0.1 && $0.endTime >= $0.startTime && $0.endTime <= repairDuration + 0.1
              }) else {
            throw KeystormError.message("The local speech repair returned invalid timing for its own audio. Nothing was inserted.")
        }
        return words.compactMap { word in
            let start = repairStart + max(0, word.startTime)
            let end = repairStart + min(repairDuration, word.endTime)
            let midpoint = (start + end) / 2
            guard end >= start, midpoint >= ownedGap.lowerBound, midpoint < ownedGap.upperBound else { return nil }
            return TimedSpeechWord(word: word.word, startTime: max(ownedGap.lowerBound, start),
                                   endTime: min(ownedGap.upperBound, end))
        }
    }

    static func uncoveredSpeechRanges(samples: [Float], words: [TimedSpeechWord],
                                      sampleRate: Double = 16_000) -> [Range<Double>] {
        guard sampleRate.isFinite, sampleRate > 0, !samples.isEmpty,
              samples.count <= 240_000, samples.allSatisfy(\.isFinite) else { return [] }
        let duration = Double(samples.count) / sampleRate
        guard words.allSatisfy({
            $0.startTime.isFinite && $0.endTime.isFinite &&
            $0.startTime >= 0 && $0.endTime >= $0.startTime && $0.endTime <= duration
        }) else { return [] }
        let frameSize = max(1, Int(sampleRate * 0.02))
        var energy: [Double] = []
        for offset in stride(from: 0, to: samples.count, by: frameSize) {
            let end = min(samples.count, offset + frameSize)
            let sum = samples[offset..<end].reduce(0.0) { $0 + Double($1) * Double($1) }
            energy.append(sqrt(sum / Double(end - offset)))
        }
        let orderedEnergy = energy.sorted()
        let threshold = max(0.006, orderedEnergy[min(orderedEnergy.count - 1, orderedEnergy.count * 3 / 4)] * 0.12)
        var gaps: [Range<Double>] = []
        var through = 0.0
        for word in words.sorted(by: { $0.startTime < $1.startTime }) {
            if word.startTime - through >= 0.65 { gaps.append(through..<word.startTime) }
            through = max(through, word.endTime)
        }
        if duration - through >= 0.65 { gaps.append(through..<duration) }
        return Array(gaps.filter { gap in
            var audible = 0.0
            for index in energy.indices where energy[index] > threshold {
                let start = Double(index * frameSize) / sampleRate
                let end = min(duration, Double((index + 1) * frameSize) / sampleRate)
                audible += max(0, min(end, gap.upperBound) - max(start, gap.lowerBound))
            }
            return audible >= 0.2 - 0.000_001
        }.prefix(4))
    }
}
