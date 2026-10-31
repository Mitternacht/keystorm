import Foundation

/// Clean mode's output check. The local model may remove noise and fix writing, never add content:
///
/// - Every output word must be a source word, in the source's order (case and punctuation are free).
/// - A source word may be missing only when it is removable noise: a filler ("uh", "äh", comma-delimited
///   "like"), a repeated word or phrase, a cut-off fragment ("wa-"), a spoken formatting command that
///   became a symbol ("comma" -> ","), or part of a spoken self-correction ("send it to Anna no wait I mean
///   to Bob") within a few words before the correction phrase.
/// - Protected literals (numbers, URLs, paths, code, identifiers) may not change, appear or be split; a
///   source literal may disappear only with the words of a self-correction.
/// - Length bounds: the result cannot grow much, and cannot shrink to a fragment.
///
/// Anything else fails, and the caller falls back to the raw transcript.
enum DictationCleanValidator {
    /// A self-correction removes at most this many words before its phrase.
    static let correctionWindow = 8
    /// What remains must be at least 30% of the words that were not removed as plain noise.
    static let minimumKeptTenths = 3
    /// The text may grow by at most half, plus slack for punctuation and line breaks.
    static let maximumGrowthSlackUTF8 = 32

    private struct Reason: OptionSet {
        let rawValue: UInt8
        static let filler = Reason(rawValue: 1)
        static let repeated = Reason(rawValue: 2)
        static let fragment = Reason(rawValue: 4)
        static let command = Reason(rawValue: 8)
        static let correction = Reason(rawValue: 16)
        static let plainNoise: Reason = [.filler, .repeated, .fragment, .command]
    }

    private struct Token {
        let word: String
        let range: NSRange
        var end: Int { range.location + range.length }
    }

    private static let fillerSounds: Set<String> = [
        "uh", "uhm", "uhh", "umm", "erm", "hm", "hmm", "mm", "mmm", "mhm",
        "äh", "ähm", "ähh", "ähem", "öh", "öhm", "ehm"
    ]
    /// Words that cannot follow German "um" ("um zehn Uhr"), so "um" before them is the English filler.
    private static let englishFillerFollowers: Set<String> = [
        "i", "we", "you", "the", "and", "but", "yeah", "well", "okay", "ok", "like", "just", "maybe", "actually",
        "basically", "let", "this", "that", "it", "what", "if", "please", "so", "yes", "no"
    ]
    private static let commaDelimitedFillers: Set<String> = ["like", "sozusagen", "quasi"]
    private static let strictlyDelimitedFillers: Set<String> = ["halt"]
    private static let fillerPhrases: [[String]] = [["you", "know"], ["weißt", "du"]]

    static func validate(output: String, source: String) throws {
        if output.utf8.elementsEqual(source.utf8) { return }
        // Explicit line breaks (a dictated "new line") are never merged away; the model may add paragraph breaks.
        guard output.filter(\.isNewline).count >= source.filter(\.isNewline).count else {
            throw DictationTransformError.changedContent
        }
        let sourceTokens = tokens(in: source)
        let outputTokens = tokens(in: output)
        // Words can only be removed, so more output words than source words is invention.
        guard outputTokens.count <= sourceTokens.count else { throw DictationTransformError.changedContent }
        let reasons = removalReasons(in: source, tokens: sourceTokens)
        guard let kept = alignment(source: sourceTokens, output: outputTokens, reasons: reasons) else {
            throw DictationTransformError.changedContent
        }
        guard droppedCommandsHaveSymbols(source: sourceTokens, kept: kept, output: output),
              literalsAreUnchanged(source: source, sourceTokens: sourceTokens, kept: kept, output: output) else {
            throw DictationTransformError.changedContent
        }
        // Length-ratio bounds: no padding, and a self-correction never deletes most of what was said.
        let sourceBytes = source.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
        let outputBytes = output.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
        guard outputBytes <= sourceBytes + sourceBytes / 2 + maximumGrowthSlackUTF8 else {
            throw DictationTransformError.outputLimit
        }
        var plainNoiseDropped = 0
        for index in sourceTokens.indices where !kept[index] && !reasons[index].isDisjoint(with: .plainNoise) {
            plainNoiseDropped += 1
        }
        let basis = sourceTokens.count - plainNoiseDropped
        guard outputTokens.count * 10 >= basis * minimumKeptTenths else { throw DictationTransformError.outputLimit }
    }

    // MARK: Words

    private static func tokens(in text: String) -> [Token] {
        let expression = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*"#)
        let value = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: value.length)).map { match in
            Token(word: value.substring(with: match.range).lowercased(with: Locale(identifier: "de_DE")), range: match.range)
        }
    }

    /// Which output words each source word can match, found by dynamic programming: `table[i][j]` says the
    /// source suffix from `i` can produce the output suffix from `j`. The first alignment is returned as a
    /// per-source-word "kept" flag, or nil when no alignment exists.
    private static func alignment(source: [Token], output: [Token], reasons: [Reason]) -> [Bool]? {
        let n = source.count, m = output.count
        let width = m + 1
        var table = [Bool](repeating: false, count: (n + 1) * width)
        table[n * width + m] = true
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in 0...m {
                var possible = false
                if j < m, source[i].word == output[j].word, table[(i + 1) * width + j + 1] { possible = true }
                if !possible, !reasons[i].isEmpty, table[(i + 1) * width + j] { possible = true }
                table[i * width + j] = possible
            }
        }
        guard table[0] else { return nil }
        var kept = [Bool](repeating: false, count: n)
        var j = 0
        for i in 0..<n {
            if j < m, source[i].word == output[j].word, table[(i + 1) * width + j + 1] {
                kept[i] = true
                j += 1
            }
        }
        return kept
    }

    /// Why each source word may be dropped. An empty set means it may not.
    private static func removalReasons(in source: String, tokens: [Token]) -> [Reason] {
        let value = source as NSString
        var reasons = [Reason](repeating: [], count: tokens.count)
        func neighbour(before location: Int) -> unichar? {
            var index = location - 1
            while index >= 0 {
                let unit = value.character(at: index)
                if !isSpace(unit) { return unit }
                index -= 1
            }
            return nil
        }
        func neighbour(after location: Int) -> unichar? {
            var index = location
            while index < value.length {
                let unit = value.character(at: index)
                if !isSpace(unit) { return unit }
                index += 1
            }
            return nil
        }
        let comma = unichar(UInt8(ascii: ","))
        let ellipsis = unichar(0x2026)
        let period = unichar(UInt8(ascii: "."))
        func isSentenceStart(_ unit: unichar?) -> Bool {
            guard let unit else { return true }
            return [period, unichar(UInt8(ascii: "?")), unichar(UInt8(ascii: "!"))].contains(unit)
        }
        func hasDigit(_ word: String) -> Bool { word.contains(where: \.isNumber) }
        func gapIsRunOn(_ left: Token, _ right: Token) -> Bool {
            guard right.range.location >= left.end else { return false }
            let gap = value.substring(with: NSRange(location: left.end, length: right.range.location - left.end))
            return gap.allSatisfy { $0 == " " || $0 == "\t" || $0 == "," }
        }

        for (index, token) in tokens.enumerated() {
            let word = token.word
            let before = neighbour(before: token.range.location)
            let after = neighbour(after: token.end)
            if fillerSounds.contains(word) {
                reasons[index].insert(.filler)
            } else if word == "um" {
                // German "um" is a word. Filler only with a pause mark after it, or before an English word.
                let nextWord = index + 1 < tokens.count ? tokens[index + 1].word : nil
                if after == comma || after == ellipsis || after == period ||
                    nextWord.map({ englishFillerFollowers.contains($0) || fillerSounds.contains($0) }) == true {
                    reasons[index].insert(.filler)
                }
            } else if commaDelimitedFillers.contains(word), before == comma || after == comma {
                reasons[index].insert(.filler)
            } else if strictlyDelimitedFillers.contains(word), before == comma, after == comma {
                reasons[index].insert(.filler)
            }
            // A stuttered word: same as the one before it, with only spaces or a comma between.
            if index > 0, tokens[index - 1].word == word, !hasDigit(word), gapIsRunOn(tokens[index - 1], token) {
                reasons[index].insert(.repeated)
            }
            // A cut-off fragment: "wa- I want".
            if token.end < value.length, !hasDigit(word) {
                let next = value.character(at: token.end)
                let afterDash = token.end + 1 < value.length ? value.character(at: token.end + 1) : nil
                if [unichar(UInt8(ascii: "-")), 0x2013, 0x2014].contains(next), afterDash == nil || isSpace(afterDash!) {
                    reasons[index].insert(.fragment)
                    // A restart: "I wa- I want" repeats the words before the fragment after it.
                    for length in 1...3 where index >= length && index + length < tokens.count {
                        let earlier = tokens[(index - length)..<index].map(\.word)
                        let restart = tokens[(index + 1)...(index + length)].map(\.word)
                        if earlier == restart, !earlier.contains(where: hasDigit) {
                            for earlierIndex in (index - length)..<index { reasons[earlierIndex].insert(.fragment) }
                        }
                    }
                }
            }
        }
        // A repeated phrase: the second copy of two to four words.
        for length in 2...4 where tokens.count >= 2 * length {
            for start in 0...(tokens.count - 2 * length) {
                let first = tokens[start..<start + length], second = tokens[start + length..<start + 2 * length]
                guard first.map(\.word) == second.map(\.word), !first.contains(where: { hasDigit($0.word) }),
                      gapIsRunOn(tokens[start + length - 1], tokens[start + length]) else { continue }
                for index in start + length..<start + 2 * length { reasons[index].insert(.repeated) }
            }
        }
        // Filler phrases: "you know," between pauses.
        for phrase in fillerPhrases where tokens.count >= phrase.count {
            for start in 0...(tokens.count - phrase.count) where matches(phrase, at: start, in: tokens) {
                let last = tokens[start + phrase.count - 1]
                let before = neighbour(before: tokens[start].range.location)
                guard neighbour(after: last.end) == comma, before == comma || isSentenceStart(before) else { continue }
                for index in start..<start + phrase.count { reasons[index].insert(.filler) }
            }
        }
        // Spoken formatting commands.
        for start in tokens.indices {
            guard let phrase = DictationSpokenCommands.phrases.first(where: { matches($0.words, at: start, in: tokens) }) else { continue }
            for index in start..<start + phrase.words.count { reasons[index].insert(.command) }
        }
        // Self-corrections: the phrase, and up to `correctionWindow` words before it. Something must follow.
        for marker in DictationSpokenCommands.correctionMarkers {
            for start in tokens.indices where matches(marker, at: start, in: tokens) && start + marker.count < tokens.count {
                for index in max(0, start - correctionWindow)..<start + marker.count { reasons[index].insert(.correction) }
            }
        }
        return reasons
    }

    private static func matches(_ words: [String], at start: Int, in tokens: [Token]) -> Bool {
        guard start + words.count <= tokens.count else { return false }
        for (offset, word) in words.enumerated() where tokens[start + offset].word != word { return false }
        return true
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    // MARK: Commands

    /// A dropped command phrase needs its symbol in the output: "comma" may vanish only where a comma exists.
    private static func droppedCommandsHaveSymbols(source: [Token], kept: [Bool], output: String) -> Bool {
        var dropped: [DictationSpokenCommandKind: Int] = [:]
        var index = 0
        while index < source.count {
            guard let phrase = DictationSpokenCommands.phrases.first(where: { matches($0.words, at: index, in: source) }) else {
                index += 1
                continue
            }
            let range = index..<index + phrase.words.count
            if range.allSatisfy({ !kept[$0] }) { dropped[phrase.kind, default: 0] += 1 }
            index += phrase.words.count
        }
        func count(_ character: Character) -> Int { output.reduce(0) { $0 + ($1 == character ? 1 : 0) } }
        let newlines = output.reduce(0) { $0 + ($1.isNewline ? 1 : 0) }
        for (kind, number) in dropped {
            let available: Int
            switch kind {
            case .comma: available = count(",")
            case .period: available = count(".")
            case .question: available = count("?")
            case .exclamation: available = count("!")
            case .colon: available = count(":")
            case .semicolon: available = count(";")
            case .newLine, .newParagraph: available = newlines
            }
            if number > available { return false }
        }
        return true
    }

    // MARK: Literals

    private enum LiteralKind { case exact, identifier, caseSensitive }

    private struct Literal {
        let key: String
        let kind: LiteralKind
        let location: Int
    }

    private static func literals(in text: String) -> [Literal] {
        let patterns: [(pattern: String, kind: LiteralKind, trimsPunctuation: Bool)] = [
            (#"(?s)```.*?```"#, .exact, false),
            (#"`[^`\n]+`"#, .exact, false),
            (#"(?:https?://|www\.)[^\s<>"']+"#, .exact, true),
            (#"[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+\.[\p{L}]{2,}"#, .exact, true),
            (#"(?:~?/|\./|\.\./)[^\s<>"']+"#, .exact, true),
            (#"[-+]?\p{N}+(?:[.,:/-]\p{N}+)*(?:%)?"#, .exact, false),
            // Identifiers compare without case: a sentence start may be capitalized.
            (#"\b[\p{L}_][\p{L}\p{N}_]*(?:[._-][\p{L}\p{N}_]+)+\b"#, .identifier, false),
            // Mixed case, all caps and honorifics: a source one must survive exactly. A new one is a casing fix.
            (#"\b(?:\p{Ll}+\p{Lu}|\p{Lu}\p{Ll}+\p{Lu})[\p{L}\p{N}]*\b"#, .caseSensitive, false),
            (#"\b\p{Lu}{2,}[\p{L}\p{N}]*\b"#, .caseSensitive, false),
            (#"\b(?:Herr|Frau|Dr\.?|Mr\.?|Ms\.?|Mrs\.?)[ \t]+\p{Lu}[\p{L}\p{M}-]+"#, .caseSensitive, false)
        ]
        let value = text as NSString
        let fullRange = NSRange(location: 0, length: value.length)
        var found: [Literal] = []
        for (index, entry) in patterns.enumerated() {
            let expression = try! NSRegularExpression(pattern: entry.pattern)
            for match in expression.matches(in: text, range: fullRange) {
                var token = value.substring(with: match.range)
                if entry.trimsPunctuation {
                    while let last = token.last, ".,;:!?)]}".contains(last) { token.removeLast() }
                }
                guard !token.isEmpty else { continue }
                let key = entry.kind == .identifier ? token.lowercased(with: Locale(identifier: "de_DE")) : token
                found.append(Literal(key: "\(index)|\(key)", kind: entry.kind, location: match.range.location))
            }
        }
        return found
    }

    private static func literalsAreUnchanged(source: String, sourceTokens: [Token], kept: [Bool], output: String) -> Bool {
        func counts(_ literals: [Literal]) -> [String: Int] {
            literals.reduce(into: [:]) { $0[$1.key, default: 0] += 1 }
        }
        let sourceLiterals = literals(in: source)
        let outputLiterals = literals(in: output)
        // Nothing the source did not hold: exact and identifier literals may only stay or go.
        let sourceCounts = counts(sourceLiterals.filter { $0.kind != .caseSensitive })
        let outputCounts = counts(outputLiterals.filter { $0.kind != .caseSensitive })
        guard outputCounts.allSatisfy({ sourceCounts[$0.key, default: 0] >= $0.value }) else { return false }
        // A mixed-case, all-caps or honorific literal of the source must be written the same way,
        // unless its first word was removed with a self-correction.
        var tokenAt: [Int: Int] = [:]
        for (index, token) in sourceTokens.enumerated() { tokenAt[token.range.location] = index }
        var droppedCounts: [String: Int] = [:]
        for literal in sourceLiterals where literal.kind == .caseSensitive {
            if let index = tokenAt[literal.location], !kept[index] { droppedCounts[literal.key, default: 0] += 1 }
        }
        let sensitiveSource = counts(sourceLiterals.filter { $0.kind == .caseSensitive })
        let sensitiveOutput = counts(outputLiterals.filter { $0.kind == .caseSensitive })
        for (key, number) in sensitiveSource {
            if sensitiveOutput[key, default: 0] < number - droppedCounts[key, default: 0] { return false }
        }
        return true
    }
}
