import AVFoundation
import Foundation
import Testing
import os
@testable import Keystorm

/// Capture behind its `CaptureSource` seam: interruptions, configuration changes, the first-buffer and stall
/// watchdogs and sample jitter, all driven by a fake source and a fake clock. No microphone, no permission prompt,
/// no sleeping on wall-clock time, and no files outside a unique temporary directory.
@MainActor
@Suite(.serialized)
struct CaptureSourceTests {
    // MARK: Writer jitter

    @Test("A sample gap inside the bridge limit is counted and the take keeps every accepted frame")
    func sampleGapIsBridged() async throws {
        let rig = try WriterRig()
        defer { rig.remove() }
        rig.enqueue(frame: 0)
        // 1,600 frames (100 ms) never arrived.
        rig.enqueue(frame: 3_200)
        rig.enqueue(frame: 4_800)
        try await rig.writer.finish()
        #expect(rig.log.failures.isEmpty)
        #expect(rig.writer.progress.frames == 4_800)
        #expect(rig.writer.progress.discontinuities == 1)
        #expect(rig.writer.progress.skippedFrames == 1_600)
        #expect(rig.log.segments.map(\.frameCount) == [4_800])
    }

    @Test("An overlapping buffer is bridged without counting skipped frames")
    func overlapIsBridged() async throws {
        let rig = try WriterRig()
        defer { rig.remove() }
        rig.enqueue(frame: 0)
        rig.enqueue(frame: 800)
        try await rig.writer.finish()
        #expect(rig.log.failures.isEmpty)
        #expect(rig.writer.progress.frames == 3_200)
        #expect(rig.writer.progress.discontinuities == 1)
        #expect(rig.writer.progress.skippedFrames == 0)
    }

    @Test("Host-clock drift past 50 ms is counted; smaller drift is ignored")
    func clockDriftThreshold() async throws {
        let rig = try WriterRig()
        defer { rig.remove() }
        rig.enqueue(frame: 0)
        // Continuous samples, host clock 30 ms late: ordinary jitter.
        rig.enqueue(frame: 1_600, hostOffset: 0.03)
        #expect(rig.writer.progress.discontinuities == 0)
        // Host clock now 200 ms ahead of the sample clock: counted, not fatal.
        rig.enqueue(frame: 3_200, hostOffset: 0.03 + 0.2)
        rig.enqueue(frame: 4_800, hostOffset: 0.03 + 0.2)
        try await rig.writer.finish()
        #expect(rig.log.failures.isEmpty)
        #expect(rig.writer.progress.discontinuities == 1)
        #expect(rig.writer.progress.frames == 6_400)
    }

    @Test("A format change reports the route change instead of a failure and still finishes cleanly")
    func formatChangeIsARouteChange() async throws {
        let rig = try WriterRig(reportsFormatChange: true)
        defer { rig.remove() }
        rig.enqueue(frame: 0)
        let other = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        rig.writer.enqueue(try captureBuffer(format: other, frames: 4_800), timestamp: captureTimestamp(frame: 1_600))
        rig.writer.enqueue(try captureBuffer(format: rig.format, frames: 1_600), timestamp: captureTimestamp(frame: 1_600))
        try await rig.writer.finish()
        #expect(rig.log.failures.isEmpty)
        #expect(rig.log.formatChanges == 1)
        #expect(rig.writer.progress.frames == 1_600)
        #expect(rig.log.segments.map(\.frameCount) == [1_600])
    }

    // MARK: Interruptions

    @Test("A configuration change pauses the take with everything accepted saved and no failure")
    func configurationChangePausesCleanly() async throws {
        let source = FakeCaptureSource()
        let rig = CaptureRig(sources: [source])
        defer { rig.remove() }
        _ = try await rig.start()
        try source.push(frames: 3_200, at: 0)
        source.emit(.configurationChanged)
        #expect(await waitUntil { rig.log.interruptions.count == 1 })
        #expect(rig.log.interruptions.first?.reason == .routeChanged)
        #expect(rig.log.failures.isEmpty)
        #expect(!rig.capture.isRecording)
        #expect(!rig.capture.isTransitioning)
        #expect(source.stopCount == 1)
        #expect(rig.log.segments.map(\.frameCount) == [3_200])
    }

    @Test("Resume after a route change opens a fresh source on the new input format")
    func resumeReopensOnTheNewInput() async throws {
        let builtIn = FakeCaptureSource(sampleRate: 16_000)
        let airPods = FakeCaptureSource(sampleRate: 48_000)
        let rig = CaptureRig(sources: [builtIn, airPods])
        defer { rig.remove() }
        let first = try await rig.start()
        try builtIn.push(frames: 3_200, at: 0)
        builtIn.emit(.configurationChanged)
        #expect(await waitUntil { rig.log.interruptions.count == 1 })
        #expect(rig.queue.made == 1)

        let second = try await rig.start(startTime: 0.2)
        #expect(rig.queue.made == 2)
        #expect(airPods.openCount == 1 && airPods.startCount == 1)
        #expect(rig.capture.isRecording)
        #expect(rig.capture.sampleRate == 48_000)
        try airPods.push(frames: 4_800, at: 0)
        try await rig.capture.pause()
        let byInterval = Dictionary(grouping: rig.log.segments, by: \.intervalID)
        #expect(byInterval[first]?.map(\.frameCount) == [3_200])
        #expect(byInterval[first]?.first?.sampleRate == 16_000)
        #expect(byInterval[second]?.map(\.frameCount) == [4_800])
        #expect(byInterval[second]?.first?.sampleRate == 48_000)
        #expect(rig.log.failures.isEmpty)
    }

    @Test("A buffer in a new format mid-take is a route change, not a failure")
    func newFormatBufferPausesTheTake() async throws {
        let source = FakeCaptureSource(sampleRate: 16_000)
        let rig = CaptureRig(sources: [source])
        defer { rig.remove() }
        _ = try await rig.start()
        try source.push(frames: 1_600, at: 0)
        let other = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try source.push(frames: 4_800, at: 1_600, format: other)
        #expect(await waitUntil { rig.log.interruptions.count == 1 })
        #expect(rig.log.interruptions.first?.reason == .routeChanged)
        #expect(rig.log.failures.isEmpty)
        #expect(rig.log.segments.map(\.frameCount) == [1_600])
        #expect(!rig.capture.isRecording)
    }

    @Test("Sleep pauses the take like any other interruption")
    func sleepPausesTheTake() async throws {
        let source = FakeCaptureSource()
        let rig = CaptureRig(sources: [source])
        defer { rig.remove() }
        _ = try await rig.start()
        try source.push(frames: 1_600, at: 0)
        source.emit(.willSleep)
        #expect(await waitUntil { rig.log.interruptions.count == 1 })
        #expect(rig.log.interruptions.first?.reason == .systemSleep)
        #expect(rig.log.failures.isEmpty)
        #expect(rig.log.segments.map(\.frameCount) == [1_600])
        #expect(source.stopCount == 1)
    }

    @Test("Audio that stops arriving pauses the take once the stall watchdog fires")
    func stallWatchdog() async throws {
        let source = FakeCaptureSource()
        let rig = CaptureRig(sources: [source])
        defer { rig.remove() }
        _ = try await rig.start()
        try source.push(frames: 1_600, at: 0)
        #expect(await rig.advanceUntil { !rig.log.interruptions.isEmpty })
        #expect(rig.log.interruptions.first?.reason == .stalled)
        #expect(rig.log.failures.isEmpty)
        #expect(!rig.capture.isRecording)
        #expect(source.stopCount == 1)
        #expect(rig.log.segments.map(\.frameCount) == [1_600])
    }

    @Test("A flowing source never trips the stall watchdog")
    func flowingSourceIsNotStalled() async throws {
        let source = FakeCaptureSource()
        let rig = CaptureRig(sources: [source])
        defer { rig.remove() }
        _ = try await rig.start()
        var frame: Int64 = 0
        for _ in 0..<20 {
            try source.push(frames: 1_600, at: frame)
            frame += 1_600
            // 0.25 s per step: every step is shorter than the 2 s stall timeout.
            #expect(await rig.advanceOnce(0.25))
        }
        #expect(rig.log.interruptions.isEmpty)
        #expect(rig.capture.isRecording)
        try await rig.capture.pause()
        #expect(rig.log.segments.map(\.frameCount).reduce(0, +) == 32_000)
    }

    @Test("A source that never delivers a first buffer pauses the take after the first-buffer timeout")
    func firstBufferWatchdog() async throws {
        let source = FakeCaptureSource()
        let rig = CaptureRig(sources: [source])
        defer { rig.remove() }
        _ = try await rig.start()
        #expect(await rig.advanceUntil { !rig.log.interruptions.isEmpty })
        #expect(rig.log.interruptions.first?.reason == .noAudio)
        #expect(rig.log.failures.isEmpty)
        #expect(!rig.capture.isRecording)
        #expect(rig.log.segments.isEmpty)
        #expect(source.stopCount == 1)
    }

    @Test("Without an interruption handler, interruptions arrive through the failure callback")
    func interruptionsFallBackToFailure() async throws {
        let source = FakeCaptureSource()
        let rig = CaptureRig(sources: [source])
        defer { rig.remove() }
        _ = try await rig.start(reportInterruptions: false)
        try source.push(frames: 1_600, at: 0)
        source.emit(.configurationChanged)
        #expect(await waitUntil { rig.log.failures.count == 1 })
        #expect(rig.log.interruptions.isEmpty)
        #expect(rig.log.segments.map(\.frameCount) == [1_600])
    }

    @Test("A user pause stops the source and commits the partial segment without any interruption")
    func userPauseCommitsTheTail() async throws {
        let source = FakeCaptureSource()
        let rig = CaptureRig(sources: [source])
        defer { rig.remove() }
        _ = try await rig.start()
        try source.push(frames: 3_200, at: 0)
        try await rig.capture.pause()
        #expect(!rig.capture.isRecording)
        #expect(source.stopCount == 1)
        #expect(rig.log.interruptions.isEmpty && rig.log.failures.isEmpty)
        #expect(rig.log.segments.map(\.frameCount) == [3_200])
    }

    @Test("A jittery source records through a gap and reports it on the capture")
    func gapDoesNotEndTheTake() async throws {
        let source = FakeCaptureSource()
        let rig = CaptureRig(sources: [source])
        defer { rig.remove() }
        _ = try await rig.start()
        try source.push(frames: 1_600, at: 0)
        try source.push(frames: 1_600, at: 3_200)
        try source.push(frames: 1_600, at: 4_800)
        try await rig.capture.pause()
        #expect(rig.capture.discontinuityCount == 1)
        #expect(rig.log.failures.isEmpty && rig.log.interruptions.isEmpty)
        #expect(rig.log.segments.map(\.frameCount) == [4_800])
    }

    // MARK: Start failures

    @Test("Denied microphone access throws before the input is opened")
    func deniedAccess() async throws {
        let source = FakeCaptureSource()
        source.granted = false
        let rig = CaptureRig(sources: [source])
        defer { rig.remove() }
        await #expect(throws: (any Error).self) { _ = try await rig.start() }
        #expect(source.openCount == 0 && source.startCount == 0)
        #expect(!rig.capture.isRecording && !rig.capture.isTransitioning)
    }

    @Test("A failed open or start releases the source and leaves capture ready to try again")
    func failedStartCanBeRetried() async throws {
        let source = FakeCaptureSource()
        let rig = CaptureRig(sources: [source])
        defer { rig.remove() }
        source.openFailure = CaptureSourceTestError.failed
        await #expect(throws: CaptureSourceTestError.self) { _ = try await rig.start() }
        #expect(source.stopCount == 1)
        source.openFailure = nil
        source.startFailure = CaptureSourceTestError.failed
        await #expect(throws: CaptureSourceTestError.self) { _ = try await rig.start() }
        #expect(source.stopCount == 2)
        #expect(!rig.capture.isRecording && !rig.capture.isTransitioning)
        source.startFailure = nil
        _ = try await rig.start()
        #expect(rig.capture.isRecording)
        try source.push(frames: 1_600, at: 0)
        try await rig.capture.pause()
        #expect(rig.log.segments.map(\.frameCount) == [1_600])
    }
}

// MARK: - Fakes and helpers

enum CaptureSourceTestError: Error { case failed }

/// A microphone that delivers only what a test pushes and reports only the events a test emits.
@MainActor
final class FakeCaptureSource: CaptureSource {
    let format: AVAudioFormat
    var granted = true
    var openFailure: (any Error)?
    var startFailure: (any Error)?
    private(set) var openCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var deliver: (@Sendable (AVReadOnlyAudioPCMBuffer, CaptureTimestamp) -> Void)?
    private var onEvent: (@Sendable (CaptureSourceEvent) -> Void)?

    init(sampleRate: Double = 16_000) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    func requestAccess() async -> Bool { granted }

    func open() async throws -> AVAudioFormat {
        openCount += 1
        if let openFailure { throw openFailure }
        return format
    }

    func start(deliver: @escaping @Sendable (AVReadOnlyAudioPCMBuffer, CaptureTimestamp) -> Void,
               onEvent: @escaping @Sendable (CaptureSourceEvent) -> Void) throws {
        startCount += 1
        if let startFailure { throw startFailure }
        self.deliver = deliver
        self.onEvent = onEvent
    }

    func stop() {
        stopCount += 1
        deliver = nil
        onEvent = nil
    }

    /// Delivers one buffer, as the audio thread would. `format` overrides the opened format to model a swapped input.
    func push(frames: Int, at frame: Int64, format override: AVAudioFormat? = nil) throws {
        let used = override ?? format
        deliver?(try captureBuffer(format: used, frames: AVAudioFrameCount(frames)),
                 captureTimestamp(frame: frame, sampleRate: used.sampleRate))
    }

    func emit(_ event: CaptureSourceEvent) { onEvent?(event) }
}

/// Watchdog time that moves only when a test advances it.
final class FakeCaptureClock: Sendable {
    private struct Sleeper: Sendable {
        let id: UUID
        let deadline: Double
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State { var now = 1_000.0; var sleepers: [Sleeper] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var clock: CaptureClock {
        CaptureClock(uptime: { [self] in self.state.withLock { $0.now } },
                     sleep: { [self] duration in try await self.sleep(duration) })
    }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func advance(_ seconds: Double) {
        let due = state.withLock { state -> [Sleeper] in
            state.now += seconds
            let due = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    private func sleep(_ duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.state.withLock { state in
                    state.sleepers.append(Sleeper(id: id, deadline: state.now + seconds, continuation: continuation))
                }
                // Cancelled before registration: the handler found nothing to resume.
                if Task.isCancelled { self.cancel(id) }
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    private func cancel(_ id: UUID) {
        let sleeper = state.withLock { state -> Sleeper? in
            guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
            return state.sleepers.remove(at: index)
        }
        sleeper?.continuation.resume(throwing: CancellationError())
    }
}

/// What capture reported, from any thread.
final class CaptureSourceLog: Sendable {
    private struct State {
        var segments: [AudioSegment] = []
        var failures: [String] = []
        var interruptions: [CaptureInterruption] = []
        var formatChanges = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var segments: [AudioSegment] { state.withLock { $0.segments } }
    var failures: [String] { state.withLock { $0.failures } }
    var interruptions: [CaptureInterruption] { state.withLock { $0.interruptions } }
    var formatChanges: Int { state.withLock { $0.formatChanges } }
    func commit(_ segment: AudioSegment) { state.withLock { $0.segments.append(segment) } }
    func fail(_ message: String) { state.withLock { $0.failures.append(message) } }
    func interrupt(_ interruption: CaptureInterruption) { state.withLock { $0.interruptions.append(interruption) } }
    func formatChanged() { state.withLock { $0.formatChanges += 1 } }
}

@MainActor
private final class SourceQueue {
    private let sources: [FakeCaptureSource]
    private(set) var made = 0
    init(_ sources: [FakeCaptureSource]) { self.sources = sources }
    /// Each `AudioCapture.start` asks for one source; the last repeats if a test starts more times than it prepared.
    func next() -> any CaptureSource {
        defer { made += 1 }
        return sources[min(made, sources.count - 1)]
    }
}

@MainActor
private final class CaptureRig {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Keystorm-CaptureSource-\(UUID().uuidString)", isDirectory: true)
    let clock: FakeCaptureClock
    let log = CaptureSourceLog()
    let queue: SourceQueue
    let capture: AudioCapture

    init(sources: [FakeCaptureSource]) {
        let clock = FakeCaptureClock()
        let queue = SourceQueue(sources)
        self.clock = clock
        self.queue = queue
        capture = AudioCapture(sourceFactory: { queue.next() }, clock: clock.clock,
                               stallTimeout: 2, firstBufferTimeout: 5, allowsDebugFixture: false)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func start(startTime: Double = 0, reportInterruptions: Bool = true) async throws -> UUID {
        let intervalID = UUID()
        let log = log
        var handler: (@Sendable (CaptureInterruption) -> Void)?
        if reportInterruptions {
            handler = { @Sendable interruption in log.interrupt(interruption) }
        }
        _ = try await capture.start(directory: directory, startTime: startTime, intervalID: intervalID,
            onCommit: { log.commit($0) }, onFailure: { log.fail($0) }, onInterruption: handler)
        return intervalID
    }

    /// Advances the watchdog clock one step once it is asleep. False when the watchdog is gone.
    func advanceOnce(_ seconds: Double) async -> Bool {
        var waited = 0
        while clock.sleeperCount == 0, waited < 1_000 {
            try? await Task.sleep(for: .milliseconds(2))
            waited += 1
        }
        guard clock.sleeperCount > 0 else { return false }
        clock.advance(seconds)
        return true
    }

    /// Steps the clock until `condition` holds, giving the watchdog time to run between steps.
    func advanceUntil(step: Double = 0.25, limit: Int = 80, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<limit {
            if condition() { return true }
            var waited = 0
            while clock.sleeperCount == 0, !condition(), waited < 500 {
                try? await Task.sleep(for: .milliseconds(2))
                waited += 1
            }
            if condition() { return true }
            guard clock.sleeperCount > 0 else { return false }
            clock.advance(step)
        }
        return condition()
    }
}

@MainActor
private final class WriterRig {
    let directory: URL
    let format: AVAudioFormat
    let log: CaptureSourceLog
    let writer: SegmentedAudioWriter
    private let samples: AVReadOnlyAudioPCMBuffer

    init(reportsFormatChange: Bool = false) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-CaptureWriter-\(UUID().uuidString)", isDirectory: true)
        let log = CaptureSourceLog()
        var formatChanged: (@Sendable () -> Void)?
        if reportsFormatChange {
            formatChanged = { @Sendable in log.formatChanged() }
        }
        self.directory = directory
        self.format = format
        self.log = log
        samples = try captureBuffer(format: format, frames: 1_600)
        writer = try SegmentedAudioWriter(
            directory: directory, format: format, intervalID: UUID(), startTime: 0,
            uptime: { 1_000 },
            onCommit: { log.commit($0) }, onFailure: { log.fail($0) },
            onFormatChange: formatChanged)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func enqueue(frame: Int64, hostOffset: Double = 0) {
        writer.enqueue(samples, timestamp: captureTimestamp(frame: frame, hostOffset: hostOffset))
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(3))
    }
    return true
}

private func captureBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVReadOnlyAudioPCMBuffer {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channels = try #require(buffer.floatChannelData)
    for channel in 0..<Int(format.channelCount) {
        channels[channel].update(repeating: 0.25, count: Int(frames))
    }
    return AVReadOnlyAudioPCMBuffer(copying: buffer)
}

private func captureTimestamp(frame: Int64, sampleRate: Double = 16_000, hostOffset: Double = 0) -> CaptureTimestamp {
    CaptureTimestamp(sampleTime: frame,
                     hostTime: AVAudioTime.hostTime(forSeconds: 100 + Double(frame) / sampleRate + hostOffset))
}
