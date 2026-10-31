import AVFoundation
import Foundation
import os

/// Collects what the segmented writer commits, from its own queue.
private final class FileSegmentCollector: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (segments: [AudioSegment](), failures: [String]()))
    func commit(_ segment: AudioSegment) { state.withLock { $0.segments.append(segment) } }
    func fail(_ message: String) { state.withLock { $0.failures.append(message) } }
    var segments: [AudioSegment] { state.withLock { $0.segments } }
    var failures: [String] { state.withLock { $0.failures } }
}

extension WorkspaceModel {
    /// The longest file accepted, the same bound a single recording has.
    static let maximumFileSeconds: Double = 6 * 3_600

    /// Transcribes an audio or video file with the same engine, windows and saved-audio rules as a recording: the
    /// file's first audio track is read as 16 kHz mono, written as five-second saved segments, and finished like a
    /// Long recording (Verbatim). The result is a normal saved dictation in History. Reading is streamed, so a
    /// multi-hour file never sits in memory, and nothing is copied outside Keystorm's own store.
    func transcribeMediaFile(_ url: URL) async throws -> DictationRecordingHandle {
        guard let store, canTranscribeFile else {
            throw KeystormError.message("Finish the current operation before transcribing a file.")
        }
        guard installedModelIDs.contains(ModelCatalog.primarySpeech.id) else {
            throw KeystormError.message("Install the local multilingual speech model in Local Models first.")
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw KeystormError.message("This file has no audio track.") }
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw KeystormError.message("This file has no readable duration.") }
        guard seconds <= Self.maximumFileSeconds else {
            throw KeystormError.message("This file is longer than six hours. Split it and transcribe the parts.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw KeystormError.message("This file's audio cannot be read.") }
        reader.add(output)
        guard reader.startReading() else {
            throw KeystormError.message(reader.error?.localizedDescription ?? "This file's audio cannot be read.")
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw KeystormError.message("The audio format could not be created.")
        }
        var session = VoiceSession()
        session.title = "File · " + url.deletingPathExtension().lastPathComponent
        let brief = BriefDocument()
        let intervalID = UUID()
        let take = BriefTake(intervalID: intervalID, expectedRevision: brief.revisionID, status: .pending)
        session.brief = brief
        session.brief?.takes = [take]
        var metadata = DictationRecordingMetadata(id: take.id, state: .captured)
        metadata.purpose = .longRecording
        metadata.captureMode = .verbatim
        session.dictation = DictationSession(recordings: [metadata])
        let audioDirectory = try await store.audioDirectory(session.id)
        let collector = FileSegmentCollector()
        let writer = try SegmentedAudioWriter(directory: audioDirectory, format: format, intervalID: intervalID,
            startTime: 0, onCommit: { collector.commit($0) }, onFailure: { collector.fail($0) })
        var frame: Int64 = 0
        // Blocks of exactly 0.1 s, whatever size the reader hands over, so every saved segment is exactly five
        // seconds and a file transcribes the same way every time.
        let block = 1_600
        var carry: [Float] = []
        func flush(final: Bool) async throws {
            var offset = 0
            while carry.count - offset >= block || (final && offset < carry.count) {
                let piece = min(block, carry.count - offset)
                while writer.pendingFrames > 3 * 16_000 {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(piece)),
                      let destination = buffer.floatChannelData?[0] else {
                    throw KeystormError.message("The audio buffer could not be created.")
                }
                buffer.frameLength = AVAudioFrameCount(piece)
                carry.withUnsafeBufferPointer { destination.update(from: $0.baseAddress! + offset, count: piece) }
                writer.enqueue(AVReadOnlyAudioPCMBuffer(copying: buffer), timestamp: CaptureTimestamp(
                    sampleTime: frame, hostTime: AVAudioTime.hostTime(forSeconds: 100 + Double(frame) / 16_000)))
                frame += Int64(piece)
                offset += piece
            }
            carry.removeFirst(offset)
        }
        do {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let data = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(data)
                // The reader keeps the file's channels (interleaved); they are averaged here, so a stereo file is as
                // loud as a mono one instead of the sum of its channels, which clips.
                let channels = max(1, sample.formatDescription.flatMap {
                    CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame
                }.map(Int.init) ?? 1)
                let count = length / MemoryLayout<Float>.size
                guard count >= channels else { continue }
                var floats = [Float](repeating: 0, count: count)
                let status = floats.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                               destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw KeystormError.message("This file's audio could not be copied.") }
                if channels == 1 {
                    carry.append(contentsOf: floats)
                } else {
                    let frames = count / channels
                    var mono = [Float](repeating: 0, count: frames)
                    for index in 0..<frames {
                        var sum: Float = 0
                        for channel in 0..<channels { sum += floats[index * channels + channel] }
                        mono[index] = sum / Float(channels)
                    }
                    carry.append(contentsOf: mono)
                }
                try await flush(final: false)
            }
            try await flush(final: true)
            if reader.status == .failed {
                throw KeystormError.message(reader.error?.localizedDescription ?? "This file's audio cannot be read.")
            }
            try await writer.finish()
        } catch {
            reader.cancelReading()
            try? await writer.finish()
            try? FileManager.default.removeItem(at: audioDirectory)
            throw error
        }
        guard collector.failures.isEmpty, frame > 0 else {
            try? FileManager.default.removeItem(at: audioDirectory)
            throw KeystormError.message(collector.failures.first ?? "No audio could be read from this file.")
        }
        session.segments = collector.segments.sorted { $0.startTime < $1.startTime }
        session.intervals = [CaptureInterval(id: intervalID, startedAt: Date(),
            endedAt: Date().addingTimeInterval(Double(frame) / 16_000), sampleRate: 16_000, channelCount: 1)]
        try await registerImportedSession(session, audioAlreadyWritten: true)
        let handle = DictationRecordingHandle(sessionID: session.id, takeID: take.id)
        _ = try await dictationComplete(handle)
        return handle
    }
}
