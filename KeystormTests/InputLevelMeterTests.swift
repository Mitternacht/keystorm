import AVFoundation
import Foundation
import Testing
@testable import Keystorm

struct InputLevelMeterTests {
    // MARK: Scale

    @Test("Silence is empty, full scale is full, and the scale only rises")
    func scaleEndpointsAndMonotonicity() {
        #expect(AudioLevelScale.normalized(amplitude: 0) == 0)
        #expect(AudioLevelScale.normalized(amplitude: .nan) == 0)
        #expect(AudioLevelScale.normalized(amplitude: -1) == 0)
        #expect(AudioLevelScale.normalized(amplitude: 1) == 1)
        #expect(AudioLevelScale.normalized(amplitude: 4) == 1)
        let amplitudes: [Float] = [0.004, 0.01, 0.03, 0.1, 0.2, 0.3]
        let positions = amplitudes.map { AudioLevelScale.normalized(amplitude: $0) }
        #expect(positions == positions.sorted())
        #expect(Set(positions).count == positions.count)
    }

    @Test("Speech-level input lands in the middle of the bar, not at either end")
    func speechLevelIsVisible() {
        // About -26 dBFS is ordinary speech into a built-in microphone.
        let speech = AudioLevelScale.normalized(amplitude: 0.05)
        #expect(speech > 0.3)
        #expect(speech < 0.8)
        // Room noise near -60 dBFS must not move the bar.
        #expect(AudioLevelScale.normalized(amplitude: 0.001) == 0)
    }

    @Test("The meter target blends RMS and peak and stays within 0 to 1")
    func meterTarget() {
        #expect(AudioLevel.silent.meterTarget == 0)
        #expect(AudioLevel(rms: 1, peak: 1).meterTarget > 0.999)
        let steady = AudioLevel(rms: 0.05, peak: 0.05).meterTarget
        let spiky = AudioLevel(rms: 0.05, peak: 0.5).meterTarget
        #expect(spiky > steady)
        #expect((0...1).contains(AudioLevel(rms: 9, peak: 9).meterTarget))
    }

    @Test("The spoken description is coarse, so VoiceOver is not flooded")
    func description() {
        #expect(String(localized: AudioLevelScale.description(level: 0)) == String(localized: "No sound"))
        #expect(String(localized: AudioLevelScale.description(level: 0.1)) == String(localized: "Quiet"))
        #expect(String(localized: AudioLevelScale.description(level: 0.5)) == String(localized: "Good"))
        #expect(String(localized: AudioLevelScale.description(level: 0.95)) == String(localized: "Loud"))
    }

    // MARK: Smoothing

    @Test("The bar rises quickly and falls slowly")
    func attackIsFasterThanRelease() {
        var rising = LevelSmoother()
        rising.step(target: 1, elapsed: 0.1)
        #expect(rising.value > 0.9)

        var falling = LevelSmoother()
        falling.step(target: 1, elapsed: 5)
        #expect(falling.value > 0.99)
        falling.step(target: 0, elapsed: 0.1)
        #expect(falling.value > 0.5)
        #expect(falling.value < rising.value)
    }

    @Test("Steps of different sizes land on the same curve")
    func smoothingIsIndependentOfFrameRate() {
        var coarse = LevelSmoother()
        coarse.step(target: 0.8, elapsed: 0.1)
        var fine = LevelSmoother()
        for _ in 0..<10 { fine.step(target: 0.8, elapsed: 0.01) }
        #expect(abs(coarse.value - fine.value) < 0.001)
    }

    @Test("A silent input settles on exactly zero, so an idle meter stops redrawing")
    func settlesOnZero() {
        var smoother = LevelSmoother()
        smoother.step(target: 1, elapsed: 1)
        for _ in 0..<300 { smoother.step(target: 0, elapsed: 1.0 / 30) }
        #expect(smoother.value == 0)
    }

    @Test("Bad input never moves the bar outside 0 to 1")
    func smoothingIgnoresBadInput() {
        var smoother = LevelSmoother()
        smoother.step(target: 0.5, elapsed: 0.5)
        let before = smoother.value
        smoother.step(target: 1, elapsed: 0)
        smoother.step(target: 1, elapsed: -1)
        smoother.step(target: 1, elapsed: .nan)
        #expect(smoother.value == before)
        smoother.step(target: .nan, elapsed: 1)
        #expect((0...1).contains(smoother.value))
        smoother.step(target: 7, elapsed: 10)
        #expect(smoother.value <= 1)
        smoother.reset()
        #expect(smoother.value == 0)
    }

    // MARK: Shared meter

    @Test("A published level reads back, and a read starts a fresh peak window")
    func publishAndRead() {
        let meter = InputLevelMeter(staleAfterNanoseconds: 1_000)
        meter.publish(rms: 0.1, peak: 0.4, at: 100)
        meter.publish(rms: 0.2, peak: 0.3, at: 200)
        let first = meter.read(at: 300)
        #expect(first.rms == 0.2)
        // The loudest peak since the last read, not just the latest buffer's.
        #expect(first.peak == 0.4)
        let second = meter.read(at: 400)
        #expect(second.rms == 0.2)
        #expect(second.peak == 0.2)
    }

    @Test("A level that stops updating reads as silence")
    func staleLevelIsSilent() {
        let meter = InputLevelMeter(staleAfterNanoseconds: 1_000)
        meter.publish(rms: 0.3, peak: 0.5, at: 1_000)
        #expect(meter.read(at: 2_000).rms == 0.3)
        #expect(meter.read(at: 2_001) == .silent)
        #expect(InputLevelMeter(staleAfterNanoseconds: 1_000).read(at: 5) == .silent)
    }

    @Test("Reset silences the meter at once, and invalid samples count as zero")
    func resetAndInvalidSamples() {
        let meter = InputLevelMeter(staleAfterNanoseconds: 1_000_000)
        meter.publish(rms: 0.3, peak: 0.5, at: 10)
        meter.reset()
        #expect(meter.read(at: 11) == .silent)
        meter.publish(rms: .nan, peak: .infinity, at: 20)
        #expect(meter.read(at: 21) == AudioLevel(rms: 0, peak: 0))
        meter.publish(rms: 3, peak: 5, at: 30)
        #expect(meter.read(at: 31) == AudioLevel(rms: 1, peak: 1))
    }

    // MARK: Live audio feed

    @Test("The live audio mirror publishes the loudness of what it is given, and closing silences it")
    func liveAudioBufferFeedsTheMeter() async throws {
        let meter = InputLevelMeter(staleAfterNanoseconds: 60_000_000_000)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = LiveAudioBuffer(format: format, intervalID: UUID(), levelMeter: meter)
        let audio = try samples(format: format, frames: 1_600, values: [0.25])
        buffer.enqueue(audio, timestamp: timestamp(frame: 0, rate: 16_000))
        _ = await buffer.diagnostics()
        let level = meter.read()
        #expect(abs(level.rms - 0.25) < 0.001)
        #expect(abs(level.peak - 0.25) < 0.001)
        buffer.close()
        #expect(meter.read() == .silent)
    }

    @Test("A stereo capture at another rate is measured after the downmix")
    func stereoLevelIsMeasuredAfterDownmix() async throws {
        let meter = InputLevelMeter(staleAfterNanoseconds: 60_000_000_000)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = LiveAudioBuffer(format: format, intervalID: UUID(), levelMeter: meter)
        defer { buffer.close() }
        let audio = try samples(format: format, frames: 4_800, values: [0.25, 0.75])
        buffer.enqueue(audio, timestamp: timestamp(frame: 0, rate: 48_000))
        _ = await buffer.diagnostics()
        #expect(abs(meter.read().rms - 0.5) < 0.001)
    }

    @Test("Digital silence reads as an empty bar")
    func silentInputReadsEmpty() async throws {
        let meter = InputLevelMeter(staleAfterNanoseconds: 60_000_000_000)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = LiveAudioBuffer(format: format, intervalID: UUID(), levelMeter: meter)
        defer { buffer.close() }
        buffer.enqueue(try samples(format: format, frames: 1_600, values: [0]),
                       timestamp: timestamp(frame: 0, rate: 16_000))
        _ = await buffer.diagnostics()
        #expect(meter.read().meterTarget == 0)
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
