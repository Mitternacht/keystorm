import AVFoundation
import Foundation
import Testing
@testable import Keystorm

struct DictationSessionTests {
    @Test func `Legacy JSON and recording projection preserve archived identities`() throws {
        let original = fixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacyBytes = try encoder.encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: legacyBytes) as? [String: Any])
        #expect(object["dictation"] == nil)
        var decoded = try JSONDecoder().decode(VoiceSession.self, from: legacyBytes)
        #expect(decoded.dictation == nil)
        #expect(decoded == original)
        #expect(try encoder.encode(decoded) == legacyBytes)

        let projected = decoded.recordings
        #expect(decoded == original)
        #expect(projected.map(\.id) == original.brief?.takes.map(\.id))
        #expect(projected.first?.captureIntervalIDs == Array(original.intervals.prefix(2)).map(\.id))
        #expect(projected.first?.activeIntervalIDs == [original.intervals[2].id])
        #expect(projected.first?.allIntervalIDs == original.intervals.map(\.id))
        #expect(projected.first?.audioRevisions == original.brief?.takes.first?.audioRevisions)
        #expect(projected.first?.activeAudioRevisionID == original.brief?.takes.first?.activeAudioRevisionID)
        let didMaterialize1 = decoded.materializeDictationMetadata()
        #expect(didMaterialize1)
        let materialized = decoded
        let didMaterialize2 = decoded.materializeDictationMetadata()
        #expect(!didMaterialize2)
        #expect(decoded == materialized)
        #expect(decoded.brief == original.brief)
        #expect(decoded.intervals == original.intervals)
        #expect(decoded.segments == original.segments)
        #expect(decoded.transcripts == original.transcripts)
        #expect(decoded.currentTranscripts == original.currentTranscripts)
        #expect(decoded.inactiveRecordingIntervalIDs == original.inactiveRecordingIntervalIDs)
        #expect(decoded.dictation?.recordings.map(\.id) == original.brief?.takes.map(\.id))
        try decoded.validateDictationMetadata()
    }

    @Test func `A dictation session can be persisted before microphone capture`() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var session = VoiceSession()
        let didMaterialize3 = session.materializeDictationMetadata()
        #expect(didMaterialize3)
        #expect(session.dictation == DictationSession())
        let didMaterialize4 = session.materializeDictationMetadata()
        #expect(!didMaterialize4)
        #expect(session.brief == nil)
        #expect(session.recordings.isEmpty)
        try session.validateDictationMetadata()
        let store = try SessionStore(root: root)
        try await store.save(session)
        let reopened = try SessionStore(root: root)
        #expect(try await reopened.loadSessions() == [session])
    }

    private static let statusCases: [(BriefTakeStatus, DictationRecordingState)] = [
        (.recording, .recording), (.paused, .paused), (.pending, .ready),
        (.applied, .ready), (.failed, .failed), (.discarded, .cancelled), (.dismissed, .cancelled)
    ]

    @Test(arguments: statusCases)
    func `Legacy capture statuses project without changing the take`(status: BriefTakeStatus,
                                                                     expected: DictationRecordingState) throws {
        var session = fixture()
        session.brief?.takes[0].status = status
        let originalTake = session.brief?.takes[0]
        let didMaterialize5 = session.materializeDictationMetadata()
        #expect(didMaterialize5)
        #expect(session.dictation?.recordings.first?.state == expected)
        #expect(session.recordings.first?.state == expected)
        #expect(session.recordings.first?.legacyStatus == status)
        #expect(session.brief?.takes.first == originalTake)
        try session.validateDictationMetadata()
    }

    @Test func `Partial transcription does not make a resumed recording ready`() {
        var session = fixture()
        session.brief?.takes[0].activeAudioRevisionID = nil
        let firstSegmentID = session.segments[0].id
        session.transcripts.removeAll { $0.segmentIDs != [firstSegmentID] }
        session.brief?.takes[0].transcriptIDs = session.transcripts.map(\.id)
        let didMaterialize6 = session.materializeDictationMetadata()
        #expect(didMaterialize6)
        #expect(session.recordings.first?.captureIntervalIDs.count == 2)
        #expect(session.dictation?.recordings.first?.state == .captured)
        #expect(session.recordings.first?.state == .captured)
    }

    @Test func `Metadata keeps caller transitions and imports later takes only once`() throws {
        var session = fixture()
        session.materializeDictationMetadata()
        let id = try #require(session.brief?.takes.first?.id)
        session.dictation?.recordings[0].state = .processing
        session.dictation?.recordings[0].failureMessage = "Previous retry was interrupted."
        session.dictation?.recordings[0].delivery = DictationDelivery(requestID: UUID(),
            targetLabel: "Notes", state: .targetChanged)
        let metadata = session.dictation?.recordings[0]
        let didMaterialize7 = session.materializeDictationMetadata()
        #expect(!didMaterialize7)
        #expect(session.dictation?.recordings[0] == metadata)
        #expect(session.recordings.first?.id == id)
        #expect(session.recordings.first?.state == .processing)
        let later = BriefTake(expectedRevision: try #require(session.brief?.revisionID))
        session.brief?.takes.append(later)
        let didMaterialize8 = session.materializeDictationMetadata()
        #expect(didMaterialize8)
        let didMaterialize9 = session.materializeDictationMetadata()
        #expect(!didMaterialize9)
        #expect(session.dictation?.recordings.map(\.id) == [id, later.id])
        #expect(session.dictation?.recordings.first == metadata)
        try session.validateDictationMetadata()
    }

    @Test func `Trash and selected audio versions retain existing source exclusion`() throws {
        var session = fixture()
        let baseline = session
        session.materializeDictationMetadata()
        #expect(session.currentTranscripts.map(\.id) == [baseline.transcripts[2].id])
        #expect(session.availableSegments.map(\.id) == [baseline.segments[2].id])
        #expect(session.recordings.first?.allIntervalIDs == baseline.intervals.map(\.id))
        session.brief?.takes[0].trashedAt = Date(timeIntervalSinceReferenceDate: 123)
        let takeTrash = session
        #expect(session.recordings.first?.trashedAt == Date(timeIntervalSinceReferenceDate: 123))
        #expect(session.currentTranscripts.isEmpty)
        #expect(session.availableSegments.isEmpty)
        #expect(session.segments == baseline.segments)
        #expect(session.transcripts == baseline.transcripts)
        #expect(session == takeTrash)
        session.brief?.takes[0].trashedAt = nil
        #expect(session.currentTranscripts == baseline.currentTranscripts)
        #expect(session.availableSegments == baseline.availableSegments)
        session.trashedAt = Date(timeIntervalSinceReferenceDate: 456)
        #expect(session.recordings.first?.trashedAt == session.trashedAt)
        #expect(session.currentTranscripts.isEmpty)
        #expect(session.availableSegments.isEmpty)
        try session.validateDictationMetadata()
    }

    @Test func `Mixed language output and delivery receipts survive reopening without touching audio`() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = fixture()
        let directory = try await store.audioDirectory(session.id)
        for index in session.segments.indices {
            let url = directory.appendingPathComponent(session.segments[index].fileName)
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000, channels: 1, interleaved: false))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
            buffer.frameLength = 160
            buffer.floatChannelData?[0].initialize(repeating: Float(index) / 10, count: 160)
            let audio = try AVAudioFile(forWriting: url, settings: format.settings)
            try audio.write(from: buffer)
            audio.close()
            session.segments[index].sha256 = try SessionStore.checksum(url)
        }
        let originalBytes = try session.segments.map { try Data(contentsOf: directory.appendingPathComponent($0.fileName)) }
        try await store.save(session)
        let original = session
        session.materializeDictationMetadata()
        let raw = "Please update die Datenschutzerklärung and send it übermorgen."
        session.dictation?.recordings[0].state = .ready
        let sourceTranscriptIDs = session.currentTranscripts.map(\.id)
        session.dictation?.recordings[0].textRevision = DictationTextRevision(rawText: raw, text: raw,
            sourceTranscriptIDs: sourceTranscriptIDs)
        let requestID = UUID()
        session.dictation?.recordings[0].delivery = DictationDelivery(requestID: requestID,
            targetLabel: "TextEdit", state: .uncertain, detail: "No duplicate insertion was attempted.")
        try session.validateDictationMetadata()
        try await store.save(session)
        let reopened = try SessionStore(root: root)
        let restored = try #require(try await reopened.loadSessions().first)
        #expect(restored == session)
        #expect(restored.dictation?.recordings.first?.languagePolicy == .mixedEnglishGerman)
        #expect(restored.dictation?.recordings.first?.outputMode == .verbatim)
        #expect(restored.dictation?.recordings.first?.textRevision?.rawText.utf8.elementsEqual(raw.utf8) == true)
        #expect(restored.dictation?.recordings.first?.textRevision?.text.utf8.elementsEqual(raw.utf8) == true)
        #expect(restored.dictation?.recordings.first?.delivery?.requestID == requestID)
        #expect(restored.dictation?.recordings.first?.delivery?.state == .uncertain)
        #expect(restored.brief == original.brief)
        #expect(restored.segments == original.segments)
        #expect(restored.transcripts == original.transcripts)
        for (index, segment) in restored.segments.enumerated() {
            #expect(try Data(contentsOf: directory.appendingPathComponent(segment.fileName)) == originalBytes[index])
        }
    }

    @Test func `Metadata rejects detached identities and missing transcript sources`() throws {
        var session = fixture()
        session.materializeDictationMetadata()
        session.dictation?.recordings[0].id = UUID()
        #expect(throws: (any Error).self) { try session.validateDictationMetadata() }
        session.dictation?.recordings[0].id = try #require(session.brief?.takes.first?.id)
        session.dictation?.recordings[0].textRevision = DictationTextRevision(rawText: "Hallo", text: "Hallo",
            sourceTranscriptIDs: [UUID()])
        #expect(throws: (any Error).self) { try session.validateDictationMetadata() }
        session.dictation?.recordings[0].textRevision = nil
        let duplicate = try #require(session.dictation?.recordings[0])
        session.dictation?.recordings.append(duplicate)
        #expect(throws: (any Error).self) { try session.validateDictationMetadata() }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Dictation-\(UUID().uuidString)",
                                                                     isDirectory: true)
    }

    private func fixture() -> VoiceSession {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        var session = VoiceSession()
        session.createdAt = date
        session.updatedAt = date
        session.intervals = (0..<3).map { index in
            CaptureInterval(startedAt: date.addingTimeInterval(Double(index)),
                endedAt: date.addingTimeInterval(Double(index + 1)), sampleRate: 16_000, channelCount: 1)
        }
        session.segments = session.intervals.enumerated().map { index, interval in
            let id = UUID()
            return AudioSegment(id: id, intervalID: interval.id, fileName: "\(id.uuidString).caf",
                startTime: Double(index) * 0.01, frameCount: 160, sampleRate: 16_000, channelCount: 1,
                sha256: String(repeating: "0", count: 64), committedAt: date)
        }
        session.transcripts = session.segments.enumerated().map { index, segment in
            TranscriptRevision(createdAt: date, rawText: "Source \(index)", text: "Source \(index)",
                segmentIDs: [segment.id], startTime: segment.startTime, endTime: segment.endTime)
        }
        var brief = BriefDocument()
        let version = RecordingAudioRevision(createdAt: date, label: "Trimmed",
            intervalIDs: [session.intervals[2].id])
        brief.takes = [BriefTake(intervalID: session.intervals[0].id,
            intervalIDs: [session.intervals[1].id], expectedRevision: brief.revisionID,
            transcriptIDs: session.transcripts.map(\.id), createdAt: date,
            audioRevisions: [version], activeAudioRevisionID: version.id)]
        session.brief = brief
        return session
    }
}
