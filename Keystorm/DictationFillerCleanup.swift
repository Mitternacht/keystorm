import Foundation

/// Deterministic first pass of Clean and Email: filler sounds and stuttered words go before the text model
/// sees the transcript. The model then only has to punctuate, and when it fails or is rejected the result
/// is still free of "äh" and "the the" instead of the raw transcript.
///
/// Conservative on purpose, because a wrong deletion loses a real word. German "um" is a word ("um zehn
/// Uhr"), so a bare "um" goes only from a sentence that is clearly English, and never before a number. Only words that never repeat on
/// purpose are collapsed ("the the", "ich ich", not "that that" or "had had").
enum DictationFillerCleanup {
    private static let alwaysFiller = "uh+m?|umm+|erm+|äh+m?|öh+m?|hmm+|mmm+"
    private static let stutterWords = "i|the|a|an|to|and|we|it|is|in|of|for|you|my|ich|wir|und|es|ein|eine|zu|in"

    private static let fillerPattern = try! NSRegularExpression(
        // A hyphen joined to a letter makes it part of a word ("uh-huh", "uh-oh", "mm-hmm"), not a filler.
        pattern: "(,[ \\t]*)?(?<![\\p{L}\\p{N}'’]|\\p{L}-)(?:\(alwaysFiller)|um(?=,))(?![\\p{L}\\p{N}'’]|-\\p{L})([ \\t]*,)?[ \\t]*",
        options: [.caseInsensitive])
    private static let stutterPattern = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}'’])(\(stutterWords))(?:[ \\t]+\\1)+(?![\\p{L}\\p{N}'’])",
        options: [.caseInsensitive])

    static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var value = removeFillers(from: text)
        value = joinSelfCorrections(in: value)
        value = removeEnglishUm(from: value)
        value = collapseStutters(in: value)
        let result = tidy(value)
        // Never turn a transcript into nothing: a lone "uh" stays as spoken.
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : result
    }

    private static func removeFillers(from text: String) -> String {
        let source = text as NSString
        var output = text as NSString
        let matches = fillerPattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {
            let range = match.range
            let hadLeadingComma = match.range(at: 1).location != NSNotFound
            // "so, uh, yes" keeps one comma; a filler between plain words just disappears.
            let replacement = hadLeadingComma ? ", " : ""
            let before = source.substring(to: range.location).trimmingCharacters(in: .whitespaces)
            let startsSentence = !hadLeadingComma && (before.isEmpty || ".!?\n".contains(before.last!))
            output = output.replacingCharacters(in: range, with: replacement) as NSString
            if startsSentence {
                let index = range.location + (replacement as NSString).length
                if index < output.length {
                    let letter = output.substring(with: NSRange(location: index, length: 1))
                    if letter.first?.isLowercase == true {
                        output = output.replacingCharacters(in: NSRange(location: index, length: 1),
                                                            with: letter.uppercased()) as NSString
                    }
                }
            }
        }
        return output as String
    }

    private static let englishWords: Set<String> = [
        "the", "a", "i", "it", "is", "are", "to", "and", "of", "that", "this", "we", "you", "they", "he", "she",
        "think", "my", "be", "for", "with", "but", "can", "will", "would", "should", "do", "have", "not", "if",
        "what", "how", "just", "i'm", "it's", "i'll", "don't", "works", "about", "really", "maybe", "actually"]
    private static let germanWords: Set<String> = [
        "der", "die", "das", "und", "ich", "ist", "nicht", "zu", "den", "dem", "ein", "eine", "mit", "für", "auf",
        "wir", "sie", "es", "ja", "nein", "bitte", "aber", "wenn", "dass", "von", "im", "am", "auch", "noch",
        "schon", "kann", "habe", "haben", "wird", "werden", "mein", "dein", "euch", "uns", "mich", "mir", "sich"]
    private static let sentencePattern = try! NSRegularExpression(pattern: "[^.!?\\n]+[.!?]?")
    private static let umPattern = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}'’])um(?![\\p{L}\\p{N}'’])[ \\t]*,?[ \\t]*", options: [.caseInsensitive])
    private static let wordPattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}]+)?")

    /// Removes a bare "um" from sentences that are clearly English (more English than German function words)
    /// and where it is not followed by a number, so "um 10 Uhr" and "um Hilfe bitten" stay.
    private static func removeEnglishUm(from text: String) -> String {
        let source = text as NSString
        var output = source
        let sentences = sentencePattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        for sentence in sentences.reversed() {
            let value = source.substring(with: sentence.range)
            let valueNS = value as NSString
            let words = wordPattern.matches(in: value, range: NSRange(location: 0, length: valueNS.length))
                .map { valueNS.substring(with: $0.range).lowercased().replacingOccurrences(of: "’", with: "'") }
            let english = words.filter(englishWords.contains).count
            let german = words.filter(germanWords.contains).count
            guard english > german else { continue }
            var rewritten = valueNS
            for match in umPattern.matches(in: value, range: NSRange(location: 0, length: valueNS.length)).reversed() {
                let after = valueNS.substring(from: match.range.location + match.range.length)
                if let next = after.first, next.isNumber { continue }
                let before = valueNS.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
                // "so, um, yes" keeps the comma before it; nothing is left dangling after it.
                let replacement = before.hasSuffix(",") ? " " : ""
                rewritten = rewritten.replacingCharacters(in: match.range, with: replacement) as NSString
                if before.isEmpty || before.hasSuffix("."), let first = after.first, first.isLowercase {
                    let index = match.range.location
                    if index < rewritten.length {
                        let letter = rewritten.substring(with: NSRange(location: index, length: 1))
                        rewritten = rewritten.replacingCharacters(in: NSRange(location: index, length: 1),
                                                                  with: letter.uppercased()) as NSString
                    }
                }
            }
            output = output.replacingCharacters(in: sentence.range, with: rewritten as String) as NSString
        }
        return output as String
    }

    /// Phrases that unmistakably start a spoken self-correction. "I mean" and "or rather" are left out: they begin
    /// ordinary sentences too ("It works. I mean it.").
    private static let strongCorrectionMarkers: [[String]] = [
        ["no", "wait"], ["wait", "no"], ["scratch", "that"], ["strike", "that"], ["actually", "no"],
        ["sorry", "i", "meant"], ["sorry", "i", "mean"], ["no", "i", "mean"],
        ["nein", "warte"], ["warte", "nein"], ["nee", "warte"], ["streich", "das"],
        ["nein", "ich", "meine"], ["sorry", "ich", "meinte"]]
    private static let correctionBreakPattern: NSRegularExpression = {
        let markers = strongCorrectionMarkers.map { $0.joined(separator: "[ \\t,]+") }.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "(?<=[\\p{L}\\p{N}])[.!?]+[ \\t]+((?:\(markers))(?![\\p{L}\\p{N}'’]))[ \\t]*,?",
            options: [.caseInsensitive])
    }()

    /// The speech model ends a sentence before a spoken correction ("Let's meet on Tuesday. No wait, Wednesday at
    /// 10."). The text model removes the corrected words reliably when the correction runs on in the same sentence,
    /// as in its examples, and not when a full stop separates them, so the break goes. The correction phrase itself
    /// stays and is the model's cue; if the model leaves the text as it is, the words are all still there.
    private static func joinSelfCorrections(in text: String) -> String {
        let source = text as NSString
        var output = source
        for match in correctionBreakPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            var marker = source.substring(with: match.range(at: 1))
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            if let first = marker.first { marker = first.lowercased() + marker.dropFirst() }
            output = output.replacingCharacters(in: match.range, with: " " + marker + " ") as NSString
        }
        return output as String
    }

    private static func collapseStutters(in text: String) -> String {
        stutterPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                withTemplate: "$1")
    }

    /// Collapses the double spaces and the "word ," gaps that deletions leave behind.
    private static func tidy(_ text: String) -> String {
        var value = text
        for (pattern, template) in [("[ \\t]{2,}", " "), ("[ \\t]+([,.;:!?])", "$1"), (",{2,}", ","), (",([.!?])", "$1"),
                                    ("^[ \\t]+", ""), ("[ \\t]+$", "")] {
            value = value.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return value
    }
}
