import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import Keystorm

/// Explicitly paced production capture, live ASR and durable storage. No microphone,
/// global workspace, external destination or clipboard is opened by these tests.
/// The 90-minute case is separately gated and must actually elapse; a timeout or
/// interrupted heartbeat is never a successful run.
@MainActor
@Suite(.serialized, .exclusiveBenchmarkUse)
struct CaptureEnduranceTests {
    @Test("A short real-time capture validates the endurance harness",
          .enabled(if: CaptureEnduranceSettings.shortEnabled), .timeLimit(.minutes(3)))
    func realTimeCaptureSmoke() async throws {
        try await record(seconds: 12)
    }

    @Test("Ninety minutes of real paced source audio survives capture, transcription and reopening",
          .enabled(if: CaptureEnduranceSettings.longEnabled), .timeLimit(.minutes(120)))
    func ninetyMinuteRealTimeCapture() async throws {
        try await record(seconds: 5_400)
    }

    @Test("Injected route and sleep events durably pause and resume one take on fresh formats",
          .enabled(if: CaptureEnduranceSettings.shortEnabled), .timeLimit(.minutes(3)))
    func routeAndSleepEventsPreserveDurableTake() async throws {
        let run = try CaptureEnduranceRun(kind: "injected-route-and-sleep", requestedSeconds: 8)
        var report = run.report
        let rates: [Double] = [16_000, 48_000, 48_000, 16_000]
        var sources: [EnduranceReplaySource] = []
        for rate in rates {
            let angularStep = 2.0 * Double.pi * 220.0 / rate
            let samples: [Float] = (0..<Int(rate)).map { index in
                Float(sin(Double(index) * angularStep) * 0.08)
            }
            sources.append(try EnduranceReplaySource(samples: samples, sampleRate: rate))
        }
        let queue = EnduranceSourceQueue(sources)
        var model: WorkspaceModel? = WorkspaceModel(root: run.storeURL, modelDirectory: run.modelsURL,
            capture: AudioCapture(sourceFactory: { queue.next() }, allowsDebugFixture: false))
        var handle: DictationRecordingHandle?
        do {
            let workspace = try #require(model)
            try await prepare(workspace, report: &report, run: run)
            let recording = try await workspace.dictationBegin()
            handle = recording
            for index in sources.indices {
                if index > 0 { try await workspace.dictationResume(recording) }
                try #require(workspace.isRecording && workspace.openTake?.id == recording.takeID)
                try await sources[index].feed(seconds: 2)
                if index < 3 {
                    let event: CaptureSourceEvent = index == 1 ? .willSleep : .configurationChanged
                    sources[index].emit(event)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                    while (workspace.isRecording || workspace.isCaptureTransitioning
                           || workspace.dictationMetadata(recording)?.state != .paused),
                          ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    try #require(!workspace.isRecording && !workspace.isCaptureTransitioning)
                    guard case .suspended(let message) = workspace.dictationCaptureStatus(recording) else {
                        throw KeystormError.message("The injected event did not reach the production suspended state.")
                    }
                    try #require(message == (event == .willSleep
                        ? CaptureInterruption.systemSleep.message : CaptureInterruption.routeChanged.message))
                    let store = try #require(workspace.store)
                    let durable = try #require(try await store.loadSession(recording.sessionID))
                    try #require(durable.status == .paused && durable.intervals.allSatisfy { $0.endedAt != nil })
                    try #require(durable.dictation?.recordings.first { $0.id == recording.takeID }?.state == .paused)
                    report.events.append("injected-\(event == .willSleep ? "willSleep" : "configurationChanged")-after-interval-\(index + 1)")
                } else {
                    try await workspace.dictationPause(recording)
                }
            }
            try #require(queue.createdCount == 4, "Each resume must open a fresh source.")
            let pausedSnapshot = try #require(workspace.sessions.first { $0.id == recording.sessionID })
            try #require(pausedSnapshot.gaps.isEmpty, "These lossless interruptions must not invent missing audio.")
            report.sourceFrames = sources.reduce(0) { $0 + $1.deliveredFrames }
            report.activeAudioSeconds = 8
            try await verifyAudio(workspace, handle: recording, sources: sources, report: &report)
            await workspace.stopForTermination()
            let durableSnapshot = try #require(workspace.sessions.first { $0.id == recording.sessionID })
            model = nil
            try await verifyReopen(run: run, handle: recording, expected: durableSnapshot, report: &report)
            report.completed = true
        } catch {
            report.failures.append(error.localizedDescription)
        }
        await model?.stopForTermination()
        model = nil
        report.phase = "finished"
        report.passed = report.completed && report.failures.isEmpty
        report.sessionID = handle?.sessionID
        report.takeID = handle?.takeID
        try run.persist(report)
        Attachment.record(try run.encoded(report), named: "capture-route-sleep.json")
        try #require(report.passed, "\(report.failures.joined(separator: "; "))")
    }

    private func record(seconds: Int) async throws {
        let run = try CaptureEnduranceRun(kind: "real-time-replay", requestedSeconds: seconds)
        var report = run.report
        var model: WorkspaceModel?
        var feeding: Task<Void, any Error>?
        let allStarted = ContinuousClock.now
        do {
            let source: EnduranceReplaySource
            if let manifestPath = ProcessInfo.processInfo.environment["KEYSTORM_CAPTURE_ENDURANCE_FIXTURE_MANIFEST"] {
                let manifestURL = URL(fileURLWithPath: manifestPath)
                let manifest = try JSONDecoder().decode(EnduranceFixtureManifest.self, from: Data(contentsOf: manifestURL))
                let audio = URL(fileURLWithPath: manifest.audioPath)
                guard !manifest.attribution.isEmpty, !manifest.sourceURL.isEmpty, !manifest.license.isEmpty,
                      ["human-read", "synthetic"].contains(manifest.kind),
                      try CaptureDurability.sha256(audio) == manifest.sha256.lowercased() else {
                    throw KeystormError.message("The explicit replay fixture needs matching audio hash and complete provenance.")
                }
                source = try EnduranceReplaySource(audio: audio)
                report.fixture = manifest
            } else {
                let fixture = try await FinishLatencyHarness.synthesizeFixture(in: run.directory)
                source = try EnduranceReplaySource(audio: fixture.url)
                report.fixture = EnduranceFixtureManifest(audioPath: fixture.url.path,
                    sha256: try CaptureDurability.sha256(fixture.url), kind: "synthetic",
                    attribution: "Locally synthesized Apple Samantha voice; FinishLatencyHarness fixture",
                    sourceURL: "local-generated-fixture", license: "local benchmark fixture")
            }
            report.fixturePatternFrames = source.patternFrames
            report.fixtureSampleRate = source.sampleRate
            report.fixtureRepetitionCount = Double(seconds) * source.sampleRate / Double(source.patternFrames)
            let workspace = WorkspaceModel(root: run.storeURL, modelDirectory: run.modelsURL,
                capture: AudioCapture(sourceFactory: { source }, allowsDebugFixture: false))
            model = workspace
            try await prepare(workspace, report: &report, run: run)
            let recording = try await workspace.dictationBegin()
            report.sessionID = recording.sessionID
            report.takeID = recording.takeID
            try #require(workspace.isRecording && workspace.openTake?.id == recording.takeID)
            report.phase = "recording"
            try run.persist(report)
            let recordingStarted = ContinuousClock.now
            let awakeStarted = ProcessInfo.processInfo.systemUptime
            feeding = Task { try await source.feed(seconds: Double(seconds)) }
            var nextObservation = ContinuousClock.now
            while !source.feedFinished {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                if source.feedFinished { break }
                guard ContinuousClock.now >= nextObservation else { continue }
                nextObservation = ContinuousClock.now.advanced(by: .seconds(10))
                guard workspace.isRecording, workspace.error == nil else {
                    throw KeystormError.message(workspace.error ?? "Capture stopped before its requested real-time duration.")
                }
                let snapshot = try #require(workspace.sessions.first { $0.id == recording.sessionID })
                let resources = await workspace.runtimeResourceSnapshot()
                let sample = EnduranceObservation(elapsedSeconds: enduranceSeconds(recordingStarted),
                    awakeSeconds: ProcessInfo.processInfo.systemUptime - awakeStarted,
                    deliveredFrames: source.deliveredFrames,
                    committedFrames: snapshot.segments.reduce(0) { $0 + $1.frameCount },
                    committedSegments: snapshot.segments.count, transcripts: snapshot.transcripts.count,
                    failedJobs: snapshot.jobs.filter { $0.status == .failed || $0.status == .incomplete }.count,
                    transcriptEndSeconds: snapshot.transcripts.map(\.endTime).max() ?? 0,
                    resources: resources, thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                    lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
                report.observations.append(sample)
                report.recordingWallSeconds = sample.elapsedSeconds
                report.recordingAwakeSeconds = sample.awakeSeconds
                report.sourceFrames = source.deliveredFrames
                try run.persist(report)
                print("CAPTURE_ENDURANCE_HEARTBEAT \(run.reportURL.path) elapsed=\(sample.elapsedSeconds) frames=\(sample.deliveredFrames)")
                guard resources["processFootprint", default: 0] > 0,
                      resources["processFootprint", default: 0] <= 6 * 1_024 * 1_024 * 1_024 else {
                    throw KeystormError.message("Resource evidence is missing or combined footprint exceeds the 6 GiB hard limit.")
                }
            }
            try await feeding?.value
            feeding = nil
            report.recordingWallSeconds = source.feedWallSeconds
            report.recordingAwakeSeconds = source.feedAwakeSeconds
            report.maximumSchedulingDelaySeconds = source.maximumSchedulingDelaySeconds
            report.sourceFrames = source.deliveredFrames
            report.activeAudioSeconds = Double(source.deliveredFrames) / source.sampleRate
            try #require(source.deliveredFrames == Int64(seconds) * Int64(source.sampleRate))
            try #require(source.feedWallSeconds >= Double(seconds) - 0.05)
            try #require(source.feedAwakeSeconds >= Double(seconds) - 0.05,
                "Sleep or scaled clock time cannot substitute for actual awake recording time.")
            report.phase = "draining-and-finishing"
            try run.persist(report)
            let finishStarted = ContinuousClock.now
            try await workspace.dictationPause(recording)
            let revision = try await workspace.dictationComplete(recording)
            report.finishMilliseconds = enduranceSeconds(finishStarted) * 1_000
            report.transcriptUTF8Bytes = revision.text.utf8.count
            try #require(!revision.text.isEmpty, "Actual local transcription must complete; no text is injected.")
            try await verifyAudio(workspace, handle: recording, sources: [source], report: &report)
            let snapshot = try #require(workspace.sessions.first { $0.id == recording.sessionID })
            let take = try #require(snapshot.brief?.takes.first { $0.id == recording.takeID })
            let sourceIDs = Set(snapshot.takeSegments(take).map(\.id))
            let completeIDs = Set(snapshot.currentTranscripts.filter(\.isComplete).flatMap(\.segmentIDs))
            let coverage = WorkspaceModel.recordingHUDCoverage(for: take, in: snapshot)
            report.finalUntranscribedSourceCount = sourceIDs.subtracting(completeIDs).count
            report.finalTranscribedSeconds = coverage.transcribed
            var latestJobs: [UUID: JobStatus] = [:]
            for job in snapshot.jobs where job.stage == .transcription {
                for id in job.inputIDs where sourceIDs.contains(id) { latestJobs[id] = job.status }
            }
            report.finalUnfinishedSourceJobCount = sourceIDs.filter { latestJobs[$0] != .completed }.count
            try #require(report.finalUntranscribedSourceCount == 0
                && report.finalUnfinishedSourceJobCount == 0)
            try #require(abs(coverage.saved - Double(seconds)) < 0.000_01
                && abs(coverage.transcribed - Double(seconds)) < 0.000_01,
                "Every saved source must have completed current transcription; partial nonempty text is insufficient.")
            report.phase = "reopening"
            try run.persist(report)
            await workspace.stopForTermination()
            model = nil
            try await verifyReopen(run: run, handle: recording, expected: snapshot, report: &report)
            try #require(AppLifecycle.bootstrap?.isReady != true)
            report.completed = true
        } catch {
            report.failures.append(error.localizedDescription)
        }
        feeding?.cancel()
        _ = await feeding?.result
        await model?.stopForTermination()
        model = nil
        report.elapsedSecondsIncludingSetup = enduranceSeconds(allStarted)
        report.phase = "finished"
        report.passed = report.completed && report.failures.isEmpty
        try run.persist(report)
        Attachment.record(try run.encoded(report), named: "capture-endurance-\(seconds)-seconds.json")
        print("CAPTURE_ENDURANCE_RESULT \(run.reportURL.path) passed=\(report.passed) awake_seconds=\(report.recordingAwakeSeconds)")
        try #require(report.passed, "\(report.failures.joined(separator: "; "))")
    }

    private func prepare(_ workspace: WorkspaceModel, report: inout EnduranceReport,
                         run: CaptureEnduranceRun) async throws {
        try #require(FinishLatencyHarness.buildConfiguration == "Release")
        try #require(AppLifecycle.bootstrap?.isReady != true)
        let identity = try BenchmarkArtifactIdentity.capture()
        report.artifactIdentity = identity
        report.buildInstrumentation = try BenchmarkBuildInstrumentation.capture(identity: identity)
        try #require(report.buildInstrumentation?.llvmProfileInstrumented == false)
        try run.persist(report)
        await workspace.initialize(loadLibrary: true)
        try #require(workspace.error == nil, "\(workspace.error ?? "")")
        try #require(workspace.installedModelIDs.contains(ModelCatalog.primarySpeech.id),
            "The pinned local speech model must already be installed. Nothing is downloaded.")
    }

    private func verifyAudio(_ workspace: WorkspaceModel, handle: DictationRecordingHandle,
                             sources: [EnduranceReplaySource], report: inout EnduranceReport) async throws {
        let snapshot = try #require(workspace.sessions.first { $0.id == handle.sessionID })
        let take = try #require(snapshot.brief?.takes.first { $0.id == handle.takeID })
        let intervals = take.captureIntervalIDs
        let segments = snapshot.takeSegments(take).sorted { $0.startTime < $1.startTime }
        let store = try #require(workspace.store)
        try #require(intervals.count == sources.count && Set(intervals).count == intervals.count)
        try #require(Set(segments.map(\.id)).count == segments.count)
        try #require(snapshot.intervals.filter { intervals.contains($0.id) }.allSatisfy { $0.endedAt != nil })
        var total: Int64 = 0
        var end = 0.0
        for (intervalID, source) in zip(intervals, sources) {
            var hasher = SHA256()
            var frames: Int64 = 0
            let audio = segments.filter { $0.intervalID == intervalID }
            try #require(!audio.isEmpty)
            for segment in audio {
                try #require(abs(segment.startTime - end) < 0.000_01)
                try #require(segment.sampleRate == source.sampleRate && segment.channelCount == 1)
                let url = try await store.audioURL(for: segment, in: snapshot.id)
                try #require(try CaptureDurability.sha256(url) == segment.sha256)
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                try #require(file.length == segment.frameCount)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
                while file.framePosition < file.length {
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(min(16_000, file.length - file.framePosition)))
                    let channel = try #require(buffer.floatChannelData?[0])
                    hasher.update(data: Data(bytes: channel, count: Int(buffer.frameLength) * MemoryLayout<Float>.size))
                    frames += Int64(buffer.frameLength)
                }
                end = segment.endTime
            }
            try #require(frames == source.deliveredFrames)
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            try #require(digest == source.pcmSHA256, "Saved samples must match every delivered Float32 sample in order.")
            total += frames
        }
        report.savedFrames = total
        report.savedSegments = segments.count
        report.intervalCount = intervals.count
        report.allPCMHashesMatched = true
        try #require(total == sources.reduce(0) { $0 + $1.deliveredFrames })
    }

    private func verifyReopen(run: CaptureEnduranceRun, handle: DictationRecordingHandle,
                              expected: VoiceSession, report: inout EnduranceReport) async throws {
        let store = try SessionStore(root: run.storeURL)
        let recovered = try #require(try await store.loadSession(handle.sessionID))
        try #require(recovered.segments == expected.segments)
        try #require(recovered.intervals == expected.intervals)
        try #require(recovered.transcripts == expected.transcripts)
        try #require(recovered.brief?.takes.first { $0.id == handle.takeID }
            == expected.brief?.takes.first { $0.id == handle.takeID })
        try #require(recovered.dictation == expected.dictation)
        report.reopenedExactly = true
    }
}

nonisolated private enum CaptureEnduranceSettings {
    static var shortEnabled: Bool {
        ProcessInfo.processInfo.environment["KEYSTORM_RUN_CAPTURE_SMOKE"] == "1"
    }
    static var longEnabled: Bool {
        ProcessInfo.processInfo.environment["KEYSTORM_RUN_CAPTURE_ENDURANCE"] == "1"
    }
}

@MainActor
private final class EnduranceSourceQueue {
    private let sources: [EnduranceReplaySource]
    private(set) var createdCount = 0
    init(_ sources: [EnduranceReplaySource]) { self.sources = sources }
    func next() -> EnduranceReplaySource {
        precondition(createdCount < sources.count)
        defer { createdCount += 1 }
        return sources[createdCount]
    }
}

/// Only this source is synthetic/replayed. Admission, watchdogs, live preview,
/// ASR, writer, commit queue, journal and reopening use production implementations.
@MainActor
private final class EnduranceReplaySource: CaptureSource {
    let sampleRate: Double
    var patternFrames: Int { samples.count }
    private let format: AVAudioFormat
    private let samples: [Float]
    private var deliver: (@Sendable (AVReadOnlyAudioPCMBuffer, CaptureTimestamp) -> Void)?
    private var onEvent: (@Sendable (CaptureSourceEvent) -> Void)?
    private var hasher = SHA256()
    private(set) var deliveredFrames: Int64 = 0
    private(set) var feedFinished = false
    private(set) var feedWallSeconds = 0.0
    private(set) var feedAwakeSeconds = 0.0
    private(set) var maximumSchedulingDelaySeconds = 0.0
    var pcmSHA256: String {
        let copy = hasher
        return copy.finalize().map { String(format: "%02x", $0) }.joined()
    }

    convenience init(audio: URL) throws {
        let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.channelCount == 1, file.processingFormat.sampleRate == 16_000,
              file.length > 0, file.length <= 16_000 * 600 else {
            throw KeystormError.message("Replay audio must be mono16kHz and at most10minutes; longer elapsed runs repeat it explicitly.")
        }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        try #require(Int64(buffer.frameLength) == file.length)
        let channel = try #require(buffer.floatChannelData?[0])
        try self.init(samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), sampleRate: 16_000)
    }

    init(samples: [Float], sampleRate: Double) throws {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite),
              sampleRate == 16_000 || sampleRate == 48_000,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw KeystormError.message("Invalid endurance source samples.")
        }
        self.samples = samples
        self.sampleRate = sampleRate
        self.format = format
    }

    func requestAccess() async -> Bool { true }
    func open() async throws -> AVAudioFormat { format }
    func start(deliver: @escaping @Sendable (AVReadOnlyAudioPCMBuffer, CaptureTimestamp) -> Void,
               onEvent: @escaping @Sendable (CaptureSourceEvent) -> Void) throws {
        guard self.deliver == nil else { throw KeystormError.message("The replay source is already open.") }
        self.deliver = deliver
        self.onEvent = onEvent
    }
    func stop() { deliver = nil; onEvent = nil }
    func emit(_ event: CaptureSourceEvent) { onEvent?(event) }

    func feed(seconds: Double) async throws {
        let began = ContinuousClock.now
        let awake = ProcessInfo.processInfo.systemUptime
        defer {
            feedWallSeconds = enduranceSeconds(began)
            feedAwakeSeconds = ProcessInfo.processInfo.systemUptime - awake
            feedFinished = true
        }
        guard deliveredFrames == 0 else { throw KeystormError.message("Each endurance source interval is used once.") }
        let frames = Int64((seconds * sampleRate).rounded())
        let capacity = AVAudioFrameCount(sampleRate / 10)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        let channel = try #require(buffer.floatChannelData?[0])
        let host = mach_absolute_time()
        while deliveredFrames < frames {
            try Task.checkCancellation()
            let count = Int(min(Int64(capacity), frames - deliveredFrames))
            let due = began.advanced(by: .seconds(Double(deliveredFrames + Int64(count)) / sampleRate))
            try await Task.sleep(until: due, clock: .continuous)
            let delay = max(0, enduranceSeconds(due))
            maximumSchedulingDelaySeconds = max(maximumSchedulingDelaySeconds, delay)
            guard delay < 1, let deliver else {
                throw KeystormError.message("Replay stopped or fell over1second behind real time; accelerated catch-up is forbidden.")
            }
            for index in 0..<count { channel[index] = samples[(Int(deliveredFrames) + index) % samples.count] }
            buffer.frameLength = AVAudioFrameCount(count)
            hasher.update(data: Data(bytes: channel, count: count * MemoryLayout<Float>.size))
            deliver(AVReadOnlyAudioPCMBuffer(copying: buffer),
                CaptureTimestamp(sampleTime: deliveredFrames,
                    hostTime: host + AVAudioTime.hostTime(forSeconds: Double(deliveredFrames) / sampleRate)))
            deliveredFrames += Int64(count)
        }
    }
}

nonisolated private struct EnduranceFixtureManifest: Codable {
    let audioPath: String
    let sha256: String
    let kind: String
    let attribution: String
    let sourceURL: String
    let license: String
}

nonisolated private struct EnduranceObservation: Encodable {
    let elapsedSeconds: Double
    let awakeSeconds: Double
    let deliveredFrames: Int64
    let committedFrames: Int64
    let committedSegments: Int
    let transcripts: Int
    let failedJobs: Int
    let transcriptEndSeconds: Double
    let resources: [String: UInt64]
    let thermalState: Int
    let lowPowerMode: Bool
}

nonisolated private struct EnduranceReport: Encodable {
    let schemaVersion = 1
    let runID: String
    let kind: String
    let generatedAt = Date()
    let processID = ProcessInfo.processInfo.processIdentifier
    let requestedRecordingSeconds: Int
    let buildConfiguration = FinishLatencyHarness.buildConfiguration
    let hardwareModel = RuntimePerformanceReport.hardwareModel
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let speechModelID = ModelCatalog.primarySpeech.id
    let speechModelRevision = ModelCatalog.primarySpeech.revision
    let scope = "Genuinely elapsed replay through production capture/liveASR/storage, never microphone capture. Repeated source is disclosed. Injected events are not physical route/sleep tests. No natural-speech accuracy score, battery drain qualification, actual app delivery, hotkey or HUD latency claim."
    let retainedStorePath: String
    var phase = "preparing"
    var artifactIdentity: BenchmarkArtifactIdentity?
    var buildInstrumentation: BenchmarkBuildInstrumentation?
    var fixture: EnduranceFixtureManifest?
    var fixturePatternFrames = 0
    var fixtureSampleRate = 0.0
    var fixtureRepetitionCount = 0.0
    var sessionID: UUID?
    var takeID: UUID?
    var sourceFrames: Int64 = 0
    var savedFrames: Int64 = 0
    var savedSegments = 0
    var intervalCount = 0
    var activeAudioSeconds = 0.0
    var recordingWallSeconds = 0.0
    var recordingAwakeSeconds = 0.0
    var elapsedSecondsIncludingSetup = 0.0
    var maximumSchedulingDelaySeconds = 0.0
    var finishMilliseconds = 0.0
    var transcriptUTF8Bytes = 0
    var finalUntranscribedSourceCount = -1
    var finalUnfinishedSourceJobCount = -1
    var finalTranscribedSeconds = 0.0
    var observations: [EnduranceObservation] = []
    var events: [String] = []
    var allPCMHashesMatched = false
    var reopenedExactly = false
    var failures: [String] = []
    var completed = false
    var passed = false
}

nonisolated private struct CaptureEnduranceRun {
    let directory: URL
    let storeURL: URL
    let modelsURL: URL
    let reportURL: URL
    let report: EnduranceReport

    init(kind: String, requestedSeconds: Int) throws {
        let runID = UUID().uuidString
        let parent = ProcessInfo.processInfo.environment["KEYSTORM_CAPTURE_ENDURANCE_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-CaptureEndurance", isDirectory: true)
        directory = parent.appendingPathComponent(runID, isDirectory: true)
        storeURL = directory.appendingPathComponent("Store", isDirectory: true)
        reportURL = directory.appendingPathComponent("report.json")
        modelsURL = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        report = EnduranceReport(runID: runID, kind: kind, requestedRecordingSeconds: requestedSeconds,
            retainedStorePath: storeURL.path)
        try persist(report)
        print("CAPTURE_ENDURANCE_REPORT \(reportURL.path)")
    }

    func encoded(_ value: EnduranceReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    func persist(_ value: EnduranceReport) throws {
        try encoded(value).write(to: reportURL, options: .atomic)
    }
}

nonisolated private func enduranceSeconds(_ began: ContinuousClock.Instant) -> Double {
    let duration = began.duration(to: .now).components
    return Double(duration.seconds) + Double(duration.attoseconds) / 1_000_000_000_000_000_000
}
