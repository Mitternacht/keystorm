import AVFoundation
import Foundation
import Darwin

nonisolated struct RecordingAudioEdit: Sendable {
    let directory: URL
    let segments: [AudioSegment]
    let intervals: [CaptureInterval]
    let duration: Double
}

/// File-only work, called from a detached task. PCM memory is bounded to 16,384 frames.
nonisolated enum RecordingAudioEditor {
    private struct Slice {
        let url: URL
        let sourceIntervalID: UUID
        let firstFrame: Int64
        let frames: Int64
        let expected: AudioSegment?
    }
    static func trim(segments: [AudioSegment], audioDirectory: URL, staging: URL,
                     start: Double, end: Double, timelineStart: Double) throws -> RecordingAudioEdit {
        guard segments.count <= 100_000, segments.allSatisfy({ segment in
            segment.frameCount > 0 && segment.sampleRate.isFinite &&
            (8_000...192_000).contains(segment.sampleRate) && (1...8).contains(segment.channelCount) &&
            segment.startTime.isFinite && segment.startTime >= 0 && segment.duration <= 6 * 3_600
        }) else {
            throw KeystormError.message("The saved recording has invalid or unsupported frame metadata.")
        }
        let ordered = segments.sorted { $0.startTime < $1.startTime }
        let duration = ordered.reduce(0) { $0 + $1.duration }
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= duration + 0.000_001 else {
            throw KeystormError.message("Choose a trim range inside this recording, with the end after the start.")
        }
        var position = 0.0
        var slices: [Slice] = []
        for segment in ordered {
            let lower = max(start, position)
            let upper = min(end, position + segment.duration)
            if upper > lower {
                guard segment.fileName.lowercased() == "\(segment.id.uuidString).caf".lowercased() else {
                    throw KeystormError.message("The source audio filename is invalid.")
                }
                let first = max(0, min(segment.frameCount, Int64(((lower - position) * segment.sampleRate).rounded())))
                let last = max(first, min(segment.frameCount, Int64(((upper - position) * segment.sampleRate).rounded())))
                if last > first {
                    slices.append(Slice(url: audioDirectory.appendingPathComponent(segment.fileName),
                        sourceIntervalID: segment.intervalID, firstFrame: first, frames: last - first, expected: segment))
                }
            }
            position += segment.duration
        }
        return try render(slices, staging: staging, timelineStart: timelineStart)
    }
    static func replace(from source: URL, staging: URL, timelineStart: Double) throws -> RecordingAudioEdit {
        try requireRegular(source)
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0 else { throw KeystormError.message("Choose an audio file containing recorded frames.") }
        return try render([Slice(url: source, sourceIntervalID: UUID(), firstFrame: 0,
            frames: file.length, expected: nil)], staging: staging, timelineStart: timelineStart)
    }
    private static func render(_ slices: [Slice], staging: URL, timelineStart: Double) throws -> RecordingAudioEdit {
        guard !slices.isEmpty, timelineStart.isFinite, timelineStart >= 0 else {
            throw KeystormError.message("The selected audio range contains no frames.")
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: staging) } }
        var segments: [AudioSegment] = []
        var intervals: [CaptureInterval] = []
        var previousSource: UUID?
        var currentInterval = UUID()
        var duration = 0.0
        var renderedBytes: Int64 = 0
        let capacityBudget = try? staging.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        for slice in slices {
            try Task.checkCancellation()
            try requireRegular(slice.url)
            if let expected = slice.expected {
                guard try CaptureDurability.sha256(slice.url) == expected.sha256 else {
                    throw KeystormError.message("Original audio failed its checksum. Restore the source before editing it.")
                }
            }
            let input = try AVAudioFile(forReading: slice.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = input.processingFormat
            guard format.sampleRate.isFinite, (8_000...192_000).contains(format.sampleRate),
                  (1...8).contains(format.channelCount), slice.firstFrame >= 0, slice.frames > 0,
                  slice.firstFrame <= input.length, slice.frames <= input.length - slice.firstFrame else {
                throw KeystormError.message("This audio format or frame range is unsupported. Use 8–192 kHz audio with up to eight channels.")
            }
            if let expected = slice.expected {
                guard input.length == expected.frameCount, format.sampleRate == expected.sampleRate,
                      Int(format.channelCount) == expected.channelCount else {
                    throw KeystormError.message("Original audio does not match its saved frame metadata.")
                }
            }
            let bytes = slice.frames.multipliedReportingOverflow(by: Int64(format.channelCount) * 4)
            guard !bytes.overflow, bytes.partialValue <= 8 * 1_024 * 1_024 * 1_024 - renderedBytes,
                  duration + Double(slice.frames) / format.sampleRate <= 6 * 3_600 else {
                throw KeystormError.message("A recording edit supports up to six hours and 8 GiB of decoded audio.")
            }
            if let capacityBudget, capacityBudget < renderedBytes + bytes.partialValue + 256 * 1_024 * 1_024 {
                throw KeystormError.message("There is not enough free space to keep the original and this recording version.")
            }
            renderedBytes += bytes.partialValue
            if previousSource != slice.sourceIntervalID {
                currentInterval = UUID()
                intervals.append(CaptureInterval(id: currentInterval, endedAt: Date(), sampleRate: format.sampleRate,
                    channelCount: Int(format.channelCount)))
                previousSource = slice.sourceIntervalID
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
                throw KeystormError.message("Unable to allocate the bounded audio edit buffer.")
            }
            input.framePosition = slice.firstFrame
            var remaining = slice.frames
            let maximumFrames = Int64(format.sampleRate * 5)
            while remaining > 0 {
                try Task.checkCancellation()
                let id = UUID()
                let url = staging.appendingPathComponent("\(id.uuidString).caf")
                let output = try AVAudioFile(forWriting: url, settings: format.settings,
                    commonFormat: .pcmFormatFloat32, interleaved: false)
                let target = min(remaining, maximumFrames)
                var written: Int64 = 0
                while written < target {
                    try Task.checkCancellation()
                    try input.read(into: buffer, frameCount: AVAudioFrameCount(min(16_384, target - written)))
                    guard buffer.frameLength > 0 else {
                        throw KeystormError.message("The source ended before all selected audio could be read.")
                    }
                    try output.write(from: buffer)
                    written += Int64(buffer.frameLength)
                }
                output.close()
                try CaptureDurability.synchronize(url)
                let segment = AudioSegment(id: id, intervalID: currentInterval, fileName: url.lastPathComponent,
                    startTime: timelineStart + duration, frameCount: written, sampleRate: format.sampleRate,
                    channelCount: Int(format.channelCount), sha256: try CaptureDurability.sha256(url))
                let sidecar = staging.appendingPathComponent("\(id.uuidString).json")
                try JSONEncoder().encode(segment).write(to: sidecar, options: .withoutOverwriting)
                try CaptureDurability.synchronize(sidecar)
                segments.append(segment)
                duration += segment.duration
                remaining -= written
            }
            input.close()
        }
        try CaptureDurability.synchronizeDirectory(staging)
        completed = true
        return RecordingAudioEdit(directory: staging, segments: segments, intervals: intervals, duration: duration)
    }
    private static func requireRegular(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw KeystormError.message("Choose an available regular audio file, without symbolic links.")
        }
    }
}

nonisolated struct RecordingRow: Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let sessionTitle: String
    let parentIsTrashed: Bool
    let take: BriefTake
    let duration: Double
    let transcripts: [TranscriptRevision]
    let transcriptText: String
    let segments: [AudioSegment]
}

@MainActor
final class RecordingPlaybackController: NSObject, @preconcurrency AVAudioPlayerDelegate {
    private var segments: [AudioSegment] = []
    private var directory: URL?
    private var nextIndex = 0
    private var player: AVAudioPlayer?
    private var onError: ((String) -> Void)?
    func play(segments: [AudioSegment], directory: URL, onError: @escaping (String) -> Void) throws {
        stop()
        self.segments = segments
        self.directory = directory
        self.onError = onError
        try playNext()
    }
    func stop() {
        player?.stop(); player?.delegate = nil; player = nil
        segments = []; directory = nil; nextIndex = 0; onError = nil
    }
    private func playNext() throws {
        guard nextIndex < segments.count, let directory else { stop(); return }
        let segment = segments[nextIndex]
        guard segment.fileName.lowercased() == "\(segment.id.uuidString).caf".lowercased() else {
            throw KeystormError.message("Invalid recording playback filename.")
        }
        let url = directory.appendingPathComponent(segment.fileName)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else {
            throw KeystormError.message("A recording segment is unavailable or outside its managed audio folder.")
        }
        nextIndex += 1
        let next = try AVAudioPlayer(contentsOf: url)
        next.delegate = self
        player = next
        guard next.play() else { throw KeystormError.message("The recording could not be played.") }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        do {
            guard flag else { throw KeystormError.message("Recording playback was interrupted.") }
            try playNext()
        } catch {
            let report = onError; stop(); report?(error.localizedDescription)
        }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        guard self.player === player else { return }
        let report = onError; stop(); report?(error?.localizedDescription ?? "The recording could not be decoded.")
    }
}
