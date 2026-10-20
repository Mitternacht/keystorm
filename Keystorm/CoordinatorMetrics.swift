import Darwin
import Foundation

/// A bounded in-memory observation, never a claim about end-to-end hardware performance.
struct RuntimeMeasurement: Identifiable, Equatable, Sendable, Codable {
    var id = UUID()
    var kind: String
    var milliseconds: Double
    var createdAt = Date()
}

struct RuntimeMetricSummary: Identifiable, Equatable, Sendable, Codable {
    var id: String { kind }
    let kind: String
    let count: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let maximumMilliseconds: Double

    var title: String {
        switch kind {
        case "workspace.initialize": "Workspace startup"
        case "capture.engineStart": "Recording request to microphone started"
        case "capture.engineStop": "Microphone stop phase"
        case "capture.drain": "Stop request to saved audio drained"
        case "speech.firstLiveText": "First provisional transcript"
        case "speech.preview": "Live preview inference"
        case "speech.previewLag": "Live preview audio lag"
        case "speech.previewPrepare": "Speech model preparation"
        case "speech.window": "Saved window transcription"
        case "brief.proposal": "Prepare request to new proposal"
        case "brief.prepareAttempt": "Prepare attempt (all outcomes)"
        case "brief.persistence": "Queued document save"
        case "brief.typing": "In-memory passage edit"
        case "processing.cancel": "Processing cancellation"
        case TextPrewarmPolicy.metricKind: "Text model prewarm (load)"
        case TextPrewarmPolicy.finishJoinMetricKind: "Finish wait for in-flight model work"
        default: kind
        }
    }
}

/// Keep independent bounded rings: frequent previews cannot evict capture/proposal evidence.
struct RuntimeMetricSamples {
    static let samplesPerMetric = 128
    static let maximumMetrics = 32
    private var samples: [String: [Double]] = [:]
    private var next: [String: Int] = [:]

    mutating func append(kind: String, milliseconds: Double) -> Bool {
        guard !kind.isEmpty, kind.utf8.count <= 128, milliseconds.isFinite, milliseconds >= 0,
              samples[kind] != nil || samples.count < Self.maximumMetrics else { return false }
        if samples[kind, default: []].count < Self.samplesPerMetric {
            samples[kind, default: []].append(milliseconds)
        } else {
            let index = next[kind, default: 0]
            samples[kind]![index] = milliseconds
            next[kind] = (index + 1) % Self.samplesPerMetric
        }
        return true
    }

    mutating func record(kind: String, milliseconds: Double) -> RuntimeMetricSummary? {
        guard append(kind: kind, milliseconds: milliseconds) else { return nil }
        return summary(for: kind)
    }

    var summaries: [RuntimeMetricSummary] { samples.keys.sorted().compactMap { summary(for: $0) } }

    private func summary(for kind: String) -> RuntimeMetricSummary? {
        guard let values = samples[kind], !values.isEmpty else { return nil }
        let ordered = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            ordered[max(0, Int(ceil(Double(ordered.count) * fraction)) - 1)]
        }
        return RuntimeMetricSummary(kind: kind, count: ordered.count,
            p50Milliseconds: percentile(0.5), p95Milliseconds: percentile(0.95),
            p99Milliseconds: percentile(0.99), maximumMilliseconds: ordered.last!)
    }
}

/// Pinned catalog manifests, explicitly distinct from observed per-job configurations.
struct RuntimeCatalogModel: Codable, Sendable {
    let modelID: String
    let repository: String?
    let revision: String?
    let runtime: String
    let runtimeRevision: String
    let quantization: String
    let artifacts: [ModelArtifact]
}

struct RuntimePerformanceReport: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let operatingSystem: String
    let hardwareModel: String
    let physicalMemoryBytes: UInt64
    let logicalProcessors: Int
    let thermalState: Int
    let lowPowerMode: Bool
    let appVersion: String
    let configuration: String
    let selectedSpeechModelID: String
    let textModelID: String
    let installedModelIDs: [String]
    let catalogModels: [RuntimeCatalogModel]
    let summaries: [RuntimeMetricSummary]
    let recentMeasurements: [RuntimeMeasurement]
    let memorySnapshotBytes: [String: UInt64]
    let limitations: String

    static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size < 256 else { return "Unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Unknown" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

struct ReviewedBriefSnapshot: Sendable {
    let session: VoiceSession
    let revisionID: UUID
    let text: String
}
