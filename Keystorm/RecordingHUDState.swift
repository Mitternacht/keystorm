import Foundation

/// Bounded presentation for the active interval, using logical take coverage across resumes. Source storage and elapsed timing remain outside the HUD.
struct RecordingHUDSession {
    let sessionID: UUID
    let intervalID: UUID
    let takeID: UUID?
    private(set) var snapshot: RecordingHUDSnapshot
    var retainedTranscriptCount: Int { entries.count }
    var retainedPreviewWordCount: Int { preview?.words?.count ?? 0 }

    private struct Entry {
        let segmentID: UUID
        let start: Double
        let end: Double
        let text: String
        let complete: Bool
        let truncated: Bool
    }
    private struct Preview {
        let start: Double
        let end: Double
        let text: String
        // Nil means timing is absent or cannot safely reconcile with saved transcripts.
        let words: [TimedSpeechWord]?
    }
    private let hasSpeechModel: Bool
    private var entries: [Entry] = []
    private var savedThrough: Double = 0
    private var completedThrough: Double = 0
    private var droppedEarlierText = false
    private var finished = false
    private var failure: String?
    private var preview: Preview?
    private var latestPreviewEnd: Double = -1
    private var previewFailure: String?
    private var hasVisiblePreview = false
    private static let characterLimit = 2_400
    private static let entryLimit = 4
    // Sample-derived adjacent ranges may differ by floating-point rounding.
    private static let timingTolerance = 0.001

    init(sessionID: UUID, intervalID: UUID, title: String, hasSpeechModel: Bool, takeID: UUID? = nil) {
        self.sessionID = sessionID
        self.intervalID = intervalID
        self.takeID = takeID
        self.hasSpeechModel = hasSpeechModel
        snapshot = RecordingHUDSnapshot(isRecording: true, title: Self.bounded(title).text,
            transcript: "", status: hasSpeechModel ? "Recording · listening…" : "Recording audio · speech model not installed",
            elapsed: "0:00")
    }

    /// Authoritative logical-take prefixes include earlier capture intervals without
    /// treating an unprocessed or unavailable earlier segment as completed.
    mutating func synchronizeCoverage(saved: Double, transcribed: Double) {
        guard saved.isFinite, transcribed.isFinite, saved >= 0, transcribed >= 0 else { return }
        savedThrough = saved
        completedThrough = min(saved, transcribed)
        refreshTranscript()
        refreshStatus()
    }

    mutating func audioSaved(through: Double) {
        guard through.isFinite, through >= 0 else { return }
        savedThrough = max(savedThrough, through)
        refreshStatus()
    }

    mutating func receivedTranscript(segmentID: UUID, startTime: Double, endTime: Double,
                                     text: String, isComplete: Bool) {
        guard startTime.isFinite, endTime.isFinite, startTime >= 0, endTime > startTime else {
            fail("Transcript timing is unavailable.")
            return
        }
        let previous = entries.first { $0.segmentID == segmentID }
        // A retry that invalidates previous complete coverage must not leave a false complete checkpoint.
        if !isComplete || previous.map({ $0.start != startTime || $0.end != endTime }) == true {
            completedThrough = min(completedThrough, previous?.start ?? startTime)
        }
        let bounded = Self.bounded(text)
        entries.removeAll { $0.segmentID == segmentID }
        entries.append(Entry(segmentID: segmentID, start: startTime, end: endTime,
            text: bounded.text, complete: isComplete, truncated: bounded.truncated))
        entries.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.segmentID.uuidString < $1.segmentID.uuidString
        }
        advanceCompletedCoverage()
        if entries.count > Self.entryLimit {
            let removed = entries.prefix(entries.count - Self.entryLimit)
            droppedEarlierText = droppedEarlierText || removed.contains { !$0.text.isEmpty }
            entries.removeFirst(entries.count - Self.entryLimit)
        }
        failure = nil
        refreshTranscript()
        refreshStatus()
    }

    /// Ephemeral recognition is never evidence of saved audio or completed processing.
    mutating func receivedPreview(text: String, words: [TimedSpeechWord],
                                  startTime: Double, endTime: Double) {
        guard !finished, startTime.isFinite, endTime.isFinite, startTime >= 0,
              endTime > startTime, endTime > latestPreviewEnd else { return }
        latestPreviewEnd = endTime
        previewFailure = nil
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            preview = nil
        } else {
            let duration = endTime - startTime
            var previousStart = -1.0
            var characterCount = 0
            let validWords = !words.isEmpty && words.count <= 150 && words.allSatisfy { word in
                defer { previousStart = word.startTime }
                characterCount += word.word.count + 1
                return !word.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && word.startTime.isFinite && word.endTime.isFinite
                    && word.startTime >= 0 && word.endTime >= word.startTime
                    && word.startTime >= previousStart
                    && word.endTime <= duration + Self.timingTolerance
                    && characterCount <= Self.characterLimit
            }
            preview = Preview(start: startTime, end: endTime, text: Self.bounded(value).text,
                words: validWords ? words : nil)
        }
        refreshTranscript()
        refreshStatus()
    }

    mutating func clearPreview() {
        preview = nil
        previewFailure = nil
        // Keep the high-water mark so a late earlier result cannot reappear.
        refreshTranscript()
        refreshStatus()
    }

    mutating func previewUnavailable(_ message: String) {
        guard !finished else { return }
        preview = nil
        let value = Self.bounded(message).text
        previewFailure = value.isEmpty ? "Retrying local speech processing." : value
        refreshTranscript()
        refreshStatus()
    }

    mutating func pause() {
        snapshot.isRecording = false
        finished = false
        refreshStatus()
    }

    mutating func finish() {
        // An out-of-order completion callback cannot turn off an active microphone indicator.
        guard !snapshot.isRecording else { refreshStatus(); return }
        finished = true
        preview = nil
        previewFailure = nil
        refreshTranscript()
        refreshStatus()
    }

    mutating func fail(_ message: String) {
        let value = Self.bounded(message).text
        failure = value.isEmpty ? "Processing could not finish." : value
        refreshStatus()
    }

    private mutating func refreshTranscript() {
        let stable = entries.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let stableIsTruncated = droppedEarlierText || entries.contains(where: \.truncated)
        hasVisiblePreview = false
        guard let preview else {
            snapshot.transcript = Self.bounded(stable, alreadyTruncated: stableIsTruncated).text
            return
        }
        let committedEnd = entries.filter(\.complete).map(\.end).max() ?? 0
        guard preview.end > committedEnd + Self.timingTolerance else {
            snapshot.transcript = Self.bounded(stable, alreadyTruncated: stableIsTruncated).text
            return
        }
        guard let words = preview.words else {
            // Showing this bounded window by itself avoids fabricated timing and duplicated text.
            snapshot.transcript = preview.text
            hasVisiblePreview = !preview.text.isEmpty
            return
        }
        let tail = words.filter {
            preview.start + ($0.startTime + $0.endTime) / 2 >= committedEnd
        }.map(\.word).joined(separator: " ")
        hasVisiblePreview = !tail.isEmpty
        let joined = [stable, tail].filter { !$0.isEmpty }.joined(separator: "\n\n")
        snapshot.transcript = Self.bounded(joined, alreadyTruncated: stableIsTruncated).text
    }

    private mutating func advanceCompletedCoverage() {
        // At most five entries exist before trimming; discarded out-of-order coverage is conservatively unknown.
        var advanced = true
        while advanced {
            advanced = false
            for entry in entries where entry.complete {
                if entry.start <= completedThrough + Self.timingTolerance, entry.end > completedThrough {
                    completedThrough = entry.end
                    advanced = true
                }
            }
        }
    }

    private mutating func refreshStatus() {
        let status: String
        if let failure {
            status = "Issue: " + failure
                + (hasVisiblePreview ? " · Live preview · may change" + savedStatusSuffix : "")
        } else if let previewFailure, snapshot.isRecording {
            status = "Live preview unavailable · recording continues" + savedStatusSuffix + " · " + previewFailure
        } else if hasVisiblePreview {
            status = "Live preview · may change" + savedStatusSuffix
                + (snapshot.isRecording ? "" : " · Finishing transcript…")
        } else if snapshot.isRecording {
            if !hasSpeechModel { status = "Recording audio · speech model not installed" }
            else if entries.contains(where: { !$0.complete }) { status = "Recording · partial transcript" }
            else if savedThrough <= 0 { status = "Recording · listening…" }
            else {
                let seconds = Int(savedThrough)
                let saved = String(format: "%d:%02d", seconds / 60, seconds % 60)
                if entries.isEmpty {
                    status = "Saved through " + saved + (completedThrough + Self.timingTolerance < savedThrough
                        ? " · Transcribing locally" : " · Transcript saved")
                }
                else if completedThrough + Self.timingTolerance < savedThrough {
                    status = "Saved through " + saved + " · Transcript catching up"
                } else { status = "Saved through " + saved + " · Live transcript" }
            }
        } else if !hasSpeechModel {
            status = savedThrough > 0 ? "Audio saved · speech model not installed" : "Paused · no saved audio reported"
        } else if !finished {
            status = entries.contains(where: { !$0.complete }) ? "Finishing transcript… · partial results" : "Finishing transcript…"
        } else if savedThrough <= 0 {
            status = "Paused · no saved audio reported"
        } else if entries.isEmpty || snapshot.transcript.allSatisfy(\.isWhitespace) {
            status = "Audio saved · transcript unavailable"
        } else if entries.contains(where: { !$0.complete }) || completedThrough + Self.timingTolerance < savedThrough
                    || (entries.last?.end ?? 0) + Self.timingTolerance < savedThrough {
            status = "Audio saved · transcript incomplete"
        } else {
            // Availability is not a semantic or all-session completeness claim.
            status = "Audio saved · transcript available"
        }
        snapshot.status = Self.bounded(status).text
    }

    private var savedStatusSuffix: String {
        guard savedThrough > 0 else { return "" }
        let seconds = Int(min(savedThrough, Double(Int.max / 2)))
        return " · Saved through " + String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func bounded(_ text: String, alreadyTruncated: Bool = false) -> (text: String, truncated: Bool) {
        let tail = text.suffix(characterLimit)
        let truncated = alreadyTruncated || tail.startIndex != text.startIndex
        guard truncated else { return (String(tail), false) }
        return ("…" + String(tail.suffix(characterLimit - 1)), true)
    }
}
