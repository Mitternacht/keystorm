import Foundation
import Testing
@testable import Keystorm

/// Uses a private defaults suite and never registers global keys.
@MainActor
struct DictationShortcutMigrationTests {
    private let storageKey = "Keystorm.globalShortcuts.v1"
    private let behaviorKey = "Keystorm.recordingBehavior.v1"

    @Test("Version 1 migration preserves custom and disabled legacy shortcuts and recording behavior")
    func migrationPreservesLegacyAssignments() throws {
        let suite = "Keystorm.DictationShortcutMigration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = GlobalShortcut(keyCode: 80, modifiers: [.command, .option], keyLabel: "F19")
        let workspace = GlobalShortcut(keyCode: 79, modifiers: [.command, .control], keyLabel: "F18")
        let legacy = ShortcutPreferences(version: 1, shortcuts: [
            ShortcutAction.toggleRecording.rawValue: record,
            ShortcutAction.showWorkspace.rawValue: workspace
            // recordEdit is deliberately disabled.
        ])
        defaults.set(try JSONEncoder().encode(legacy), forKey: storageKey)
        defaults.set(RecordingBehavior.hold.rawValue, forKey: behaviorKey)
        var registrations = 0
        let manager = ShortcutManager(defaults: defaults, registerOperation: { _, _, _ in
            registrations += 1
            return 0
        })
        #expect(manager.preferences.version == 2)
        #expect(manager.shortcut(for: .toggleRecording) == record)
        #expect(manager.shortcut(for: .showWorkspace) == workspace)
        #expect(manager.shortcut(for: .recordEdit) == nil)
        #expect(manager.recordingBehavior == .hold)
        #expect(manager.shortcut(for: .toggleDictation) == ShortcutPreferences.defaults.shortcuts[ShortcutAction.toggleDictation.rawValue])
        #expect(manager.shortcut(for: .pauseResumeDictation) == ShortcutPreferences.defaults.shortcuts[ShortcutAction.pauseResumeDictation.rawValue])
        #expect(registrations == 0)
        let migrated = try JSONDecoder().decode(ShortcutPreferences.self, from: #require(defaults.data(forKey: storageKey)))
        #expect(migrated == manager.preferences)
        let relaunched = ShortcutManager(defaults: defaults)
        #expect(relaunched.preferences == migrated)
        #expect(relaunched.recordingBehavior == .hold)
    }

    @Test("Clearing an added dictation shortcut survives every subsequent launch",
          arguments: [ShortcutAction.toggleDictation, .pauseResumeDictation])
    func clearedDictationShortcutStaysDisabled(_ action: ShortcutAction) throws {
        let suite = "Keystorm.DictationShortcutClear." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyRecord = GlobalShortcut(keyCode: 80, modifiers: [.command, .option], keyLabel: "F19")
        let legacy = ShortcutPreferences(version: 1, shortcuts: [ShortcutAction.toggleRecording.rawValue: legacyRecord])
        defaults.set(try JSONEncoder().encode(legacy), forKey: storageKey)
        let migrated = ShortcutManager(defaults: defaults)
        try #require(migrated.shortcut(for: action) != nil)
        try migrated.setShortcut(nil, for: action)
        #expect(migrated.preferences.version == 2)
        for _ in 0..<3 {
            let relaunched = ShortcutManager(defaults: defaults)
            #expect(relaunched.shortcut(for: action) == nil)
            #expect(relaunched.shortcut(for: .toggleRecording) == legacyRecord)
            #expect(relaunched.preferences.version == 2)
        }
        let saved = try JSONDecoder().decode(ShortcutPreferences.self, from: #require(defaults.data(forKey: storageKey)))
        #expect(saved.version == 2)
        #expect(saved.shortcuts[action.rawValue] == nil)
    }

    @Test("Version 2 preferences with every action disabled never regain default dictation bindings")
    func versionTwoDoesNotRepeatMigration() throws {
        let suite = "Keystorm.DictationShortcutDisabled." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let disabled = ShortcutPreferences(version: 2, shortcuts: [:])
        defaults.set(try JSONEncoder().encode(disabled), forKey: storageKey)
        let manager = ShortcutManager(defaults: defaults)
        #expect(manager.preferences == disabled)
        #expect(ShortcutAction.allCases.allSatisfy { manager.shortcut(for: $0) == nil })
        let saved = try JSONDecoder().decode(ShortcutPreferences.self, from: #require(defaults.data(forKey: storageKey)))
        #expect(saved == disabled)
    }
}
