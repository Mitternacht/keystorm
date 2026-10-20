import Foundation

/// An app the user blocked from Quick dictation. Matching uses the bundle identifier only; the name is for display.
struct DictationBlockedApplication: Codable, Equatable, Identifiable, Sendable {
    var bundleIdentifier: String
    var name: String
    var id: String { bundleIdentifier }
}

/// The Quick mode to use when dictation starts in one app. Only Quick modes can be stored: translation is never
/// a preset, because it needs an explicit post-recording transform and Apply. A stored preview-only mode such as
/// "translateEnglish" fails to decode and the entry is dropped.
struct DictationAppPreset: Codable, Equatable, Identifiable, Sendable {
    var bundleIdentifier: String
    var name: String
    var mode: DictationQuickMode
    var id: String { bundleIdentifier }
}

/// User exclusions as one recording sees them: read at Start, and read again at Finish so an app or website
/// blocked during the recording is never written to. The built-in password managers are not part of this value;
/// the delivery service always enforces them itself.
struct DictationUserExclusions: Equatable, Sendable {
    var applications: Set<String> = []
    /// Normalized domains; see `DictationWebsiteExclusion.normalizedDomain(_:)`.
    var websites: [String] = []

    static let empty = DictationUserExclusions()
}

/// A built-in exclusion as Settings shows it. Built-ins cannot be removed.
struct DictationBuiltInExclusion: Identifiable, Sendable {
    let name: String
    let bundleIdentifiers: [String]
    var id: String { name }

    /// Display names for `DictationDeliveryService.passwordManagerBundleIdentifiers`; a test keeps both in step.
    static let passwordManagers: [DictationBuiltInExclusion] = [
        DictationBuiltInExclusion(name: "1Password", bundleIdentifiers: [
            "com.1password.1password", "com.agilebits.onepassword7",
            "com.agilebits.onepassword-osx", "com.agilebits.onepassword4"
        ]),
        DictationBuiltInExclusion(name: "Passwords", bundleIdentifiers: ["com.apple.Passwords"]),
        DictationBuiltInExclusion(name: "Keychain Access", bundleIdentifiers: ["com.apple.keychainaccess"]),
        DictationBuiltInExclusion(name: "Bitwarden", bundleIdentifiers: ["com.bitwarden.desktop"]),
        DictationBuiltInExclusion(name: "KeePassXC", bundleIdentifiers: ["org.keepassxc.keepassxc"]),
        DictationBuiltInExclusion(name: "LastPass", bundleIdentifiers: ["com.lastpass.LastPass"]),
        DictationBuiltInExclusion(name: "Dashlane", bundleIdentifiers: [
            "com.dashlane.dashlanephonefinal", "com.dashlane.Dashlane"
        ]),
        DictationBuiltInExclusion(name: "Enpass", bundleIdentifiers: ["in.sinew.Enpass-Desktop"]),
        DictationBuiltInExclusion(name: "Proton Pass", bundleIdentifiers: ["me.proton.pass.electron"])
    ]
}

/// What the delivery adapter could learn about the web documents around a focused element.
/// Only Accessibility metadata is used (each ancestor's role and a web area's document address), never a field's value.
enum DictationWebDocumentLookup: Equatable, Sendable {
    /// The element is not inside web content, such as a native field or a browser's address bar.
    case notWebContent
    /// The addresses of the web documents that contain the element, innermost first (an iframe before its page).
    /// nil marks a document that reported no readable address.
    case webContent([URL?])
    /// The ancestry could not be read safely.
    case unavailable
}

enum DictationWebsiteVerdict: Equatable, Sendable {
    /// No website is blocked, so nothing was looked up.
    case notChecked
    case notWebContent
    case allowed
    case blocked
    /// Web content whose address could not be established. Treated as unsafe: nothing is pasted and no context is used.
    case unverified
}

/// Pure website-exclusion rules. Addresses are compared in memory at Start and Finish and are never stored.
enum DictationWebsiteExclusion {
    static let maximumDomainUTF8 = 253

    /// Turns what a user typed into a lowercase ASCII domain, or nil when it is not a plain domain name.
    /// "https://www.Example.com/login" becomes "example.com". A leading "www." or "*." is dropped, because
    /// blocking a domain also blocks its subdomains. International names must use their ASCII ("xn--") form.
    static func normalizedDomain(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let end = text.firstIndex(where: { "/?#".contains($0) }) { text = String(text[..<end]) }
        if let userInfo = text.lastIndex(of: "@") { text = String(text[text.index(after: userInfo)...]) }
        if let port = text.firstIndex(of: ":") { text = String(text[..<port]) }
        while text.hasSuffix(".") { text.removeLast() }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        // "www.example.com" means example.com, but "www.com" is not shortened to a bare top-level domain.
        if text.hasPrefix("www."), text.dropFirst(4).contains(".") { text.removeFirst(4) }
        return isValidDomain(text) ? text : nil
    }

    /// At least two ASCII labels of letters, digits and inner hyphens. The last label contains a letter,
    /// unless the whole name is an IPv4 address.
    static func isValidDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.utf8.count <= maximumDomainUTF8,
              domain.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard (1...63).contains(label.count), label.allSatisfy(allowed.contains),
                  label.first != "-", label.last != "-" else { return false }
        }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return labels.count == 4 && labels.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
        }
        return labels.last?.contains(where: \.isLetter) == true
    }

    /// A host matches a blocked domain itself and every subdomain of it.
    static func host(_ host: String, matches domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    private enum DocumentKind {
        case host(String)
        /// A file has no domain to match.
        case local
        /// about:blank and about:srcdoc take their origin from the document that contains them.
        case inheriting
        case unknown
    }

    private static func kind(of url: URL) -> DocumentKind {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" { return .inheriting }
        if let rawHost = url.host(percentEncoded: true), !rawHost.isEmpty {
            // A host this check cannot compare exactly (non-ASCII or percent-encoded) is not guessed at.
            guard rawHost.unicodeScalars.allSatisfy({ $0.isASCII }), !rawHost.contains("%") else { return .unknown }
            var host = rawHost.lowercased()
            while host.hasSuffix(".") { host.removeLast() }
            return host.isEmpty ? .unknown : .host(host)
        }
        return scheme == "file" ? .local : .unknown
    }

    /// Blocked when any containing document's host matches; allowed only when every document's address was read
    /// and the outermost one is a real page. Anything else is unverified and fails safe.
    static func verdict(_ lookup: DictationWebDocumentLookup, blockedDomains: [String]) -> DictationWebsiteVerdict {
        guard !blockedDomains.isEmpty else { return .notChecked }
        switch lookup {
        case .unavailable:
            return .unverified
        case .notWebContent:
            return .notWebContent
        case .webContent(let documents):
            guard !documents.isEmpty else { return .unverified }
            var verified = true
            for (index, url) in documents.enumerated() {
                guard let url else { verified = false; continue }
                switch kind(of: url) {
                case .host(let host):
                    if blockedDomains.contains(where: { Self.host(host, matches: $0) }) { return .blocked }
                case .local:
                    break
                case .inheriting:
                    // An inheriting outermost document has nothing to inherit from.
                    if index == documents.count - 1 { verified = false }
                case .unknown:
                    verified = false
                }
            }
            return verified ? .allowed : .unverified
        }
    }
}

/// Exclusions and presets are stored as JSON arrays under versioned keys. Each entry decodes on its own, so one
/// unreadable entry (for example a preset naming a mode this version does not offer) never discards the rest.
enum DictationExclusionStorage {
    struct Decoded<Entry> {
        var entries: [Entry]
        /// False when stored data or an entry could not be read; those parts are ignored.
        var isComplete: Bool
    }

    static func decode<Entry: Decodable>(_ type: Entry.Type, from data: Data?) -> Decoded<Entry> {
        guard let data else { return Decoded(entries: [], isComplete: true) }
        guard let lossy = try? JSONDecoder().decode([LossyEntry<Entry>].self, from: data) else {
            return Decoded(entries: [], isComplete: false)
        }
        let entries = lossy.compactMap(\.value)
        return Decoded(entries: entries, isComplete: entries.count == lossy.count)
    }

    static func encode<Entry: Encodable>(_ entries: [Entry]) -> Data? {
        try? JSONEncoder().encode(entries)
    }
}

private struct LossyEntry<Entry: Decodable>: Decodable {
    let value: Entry?

    init(from decoder: any Decoder) throws {
        value = try? Entry(from: decoder)
    }
}
