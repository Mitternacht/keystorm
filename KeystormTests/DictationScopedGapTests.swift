import AVFoundation
import Foundation
import Testing
@testable import Keystorm

@MainActor
struct DictationScopedGapTests {
    @Test func legacyGapDecodesWithoutScopeAndRemainsBlocking() throws {
        let fixture = metadataFixture()
        var session = fixture.session
        let legacy = SessionGap(reason: "Legacy capture interruption")
        let data = try JSONEncoder().encode(legacy)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "segmentIDs")
        object.removeValue(forKey: "intervalIDs")
        let decoded = try JSONDecoder().decode(SessionGap.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.segmentIDs == nil)
        #expect(decoded.intervalIDs == nil)
        session.gaps = [decoded]
        let error = #expect(throws: (any Error).self) {
            try WorkspaceModel.completeDictationText(in: session, takeID: fixture.takeID)
        }
        #expect(error?.localizedDescription.contains("no reliable recording scope") == true)
    }

    @Test(arguments: ["segment", "interval", "both"])
    func unrelatedKnownSourceGapDoesNotBlockSelectedTake(scope: String) throws {
        let fixture = metadataFixture()
        var session = fixture.session
        let other = segment(start: 2)
        session.segments.append(other)
        session.intervals.append(interval(other))
        let otherTake = BriefTake(intervalID: other.intervalID,
            expectedRevision: try #require(session.brief?.revisionID), status: .pending)
        session.brief?.takes.append(otherTake)
        session.unavailableSegmentIDs = [other.id]
        session.gaps = [SessionGap(reason: "Known other recording audio unavailable",
            segmentIDs: scope == "interval" ? nil : [other.id],
            intervalIDs: scope == "segment" ? nil : [other.intervalID])]
        let output = try WorkspaceModel.completeDictationText(in: session, takeID: fixture.takeID)
        #expect(output.text == "Healthy selected audio.")
        #expect(output.sourceTranscriptIDs == session.transcripts.map(\.id))
    }

    @Test(arguments: ["empty", "unknownSegment", "unknownInterval", "selectedSegment", "selectedInterval"])
    func uncertainOrSelectedGapRemainsBlocking(scope: String) throws {
        let fixture = metadataFixture()
        var session = fixture.session
        let selected = try #require(session.segments.first)
        session.gaps = [SessionGap(reason: "Source needs review",
            segmentIDs: scope == "selectedSegment" ? [selected.id] : (scope == "unknownSegment" ? [UUID()] : []),
            intervalIDs: scope == "selectedInterval" ? [selected.intervalID] : (scope == "unknownInterval" ? [UUID()] : []))]
        #expect(throws: (any Error).self) {
            try WorkspaceModel.completeDictationText(in: session, takeID: fixture.takeID)
        }
    }

    @Test func missingOriginalRecoveryAllowsHealthyReplacementButStillBlocksOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-ScopedGap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        let audio = try await store.audioDirectory(session.id)
        let original = try writeAudio(in: audio)
        session.segments = [original]
        session.intervals = [interval(original)]
        var brief = BriefDocument()
        let take = BriefTake(intervalID: original.intervalID, expectedRevision: brief.revisionID, status: .pending)
        brief.takes = [take]
        session.brief = brief
        session.dictation = DictationSession(recordings: [DictationRecordingMetadata(id: take.id, state: .captured)])
        try await store.save(session)
        try FileManager.default.removeItem(at: audio.appendingPathComponent(original.fileName))
        _ = try await store.recover()
        let recovered = try #require(try await store.loadSessions().first)
        #expect(recovered.gaps.count == 1)
        #expect(recovered.gaps.first?.segmentIDs == [original.id])
        #expect(recovered.gaps.first?.intervalIDs == [original.intervalID])
        #expect(throws: (any Error).self) {
            try WorkspaceModel.completeDictationText(in: recovered, takeID: take.id)
        }
        let reopened = try SessionStore(root: root)
        #expect(try await reopened.loadSessions().first?.gaps == recovered.gaps)
        let model = WorkspaceModel(root: root, modelDirectory: root.appendingPathComponent("Models"))
        await model.initialize(loadLibrary: true)
        do {
            let imported = try writeAudio(in: root)
            let handle = DictationRecordingHandle(sessionID: session.id, takeID: take.id)
            try await model.dictationReplaceRecording(handle, from: root.appendingPathComponent(imported.fileName))
            var replaced = try #require(model.sessions.first(where: { $0.id == session.id }))
            let selectedTake = try #require(replaced.brief?.takes.first)
            let selectedAudio = replaced.takeSegments(selectedTake)
            let first = try #require(selectedAudio.first)
            let last = try #require(selectedAudio.last)
            let transcript = TranscriptRevision(rawText: "Healthy replacement audio.", text: "Healthy replacement audio.",
                segmentIDs: selectedAudio.map(\.id), startTime: first.startTime, endTime: last.endTime, timingPrecision: .window)
            replaced.transcripts = [transcript]
            replaced.brief?.takes[0].transcriptIDs = [transcript.id]
            let output = try WorkspaceModel.completeDictationText(in: replaced, takeID: take.id)
            #expect(output.text == "Healthy replacement audio.")
            #expect(output.sourceTranscriptIDs == [transcript.id])
            #expect(replaced.unavailableSegmentIDs.contains(original.id))
            #expect(replaced.gaps == recovered.gaps)
            replaced.brief?.takes[0].activeAudioRevisionID = nil
            #expect(throws: (any Error).self) {
                try WorkspaceModel.completeDictationText(in: replaced, takeID: take.id)
            }
            await model.stopForTermination()
        } catch {
            await model.stopForTermination()
            throw error
        }
    }

    private func metadataFixture() -> (session: VoiceSession, takeID: UUID) {
        var session = VoiceSession()
        let source = segment(start: 0)
        session.segments = [source]
        session.intervals = [interval(source)]
        let transcript = TranscriptRevision(rawText: "Healthy selected audio.", text: "Healthy selected audio.",
            segmentIDs: [source.id], startTime: source.startTime, endTime: source.endTime, timingPrecision: .window)
        session.transcripts = [transcript]
        var brief = BriefDocument()
        let take = BriefTake(intervalID: source.intervalID, expectedRevision: brief.revisionID,
            status: .pending, transcriptIDs: [transcript.id])
        brief.takes = [take]
        session.brief = brief
        return (session, take.id)
    }

    private func segment(start: Double) -> AudioSegment {
        let id = UUID()
        return AudioSegment(id: id, intervalID: UUID(), fileName: id.uuidString + ".caf", startTime: start,
            frameCount: 160, sampleRate: 16_000, channelCount: 1, sha256: String(repeating: "a", count: 64))
    }

    private func interval(_ source: AudioSegment) -> CaptureInterval {
        CaptureInterval(id: source.intervalID, endedAt: Date(), sampleRate: source.sampleRate, channelCount: source.channelCount)
    }

    private func writeAudio(in directory: URL) throws -> AudioSegment {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<160 { samples[index] = Float(index % 17) / 100 }
        var source = segment(start: 0)
        let url = directory.appendingPathComponent(source.fileName)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        file.close()
        source.sha256 = try CaptureDurability.sha256(url)
        try JSONEncoder().encode(source).write(to: directory.appendingPathComponent(source.id.uuidString + ".json"))
        return source
    }
}
