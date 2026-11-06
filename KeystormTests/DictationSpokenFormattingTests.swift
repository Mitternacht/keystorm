import Foundation
import Testing
@testable import Keystorm

/// The deterministic spoken-formatting pre-pass: pure text in, text out, no model, no hardware.
struct DictationSpokenFormattingTests {
    private static let converted: [(String, String)] = [
        // English punctuation, including the punctuation a speech model writes around a command word.
        ("Hello comma how are you question mark", "Hello, how are you?"),
        ("Hello, comma, how are you? Question mark.", "Hello, how are you?"),
        ("Is it ready question mark Yes exclamation point", "Is it ready? Yes!"),
        ("I went home period I slept", "I went home. I slept"),
        ("Note colon call Anna semicolon then Bob", "Note: call Anna; then Bob"),
        ("Done full stop Next topic", "Done. Next topic"),
        // English layout.
        ("Dear Anna new paragraph thanks for the update", "Dear Anna\n\nThanks for the update"),
        ("first line new line second line", "first line\nsecond line"),
        ("Hello new line world new paragraph again", "Hello\nworld\n\nAgain"),
        ("one line break two", "one\ntwo"),
        // German.
        ("Ich komme morgen Punkt wir treffen uns", "Ich komme morgen. Wir treffen uns"),
        ("Achtung Doppelpunkt bitte leise bleiben Ausrufezeichen", "Achtung: bitte leise bleiben!"),
        ("Wie geht es dir Fragezeichen mir geht es gut", "Wie geht es dir? Mir geht es gut"),
        ("Hallo Anna neue Zeile bis bald", "Hallo Anna\nbis bald"),
        ("Das ist wichtig neuer Absatz bitte lesen", "Das ist wichtig\n\nBitte lesen"),
        ("Das ist wichtig Absatz bitte lesen", "Das ist wichtig\n\nBitte lesen"),
        ("Ich komme Komma wenn es passt", "Ich komme, wenn es passt"),
        // A German decimal comma is joined to its digits.
        ("das kostet 3 Komma 5 Euro", "das kostet 3,5 Euro")
    ]

    @Test(arguments: converted)
    func `Spoken punctuation and line-break commands become symbols`(source: String, expected: String) {
        #expect(DictationSpokenFormatting.apply(to: source) == expected)
    }

    private static let unchanged: [String] = [
        "the comma is missing",
        "Ich habe ein Komma vergessen",
        "the trial period ends on Friday",
        "the project period is long",
        "a long period of time",
        "Punkt 3 der Tagesordnung",
        "Das ist ein kleiner Punkt.",
        "Absatz 2 gilt weiter",
        "im Absatz steht nichts",
        "create new line items for the invoice",
        "this is a new line of products",
        "Please keep the new paragraph structure",
        "I have a question mark on my screen",
        "Version 2 Punkt 5 ist fertig",
        "Nothing to change here.",
        ""
    ]

    @Test(arguments: unchanged)
    func `Nouns, numbered references and ordinary text are never rewritten`(text: String) {
        #expect(DictationSpokenFormatting.apply(to: text) == text)
    }

    @Test func `A lone command stays a transcript instead of becoming a blank`() {
        #expect(DictationSpokenFormatting.apply(to: "new line") == "new line")
        #expect(DictationSpokenFormatting.apply(to: "  new paragraph  ") == "  new paragraph  ")
    }

    @Test func `Applying the pre-pass twice changes nothing more`() {
        for source in ["Hello, comma, how are you? Question mark.", "Dear Anna new paragraph thanks", "Ich komme morgen Punkt wir gehen",
                       "das kostet 3 Komma 5 Euro"] {
            let once = DictationSpokenFormatting.apply(to: source)
            #expect(DictationSpokenFormatting.apply(to: once) == once)
        }
    }

    @Test func `Non-command text keeps its whitespace and its umlauts`() {
        let text = "  Grüße aus München\tund Köln \n"
        #expect(DictationSpokenFormatting.apply(to: text) == text)
    }

    @Test func `The command table is longest-first and has no empty phrase`() {
        let counts = DictationSpokenCommands.phrases.map(\.words.count)
        #expect(counts == counts.sorted(by: >))
        #expect(DictationSpokenCommands.phrases.allSatisfy { !$0.words.isEmpty && $0.words.allSatisfy { $0 == $0.lowercased() } })
        #expect(DictationSpokenCommands.correctionMarkers.allSatisfy { !$0.isEmpty })
    }

    @MainActor
    @Test func `The preference is on by default and survives a reload`() throws {
        let suiteName = "KeystormTests.spokenFormatting.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(DictationPreferences(defaults: defaults).spokenFormattingCommands)
        #expect(DictationPreferences().spokenFormattingCommands)
        let preferences = DictationPreferences(defaults: defaults)
        preferences.spokenFormattingCommands = false
        #expect(!DictationPreferences(defaults: defaults).spokenFormattingCommands)
        preferences.spokenFormattingCommands = true
        #expect(DictationPreferences(defaults: defaults).spokenFormattingCommands)
    }
}
