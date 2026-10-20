import Accelerate
import AVFoundation
import Foundation
import os

/// Provisional audio only. These samples are not an acknowledgment of durable recording.
struct LiveAudioWindow: Sendable {
    let intervalID: UUID
    let sequence: Int64
    let startTime: Double
    let endTime: Double
    let samples: [Float]
    let droppedBuffers: Int64
    let discontinuityCount: Int64
    let bufferIssue: String?
}

struct LiveAudioDiagnostics: Sendable {
    let pendingFrames: Int64
    let peakPendingFrames: Int64
    let maximumPendingFrames: Int64
    let retainedSamples: Int
    let scratchBufferAllocations: Int
    let droppedBuffers: Int64
    let discontinuityCount: Int64
    let issue: String?
    let isClosed: Bool
}

/// Independent best-effort mirror. Its admission lock covers counters and scheduling only.
/// Conversion, downmixing, ring storage, and owned snapshots belong exclusively to queue.
final class LiveAudioBuffer: @unchecked Sendable {
    private struct Admission {
        var accepting = true
        var pendingFrames: Int64 = 0
        var peakPendingFrames: Int64 = 0
        var firstSampleTime: Int64?
        var expectedSampleTime: Int64?
        var epoch: Int64 = 0
        var sequence: Int64 = 0
        var droppedBuffers: Int64 = 0
        var discontinuities: Int64 = 0
        var issue: String?
    }
    private struct Ticket: Sendable {
        let epoch: Int64
        let sequence: Int64
        let relativeStart: Double
        let frames: Int64
    }
    private let admission = OSAllocatedUnfairLock(initialState: Admission())
    private let queue: DispatchQueue
    private let format: AVAudioFormat
    private let intervalID: UUID
    private let maximumPendingFrames: Int64
    private let usableFormat: Bool
    // Queue-confined state; never read or mutated by the capture callback.
    private var ring = LiveAudioRing(capacity: 16_000 * 12)
    private var processedEpoch: Int64 = -1
    private var processedSequence: Int64 = 0
    private var sourceStart: Double = 0
    private var convertedFrames: Int64 = 0
    private var resampler: AVAudioConverter?
    private var normalizationConverter: AVAudioConverter?
    private let monoFormat: AVAudioFormat?
    private let normalizedFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var inputScratch: AVAudioPCMBuffer?
    private var normalizedScratch: AVAudioPCMBuffer?
    private var monoScratch: AVAudioPCMBuffer?
    private var sliceScratch: AVAudioPCMBuffer?
    private var outputScratch: AVAudioPCMBuffer?
    private var scratchBufferAllocations = 0

    init(format: AVAudioFormat, intervalID: UUID, processingQueue: DispatchQueue? = nil) {
        queue = processingQueue ?? DispatchQueue(label: "Keystorm.live-audio-mirror", qos: .userInitiated)
        self.format = format
        self.intervalID = intervalID
        usableFormat = format.sampleRate.isFinite && (8_000...192_000).contains(format.sampleRate)
            && (1...8).contains(format.channelCount)
        maximumPendingFrames = usableFormat ? max(1, Int64(format.sampleRate * 0.75)) : 0
        monoFormat = usableFormat ? AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) : nil
        normalizedFormat = usableFormat ? AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate, channels: format.channelCount, interleaved: false) : nil
    }

    func enqueue(_ buffer: AVReadOnlyAudioPCMBuffer, timestamp: CaptureTimestamp) {
        admission.withLock { state in
            guard state.accepting, buffer.frameLength > 0 else { return }
            let frames = Int64(buffer.frameLength)
            state.sequence &+= 1
            guard usableFormat, buffer.format.isEqual(format), let sampleTime = timestamp.sampleTime else {
                drop(&state, message: "Live preview input format or sample clock is unavailable.")
                return
            }
            if state.firstSampleTime == nil { state.firstSampleTime = sampleTime }
            let origin = state.firstSampleTime!
            let relative = sampleTime.subtractingReportingOverflow(origin)
            let next = sampleTime.addingReportingOverflow(frames)
            guard !relative.overflow, relative.partialValue >= 0, !next.overflow else {
                drop(&state, message: "Live preview sample clock reset.")
                state.expectedSampleTime = nil
                return
            }
            if let expected = state.expectedSampleTime, sampleTime != expected {
                state.epoch &+= 1
                state.discontinuities &+= 1
                state.issue = "Live preview restarted after an audio discontinuity."
            }
            state.expectedSampleTime = next.partialValue
            guard frames <= maximumPendingFrames, state.pendingFrames <= maximumPendingFrames - frames else {
                drop(&state, message: "Live preview dropped audio because its bounded queue was full.")
                return
            }
            let ticket = Ticket(epoch: state.epoch, sequence: state.sequence,
                relativeStart: Double(relative.partialValue) / format.sampleRate, frames: frames)
            state.pendingFrames += frames
            state.peakPendingFrames = max(state.peakPendingFrames, state.pendingFrames)
            // Schedule under the short admission lock so close is ordered after accepted work.
            queue.async { [self, buffer] in
                autoreleasepool {
                    defer { admission.withLock { $0.pendingFrames -= frames } }
                    guard admission.withLock({ $0.accepting && $0.epoch == ticket.epoch }) else { return }
                    if processedEpoch != ticket.epoch { reset(epoch: ticket.epoch, start: ticket.relativeStart) }
                    do {
                        let count = try appendMonoSamples(buffer)
                        // A concurrent overflow invalidates this window rather than splicing across missing audio.
                        guard admission.withLock({ $0.accepting && $0.epoch == ticket.epoch }) else {
                            reset(epoch: -1, start: 0)
                            return
                        }
                        convertedFrames += Int64(count)
                        processedSequence = ticket.sequence
                    } catch {
                        let message = String(("Live preview conversion failed: " + error.localizedDescription).prefix(300))
                        admission.withLock { state in drop(&state, message: message) }
                        reset(epoch: -1, start: 0)
                    }
                }
            }
        }
    }

    func snapshot(after sequence: Int64) async -> LiveAudioWindow? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let state = admission.withLock { $0 }
                guard state.accepting, processedEpoch == state.epoch, processedSequence > sequence,
                      ring.count >= 12_800 else { continuation.resume(returning: nil); return }
                let samples = ring.ownedSamples()
                let end = sourceStart + Double(convertedFrames) / 16_000
                let value = LiveAudioWindow(intervalID: intervalID, sequence: processedSequence,
                    startTime: max(sourceStart, end - Double(samples.count) / 16_000), endTime: end,
                    samples: samples, droppedBuffers: state.droppedBuffers,
                    discontinuityCount: state.discontinuities, bufferIssue: state.issue)
                // Closing is synchronous at admission; never return retained audio from a closed generation.
                let valid = admission.withLock { $0.accepting && $0.epoch == state.epoch }
                continuation.resume(returning: valid ? value : nil)
            }
        }
    }

    func diagnostics() async -> LiveAudioDiagnostics {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let state = admission.withLock { $0 }
                continuation.resume(returning: LiveAudioDiagnostics(pendingFrames: state.pendingFrames,
                    peakPendingFrames: state.peakPendingFrames, maximumPendingFrames: maximumPendingFrames,
                    retainedSamples: ring.count, scratchBufferAllocations: scratchBufferAllocations,
                    droppedBuffers: state.droppedBuffers,
                    discontinuityCount: state.discontinuities, issue: state.issue, isClosed: !state.accepting))
            }
        }
    }

    func close() {
        admission.withLock { state in
            guard state.accepting else { return }
            state.accepting = false
            state.epoch &+= 1
            queue.async { [self] in
                reset(epoch: -1, start: 0)
                ring.releaseStorage()
                inputScratch = nil
                normalizedScratch = nil
                monoScratch = nil
                sliceScratch = nil
                outputScratch = nil
            }
        }
    }

    private func drop(_ state: inout Admission, message: String) {
        state.droppedBuffers &+= 1
        state.discontinuities &+= 1
        state.epoch &+= 1
        state.issue = message
    }

    private func reset(epoch: Int64, start: Double) {
        processedEpoch = epoch
        processedSequence = 0
        sourceStart = start
        convertedFrames = 0
        ring.clear()
        resampler = nil
        normalizationConverter = nil
    }

    /// Native Float32 input stays read-only. Only downmixing/conversion uses owned
    /// scratch buffers, which grow to the largest admitted tap and are reused.
    private func appendMonoSamples(_ source: AVReadOnlyAudioPCMBuffer) throws -> Int {
        let count = Int(source.frameLength)
        if format.commonFormat == .pcmFormatFloat32, !format.isInterleaved {
            return try source.withUnsafeAudioBufferList { list in
                let channels = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
                guard channels.count == Int(format.channelCount),
                      channels.allSatisfy({ $0.mNumberChannels == 1 &&
                          Int($0.mDataByteSize) >= count * MemoryLayout<Float>.size && $0.mData != nil }) else {
                    throw KeystormError.message("Live preview PCM bytes are incomplete.")
                }
                return try downmixAndAppend(frameCount: count) { channel in
                    UnsafePointer(channels[channel].mData!.assumingMemoryBound(to: Float.self))
                }
            }
        }
        // Non-native PCM still needs a mutable converter input. Preserve every
        // interleaved byte and reuse both input and normalized storage.
        guard let normalizedFormat else {
            throw KeystormError.message("Could not create live preview normalization.")
        }
        let input = try scratch(&inputScratch, format: format, capacity: count)
        input.frameLength = AVAudioFrameCount(count)
        try source.withUnsafeAudioBufferList { sourceList in
            let originals = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: sourceList))
            let copies = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            guard originals.count == copies.count else {
                throw KeystormError.message("Live preview PCM buffer layout changed.")
            }
            for index in originals.indices {
                let original = originals[index]
                let copy = copies[index]
                guard original.mDataByteSize <= copy.mDataByteSize,
                      let from = original.mData, let to = copy.mData else {
                    throw KeystormError.message("Live preview PCM bytes are incomplete.")
                }
                to.copyMemory(from: from, byteCount: Int(original.mDataByteSize))
            }
        }
        let normalized = try scratch(&normalizedScratch, format: normalizedFormat, capacity: count)
        normalized.frameLength = 0
        if normalizationConverter == nil {
            normalizationConverter = AVAudioConverter(from: format, to: normalizedFormat)
        }
        guard let normalizationConverter else {
            throw KeystormError.message("Unsupported live preview PCM format.")
        }
        try normalizationConverter.convert(to: normalized, from: input)
        guard let channels = normalized.floatChannelData else {
            throw KeystormError.message("Could not access normalized preview samples.")
        }
        return try downmixAndAppend(frameCount: Int(normalized.frameLength)) { UnsafePointer(channels[$0]) }
    }

    private func downmixAndAppend(frameCount count: Int,
                                  channel: (Int) -> UnsafePointer<Float>) throws -> Int {
        guard count > 0 else { return 0 }
        let channelCount = Int(format.channelCount)
        if channelCount == 1, format.sampleRate == 16_000 {
            ring.append(UnsafeBufferPointer(start: channel(0), count: count))
            return count
        }
        guard let monoFormat else { throw KeystormError.message("Could not create live mono preview.") }
        let mono = try scratch(&monoScratch, format: monoFormat, capacity: count)
        guard let destination = mono.floatChannelData?[0] else {
            throw KeystormError.message("Could not access live mono preview.")
        }
        destination.update(from: channel(0), count: count)
        if channelCount > 1 {
            for index in 1..<channelCount {
                vDSP_vadd(destination, 1, channel(index), 1, destination, 1, vDSP_Length(count))
            }
            var scale = 1 / Float(channelCount)
            vDSP_vsmul(destination, 1, &scale, destination, 1, vDSP_Length(count))
        }
        mono.frameLength = AVAudioFrameCount(count)
        if format.sampleRate == 16_000 {
            ring.append(UnsafeBufferPointer(start: destination, count: count))
            return count
        }
        if resampler == nil {
            resampler = AVAudioConverter(from: monoFormat, to: outputFormat)
            // Keep real source-time alignment; never fabricate an end-of-stream.
            resampler?.primeMethod = .normal
            resampler?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        guard let resampler else { throw KeystormError.message("Unsupported preview sample rate.") }
        let slice = try scratch(&sliceScratch, format: monoFormat, capacity: count)
        let output = try scratch(&outputScratch, format: outputFormat,
            capacity: Int(ceil(Double(count) * 16_000 / format.sampleRate)) + 32)
        guard let sliceSamples = slice.floatChannelData?[0] else {
            throw KeystormError.message("Could not access live preview resampling.")
        }
        output.frameLength = 0
        var cursor = 0
        var conversionError: NSError?
        let status = resampler.convert(to: output, error: &conversionError) { requested, status in
            guard cursor < count, requested > 0 else { status.pointee = .noDataNow; return nil }
            // Supply exactly the requested portion; excess input delays subsequent windows.
            let portion = min(Int(requested), count - cursor)
            sliceSamples.update(from: destination.advanced(by: cursor), count: portion)
            slice.frameLength = AVAudioFrameCount(portion)
            cursor += portion
            status.pointee = .haveData
            return slice
        }
        guard status != .error, conversionError == nil, cursor == count,
              let converted = output.floatChannelData?[0] else {
            throw conversionError ?? NSError(domain: "Keystorm.LivePreview", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio sample-rate conversion did not consume its bounded input."])
        }
        let convertedCount = Int(output.frameLength)
        ring.append(UnsafeBufferPointer(start: converted, count: convertedCount))
        return convertedCount
    }

    private func scratch(_ existing: inout AVAudioPCMBuffer?, format: AVAudioFormat,
                         capacity: Int) throws -> AVAudioPCMBuffer {
        if let existing, Int(existing.frameCapacity) >= capacity { return existing }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw KeystormError.message("Could not allocate bounded live preview storage.")
        }
        existing = buffer
        scratchBufferAllocations += 1
        return buffer
    }
}

/// Fixed-size ring avoids moving twelve seconds of samples on every tap.
private struct LiveAudioRing {
    let capacity: Int
    private var storage: [Float] = []
    private var writeIndex = 0
    private(set) var count = 0

    init(capacity: Int) { self.capacity = capacity }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        if storage.isEmpty { storage = Array(repeating: 0, count: capacity) }
        let sourceOffset = max(0, samples.count - capacity)
        let retainedCount = samples.count - sourceOffset
        let firstCount = min(retainedCount, capacity - writeIndex)
        storage.withUnsafeMutableBufferPointer { destination in
            guard let target = destination.baseAddress, let input = samples.baseAddress else { return }
            target.advanced(by: writeIndex).update(from: input.advanced(by: sourceOffset), count: firstCount)
            if firstCount < retainedCount {
                target.update(from: input.advanced(by: sourceOffset + firstCount), count: retainedCount - firstCount)
            }
        }
        writeIndex = (writeIndex + retainedCount) % capacity
        count = min(capacity, count + retainedCount)
    }

    func ownedSamples() -> [Float] {
        guard count > 0 else { return [] }
        let start = (writeIndex - count + capacity) % capacity
        let firstCount = min(count, capacity - start)
        var result: [Float] = []
        result.reserveCapacity(count)
        result.append(contentsOf: storage[start..<(start + firstCount)])
        if firstCount < count { result.append(contentsOf: storage[0..<(count - firstCount)]) }
        return result
    }

    mutating func clear() { writeIndex = 0; count = 0 }
    mutating func releaseStorage() { clear(); storage.removeAll(keepingCapacity: false) }
}
