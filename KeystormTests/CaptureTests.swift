import AVFoundation
import Foundation
import Testing
import os
@testable import Keystorm

struct CaptureTests {
    @Test func `Rotation preserves every accepted sample and commits a final partial segment`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let receipts = CaptureReceipts()
        let intervalID = UUID()
        let writer = try SegmentedAudioWriter(
            directory: directory, format: format, intervalID: intervalID, startTime: 17,
            maximumBufferedSeconds: 20,
            onCommit: { receipts.commit($0) }, onFailure: { receipts.fail($0) }
        )
        let samples = try makeCaptureBuffer(format: format, frames: 1_600)
        for index in 0..<120 {
            writer.enqueue(samples, timestamp: timestamp(frame: Int64(index * 1_600)))
        }
        try await writer.finish()
        let segments = receipts.segments
        #expect(receipts.failures.isEmpty)
        #expect(segments.map(\.frameCount) == [80_000, 80_000, 32_000])
        #expect(segments.map(\.startTime) == [17, 22, 27])
        #expect(writer.progress.frames == 192_000)
        #expect(segments.allSatisfy { $0.intervalID == intervalID })
        for segment in segments {
            let url = directory.appendingPathComponent(segment.fileName)
            let sidecar = directory.appendingPathComponent("\(segment.id.uuidString).json")
            #expect(try JSONDecoder().decode(AudioSegment.self, from: Data(contentsOf: sidecar)) == segment)
            #expect(try CaptureDurability.sha256(url) == segment.sha256)
            let audio = try AVAudioFile(forReading: url)
            #expect(audio.length == segment.frameCount)
            let decoded = try audio.read(frameCount: 16)
            let mutable = AVAudioPCMBuffer(copying: decoded)
            #expect(mutable.floatChannelData?[0][0] == 0.25)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 6)
        #expect(!files.contains { $0.contains("partial") || $0.hasSuffix(".tmp") })
    }

    @Test func `A clock discontinuity stops admission without concealing the valid prefix`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let receipts = CaptureReceipts()
        let writer = try SegmentedAudioWriter(
            directory: directory, format: format, intervalID: UUID(), startTime: 0,
            onCommit: { receipts.commit($0) }, onFailure: { receipts.fail($0) }
        )
        let samples = try makeCaptureBuffer(format: format, frames: 1_600)
        writer.enqueue(samples, timestamp: timestamp(frame: 0))
        writer.enqueue(samples, timestamp: timestamp(frame: 3_200))
        writer.enqueue(samples, timestamp: timestamp(frame: 4_800))
        await #expect(throws: (any Error).self) { try await writer.finish() }
        #expect(receipts.failures.count == 1)
        #expect(receipts.failures.first?.contains("sample gap") == true)
        #expect(receipts.segments.map(\.frameCount) == [1_600])
        #expect(writer.progress.frames == 1_600)
    }

    @Test func `A bounded queue rejects overflow visibly before acknowledging audio`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let receipts = CaptureReceipts()
        let writer = try SegmentedAudioWriter(
            directory: directory, format: format, intervalID: UUID(), startTime: 0,
            maximumBufferedSeconds: 0.05,
            onCommit: { receipts.commit($0) }, onFailure: { receipts.fail($0) }
        )
        writer.enqueue(try makeCaptureBuffer(format: format, frames: 1_600), timestamp: timestamp(frame: 0))
        await #expect(throws: (any Error).self) { try await writer.finish() }
        #expect(receipts.segments.isEmpty)
        #expect(receipts.failures.count == 1)
        #expect(receipts.failures.first?.contains("could not keep up") == true)
        #expect(writer.progress.frames == 0)
    }

    @Test func `A write failure never acknowledges an uncommitted segment`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let receipts = CaptureReceipts()
        let writer = try SegmentedAudioWriter(
            directory: directory, format: format, intervalID: UUID(), startTime: 0,
            onCommit: { receipts.commit($0) }, onFailure: { receipts.fail($0) }
        )
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
        writer.enqueue(try makeCaptureBuffer(format: format, frames: 1_600), timestamp: timestamp(frame: 0))
        await #expect(throws: (any Error).self) { try await writer.finish() }
        #expect(receipts.segments.isEmpty)
        #expect(receipts.failures.count == 1)
    }

    /// Opt-in because this writes roughly 350 MB and performs 1,080 durable commits.
    /// It accelerates generated audio; it does not qualify real-time microphone capture,
    /// 90 minutes of wall-clock recording, thermal behavior, or battery usage.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_LONG_CAPTURE_SMOKE"] == "1"))
    func `Accelerated ninety minute synthetic writer smoke test`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let receipts = CaptureReceipts()
        let (commits, continuation) = AsyncStream.makeStream(
            of: AudioSegment.self, bufferingPolicy: .bufferingOldest(1)
        )
        defer { continuation.finish() }
        let writer = try SegmentedAudioWriter(
            directory: directory, format: format, intervalID: UUID(), startTime: 0,
            onCommit: { segment in
                receipts.commit(segment)
                continuation.yield(segment)
            },
            onFailure: { message in
                receipts.fail(message)
                continuation.finish()
            }
        )
        let samples = try makeCaptureBuffer(format: format, frames: 16_000)
        var iterator = commits.makeAsyncIterator()
        let started = ProcessInfo.processInfo.systemUptime
        var nextFrame: Int64 = 0
        do {
            for segmentIndex in 0..<1_080 {
                // Wait for each durable five-second commit before feeding the next batch.
                // This bounds producer memory without altering production queue limits.
                for _ in 0..<5 {
                    writer.enqueue(samples, timestamp: timestamp(frame: nextFrame))
                    nextFrame += 16_000
                }
                let received = await iterator.next()
                let segment = try #require(received, "Synthetic writer stopped unexpectedly.")
                #expect(segment.frameCount == 80_000)
                #expect(segment.startTime == Double(segmentIndex * 5))
            }
            try await writer.finish()
        } catch {
            // Finish accepted work before the temporary directory is removed.
            try? await writer.finish()
            throw error
        }
        #expect(receipts.failures.isEmpty)
        #expect(receipts.segments.count == 1_080)
        #expect(writer.progress.frames == 86_400_000)
        #expect(receipts.segments.last?.endTime == 5_400)
        var bytes: Int64 = 0
        for segment in receipts.segments {
            let url = directory.appendingPathComponent(segment.fileName)
            #expect(try CaptureDurability.sha256(url) == segment.sha256)
            let file = try AVAudioFile(forReading: url)
            #expect(file.length == segment.frameCount)
            let sidecar = directory.appendingPathComponent("\(segment.id.uuidString).json")
            #expect(try JSONDecoder().decode(AudioSegment.self, from: Data(contentsOf: sidecar)) == segment)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 2_160)
        #expect(!files.contains { $0.contains("partial") || $0.hasSuffix(".tmp") })
        let report = """
        Accelerated synthetic writer smoke test only.
        Generated audio duration: 5,400 seconds (90 minutes).
        Sample format: 16,000 Hz, one channel, Float32 PCM in CAF.
        Committed samples: \(writer.progress.frames).
        Durable segments: \(receipts.segments.count).
        Audio bytes written: \(bytes).
        Wall-clock seconds: \(ProcessInfo.processInfo.systemUptime - started).
        Does not qualify real-time capture, sustained hardware behavior, thermals, or battery.
        """
        Attachment.record(report, named: "synthetic-writer-smoke.txt")
    }

    private func makeCaptureBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVReadOnlyAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(repeating: 0.25, count: Int(frames))
        }
        return AVReadOnlyAudioPCMBuffer(copying: buffer)
    }

    private func timestamp(frame: Int64) -> CaptureTimestamp {
        CaptureTimestamp(
            sampleTime: frame,
            hostTime: AVAudioTime.hostTime(forSeconds: 100 + Double(frame) / 16_000)
        )
    }
}

private final class CaptureReceipts: Sendable {
    private struct State {
        var segments: [AudioSegment] = []
        var failures: [String] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var segments: [AudioSegment] { state.withLock { $0.segments } }
    var failures: [String] { state.withLock { $0.failures } }
    func commit(_ segment: AudioSegment) { state.withLock { $0.segments.append(segment) } }
    func fail(_ message: String) { state.withLock { $0.failures.append(message) } }
}
