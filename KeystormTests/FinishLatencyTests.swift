import AVFoundation
import Foundation
import Testing
import os
@testable import Keystorm

/// Opt-in Finish timing harness, off by default: KEYSTORM_RUN_FINISH_LATENCY=1 enables it.
/// KEYSTORM_FINISH_LATENCY_COUNT sets the warm passes (default 100) and
/// KEYSTORM_FINISH_LATENCY_OUTPUT names a .json file or a directory (default: a temporary one).
///
/// Each pass feeds a WAV synthesized here with /usr/bin/say and afconvert through the production
/// segmented writer, then times the production Finish steps on installed local models: saved-audio
/// transcription (raw), Clean, and the in-process delivery step against an in-memory field.
/// No microphone, download, network, real Accessibility target or clipboard is used.
@MainActor
@Suite(.serialized)
struct FinishLatencyTests {
    @Test("File-fed Finish passes are timed against the engineering budgets",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_FINISH_LATENCY"] == "1"),
          .timeLimit(.minutes(120)))
    func finishPassesAgainstBudgets() async throws {
        let environment = ProcessInfo.processInfo.environment
        let warmPasses = FinishLatencyHarness.passCount(from: environment[FinishLatencyHarness.countVariable])
        let outputURL = FinishLatencyHarness.outputURL(from: environment[FinishLatencyHarness.outputVariable], now: Date())
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models", isDirectory: true)
        let installation = LocalInference(modelDirectory: models)
        guard await installation.isInstalled(ModelCatalog.primarySpeech) else {
            try Test.cancel("The pinned local speech model is not installed in \(models.path). Nothing was downloaded.")
        }
        let textInstalled = await installation.isInstalled(ModelCatalog.primaryText)
        guard FileManager.default.isExecutableFile(atPath: FinishLatencyHarness.sayPath),
              FileManager.default.isExecutableFile(atPath: FinishLatencyHarness.afconvertPath) else {
            try Test.cancel("Local speech synthesis tools are unavailable. No audio was fetched instead.")
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-FinishLatency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await FinishLatencyHarness.synthesizeFixture(in: work)
        var report = FinishLatencyReport(fixture: fixture.metadata, textModelInstalled: textInstalled,
            requestedWarmPasses: warmPasses)

        // Cold: a fresh worker process for one pass, without a prewarm.
        let cold = WorkspaceModel(root: work.appendingPathComponent("ColdStore", isDirectory: true), modelDirectory: models)
        do {
            await cold.initialize(loadLibrary: true)
            try #require(cold.error == nil, "\(cold.error ?? "")")
            report.passes.append(await runPass(index: 0, scenario: .cold, model: cold, audio: fixture.url,
                measuresClean: textInstalled))
        } catch {
            await cold.stopForTermination()
            throw error
        }
        await cold.stopForTermination()

        // Prewarmed first use, then warm passes, on a second fresh worker process.
        let warm = WorkspaceModel(root: work.appendingPathComponent("WarmStore", isDirectory: true), modelDirectory: models)
        do {
            await warm.initialize(loadLibrary: true)
            try #require(warm.error == nil, "\(warm.error ?? "")")
            if textInstalled { report.prewarm = await warm.prewarmTextModel() }
            report.passes.append(await runPass(index: 1, scenario: .prewarmedFirst, model: warm, audio: fixture.url,
                measuresClean: textInstalled))
            for offset in 0..<warmPasses {
                report.passes.append(await runPass(index: 2 + offset, scenario: .warm, model: warm, audio: fixture.url,
                    measuresClean: textInstalled))
            }
            report.runtimeSummaries = warm.performanceSummaries
        } catch {
            await warm.stopForTermination()
            throw error
        }
        await warm.stopForTermination()

        report.complete()
        // Persist the complete evidence, failures included, before any assertion.
        let data = try FinishLatencyHarness.encode(report)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outputURL, options: .atomic)
        Attachment.record(data, named: "finish-latency.json")
        print("FINISH_LATENCY_REPORT " + outputURL.path)
        for line in FinishLatencyHarness.summaryLines(report) { print(line) }

        let failures = report.passes.compactMap { pass in
            pass.failure.map { "pass \(pass.index) (\(pass.scenario.rawValue)): \($0)" }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "; "))")
        #expect(report.passes.count == warmPasses + 2)
        let notInsertedExactlyOnce = report.passes.filter { $0.failure == nil && !$0.insertedExactlyOnce }.map(\.index)
        #expect(notInsertedExactlyOnce.isEmpty, "Passes not inserted exactly once: \(notInsertedExactlyOnce)")
    }

    /// One production Finish on a fresh take: raw, then Clean when installed, then delivery.
    private func runPass(index: Int, scenario: FinishLatencyScenario, model: WorkspaceModel,
                         audio: URL, measuresClean: Bool) async -> FinishLatencyPass {
        var pass = FinishLatencyPass(index: index, scenario: scenario)
        let adapter = FinishLatencyAdapter()
        let delivery = DictationDeliveryService(adapter: adapter,
            ownBundleIdentifier: "test.Keystorm.latency", ownProcessIdentifier: 999)
        do {
            // Start captures the destination before any audio, as the coordinator does.
            guard case .ready(let target) = delivery.captureTarget() else {
                throw KeystormError.message("The in-memory destination was not captured.")
            }
            let recording = try await recordFixture(audio, into: model)
            model.dictationSetForegroundProcessing(recording, active: true)
            defer { model.dictationSetForegroundProcessing(recording, active: false) }

            let finishStarted = ContinuousClock.now
            let source = try await model.dictationComplete(recording)
            pass.rawMilliseconds = FinishLatencyHarness.milliseconds(since: finishStarted)
            pass.rawText = source.text
            var output = source
            if measuresClean {
                let cleanStarted = ContinuousClock.now
                let result = try await model.dictationTransform(recording, source: source, mode: .clean, context: nil)
                try DictationTransformPolicy.validateText(result.text, source: source.text, mode: .clean)
                let metadata = try await model.dictationApplyTransform(recording, source: source, result: result, context: nil)
                guard let saved = metadata.textRevision, saved.id == result.jobID,
                      saved.text.utf8.elementsEqual(result.text.utf8) else {
                    throw KeystormError.message("The committed Clean output did not match its generated result.")
                }
                output = saved
                pass.cleanMilliseconds = FinishLatencyHarness.milliseconds(since: cleanStarted)
                pass.finishToCleanMilliseconds = FinishLatencyHarness.milliseconds(since: finishStarted)
            }
            pass.outputText = output.text

            // A durable intent precedes the write; the timed step is the delivery itself.
            let requestID = UUID()
            try await model.dictationSave(recording, state: .ready, revision: output,
                delivery: DictationDelivery(requestID: requestID, textRevisionID: output.id,
                    targetLabel: target.descriptor.appName), failure: nil)
            let deliveryStarted = ContinuousClock.now
            let receipt = await delivery.deliver(output.text, to: target, deliveryID: requestID)
            pass.deliveryMilliseconds = FinishLatencyHarness.milliseconds(since: deliveryStarted)
            pass.deliveryOutcome = receipt.outcome.rawValue
            let persistStarted = ContinuousClock.now
            try await model.dictationSave(recording, state: .ready, revision: output,
                delivery: DictationDelivery(requestID: requestID, textRevisionID: output.id,
                    targetLabel: receipt.destination.appName,
                    state: receipt.outcome == .confirmed ? .inserted : .failed, detail: receipt.message), failure: nil)
            pass.receiptSaveMilliseconds = FinishLatencyHarness.milliseconds(since: persistStarted)
            pass.insertedExactlyOnce = receipt.outcome == .confirmed && adapter.writes == [output.text]
            if receipt.outcome != .confirmed { pass.failure = "Delivery outcome: \(receipt.outcome.rawValue). \(receipt.message)" }
        } catch {
            pass.failure = error.localizedDescription
        }
        return pass
    }

    /// Feeds the fixture through the production segmented writer into a new take, as saved capture.
    private func recordFixture(_ audio: URL, into model: WorkspaceModel) async throws -> DictationRecordingHandle {
        let store = try #require(model.store)
        let input = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sampleRate = input.processingFormat.sampleRate
        var session = VoiceSession()
        session.title = "Finish latency fixture"
        let brief = BriefDocument()
        let intervalID = UUID()
        let take = BriefTake(intervalID: intervalID, expectedRevision: brief.revisionID, status: .pending)
        session.brief = brief
        session.brief?.takes = [take]
        var metadata = DictationRecordingMetadata(id: take.id, state: .captured)
        metadata.captureMode = .clean
        session.dictation = DictationSession(recordings: [metadata])
        let directory = try await store.audioDirectory(session.id)
        let commits = FinishLatencyWriterReceipts()
        let writer = try SegmentedAudioWriter(directory: directory, format: input.processingFormat,
            intervalID: intervalID, startTime: 0,
            onCommit: { commits.commit($0) }, onFailure: { commits.fail($0) })
        let block = try #require(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 1_600))
        var cursor: Int64 = 0
        do {
            while cursor < input.length {
                let count = AVAudioFrameCount(min(1_600, input.length - cursor))
                try input.read(into: block, frameCount: count)
                guard block.frameLength == count else { throw KeystormError.message("Unexpected end of the fixture WAV.") }
                writer.enqueue(AVReadOnlyAudioPCMBuffer(copying: block), timestamp: CaptureTimestamp(
                    sampleTime: cursor, hostTime: AVAudioTime.hostTime(forSeconds: 100 + Double(cursor) / sampleRate)))
                cursor += Int64(count)
                // A short paced feed lets the writer drain without pretending to be the microphone clock.
                try await Task.sleep(for: .milliseconds(12))
            }
            try await writer.finish()
        } catch {
            try? await writer.finish()
            throw error
        }
        guard commits.failures.isEmpty else { throw KeystormError.message(commits.failures.joined(separator: " ")) }
        session.segments = commits.segments.sorted { $0.startTime < $1.startTime }
        guard !session.segments.isEmpty, session.segments.reduce(0, { $0 + $1.frameCount }) == cursor else {
            throw KeystormError.message("The production writer did not preserve the complete fixture.")
        }
        let startedAt = Date()
        session.intervals = [CaptureInterval(id: intervalID, startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(Double(cursor) / sampleRate), sampleRate: sampleRate, channelCount: 1)]
        try await store.save(session)
        let handle = DictationRecordingHandle(sessionID: session.id, takeID: take.id)
        // Loads the saved take into the workspace exactly as reopening a recording does.
        try await model.dictationSave(handle, state: .captured, revision: nil, delivery: nil, failure: nil)
        return handle
    }
}

/// Fast checks of the harness arithmetic. These never run a model or synthesize audio.
struct FinishLatencyHarnessTests {
    @Test("Nearest-rank percentiles match the runtime metrics convention")
    func nearestRankPercentiles() {
        let values = (1...20).map(Double.init)
        #expect(FinishLatencyHarness.percentile(values, 0.5) == 10)
        #expect(FinishLatencyHarness.percentile(values, 0.95) == 19)
        #expect(FinishLatencyHarness.percentile(values, 0.99) == 20)
        #expect(FinishLatencyHarness.percentile([], 0.5) == nil)
        #expect(FinishLatencyHarness.percentile([7], 0.95) == 7)
    }

    @Test("The pass count defaults to 100 and stays bounded",
          arguments: [(nil, 100), ("250", 250), ("0", 1), ("-3", 1), ("many", 100), ("50000", 10_000)] as [(String?, Int)])
    func passCount(value: String?, expected: Int) {
        #expect(FinishLatencyHarness.passCount(from: value) == expected)
    }

    @Test("Output names a JSON file, or a directory that receives a timestamped report")
    func outputLocation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let file = FinishLatencyHarness.outputURL(from: "/tmp/latency/run.json", now: now)
        #expect(file.path == "/tmp/latency/run.json")
        let directory = FinishLatencyHarness.outputURL(from: "/tmp/latency", now: now)
        #expect(directory.path == "/tmp/latency/finish-latency-1800000000.json")
        let fallback = FinishLatencyHarness.outputURL(from: nil, now: now)
        #expect(fallback.lastPathComponent == "finish-latency-1800000000.json")
        #expect(fallback.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test("Budgets use warm passes only, and failed passes are reported, never dropped")
    func budgetsUseWarmPasses() throws {
        var report = FinishLatencyReport(fixture: FinishLatencyFixture(text: "x", wordCount: 1, voice: "fixture",
            format: "fixture", frames: 16_000, sampleRate: 16_000, durationSeconds: 1, sha256: "0"),
            textModelInstalled: true, requestedWarmPasses: 3)
        var cold = FinishLatencyPass(index: 0, scenario: .cold)
        cold.rawMilliseconds = 9_000
        report.passes.append(cold)
        for (index, raw) in [400.0, 600, 900].enumerated() {
            var pass = FinishLatencyPass(index: 2 + index, scenario: .warm)
            pass.rawMilliseconds = raw
            pass.finishToCleanMilliseconds = raw + 1_000
            pass.deliveryMilliseconds = 5
            report.passes.append(pass)
        }
        var failed = FinishLatencyPass(index: 5, scenario: .warm)
        failed.failure = "Clean validation rejected the output."
        report.passes.append(failed)
        report.complete()
        let raw = try #require(report.budgets.first { $0.metric == "raw" && $0.percentile == "p95" })
        #expect(raw.observedMilliseconds == 900)
        #expect(raw.sampleCount == 3)
        #expect(raw.failedPasses == 1)
        #expect(raw.met == false)
        let delivery = try #require(report.budgets.first { $0.metric == "delivery" })
        #expect(delivery.met == true)
        let coldRaw = try #require(report.summaries.first { $0.scenario == "cold" && $0.metric == "raw" })
        #expect(coldRaw.count == 1 && coldRaw.p95Milliseconds == 9_000)
    }
}

nonisolated enum FinishLatencyScenario: String, Encodable, CaseIterable, Sendable {
    /// Fresh worker process, no prewarm: process-cold speech and text.
    case cold
    /// Fresh worker process whose text model was prewarmed first; speech is still process-cold.
    case prewarmedFirst
    /// One reused worker with both models resident.
    case warm
}

nonisolated enum FinishLatencyMetric: String, CaseIterable, Sendable {
    case raw, clean, finishToClean, delivery, receiptSave

    func value(in pass: FinishLatencyPass) -> Double? {
        switch self {
        case .raw: pass.rawMilliseconds
        case .clean: pass.cleanMilliseconds
        case .finishToClean: pass.finishToCleanMilliseconds
        case .delivery: pass.deliveryMilliseconds
        case .receiptSave: pass.receiptSaveMilliseconds
        }
    }
}

nonisolated struct FinishLatencyFixture: Encodable, Sendable {
    let text: String
    let wordCount: Int
    let voice: String
    let format: String
    let frames: Int64
    let sampleRate: Double
    let durationSeconds: Double
    let sha256: String
}

nonisolated struct FinishLatencyPass: Encodable, Sendable {
    let index: Int
    let scenario: FinishLatencyScenario
    /// Finish to the complete raw transcript: dictationComplete on the whole saved take.
    var rawMilliseconds: Double?
    /// Clean generation, validation and durable commit of the output revision.
    var cleanMilliseconds: Double?
    var finishToCleanMilliseconds: Double?
    /// Commit-ready output to the confirmed in-memory write, excluding receipt persistence.
    var deliveryMilliseconds: Double?
    var receiptSaveMilliseconds: Double?
    var deliveryOutcome: String?
    var insertedExactlyOnce = false
    var rawText: String?
    var outputText: String?
    var failure: String?

    init(index: Int, scenario: FinishLatencyScenario) {
        self.index = index
        self.scenario = scenario
    }
}

nonisolated struct FinishLatencySummary: Encodable, Sendable {
    let scenario: String
    let metric: String
    let count: Int
    let failedPasses: Int
    let p50Milliseconds: Double?
    let p95Milliseconds: Double?
    let p99Milliseconds: Double?
    let maximumMilliseconds: Double?
}

nonisolated struct FinishLatencyBudget: Encodable, Sendable {
    let measurement: String
    let scenario: String
    let metric: String
    let percentile: String
    let budgetMilliseconds: Double
    let observedMilliseconds: Double?
    let sampleCount: Int
    let failedPasses: Int
    /// Nil when nothing was measured, for example without an installed text model.
    let met: Bool?
}

nonisolated struct FinishLatencyReport: Encodable, Sendable {
    let schemaVersion = 1
    let purpose = "Opt-in file-fed timing of the production Finish steps against the engineering budgets. Budgets are targets, not results."
    let generatedAt = Date()
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let hardwareModel = RuntimePerformanceReport.hardwareModel
    let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    let logicalProcessors = ProcessInfo.processInfo.activeProcessorCount
    let thermalStateAtStart = ProcessInfo.processInfo.thermalState.rawValue
    var thermalStateAtEnd: Int?
    let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    let buildConfiguration = FinishLatencyHarness.buildConfiguration
    let speechModelID = ModelCatalog.primarySpeech.id
    let speechModelRevision = ModelCatalog.primarySpeech.revision
    let textModelID = ModelCatalog.primaryText.id
    let textModelRevision = ModelCatalog.primaryText.revision
    let fixture: FinishLatencyFixture
    let textModelInstalled: Bool
    let requestedWarmPasses: Int
    var prewarm: TextPrewarmRun?
    var passes: [FinishLatencyPass] = []
    var summaries: [FinishLatencySummary] = []
    var budgets: [FinishLatencyBudget] = []
    var runtimeSummaries: [RuntimeMetricSummary] = []
    let limitations = "Each pass feeds a locally synthesized English WAV through the production segmented writer at up to about eight times real time (100 ms of audio per 12 ms pause), then times WorkspaceModel.dictationComplete (transcription of the whole saved take, so an upper bound on a live tail whose earlier windows were already transcribed during recording), dictationTransform plus dictationApplyTransform (Clean), and DictationDeliveryService.deliver against an in-memory field. No microphone, capture drain, HUD, coordinator UI, physical shortcut, real Accessibility target, app or clipboard is involved. Cold and prewarmed-first passes use fresh worker processes; OS file and compiled-shader caches may already be warm. Warm passes reuse one worker with both models resident; only they are compared with the budgets. Failed passes are listed and counted; they contribute no timing samples. Synthetic single-speaker English does not establish ASR accuracy, mixed-language behavior, thermal or battery behavior."

    init(fixture: FinishLatencyFixture, textModelInstalled: Bool, requestedWarmPasses: Int) {
        self.fixture = fixture
        self.textModelInstalled = textModelInstalled
        self.requestedWarmPasses = requestedWarmPasses
    }

    mutating func complete() {
        thermalStateAtEnd = ProcessInfo.processInfo.thermalState.rawValue
        summaries = FinishLatencyScenario.allCases.flatMap { scenario -> [FinishLatencySummary] in
            let scoped = passes.filter { $0.scenario == scenario }
            return FinishLatencyMetric.allCases.compactMap { metric -> FinishLatencySummary? in
                guard !scoped.isEmpty else { return nil }
                let values = scoped.filter { $0.failure == nil }.compactMap { metric.value(in: $0) }.sorted()
                return FinishLatencySummary(scenario: scenario.rawValue, metric: metric.rawValue, count: values.count,
                    failedPasses: scoped.filter { $0.failure != nil }.count,
                    p50Milliseconds: FinishLatencyHarness.percentile(values, 0.5),
                    p95Milliseconds: FinishLatencyHarness.percentile(values, 0.95),
                    p99Milliseconds: FinishLatencyHarness.percentile(values, 0.99),
                    maximumMilliseconds: values.last)
            }
        }
        let warm = passes.filter { $0.scenario == .warm }
        let failed = warm.filter { $0.failure != nil }.count
        budgets = FinishLatencyHarness.budgets.map { budget -> FinishLatencyBudget in
            let values = warm.filter { $0.failure == nil }.compactMap { budget.metric.value(in: $0) }.sorted()
            let observed = FinishLatencyHarness.percentile(values, budget.fraction)
            return FinishLatencyBudget(measurement: budget.measurement, scenario: FinishLatencyScenario.warm.rawValue,
                metric: budget.metric.rawValue, percentile: budget.label, budgetMilliseconds: budget.milliseconds,
                observedMilliseconds: observed, sampleCount: values.count, failedPasses: failed,
                met: observed.map { $0 <= budget.milliseconds })
        }
    }
}

nonisolated enum FinishLatencyHarness {
    static let countVariable = "KEYSTORM_FINISH_LATENCY_COUNT"
    static let outputVariable = "KEYSTORM_FINISH_LATENCY_OUTPUT"
    static let defaultPassCount = 100
    static let maximumPassCount = 10_000
    static let sayPath = "/usr/bin/say"
    static let afconvertPath = "/usr/bin/afconvert"
    static let preferredVoice = "Samantha"
    /// Short case: at most 30 words and 15 seconds.
    static let fixtureText = "Please keep the invoice local, not in the cloud. Send the short summary to Anna by Friday and keep forty two files in the project folder."

    static var buildConfiguration: String {
        #if DEBUG
        return "Debug; optimization disabled"
        #else
        return "Release"
        #endif
    }

    /// Targets on the reference machine with installed assets.
    static let budgets: [(measurement: String, metric: FinishLatencyMetric, fraction: Double, label: String, milliseconds: Double)] = [
        ("Finish to raw final, ≤30 words / ≤15 s", .raw, 0.95, "p95", 800),
        ("Finish to completed Clean result, same short case", .finishToClean, 0.5, "p50", 700),
        ("Finish to completed Clean result, same short case", .finishToClean, 0.95, "p95", 1_500),
        ("Commit-ready result to confirmed supported-field delivery", .delivery, 0.95, "p95", 100)
    ]

    static func passCount(from value: String?) -> Int {
        guard let value, let count = Int(value.trimmingCharacters(in: .whitespaces)) else { return defaultPassCount }
        return min(maximumPassCount, max(1, count))
    }

    /// A value ending in .json is the report file; any other value is a directory for it.
    static func outputURL(from value: String?, now: Date) -> URL {
        let name = "finish-latency-\(Int(now.timeIntervalSince1970)).json"
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Keystorm-FinishLatency-Results", isDirectory: true)
                .appendingPathComponent(name)
        }
        let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        return url.pathExtension.lowercased() == "json" ? url : url.appendingPathComponent(name)
    }

    /// Nearest rank, as RuntimeMetricSamples reports it.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((Double(sorted.count) * fraction).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
    }

    static func encode(_ report: FinishLatencyReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    static func summaryLines(_ report: FinishLatencyReport) -> [String] {
        func format(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "n/a" }
        var lines: [String] = []
        if let prewarm = report.prewarm {
            lines.append("FINISH_LATENCY_PREWARM outcome=\(prewarm.outcome.rawValue) ms=\(format(prewarm.milliseconds))")
        }
        for summary in report.summaries where summary.count > 0 || summary.failedPasses > 0 {
            lines.append("FINISH_LATENCY \(summary.scenario) \(summary.metric) n=\(summary.count) failed=\(summary.failedPasses) " +
                "p50=\(format(summary.p50Milliseconds)) p95=\(format(summary.p95Milliseconds)) max=\(format(summary.maximumMilliseconds))")
        }
        for budget in report.budgets {
            let verdict = budget.met.map { $0 ? "met" : "missed" } ?? "not measured"
            lines.append("FINISH_LATENCY_BUDGET \(budget.metric) \(budget.percentile) observed=\(format(budget.observedMilliseconds)) " +
                "budget=\(format(budget.budgetMilliseconds)) \(verdict) n=\(budget.sampleCount) failed=\(budget.failedPasses)")
        }
        return lines
    }

    /// Synthesizes the fixture on this Mac: say, then afconvert to mono PCM16 at 16 kHz. Nothing is downloaded.
    static func synthesizeFixture(in directory: URL) async throws -> (url: URL, metadata: FinishLatencyFixture) {
        let speech = directory.appendingPathComponent("fixture.aiff")
        let wav = directory.appendingPathComponent("fixture.wav")
        var voice = preferredVoice
        var status = try await runTool(sayPath, ["-v", voice, "-o", speech.path, fixtureText])
        if status != 0 {
            voice = "system default"
            status = try await runTool(sayPath, ["-o", speech.path, fixtureText])
        }
        try #require(status == 0, "/usr/bin/say could not synthesize the local fixture.")
        let converted = try await runTool(afconvertPath, ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", speech.path, wav.path])
        try #require(converted == 0, "afconvert could not produce mono PCM16 16 kHz audio.")
        let file = try AVAudioFile(forReading: wav)
        try #require(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1 &&
            file.fileFormat.commonFormat == .pcmFormatInt16, "The fixture must be mono PCM16 at 16 kHz.")
        let duration = Double(file.length) / 16_000
        let words = fixtureText.split(whereSeparator: \.isWhitespace).count
        try #require(file.length > 0 && duration <= 15 && words <= 30,
            "The fixture must stay within the short case: at most 30 words and 15 seconds.")
        let metadata = FinishLatencyFixture(text: fixtureText, wordCount: words, voice: voice,
            format: "WAVE, mono PCM16, 16 kHz (say + afconvert)", frames: file.length, sampleRate: 16_000,
            durationSeconds: duration, sha256: try CaptureDurability.sha256(wav))
        return (wav, metadata)
    }

    /// Runs a local tool off the main actor. Output is discarded; only the exit status matters.
    private static func runTool(_ path: String, _ arguments: [String]) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
}

/// An in-memory field standing in for a qualified destination. It reports no secure state,
/// keeps its own text and selection, and records every write.
@MainActor
private final class FinishLatencyField: DictationDeliveryField {}

@MainActor
private final class FinishLatencyAdapter: DictationDeliveryAdapter {
    private let field = FinishLatencyField()
    private let processIdentifier: Int32 = 4_242
    private var current = DictationFieldSnapshot(text: "Before  after", selection: NSRange(location: 7, length: 0))
    private(set) var writes: [String] = []

    var isTrusted: Bool { true }
    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? {
        DictationDeliveryApplication(processIdentifier: processIdentifier, bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
    }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField { field }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { lhs === rhs }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata {
        DictationFieldMetadata(processIdentifier: processIdentifier, role: "AXTextArea", subrole: nil,
            isEnabled: true, isProtected: false, selectedTextIsSettable: true)
    }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot { current }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        writes.append(text)
        current.text = (current.text as NSString).replacingCharacters(in: current.selection, with: text)
        current.selection = NSRange(location: current.selection.location + text.utf16.count, length: 0)
        return .accepted
    }
}

private final class FinishLatencyWriterReceipts: Sendable {
    private struct State { var segments: [AudioSegment] = []; var failures: [String] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var segments: [AudioSegment] { state.withLock { $0.segments } }
    var failures: [String] { state.withLock { $0.failures } }
    func commit(_ segment: AudioSegment) { state.withLock { $0.segments.append(segment) } }
    func fail(_ message: String) { state.withLock { $0.failures.append(message) } }
}
