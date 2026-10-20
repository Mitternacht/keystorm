import Foundation
import SQLite3
import Testing
@testable import Keystorm

struct DocumentIntegrityTests {
    @Test(arguments: [false, true])
    func removingOneRepresentationKeepsTheVisibleFact(replace: Bool) throws {
        let factID = UUID()
        let first = BriefBlock(text: "First representation", factIDs: [factID])
        let second = BriefBlock(text: "Second representation", factIDs: [factID])
        var brief = BriefDocument()
        try brief.apply([.append(section: .goal, block: first), .append(section: .constraints, block: second)],
                        expectedRevision: brief.revisionID, label: "Add")
        let edit: BriefEdit = replace
            ? .replace(blockID: first.id, text: "An independent typed instruction", origin: .typed, sources: [])
            : .remove(blockID: first.id)
        try brief.apply([edit], expectedRevision: brief.revisionID, label: "Refine")
        #expect(!brief.removedFactIDs.contains(factID))
        try brief.apply([.remove(blockID: second.id)], expectedRevision: brief.revisionID, label: "Remove last representation")
        #expect(brief.removedFactIDs.contains(factID))
        try brief.undo()
        #expect(!brief.removedFactIDs.contains(factID))
        try brief.redo()
        #expect(brief.removedFactIDs.contains(factID))
    }

    @Test func ledgerRejectsUnicodeNormalizationOfOriginalQuotes() throws {
        let original = "Keep e\u{301} and /tmp/Exact.swift unchanged."
        let transcript = TranscriptRevision(rawText: original, text: original)
        var fact = Fact(kind: .constraint, text: original, sources: [source(transcript)])
        try LedgerValidation.validate([fact], transcripts: [transcript])
        fact.sources[0].quote = original.precomposedStringWithCanonicalMapping
        #expect(fact.sources[0].quote == original, "Swift String equality alone accepts different UTF-8 bytes.")
        #expect(throws: (any Error).self) { try LedgerValidation.validate([fact], transcripts: [transcript]) }
    }

    @Test func staleDictionarySuggestionRejectsCanonicallyEquivalentBytes() throws {
        let original = "e\u{301}"
        let suggestion = DictionarySuggestion(entryID: UUID(), original: "é", replacement: "changed",
            startUTF8: 0, endUTF8: original.utf8.count)
        #expect(throws: (any Error).self) { try Terminology.applying(suggestion, to: original) }
    }

    @Test func exportRejectsCanonicallyEquivalentSnapshotText() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var session = VoiceSession()
        var brief = BriefDocument()
        try brief.apply([.append(section: .constraints, block: BriefBlock(text: "Keep e\u{301} exactly.", exact: true))],
                        expectedRevision: brief.revisionID, label: "Exact reference")
        try brief.markReviewed(session: session)
        session.brief = brief
        let original = brief.markdown(title: session.title)
        let snapshot = ReviewedBriefSnapshot(session: session, revisionID: brief.revisionID,
            text: original.precomposedStringWithCanonicalMapping)
        #expect(snapshot.text == original)
        #expect(!snapshot.text.utf8.elementsEqual(original.utf8))
        #expect(throws: (any Error).self) {
            try BriefTransfer.prepare(snapshot, to: directory.appendingPathComponent("brief.md"), includeProvenance: false)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test(arguments: [false, true])
    func immutableTranscriptsRejectUnicodeNormalization(rawText: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(root: directory)
        let original = "Keep e\u{301} exactly."
        var session = VoiceSession()
        session.transcripts = [TranscriptRevision(rawText: original, text: original)]
        try await store.save(session)
        if rawText { session.transcripts[0].rawText = original.precomposedStringWithCanonicalMapping }
        else { session.transcripts[0].text = original.precomposedStringWithCanonicalMapping }
        await #expect(throws: (any Error).self) { try await store.save(session) }
        let restored = try #require(try await store.loadSessions().first?.transcripts.first)
        #expect(restored.rawText.utf8.elementsEqual(original.utf8))
        #expect(restored.text.utf8.elementsEqual(original.utf8))
    }

    @Test func exactReferenceBytesSurviveRestartUndoRedoArchiveAndExport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(root: directory.appendingPathComponent("Store"))
        let original = "\tlet e\u{301} = \"/tmp/Café/Exact.swift\"\r\n// Never upload 256 or 👩🏽‍💻.\n\n"
        var session = VoiceSession()
        let block = BriefBlock(text: original, exact: true)
        var brief = BriefDocument()
        try brief.apply([.append(section: .constraints, block: block)], expectedRevision: brief.revisionID, label: "Exact reference")
        session.brief = brief
        try await store.save(session)
        let reopened = try SessionStore(root: directory.appendingPathComponent("Store"))
        session = try #require(try await reopened.loadSessions().first)
        brief = try #require(session.brief)
        try brief.undo()
        try brief.redo()
        #expect(brief.block(block.id)?.text.utf8.elementsEqual(original.utf8) == true)
        #expect(brief.block(block.id)?.exact == true)
        try brief.markReviewed(session: session)
        session.brief = brief
        try await reopened.save(session)
        let archive = directory.appendingPathComponent("Exact.keystorm")
        try SessionTransfer.exportArchive(session: session, audioDirectory: await reopened.audioDirectory(session.id), to: archive)
        var imported = try await SessionTransfer.importArchive(from: archive, store: reopened)
        var importedBrief = try #require(imported.brief)
        #expect(importedBrief.block(block.id)?.text.utf8.elementsEqual(original.utf8) == true)
        #expect(!importedBrief.isReviewed)
        try importedBrief.markReviewed(session: imported)
        imported.brief = importedBrief
        let expected = importedBrief.markdown(title: imported.title)
        let snapshot = ReviewedBriefSnapshot(session: imported, revisionID: importedBrief.revisionID, text: expected)
        let output = directory.appendingPathComponent("Exact.md")
        let prepared = try BriefTransfer.prepare(snapshot, to: output, includeProvenance: true)
        try BriefTransfer.commit(prepared)
        #expect(try Data(contentsOf: output) == Data(expected.utf8))
        let provenance = try JSONDecoder().decode(BriefTransfer.Provenance.self,
            from: Data(contentsOf: output.appendingPathExtension("provenance.json")))
        #expect(provenance.brief.block(block.id)?.text.utf8.elementsEqual(original.utf8) == true)
    }

    @Test(arguments: [false, true])
    func persistedProposalsCannotUnlockProtectedReferences(remove: Bool) throws {
        var brief = BriefDocument()
        let block = BriefBlock(text: "/tmp/Exact.swift", exact: true)
        try brief.apply([.append(section: .constraints, block: block)], expectedRevision: brief.revisionID, label: "Exact reference")
        let edit: BriefEdit = remove ? .remove(blockID: block.id, allowExact: true)
            : .replace(blockID: block.id, text: "Changed", origin: .typed, sources: [], allowExact: true)
        brief.pendingProposal = BriefProposal(expectedRevision: brief.revisionID, edits: [edit], takeIDs: [], label: "Imported proposal")
        #expect(throws: BriefDocumentError.protectedLiteral) { try brief.validate(session: VoiceSession()) }
        #expect(brief.block(block.id)?.text == block.text)
    }

    @Test func corruptCatalogPayloadRecoversFromSynchronizedSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(root: directory)
        var session = VoiceSession()
        session.title = "Snapshot remains intact"
        try await store.save(session)
        var connection: OpaquePointer?
        try #require(sqlite3_open(directory.appendingPathComponent("catalog.sqlite").path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        try #require(sqlite3_exec(connection, "UPDATE sessions SET payload=X'7b'", nil, nil, nil) == SQLITE_OK)
        let reports = try await store.recover()
        #expect(reports.contains { $0.contains("catalog copy could not be read") })
        let snapshot = try await store.sessionDirectory(session.id).appendingPathComponent("session.json")
        try FileManager.default.removeItem(at: snapshot)
        let reopened = try SessionStore(root: directory)
        #expect(try await reopened.loadSessions().first?.title == session.title)
    }

    @Test(arguments: [false, true])
    func unsafeRecoverySidecarsRemainVisibleAndUncommitted(symlink: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(root: directory)
        let session = VoiceSession()
        try await store.save(session)
        let audio = try await store.audioDirectory(session.id)
        let sidecar = audio.appendingPathComponent(UUID().uuidString + ".json")
        if symlink {
            let outside = directory.appendingPathComponent("external.json")
            try Data("{}".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside)
        } else {
            let handle = try FileHandle(forWritingTo: {
                FileManager.default.createFile(atPath: sidecar.path, contents: Data())
                return sidecar
            }())
            try handle.truncate(atOffset: 257 * 1_024)
            try handle.close()
        }
        let reports = try await store.recover()
        #expect(reports.contains { $0.contains("bounded regular file") })
        #expect(try await store.loadSessions().first?.segments.isEmpty == true)
        #expect(try await store.loadSessions().first?.gaps.count == 1)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test func gapsAndUnavailableAudioRemainVisibleDuringFinish() throws {
        var session = VoiceSession()
        session.gaps = [SessionGap(reason: "The recorder stopped before saving its tail.")]
        session.unavailableSegmentIDs = [UUID()]
        var brief = BriefDocument()
        try brief.apply([.append(section: .goal, block: BriefBlock(text: "A usable typed brief"))],
                        expectedRevision: brief.revisionID, label: "Add")
        let issues = brief.reviewIssues(session: session)
        #expect(issues.contains { $0.kind == .recordingGap && $0.severity == .attention })
        #expect(issues.contains { $0.kind == .unavailableAudio && $0.severity == .attention })
        try brief.markReviewed(session: session)
    }

    @Test func untranscribedSavedAudioRequiresProcessingOrTakeDismissal() throws {
        let segment = AudioSegment(intervalID: UUID(), fileName: "fixture.caf", startTime: 0,
            frameCount: 80_000, sampleRate: 16_000, channelCount: 1, sha256: String(repeating: "0", count: 64))
        var session = VoiceSession()
        session.segments = [segment]
        var brief = BriefDocument()
        try brief.apply([.append(section: .goal, block: BriefBlock(text: "A usable typed brief"))],
                        expectedRevision: brief.revisionID, label: "Add")
        #expect(brief.reviewIssues(session: session).contains { $0.kind == .incompleteTranscription && $0.severity == .blocker })
        #expect(throws: (any Error).self) { try brief.markReviewed(session: session) }
        brief.takes = [BriefTake(intervalID: segment.intervalID, expectedRevision: brief.revisionID, status: .dismissed)]
        #expect(!brief.reviewIssues(session: session).contains { $0.kind == .incompleteTranscription })
        session.intervals = [CaptureInterval(id: segment.intervalID)]
        try brief.markReviewed(session: session)
    }

    @Test func longDecisionChainsValidateAndCyclesRemainRejected() throws {
        let transcript = TranscriptRevision(rawText: "Use a local cache.", text: "Use a local cache.")
        let quote = source(transcript)
        var facts: [Fact] = []
        for index in 0..<4_000 {
            facts.append(Fact(kind: .decision, text: "Decision \(index)", sources: [quote], supersedes: facts.last?.id))
        }
        try LedgerValidation.validate(facts, transcripts: [transcript])
        facts[0].supersedes = facts.last?.id
        #expect(throws: (any Error).self) { try LedgerValidation.validate(facts, transcripts: [transcript]) }
        facts[0].supersedes = UUID()
        #expect(throws: (any Error).self) { try LedgerValidation.validate(facts, transcripts: [transcript]) }
    }

    @Test func briefProvenanceExcludesTrashAndInactiveContentButKeepsRequiredCorrectionLineage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var session = VoiceSession()
        let originalInterval = CaptureInterval(), activeInterval = CaptureInterval(), trashInterval = CaptureInterval()
        session.intervals = [originalInterval, activeInterval, trashInterval]
        func segment(_ interval: UUID, start: Double) -> AudioSegment {
            let id = UUID()
            return AudioSegment(id: id, intervalID: interval, fileName: id.uuidString + ".caf", startTime: start,
                frameCount: 16_000, sampleRate: 16_000, channelCount: 1, sha256: String(repeating: "0", count: 64))
        }
        let originalAudio = segment(originalInterval.id, start: 0)
        let activeAudio = segment(activeInterval.id, start: 1)
        let trashAudio = segment(trashInterval.id, start: 2)
        session.segments = [originalAudio, activeAudio, trashAudio]
        let inactive = TranscriptRevision(rawText: "INACTIVE SECRET", text: "INACTIVE SECRET", segmentIDs: [originalAudio.id])
        let original = TranscriptRevision(rawText: "Keep 265 local.", text: "Keep 265 local.", segmentIDs: [activeAudio.id], startTime: 1, endTime: 2)
        let corrected = TranscriptRevision(replacesID: original.id, rawText: original.rawText, text: "Keep 256 local.",
            segmentIDs: [activeAudio.id], startTime: 1, endTime: 2)
        let trash = TranscriptRevision(rawText: "TRASH SECRET", text: "TRASH SECRET", segmentIDs: [trashAudio.id], startTime: 2, endTime: 3)
        session.transcripts = [inactive, original, corrected, trash]
        let previousFact = Fact(kind: .constraint, status: .superseded, text: inactive.text, sources: [source(inactive)])
        let currentFact = Fact(kind: .constraint, status: .confirmed, text: corrected.text, sources: [source(corrected)], supersedes: previousFact.id)
        session.facts = [previousFact, currentFact]
        let used = ContextSnapshot(title: "Selected reference", content: "Keep this reference.", sha256: String(repeating: "0", count: 64))
        let unused = ContextSnapshot(title: "Unused context", content: "UNUSED SECRET", sha256: String(repeating: "0", count: 64))
        session.contexts = [used, unused]
        var brief = BriefDocument()
        let discardedBlock = BriefBlock(text: trash.text, origin: .speech, sources: [source(trash)])
        try brief.apply([.append(section: .changes, block: discardedBlock)], expectedRevision: brief.revisionID, label: "Historical secret")
        try brief.apply([.remove(blockID: discardedBlock.id)], expectedRevision: brief.revisionID, label: "Remove historical passage")
        let visible = BriefBlock(text: corrected.text, origin: .speech, sources: [source(corrected)], contextIDs: [used.id], factIDs: [currentFact.id])
        try brief.apply([.append(section: .constraints, block: visible)], expectedRevision: brief.revisionID, label: "Current source")
        let selectedRevision = RecordingAudioRevision(label: "Replacement", intervalIDs: [activeInterval.id])
        brief.takes = [BriefTake(intervalID: originalInterval.id, expectedRevision: brief.revisionID, status: .applied,
            audioRevisions: [selectedRevision], activeAudioRevisionID: selectedRevision.id),
            BriefTake(intervalID: trashInterval.id, expectedRevision: brief.revisionID, status: .applied, name: "TRASH NAME SECRET", trashedAt: Date())]
        session.brief = brief
        try brief.markReviewed(session: session)
        session.brief = brief
        let snapshot = ReviewedBriefSnapshot(session: session, revisionID: brief.revisionID, text: brief.markdown(title: session.title))
        let prepared = try BriefTransfer.prepare(snapshot, to: directory.appendingPathComponent("Current.md"), includeProvenance: true)
        defer { BriefTransfer.discard(prepared) }
        let data = try Data(contentsOf: prepared.directory.appendingPathComponent("provenance.json"))
        let exported = try JSONDecoder().decode(BriefTransfer.Provenance.self, from: data)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("TRASH SECRET") && !text.contains("INACTIVE SECRET"))
        #expect(!text.contains("TRASH NAME SECRET") && !text.contains("UNUSED SECRET"))
        #expect(exported.version == 2 && exported.scope?.contains("current brief") == true)
        #expect(exported.brief.blocks == [visible])
        #expect(exported.brief.history.isEmpty && exported.brief.takes.isEmpty && exported.brief.journalTextBytes == 0)
        #expect(exported.transcripts == [original, corrected])
        #expect(exported.facts == [currentFact])
        #expect(exported.omittedHistoricalFactIDs == [previousFact.id])
        #expect(exported.contexts == [used] && exported.segments == [activeAudio])
        #expect(exported.brief.reviewedRevisionID == brief.reviewedRevisionID)
        #expect(session.brief?.history.isEmpty == false && session.transcripts.count == 4)
    }

    private func source(_ transcript: TranscriptRevision) -> SourceReference {
        SourceReference(transcriptID: transcript.id, startUTF8: 0, endUTF8: transcript.text.utf8.count, quote: transcript.text)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
