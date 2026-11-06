import Foundation
import Testing
@testable import Keystorm

struct IncrementalPreviewTests {
    @Test("Preview reuse replaces the revisable tail and retains older provisional words")
    func revisesTail() throws {
        var preview = IncrementalPreviewTranscript()
        let first = window(start: 0, end: 8, sequence: 1)
        let plan = preview.plan(for: first)
        _ = preview.accept(text: "keep 256 not 512", words: [
            word("keep", 0.5, 1), word("256", 3.1, 3.5), word("not", 5, 5.5), word("512", 7, 7.5)
        ], plan: plan)
        let second = preview.plan(for: window(start: 0, end: 8.5, sequence: 2))
        #expect(second.window.samples.count < first.samples.count)
        #expect(second.window.endTime == 8.5)
        let start = second.window.startTime
        let revisedResult = preview.accept(text: "256 not 1024", words: [
            word("256", 3.1 - start, 3.5 - start),
            word("not", 5 - start, 5.5 - start), word("1024", 7 - start, 7.5 - start)
        ], plan: second)
        let revised = try #require(revisedResult)
        #expect(revised.text == "keep 256 not 1024")
        #expect(revised.words.map(\.word) == ["keep", "256", "not", "1024"])
    }

    @Test("Invalid timing and discontinuities never stitch unrelated text")
    func fallsBack() throws {
        var preview = IncrementalPreviewTranscript()
        let plan = preview.plan(for: window(start: 0, end: 8, sequence: 1))
        _ = preview.accept(text: "original", words: [], plan: plan)
        #expect(preview.plan(for: window(start: 0, end: 9, sequence: 2)).window.startTime == 0)
        _ = preview.accept(text: "old", words: [word("old", 1, 2)], plan: plan)
        let next = preview.plan(for: window(start: 8, end: 10, sequence: 3, discontinuities: 1))
        let resultResult = preview.accept(text: "new", words: [word("new", 0.5, 1)], plan: next)
        let result = try #require(resultResult)
        #expect(result.text == "new")
        #expect(result.startTime == 8)
    }

    @Test("Confirmed context with an empty revisable tail removes the obsolete provisional words")
    func emptyTail() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 8, sequence: 1))
        _ = preview.accept(text: "keep gone", words: [word("keep", 3, 3.5), word("gone", 7, 7.5)], plan: first)
        let next = preview.plan(for: window(start: 0, end: 9, sequence: 2))
        let resultResult = preview.accept(text: "keep", words: [
            word("keep", 3 - next.window.startTime, 3.5 - next.window.startTime)
        ], plan: next)
        let result = try #require(resultResult)
        #expect(result.text == "keep")
        #expect(result.words.map(\.word) == ["keep"])
    }

    @Test("Preview duty cycle stays below half even when a decode takes several seconds")
    func slowWorkerShare() throws {
        #expect(LivePreviewPacing.interval(sequence: 2, lastDecode: .seconds(3)) >= .seconds(6))
    }

    @Test("A rolling ring decodes only the revisable tail and keeps relative word times")
    func rollingRing() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 20, end: 32, sequence: 1))
        _ = preview.accept(text: "older latest", words: [word("older", 6.5, 7), word("latest", 11, 11.5)], plan: first)
        let next = preview.plan(for: window(start: 20.5, end: 32.5, sequence: 2))
        #expect(next.window.samples.count == 104_000)
        let resultResult = preview.accept(text: "older revised", words: [
            word("older", 0.5, 1), word("revised", 4.5, 5)
        ], plan: next)
        let result = try #require(resultResult)
        #expect(result.text == "older revised")
        #expect(result.startTime == 20.5)
        #expect(result.words.first?.startTime == 6)
        #expect(result.words.last?.startTime == 10)
    }

    @Test("A word crossing the four-second boundary stays wholly revisable")
    func crossingRevisionBoundary() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 8, sequence: 1))
        _ = preview.accept(text: "keep old tail", words: [
            word("keep", 3, 3.5), word("old", 4.25, 4.75), word("tail", 7, 7.5)
        ], plan: first)
        // The nominal boundary is 4.5 s; the crossing word moves it back to 4.25 s.
        // Extra context independently confirms the retained "keep".
        let next = preview.plan(for: window(start: 0, end: 8.5, sequence: 2))
        #expect(next.window.startTime == 2.5)
        let resultResult = preview.accept(text: "keep revised tail", words: [
            word("keep", 0.5, 1), word("revised", 1.75, 2.25), word("tail", 4.5, 5)
        ], plan: next)
        let result = try #require(resultResult)
        #expect(result.text == "keep revised tail")
        #expect(result.words.map(\.word) == ["keep", "revised", "tail"])
        #expect(result.words.dropFirst().first?.startTime == 4.25)
    }

    @Test("A new interval never inherits an earlier interval's words or sequence")
    func intervalChangeResetsReuse() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 8, sequence: 99))
        _ = preview.accept(text: "old tail", words: [
            word("old", 1, 2), word("tail", 7, 7.5)
        ], plan: first)
        let nextInterval = UUID()
        let next = preview.plan(for: window(start: 0, end: 8.5, sequence: 1, intervalID: nextInterval))
        #expect(next.window.startTime == 0)
        let resultResult = preview.accept(text: "new", words: [word("new", 3, 3.5)], plan: next)
        let result = try #require(resultResult)
        #expect(result.text == "new")
        #expect(result.words.map(\.word) == ["new"])
        #expect(preview.plan(for: window(start: 0, end: 9, sequence: 2,
            intervalID: nextInterval)).window.startTime == 2.5)
    }

    @Test("Incomplete, unordered or nonfinite timings force a full-window retry")
    func invalidTimings() throws {
        for words in [
            [word("partial", 1, 2)],
            [word("whole", 3, 4), word("sentence", 1, 2)],
            [word("whole sentence", .nan, 2)]
        ] {
            var preview = IncrementalPreviewTranscript()
            let first = preview.plan(for: window(start: 0, end: 10, sequence: 1))
            let resultResult = preview.accept(text: "whole sentence", words: words, plan: first)
            let result = try #require(resultResult)
            #expect(result.text == "whole sentence")
            #expect(result.words.isEmpty)
            #expect(preview.plan(for: window(start: 0, end: 11, sequence: 2)).window.startTime == 0)
        }
    }

    @Test("A stale decode cannot replace newer planning state")
    func staleResult() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 8, sequence: 1))
        _ = preview.accept(text: "keep tail", words: [word("keep", 3, 3.5), word("tail", 7, 7.5)], plan: first)
        let second = preview.plan(for: window(start: 0, end: 9, sequence: 2))
        _ = preview.accept(text: "keep new", words: [word("keep", 0.5, 1), word("new", 3, 3.5)], plan: second)
        _ = preview.accept(text: "old", words: [], plan: first)
        #expect(preview.plan(for: window(start: 0, end: 10, sequence: 3)).window.startTime > 0)
    }

    @Test("Word reuse keeps Unicode intact and never exceeds the HUD bound")
    func boundedUnicode() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 12, sequence: 1))
        let old = String(repeating: "👩🏽‍💻", count: 1_500)
        _ = preview.accept(text: old + " anchor", words: [word(old, 2, 3), word("anchor", 7, 7.5)], plan: first)
        let next = preview.plan(for: window(start: 0, end: 12.5, sequence: 2))
        let new = String(repeating: "ä", count: 1_500)
        let resultResult = preview.accept(text: "anchor " + new, words: [
            word("anchor", 0.5, 1), word(new, 3, 3.5)
        ], plan: next)
        let result = try #require(resultResult)
        #expect(result.text.count <= 2_400)
        #expect(result.words.map(\.word).joined(separator: " ") == result.text)
        #expect(result.text == "anchor " + new)
    }


    @Test("An untimed cropped response preserves the display and forces one full-window retry")
    func invalidCroppedResponseRetriesFullWindow() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 8, sequence: 1))
        _ = preview.accept(text: "keep old tail", words: [
            word("keep", 3, 3.5), word("old", 5, 5.5), word("tail", 7, 7.5)
        ], plan: first)
        let cropped = preview.plan(for: window(start: 0, end: 8.5, sequence: 2))
        #expect(cropped.window.startTime > 0)
        let rejected = preview.accept(text: "new tail", words: [], plan: cropped)
        #expect(rejected == nil, "An incomplete cropped result must never replace the full preview.")
        let retry = preview.plan(for: window(start: 0, end: 9, sequence: 3))
        #expect(retry.window.startTime == 0)
        let restoredResult = preview.accept(text: "keep new tail", words: [], plan: retry)
        let restored = try #require(restoredResult)
        #expect(restored.text == "keep new tail")
        #expect(restored.words.isEmpty)
    }

    @Test("A newly shifted word at a cropped boundary retries instead of dropping that word")
    func shiftedBoundaryWordRetriesFullWindow() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 8, sequence: 1))
        _ = preview.accept(text: "keep old tail", words: [
            word("keep", 3, 3.5), word("old", 4.25, 4.75), word("tail", 7, 7.5)
        ], plan: first)
        let cropped = preview.plan(for: window(start: 0, end: 8.5, sequence: 2))
        #expect(cropped.window.startTime == 2.5)
        // Confirm the old prefix, but shift "revised" across the revision boundary.
        let rejected = preview.accept(text: "keep revised tail", words: [
            word("keep", 0.5, 1), word("revised", 1.5, 1.9), word("tail", 4.5, 5)
        ], plan: cropped)
        #expect(rejected == nil)
        #expect(preview.plan(for: window(start: 0, end: 9, sequence: 3)).window.startTime == 0)
    }


    @Test("A word shifted wholly into the revisable tail cannot duplicate a retained word")
    func wordShiftedRightRetriesFullWindow() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 8, sequence: 1))
        _ = preview.accept(text: "keep boundary tail", words: [
            word("keep", 1, 2), word("boundary", 4.25, 4.4), word("tail", 7, 7.5)
        ], plan: first)
        let cropped = preview.plan(for: window(start: 0, end: 8.5, sequence: 2))
        #expect(cropped.window.startTime == 4)
        let rejected = preview.accept(text: "boundary tail", words: [
            word("boundary", 0.6, 0.8), word("tail", 3, 3.5)
        ], plan: cropped)
        #expect(rejected == nil, "A shifted word must not become 'keep boundary boundary tail'.")
        let retry = preview.plan(for: window(start: 0, end: 9, sequence: 3))
        #expect(retry.window.startTime == 0)
        let recoveredResult = preview.accept(text: "keep boundary tail", words: [
            word("keep", 1, 2), word("boundary", 4.6, 4.8), word("tail", 7, 7.5)
        ], plan: retry)
        let recovered = try #require(recoveredResult)
        #expect(recovered.text == "keep boundary tail")
    }

    @Test("A word shifted wholly before the revisable tail cannot disappear")
    func wordShiftedLeftRetriesFullWindow() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 8, sequence: 1))
        _ = preview.accept(text: "keep boundary tail", words: [
            word("keep", 3.5, 3.9), word("boundary", 4.6, 4.8), word("tail", 7, 7.5)
        ], plan: first)
        let cropped = preview.plan(for: window(start: 0, end: 8.5, sequence: 2))
        #expect(cropped.window.startTime == 3)
        let rejected = preview.accept(text: "keep boundary tail", words: [
            word("keep", 0.5, 0.9), word("boundary", 1.25, 1.4), word("tail", 4, 4.5)
        ], plan: cropped)
        #expect(rejected == nil, "A shifted word must not become 'keep tail'.")
        let retry = preview.plan(for: window(start: 0, end: 9, sequence: 3))
        #expect(retry.window.startTime == 0)
        let recoveredResult = preview.accept(text: "keep boundary tail", words: [
            word("keep", 3.5, 3.9), word("boundary", 4.25, 4.4), word("tail", 7, 7.5)
        ], plan: retry)
        let recovered = try #require(recoveredResult)
        #expect(recovered.text == "keep boundary tail")
    }

    @Test("Matching acoustic overlap permits reuse despite small timing changes")
    func matchingOverlapKeepsIncrementalDecode() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 8, sequence: 1))
        _ = preview.accept(text: "keep boundary old", words: [
            word("keep", 1, 2), word("boundary", 4.25, 4.4), word("old", 7, 7.5)
        ], plan: first)
        let cropped = preview.plan(for: window(start: 0, end: 8.5, sequence: 2))
        #expect(cropped.window.samples.count == 72_000)
        let result = preview.accept(text: "boundary revised", words: [
            word("boundary", 0.1, 0.35), word("revised", 3, 3.5)
        ], plan: cropped)
        let accepted = try #require(result)
        #expect(accepted.text == "keep boundary revised")
        #expect(accepted.words.map(\.word) == ["keep", "boundary", "revised"])
        #expect(preview.plan(for: window(start: 0, end: 9, sequence: 3)).window.startTime > 0)
    }

    @Test("A zero-duration word on the boundary belongs to the revisable tail once")
    func zeroDurationBoundaryWordIsNotDuplicated() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 8, sequence: 1))
        _ = preview.accept(text: "keep boundary tail", words: [
            word("keep", 3, 3.5), word("boundary", 4.5, 4.5), word("tail", 7, 7.5)
        ], plan: first)
        let cropped = preview.plan(for: window(start: 0, end: 8.5, sequence: 2))
        let result = preview.accept(text: "keep boundary tail", words: [
            word("keep", 0.5, 1), word("boundary", 2, 2), word("tail", 4.5, 5)
        ], plan: cropped)
        let accepted = try #require(result)
        #expect(accepted.words.map(\.word) == ["keep", "boundary", "tail"])
        #expect(accepted.text == "keep boundary tail")
    }


    @Test("A formerly empty overlap is extended and cannot duplicate a word shifted beyond half a second")
    func emptyOverlapExtendsToConfirmAnchor() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 8, sequence: 1))
        _ = preview.accept(text: "keep boundary tail", words: [
            word("keep", 1, 2), word("boundary", 3.7, 3.9), word("tail", 7, 7.5)
        ], plan: first)
        let cropped = preview.plan(for: window(start: 0, end: 8.5, sequence: 2))
        #expect(cropped.window.startTime <= 3.2)
        #expect(cropped.window.startTime > 3)
        let start = cropped.window.startTime
        let rejected = preview.accept(text: "boundary tail", words: [
            word("boundary", 4.55 - start, 4.8 - start), word("tail", 7 - start, 7.5 - start)
        ], plan: cropped)
        #expect(rejected == nil)
        #expect(preview.plan(for: window(start: 0, end: 9, sequence: 3)).window.startTime == 0)
    }

    @Test("A distant retained word uses the full ring instead of an unbounded crop extension")
    func distantAnchorFallsBackToFullRing() throws {
        var preview = IncrementalPreviewTranscript()
        let first = preview.plan(for: window(start: 0, end: 8, sequence: 1))
        _ = preview.accept(text: "keep tail", words: [
            word("keep", 1, 2), word("tail", 7, 7.5)
        ], plan: first)
        let next = preview.plan(for: window(start: 0, end: 8.5, sequence: 2))
        #expect(next.window.startTime == 0)
        #expect(next.window.samples.count == 136_000)
        let emptyResult = preview.accept(text: "", words: [], plan: next)
        let empty = try #require(emptyResult)
        #expect(empty.text.isEmpty)
        #expect(empty.words.isEmpty)
    }

    @MainActor
    @Test("Slow failed and cancelled previews retain their worker cost for retry pacing")
    func slowFailedAttemptBacksOff() async throws {
        for cancelled in [false, true] {
            let origin = ContinuousClock.now
            var elapsed: Duration = .zero
            var measured: Duration = .milliseconds(20)
            do {
                let _: Void = try await LivePreviewPacing.measureAttempt(
                    now: { origin.advanced(by: elapsed) },
                    recordDuration: { measured = $0 }
                ) {
                    elapsed = .seconds(8)
                    if cancelled { throw CancellationError() }
                    throw PreviewAttemptFailure.expected
                }
                Issue.record("The timing wrapper must propagate the attempt's failure.")
            } catch {
                let expected = cancelled ? error is CancellationError : error is PreviewAttemptFailure
                #expect(expected)
            }
            #expect(measured == .seconds(8))
            let retryAfter = origin.advanced(by: elapsed + .seconds(2))
            let pacedNext = origin.advanced(by: LivePreviewPacing.interval(sequence: 1, lastDecode: measured))
            let nextStart = max(retryAfter, pacedNext)
            #expect(origin.duration(to: nextStart) == .seconds(16))
            #expect(origin.advanced(by: elapsed).duration(to: nextStart) == .seconds(8),
                "An eight-second failure must leave at least eight seconds to other work, not only two.")
        }
    }

    private enum PreviewAttemptFailure: Error { case expected }

    private func window(start: Double, end: Double, sequence: Int64,
                        discontinuities: Int64 = 0,
                        intervalID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!) -> LiveAudioWindow {
        LiveAudioWindow(intervalID: intervalID,
            sequence: sequence, startTime: start, endTime: end,
            samples: Array(repeating: 0.1, count: Int((end - start) * 16_000)),
            droppedBuffers: 0, discontinuityCount: discontinuities, bufferIssue: nil)
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> TimedSpeechWord {
        TimedSpeechWord(word: text, startTime: start, endTime: end)
    }
}
