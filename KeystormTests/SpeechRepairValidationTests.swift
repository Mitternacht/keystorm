import Foundation
import Testing
@testable import Keystorm

/// Validates unmodified decoder evidence before any clipping could conceal bad timing.
struct SpeechRepairValidationTests {
    @Test("Every malformed original word rejects the complete repair", arguments: [
        RepairTimingFault.oversizedSpan, .negativeStart, .infiniteStart, .nanStart,
        .infiniteEnd, .nanEnd, .reversed, .pastRepairDuration
    ])
    func malformedTimingRejectsWholeRepair(_ fault: RepairTimingFault) {
        let invalid: TimedSpeechWord
        switch fault {
        case .oversizedSpan: invalid = word("oversized", -10, 40)
        case .negativeStart: invalid = word("negative", -0.100_001, 0.4)
        case .infiniteStart: invalid = word("infinite", -.infinity, 0.4)
        case .nanStart: invalid = word("nan", .nan, 0.4)
        case .infiniteEnd: invalid = word("infinite", 0.2, .infinity)
        case .nanEnd: invalid = word("nan", 0.2, .nan)
        case .reversed: invalid = word("reversed", 0.7, 0.3)
        case .pastRepairDuration: invalid = word("late", 0.2, 1.100_001)
        }
        #expect(throws: (any Error).self) {
            try SpeechGapRecovery.validatedRepairWords(
                [word("valid first", 0.1, 0.2), invalid, word("valid last", 0.7, 0.9)],
                repairStart: 3, repairDuration: 1, ownedGap: 3..<4)
        }
    }

    @Test("Empty or whitespace-only decoder words reject the complete repair", arguments: ["", " \t\n"])
    func emptyWordsAreInvalid(_ text: String) {
        #expect(throws: (any Error).self) {
            try SpeechGapRecovery.validatedRepairWords([word("valid", 0.1, 0.3), word(text, 0.4, 0.6)],
                repairStart: 0, repairDuration: 1, ownedGap: 0..<1)
        }
    }

    @Test("The word-size bound counts UTF-8 bytes rather than characters")
    func oversizedUnicodeWordIsInvalid() {
        let text = String(repeating: "ä", count: 2_049)
        #expect(text.count < 4_096)
        #expect(text.utf8.count > 4_096)
        #expect(throws: (any Error).self) {
            try SpeechGapRecovery.validatedRepairWords([word(text, 0.2, 0.8)],
                repairStart: 0, repairDuration: 1, ownedGap: 0..<1)
        }
    }

    @Test("A decoder word exactly at the UTF-8 byte bound remains valid")
    func exactWordByteLimitIsAccepted() throws {
        let text = String(repeating: "ä", count: 2_048)
        let result = try SpeechGapRecovery.validatedRepairWords([word(text, 0.2, 0.8)],
            repairStart: 0, repairDuration: 1, ownedGap: 0..<1)
        #expect(result.count == 1)
        #expect(result.first?.word == text)
    }

    @Test("Legitimate decoder quantization tolerance clamps to the owned gap")
    func quantizationToleranceDoesNotLeakAcrossNeighbors() throws {
        let result = try SpeechGapRecovery.validatedRepairWords(
            [word("Grüße", -0.08, 0.35), word("München", 0.65, 1.08)],
            repairStart: 2, repairDuration: 1, ownedGap: 2.1..<2.9)
        try #require(result.count == 2)
        #expect(result.map(\.word) == ["Grüße", "München"])
        #expect(abs(result[0].startTime - 2.1) < 0.000_001)
        #expect(abs(result[0].endTime - 2.35) < 0.000_001)
        #expect(abs(result[1].startTime - 2.65) < 0.000_001)
        #expect(abs(result[1].endTime - 2.9) < 0.000_001)
        #expect(result.allSatisfy { $0.startTime >= 2.1 && $0.endTime <= 2.9 && $0.endTime >= $0.startTime })
    }

    @Test("Six-hundredth-second context padding never re-emits neighboring words")
    func knownContextWordsAreFiltered() throws {
        let result = try SpeechGapRecovery.validatedRepairWords([
            word("previous", 0, 0.05), word("stimmhaft", 0.08, 0.4),
            word("voiced", 0.75, 1.04), word("next", 1.07, 1.12)
        ], repairStart: 4.94, repairDuration: 1.12, ownedGap: 5..<6)
        #expect(result.map(\.word) == ["stimmhaft", "voiced"])
        #expect(result.allSatisfy { $0.startTime >= 5 && $0.endTime <= 6 })
        try #require(result.count == 2)
        #expect(abs(result[0].startTime - 5.02) < 0.000_001)
        #expect(abs(result[0].endTime - 5.34) < 0.000_001)
        #expect(abs(result[1].startTime - 5.69) < 0.000_001)
        #expect(abs(result[1].endTime - 5.98) < 0.000_001)
    }

    @Test("Multiple repaired words keep their text, order, and translated timing")
    func multipleWordsKeepStableTiming() throws {
        let result = try SpeechGapRecovery.validatedRepairWords([
            word("do", 0.2, 0.4), word("not", 0.45, 0.6), word("hochladen", 0.65, 0.9)
        ], repairStart: 10, repairDuration: 1.2, ownedGap: 10.1..<11.1)
        #expect(result.map(\.word) == ["do", "not", "hochladen"])
        try #require(result.count == 3)
        for (actual, expected) in zip(result, [10.2..<10.4, 10.45..<10.6, 10.65..<10.9]) {
            #expect(abs(actual.startTime - expected.lowerBound) < 0.000_001)
            #expect(abs(actual.endTime - expected.upperBound) < 0.000_001)
        }
    }

    @Test("Only midpoints in the half-open owned interval can produce output")
    func midpointOwnershipUsesExactGapBoundaries() throws {
        let result = try SpeechGapRecovery.validatedRepairWords([
            word("lower boundary", 0.4, 0.6), word("inside", 0.8, 1.2), word("upper boundary", 1.4, 1.6)
        ], repairStart: 0, repairDuration: 2, ownedGap: 0.5..<1.5)
        #expect(result.map(\.word) == ["lower boundary", "inside"])
        #expect(result.first?.startTime == 0.5)
        #expect(result.allSatisfy { $0.startTime >= 0.5 && $0.endTime <= 1.5 })
    }

    @Test("Malformed words outside the owned gap are still rejected",
          arguments: [RepairContextFault.beforeGap, .afterGap])
    func malformedUnusedContextCannotHideBehindFiltering(_ fault: RepairContextFault) {
        let invalid = fault == .beforeGap ? word("before", -0.2, 0.1) : word("after", 1.9, 2.100_001)
        #expect(throws: (any Error).self) {
            try SpeechGapRecovery.validatedRepairWords([word("owned", 0.9, 1.1), invalid],
                repairStart: 0, repairDuration: 2, ownedGap: 0.75..<1.25)
        }
    }

    @Test("Invalid repair windows reject all words before translation", arguments: [
        RepairWindowFault.negativeStart, .nonfiniteStart, .nanStart, .tooShort, .tooLong,
        .infiniteDuration, .nanDuration, .gapBeforeWindow, .gapAfterWindow, .emptyGap, .infiniteGap
    ])
    func invalidRepairWindowIsRejected(_ fault: RepairWindowFault) {
        var start = 1.0
        var duration = 1.0
        var gap = 1.1..<1.9
        switch fault {
        case .negativeStart: start = -0.1
        case .nonfiniteStart: start = .infinity
        case .nanStart: start = .nan
        case .tooShort: duration = 0.299_999
        case .tooLong: duration = 15.000_001
        case .infiniteDuration: duration = .infinity
        case .nanDuration: duration = .nan
        case .gapBeforeWindow: gap = 0.99..<1.9
        case .gapAfterWindow: gap = 1.1..<2.01
        case .emptyGap: gap = 1.5..<1.5
        case .infiniteGap: gap = 1.1..<Double.infinity
        }
        #expect(throws: (any Error).self) {
            try SpeechGapRecovery.validatedRepairWords([word("valid", 0.2, 0.8)],
                repairStart: start, repairDuration: duration, ownedGap: gap)
        }
    }

    @Test("The minimum and maximum repair durations remain valid", arguments: [0.3, 15.0])
    func repairDurationLimitsAreInclusive(_ duration: Double) throws {
        let result = try SpeechGapRecovery.validatedRepairWords([word("valid", 0, duration)],
            repairStart: 0, repairDuration: duration, ownedGap: 0..<duration)
        #expect(result == [word("valid", 0, duration)])
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> TimedSpeechWord {
        TimedSpeechWord(word: text, startTime: start, endTime: end)
    }
}

enum RepairTimingFault: Sendable {
    case oversizedSpan, negativeStart, infiniteStart, nanStart, infiniteEnd, nanEnd, reversed, pastRepairDuration
}
enum RepairContextFault: Sendable { case beforeGap, afterGap }
enum RepairWindowFault: Sendable {
    case negativeStart, nonfiniteStart, nanStart, tooShort, tooLong, infiniteDuration, nanDuration
    case gapBeforeWindow, gapAfterWindow, emptyGap, infiniteGap
}
