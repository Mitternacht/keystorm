import Foundation
import Observation

/// Only modes suitable for direct dictation may be selected before recording. Translation
/// is deliberately absent: it requires an explicit post-recording transform and Apply.
enum DictationQuickMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case verbatim
    case clean
    case email

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .verbatim: "Verbatim"
        case .clean: "Clean"
        case .email: "Email"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        // Verbatim delivers the speech model's text unchanged; that model can write spoken numbers as
        // digits (observed 2026-10-20: spoken "fünf" came out as "5"), and nothing in Keystorm undoes it.
        case .verbatim: "Finish with the words you spoke. The speech model can write spoken numbers as digits, so “fünf” becomes “5”."
        case .clean: "Clean up punctuation and fillers on this Mac when you finish. Your original is always saved."
        case .email: "Clean up and split into email paragraphs on this Mac when you finish. Nothing is added or translated, and your original is always saved."
        }
    }

    var outputMode: DictationOutputMode {
        switch self {
        case .verbatim: .verbatim
        case .clean: .clean
        case .email: .email
        }
    }

    /// Clean and Email run one validated local transform on Finish, after the raw transcript
    /// is durable and before any delivery. Verbatim never invokes a text model.
    var transformsOnFinish: Bool {
        switch self {
        case .verbatim: false
        case .clean, .email: true
        }
    }
}

/// A recording snapshots this preference at Start. Tests can omit a defaults store.
@MainActor @Observable
final class DictationPreferences {
    static let modeKey = "dictation.quickMode.v1"
    static let contextModeKey = "dictation.contextMode.v1"
    static let contextProfileKey = "dictation.contextProfile.v1"

    var contextMode: DictationContextMode {
        didSet { defaults?.set(contextMode.rawValue, forKey: Self.contextModeKey) }
    }
    var contextProfile: DictationContextProfileSelection {
        didSet { defaults?.set(contextProfile.rawValue, forKey: Self.contextProfileKey) }
    }
    var contextSettings: DictationContextSettings {
        DictationContextSettings(mode: contextMode, profile: contextProfile)
    }

    static let pasteIntoOtherAppsKey = "dictation.pasteIntoOtherApps.v1"
    /// Validated paste fallback outside qualified adapters. Snapshotted at Start; on when never set.
    var pasteIntoOtherApps: Bool {
        didSet { defaults?.set(pasteIntoOtherApps, forKey: Self.pasteIntoOtherAppsKey) }
    }

    var mode: DictationQuickMode {
        didSet { defaults?.set(mode.rawValue, forKey: Self.modeKey) }
    }

    // Exclusions and presets: JSON arrays under their own versioned keys. Missing keys mean none, so
    // preferences stored before these existed load unchanged.
    static let blockedApplicationsKey = "dictation.blockedApplications.v1"
    static let blockedWebsitesKey = "dictation.blockedWebsites.v1"
    static let appPresetsKey = "dictation.appPresets.v1"

    /// Apps where Quick dictation never starts, in addition to the built-in password managers.
    private(set) var blockedApplications: [DictationBlockedApplication] {
        didSet { store(blockedApplications, forKey: Self.blockedApplicationsKey) }
    }
    /// Normalized domains; each also covers its subdomains.
    private(set) var blockedWebsites: [String] {
        didSet { store(blockedWebsites, forKey: Self.blockedWebsitesKey) }
    }
    /// Per-app Quick modes, applied at Start for that app's bundle identifier.
    private(set) var appPresets: [DictationAppPreset] {
        didSet { store(appPresets, forKey: Self.appPresetsKey) }
    }
    /// True when stored exclusions or presets held entries this version cannot read. They are ignored, and
    /// they stay stored until the user next changes that list, which also ends the report for that list.
    var hasUnreadableExclusions: Bool { !unreadableListKeys.isEmpty }
    /// Storage keys of the lists that held unreadable entries when they were loaded.
    private var unreadableListKeys: Set<String> = []

    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        let storedMode = defaults?.string(forKey: Self.modeKey)
        self.mode = storedMode.flatMap(DictationQuickMode.init(rawValue:)) ?? .verbatim
        self.contextMode = defaults?.string(forKey: Self.contextModeKey)
            .flatMap(DictationContextMode.init(rawValue:)) ?? .off
        self.contextProfile = defaults?.string(forKey: Self.contextProfileKey)
            .flatMap(DictationContextProfileSelection.init(rawValue:)) ?? .automatic
        if let defaults, defaults.object(forKey: Self.pasteIntoOtherAppsKey) != nil {
            self.pasteIntoOtherApps = defaults.bool(forKey: Self.pasteIntoOtherAppsKey)
        } else {
            self.pasteIntoOtherApps = true
        }
        let applications = DictationExclusionStorage.decode(DictationBlockedApplication.self,
            from: defaults?.data(forKey: Self.blockedApplicationsKey))
        let websites = DictationExclusionStorage.decode(String.self,
            from: defaults?.data(forKey: Self.blockedWebsitesKey))
        let presets = DictationExclusionStorage.decode(DictationAppPreset.self,
            from: defaults?.data(forKey: Self.appPresetsKey))
        var seenApplications = Set<String>()
        self.blockedApplications = applications.entries.filter {
            !$0.bundleIdentifier.isEmpty && seenApplications.insert($0.bundleIdentifier).inserted
        }
        var seenWebsites = Set<String>()
        let normalizedWebsites = websites.entries.compactMap(DictationWebsiteExclusion.normalizedDomain)
        self.blockedWebsites = normalizedWebsites.filter { seenWebsites.insert($0).inserted }
        var seenPresets = Set<String>()
        self.appPresets = presets.entries.filter {
            !$0.bundleIdentifier.isEmpty && seenPresets.insert($0.bundleIdentifier).inserted
        }
        var unreadable = Set<String>()
        if !applications.isComplete { unreadable.insert(Self.blockedApplicationsKey) }
        if !websites.isComplete || normalizedWebsites.count != websites.entries.count {
            unreadable.insert(Self.blockedWebsitesKey)
        }
        if !presets.isComplete { unreadable.insert(Self.appPresetsKey) }
        unreadableListKeys = unreadable
    }

    /// What Start and Finish check, besides the built-in password managers.
    var userExclusions: DictationUserExclusions {
        DictationUserExclusions(applications: Set(blockedApplications.map(\.bundleIdentifier)), websites: blockedWebsites)
    }

    static func isBuiltInExclusion(_ bundleIdentifier: String) -> Bool {
        DictationDeliveryService.passwordManagerBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Built-in password managers are already blocked and are never added; duplicates are ignored.
    func blockApplication(bundleIdentifier: String, name: String) {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !Self.isBuiltInExclusion(identifier),
              !blockedApplications.contains(where: { $0.bundleIdentifier == identifier }) else { return }
        let entry = DictationBlockedApplication(bundleIdentifier: identifier, name: Self.displayName(name, identifier))
        let index = blockedApplications.firstIndex {
            $0.name.localizedStandardCompare(entry.name) == .orderedDescending
        } ?? blockedApplications.endIndex
        blockedApplications.insert(entry, at: index)
    }

    func unblockApplication(_ bundleIdentifier: String) {
        blockedApplications.removeAll { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Returns false, and stores nothing, when the input is not a plain domain name.
    @discardableResult
    func blockWebsite(_ input: String) -> Bool {
        guard let domain = DictationWebsiteExclusion.normalizedDomain(input) else { return false }
        guard !blockedWebsites.contains(domain) else { return true }
        let index = blockedWebsites.firstIndex { $0 > domain } ?? blockedWebsites.endIndex
        blockedWebsites.insert(domain, at: index)
        return true
    }

    func unblockWebsite(_ domain: String) {
        blockedWebsites.removeAll { $0 == domain }
    }

    func appPreset(for bundleIdentifier: String?) -> DictationAppPreset? {
        guard let bundleIdentifier else { return nil }
        return appPresets.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Adds, changes or (with nil) removes one app's preset. The mode type admits Quick modes only.
    func setPreset(_ mode: DictationQuickMode?, bundleIdentifier: String, name: String) {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        guard let mode else {
            appPresets.removeAll { $0.bundleIdentifier == identifier }
            return
        }
        if let existing = appPresets.firstIndex(where: { $0.bundleIdentifier == identifier }) {
            appPresets[existing].mode = mode
            return
        }
        let entry = DictationAppPreset(bundleIdentifier: identifier, name: Self.displayName(name, identifier), mode: mode)
        let index = appPresets.firstIndex {
            $0.name.localizedStandardCompare(entry.name) == .orderedDescending
        } ?? appPresets.endIndex
        appPresets.insert(entry, at: index)
    }

    /// The mode a recording that starts in this app uses: its preset, otherwise the Next recording choice.
    func quickMode(for bundleIdentifier: String?) -> DictationQuickMode {
        appPreset(for: bundleIdentifier)?.mode ?? mode
    }

    private static func displayName(_ name: String, _ identifier: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? identifier : trimmed
    }

    private func store<Entry: Encodable>(_ entries: [Entry], forKey key: String) {
        guard let defaults, let data = DictationExclusionStorage.encode(entries) else { return }
        defaults.set(data, forKey: key)
        // The unreadable entries of this list were just replaced, so they are no longer stored.
        if unreadableListKeys.contains(key) { unreadableListKeys.remove(key) }
    }
}
