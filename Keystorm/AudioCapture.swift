import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Observation
import os

/// Captures only after an explicit call to start. Inference never runs on this object.
@MainActor
@Observable
final class AudioCapture {
    private(set) var isRecording = false
    private(set) var elapsed: Double = 0
    private(set) var sampleRate: Double = 0
    private(set) var channelCount = 0
    private(set) var hostTime: UInt64 = 0
    /// Synchronous engine/tap teardown only; excludes event dispatch and durable writer drain.
    private(set) var lastMicrophoneStopMilliseconds: Double = 0

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var inputTapNode: AVAudioInputNode?
    #if DEBUG
    private(set) var debugAudioSourceStatus: String?
    @ObservationIgnored private var debugFixtureTask: Task<Void, Never>?
    @ObservationIgnored private var debugFixtureDirectory: URL?
    @ObservationIgnored private var debugFixtureCursor: Int64 = 0
    @ObservationIgnored private var debugFixtureIntervalStart: Int64 = 0
    @ObservationIgnored private var debugFixtureLength: Int64 = 0
    @ObservationIgnored private var debugFixtureExhausted = false
    @ObservationIgnored private var debugFixtureConfiguration: DebugAudioValidationConfiguration?
    #endif
    @ObservationIgnored private var writer: SegmentedAudioWriter?
    @ObservationIgnored private var liveBuffer: LiveAudioBuffer?
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private var isStarting = false
    private var isStopping = false
    var isTransitioning: Bool { isStarting || isStopping }
    @ObservationIgnored private var stopWaiters: [CheckedContinuation<Void, any Error>] = []
    @ObservationIgnored private var failureHandler: (@Sendable (String) -> Void)?

    func start(
        directory: URL,
        startTime: Double,
        intervalID: UUID,
        enableLivePreview: Bool = false,
        onCommit: @escaping @Sendable (AudioSegment) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws -> CaptureInterval {
        guard !isRecording, writer == nil, !isStarting, !isStopping else {
            throw KeystormError.message("A recording is already starting or running.")
        }
        isStarting = true
        defer { isStarting = false }
        #if DEBUG
        if let configuration = try DebugAudioValidationConfiguration.configuration() {
            return try await startDebugFixture(configuration: configuration, directory: directory,
                startTime: startTime, intervalID: intervalID, enableLivePreview: enableLivePreview,
                onCommit: onCommit, onFailure: onFailure)
        }
        #endif
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw KeystormError.message("Microphone access is required. Enable it in System Settings → Privacy & Security → Microphone.")
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw KeystormError.message("The microphone has no usable audio format. Reconnect it and resume explicitly.")
        }
        let token = UUID()
        generation = token
        failureHandler = onFailure
        let writer = try SegmentedAudioWriter(
            directory: directory, format: format, intervalID: intervalID, startTime: startTime,
            onCommit: onCommit,
            onFailure: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    await self.interrupt(message)
                }
            }
        )
        let liveBuffer = enableLivePreview ? LiveAudioBuffer(format: format, intervalID: intervalID) : nil
        self.liveBuffer = liveBuffer
        self.writer = writer
        self.engine = engine
        sampleRate = format.sampleRate
        channelCount = Int(format.channelCount)
        elapsed = 0
        hostTime = mach_absolute_time()
        do {
            // The new tap owns immutable Sendable samples; retaining a buffer does not
            // retain a mutable engine scratch buffer. Admission is bounded before enqueue.
            try input.installAudioTap(
                onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.1), format: format
            ) { buffer, time in
                let timestamp = CaptureTimestamp(time)
                writer.enqueue(buffer, timestamp: timestamp)
                liveBuffer?.enqueue(buffer, timestamp: timestamp)
            }
            inputTapNode = input
            engine.prepare()
            try engine.start()
            isRecording = true
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Preserving an active voice recording"
            )
            observeInterruptions(engine: engine, token: token)
            progressTask = Task { @MainActor [weak self, writer] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, self.generation == token, self.isRecording else { return }
                    let progress = writer.progress
                    self.elapsed = Double(progress.frames) / self.sampleRate
                    if let first = progress.firstHostTime { self.hostTime = first }
                    if let last = progress.lastArrivalUptime,
                       ProcessInfo.processInfo.systemUptime - last > 2 {
                        await self.interrupt("Microphone audio stopped arriving. Recording paused; resume explicitly after checking the input.")
                        return
                    }
                    if progress.lastArrivalUptime == nil,
                       ProcessInfo.processInfo.systemUptime - progress.startedUptime > 3 {
                        await self.interrupt("The microphone supplied no audio. Recording paused; check the input and resume explicitly.")
                        return
                    }
                }
            }
            return CaptureInterval(
                id: intervalID, hostTime: hostTime,
                sampleRate: sampleRate, channelCount: channelCount
            )
        } catch {
            input.removeTap(onBus: 0)
            inputTapNode = nil
            engine.stop()
            liveBuffer?.close()
            self.liveBuffer = nil
            try? await writer.finish()
            self.writer = nil
            self.engine = nil
            failureHandler = nil
            throw error
        }
    }

    /// Stops admission, drains accepted buffers, and commits the final partial segment.
    func pause() async throws {
        if isStopping {
            // A route interruption can already be draining this writer. Every caller
            // observes that same completion before another interval may begin.
            try await withCheckedThrowingContinuation { continuation in stopWaiters.append(continuation) }
            return
        }
        guard let writer else { return }
        isStopping = true
        var completion: Result<Void, any Error> = .success(())
        defer {
            isStopping = false
            let waiters = stopWaiters
            stopWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters { waiter.resume(with: completion) }
        }
        // Clear the owning reference before suspension; a concurrent pause cannot finish twice.
        self.writer = nil
        liveBuffer?.close()
        liveBuffer = nil
        isRecording = false
        progressTask?.cancel()
        progressTask = nil
        let microphoneStopStarted = ContinuousClock.now
        #if DEBUG
        debugFixtureTask?.cancel()
        debugFixtureTask = nil
        #endif
        inputTapNode?.removeTap(onBus: 0)
        inputTapNode = nil
        engine?.stop()
        engine = nil
        let microphoneStopDuration = microphoneStopStarted.duration(to: .now)
        lastMicrophoneStopMilliseconds = Double(microphoneStopDuration.components.seconds) * 1_000
            + Double(microphoneStopDuration.components.attoseconds) / 1e15
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        defer {
            let progress = writer.progress
            elapsed = Double(progress.frames) / max(sampleRate, 1)
            if let firstHostTime = progress.firstHostTime { hostTime = firstHostTime }
            #if DEBUG
            if let configuration = debugFixtureConfiguration {
                debugFixtureCursor = debugFixtureIntervalStart + progress.frames
                debugAudioSourceStatus = "File validation · " + configuration.audio.lastPathComponent
                    + " · " + String(format: "%.2f", Double(debugFixtureCursor) / sampleRate) + " s"
                    + (debugFixtureExhausted ? " · Source exhausted; finish recording" : " · Paused")
                configuration.log("pause", fields: ["sourceStartFrame": debugFixtureIntervalStart,
                    "sourceEndFrame": debugFixtureCursor, "acceptedFrames": progress.frames,
                    "sourceLength": debugFixtureLength, "captureDirectory": debugFixtureDirectory?.path ?? ""])
            }
            #endif
        }
        do { try await writer.finish() }
        catch { completion = .failure(error); throw error }
    }

    #if DEBUG
    /// A paced file adapter replaces the hardware input only. Writer, live preview,
    /// WorkspaceModel transitions, inference, persistence and delivery stay unchanged.
    private func startDebugFixture(
        configuration: DebugAudioValidationConfiguration, directory: URL, startTime: Double,
        intervalID: UUID, enableLivePreview: Bool,
        onCommit: @escaping @Sendable (AudioSegment) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws -> CaptureInterval {
        try configuration.validateCaptureDirectory(directory)
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        if debugFixtureDirectory != resolvedDirectory || startTime == 0 {
            debugFixtureCursor = 0
            debugFixtureDirectory = resolvedDirectory
        }
        let file = try AVAudioFile(forReading: configuration.audio)
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1,
              file.length > 0, file.length <= 16_000 * 300,
              debugFixtureCursor < file.length else {
            throw KeystormError.message("The validation source must be mono 16 kHz, at most five minutes, and have remaining audio.")
        }
        let token = UUID()
        generation = token
        failureHandler = onFailure
        let writer = try SegmentedAudioWriter(directory: directory, format: format,
            intervalID: intervalID, startTime: startTime, onCommit: onCommit,
            onFailure: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    await self.interrupt(message)
                }
            })
        let liveBuffer = enableLivePreview ? LiveAudioBuffer(format: format, intervalID: intervalID) : nil
        let engine = AVAudioEngine()
        let source = AVAudioPlayerNode()
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        let frameCapacity: AVAudioFrameCount = 1_600
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frameCapacity)
        source.scheduleSegment(file, startingFrame: debugFixtureCursor,
            frameCount: AVAudioFrameCount(file.length - debugFixtureCursor), at: nil, completionHandler: nil)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw KeystormError.message("The file validation render buffer could not be created.")
        }
        self.writer = writer
        self.liveBuffer = liveBuffer
        self.engine = engine
        debugFixtureConfiguration = configuration
        debugFixtureIntervalStart = debugFixtureCursor
        debugFixtureLength = file.length
        debugFixtureExhausted = false
        sampleRate = format.sampleRate
        channelCount = Int(format.channelCount)
        elapsed = 0
        hostTime = mach_absolute_time()
        let intervalHostTime = hostTime
        let sourceStart = debugFixtureCursor
        let sourceLength = file.length
        do {
            engine.prepare()
            try engine.start()
            try source.playAudio(at: nil)
            isRecording = true
            debugAudioSourceStatus = "File validation · " + configuration.audio.lastPathComponent + " · Recording"
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "Validating isolated file audio capture")
            configuration.log("start", fields: ["intervalID": intervalID.uuidString,
                "sourceStartFrame": sourceStart, "sourceLength": sourceLength,
                "captureStartTime": startTime, "captureDirectory": resolvedDirectory.path,
                "mode": "wall-clock-paced-offline-engine"])
            debugFixtureTask = Task { @MainActor [weak self, writer, liveBuffer, engine, source, file] in
                // Retain the player and file until pause cancels this task.
                _ = source
                _ = file
                var rendered: Int64 = 0
                var deadline = ContinuousClock.now
                do {
                    while !Task.isCancelled, rendered < sourceLength - sourceStart {
                        let count = AVAudioFrameCount(min(Int64(frameCapacity), sourceLength - sourceStart - rendered))
                        deadline = max(deadline, .now).advanced(by: .seconds(Double(count) / format.sampleRate))
                        try await Task.sleep(until: deadline, clock: .continuous)
                        guard let self, self.generation == token, self.isRecording, !Task.isCancelled else { return }
                        let status = try engine.renderOffline(count, to: buffer)
                        guard status == .success, buffer.frameLength == count else {
                            throw KeystormError.message("The validation engine did not render the complete requested source buffer.")
                        }
                        let immutable = AVReadOnlyAudioPCMBuffer(copying: buffer)
                        let timestamp = CaptureTimestamp(sampleTime: rendered,
                            hostTime: intervalHostTime + AVAudioTime.hostTime(forSeconds: Double(rendered) / format.sampleRate))
                        let before = writer.progress.frames
                        writer.enqueue(immutable, timestamp: timestamp)
                        guard writer.progress.frames - before == Int64(count) else {
                            throw KeystormError.message("The validation writer did not accept the complete rendered buffer.")
                        }
                        liveBuffer?.enqueue(immutable, timestamp: timestamp)
                        rendered += Int64(count)
                        self.elapsed = Double(writer.progress.frames) / format.sampleRate
                        self.debugAudioSourceStatus = "File validation · " + configuration.audio.lastPathComponent
                            + " · " + String(format: "%.2f", Double(sourceStart + rendered) / format.sampleRate) + " s"
                    }
                    guard let self, self.generation == token, self.isRecording, !Task.isCancelled else { return }
                    self.debugFixtureExhausted = true
                    self.debugAudioSourceStatus = "File validation · " + configuration.audio.lastPathComponent
                        + " · Source exhausted; finish recording"
                    configuration.log("source-exhausted", fields: ["intervalID": intervalID.uuidString,
                        "sourceStartFrame": sourceStart, "sourceEndFrame": sourceStart + rendered,
                        "acceptedFrames": writer.progress.frames])
                    // No automatic finish, new interval, zeros, microphone fallback or transcript injection.
                } catch is CancellationError { }
                catch {
                    guard let self, self.generation == token, self.isRecording else { return }
                    await self.interrupt(error.localizedDescription)
                }
            }
            return CaptureInterval(id: intervalID, hostTime: hostTime,
                sampleRate: sampleRate, channelCount: channelCount)
        } catch {
            engine.stop()
            liveBuffer?.close()
            self.liveBuffer = nil
            try? await writer.finish()
            self.writer = nil
            self.engine = nil
            failureHandler = nil
            throw error
        }
    }
    #endif

    func liveWindow(after sequence: Int64) async -> LiveAudioWindow? {
        guard isRecording, let liveBuffer else { return nil }
        let token = generation
        let window = await liveBuffer.snapshot(after: sequence)
        guard isRecording, generation == token, self.liveBuffer === liveBuffer else { return nil }
        return window
    }

    private func interrupt(_ message: String) async {
        guard isRecording || writer != nil else { return }
        let handler = failureHandler
        failureHandler = nil
        do {
            try await pause()
            handler?(message)
        } catch {
            handler?(error.localizedDescription == message ? message : "\(message) \(error.localizedDescription)")
        }
    }

    private func observeInterruptions(engine: AVAudioEngine, token: UUID) {
        let center = NotificationCenter.default
        let configuration = center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Engine teardown is asynchronous, outside AVAudioEngine's internal callback.
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                await self.interrupt("The microphone configuration changed. Recording paused; inspect the gap and resume explicitly.")
            }
        }
        observers.append((center, configuration))
        let workspace = NSWorkspace.shared.notificationCenter
        let sleep = workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                await self.interrupt("The Mac is going to sleep. Recording paused; resume explicitly after waking.")
            }
        }
        observers.append((workspace, sleep))
    }
}

struct CaptureTimestamp: Sendable {
    var sampleTime: Int64?
    var hostTime: UInt64?

    init(_ time: AVAudioTime) {
        sampleTime = time.isSampleTimeValid ? time.sampleTime : nil
        hostTime = time.isHostTimeValid ? time.hostTime : nil
    }

    init(sampleTime: Int64, hostTime: UInt64) {
        self.sampleTime = sampleTime
        self.hostTime = hostTime
    }
}

/// All AVAudioFile state belongs exclusively to queue. The lock only protects
/// bounded admission and counters; no file I/O occurs while holding it.
final class SegmentedAudioWriter: @unchecked Sendable {
    struct Progress: Sendable {
        var frames: Int64 = 0
        var firstHostTime: UInt64?
        var lastArrivalUptime: Double?
        var startedUptime = ProcessInfo.processInfo.systemUptime
    }

    private struct Admission {
        var accepting = true
        var pendingFrames: Int64 = 0
        var expectedSampleTime: Int64?
        var expectedHostSeconds: Double?
        var failure: String?
        var progress = Progress()
    }

    private let queue = DispatchQueue(label: "Keystorm.audio-writer", qos: .userInitiated)
    private let admission = OSAllocatedUnfairLock(initialState: Admission())
    private let directory: URL
    private let format: AVAudioFormat
    private let intervalID: UUID
    private let startTime: Double
    private let targetFrames: Int64
    private let maximumBufferedFrames: Int64
    private let onCommit: @Sendable (AudioSegment) -> Void
    private let onFailure: @Sendable (String) -> Void
    // Queue-confined state.
    private var file: AVAudioFile?
    private var segmentID: UUID?
    private var segmentFrames: Int64 = 0
    private var completedFrames: Int64 = 0
    private var writeFailure: String?

    var progress: Progress { admission.withLock { $0.progress } }

    init(
        directory: URL, format: AVAudioFormat, intervalID: UUID, startTime: Double,
        segmentSeconds: Double = 5, maximumBufferedSeconds: Double = 10,
        onCommit: @escaping @Sendable (AudioSegment) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              startTime.isFinite, startTime >= 0,
              segmentSeconds > 0, maximumBufferedSeconds > 0 else {
            throw KeystormError.message("Invalid recording format or segment configuration.")
        }
        self.directory = directory
        self.format = format
        self.intervalID = intervalID
        self.startTime = startTime
        targetFrames = max(1, Int64(format.sampleRate * segmentSeconds))
        maximumBufferedFrames = max(1, Int64(format.sampleRate * maximumBufferedSeconds))
        self.onCommit = onCommit
        self.onFailure = onFailure
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func enqueue(_ buffer: AVReadOnlyAudioPCMBuffer, timestamp: CaptureTimestamp) {
        let reportedFailure: String? = admission.withLock { state in
            guard state.accepting else { return nil }
            let frames = Int64(buffer.frameLength)
            guard frames > 0 else { return nil }
            let failure: String?
            if !buffer.format.isEqual(format) {
                failure = "The microphone format changed mid-recording. Recording stopped to preserve an explicit discontinuity."
            } else if timestamp.sampleTime == nil || timestamp.hostTime == nil {
                failure = "The microphone supplied audio without a usable monotonic timestamp. Recording stopped."
            } else if let expected = state.expectedSampleTime, timestamp.sampleTime != expected {
                failure = "A microphone sample gap or overlap was detected. Recording stopped; the missing interval requires review."
            } else if let expected = state.expectedHostSeconds,
                      let actual = timestamp.hostTime,
                      abs(AVAudioTime.seconds(forHostTime: actual) - expected) > 0.05 {
                failure = "A microphone clock discontinuity was detected. Recording stopped."
            } else if frames > maximumBufferedFrames - state.pendingFrames {
                failure = "The audio writer could not keep up. Recording stopped before silently dropping queued audio."
            } else {
                failure = nil
            }
            if let failure {
                state.accepting = false
                state.failure = failure
                return failure
            }
            state.pendingFrames += frames
            state.expectedSampleTime = timestamp.sampleTime.map { $0 + frames }
            state.expectedHostSeconds = timestamp.hostTime.map {
                AVAudioTime.seconds(forHostTime: $0) + Double(frames) / format.sampleRate
            }
            state.progress.frames += frames
            if state.progress.firstHostTime == nil { state.progress.firstHostTime = timestamp.hostTime }
            state.progress.lastArrivalUptime = ProcessInfo.processInfo.systemUptime
            // Enqueue under the admission lock so finish is ordered after every accepted buffer.
            queue.async { [self, buffer] in
                autoreleasepool {
                    defer { admission.withLock { $0.pendingFrames -= frames } }
                    guard writeFailure == nil else { return }
                    do {
                        try append(buffer)
                    } catch {
                        let message = "Audio could not be saved: \(error.localizedDescription)"
                        writeFailure = message
                        let report = admission.withLock { state in
                            state.accepting = false
                            let report = state.failure == nil
                            state.failure = state.failure ?? message
                            return report
                        }
                        if report { onFailure(message) }
                    }
                }
            }
            return nil
        }
        if let reportedFailure { onFailure(reportedFailure) }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            admission.withLock { state in
                state.accepting = false
                queue.async { [self] in
                    do {
                        if let writeFailure {
                            file?.close()
                            file = nil
                            throw KeystormError.message(writeFailure)
                        }
                        try commitCurrent()
                        if let failure = admission.withLock({ $0.failure }) {
                            throw KeystormError.message(failure)
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func append(_ buffer: AVReadOnlyAudioPCMBuffer) throws {
        if file == nil {
            let id = UUID()
            segmentID = id
            let url = directory.appendingPathComponent("\(id.uuidString).partial.caf")
            file = try AVAudioFile(
                forWriting: url, settings: format.settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved
            )
        }
        guard let file else { throw KeystormError.message("The audio segment could not be opened.") }
        try file.write(from: buffer)
        segmentFrames += Int64(buffer.frameLength)
        if segmentFrames >= targetFrames { try commitCurrent() }
    }

    private func commitCurrent() throws {
        guard let id = segmentID, let file, segmentFrames > 0 else { return }
        file.close()
        self.file = nil
        let temporary = directory.appendingPathComponent("\(id.uuidString).partial.caf")
        let final = directory.appendingPathComponent("\(id.uuidString).caf")
        try CaptureDurability.synchronize(temporary)
        let hash = try CaptureDurability.sha256(temporary)
        try FileManager.default.moveItem(at: temporary, to: final)
        let segment = AudioSegment(
            id: id, intervalID: intervalID, fileName: final.lastPathComponent,
            startTime: startTime + Double(completedFrames) / format.sampleRate,
            frameCount: segmentFrames, sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount), sha256: hash
        )
        let sidecarTemporary = directory.appendingPathComponent("\(id.uuidString).json.tmp")
        let sidecar = directory.appendingPathComponent("\(id.uuidString).json")
        try JSONEncoder().encode(segment).write(to: sidecarTemporary, options: .withoutOverwriting)
        try CaptureDurability.synchronize(sidecarTemporary)
        try FileManager.default.moveItem(at: sidecarTemporary, to: sidecar)
        try CaptureDurability.synchronizeDirectory(directory)
        completedFrames += segmentFrames
        segmentFrames = 0
        segmentID = nil
        // Notification is an acknowledgment only after audio and sidecar are durable.
        onCommit(segment)
    }
}

enum CaptureDurability {
    static func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw KeystormError.message("Could not open the audio directory for synchronization (errno \(errno)).")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw KeystormError.message("Could not synchronize the audio directory (errno \(errno)).")
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 256 * 1024), !bytes.isEmpty {
            digest.update(data: bytes)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
