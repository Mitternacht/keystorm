import AVFoundation
import Foundation
import Testing
@testable import Keystorm

struct PromptTests {
    @Test func `Source quotes require exact UTF8 boundaries and original text`() throws {
        let transcript = TranscriptRevision(rawText: "Ä use 256, not 512.", text: "Ä use 256, not 512.")
        let valid = Fact(kind: .constraint, status: .confirmed, text: "Use 256, not 512.",
            sources: [SourceReference(transcriptID: transcript.id, startUTF8: 3, endUTF8: 20, quote: "use 256, not 512.")])
        // Use the actual UTF8 length rather than assuming a character index equals a byte index.
        var fact = valid
        fact.sources[0].endUTF8 = transcript.text.utf8.count
        try LedgerValidation.validate([fact], transcripts: [transcript])
        fact.sources[0].startUTF8 = 1
        #expect(throws: (any Error).self) { try LedgerValidation.validate([fact], transcripts: [transcript]) }
        fact.sources[0] = SourceReference(transcriptID: transcript.id, startUTF8: 3,
            endUTF8: transcript.text.utf8.count, quote: "use 512, not 256.")
        #expect(throws: (any Error).self) { try LedgerValidation.validate([fact], transcripts: [transcript]) }
    }

    @Test func `Brief rendering retains numbers and negations while exposing omitted examples`() throws {
        var session = VoiceSession()
        let requirement = "Use 256, not 512; never overwrite /tmp/Keystorm_v2."
        let example = "For example, preserve Q8_0 in the manifest."
        let transcript = TranscriptRevision(rawText: requirement + "\n" + example, text: requirement + "\n" + example)
        let constraint = sourcedFact(requirement, kind: .constraint, transcript: transcript)
        let illustration = sourcedFact(example, kind: .example, transcript: transcript)
        session.transcripts = [transcript]
        session.facts = [constraint, illustration]
        let draft = try PromptComposer.compose(session: session, detail: .brief, configurationID: nil)
        #expect(draft.text.contains(requirement))
        #expect(!draft.text.contains(example))
        #expect(draft.factIDs == [constraint.id])
        #expect(draft.dispositions.contains { $0.factID == illustration.id && $0.disposition == "omitted for selected detail" })
        #expect(draft.dispositions.count == 2)
    }

    @Test func `Exploration and ambiguity remain separate from confirmed instructions`() throws {
        var session = VoiceSession()
        let transcript = TranscriptRevision(rawText: "Maybe use SQLite. Decide whether to support two speakers.",
            text: "Maybe use SQLite. Decide whether to support two speakers.")
        var idea = sourcedFact("Maybe use SQLite.", kind: .decision, transcript: transcript)
        idea.status = .exploratory
        var question = sourcedFact("Decide whether to support two speakers.", kind: .question, transcript: transcript)
        question.status = .ambiguous
        session.transcripts = [transcript]
        session.facts = [idea, question]
        let draft = try PromptComposer.compose(session: session, detail: .standard, configurationID: nil)
        #expect(draft.text.contains("Exploratory ideas (not instructions)"))
        #expect(draft.text.contains("Needs clarification"))
        #expect(!draft.text.contains("## Confirmed decisions"))
    }

    @Test func `Only reviewed explicit reversals supersede an earlier decision`() throws {
        var session = VoiceSession()
        let transcript = TranscriptRevision(rawText: "Use 256. Correction: use 512 for the cache only.",
            text: "Use 256. Correction: use 512 for the cache only.")
        let old = sourcedFact("Use 256.", kind: .decision, transcript: transcript)
        var reversal = sourcedFact("Correction: use 512 for the cache only.", kind: .decision, transcript: transcript)
        reversal.supersedes = old.id
        session.transcripts = [transcript]
        session.facts = [old, reversal]
        #expect(LedgerValidation.currentFacts(in: session).contains { $0.id == old.id })
        session.facts[1].reviewed = true
        let draft = try PromptComposer.compose(session: session, detail: .detailed, configurationID: nil)
        #expect(!draft.factIDs.contains(old.id))
        #expect(draft.factIDs.contains(reversal.id))
        #expect(draft.text.contains("for the cache only"))
        #expect(draft.dispositions.contains { $0.factID == old.id && $0.disposition != "included" })
    }

    @Test func `Corrections and undo append revisions and invalidate old draft coverage`() throws {
        var session = VoiceSession()
        let raw = TranscriptRevision(rawText: "Use voice prom.", text: "Use voice prom.", origin: .imported)
        let fact = sourcedFact(raw.text, kind: .requirement, transcript: raw)
        session.transcripts = [raw]
        session.facts = [fact]
        session.drafts = [try PromptComposer.compose(session: session, detail: .standard, configurationID: nil)]
        let corrected = TranscriptRevision(replacesID: raw.id, rawText: raw.rawText, text: "Use Keystorm.", origin: .imported)
        session.transcripts.append(corrected)
        session.invalidateDerivedWork()
        #expect(session.drafts[0].stale)
        #expect(session.currentTranscripts.map(\.id) == [corrected.id])
        #expect(LedgerValidation.currentFacts(in: session).isEmpty)
        let undone = TranscriptRevision(replacesID: corrected.id, rawText: raw.rawText, text: raw.text, origin: .imported)
        session.transcripts.append(undone)
        #expect(session.currentTranscripts.map(\.id) == [undone.id])
        #expect(session.transcripts.first == raw)
        // Returning to the same spelling does not revive facts pointing to an older revision.
        #expect(LedgerValidation.currentFacts(in: session).isEmpty)
    }

    @Test func `Dictionary replacement respects Unicode token boundaries and can be undone`() throws {
        let text = "écho: cf and scf CF_2 cf2; cf."
        let entry = DictionaryEntry(canonical: "CoreFlow", aliases: ["cf"])
        let suggestions = Terminology.suggestions(in: text, entries: [entry], projectPath: nil)
        #expect(suggestions.count == 2)
        let suggestion = try #require(suggestions.first)
        let corrected = try Terminology.applying(suggestion, to: text)
        #expect(corrected == "écho: CoreFlow and scf CF_2 cf2; cf.")
        let undo = DictionarySuggestion(entryID: entry.id, original: entry.canonical, replacement: suggestion.original,
            startUTF8: suggestion.startUTF8, endUTF8: suggestion.startUTF8 + entry.canonical.utf8.count)
        #expect(try Terminology.applying(undo, to: corrected) == text)
        #expect(throws: (any Error).self) { try Terminology.applying(suggestion, to: "prefix " + text) }
    }

    @Test func `Project vocabulary takes priority and conflicting project aliases suppress global guesses`() {
        let project = "/Projects/Example"
        let global = DictionaryEntry(canonical: "CloudForge", aliases: ["cf"])
        let local = DictionaryEntry(canonical: "CoreFlow", aliases: ["cf"], projectPath: project)
        let unrelated = DictionaryEntry(canonical: "OtherProject", aliases: ["cf"], projectPath: "/Projects/Elsewhere")
        let preferred = Terminology.suggestions(in: "Use cf.", entries: [global, local, unrelated], projectPath: project)
        #expect(preferred.map(\.replacement) == ["CoreFlow"])
        let conflict = DictionaryEntry(canonical: "CoreFiles", aliases: ["CF"], projectPath: project)
        #expect(Terminology.suggestions(in: "Use cf.", entries: [global, local, conflict], projectPath: project).isEmpty)
    }

    @Test func `Prompt export requires current review and includes verifiable provenance without audio`() throws {
        let root = try transferRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var session = textSession()
        var draft = try PromptComposer.compose(session: session, detail: .detailed, configurationID: nil)
        session.drafts = [draft]
        let destination = root.appendingPathComponent("Prompt.md")
        #expect(throws: (any Error).self) {
            try SessionTransfer.exportPrompt(draft: draft, session: session, to: destination, includeProvenance: true)
        }
        draft.reviewed = true
        session.drafts = [draft]
        try SessionTransfer.exportPrompt(draft: draft, session: session, to: destination, includeProvenance: true)
        #expect(try String(contentsOf: destination, encoding: .utf8) == draft.text)
        let provenance = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathExtension("provenance.json"))) as? [String: Any])
        #expect(provenance["sessionID"] as? String == session.id.uuidString)
        #expect((provenance["facts"] as? [[String: Any]])?.count == 1)
        #expect((provenance["transcripts"] as? [[String: Any]])?.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
        // A repeated export cannot overwrite an existing user file.
        #expect(throws: (any Error).self) {
            try SessionTransfer.exportPrompt(draft: draft, session: session, to: destination, includeProvenance: false)
        }
    }

    @Test func `Export rejects changed sources even when a stale flag was not set`() throws {
        let root = try transferRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var session = textSession()
        var draft = try PromptComposer.compose(session: session, detail: .standard, configurationID: nil)
        draft.reviewed = true
        session.drafts = [draft]
        let old = try #require(session.transcripts.first)
        session.transcripts.append(TranscriptRevision(replacesID: old.id, rawText: old.rawText,
            text: "Use 512 instead.", origin: .imported))
        #expect(!draft.stale)
        #expect(throws: (any Error).self) {
            try SessionTransfer.exportPrompt(draft: draft, session: session, to: root.appendingPathComponent("unsafe.md"), includeProvenance: false)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func `Portable archive roundtrip preserves sources and creates a new session identity`() async throws {
        let root = try transferRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root.appendingPathComponent("Store"))
        let session = try await audioSession(store: store)
        try await store.save(session)
        let audio = try await store.audioDirectory(session.id)
        let archive = root.appendingPathComponent("Session.keystorm", isDirectory: true)
        try SessionTransfer.exportArchive(session: session, audioDirectory: audio, to: archive)
        let sourceManifest = try Data(contentsOf: archive.appendingPathComponent("session.json"))
        let imported = try await SessionTransfer.importArchive(from: archive, store: store)
        #expect(imported.id != session.id)
        #expect(imported.segments == session.segments)
        #expect(imported.transcripts == session.transcripts)
        #expect(imported.facts == session.facts)
        #expect(imported.drafts.allSatisfy { !$0.reviewed })
        #expect(try await store.loadSessions().count == 2)
        let importedAudio = try await store.audioURL(for: imported.segments[0], in: imported.id)
        #expect(try SessionStore.checksum(importedAudio) == session.segments[0].sha256)
        #expect(try Data(contentsOf: archive.appendingPathComponent("session.json")) == sourceManifest)
    }

    @Test(arguments: ["missing", "checksum", "traversal", "symlink", "wrongFrames", "oversizedManifest"])
    func `Unsafe or incomplete archives never become complete local sessions`(damage: String) async throws {
        let root = try transferRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceStore = try SessionStore(root: root.appendingPathComponent("Source"))
        var session = try await audioSession(store: sourceStore)
        let archive = root.appendingPathComponent("Session.keystorm", isDirectory: true)
        try SessionTransfer.exportArchive(session: session,
            audioDirectory: await sourceStore.audioDirectory(session.id), to: archive)
        let audio = archive.appendingPathComponent("Audio").appendingPathComponent(session.segments[0].fileName)
        let manifest = archive.appendingPathComponent("session.json")
        switch damage {
        case "missing":
            try FileManager.default.removeItem(at: audio)
        case "checksum":
            try Data("corrupt".utf8).write(to: audio)
        case "traversal":
            session.segments[0].fileName = "../outside.caf"
            try JSONEncoder().encode(session).write(to: manifest)
        case "symlink":
            let outside = root.appendingPathComponent("outside.caf")
            try FileManager.default.copyItem(at: audio, to: outside)
            try FileManager.default.removeItem(at: audio)
            try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: outside)
        case "wrongFrames":
            session.segments[0].frameCount *= 2
            try JSONEncoder().encode(session).write(to: manifest)
            let sidecar = archive.appendingPathComponent("Audio").appendingPathComponent("\(session.segments[0].id.uuidString).json")
            try JSONEncoder().encode(session.segments[0]).write(to: sidecar)
        default:
            let handle = try FileHandle(forWritingTo: manifest)
            try handle.truncate(atOffset: 65 * 1_024 * 1_024)
            try handle.close()
        }
        let destination = try SessionStore(root: root.appendingPathComponent("Destination"))
        await #expect(throws: (any Error).self) { try await SessionTransfer.importArchive(from: archive, store: destination) }
        #expect(try await destination.loadSessions().isEmpty)
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    private func sourcedFact(_ quote: String, kind: FactKind, transcript: TranscriptRevision) -> Fact {
        let range = transcript.text.range(of: quote)!
        let start = transcript.text[..<range.lowerBound].utf8.count
        return Fact(kind: kind, status: .confirmed, text: quote,
            sources: [SourceReference(transcriptID: transcript.id, startUTF8: start, endUTF8: start + quote.utf8.count, quote: quote)])
    }

    private func textSession() -> VoiceSession {
        var session = VoiceSession()
        let text = "Use 256, not 512."
        let transcript = TranscriptRevision(rawText: text, text: text, origin: .imported)
        session.transcripts = [transcript]
        session.facts = [sourcedFact(text, kind: .constraint, transcript: transcript)]
        return session
    }

    private func transferRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func audioSession(store: SessionStore) async throws -> VoiceSession {
        var session = textSession()
        session.status = .paused
        let interval = CaptureInterval(sampleRate: 16_000, channelCount: 1)
        session.intervals = [interval]
        let directory = try await store.audioDirectory(session.id)
        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        buffer.floatChannelData?[0].update(repeating: 0, count: 1_600)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        let segment = AudioSegment(id: id, intervalID: interval.id, fileName: url.lastPathComponent,
            startTime: 0, frameCount: 1_600, sampleRate: 16_000, channelCount: 1, sha256: try SessionStore.checksum(url))
        session.segments = [segment]
        try JSONEncoder().encode(segment).write(to: directory.appendingPathComponent("\(id.uuidString).json"))
        session.transcripts[0].segmentIDs = [segment.id]
        session.transcripts[0].origin = .transcription
        session.transcripts[0].endTime = segment.endTime
        var draft = try PromptComposer.compose(session: session, detail: .standard, configurationID: nil)
        draft.reviewed = true
        session.drafts = [draft]
        return session
    }
}
