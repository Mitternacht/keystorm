import AppKit
import AVFoundation
import CoreAudio
import Foundation
import os
import Testing
@testable import Keystorm

/// Requires an explicitly coordinated physical action. These tests never inject a
/// source event, change a system audio setting, put the Mac to sleep, or wake it.
/// Existing mic permission is mandatory. At most40s of awake capture precedes
/// the action, followed by2s after explicit resume; private ambient audio is erased.
@MainActor
@Suite(.serialized, .exclusiveBenchmarkUse)
struct PhysicalCaptureRecoveryTests {
    @Test("A physical default-input change preserves a durable take and resumes microphone capture",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_PHYSICAL_CAPTURE_ROUTE"] == "1"),
          .timeLimit(.minutes(3)))
    func physicalInputChangePausesAndResumes() async throws {
        try await run(kind: .route)
    }

    @Test("Actual macOS sleep and wake preserve a durable paused take before explicit resume",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_PHYSICAL_CAPTURE_SLEEP"] == "1"),
          .timeLimit(.minutes(3)))
    func physicalSleepWakePausesAndResumes() async throws {
        try await run(kind: .sleep)
    }

    private func run(kind: PhysicalRecoveryKind) async throws {
        let runID = UUID().uuidString
        let parent = ProcessInfo.processInfo.environment["KEYSTORM_PHYSICAL_CAPTURE_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-PhysicalCaptureRecovery", isDirectory: true)
        let directory = parent.appendingPathComponent(runID, isDirectory: true)
        let storeURL = directory.appendingPathComponent("PrivateAmbientStore", isDirectory: true)
        let reportURL = directory.appendingPathComponent("report.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report = PhysicalRecoveryReport(runID: runID, kind: kind.rawValue)
        try persist(report, at: reportURL)
        // record() owns all store/model references. It drains/terminates them before
        // returning, so cleanup never unlinks SQLite while this scope owns a store.
        report = await record(kind: kind, storeURL: storeURL, reportURL: reportURL, report: report)
        do {
            if FileManager.default.fileExists(atPath: storeURL.path) {
                try FileManager.default.removeItem(at: storeURL)
            }
            report.privateAudioRemoved = !FileManager.default.fileExists(atPath: storeURL.path)
        } catch {
            report.failures.append("Private ambient fixture cleanup failed: " + error.localizedDescription)
        }
        report.passed = report.completed && report.failures.isEmpty && report.privateAudioRemoved
        report.phase = "finished"
        try persist(report, at: reportURL)
        Attachment.record(try encode(report), named: "physical-capture-\(kind.rawValue).json")
        print("PHYSICAL_CAPTURE_RESULT \(reportURL.path) passed=\(report.passed)")
        try #require(report.passed, "\(report.failures.joined(separator: "; "))")
    }

    private func record(kind: PhysicalRecoveryKind, storeURL: URL, reportURL: URL,
                        report original: PhysicalRecoveryReport) async -> PhysicalRecoveryReport {
        var report = original
        var workspace: WorkspaceModel?
        let notifications = PhysicalNotificationLog()
        let systemCenter = NSWorkspace.shared.notificationCenter
        let regularCenter = NotificationCenter.default
        let sleep = systemCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
            notifications.append("NSWorkspace.willSleep")
        }
        let wake = systemCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            notifications.append("NSWorkspace.didWake")
        }
        let route = regularCenter.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { _ in
            notifications.append("AVAudioEngine.configurationChange")
        }
        defer {
            systemCenter.removeObserver(sleep)
            systemCenter.removeObserver(wake)
            regularCenter.removeObserver(route)
        }
        do {
            try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                "This explicitly enabled test requires existing microphone permission; no prompt is requested.")
            try #require(FinishLatencyHarness.buildConfiguration == "Release")
            try #require(AppLifecycle.bootstrap?.isReady != true)
            let identity = try BenchmarkArtifactIdentity.capture()
            report.artifactIdentity = identity
            report.buildInstrumentation = try BenchmarkBuildInstrumentation.capture(identity: identity)
            try #require(report.buildInstrumentation?.llvmProfileInstrumented == false)
            let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models", isDirectory: true)
            // Retain only real sources so each running input AudioUnit can be observed directly.
            // AudioCapture still owns their lifecycle and creates a new source on explicit resume.
            var openedSources: [EngineCaptureSource] = []
            let capture = AudioCapture(sourceFactory: {
                let source = EngineCaptureSource()
                openedSources.append(source)
                return source
            }, allowsDebugFixture: false)
            let model = WorkspaceModel(root: storeURL, modelDirectory: models, capture: capture)
            workspace = model
            await model.initialize(loadLibrary: true)
            try #require(model.error == nil, "\(model.error ?? "")")
            try #require(model.installedModelIDs.contains(ModelCatalog.primarySpeech.id))
            report.inputBefore = try PhysicalInputDevice.current()
            let handle = try await model.dictationBegin()
            report.sessionID = handle.sessionID
            report.takeID = handle.takeID
            let captureStarted = ContinuousClock.now
            let awakeStarted = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(1))
            try #require(model.isRecording, "Capture must deliver an initial interval before the physical action.")
            try #require(openedSources.count == 1)
            let initialSource = try #require(openedSources.first)
            let initialDefault = try #require(report.inputBefore)
            report.actualInputDeviceBefore = try initialSource.currentInputDeviceID()
            try #require(report.actualInputDeviceBefore == initialDefault.audioObjectID,
                "The initial capture AudioUnit must use the expected default input.")
            try #require(try PhysicalInputDevice.current() == initialDefault,
                "The default input must remain stable while its actual capture binding is observed.")
            let initialCount = notifications.events.count
            report.phase = kind == .route ? "ready-for-physical-input-change" : "ready-for-system-sleep-and-wake"
            report.readyAt = Date()
            try persist(report, at: reportURL)
            print("PHYSICAL_CAPTURE_READY \(reportURL.path) action=\(kind.rawValue) maximum_awake_capture_seconds=40")
            var lastHeartbeat = -1
            var observedInterruption = false
            while ProcessInfo.processInfo.systemUptime - awakeStarted < 40 {
                try Task.checkCancellation()
                let currentEvents = Array(notifications.events.dropFirst(initialCount))
                if case .suspended(let message) = model.dictationCaptureStatus(handle) {
                    let expected = kind == .route ? CaptureInterruption.routeChanged.message : CaptureInterruption.systemSleep.message
                    try #require(message == expected, "The production interruption reason must match the physical action.")
                    observedInterruption = true
                    // Do not resume a sleep test until an actual wake notification arrived.
                    if kind == .route || currentEvents.contains(where: { $0.kind == "NSWorkspace.didWake" }) { break }
                }
                if !model.isRecording && !model.isCaptureTransitioning && !observedInterruption {
                    throw KeystormError.message("Capture stopped without the expected production interruption.")
                }
                let elapsed = Int(ProcessInfo.processInfo.systemUptime - awakeStarted)
                if elapsed / 2 != lastHeartbeat {
                    lastHeartbeat = elapsed / 2
                    report.notifications = currentEvents
                    report.awakeSecondsBeforeResume = ProcessInfo.processInfo.systemUptime - awakeStarted
                    report.wallSecondsBeforeResume = physicalRecoverySeconds(captureStarted)
                    try persist(report, at: reportURL)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            // Always end the bounded ambient interval, even when the user action was absent.
            if model.isRecording { try await model.dictationPause(handle) }
            try #require(observedInterruption,
                "The real input/sleep action was not observed within40awake seconds; this is not a physical recovery pass.")
            try #require(!model.isRecording && !model.isCaptureTransitioning)
            report.awakeSecondsBeforeResume = ProcessInfo.processInfo.systemUptime - awakeStarted
            report.wallSecondsBeforeResume = physicalRecoverySeconds(captureStarted)
            report.notifications = Array(notifications.events.dropFirst(initialCount))
            report.inputAfterInterruption = try PhysicalInputDevice.current()
            if kind == .route {
                try #require(report.notifications.contains { $0.kind == "AVAudioEngine.configurationChange" })
                let before = try #require(report.inputBefore)
                let after = try #require(report.inputAfterInterruption)
                try #require(before.audioObjectID != after.audioObjectID,
                    "A device-switch pass requires a different default input device ID; a sample-rate-only change is insufficient.")
            } else {
                let asleep = try #require(report.notifications.first { $0.kind == "NSWorkspace.willSleep" })
                let awake = try #require(report.notifications.first { $0.kind == "NSWorkspace.didWake" })
                try #require(awake.time > asleep.time)
                report.observedSystemSleepSeconds = report.wallSecondsBeforeResume - report.awakeSecondsBeforeResume
                try #require(report.observedSystemSleepSeconds >= 1,
                    "Notifications alone are insufficient: wall time must include at least1s of actual system sleep.")
            }
            let store = try #require(model.store)
            let closed = try #require(try await store.loadSession(handle.sessionID))
            let firstTake = try #require(closed.brief?.takes.first { $0.id == handle.takeID })
            let firstAudio = closed.takeSegments(firstTake)
            try #require(closed.status == .paused && firstTake.status == .paused)
            try #require(closed.intervals.allSatisfy { $0.endedAt != nil })
            try #require(firstTake.captureIntervalIDs.count == 1 && !firstAudio.isEmpty)
            try #require(closed.dictation?.recordings.first { $0.id == handle.takeID }?.state == .paused)
            report.durablePausedBeforeResume = true
            report.phase = "explicit-resume"
            try persist(report, at: reportURL)
            try await model.dictationResume(handle)
            try #require(model.isRecording && model.openTake?.id == handle.takeID)
            report.inputAtResume = try PhysicalInputDevice.current()
            try #require(report.inputAtResume == report.inputAfterInterruption)
            try #require(openedSources.count == 2)
            try #require(openedSources[0] !== openedSources[1],
                "Explicit resume must open a fresh real input source.")
            report.engineSourceCount = openedSources.count
            let resumedSource = openedSources[1]
            let resumedDefault = try #require(report.inputAtResume)
            report.actualInputDeviceAtResume = try resumedSource.currentInputDeviceID()
            try #require(report.actualInputDeviceAtResume == resumedDefault.audioObjectID,
                "The resumed capture AudioUnit must bind to the new expected default input.")
            try #require(try PhysicalInputDevice.current() == resumedDefault,
                "The default input changed during the resumed AudioUnit observation.")
            if kind == .route {
                try #require(report.actualInputDeviceBefore != report.actualInputDeviceAtResume,
                    "The actual AudioUnit device must change, not just the system default setting.")
            }
            try await Task.sleep(for: .seconds(2))
            try #require(model.isRecording, "Resumed physical capture must remain active for the observation.")
            report.inputAfterResumeObservation = try PhysicalInputDevice.current()
            try #require(report.inputAfterResumeObservation == resumedDefault)
            report.actualInputDeviceAfterResumeObservation = try resumedSource.currentInputDeviceID()
            try #require(report.actualInputDeviceAfterResumeObservation == resumedDefault.audioObjectID,
                "The input AudioUnit must retain the expected device throughout resumed tap delivery.")
            try #require(try PhysicalInputDevice.current() == resumedDefault)
            try await model.dictationPause(handle)
            let saved = try #require(model.sessions.first { $0.id == handle.sessionID })
            let take = try #require(saved.brief?.takes.first { $0.id == handle.takeID })
            let audio = saved.takeSegments(take)
            try #require(take.captureIntervalIDs.count == 2 && Set(take.captureIntervalIDs).count == 2)
            try #require(audio.filter { $0.intervalID == firstTake.captureIntervalIDs[0] } == firstAudio)
            try #require(Set(audio.map(\.intervalID)) == Set(take.captureIntervalIDs))
            try #require(saved.gaps.isEmpty)
            let resumedAudio = audio.filter { $0.intervalID == take.captureIntervalIDs[1] }
            try #require(resumedAudio.reduce(0) { $0 + $1.duration } >= 1.5)
            let resumedInterval = try #require(saved.intervals.first { $0.id == take.captureIntervalIDs[1] })
            let actualInput = try #require(report.inputAtResume)
            try #require(abs(resumedInterval.sampleRate - actualInput.nominalSampleRate) < 1)
            try #require(audio.allSatisfy { $0.frameCount > 0 && $0.sampleRate > 0 })
            let seconds = audio.reduce(0) { $0 + $1.duration }
            try #require(seconds <= 45, "Physical recovery tests must not collect unbounded ambient audio.")
            for pair in zip(audio, audio.dropFirst()) {
                try #require(abs(pair.0.endTime - pair.1.startTime) <= 1 / pair.0.sampleRate)
            }
            for segment in audio {
                let url = try await store.audioURL(for: segment, in: saved.id)
                try #require(try CaptureDurability.sha256(url) == segment.sha256)
                try #require(try AVAudioFile(forReading: url).length == segment.frameCount)
            }
            report.intervalCount = take.captureIntervalIDs.count
            report.sourceFrames = audio.map(\.frameCount)
            report.sampleRates = audio.map(\.sampleRate)
            report.sourceHashes = audio.map(\.sha256)
            report.recordedAmbientSeconds = seconds
            await model.stopForTermination()
            let expected = try #require(model.sessions.first { $0.id == handle.sessionID })
            let fresh = try SessionStore(root: storeURL)
            let restored = try #require(try await fresh.loadSession(handle.sessionID))
            try #require(restored.segments == expected.segments && restored.intervals == expected.intervals)
            try #require(restored.brief?.takes.first { $0.id == handle.takeID }
                == expected.brief?.takes.first { $0.id == handle.takeID })
            try #require(restored.dictation?.recordings.first { $0.id == handle.takeID }?.state == .paused)
            report.reopenedSameTake = true
            report.completed = true
        } catch {
            report.failures.append(error.localizedDescription)
        }
        await workspace?.stopForTermination()
        workspace = nil
        report.notifications = notifications.events
        return report
    }

    private func encode(_ report: PhysicalRecoveryReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    private func persist(_ report: PhysicalRecoveryReport, at url: URL) throws {
        try encode(report).write(to: url, options: .atomic)
    }
}

nonisolated private enum PhysicalRecoveryKind: String { case route, sleep }

nonisolated private struct PhysicalInputDevice: Encodable, Equatable {
    let audioObjectID: UInt32
    let nominalSampleRate: Double

    static func current() throws -> Self {
        var device = AudioObjectID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress,
            0, nil, &deviceSize, &device) == noErr, device != kAudioObjectUnknown else {
            throw KeystormError.message("The actual default input identity could not be read.")
        }
        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &rate) == noErr,
              rate.isFinite, rate > 0 else {
            throw KeystormError.message("The actual default input sample rate could not be read.")
        }
        return Self(audioObjectID: device, nominalSampleRate: rate)
    }
}

nonisolated private struct PhysicalNotification: Encodable, Sendable {
    let kind: String
    let time: Date
    let systemUptime: Double
}

nonisolated private final class PhysicalNotificationLog: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [PhysicalNotification]())
    var events: [PhysicalNotification] { storage.withLock { $0 } }
    nonisolated func append(_ kind: String) {
        storage.withLock { $0.append(PhysicalNotification(kind: kind, time: Date(),
            systemUptime: ProcessInfo.processInfo.systemUptime)) }
    }
}

nonisolated private struct PhysicalRecoveryReport: Encodable {
    let schemaVersion = 2
    let runID: String
    let kind: String
    let generatedAt = Date()
    let processID = ProcessInfo.processInfo.processIdentifier
    let scope = "Explicit physical input-device switch or actual system sleep/wake recovery through EngineCaptureSource. Actual running input AudioUnit device IDs must match stable system-default observations during initial capture, immediately after resume, and after 2s of resumed tap delivery. A route pass requires different actual device IDs; a sample-rate-only change cannot pass. Existing permissions only. No injected events, no system-setting changes by this test, no accuracy or latency percentile claim. Private ambient audio is deleted after durable verification."
    var artifactIdentity: BenchmarkArtifactIdentity?
    var buildInstrumentation: BenchmarkBuildInstrumentation?
    var phase = "preparing"
    var readyAt: Date?
    var sessionID: UUID?
    var takeID: UUID?
    var inputBefore: PhysicalInputDevice?
    var inputAfterInterruption: PhysicalInputDevice?
    var inputAtResume: PhysicalInputDevice?
    var inputAfterResumeObservation: PhysicalInputDevice?
    var actualInputDeviceBefore: UInt32?
    var actualInputDeviceAtResume: UInt32?
    var actualInputDeviceAfterResumeObservation: UInt32?
    var engineSourceCount = 0
    var notifications: [PhysicalNotification] = []
    var awakeSecondsBeforeResume = 0.0
    var wallSecondsBeforeResume = 0.0
    var observedSystemSleepSeconds = 0.0
    var durablePausedBeforeResume = false
    var reopenedSameTake = false
    var intervalCount = 0
    var sourceFrames: [Int64] = []
    var sampleRates: [Double] = []
    var sourceHashes: [String] = []
    var recordedAmbientSeconds = 0.0
    var privateAudioRemoved = false
    var failures: [String] = []
    var completed = false
    var passed = false
}

nonisolated private func physicalRecoverySeconds(_ began: ContinuousClock.Instant) -> Double {
    let duration = began.duration(to: .now).components
    return Double(duration.seconds) + Double(duration.attoseconds) / 1_000_000_000_000_000_000
}
