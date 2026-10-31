import AVFoundation
import Foundation
import Testing
@testable import Keystorm

/// A crash or force quit leaves the writer's open segment as `<id>.partial.caf`. Reopening the session rebuilds it
/// into a committed segment instead of leaving up to five seconds of speech unread. Everything here lives in a
/// unique temporary directory; no real Application Support store is touched.
struct PartialSegmentSalvageTests {
    @Test("A crashed dictation recovers its open tail as a committed segment and can still finish")
    func salvagesTheOpenTail() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let (session, interval) = crashedDictation()
        try await store.save(session)
        let tail = try await writeTail(store: store, sessionID: session.id, seconds: 1.5)

        let reports = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        let segment = try #require(recovered.segments.first)
        #expect(recovered.segments.count == 1)
        #expect(segment.id == tail.id)
        #expect(segment.intervalID == interval.id)
        #expect(segment.startTime == 0)
        #expect(segment.frameCount == 24_000)
        #expect(segment.sampleRate == 16_000 && segment.channelCount == 1)
        #expect(recovered.status == .interrupted)
        // The take can finish with what it saved, so no unscoped gap blocks it.
        #expect(recovered.gaps.isEmpty)
        #expect(reports.contains { $0.contains("recovered 1.5 s of audio") })

        let directory = try await store.audioDirectory(session.id)
        let final = directory.appendingPathComponent("\(tail.id.uuidString).caf")
        let audio = try AVAudioFile(forReading: final)
        #expect(audio.length == 24_000)
        #expect(try SessionStore.checksum(final) == segment.sha256)
        let sidecar = try JSONDecoder().decode(AudioSegment.self,
            from: Data(contentsOf: directory.appendingPathComponent("\(tail.id.uuidString).json")))
        #expect(sidecar == segment)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains(tail.url.lastPathComponent))
        #expect(names.contains(tail.url.lastPathComponent + ".salvaged"))
        #expect(!names.contains { $0.hasSuffix(".salvage.caf") || $0.hasSuffix(".tmp") })

        // Recovering again changes nothing and does not flag the preserved original as a new tail.
        _ = try await store.recover()
        let again = try #require(try await store.loadSessions().first)
        #expect(again.segments == recovered.segments)
        #expect(again.gaps.isEmpty)
    }

    @Test("A salvaged tail continues the timeline after the interval's last committed segment")
    func tailFollowsCommittedAudio() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let fixture = crashedDictation()
        var session = fixture.session
        let interval = fixture.interval
        let committed = try await committedSegment(store: store, sessionID: session.id, intervalID: interval.id,
                                                   start: 0, seconds: 5)
        session.segments = [committed]
        try await store.save(session)
        let tail = try await writeTail(store: store, sessionID: session.id, seconds: 2)

        _ = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.segments.count == 2)
        let salvaged = try #require(recovered.segments.first { $0.id == tail.id })
        #expect(salvaged.startTime == 5)
        #expect(salvaged.frameCount == 32_000)
        #expect(salvaged.intervalID == interval.id)
        #expect(abs(committed.endTime - salvaged.startTime) <= 1 / committed.sampleRate)
        #expect(recovered.gaps.isEmpty)
    }

    @Test("A crashed developer brief keeps its interruption gap even when a tail is recovered")
    func briefKeepsItsGap() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.status = .recording
        session.intervals = [CaptureInterval(sampleRate: 16_000, channelCount: 1)]
        try await store.save(session)
        let tail = try await writeTail(store: store, sessionID: session.id, seconds: 1)

        _ = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.segments.map(\.id) == [tail.id])
        #expect(recovered.gaps.contains { $0.reason.contains("Recording was interrupted") })
        #expect(!recovered.gaps.contains { $0.reason.contains("Incomplete audio tail") })
    }

    @Test("A tail with no open interval is left alone and flagged as an incomplete tail")
    func tailWithoutOpenIntervalIsNotAdopted() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.intervals = [CaptureInterval(endedAt: Date(), sampleRate: 16_000, channelCount: 1)]
        try await store.save(session)
        let tail = try await writeTail(store: store, sessionID: session.id, seconds: 1)

        _ = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.segments.isEmpty)
        #expect(recovered.gaps.contains { $0.reason.contains("Incomplete audio tail") })
        #expect(FileManager.default.fileExists(atPath: tail.url.path))
    }

    @Test("A tail in another format than the interval's committed audio is left alone")
    func mismatchedFormatIsNotAdopted() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let fixture = crashedDictation()
        var session = fixture.session
        let interval = fixture.interval
        session.segments = [try await committedSegment(store: store, sessionID: session.id, intervalID: interval.id,
                                                       start: 0, seconds: 5)]
        try await store.save(session)
        let tail = try await writeTail(store: store, sessionID: session.id, seconds: 1, sampleRate: 48_000)

        _ = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.segments.count == 1)
        #expect(!recovered.segments.contains { $0.id == tail.id })
        #expect(recovered.gaps.contains { $0.reason.contains("Incomplete audio tail") })
        #expect(FileManager.default.fileExists(atPath: tail.url.path))
    }

    // MARK: Fixtures

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-Salvage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A dictation that was recording when the app died: one open interval and an open take.
    private func crashedDictation() -> (session: VoiceSession, interval: CaptureInterval) {
        var session = VoiceSession()
        session.status = .recording
        let interval = CaptureInterval(sampleRate: 16_000, channelCount: 1)
        session.intervals = [interval]
        var brief = BriefDocument()
        brief.takes = [BriefTake(intervalID: interval.id, expectedRevision: brief.revisionID, status: .recording)]
        session.brief = brief
        session.dictation = DictationSession(recordings: [
            DictationRecordingMetadata(id: brief.takes[0].id, state: .recording)
        ])
        return (session, interval)
    }

    private func samples(seconds: Double, sampleRate: Double) throws -> (AVAudioFormat, AVAudioPCMBuffer) {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                channels: 1, interleaved: false))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData?[0].update(repeating: 0.25, count: Int(frames))
        return (format, buffer)
    }

    /// What the writer leaves behind mid-segment: a CAF named `<id>.partial.caf`, with no sidecar.
    private func writeTail(store: SessionStore, sessionID: UUID, seconds: Double,
                           sampleRate: Double = 16_000) async throws -> (id: UUID, url: URL) {
        let id = UUID()
        let url = try await store.audioDirectory(sessionID).appendingPathComponent("\(id.uuidString).partial.caf")
        let (format, buffer) = try samples(seconds: seconds, sampleRate: sampleRate)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        return (id, url)
    }

    /// A normally committed segment with its sidecar, as the writer produces.
    private func committedSegment(store: SessionStore, sessionID: UUID, intervalID: UUID,
                                  start: Double, seconds: Double) async throws -> AudioSegment {
        let id = UUID()
        let directory = try await store.audioDirectory(sessionID)
        let url = directory.appendingPathComponent("\(id.uuidString).caf")
        let (format, buffer) = try samples(seconds: seconds, sampleRate: 16_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        let segment = AudioSegment(id: id, intervalID: intervalID, fileName: url.lastPathComponent,
            startTime: start, frameCount: Int64(buffer.frameLength), sampleRate: 16_000, channelCount: 1,
            sha256: try SessionStore.checksum(url))
        try JSONEncoder().encode(segment).write(to: directory.appendingPathComponent("\(id.uuidString).json"))
        return segment
    }
}
