import Darwin
import Foundation

enum InferenceWorkerOperation: String, Codable, Sendable {
    case ping, prepareSpeech, prepareText, speechPreview, speech, extraction, edit, transform, classifyCorrection, memory
    #if DEBUG
    case debugWait
    #endif
}

struct InferenceWorkerRequest: Codable, Sendable {
    var version = 1
    var id = UUID()
    var operation: InferenceWorkerOperation
    var parentFootprint: UInt64 = 0
    var modelID: String?
    var audioDirectory: URL?
    var previewPCM: Data?
    var segments: [AudioSegment] = []
    var transcripts: [TranscriptRevision] = []
    var contexts: [ContextSnapshot] = []
    var configuration: ProcessingConfiguration?
    var priorFacts: [Fact] = []
    var command: String?
    var document: BriefDocument?
    var targetSection: BriefSectionKind?
    var selectedBlockIDs: [UUID] = []
    var sources: [SourceReference] = []
    var transform: DictationTransformRequest?
    var correction: CorrectionClassificationRequest?
}

struct InferenceWorkerReply: Codable, Sendable {
    var version = 1
    var id: UUID
    var succeeded = true
    var error: String?
    var processID: Int32
    var speech: SpeechWindowResult?
    var speechPreview: LiveSpeechPreviewResult?
    var facts: [Fact]?
    var edits: [BriefEdit]?
    var transform: DictationTransformResult?
    var correction: CorrectionClassificationResult?
    var transformFailure: DictationTransformGenerationFailure?
    var memory: [String: UInt64] = [:]
}

/// Ephemeral display output only. Times are relative to the supplied 16 kHz window;
/// this value carries no persisted source, transcript revision, or completion claim.
nonisolated struct LiveSpeechPreviewResult: Codable, Equatable, Sendable {
    let text: String
    let words: [TimedSpeechWord]

    func validate(sampleCount: Int) throws {
        let duration = Double(sampleCount) / Double(LiveSpeechPreviewPCM.sampleRate)
        guard (LiveSpeechPreviewPCM.minimumSamples...LiveSpeechPreviewPCM.maximumSamples).contains(sampleCount),
              text.utf8.count <= 16_384, words.count < LocalInference.speechTokenLimit,
              words.allSatisfy({
                  !$0.word.isEmpty && $0.word.utf8.count <= 4_096 &&
                  $0.startTime.isFinite && $0.endTime.isFinite &&
                  $0.startTime >= 0 && $0.endTime >= $0.startTime &&
                  $0.endTime <= duration + 0.5
              }) else {
            throw KeystormError.message("The speech preview returned invalid relative timing or exceeded its bounded output.")
        }
    }
}

/// Canonical little-endian Float32 PCM. Codable encodes Data as base64, avoiding
/// hundreds of thousands of JSON numbers. Both pipe endpoints validate before use.
nonisolated enum LiveSpeechPreviewPCM {
    static let sampleRate = 16_000
    static let minimumSamples = 1_600
    static let maximumSamples = 240_000

    static func encode(_ samples: [Float]) throws -> Data {
        guard (minimumSamples...maximumSamples).contains(samples.count),
              samples.allSatisfy(\.isFinite) else { throw invalidAudio() }
        var words = samples.map { $0.bitPattern.littleEndian }
        return words.withUnsafeMutableBytes { Data($0) }
    }

    static func decode(_ data: Data) throws -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<UInt32>.size),
              (minimumSamples...maximumSamples).contains(data.count / MemoryLayout<UInt32>.size) else {
            throw invalidAudio()
        }
        let samples: [Float] = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: MemoryLayout<UInt32>.size).map { offset in
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
        guard samples.allSatisfy(\.isFinite) else { throw invalidAudio() }
        return samples
    }

    private static func invalidAudio() -> KeystormError {
        .message("Speech previews require 0.1–15 seconds of finite mono 16 kHz Float32 audio.")
    }
}

/// Failed generated output stays inside the private worker transport. The UI sees
/// only the localized reason; opt-in tests can attach the actual bounded envelope.
nonisolated struct DictationTransformGenerationFailure: Codable, LocalizedError, Sendable {
    let message: String
    let generatedEnvelope: String
    let generatedTokens: Int
    var errorDescription: String? { message }
}

struct InferenceWorkerIdentity: Equatable, Sendable {
    let processID: Int32
    let protocolVersion: Int
}

/// Newline framing bounds both queued input and decoded replies. Private anonymous
/// pipes carry all source material; no socket, listening port, or public endpoint exists.
enum InferenceWorkerCodec {
    static let prefix = Data("KEYSTORM-RPC/1 ".utf8)
    static let maximumFrameBytes = 8 * 1_024 * 1_024

    static func frame<T: Encodable>(_ value: T) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count + prefix.count <= maximumFrameBytes else {
            throw KeystormError.message("This worker job exceeds the bounded 8 MB message limit. Select a smaller section.")
        }
        var frame = prefix
        frame.append(encoded)
        frame.append(0x0A)
        return frame
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        guard line.count <= maximumFrameBytes, line.starts(with: prefix) else {
            throw KeystormError.message("The local worker returned an invalid protocol frame.")
        }
        return try JSONDecoder().decode(type, from: line.dropFirst(prefix.count))
    }
}

/// One reader owns this buffer, whether in the daemon loop or on its dedicated
/// parent-side background task. A blocked pipe read never occupies the UI actor.
final class InferenceWorkerFrameReader: @unchecked Sendable {
    private let file: FileHandle
    private var buffer = Data()
    private var scanOffset = 0
    private var readBuffer = [UInt8](repeating: 0, count: 8_192)
    #if DEBUG
    private(set) var scannedByteCount = 0
    #endif

    init(file: FileHandle) { self.file = file }

    func nextLine() throws -> Data? {
        while true {
            // Inspect only bytes added by the last read. Rescanning the entire frame
            // on every 8 KB read makes a maximum-sized message visit over 4 GB.
            let unscanned = buffer.index(buffer.startIndex, offsetBy: scanOffset)
            let newline = buffer[unscanned...].firstIndex(of: 0x0A)
            #if DEBUG
            scannedByteCount += newline.map { buffer.distance(from: unscanned, to: $0) + 1 }
                ?? (buffer.count - scanOffset)
            #endif
            if let newline {
                let length = buffer.distance(from: buffer.startIndex, to: newline)
                guard length <= InferenceWorkerCodec.maximumFrameBytes else {
                    throw KeystormError.message("The local worker message exceeded its output limit.")
                }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                scanOffset = 0
                return line
            }
            scanOffset = buffer.count
            guard buffer.count <= InferenceWorkerCodec.maximumFrameBytes else {
                throw KeystormError.message("The local worker message exceeded its output limit.")
            }
            // FileHandle's length-based reads may wait to fill the requested length on
            // a pipe. A single POSIX read returns as soon as any frame bytes are available.
            // Retain one scratch buffer, and admit only enough bytes to detect overflow.
            let available = min(readBuffer.count, InferenceWorkerCodec.maximumFrameBytes + 1 - buffer.count)
            let count = readBuffer.withUnsafeMutableBytes { raw in
                Darwin.read(file.fileDescriptor, raw.baseAddress, available)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else {
                guard buffer.isEmpty else { throw KeystormError.message("The local worker stopped in the middle of a reply.") }
                return nil
            }
            buffer.append(contentsOf: readBuffer.prefix(count))
        }
    }
}
