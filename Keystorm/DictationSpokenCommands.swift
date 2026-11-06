import Foundation

/// What a spoken formatting command becomes in the text.
enum DictationSpokenCommandKind: Hashable, Sendable {
    case comma, period, question, exclamation, colon, semicolon, newLine, newParagraph

    var symbol: String {
        switch self {
        case .comma: ","
        case .period: "."
        case .question: "?"
        case .exclamation: "!"
        case .colon: ":"
        case .semicolon: ";"
        case .newLine: "\n"
        case .newParagraph: "\n\n"
        }
    }

    var isLineBreak: Bool { self == .newLine || self == .newParagraph }

    /// The next word starts a sentence or paragraph, so its first letter is capitalized.
    var startsNewSentence: Bool {
        switch self {
        case .period, .question, .exclamation, .newParagraph: true
        case .comma, .colon, .semicolon, .newLine: false
        }
    }
}

struct DictationSpokenCommandPhrase: Sendable {
    /// Lowercased words, in order.
    let words: [String]
    let kind: DictationSpokenCommandKind
    /// Also an everyday word ("period", "Punkt", "Absatz"). It counts as a command only where the
    /// surrounding words make that likely; see `DictationSpokenFormatting`.
    let isAmbiguous: Bool

    init(_ words: [String], _ kind: DictationSpokenCommandKind, ambiguous: Bool = false) {
        self.words = words
        self.kind = kind
        isAmbiguous = ambiguous
    }
}

/// The spoken formatting commands Keystorm understands, in English and German. One table serves the
/// deterministic pre-pass (`DictationSpokenFormatting`) and Clean's output validator, which lets a model
/// drop exactly these words when it writes the symbol instead.
enum DictationSpokenCommands {
    /// Longest phrase first, so "new paragraph" is tried before any shorter phrase.
    static let phrases: [DictationSpokenCommandPhrase] = {
        let all: [DictationSpokenCommandPhrase] = [
        // English.
        .init(["new", "paragraph"], .newParagraph),
        .init(["new", "line"], .newLine),
        .init(["newline"], .newLine),
        .init(["line", "break"], .newLine),
        .init(["full", "stop"], .period),
        .init(["period"], .period, ambiguous: true),
        .init(["question", "mark"], .question),
        .init(["exclamation", "mark"], .exclamation),
        .init(["exclamation", "point"], .exclamation),
        .init(["semi", "colon"], .semicolon),
        .init(["semicolon"], .semicolon),
        .init(["colon"], .colon),
        .init(["comma"], .comma),
        // German.
        .init(["neuer", "absatz"], .newParagraph),
        .init(["neuen", "absatz"], .newParagraph),
        .init(["neue", "zeile"], .newLine),
        .init(["zeilenumbruch"], .newLine),
        .init(["absatz"], .newParagraph, ambiguous: true),
        .init(["punkt"], .period, ambiguous: true),
        .init(["fragezeichen"], .question),
        .init(["ausrufezeichen"], .exclamation),
        .init(["doppelpunkt"], .colon),
        .init(["semikolon"], .semicolon),
        .init(["strichpunkt"], .semicolon),
        .init(["komma"], .comma)
        ]
        return all.sorted { $0.words.count > $1.words.count }
    }()

    /// A command directly after one of these is the noun ("the comma", "ein Komma", "im Absatz", "zum Punkt").
    static let nounIntroducers: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her", "our", "their", "its",
        "each", "every", "another", "any", "first", "second", "third", "last", "next", "previous", "trial", "grace",
        "same", "long", "short", "whole", "certain", "given", "new", "neue", "neuer", "neuen",
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
        "mein", "meine", "meinen", "dein", "deine", "sein", "seine", "ihr", "ihre", "unser", "unsere",
        "kein", "keine", "keinen", "dieser", "diesem", "diesen", "dieses", "jeder", "jedem", "jeden",
        "erste", "ersten", "zweite", "zweiten", "dritte", "dritten", "nächste", "nächsten", "letzte", "letzten",
        "am", "im", "zum", "zur", "beim", "vom", "bis", "ab", "pro", "wichtiger", "wichtigen", "guter", "guten"
    ]

    /// A command right before one of these is the noun ("comma separated", "new line item", "Punkt 3", "Absatz drei").
    static let nounFollowers: [DictationSpokenCommandKind: Set<String>] = [
        .comma: ["separated", "delimited", "splice", "splices", "operator"],
        .newLine: ["item", "items", "of", "character", "characters", "count", "numbers"],
        .newParagraph: ["of", "von", "des", "der", "im", "ist", "wird", "war", "bei", "für"],
        .period: ["of", "is", "was", "are", "were", "has", "had", "in", "for", "from", "between", "during", "when",
                  "where", "that", "which", "ist", "war", "sind", "waren", "wird", "wurde", "hat", "hatte", "bei", "an",
                  "auf", "zu", "zur", "zum", "dass", "ob", "wo", "mit", "von", "aus", "nach", "vor", "über", "unter",
                  "uhr", "und", "oder", "aber", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht",
                  "neun", "zehn", "elf", "zwölf", "null"]
    ]

    /// Phrases that mark a self-correction: the words before them (and the phrase itself) are replaced by what follows.
    static let correctionMarkers: [[String]] = {
        let all: [[String]] = [
        ["sorry", "i", "meant"], ["sorry", "i", "mean"], ["no", "i", "mean"], ["nein", "ich", "meine"],
        ["sorry", "ich", "meinte"], ["no", "wait"], ["wait", "no"], ["scratch", "that"], ["strike", "that"],
        ["actually", "no"], ["or", "rather"], ["i", "meant"], ["i", "mean"],
        ["nein", "warte"], ["warte", "nein"], ["nee", "warte"], ["streich", "das"], ["oder", "besser"],
        ["besser", "gesagt"], ["ich", "meinte"], ["ich", "meine"]
        ]
        return all.sorted { $0.count > $1.count }
    }()
}

/// Deterministic, model-free handling of spoken punctuation and line-break commands: "comma", "new line",
/// "Komma", "Absatz". It only removes the command words and writes the symbol; it never rewrites other words.
/// Instant, so it can run in Verbatim mode, where no text model is involved.
///
/// Heuristics, deliberately conservative because a wrong conversion deletes a real word:
/// - A command right after an article or preposition is the noun ("the comma", "im Absatz") and stays.
/// - "period", "Punkt" and "Absatz" also need a following word in the same sentence, and are skipped before
///   words that make them a noun ("Punkt 3", "period of time"). At the very end of the text the speech model
///   has already ended the sentence.
/// - Punctuation the speech model wrote around a command word is absorbed into the symbol.
/// - German "Komma" between two digits is a decimal separator: "3 Komma 5" becomes "3,5".
enum DictationSpokenFormatting {
    private struct WordToken {
        let range: NSRange
        let word: String
        var end: Int { range.location + range.length }
    }

    private struct CommandMatch {
        let range: NSRange
        let kind: DictationSpokenCommandKind
        let isDecimalSeparator: Bool
    }

    /// Characters the speech model puts around a spoken command word.
    private static let strayPunctuation: Set<unichar> = Set(",;:.!?".utf16)
    private static let sentenceBreaks: Set<unichar> = Set(".?!\n".utf16)

    /// The text with every recognized command applied. Unchanged when it holds none, and unchanged when
    /// applying them would leave nothing but whitespace (a lone "new line" stays a transcript, not a blank).
    static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        let value = text as NSString
        let tokens = wordTokens(in: text, value: value)
        let matches = commandMatches(in: tokens, value: value)
        guard !matches.isEmpty else { return text }
        let length = value.length
        var output = ""
        var cursor = 0
        var capitalizeNext = false
        for match in matches {
            var left = match.range.location
            while left > cursor, isSpace(value.character(at: left - 1)) { left -= 1 }
            if !match.kind.isLineBreak, !match.isDecimalSeparator {
                // "Hello, comma, how": the speech model's commas belong to the command.
                while left > cursor, strayPunctuation.contains(value.character(at: left - 1)) {
                    left -= 1
                    while left > cursor, isSpace(value.character(at: left - 1)) { left -= 1 }
                }
            }
            var right = match.range.location + match.range.length
            while right < length, strayPunctuation.contains(value.character(at: right)) { right += 1 }
            if match.kind.isLineBreak || match.isDecimalSeparator {
                while right < length, isSpace(value.character(at: right)) { right += 1 }
            }
            let segment = value.substring(with: NSRange(location: cursor, length: max(0, left - cursor)))
            output += capitalizing(segment, pending: &capitalizeNext)
            switch match.kind {
            case .newLine, .newParagraph:
                output += match.kind.symbol
            case .comma, .period, .question, .exclamation, .colon, .semicolon:
                if output.last.map({ String($0) }) != match.kind.symbol { output += match.kind.symbol }
            }
            cursor = right
            capitalizeNext = match.kind.startsNewSentence
        }
        output += capitalizing(value.substring(from: min(cursor, length)), pending: &capitalizeNext)
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : output
    }

    // MARK: Matching

    private static func wordTokens(in text: String, value: NSString) -> [WordToken] {
        let expression = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*"#)
        return expression.matches(in: text, range: NSRange(location: 0, length: value.length)).map { match in
            WordToken(range: match.range, word: value.substring(with: match.range).lowercased(with: Locale(identifier: "de_DE")))
        }
    }

    private static func commandMatches(in tokens: [WordToken], value: NSString) -> [CommandMatch] {
        var matches: [CommandMatch] = []
        var index = 0
        while index < tokens.count {
            var accepted: (match: CommandMatch, count: Int)?
            for phrase in DictationSpokenCommands.phrases where matchesWords(phrase.words, at: index, in: tokens, value: value) {
                let last = index + phrase.words.count - 1
                if let candidate = accept(phrase, first: index, last: last, tokens: tokens, value: value) {
                    accepted = (candidate, phrase.words.count)
                }
                break
            }
            if let accepted {
                matches.append(accepted.match)
                index += accepted.count
            } else {
                index += 1
            }
        }
        return matches
    }

    private static func matchesWords(_ words: [String], at index: Int, in tokens: [WordToken], value: NSString) -> Bool {
        guard index + words.count <= tokens.count else { return false }
        for offset in words.indices {
            guard tokens[index + offset].word == words[offset] else { return false }
            if offset > 0 {
                // "new line" and "new-line", never "new. Line".
                let gap = gapText(tokens[index + offset - 1], tokens[index + offset], value: value)
                guard gap.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "-" }) else { return false }
            }
        }
        return true
    }

    private static func accept(_ phrase: DictationSpokenCommandPhrase, first: Int, last: Int,
                               tokens: [WordToken], value: NSString) -> CommandMatch? {
        let range = NSRange(location: tokens[first].range.location, length: tokens[last].end - tokens[first].range.location)
        let previous = first > 0 ? tokens[first - 1] : nil
        let next = last + 1 < tokens.count ? tokens[last + 1] : nil
        // Words across a sentence break do not belong to this command.
        let previousWord = previous.flatMap { token in
            hasSentenceBreak(gapText(token, tokens[first], value: value)) ? nil : token.word
        }
        let nextWord = next.flatMap { token in
            hasSentenceBreak(gapText(tokens[last], token, value: value)) ? nil : token.word
        }
        if let previousWord, DictationSpokenCommands.nounIntroducers.contains(previousWord) { return nil }
        if let nextWord, DictationSpokenCommands.nounFollowers[phrase.kind]?.contains(nextWord) == true { return nil }
        if phrase.isAmbiguous {
            guard let nextWord, !nextWord.contains(where: \.isNumber) else { return nil }
        }
        // German "3 Komma 5": a decimal separator, so it is written without spaces.
        var decimal = false
        if phrase.words == ["komma"], let previous, let next,
           previous.word.allSatisfy(\.isASCII), previous.word.allSatisfy(\.isNumber),
           next.word.allSatisfy(\.isASCII), next.word.allSatisfy(\.isNumber),
           gapText(previous, tokens[first], value: value).allSatisfy({ $0 == " " }),
           gapText(tokens[last], next, value: value).allSatisfy({ $0 == " " }) {
            decimal = true
        }
        return CommandMatch(range: range, kind: phrase.kind, isDecimalSeparator: decimal)
    }

    private static func gapText(_ first: WordToken, _ second: WordToken, value: NSString) -> String {
        let start = first.end
        guard second.range.location >= start else { return "" }
        return value.substring(with: NSRange(location: start, length: second.range.location - start))
    }

    private static func hasSentenceBreak(_ gap: String) -> Bool {
        gap.utf16.contains { sentenceBreaks.contains($0) }
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0
    }

    /// Uppercases the first letter of `segment` once a sentence-ending command is pending.
    private static func capitalizing(_ segment: String, pending: inout Bool) -> String {
        guard pending, !segment.isEmpty else { return segment }
        guard let index = segment.firstIndex(where: { !$0.isWhitespace }) else { return segment }
        pending = false
        let first = segment[index]
        guard first.isLetter, first.isLowercase, first != "ß" else { return segment }
        return String(segment[..<index]) + first.uppercased() + String(segment[segment.index(after: index)...])
    }
}
