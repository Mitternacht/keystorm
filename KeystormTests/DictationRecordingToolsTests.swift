import AVFoundation
import Foundation
import Testing
@testable import Keystorm

@MainActor
struct DictationRecordingToolsTests {
    @Test func stableHandleEditsOnlyItsRecordingAndInvalidatesCurrentOutput() async throws {
        let fixture = try await makeFixture()
        let model = WorkspaceModel(root: fixture.root, modelDirectory: fixture.root.appendingPathComponent("Models"))
        await model.initialize(loadLibrary: true)
        model.selectedSessionID = fixture.other.id
        do {
            try await model.dictationTrimRecording(fixture.handle, start: 0.25, end: 0.75)
            #expect(model.selectedSessionID == fixture.session.id)
            let row = try model.dictationRecordingForTools(fixture.handle)
            #expect(row.duration == 0.5)
            #expect(row.segments.reduce(0) { $0 + $1.frameCount } == 8_000)
            let changed = try #require(model.sessions.first(where: { $0.id == fixture.session.id }))
            let metadata = try #require(changed.dictation?.recordings.first)
            #expect(metadata.state == .captured)
            #expect(metadata.textRevision == nil)
            #expect(metadata.activeOutputID == nil)
            #expect(metadata.delivery == nil)
            #expect(metadata.outputHistory?.contains(where: { $0.textRevision == fixture.revision }) == true)
            #expect(changed.transcripts == fixture.session.transcripts)
            #expect(model.sessions.first(where: { $0.id == fixture.other.id }) == fixture.other)
            for segment in fixture.session.segments {
                #expect(try CaptureDurability.sha256(fixture.audio.appendingPathComponent(segment.fileName)) == segment.sha256)
            }
            let durable = try SessionStore(root: fixture.root)
            let persisted = try #require(try await durable.loadSessions().first(where: { $0.id == fixture.session.id }))
            #expect(persisted.dictation?.recordings.first?.textRevision == nil)
            #expect(persisted.dictation?.recordings.first?.outputHistory == metadata.outputHistory)
            await model.stopForTermination()
            try? FileManager.default.removeItem(at: fixture.root)
        } catch {
            await model.stopForTermination()
            try? FileManager.default.removeItem(at: fixture.root)
            throw error
        }
    }

    @Test func mismatchedSessionAndTakeCannotRetargetAnAudioAction() async throws {
        let fixture = try await makeFixture()
        let model = WorkspaceModel(root: fixture.root, modelDirectory: fixture.root.appendingPathComponent("Models"))
        await model.initialize(loadLibrary: true)
        model.selectedSessionID = fixture.other.id
        let wrong = DictationRecordingHandle(sessionID: fixture.other.id, takeID: fixture.handle.takeID)
        await #expect(throws: (any Error).self) {
            try await model.dictationTrimRecording(wrong, start: 0, end: 0.5)
        }
        #expect(model.selectedSessionID == fixture.other.id)
        #expect(model.sessions.first(where: { $0.id == fixture.session.id }) == fixture.session)
        #expect(model.sessions.first(where: { $0.id == fixture.other.id }) == fixture.other)
        await model.stopForTermination()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @Test func invalidTrimDoesNotInvalidateTextOrCreateAnAudioVersion() async throws {
        let fixture = try await makeFixture()
        let model = WorkspaceModel(root: fixture.root, modelDirectory: fixture.root.appendingPathComponent("Models"))
        await model.initialize(loadLibrary: true)
        await #expect(throws: (any Error).self) {
            try await model.dictationTrimRecording(fixture.handle, start: 0.8, end: 0.2)
        }
        let row = try #require(model.sessions.first(where: { $0.id == fixture.session.id }))
        #expect(row.dictation?.recordings.first?.textRevision == fixture.revision)
        #expect(row.brief?.takes.first?.audioRevisions?.isEmpty ?? true)
        #expect(row.segments == fixture.session.segments)
        await model.stopForTermination()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @Test func replaceRestoreAndPortableExportPreserveAllSources() async throws {
        let fixture = try await makeFixture()
        let model = WorkspaceModel(root: fixture.root, modelDirectory: fixture.root.appendingPathComponent("Models"))
        await model.initialize(loadLibrary: true)
        do {
            let replacement = try writeAudio(in: fixture.root, frames: 8_000)
            let replacementURL = fixture.root.appendingPathComponent(replacement.fileName)
            try await model.dictationReplaceRecording(fixture.handle, from: replacementURL)
            let replaced = try model.dictationRecordingForTools(fixture.handle)
            #expect(replaced.duration == 0.5)
            #expect(replaced.take.audioRevisions?.count == 1)
            #expect(replaced.take.activeAudioRevisionID != nil)
            try await model.dictationRestoreRecording(fixture.handle, revisionID: nil)
            let restored = try model.dictationRecordingForTools(fixture.handle)
            #expect(restored.segments.map(\.id) == fixture.session.segments.map(\.id))
            #expect(restored.duration == 1)
            #expect(model.dictationMetadata(fixture.handle)?.state == .captured)
            #expect(model.dictationMetadata(fixture.handle)?.textRevision == nil)
            #expect(model.dictationMetadata(fixture.handle)?.outputHistory?.contains(where: { $0.textRevision == fixture.revision }) == true)
            let destination = fixture.root.appendingPathComponent("Export.keystorm")
            try await model.dictationExportRecordingArchive(fixture.handle, to: destination)
            let exported = try JSONDecoder().decode(VoiceSession.self, from: Data(contentsOf: destination.appendingPathComponent("session.json")))
            #expect(exported.id == fixture.session.id)
            #expect(exported.segments.count == 2)
            #expect(exported.brief?.takes.first?.audioRevisions?.count == 1)
            for segment in exported.segments {
                #expect(try CaptureDurability.sha256(destination.appendingPathComponent("Audio/" + segment.fileName)) == segment.sha256)
            }
            #expect(try CaptureDurability.sha256(replacementURL) == replacement.sha256)
            await model.stopForTermination()
            try? FileManager.default.removeItem(at: fixture.root)
        } catch {
            await model.stopForTermination()
            try? FileManager.default.removeItem(at: fixture.root)
            throw error
        }
    }

    private struct Fixture {
        var root: URL
        var audio: URL
        var session: VoiceSession
        var other: VoiceSession
        var handle: DictationRecordingHandle
        var revision: DictationTextRevision
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-RecordingTools-\(UUID())")
        let store = try SessionStore(root: root)
        var session = VoiceSession()
        session.title = "Dictation tools source"
        let audio = try await store.audioDirectory(session.id)
        let source = try writeAudio(in: audio, frames: 16_000)
        session.segments = [source]
        session.intervals = [CaptureInterval(id: source.intervalID, endedAt: Date(), sampleRate: source.sampleRate, channelCount: source.channelCount)]
        let transcript = TranscriptRevision(rawText: "Keep die Rechnung local.", text: "Keep die Rechnung local.",
            segmentIDs: [source.id], startTime: 0, endTime: 1, timingPrecision: .window)
        session.transcripts = [transcript]
        var brief = BriefDocument()
        let take = BriefTake(intervalID: source.intervalID, expectedRevision: brief.revisionID,
            status: .pending, transcriptIDs: [transcript.id])
        brief.takes = [take]
        session.brief = brief
        let revision = DictationTextRevision(rawText: transcript.rawText, text: transcript.text, sourceTranscriptIDs: [transcript.id])
        session.dictation = DictationSession(recordings: [DictationRecordingMetadata(id: take.id, state: .ready,
            textRevision: revision, delivery: DictationDelivery(requestID: UUID(), textRevisionID: revision.id,
                targetLabel: "Synthetic target", state: .inserted))])
        var other = VoiceSession()
        other.title = "Unrelated dictation"
        let otherBrief = BriefDocument()
        let otherTake = BriefTake(expectedRevision: otherBrief.revisionID, status: .pending)
        var otherDocument = otherBrief
        otherDocument.takes = [otherTake]
        other.brief = otherDocument
        other.dictation = DictationSession(recordings: [DictationRecordingMetadata(id: otherTake.id, state: .captured)])
        try await store.save(session)
        try await store.save(other)
        return Fixture(root: root, audio: audio, session: session, other: other,
            handle: DictationRecordingHandle(sessionID: session.id, takeID: take.id), revision: revision)
    }

    private func writeAudio(in directory: URL, frames: Int64) throws -> AudioSegment {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let pointer = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) { pointer[index] = Float(index % 31) / 100 }
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString + ".caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        file.close()
        let segment = AudioSegment(id: id, intervalID: UUID(), fileName: url.lastPathComponent, startTime: 0,
            frameCount: frames, sampleRate: 16_000, channelCount: 1, sha256: try CaptureDurability.sha256(url))
        try JSONEncoder().encode(segment).write(to: directory.appendingPathComponent(id.uuidString + ".json"))
        return segment
    }
}
