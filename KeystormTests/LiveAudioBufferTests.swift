import AVFoundation
import Foundation
import Testing
import os
@testable import Keystorm

struct LiveAudioBufferTests {
    @Test func monoPreviewStartsBeforeDurableSegmentAndOwnsItsSamples() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let interval = UUID()
        let preview = LiveAudioBuffer(format: format, intervalID: interval)
        defer { preview.close() }
        let buffer = try samples(format: format, frames: 1_600, values: [0.25])
        for index in 0..<7 {
            preview.enqueue(buffer, timestamp: timestamp(frame: 96_000 + Int64(index * 1_600), rate: 16_000))
            _ = await preview.diagnostics()
        }
        #expect(await preview.snapshot(after: 0) == nil)
        for index in 7..<10 {
            preview.enqueue(buffer, timestamp: timestamp(frame: 96_000 + Int64(index * 1_600), rate: 16_000))
            _ = await preview.diagnostics()
        }
        let first = try #require(await preview.snapshot(after: 0))
        #expect(first.intervalID == interval)
        #expect(first.sequence == 10)
        #expect(first.samples.count == 16_000)
        #expect(first.samples.allSatisfy { $0 == 0.25 })
        #expect(first.startTime == 0)
        #expect(first.endTime == 1)
        #expect(await preview.diagnostics().scratchBufferAllocations == 0)
        #expect(await preview.snapshot(after: first.sequence) == nil)
        var owned = first.samples
        owned[0] = -0.75
        preview.enqueue(buffer, timestamp: timestamp(frame: 112_000, rate: 16_000))
        let next = try #require(await preview.snapshot(after: first.sequence))
        #expect(next.samples.first == 0.25)
        #expect(owned.first == -0.75)
    }

    @Test func stereoFortyEightKIsAveragedAndResampledOffTheProducer() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let preview = LiveAudioBuffer(format: format, intervalID: UUID())
        defer { preview.close() }
        let buffer = try samples(format: format, frames: 4_800, values: [0.25, 0.75])
        await feed(preview, buffer: buffer, count: 10, startFrame: 0, rate: 48_000)
        let window = try #require(await preview.snapshot(after: 0))
        #expect(window.samples.count >= 12_800)
        #expect(window.samples.count <= 16_160)
        #expect(window.samples.dropFirst(512).allSatisfy { abs($0 - 0.5) < 0.01 })
        #expect(abs(window.endTime - 1) < 0.02)
        #expect(window.droppedBuffers == 0)
    }

    @Test(arguments: [16_000.0, 48_000.0])
    func nativeFloatConversionReusesBoundedScratchStorage(rate: Double) async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let preview = LiveAudioBuffer(format: format, intervalID: UUID())
        defer { preview.close() }
        let frames = AVAudioFrameCount(rate / 10)
        let buffer = try samples(format: format, frames: frames, values: [-0.25, 0.75])
        await feed(preview, buffer: buffer, count: 10, startFrame: 0, rate: rate)
        let warm = await preview.diagnostics()
        #expect(warm.scratchBufferAllocations == (rate == 16_000 ? 1 : 3))
        await feed(preview, buffer: buffer, count: 100, startFrame: Int64(frames) * 10, rate: rate)
        let sustained = await preview.diagnostics()
        #expect(sustained.scratchBufferAllocations == warm.scratchBufferAllocations)
        #expect(sustained.droppedBuffers == 0)
        let window = try #require(await preview.snapshot(after: 0))
        #expect(window.samples.dropFirst(512).allSatisfy { abs($0 - 0.25) < 0.01 })
    }

    @Test func interleavedIntegerPcmConvertsToFiniteMono() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 2, interleaved: true))
        let mutable = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        mutable.frameLength = 4_410
        let channel = try #require(mutable.int16ChannelData?[0])
        for index in 0..<4_410 { channel[index * 2] = 8_192; channel[index * 2 + 1] = 24_576 }
        // Initialize all interleaved bytes directly. The SDK convenience copying initializer
        // currently copies only frameLength scalar samples for this interleaved Int16 fixture.
        let immutable = try AVReadOnlyAudioPCMBuffer(format: format, frameCapacity: 4_410) { list in
            let destination = try #require(list.pointee.mBuffers.mData)
            destination.copyMemory(from: channel, byteCount: 4_410 * 2 * MemoryLayout<Int16>.size)
            list.pointee.mBuffers.mDataByteSize = UInt32(4_410 * 2 * MemoryLayout<Int16>.size)
        }
        #expect(immutable.frameLength == 4_410)
        let preview = LiveAudioBuffer(format: format, intervalID: UUID())
        defer { preview.close() }
        await feed(preview, buffer: immutable, count: 10, startFrame: 0, rate: 44_100)
        let window = try #require(await preview.snapshot(after: 0))
        #expect(window.samples.count >= 12_800)
        #expect(window.samples.allSatisfy { $0.isFinite })
        #expect(window.samples.dropFirst(512).allSatisfy { abs($0 - 0.5) < 0.01 })
        let warm = await preview.diagnostics()
        #expect(warm.scratchBufferAllocations == 5)
        await feed(preview, buffer: immutable, count: 10, startFrame: 44_100, rate: 44_100)
        #expect(await preview.diagnostics().scratchBufferAllocations == warm.scratchBufferAllocations)
        #expect(await preview.diagnostics().droppedBuffers == 0)
    }

    @Test func rollingStorageAndPendingAdmissionRemainBounded() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let preview = LiveAudioBuffer(format: format, intervalID: UUID())
        let buffer = try samples(format: format, frames: 1_600, values: [0.125])
        await feed(preview, buffer: buffer, count: 200, startFrame: 0, rate: 16_000)
        let diagnostics = await preview.diagnostics()
        #expect(diagnostics.retainedSamples == 192_000)
        #expect(diagnostics.peakPendingFrames <= diagnostics.maximumPendingFrames)
        #expect(diagnostics.maximumPendingFrames == 12_000)
        let window = try #require(await preview.snapshot(after: 0))
        #expect(window.samples.count == 192_000)
        #expect(window.startTime == 8)
        #expect(window.endTime == 20)
        preview.close()
        let closed = await preview.diagnostics()
        #expect(closed.isClosed)
        #expect(closed.retainedSamples == 0)
        #expect(await preview.snapshot(after: 0) == nil)
    }

    @Test func previewOverflowCannotDropDurableWriterAudioAndRecoveryDoesNotSplice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let receipts = LiveWriterReceipts()
        let interval = UUID()
        let writer = try SegmentedAudioWriter(directory: directory, format: format, intervalID: interval,
            startTime: 0, onCommit: { receipts.commit($0) }, onFailure: { receipts.fail($0) })
        let queue = DispatchQueue(label: "Keystorm.test.stalled-preview")
        let preview = LiveAudioBuffer(format: format, intervalID: interval, processingQueue: queue)
        defer { preview.close() }
        let first = try samples(format: format, frames: 1_600, values: [0.25])
        queue.suspend()
        // Deterministically stall only preview conversion. Durable admission and writing continue normally.
        for index in 0..<20 {
            let time = timestamp(frame: Int64(index * 1_600), rate: 16_000)
            writer.enqueue(first, timestamp: time)
            preview.enqueue(first, timestamp: time)
        }
        queue.resume()
        let dropped = await preview.diagnostics()
        #expect(dropped.droppedBuffers > 0)
        #expect(dropped.peakPendingFrames <= 12_000)
        #expect(await preview.snapshot(after: 0) == nil)
        let resumed = try samples(format: format, frames: 1_600, values: [0.75])
        for index in 20..<30 {
            let time = timestamp(frame: Int64(index * 1_600), rate: 16_000)
            writer.enqueue(resumed, timestamp: time)
            preview.enqueue(resumed, timestamp: time)
            _ = await preview.diagnostics()
        }
        try await writer.finish()
        #expect(receipts.failures.isEmpty)
        #expect(receipts.segments.reduce(0) { $0 + $1.frameCount } == 48_000)
        #expect(writer.progress.frames == 48_000)
        for segment in receipts.segments {
            let url = directory.appendingPathComponent(segment.fileName)
            #expect(try AVAudioFile(forReading: url).length == segment.frameCount)
            #expect(try CaptureDurability.sha256(url) == segment.sha256)
        }
        let window = try #require(await preview.snapshot(after: 0))
        #expect(window.startTime == 2)
        #expect(window.endTime == 3)
        #expect(window.samples.allSatisfy { $0 == 0.75 })
        #expect(window.droppedBuffers == dropped.droppedBuffers)
        #expect(window.bufferIssue?.contains("bounded queue") == true)
    }

    @Test func discontinuityAndNewCaptureGenerationCannotReuseOldSamples() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let oldID = UUID()
        let old = LiveAudioBuffer(format: format, intervalID: oldID)
        let first = try samples(format: format, frames: 1_600, values: [0.25])
        await feed(old, buffer: first, count: 9, startFrame: 64_000, rate: 16_000)
        let previous = try #require(await old.snapshot(after: 0))
        #expect(previous.startTime == 0)
        let second = try samples(format: format, frames: 1_600, values: [0.5])
        await feed(old, buffer: second, count: 10, startFrame: 80_000, rate: 16_000)
        let afterGap = try #require(await old.snapshot(after: previous.sequence))
        #expect(afterGap.startTime == 1)
        #expect(afterGap.endTime == 2)
        #expect(afterGap.samples.allSatisfy { $0 == 0.5 })
        #expect(afterGap.discontinuityCount > 0)
        #expect(afterGap.bufferIssue?.contains("discontinuity") == true)
        old.close()
        old.enqueue(first, timestamp: timestamp(frame: 96_000, rate: 16_000))
        #expect(await old.snapshot(after: 0) == nil)
        let newID = UUID()
        let current = LiveAudioBuffer(format: format, intervalID: newID)
        defer { current.close() }
        await feed(current, buffer: second, count: 9, startFrame: 8_000_000, rate: 16_000)
        let fresh = try #require(await current.snapshot(after: 0))
        #expect(fresh.intervalID == newID)
        #expect(fresh.intervalID != oldID)
        #expect(fresh.sequence == 9)
        #expect(fresh.startTime == 0)
        #expect(fresh.endTime == 0.9)
        #expect(fresh.droppedBuffers == 0)
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func varyingInputPartitionsPreserveSignalAndSourceClock(rate: Double) async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let preview = LiveAudioBuffer(format: format, intervalID: UUID())
        defer { preview.close() }
        let frameCount = Int(rate * 2)
        let partitions = [127, 511, 4_095, 4_800, 8_191]
        var cursor = 0
        var index = 0
        while cursor < frameCount {
            let count = min(partitions[index % partitions.count], frameCount - cursor)
            let start = cursor
            let buffer = try AVReadOnlyAudioPCMBuffer(format: format, frameCapacity: count) { list in
                let destination = try #require(list.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self))
                for offset in 0..<count { destination[offset] = Float(Double(start + offset) / rate * 0.2) }
                list.pointee.mBuffers.mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
            }
            preview.enqueue(buffer, timestamp: timestamp(frame: 7_000_000 + Int64(cursor), rate: rate))
            _ = await preview.diagnostics()
            cursor += count
            index += 1
        }
        let window = try #require(await preview.snapshot(after: 0))
        #expect(window.startTime == 0)
        #expect(abs(window.endTime - 2) < 0.002)
        #expect(window.samples.count == Int((window.endTime * 16_000).rounded()))
        #expect(window.droppedBuffers == 0)
        #expect(window.discontinuityCount == 0)
        // A time-varying signal exposes dropped, duplicated, or zero-filled converter portions.
        let maximumError = window.samples.enumerated().dropFirst(128).map { sample in
            abs(sample.element - Float(Double(sample.offset) / 16_000 * 0.2))
        }.max() ?? .infinity
        #expect(maximumError < 0.001)
    }

    private func feed(_ preview: LiveAudioBuffer, buffer: AVReadOnlyAudioPCMBuffer,
                      count: Int, startFrame: Int64, rate: Double) async {
        for index in 0..<count {
            preview.enqueue(buffer, timestamp: timestamp(frame: startFrame + Int64(index) * Int64(buffer.frameLength), rate: rate))
            _ = await preview.diagnostics()
        }
    }

    private func samples(format: AVAudioFormat, frames: AVAudioFrameCount, values: [Float]) throws -> AVReadOnlyAudioPCMBuffer {
        let mutable = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        mutable.frameLength = frames
        let channels = try #require(mutable.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(repeating: values[channel], count: Int(frames))
        }
        return AVReadOnlyAudioPCMBuffer(copying: mutable)
    }

    private func timestamp(frame: Int64, rate: Double) -> CaptureTimestamp {
        CaptureTimestamp(sampleTime: frame, hostTime: AVAudioTime.hostTime(forSeconds: 100 + Double(frame) / rate))
    }
}

private final class LiveWriterReceipts: Sendable {
    private struct State { var segments: [AudioSegment] = []; var failures: [String] = [] }
    private let storage = OSAllocatedUnfairLock(initialState: State())
    var segments: [AudioSegment] { storage.withLock { $0.segments } }
    var failures: [String] { storage.withLock { $0.failures } }
    func commit(_ segment: AudioSegment) { storage.withLock { $0.segments.append(segment) } }
    func fail(_ message: String) { storage.withLock { $0.failures.append(message) } }
}
