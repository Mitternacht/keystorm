import Foundation
import Testing
@testable import Keystorm

/// Blocked apps, blocked websites and per-app presets: persistence under versioned keys, compatibility with
/// preferences stored before they existed, and the coordinator applying a preset at Start.
@MainActor
@Suite(.serialized)
struct ExclusionPreferencesTests {
    private static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "Keystorm.ExclusionPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test("Preferences stored before exclusions existed load unchanged, with no exclusions and nothing written")
    func olderPreferencesStillLoad() throws {
        try Self.withDefaults { defaults in
            defaults.set("email", forKey: DictationPreferences.modeKey)
            defaults.set("nearbyText", forKey: DictationPreferences.contextModeKey)
            defaults.set("notes", forKey: DictationPreferences.contextProfileKey)
            defaults.set(false, forKey: DictationPreferences.pasteIntoOtherAppsKey)
            let preferences = DictationPreferences(defaults: defaults)
            #expect(preferences.mode == .email)
            #expect(preferences.contextMode == .nearbyText)
            #expect(preferences.contextProfile == .notes)
            #expect(!preferences.pasteIntoOtherApps)
            #expect(preferences.blockedApplications.isEmpty)
            #expect(preferences.blockedWebsites.isEmpty)
            #expect(preferences.appPresets.isEmpty)
            #expect(!preferences.hasUnreadableExclusions)
            #expect(preferences.userExclusions == .empty)
            for key in [DictationPreferences.blockedApplicationsKey, DictationPreferences.blockedWebsitesKey,
                        DictationPreferences.appPresetsKey] {
                #expect(defaults.object(forKey: key) == nil, "Loading never writes \(key).")
            }
        }
    }

    @Test("Exclusion and preset keys are versioned like the existing preference keys")
    func keysAreVersioned() {
        #expect(DictationPreferences.blockedApplicationsKey == "dictation.blockedApplications.v1")
        #expect(DictationPreferences.blockedWebsitesKey == "dictation.blockedWebsites.v1")
        #expect(DictationPreferences.appPresetsKey == "dictation.appPresets.v1")
    }

    @Test("Blocked apps persist, reload, ignore duplicates and stay sorted by name")
    func blockedAppsPersist() throws {
        try Self.withDefaults { defaults in
            let preferences = DictationPreferences(defaults: defaults)
            preferences.blockApplication(bundleIdentifier: "com.example.Zeta", name: "Zeta")
            preferences.blockApplication(bundleIdentifier: " com.example.Alpha ", name: "Alpha")
            preferences.blockApplication(bundleIdentifier: "com.example.Zeta", name: "Zeta again")
            preferences.blockApplication(bundleIdentifier: "", name: "Nothing")
            preferences.blockApplication(bundleIdentifier: "com.example.Unnamed", name: "  ")
            #expect(preferences.blockedApplications.map(\.bundleIdentifier) ==
                    ["com.example.Alpha", "com.example.Unnamed", "com.example.Zeta"])
            #expect(preferences.blockedApplications.first { $0.bundleIdentifier == "com.example.Unnamed" }?.name ==
                    "com.example.Unnamed")
            let reloaded = DictationPreferences(defaults: defaults)
            #expect(reloaded.blockedApplications == preferences.blockedApplications)
            #expect(reloaded.userExclusions.applications == ["com.example.Alpha", "com.example.Unnamed", "com.example.Zeta"])
            reloaded.unblockApplication("com.example.Zeta")
            #expect(DictationPreferences(defaults: defaults).blockedApplications.map(\.bundleIdentifier) ==
                    ["com.example.Alpha", "com.example.Unnamed"])
        }
    }

    @Test("Built-in password managers are never added to, or removable from, the user's list",
          arguments: DictationDeliveryService.passwordManagerBundleIdentifiers.sorted())
    func builtInsAreNotUserEntries(_ identifier: String) {
        let preferences = DictationPreferences()
        preferences.blockApplication(bundleIdentifier: identifier, name: "Vault")
        #expect(preferences.blockedApplications.isEmpty)
        preferences.unblockApplication(identifier)
        #expect(DictationPreferences.isBuiltInExclusion(identifier))
        // Still refused by the service itself, whatever the user's list says.
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        adapter.app.bundleIdentifier = identifier
        #expect(deliverySafetyFailure(DeliverySafetyAdapter.service(adapter)
            .captureTarget(pasteIntoOtherApps: true, exclusions: preferences.userExclusions)) == .excludedApplication)
    }

    @Test("Settings names every built-in password manager identifier exactly once")
    func builtInNamesCoverTheEnforcedList() {
        let named = DictationBuiltInExclusion.passwordManagers.flatMap(\.bundleIdentifiers)
        #expect(Set(named) == DictationDeliveryService.passwordManagerBundleIdentifiers)
        #expect(named.count == Set(named).count)
    }

    @Test("Blocked websites are normalized, deduplicated, persisted and removable; invalid input stores nothing")
    func blockedWebsitesPersist() throws {
        try Self.withDefaults { defaults in
            let preferences = DictationPreferences(defaults: defaults)
            #expect(preferences.blockWebsite("https://www.Bank.example/login"))
            #expect(preferences.blockWebsite("bank.example"))
            #expect(preferences.blockWebsite("*.another.example"))
            #expect(!preferences.blockWebsite("not a domain"))
            #expect(preferences.blockedWebsites == ["another.example", "bank.example"])
            #expect(DictationPreferences(defaults: defaults).blockedWebsites == ["another.example", "bank.example"])
            preferences.unblockWebsite("bank.example")
            #expect(DictationPreferences(defaults: defaults).userExclusions.websites == ["another.example"])
        }
    }

    @Test("Presets persist, change and remove, and choose the mode only for their own app")
    func presetsPersistAndResolve() throws {
        try Self.withDefaults { defaults in
            let preferences = DictationPreferences(defaults: defaults)
            preferences.mode = .verbatim
            preferences.setPreset(.email, bundleIdentifier: "com.apple.mail", name: "Mail")
            preferences.setPreset(.clean, bundleIdentifier: "com.apple.Notes", name: "Notes")
            preferences.setPreset(.verbatim, bundleIdentifier: "com.apple.Notes", name: "Notes")
            #expect(preferences.appPresets.map(\.name) == ["Mail", "Notes"])
            #expect(preferences.quickMode(for: "com.apple.mail") == .email)
            #expect(preferences.quickMode(for: "com.apple.Notes") == .verbatim)
            preferences.mode = .clean
            #expect(preferences.quickMode(for: "com.example.Other") == .clean)
            #expect(preferences.quickMode(for: nil) == .clean)
            let reloaded = DictationPreferences(defaults: defaults)
            #expect(reloaded.appPresets == preferences.appPresets)
            reloaded.setPreset(nil, bundleIdentifier: "com.apple.mail", name: "Mail")
            #expect(DictationPreferences(defaults: defaults).appPreset(for: "com.apple.mail") == nil)
        }
    }

    @Test("A stored preset naming translation or another non-Quick mode is ignored; the other entries still load",
          arguments: ["translateEnglish", "translateGerman", "summarize", "organize", "CLEAN", "futureMode"])
    func translationIsNeverAPreset(_ storedMode: String) throws {
        try Self.withDefaults { defaults in
            let json = """
            [{"bundleIdentifier":"com.apple.mail","name":"Mail","mode":"\(storedMode)"},
             {"bundleIdentifier":"com.apple.Notes","name":"Notes","mode":"clean","addedLater":true}]
            """
            defaults.set(Data(json.utf8), forKey: DictationPreferences.appPresetsKey)
            let preferences = DictationPreferences(defaults: defaults)
            #expect(preferences.appPresets.map(\.bundleIdentifier) == ["com.apple.Notes"],
                    "An entry with an unknown extra field still loads.")
            #expect(preferences.quickMode(for: "com.apple.mail") == .verbatim)
            #expect(preferences.hasUnreadableExclusions)
            #expect(defaults.data(forKey: DictationPreferences.appPresetsKey) == Data(json.utf8),
                    "Unreadable entries stay stored until the list is changed.")
        }
    }

    @Test("Unreadable stored lists load as empty, are reported, and are left untouched", arguments: [
        Data("not json".utf8), Data("{\"bundleIdentifier\":\"com.example.App\"}".utf8), Data([0xFF, 0x00])
    ])
    func malformedStorageIsReported(_ data: Data) throws {
        try Self.withDefaults { defaults in
            for key in [DictationPreferences.blockedApplicationsKey, DictationPreferences.blockedWebsitesKey,
                        DictationPreferences.appPresetsKey] {
                defaults.set(data, forKey: key)
            }
            let preferences = DictationPreferences(defaults: defaults)
            #expect(preferences.blockedApplications.isEmpty)
            #expect(preferences.blockedWebsites.isEmpty)
            #expect(preferences.appPresets.isEmpty)
            #expect(preferences.hasUnreadableExclusions)
            #expect(defaults.data(forKey: DictationPreferences.blockedApplicationsKey) == data)
        }
    }

    @Test("Changing a list that held unreadable entries replaces them and ends the report for that list only")
    func changingAnUnreadableListEndsItsReport() throws {
        try Self.withDefaults { defaults in
            let unreadable = Data("not json".utf8)
            defaults.set(unreadable, forKey: DictationPreferences.blockedApplicationsKey)
            defaults.set(unreadable, forKey: DictationPreferences.appPresetsKey)
            let preferences = DictationPreferences(defaults: defaults)
            #expect(preferences.hasUnreadableExclusions)
            preferences.blockApplication(bundleIdentifier: "com.example.Vault", name: "Vault")
            #expect(defaults.data(forKey: DictationPreferences.blockedApplicationsKey) != unreadable)
            #expect(preferences.hasUnreadableExclusions, "The presets list still holds unreadable entries.")
            #expect(defaults.data(forKey: DictationPreferences.appPresetsKey) == unreadable)
            preferences.setPreset(.clean, bundleIdentifier: "com.apple.Notes", name: "Notes")
            #expect(!preferences.hasUnreadableExclusions)
            let reloaded = DictationPreferences(defaults: defaults)
            #expect(!reloaded.hasUnreadableExclusions)
            #expect(reloaded.blockedApplications.map(\.bundleIdentifier) == ["com.example.Vault"])
            #expect(reloaded.appPresets.map(\.bundleIdentifier) == ["com.apple.Notes"])
        }
    }

    @Test("A stored website that is no longer a valid domain is dropped and reported")
    func invalidStoredWebsiteIsReported() throws {
        try Self.withDefaults { defaults in
            defaults.set(Data(#"["Example.com", "not a domain", "example.com"]"#.utf8), forKey: DictationPreferences.blockedWebsitesKey)
            let preferences = DictationPreferences(defaults: defaults)
            #expect(preferences.blockedWebsites == ["example.com"])
            #expect(preferences.hasUnreadableExclusions)
        }
    }

    // MARK: Presets at Start

    @Test("A preset chooses this recording's mode at Start without changing Next recording")
    func presetAppliesAtStart() async {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        let preferences = DictationPreferences()
        preferences.mode = .verbatim
        preferences.setPreset(.email, bundleIdentifier: "com.apple.Notes", name: "Notes")
        let backend = DeliverySafetyBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: DeliverySafetyAdapter.service(adapter),
                                               preferences: preferences)
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .recording)
        #expect(backend.beginModes == [.email])
        #expect(coordinator.captureMode == .email)
        #expect(preferences.mode == .verbatim)
        #expect(coordinator.message.hasSuffix("Using the Email preset for Notes."))
    }

    @Test("A preset also applies when the destination is Copy-only, because it follows the app in front")
    func presetAppliesWithoutDestination() async {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        adapter.isTrusted = false
        let preferences = DictationPreferences()
        preferences.setPreset(.clean, bundleIdentifier: "com.apple.Notes", name: "Notes")
        let backend = DeliverySafetyBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: DeliverySafetyAdapter.service(adapter),
                                               preferences: preferences)
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.destinationLabel == "Copy after recording")
        #expect(backend.beginModes == [.clean])
    }

    @Test("Other apps, Long Recording and Keystorm itself use the Next recording mode", arguments: PresetBypass.allCases)
    func presetDoesNotApplyElsewhere(_ bypass: PresetBypass) async {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        let preferences = DictationPreferences()
        preferences.mode = .clean
        preferences.setPreset(.email, bundleIdentifier: "com.apple.Notes", name: "Notes")
        let backend = DeliverySafetyBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: DeliverySafetyAdapter.service(adapter),
                                               preferences: preferences)
        switch bypass {
        case .otherApp:
            adapter.app = DictationDeliveryApplication(processIdentifier: 77, bundleIdentifier: "com.example.Other", name: "Other")
            coordinator.toggle()
        case .longRecording:
            coordinator.startLongRecording()
        case .keystormInFront:
            adapter.app = DictationDeliveryApplication(processIdentifier: 900, bundleIdentifier: "test.keystorm", name: "Keystorm")
            coordinator.toggle()
        }
        await coordinator.waitUntilSettled()
        #expect(backend.beginModes == [bypass == .longRecording ? .verbatim : .clean])
        #expect(!coordinator.message.contains("preset"))
    }
}

enum PresetBypass: CaseIterable, Sendable { case otherApp, longRecording, keystormInFront }
