import AVFoundation
import Foundation
import Testing
@testable import Keystorm

@MainActor
struct RecordingAudioEditTests {
    @Test func trimIsFrameExactAcrossCaptureIntervalsAndPreservesOriginals() throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try writeSource(in: fixture.audio, frames: 32_000, interval: UUID())
        let second = try writeSource(in: fixture.audio, frames: 56_000, interval: UUID(), start: 2)
        let edit = try RecordingAudioEditor.trim(segments: [second, first], audioDirectory: fixture.audio,
            staging: fixture.staging, start: 1.25, end: 5.25, timelineStart: 100)
        #expect(edit.directory == fixture.staging)
        #expect(edit.duration == 4)
        #expect(edit.segments.map(\.frameCount) == [12_000, 52_000])
        #expect(edit.segments.map(\.startTime) == [100, 100.75])
        #expect(edit.intervals.count == 2)
        #expect(Set(edit.segments.map(\.intervalID)) == Set(edit.intervals.map(\.id)))
        #expect(Set(edit.intervals.map(\.id)).isDisjoint(with: [first.intervalID, second.intervalID]))
        try verifyCommitted(edit)
        let firstOutput = try #require(edit.segments.first)
        let secondOutput = try #require(edit.segments.last)
        #expect(try sample(at: 0, in: fixture.staging.appendingPathComponent(firstOutput.fileName)) == value(at: 20_000))
        #expect(try sample(at: 11_999, in: fixture.staging.appendingPathComponent(firstOutput.fileName)) == value(at: 31_999))
        #expect(try sample(at: 0, in: fixture.staging.appendingPathComponent(secondOutput.fileName)) == value(at: 0))
        #expect(try sample(at: 51_999, in: fixture.staging.appendingPathComponent(secondOutput.fileName)) == value(at: 51_999))
        try verifyOriginal(first, in: fixture.audio)
        try verifyOriginal(second, in: fixture.audio)
    }

    @Test func replacementChunksAudioAtFiveSecondsWithDurableSidecars() throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try writeSource(in: fixture.audio, frames: 210_000, interval: UUID())
        let source = fixture.audio.appendingPathComponent(original.fileName)
        let edit = try RecordingAudioEditor.replace(from: source, staging: fixture.staging, timelineStart: 50)
        #expect(edit.duration == 13.125)
        #expect(edit.segments.map(\.frameCount) == [80_000, 80_000, 50_000])
        #expect(edit.segments.map(\.startTime) == [50, 55, 60])
        #expect(edit.segments.allSatisfy { $0.duration <= 5 })
        #expect(edit.intervals.count == 1)
        try verifyCommitted(edit)
        for (index, segment) in edit.segments.enumerated() {
            let url = fixture.staging.appendingPathComponent(segment.fileName)
            #expect(try sample(at: 0, in: url) == value(at: Int64(index) * 80_000))
        }
        try verifyOriginal(original, in: fixture.audio)
    }

    @Test(arguments: [(-1.0, 1.0), (0.0, 0.0), (2.0, 1.0), (0.0, 6.0), (Double.nan, 1.0), (0.0, Double.infinity)])
    func invalidTrimRangeCreatesNoFiles(start: Double, end: Double) throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try writeSource(in: fixture.audio, frames: 16_000, interval: UUID())
        #expect(throws: (any Error).self) {
            try RecordingAudioEditor.trim(segments: [original], audioDirectory: fixture.audio,
                staging: fixture.staging, start: start, end: end, timelineStart: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
        try verifyOriginal(original, in: fixture.audio)
    }

    @Test(arguments: [false, true])
    func missingOrCorruptLaterSourceRemovesPartialRenderedOutput(corrupt: Bool) throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try writeSource(in: fixture.audio, frames: 16_000, interval: UUID())
        let second = try writeSource(in: fixture.audio, frames: 16_000, interval: UUID(), start: 1)
        let secondURL = fixture.audio.appendingPathComponent(second.fileName)
        var corruptHash: String?
        if corrupt {
            var bytes = try Data(contentsOf: secondURL)
            bytes[bytes.count - 1] ^= 1
            try bytes.write(to: secondURL)
            corruptHash = try CaptureDurability.sha256(secondURL)
        } else { try FileManager.default.removeItem(at: secondURL) }
        #expect(throws: (any Error).self) {
            try RecordingAudioEditor.trim(segments: [first, second], audioDirectory: fixture.audio,
                staging: fixture.staging, start: 0, end: 2, timelineStart: 10)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
        try verifyOriginal(first, in: fixture.audio)
        if let corruptHash { #expect(try CaptureDurability.sha256(secondURL) == corruptHash) }
    }

    @Test(arguments: [0.0, -16_000.0, Double.infinity])
    func invalidSavedRateIsRejectedBeforeFrameArithmetic(rate: Double) throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var original = try writeSource(in: fixture.audio, frames: 16_000, interval: UUID())
        original.sampleRate = rate
        #expect(throws: (any Error).self) {
            try RecordingAudioEditor.trim(segments: [original], audioDirectory: fixture.audio,
                staging: fixture.staging, start: 0, end: 0.5, timelineStart: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
    }

    @Test func unsupportedReplacementFormatAndNonAudioDataLeaveNoStaging() throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Low requested rates can be normalized into the supported range by Core Audio.
        // Check the actual decoder format, then exercise the independent channel limit.
        let unsupported = try writeSource(in: fixture.audio, frames: 1_600, interval: UUID(), channels: 9)
        let unsupportedURL = fixture.audio.appendingPathComponent(unsupported.fileName)
        let decoded = try AVAudioFile(forReading: unsupportedURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let decodedChannels = decoded.processingFormat.channelCount
        decoded.close()
        try #require(decodedChannels > 8)
        #expect(throws: (any Error).self) {
            try RecordingAudioEditor.replace(from: unsupportedURL,
                staging: fixture.staging, timelineStart: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
        try verifyOriginal(unsupported, in: fixture.audio)
        let text = fixture.root.appendingPathComponent("unsupported.txt")
        try Data("This contains no audio frames.".utf8).write(to: text)
        #expect(throws: (any Error).self) {
            try RecordingAudioEditor.replace(from: text, staging: fixture.staging, timelineStart: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
    }

    @Test func replacementRejectsSymbolicLinks() throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try writeSource(in: fixture.audio, frames: 1_600, interval: UUID())
        let alias = fixture.root.appendingPathComponent("linked.caf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.audio.appendingPathComponent(original.fileName))
        #expect(throws: (any Error).self) {
            try RecordingAudioEditor.replace(from: alias, staging: fixture.staging, timelineStart: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
        try verifyOriginal(original, in: fixture.audio)
    }

    private func makeRoot() throws -> (root: URL, audio: URL, staging: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-AudioEdit-\(UUID().uuidString)")
        let session = root.appendingPathComponent("Session")
        let audio = session.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        return (root, audio, session.appendingPathComponent(".recording-edit-\(UUID().uuidString)"))
    }

    private func value(at frame: Int64) -> Float { Float(frame % 997) / 997 }

    private func writeSource(in directory: URL, frames: Int64, interval: UUID, start: Double = 0,
                             sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) throws -> AudioSegment {
        let format: AVAudioFormat
        if channels > 2 {
            // The channel-count convenience initializer only supports mono/stereo.
            // An explicit discrete layout creates a real, decodable multichannel CAF.
            let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        } else {
            format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384))
        let pointers = try #require(buffer.floatChannelData)
        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString).caf")
        let output = try AVAudioFile(forWriting: url, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        var written: Int64 = 0
        while written < frames {
            let count = Int(min(16_384, frames - written))
            for channel in 0..<Int(channels) {
                for index in 0..<count { pointers[channel][index] = value(at: written + Int64(index)) }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try output.write(from: buffer)
            written += Int64(count)
        }
        output.close()
        return AudioSegment(id: id, intervalID: interval, fileName: url.lastPathComponent,
            startTime: start, frameCount: frames, sampleRate: sampleRate, channelCount: Int(channels),
            sha256: try CaptureDurability.sha256(url))
    }

    private func sample(at frame: Int64, in url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { file.close() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
        file.framePosition = frame
        try file.read(into: buffer, frameCount: 1)
        let pointer = try #require(buffer.floatChannelData?[0])
        #expect(buffer.frameLength == 1)
        return pointer[0]
    }

    private func verifyOriginal(_ segment: AudioSegment, in directory: URL) throws {
        let hash = try CaptureDurability.sha256(directory.appendingPathComponent(segment.fileName))
        #expect(hash == segment.sha256)
    }

    private func verifyCommitted(_ edit: RecordingAudioEdit) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: edit.directory.path)
        #expect(files.count == edit.segments.count * 2)
        for segment in edit.segments {
            let url = edit.directory.appendingPathComponent(segment.fileName)
            let file = try AVAudioFile(forReading: url)
            #expect(file.length == segment.frameCount)
            #expect(file.processingFormat.sampleRate == segment.sampleRate)
            #expect(Int(file.processingFormat.channelCount) == segment.channelCount)
            file.close()
            let hash = try CaptureDurability.sha256(url)
            #expect(hash == segment.sha256)
            let data = try Data(contentsOf: edit.directory.appendingPathComponent("\(segment.id.uuidString).json"))
            let sidecar = try JSONDecoder().decode(AudioSegment.self, from: data)
            #expect(sidecar == segment)
        }
    }
}
