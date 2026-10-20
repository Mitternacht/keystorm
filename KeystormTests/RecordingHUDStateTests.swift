import Foundation
import Testing
@testable import Keystorm

struct RecordingHUDStateTests {
    private func state(hasSpeechModel: Bool = true) -> RecordingHUDSession {
        RecordingHUDSession(sessionID: UUID(), intervalID: UUID(), title: "Project brief", hasSpeechModel: hasSpeechModel)
    }


    @Test func previewCanReviseNegationWithoutAccumulatingEarlierGuesses() {
        var value = state()
        value.receivedPreview(text: "Use 512.", words: [], startTime: 0, endTime: 0.8)
        #expect(value.snapshot.transcript == "Use 512.")
        #expect(value.snapshot.status == "Live preview · may change")
        #expect(value.retainedTranscriptCount == 0)
        value.receivedPreview(text: "Do not use 512.", words: [], startTime: 0, endTime: 1.4)
        #expect(value.snapshot.transcript == "Do not use 512.")
        #expect(value.snapshot.isRecording)
        #expect(!value.snapshot.status.contains("Saved"))
        value.audioSaved(through: 5)
        #expect(value.snapshot.status == "Live preview · may change · Saved through 0:05")
        value.pause()
        value.finish()
        #expect(value.snapshot.transcript.isEmpty)
        #expect(value.snapshot.status == "Audio saved · transcript unavailable")
    }

    @Test func latePreviewCannotReplaceANewerResultOrReappearAfterClear() {
        var value = state()
        value.receivedPreview(text: "Newer.", words: [], startTime: 0, endTime: 2)
        value.receivedPreview(text: "Older.", words: [], startTime: 0, endTime: 1)
        #expect(value.snapshot.transcript == "Newer.")
        value.clearPreview()
        value.receivedPreview(text: "Same late result.", words: [], startTime: 0, endTime: 2)
        #expect(value.snapshot.transcript.isEmpty)
        value.receivedPreview(text: "Next.", words: [], startTime: 0, endTime: 3)
        #expect(value.snapshot.transcript == "Next.")
    }

    @Test func savedTranscriptsReplaceOverlappingPreviewWordsAtNativeBoundaries() {
        var value = state()
        value.receivedPreview(text: "Keep everything local. Use 256.", words: [
            TimedSpeechWord(word: "Keep", startTime: 0, endTime: 0.2),
            TimedSpeechWord(word: "everything", startTime: 0.2, endTime: 0.4),
            TimedSpeechWord(word: "local.", startTime: 0.4, endTime: 0.8),
            TimedSpeechWord(word: "Use", startTime: 1, endTime: 1.2),
            TimedSpeechWord(word: "256.", startTime: 1.2, endTime: 1.6)
        ], startTime: 4, endTime: 6)
        value.audioSaved(through: 5)
        value.receivedTranscript(segmentID: UUID(), startTime: 0, endTime: 5,
            text: "Keep everything local.", isComplete: true)
        #expect(value.snapshot.transcript == "Keep everything local.\n\nUse 256.")
        #expect(value.retainedTranscriptCount == 1)
        value.receivedTranscript(segmentID: UUID(), startTime: 5, endTime: 6,
            text: "Use 256.", isComplete: true)
        #expect(value.snapshot.transcript == "Keep everything local.\n\nUse 256.")
        #expect(!value.snapshot.status.contains("may change"))
    }

    @Test func missingOrInvalidWordTimesShowOneClearlyProvisionalWindow() {
        var value = state()
        value.receivedTranscript(segmentID: UUID(), startTime: 0, endTime: 5,
            text: "Keep everything local.", isComplete: true)
        value.receivedPreview(text: "Keep everything local. Use 256.", words: [
            TimedSpeechWord(word: "256", startTime: .nan, endTime: 2)
        ], startTime: 4, endTime: 6)
        #expect(value.snapshot.transcript == "Keep everything local. Use 256.")
        #expect(value.snapshot.status.contains("Live preview · may change"))
        #expect(value.retainedPreviewWordCount == 0)
        #expect(value.retainedTranscriptCount == 1)
        value.clearPreview()
        #expect(value.snapshot.transcript == "Keep everything local.")
    }

    @Test func blankPreviewClearsOnlyEphemeralTextAndKeepsItsHighWaterMark() {
        var value = state()
        value.receivedTranscript(segmentID: UUID(), startTime: 0, endTime: 5,
            text: "Saved clause.", isComplete: true)
        value.receivedPreview(text: "Temporary.", words: [], startTime: 5, endTime: 6)
        value.receivedPreview(text: " \n", words: [], startTime: 5, endTime: 7)
        #expect(value.snapshot.transcript == "Saved clause.")
        value.receivedPreview(text: "Late temporary.", words: [], startTime: 5, endTime: 6.5)
        #expect(value.snapshot.transcript == "Saved clause.")
        #expect(value.snapshot.isRecording)
    }

    @Test func previewFailurePreservesCaptureSavedTextAndIncompleteCoverage() {
        var value = state()
        value.audioSaved(through: 10)
        value.receivedTranscript(segmentID: UUID(), startTime: 0, endTime: 5,
            text: "Saved clause.", isComplete: true)
        value.receivedPreview(text: "Temporary.", words: [], startTime: 5, endTime: 6)
        value.previewUnavailable("Worker is restarting.")
        #expect(value.snapshot.isRecording)
        #expect(value.snapshot.transcript == "Saved clause.")
        #expect(value.snapshot.status.contains("recording continues"))
        #expect(value.snapshot.status.contains("Saved through 0:10"))
        #expect(value.retainedTranscriptCount == 1)
        value.pause()
        value.finish()
        #expect(value.snapshot.status == "Audio saved · transcript incomplete")
    }

    @Test func finalizationDiscardsProvisionalMaterialAndRejectsLateResults() {
        var value = state()
        value.audioSaved(through: 5)
        value.receivedTranscript(segmentID: UUID(), startTime: 0, endTime: 5,
            text: "Confirmed from saved audio.", isComplete: true)
        value.receivedPreview(text: "Unconfirmed temporary.", words: [], startTime: 5, endTime: 6)
        value.pause()
        #expect(value.snapshot.transcript == "Unconfirmed temporary.")
        #expect(value.snapshot.status.contains("may change"))
        value.finish()
        #expect(value.snapshot.transcript == "Confirmed from saved audio.")
        #expect(value.snapshot.status == "Audio saved · transcript available")
        value.receivedPreview(text: "Late.", words: [], startTime: 5, endTime: 7)
        #expect(value.snapshot.transcript == "Confirmed from saved audio.")
    }

    @Test func previewStorageStaysBoundedAndPreservesUnicodeGraphemes() {
        var value = state()
        let cluster = "👩🏽‍💻"
        let longText = String(repeating: cluster, count: 3_000) + " e\u{301}"
        let oversizedWords = (0..<1_000).map {
            TimedSpeechWord(word: String($0), startTime: 0, endTime: 0.1)
        }
        value.receivedPreview(text: longText, words: oversizedWords, startTime: 0, endTime: 1)
        #expect(value.snapshot.transcript.count == 2_400)
        #expect(value.snapshot.transcript.hasPrefix("…"))
        #expect(value.snapshot.transcript.hasSuffix(" e\u{301}"))
        #expect(value.snapshot.transcript.dropFirst().dropLast(2).allSatisfy { String($0) == cluster })
        #expect(value.retainedPreviewWordCount == 0)
        #expect(value.retainedTranscriptCount == 0)
    }

    @Test func invalidPreviewWindowsCannotChangePresentationOrDurableCoverage() {
        var value = state()
        value.receivedPreview(text: "Valid.", words: [], startTime: 0, endTime: 1)
        value.receivedPreview(text: "Invalid.", words: [], startTime: .nan, endTime: 2)
        value.receivedPreview(text: "Invalid.", words: [], startTime: 0, endTime: .infinity)
        value.receivedPreview(text: "Invalid.", words: [], startTime: 4, endTime: 3)
        #expect(value.snapshot.transcript == "Valid.")
        #expect(value.snapshot.status == "Live preview · may change")
    }

    @Test func initialIdentityAndNoModelStateStayHonest() {
        let sessionID = UUID()
        let intervalID = UUID()
        var value = RecordingHUDSession(sessionID: sessionID, intervalID: intervalID,
            title: "Project brief", hasSpeechModel: false)
        #expect(value.sessionID == sessionID)
        #expect(value.intervalID == intervalID)
        #expect(value.snapshot.isRecording)
        #expect(value.snapshot.elapsed == "0:00")
        #expect(value.snapshot.transcript.isEmpty)
        #expect(value.snapshot.status.contains("not installed"))
        value.audioSaved(through: 5)
        value.pause()
        value.finish()
        #expect(!value.snapshot.isRecording)
        #expect(value.snapshot.status == "Audio saved · speech model not installed")
        #expect(value.snapshot.transcript.isEmpty)
    }

    @Test func outOfOrderAndRepeatedSegmentsReplaceRatherThanDuplicate() {
        var value = state()
        let first = UUID()
        let second = UUID()
        value.receivedTranscript(segmentID: second, startTime: 5, endTime: 10, text: "Second partial.", isComplete: false)
        value.receivedTranscript(segmentID: first, startTime: 0, endTime: 5, text: "First.", isComplete: true)
        #expect(value.snapshot.transcript == "First.\n\nSecond partial.")
        #expect(value.snapshot.status.contains("partial"))
        value.receivedTranscript(segmentID: second, startTime: 5, endTime: 10, text: "Second complete.", isComplete: true)
        #expect(value.retainedTranscriptCount == 2)
        #expect(value.snapshot.transcript == "First.\n\nSecond complete.")
        value.audioSaved(through: 10)
        value.pause()
        #expect(value.snapshot.status == "Finishing transcript…")
        value.finish()
        #expect(value.snapshot.status == "Audio saved · transcript available")
    }

    @Test func latestTranscriptTextAndEntryCountRemainBoundedAcrossALongTake() {
        var value = state()
        for index in 0..<1_080 {
            value.receivedTranscript(segmentID: UUID(), startTime: Double(index * 5),
                endTime: Double(index * 5 + 5), text: "Chunk \(index)", isComplete: true)
            #expect(value.retainedTranscriptCount <= 4)
            #expect(value.snapshot.transcript.count <= 2_400)
        }
        #expect(value.retainedTranscriptCount == 4)
        #expect(value.snapshot.transcript.hasPrefix("…"))
        #expect(value.snapshot.transcript.contains("Chunk 1079"))
        #expect(!value.snapshot.transcript.contains("Chunk 1075"))
        value.audioSaved(through: 5_400)
        value.pause()
        value.finish()
        #expect(value.snapshot.status == "Audio saved · transcript available")
    }

    @Test func unicodeSuffixPreservesWholeGraphemesAndMarksTruncation() {
        var value = state()
        let cluster = "👩🏽‍💻"
        let longText = String(repeating: cluster, count: 3_000) + " e\u{301}"
        value.receivedTranscript(segmentID: UUID(), startTime: 0, endTime: 5, text: longText, isComplete: true)
        #expect(value.snapshot.transcript.count == 2_400)
        #expect(value.snapshot.transcript.hasPrefix("…"))
        #expect(value.snapshot.transcript.hasSuffix(" e\u{301}"))
        #expect(value.snapshot.transcript.dropFirst().dropLast(2).allSatisfy { String($0) == cluster })
    }

    @Test func missingTailOrMiddleCoverageCannotLookFinished() {
        var tail = state()
        tail.audioSaved(through: 10)
        tail.receivedTranscript(segmentID: UUID(), startTime: 0, endTime: 5, text: "Only the first core.", isComplete: true)
        tail.pause()
        tail.finish()
        #expect(tail.snapshot.status.contains("incomplete"))
        var gap = state()
        gap.audioSaved(through: 15)
        gap.receivedTranscript(segmentID: UUID(), startTime: 0, endTime: 5, text: "First.", isComplete: true)
        gap.receivedTranscript(segmentID: UUID(), startTime: 10, endTime: 15, text: "Third.", isComplete: true)
        gap.pause()
        gap.finish()
        #expect(gap.snapshot.status.contains("incomplete"))
    }

    @Test func incompleteRetryAndFailureNeverTurnOffTheMicrophoneIndicator() {
        var value = state()
        let id = UUID()
        value.audioSaved(through: 5)
        value.receivedTranscript(segmentID: id, startTime: 0, endTime: 5, text: "Quiet clause…", isComplete: false)
        value.fail("Speech worker stopped.")
        #expect(value.snapshot.isRecording)
        #expect(value.snapshot.status.contains("Speech worker stopped."))
        value.finish()
        #expect(value.snapshot.isRecording)
        value.pause()
        value.finish()
        #expect(value.snapshot.status.contains("Speech worker stopped."))
        value.receivedTranscript(segmentID: id, startTime: 0, endTime: 5, text: "Quiet clause remains.", isComplete: true)
        #expect(!value.snapshot.isRecording)
        #expect(value.snapshot.status == "Audio saved · transcript available")
        value.receivedTranscript(segmentID: id, startTime: 0, endTime: 5, text: "Truncated retry", isComplete: false)
        #expect(value.snapshot.status.contains("incomplete"))
    }

    @Test func savedAudioWithoutResultsRemainsUnavailable() {
        var value = state()
        value.audioSaved(through: 5)
        value.pause()
        value.finish()
        #expect(value.snapshot.status == "Audio saved · transcript unavailable")
        var empty = state()
        empty.pause()
        empty.finish()
        #expect(empty.snapshot.status.contains("no saved audio"))
    }

    @Test func invalidCoverageAndLargeMessagesStayBounded() {
        var value = RecordingHUDSession(sessionID: UUID(), intervalID: UUID(),
            title: String(repeating: "題", count: 4_000), hasSpeechModel: true)
        value.audioSaved(through: .nan)
        value.audioSaved(through: -.infinity)
        value.receivedTranscript(segmentID: UUID(), startTime: .infinity, endTime: 5,
            text: "Never display invalid coverage as complete.", isComplete: true)
        #expect(value.snapshot.status.contains("timing"))
        #expect(value.snapshot.isRecording)
        #expect(value.snapshot.transcript.isEmpty)
        value.fail(String(repeating: "故障", count: 4_000))
        #expect(value.snapshot.status.count <= 2_400)
        #expect(value.snapshot.title.count <= 2_400)
    }
}
