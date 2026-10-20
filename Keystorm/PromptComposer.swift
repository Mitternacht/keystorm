import Foundation

enum LedgerValidation {
    static func validate(_ facts: [Fact], transcripts: [TranscriptRevision]) throws {
        guard Set(transcripts.map(\.id)).count == transcripts.count else { throw KeystormError.message("Duplicate transcript identities.") }
        let indexed = Dictionary(uniqueKeysWithValues: transcripts.map { ($0.id, $0) })
        let ids = Set(facts.map(\.id))
        guard ids.count == facts.count else { throw KeystormError.message("Duplicate fact identities.") }
        for fact in facts {
            guard !fact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !fact.sources.isEmpty else {
                throw KeystormError.message("A fact is missing its statement or supporting source.")
            }
            for source in fact.sources {
                guard let transcript = indexed[source.transcriptID] else {
                    throw KeystormError.message("A fact refers to an unavailable transcript revision.")
                }
                guard BriefDocument.isValid(source, in: transcript.text) else {
                    throw KeystormError.message("A fact's source does not match the original transcript.")
                }
            }
            if let earlier = fact.supersedes, earlier == fact.id || !ids.contains(earlier) {
                throw KeystormError.message("A fact must supersede an existing, different fact.")
            }
        }
        let edges = Dictionary(uniqueKeysWithValues: facts.compactMap { fact in fact.supersedes.map { (fact.id, $0) } })
        var validated = Set<UUID>()
        for fact in facts where !validated.contains(fact.id) {
            var visited = Set<UUID>()
            var cursor: UUID? = fact.id
            while let id = cursor, !validated.contains(id) {
                guard visited.insert(id).inserted else { throw KeystormError.message("Cyclic decision history.") }
                cursor = edges[id]
            }
            validated.formUnion(visited)
        }
    }

    static func currentFacts(in session: VoiceSession) -> [Fact] {
        let current = Set(session.currentTranscripts.map(\.id))
        let superseded = Set(session.facts.filter(\.reviewed).compactMap(\.supersedes))
        return session.facts.filter { fact in
            !superseded.contains(fact.id) && fact.sources.allSatisfy { current.contains($0.transcriptID) }
        }
    }
}

enum PromptComposer {
    static func compose(session: VoiceSession, detail: DetailLevel, configurationID: UUID?) throws -> PromptRevision {
        try LedgerValidation.validate(session.facts, transcripts: session.transcripts)
        let facts = LedgerValidation.currentFacts(in: session)
        guard !facts.isEmpty else { throw KeystormError.message("Extract or add source-linked facts before preparing a prompt.") }
        var parts = ["# " + session.title]
        if !session.taskDescription.isEmpty { parts.append("## Task context\n" + session.taskDescription) }
        let sections: [(FactKind, String)] = [
            (.goal, "Objective"), (.requirement, "Requirements"), (.constraint, "Constraints"),
            (.decision, "Confirmed decisions"), (.example, "Examples"), (.task, "Tasks"), (.question, "Open questions")
        ]
        var included = Set<UUID>()
        for (kind, heading) in sections {
            let selected = facts.filter { $0.kind == kind && $0.status == .confirmed && (detail != .brief || kind != .example) }
            if !selected.isEmpty {
                parts.append("## " + heading + "\n" + selected.map { "- " + $0.text }.joined(separator: "\n"))
                included.formUnion(selected.map(\.id))
            }
        }
        let ambiguous = facts.filter { $0.status == .ambiguous }
        if !ambiguous.isEmpty {
            parts.append("## Needs clarification\n" + ambiguous.map { "- " + $0.text }.joined(separator: "\n"))
            included.formUnion(ambiguous.map(\.id))
        }
        let exploratory = facts.filter { $0.status == .exploratory }
        if detail != .brief && !exploratory.isEmpty {
            parts.append("## Exploratory ideas (not instructions)\n" + exploratory.map { "- " + $0.text }.joined(separator: "\n"))
            included.formUnion(exploratory.map(\.id))
        }
        if !session.gaps.isEmpty || session.currentTranscripts.contains(where: { !$0.isComplete }) {
            parts.append("## Source limitations\nSome recording intervals or processing results are incomplete. Review these before acting.")
        }
        if detail == .detailed {
            let appendix = facts.filter { included.contains($0.id) }.enumerated().map { index, fact in
                let quotes = fact.sources.map { "> " + $0.quote.replacingOccurrences(of: "\n", with: "\n> ") }.joined(separator: "\n")
                return "\(index + 1). \(fact.text)\n\(quotes)"
            }
            parts.append("## Source excerpts\n" + appendix.joined(separator: "\n\n"))
        }
        let currentIDs = Set(facts.map(\.id))
        let dispositions = session.facts.map { fact in
            FactDisposition(factID: fact.id, disposition: included.contains(fact.id) ? "included" :
                fact.status == .superseded ? "superseded" :
                currentIDs.contains(fact.id) ? "omitted for selected detail" : "superseded or stale source")
        }
        return PromptRevision(detail: detail, text: parts.joined(separator: "\n\n"),
            factIDs: facts.filter { included.contains($0.id) }.map(\.id),
            transcriptIDs: session.currentTranscripts.map(\.id), contextIDs: session.contexts.map(\.id),
            dispositions: dispositions, configurationID: configurationID)
    }
}

struct DictionarySuggestion: Identifiable, Equatable, Sendable {
    let id = UUID()
    let entryID: UUID
    let original: String
    let replacement: String
    let startUTF8: Int
    let endUTF8: Int
}

enum Terminology {
    static func suggestions(in text: String, entries: [DictionaryEntry], projectPath: String?) -> [DictionarySuggestion] {
        let scoped = entries.filter { $0.projectPath == nil || $0.projectPath == projectPath }
            .sorted { ($0.projectPath != nil ? 0 : 1) < ($1.projectPath != nil ? 0 : 1) }
        var result: [DictionarySuggestion] = []
        var used = Set<String>()
        for entry in scoped {
            for alias in entry.aliases where !alias.isEmpty && alias != entry.canonical {
                let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: alias) + "(?![\\p{L}\\p{N}_])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range, in: text) else { continue }
                    let start = text[..<range.lowerBound].utf8.count
                    let end = start + text[range].utf8.count
                    let key = "\(start):\(end)"
                    let conflicting = scoped.contains { other in
                        other.id != entry.id && other.projectPath == entry.projectPath &&
                        other.canonical != entry.canonical && other.aliases.contains { $0.caseInsensitiveCompare(alias) == .orderedSame }
                    }
                    let shadowed = entry.projectPath == nil && scoped.contains { other in
                        other.projectPath != nil && other.aliases.contains { $0.caseInsensitiveCompare(alias) == .orderedSame }
                    }
                    guard !conflicting, !shadowed, used.insert(key).inserted else { continue }
                    result.append(DictionarySuggestion(entryID: entry.id, original: String(text[range]), replacement: entry.canonical, startUTF8: start, endUTF8: end))
                }
            }
        }
        return result.sorted { $0.startUTF8 < $1.startUTF8 }
    }

    static func applying(_ suggestion: DictionarySuggestion, to text: String) throws -> String {
        let bytes = Array(text.utf8)
        guard suggestion.startUTF8 >= 0, suggestion.endUTF8 <= bytes.count, suggestion.startUTF8 < suggestion.endUTF8,
              bytes[suggestion.startUTF8..<suggestion.endUTF8].elementsEqual(suggestion.original.utf8),
              let prefix = String(bytes: bytes[..<suggestion.startUTF8], encoding: .utf8),
              let suffix = String(bytes: bytes[suggestion.endUTF8...], encoding: .utf8) else {
            throw KeystormError.message("This suggestion is stale. Review the current transcript.")
        }
        return prefix + suggestion.replacement + suffix
    }
}
