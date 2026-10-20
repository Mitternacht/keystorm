import Foundation
import Testing
@testable import Keystorm

@MainActor
struct DictationPreferencesTests {
    @Test("New and in-memory preferences preserve Verbatim behavior")
    func missingPreferenceIsVerbatim() throws {
        let suiteName = "Keystorm.DictationPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(DictationPreferences(defaults: defaults).mode == .verbatim)
        #expect(defaults.object(forKey: DictationPreferences.modeKey) == nil)
        let first = DictationPreferences()
        first.mode = .clean
        #expect(DictationPreferences().mode == .verbatim)
    }

    @Test("An explicit selection is restored from the injected preferences store")
    func selectedModePersists() throws {
        let suiteName = "Keystorm.DictationPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = DictationPreferences(defaults: defaults)
        preferences.mode = .clean
        #expect(defaults.string(forKey: DictationPreferences.modeKey) == "clean")
        #expect(DictationPreferences(defaults: defaults).mode == .clean)
        preferences.mode = .verbatim
        #expect(DictationPreferences(defaults: defaults).mode == .verbatim)
    }

    @Test("Unknown and preview-only modes cannot enable automatic rewriting",
          arguments: ["summarize", "organize", "translateEnglish", "translateGerman", "CLEAN", "EMAIL", "", "futureMode"])
    func invalidModeFallsBackToVerbatim(_ storedValue: String) throws {
        let suiteName = "Keystorm.DictationPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(storedValue, forKey: DictationPreferences.modeKey)
        #expect(DictationPreferences(defaults: defaults).mode == .verbatim)
        #expect(defaults.string(forKey: DictationPreferences.modeKey) == storedValue)
    }

    @Test("Where Verbatim is chosen, it discloses that spoken numbers can become digits")
    func verbatimDisclosesDigits() {
        let detail = String(localized: DictationQuickMode.verbatim.detail)
        #expect(detail.contains("spoken numbers as digits"))
        #expect(detail.contains("“fünf” becomes “5”"))
        // Verbatim must not run a text model, so the digits come from the speech model, not a rewrite.
        #expect(!DictationQuickMode.verbatim.transformsOnFinish)
    }

    @Test("Quick modes only map to Verbatim, Clean and Email output, never translation")
    func availableModesAreSafeForQuickDictation() {
        #expect(DictationQuickMode.allCases == [.verbatim, .clean, .email])
        #expect(DictationQuickMode.verbatim.outputMode == .verbatim)
        #expect(DictationQuickMode.clean.outputMode == .clean)
        #expect(DictationQuickMode.email.outputMode == .email)
        #expect(DictationQuickMode.allCases.allSatisfy { $0.outputMode.translationTarget == nil })
    }
}
