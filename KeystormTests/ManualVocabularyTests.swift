import Foundation
import Testing
@testable import Keystorm

/// Every store here lives in a temporary directory; nothing reads or writes the real Application Support folder.
struct ManualVocabularyTests {
    // MARK: Text format

    @Test("Entries are trimmed, collapsed and rejected when they cannot survive a text round trip")
    func normalizationRules() {
        #expect(VocabularyPolicy.normalized("  Kubernetes  ") == "Kubernetes")
        #expect(VocabularyPolicy.normalized("New\t  York   City") == "New York City")
        #expect(VocabularyPolicy.normalized("") == nil)
        #expect(VocabularyPolicy.normalized("   ") == nil)
        #expect(VocabularyPolicy.normalized("a, b") == nil)
        #expect(VocabularyPolicy.normalized("spoken => Word") == nil)
        #expect(VocabularyPolicy.normalized("a → b") == nil)
        #expect(VocabularyPolicy.normalized("!!!") == nil)
        #expect(VocabularyPolicy.normalized(String(repeating: "a", count: 65)) == nil)
        #expect(VocabularyPolicy.normalized(String(repeating: "a", count: 64)) != nil)
        #expect(VocabularyPolicy.normalized("C++") == "C++")
        #expect(VocabularyPolicy.normalized("Müller") == "Müller")
    }

    @Test("Import text understands plain words, replacements, comments and bad lines")
    func parsesOneEntryPerLine() {
        let text = """
            # my terms
            Kubernetes

            cube er net ease, cooper netties => Kubernetes
            gee pee tee -> GPT
            my sequel → MySQL
            bad, line
            lonely =>
            foo => Foo
            """
        let parsed = VocabularyPolicy.parse(text)
        #expect(parsed.lines == [
            .init(word: "Kubernetes", soundsLike: []),
            .init(word: "Kubernetes", soundsLike: ["cube er net ease", "cooper netties"]),
            .init(word: "GPT", soundsLike: ["gee pee tee"]),
            .init(word: "MySQL", soundsLike: ["my sequel"]),
            // "foo" differs from "Foo" only in case, which a plain entry already enforces.
            .init(word: "Foo", soundsLike: [])
        ])
        #expect(parsed.skipped == 2)
    }

    @Test("Export text parses back to the same entries")
    func exportRoundTrips() {
        let entries = [
            VocabularyEntry(word: "Kubernetes", soundsLike: ["cube er net ease", "cooper netties"]),
            VocabularyEntry(word: "Müller"),
            VocabularyEntry(word: "GPT", soundsLike: ["gee pee tee"])
        ]
        let text = VocabularyPolicy.text(for: entries)
        #expect(text == "cube er net ease, cooper netties => Kubernetes\nMüller\ngee pee tee => GPT\n")
        let parsed = VocabularyPolicy.parse(text)
        #expect(parsed.skipped == 0)
        #expect(parsed.lines.map(\.word) == entries.map(\.word))
        #expect(parsed.lines.map(\.soundsLike) == entries.map(\.soundsLike))
        #expect(VocabularyPolicy.text(for: []).isEmpty)
    }

    // MARK: Store

    @Test("Adding, editing and removing persist across a new store instance")
    func storePersists() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vocabulary.json")
        let store = ManualVocabularyStore(url: url)
        #expect(try await store.entries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let added = try await store.add(word: "  Kubernetes ", soundsLike: ["cube er net ease", "Cube Er Net Ease", "kubernetes"])
        #expect(added.word == "Kubernetes")
        // Duplicates and the word itself, ignoring case, are dropped.
        #expect(added.soundsLike == ["cube er net ease"])
        try await store.add(word: "GPT", soundsLike: [])

        let reopened = ManualVocabularyStore(url: url)
        #expect(try await reopened.entries().map(\.word) == ["Kubernetes", "GPT"])

        try await reopened.update(id: added.id, word: "Kubernetes", soundsLike: ["cooper netties"])
        #expect(try await ManualVocabularyStore(url: url).entries().first?.soundsLike == ["cooper netties"])

        try await reopened.remove(id: added.id)
        #expect(try await ManualVocabularyStore(url: url).entries().map(\.word) == ["GPT"])
        await #expect(throws: VocabularyError.missingEntry) { try await reopened.remove(id: added.id) }
    }

    @Test("Duplicates, conflicting phrases and invalid input are rejected without writing")
    func storeValidation() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vocabulary.json")
        let store = ManualVocabularyStore(url: url)
        try await store.add(word: "Kubernetes", soundsLike: ["cube er net ease"])
        let before = try Data(contentsOf: url)

        await #expect(throws: VocabularyError.duplicate) { try await store.add(word: "kubernetes", soundsLike: []) }
        await #expect(throws: VocabularyError.conflictingSoundsLike("Cube er net ease")) {
            try await store.add(word: "Cubes", soundsLike: ["Cube er net ease"])
        }
        await #expect(throws: VocabularyError.invalidWord) { try await store.add(word: "a, b", soundsLike: []) }
        await #expect(throws: VocabularyError.invalidWord) { try await store.add(word: "   ", soundsLike: []) }
        await #expect(throws: VocabularyError.invalidSoundsLike) { try await store.add(word: "Foo", soundsLike: ["x => y"]) }
        #expect(try Data(contentsOf: url) == before)
        #expect(try await store.entries().count == 1)
    }

    @Test("A damaged vocabulary file is reported and left untouched")
    func damagedFileIsPreserved() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vocabulary.json")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)
        let store = ManualVocabularyStore(url: url)
        await #expect(throws: VocabularyError.unsupportedStore) { try await store.entries() }
        await #expect(throws: VocabularyError.unsupportedStore) { try await store.add(word: "Word", soundsLike: []) }
        #expect(try Data(contentsOf: url) == garbage)
    }

    @Test("Import merges into existing words and reports what it did")
    func importSummary() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ManualVocabularyStore(url: directory.appendingPathComponent("vocabulary.json"))
        try await store.add(word: "Kubernetes", soundsLike: ["cube er net ease"])
        let summary = try await store.importText("""
            kubernetes
            cooper netties => kubernetes
            cube er net ease => Kubernetes
            Müller
            bad, line
            """)
        // "kubernetes" exists with nothing new, "cooper netties" is new for it, "cube er net ease" is already there.
        #expect(summary == VocabularyImportSummary(added: 1, merged: 1, skipped: 1))
        let entries = try await store.entries()
        #expect(entries.map(\.word) == ["Kubernetes", "Müller"])
        #expect(entries.first?.soundsLike == ["cube er net ease", "cooper netties"])
        #expect(try await store.exportText() == "cube er net ease, cooper netties => Kubernetes\nMüller\n")

        let oversized = String(repeating: "word\n", count: VocabularyPolicy.maxImportBytes)
        await #expect(throws: VocabularyError.unreadableFile) { try await store.importText(oversized) }
    }

    // MARK: Application

    private func apply(_ entries: [VocabularyEntry], to text: String, maximumTerms: Int = 64) -> LearnedTermApplication {
        ManualVocabularyApplicator.apply(entries: entries, to: text, maximumTerms: maximumTerms)
    }

    @Test("A plain word fixes capitalization without any context or language")
    func casingOnly() {
        let kubernetes = VocabularyEntry(word: "Kubernetes")
        let result = apply([kubernetes], to: "We deployed kubernetes and KUBERNETES today.")
        #expect(result.text == "We deployed Kubernetes and Kubernetes today.")
        #expect(result.termIDs == [kubernetes.id])
        let unchanged = apply([kubernetes], to: "We deployed Kubernetes today.")
        #expect(unchanged.text == "We deployed Kubernetes today.")
        #expect(unchanged.termIDs.isEmpty)
    }

    @Test("Sounds-like phrases match case-insensitively across whitespace and in German text")
    func soundsLike() {
        let kubernetes = VocabularyEntry(word: "Kubernetes", soundsLike: ["cube er net ease"])
        let result = apply([kubernetes], to: "Wir nutzen Cube  Er\nNet Ease im Cluster.")
        #expect(result.text == "Wir nutzen Kubernetes im Cluster.")
        let mueller = VocabularyEntry(word: "Müller", soundsLike: ["mueller"])
        #expect(apply([mueller], to: "Herr mueller kommt.").text == "Herr Müller kommt.")
    }

    @Test("Matches never start or end inside another word")
    func wordBoundaries() {
        let entries = [VocabularyEntry(word: "Max"), VocabularyEntry(word: "OP", soundsLike: ["oh pee"])]
        #expect(apply(entries, to: "the maximum stop value").text == "the maximum stop value")
        #expect(apply(entries, to: "ask max and the oh pee team").text == "ask Max and the OP team")
        // A hyphen joins words, but it does not stop a match: "kubernetes-based" is still Kubernetes.
        #expect(apply([VocabularyEntry(word: "Kubernetes")], to: "a kubernetes-based setup").text == "a Kubernetes-based setup")
    }

    @Test("Links, paths and code are never rewritten")
    func protectedText() {
        let entry = VocabularyEntry(word: "Kubernetes")
        for text in ["see https://example.com/kubernetes for details", "open kubernetes.io today",
                     "run `kubernetes` now", "write ~/docs/kubernetes/notes"] {
            #expect(apply([entry], to: text).text == text)
        }
    }

    @Test("The longest phrase wins an overlap, then the earlier entry")
    func overlaps() {
        let city = VocabularyEntry(word: "New York City", soundsLike: ["new york"])
        let shire = VocabularyEntry(word: "Yorkshire", soundsLike: ["york"])
        #expect(apply([city, shire], to: "visit new york and york").text == "visit New York City and Yorkshire")
        let first = VocabularyEntry(word: "Alpha", soundsLike: ["a l"])
        let second = VocabularyEntry(word: "Beta", soundsLike: ["a l"])
        #expect(apply([first, second], to: "say a l").text == "say Alpha")
    }

    @Test("At most the allowed number of distinct words is applied, and the rest stay as spoken")
    func termCap() {
        let entries = (0..<5).map { VocabularyEntry(word: "Word\($0)", soundsLike: ["spoken\($0)"]) }
        let text = (0..<5).map { "spoken\($0)" }.joined(separator: " ")
        let capped = apply(entries, to: text, maximumTerms: 2)
        #expect(capped.termIDs.count == 2)
        #expect(Set(capped.termIDs).isSubset(of: Set(entries.map(\.id))))
        #expect(apply(entries, to: text, maximumTerms: 0).text == text)
        #expect(apply([], to: text).termIDs.isEmpty)
    }

    // MARK: Controller

    @MainActor
    @Test("Manual words apply to dictation output with learning off, and the file stays inside the store folder")
    func controllerAppliesManualWordsWithLearningOff() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("dictionary-v1.json"))
        #expect(repository.vocabularyURL.path == directory.appendingPathComponent("vocabulary-v1.json").path)
        let controller = LearningDictionaryController(repository: repository) { _ in throw CancellationError() }
        #expect(!controller.isEnabled)

        let untouched = await controller.applyDictionaries(to: "We deployed kubernetes.", appBundleID: nil)
        #expect(untouched.text == "We deployed kubernetes." && untouched.termIDs.isEmpty)

        #expect(await controller.addVocabularyWord("Kubernetes", soundsLike: ["cube er net ease"]))
        #expect(controller.vocabulary.map(\.word) == ["Kubernetes"])
        let id = try #require(controller.vocabulary.first?.id)
        let applied = await controller.applyDictionaries(to: "We deployed kubernetes and cube er net ease.", appBundleID: "com.apple.TextEdit")
        #expect(applied.text == "We deployed Kubernetes and Kubernetes.")
        #expect(applied.termIDs == [id])

        // A rejected word reports an error and keeps the list as it was.
        #expect(await controller.addVocabularyWord("kubernetes", soundsLike: []) == false)
        #expect(controller.errorMessage != nil)
        #expect(controller.vocabulary.count == 1)

        #expect(await controller.updateVocabularyEntry(id: id, word: "Kubernetes", soundsLike: ["cooper netties"]))
        #expect(controller.vocabulary.first?.soundsLike == ["cooper netties"])
        await controller.deleteVocabularyEntry(id: id)
        #expect(controller.vocabulary.isEmpty)
        let removed = await controller.applyDictionaries(to: "We deployed kubernetes.", appBundleID: nil)
        #expect(removed.termIDs.isEmpty)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.contains("vocabulary-v1.json"))
    }

    @MainActor
    @Test("Import and export go through plain text files")
    func controllerImportExport() async throws {
        let directory = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LearningRepository(url: directory.appendingPathComponent("dictionary-v1.json"))
        let controller = LearningDictionaryController(repository: repository) { _ in throw CancellationError() }
        let source = directory.appendingPathComponent("words.txt")
        try "Kubernetes\ncube er net ease => Kubernetes\nMüller\n".write(to: source, atomically: true, encoding: .utf8)
        await controller.importVocabulary(from: source)
        #expect(controller.vocabulary.map(\.word) == ["Kubernetes", "Müller"])
        #expect(controller.vocabularyStatusMessage != nil)

        let target = directory.appendingPathComponent("export.txt")
        await controller.exportVocabulary(to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "cube er net ease => Kubernetes\nMüller\n")

        let missing = directory.appendingPathComponent("missing.txt")
        await controller.importVocabulary(from: missing)
        #expect(controller.errorMessage != nil)
        #expect(controller.vocabulary.count == 2)
    }
}
