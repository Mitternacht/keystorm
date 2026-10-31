import Foundation

/// A word the person added by hand. Unlike a learned correction it is approved from the start,
/// applies in every app and both languages, and needs no matching context.
struct VocabularyEntry: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    /// The spelling dictation should produce.
    var word: String
    /// Spoken or misrecognized spellings that become `word`. Empty means only the casing of `word` is enforced.
    var soundsLike: [String] = []
    var createdAt = Date()
}

enum VocabularyError: LocalizedError, Equatable {
    case invalidWord, invalidSoundsLike, duplicate, conflictingSoundsLike(String)
    case limitReached, missingEntry, unsupportedStore, storageLimit, unreadableFile

    var errorDescription: String? {
        switch self {
        case .invalidWord:
            String(localized: "Enter a word or short phrase without commas, line breaks or “=>”.")
        case .invalidSoundsLike:
            String(localized: "“Sounds like” spellings must be short phrases without line breaks or “=>”. Separate several with commas.")
        case .duplicate: String(localized: "That word is already in your vocabulary.")
        case .conflictingSoundsLike(let phrase):
            String(localized: "“\(phrase)” already stands for a different word in your vocabulary.")
        case .limitReached: String(localized: "Your vocabulary has reached its limit of 500 words.")
        case .missingEntry: String(localized: "That word is no longer in your vocabulary.")
        case .unsupportedStore: String(localized: "The saved vocabulary is invalid or uses an unsupported format. It was left untouched.")
        case .storageLimit: String(localized: "The vocabulary is too large to save.")
        case .unreadableFile: String(localized: "That file could not be read as plain text, or it is too large.")
        }
    }
}

/// Validation and the one-per-line text format shared by the store, import and export.
enum VocabularyPolicy {
    static let maxEntries = 500
    static let maxCharacters = 64
    static let maxSoundsLike = 8
    static let maxFileBytes = 1_024 * 1_024
    static let maxImportBytes = 256 * 1_024
    static let maxImportLines = 2_000
    static let separators = ["=>", "->", "→"]

    /// Trims, collapses whitespace runs and rejects anything that could not survive a text round trip.
    static func normalized(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        let collapsed = words.joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= maxCharacters,
              !collapsed.contains(","), !separators.contains(where: { collapsed.contains($0) }),
              collapsed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              collapsed.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return nil }
        return collapsed
    }

    static func key(_ text: String) -> String { text.lowercased() }

    /// Comma-separated user input to validated spellings. Duplicates and the word itself are dropped.
    static func soundsLikeList(from text: String, word: String) throws -> [String] {
        try soundsLikeList(text.split(separator: ",").map(String.init), word: word)
    }

    static func soundsLikeList(_ phrases: [String], word: String) throws -> [String] {
        var result: [String] = []
        for phrase in phrases {
            if phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let value = normalized(phrase) else { throw VocabularyError.invalidSoundsLike }
            guard key(value) != key(word), !result.contains(where: { key($0) == key(value) }) else { continue }
            result.append(value)
        }
        guard result.count <= maxSoundsLike else { throw VocabularyError.invalidSoundsLike }
        return result
    }

    struct ParsedLine: Equatable, Sendable {
        var word: String
        var soundsLike: [String]
    }

    /// `Word`, or `spoken one, spoken two => Word`. Blank lines and `#` comments are ignored.
    static func parse(_ text: String) -> (lines: [ParsedLine], skipped: Int) {
        var lines: [ParsedLine] = []
        var skipped = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).prefix(maxImportLines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var wordPart = line
            var spokenParts: [String] = []
            if let hit = separators.compactMap({ separator in line.range(of: separator).map { (separator, $0) } })
                .min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
                spokenParts = line[..<hit.1.lowerBound].split(separator: ",").map(String.init)
                wordPart = String(line[hit.1.upperBound...])
            }
            guard let word = normalized(wordPart),
                  let spoken = try? soundsLikeList(spokenParts, word: word) else { skipped += 1; continue }
            lines.append(ParsedLine(word: word, soundsLike: spoken))
        }
        return (lines, skipped)
    }

    static func text(for entries: [VocabularyEntry]) -> String {
        entries.map { entry in
            entry.soundsLike.isEmpty ? entry.word : entry.soundsLike.joined(separator: ", ") + " => " + entry.word
        }.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
    }
}

struct VocabularyImportSummary: Equatable, Sendable {
    var added = 0
    var merged = 0
    var skipped = 0
}

/// One writer and a separate file, next to the learning dictionary. Nothing here touches that
/// file or the older terminology dictionary. The file is read lazily, so merely constructing a store does no I/O.
actor ManualVocabularyStore {
    private struct Snapshot: Codable {
        var schemaVersion = 1
        var entries: [VocabularyEntry]
    }

    private let url: URL
    private let write: @Sendable (Data, URL) throws -> Void
    private var loaded: [VocabularyEntry]?

    init(url: URL, writer: (@Sendable (Data, URL) throws -> Void)? = nil) {
        self.url = url
        self.write = writer ?? LearningRepository.atomicWrite
    }

    func entries() throws -> [VocabularyEntry] { try load() }

    @discardableResult
    func add(word: String, soundsLike: [String]) throws -> VocabularyEntry {
        var next = try load()
        guard next.count < VocabularyPolicy.maxEntries else { throw VocabularyError.limitReached }
        guard let word = VocabularyPolicy.normalized(word) else { throw VocabularyError.invalidWord }
        guard !next.contains(where: { VocabularyPolicy.key($0.word) == VocabularyPolicy.key(word) }) else {
            throw VocabularyError.duplicate
        }
        let spoken = try VocabularyPolicy.soundsLikeList(soundsLike, word: word)
        try Self.requireNoConflict(spoken + [word], in: next)
        let entry = VocabularyEntry(word: word, soundsLike: spoken)
        next.append(entry)
        try commit(next)
        return entry
    }

    func update(id: UUID, word: String, soundsLike: [String]) throws {
        var next = try load()
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw VocabularyError.missingEntry }
        guard let word = VocabularyPolicy.normalized(word) else { throw VocabularyError.invalidWord }
        let others = next.filter { $0.id != id }
        guard !others.contains(where: { VocabularyPolicy.key($0.word) == VocabularyPolicy.key(word) }) else {
            throw VocabularyError.duplicate
        }
        let spoken = try VocabularyPolicy.soundsLikeList(soundsLike, word: word)
        try Self.requireNoConflict(spoken + [word], in: others)
        next[index].word = word
        next[index].soundsLike = spoken
        try commit(next)
    }

    func remove(id: UUID) throws {
        var next = try load()
        guard next.contains(where: { $0.id == id }) else { throw VocabularyError.missingEntry }
        next.removeAll { $0.id == id }
        try commit(next)
    }

    /// An existing word keeps its stored spelling and gains any new "sounds like" phrases.
    func importText(_ text: String) throws -> VocabularyImportSummary {
        guard text.utf8.count <= VocabularyPolicy.maxImportBytes else { throw VocabularyError.unreadableFile }
        var next = try load()
        let parsed = VocabularyPolicy.parse(text)
        var summary = VocabularyImportSummary(skipped: parsed.skipped)
        for line in parsed.lines {
            if let index = next.firstIndex(where: { VocabularyPolicy.key($0.word) == VocabularyPolicy.key(line.word) }) {
                let fresh = line.soundsLike.filter { phrase in
                    !next[index].soundsLike.contains(where: { VocabularyPolicy.key($0) == VocabularyPolicy.key(phrase) })
                }
                let others = next.filter { $0.id != next[index].id }
                guard !fresh.isEmpty, next[index].soundsLike.count + fresh.count <= VocabularyPolicy.maxSoundsLike,
                      (try? Self.requireNoConflict(fresh, in: others)) != nil else {
                    summary.skipped += fresh.isEmpty ? 0 : 1
                    continue
                }
                next[index].soundsLike += fresh
                summary.merged += 1
            } else {
                guard next.count < VocabularyPolicy.maxEntries,
                      (try? Self.requireNoConflict(line.soundsLike + [line.word], in: next)) != nil else {
                    summary.skipped += 1
                    continue
                }
                next.append(VocabularyEntry(word: line.word, soundsLike: line.soundsLike))
                summary.added += 1
            }
        }
        if summary.added > 0 || summary.merged > 0 { try commit(next) }
        return summary
    }

    func exportText() throws -> String { VocabularyPolicy.text(for: try load()) }

    /// A phrase may stand for one word only; two words claiming it would make the result depend on order.
    private static func requireNoConflict(_ phrases: [String], in others: [VocabularyEntry]) throws {
        for phrase in phrases {
            let claimed = others.contains { other in
                VocabularyPolicy.key(other.word) == VocabularyPolicy.key(phrase) ||
                    other.soundsLike.contains { VocabularyPolicy.key($0) == VocabularyPolicy.key(phrase) }
            }
            if claimed { throw VocabularyError.conflictingSoundsLike(phrase) }
        }
    }

    private func load() throws -> [VocabularyEntry] {
        if let loaded { return loaded }
        var result: [VocabularyEntry] = []
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= VocabularyPolicy.maxFileBytes,
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url)),
                  snapshot.schemaVersion == 1, snapshot.entries.count <= VocabularyPolicy.maxEntries,
                  Set(snapshot.entries.map(\.id)).count == snapshot.entries.count,
                  snapshot.entries.allSatisfy({ VocabularyPolicy.normalized($0.word) != nil }) else {
                throw VocabularyError.unsupportedStore
            }
            result = snapshot.entries
        }
        loaded = result
        return result
    }

    private func commit(_ next: [VocabularyEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(entries: next))
        guard data.count <= VocabularyPolicy.maxFileBytes else { throw VocabularyError.storageLimit }
        try write(data, url)
        loaded = next
    }
}

/// Case-insensitive, context-free replacement on a finished dictation. It skips URLs, paths and code like
/// the learned-term applicator and never rewrites text that already has the entry's exact spelling.
enum ManualVocabularyApplicator {
    private struct Candidate {
        var range: NSRange
        var entryIndex: Int
        var text: String
        var termID: UUID
    }

    static let maxReplacements = 512

    static func apply(entries: [VocabularyEntry], to source: String, maximumTerms: Int = 64) -> LearnedTermApplication {
        let unchanged = LearnedTermApplication(text: source, termIDs: [])
        guard !entries.isEmpty, !source.isEmpty, maximumTerms > 0,
              source.utf8.count <= LearnedTermApplicator.maxSourceUTF8 else { return unchanged }
        let nsSource = source as NSString
        let full = NSRange(location: 0, length: nsSource.length)
        var candidates: [Candidate] = []
        var protectedRanges: [NSRange]?
        for (index, entry) in entries.enumerated() {
            for phrase in [entry.word] + entry.soundsLike {
                // Cheap filter first: most phrases never occur, and compiling a pattern is the costly step.
                guard let first = phrase.split(whereSeparator: { $0.isWhitespace }).first,
                      source.range(of: String(first), options: .caseInsensitive) != nil,
                      let regex = pattern(for: phrase) else { continue }
                for match in regex.matches(in: source, range: full) where match.range.length > 0 {
                    guard nsSource.substring(with: match.range) != entry.word else { continue }
                    if protectedRanges == nil {
                        protectedRanges = LearnedTermApplicator.protectedLiteralRanges(in: source).map { NSRange($0, in: source) }
                    }
                    guard !(protectedRanges ?? []).contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                    candidates.append(Candidate(range: match.range, entryIndex: index, text: entry.word, termID: entry.id))
                    if candidates.count > maxReplacements * 4 { return unchanged }
                }
            }
        }
        // Longest phrase wins, then the earlier entry; overlapping losers are dropped, never merged.
        candidates.sort {
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            if $0.entryIndex != $1.entryIndex { return $0.entryIndex < $1.entryIndex }
            return $0.range.location < $1.range.location
        }
        var accepted: [Candidate] = []
        var usedTerms = Set<UUID>()
        for candidate in candidates {
            guard accepted.count < maxReplacements,
                  usedTerms.contains(candidate.termID) || usedTerms.count < maximumTerms,
                  !accepted.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) else { continue }
            accepted.append(candidate)
            usedTerms.insert(candidate.termID)
        }
        guard !accepted.isEmpty else { return unchanged }
        accepted.sort { $0.range.location < $1.range.location }
        var result = ""
        var cursor = 0
        var termIDs: [UUID] = []
        for candidate in accepted {
            result += nsSource.substring(with: NSRange(location: cursor, length: candidate.range.location - cursor))
            result += candidate.text
            cursor = candidate.range.location + candidate.range.length
            if !termIDs.contains(candidate.termID) { termIDs.append(candidate.termID) }
        }
        result += nsSource.substring(from: cursor)
        guard result.utf8.count <= LearnedTermApplicator.maxSourceUTF8, result != source else { return unchanged }
        return LearnedTermApplication(text: result, termIDs: termIDs)
    }

    private static func pattern(for phrase: String) -> NSRegularExpression? {
        let tokens = phrase.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !tokens.isEmpty else { return nil }
        let body = tokens.joined(separator: #"\s+"#)
        return try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])"# + body + #"(?![\p{L}\p{N}_])"#, options: [.caseInsensitive])
    }
}
