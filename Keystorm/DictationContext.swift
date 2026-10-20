import CryptoKit
import Foundation

enum DictationContextMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, application, nearbyText
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .application: "App only"
        case .nearbyText: "Nearby text"
        }
    }
}

enum DictationContextProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case general, email, chat, notes, developer
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .general: "General"
        case .email: "Email"
        case .chat: "Chat"
        case .notes: "Notes"
        case .developer: "Developer"
        }
    }

    /// Fixed product hints; no application name or field contents becomes an instruction.
    var formattingHint: String {
        switch self {
        case .general: "Use natural punctuation and paragraph boundaries."
        case .email: "Use readable paragraphs at spoken topic boundaries. Do not add greetings, signatures or recipients."
        case .chat: "Use compact punctuation and short paragraphs. Do not add emoji, slang or conversational replies."
        case .notes: "Use paragraph breaks at spoken topic boundaries. Do not add headings, bullets or action items."
        case .developer: "Use conservative punctuation around technical dictation. Preserve every literal identifier and code fragment."
        }
    }
}

enum DictationContextProfileSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, general, email, chat, notes, developer
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .automatic: "Automatic"
        case .general: "General"
        case .email: "Email"
        case .chat: "Chat"
        case .notes: "Notes"
        case .developer: "Developer"
        }
    }

    func resolved(for bundleIdentifier: String) -> DictationContextProfile {
        if self != .automatic { return DictationContextProfile(rawValue: rawValue) ?? .general }
        switch bundleIdentifier.lowercased() {
        case "com.apple.mail", "com.microsoft.outlook": return .email
        case "com.apple.mobilesms", "com.tinyspeck.slackmacgap", "com.hnc.discord": return .chat
        case "com.apple.notes", "net.shinyfrog.bear", "md.obsidian": return .notes
        case "com.apple.dt.xcode", "com.microsoft.vscode": return .developer
        default: return .general
        }
    }
}

struct DictationContextSettings: Equatable, Sendable {
    var mode: DictationContextMode = .off
    var profile: DictationContextProfileSelection = .automatic
}

enum DictationContextAvailability: String, Codable, Sendable {
    case application, nearbyText
}

/// Ephemeral data for one recording. This value may cross the private worker pipe,
/// but it must never be encoded into recording metadata, logs or saved output history.
struct DictationContextSnapshot: Codable, Equatable, Sendable {
    let profile: DictationContextProfile
    let availability: DictationContextAvailability
    let nearbyText: String?
    let capturedAt: Date

    init(profile: DictationContextProfile, availability: DictationContextAvailability,
         nearbyText: String? = nil, capturedAt: Date = Date()) {
        self.profile = profile
        self.availability = availability
        self.nearbyText = nearbyText
        self.capturedAt = capturedAt
    }

    var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var material = modelData
        material["availability"] = availability.rawValue
        guard let data = try? encoder.encode(material) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Only untrusted model data: the trusted formatting hint lives in the system template.
    var modelData: [String: String] {
        var data = ["profile": profile.rawValue]
        if let nearbyText { data["nearby_text"] = nearbyText }
        return data
    }

    func isFresh(at date: Date = Date()) -> Bool {
        let age = date.timeIntervalSince(capturedAt)
        return age.isFinite && age >= 0 && age <= DictationContextPolicy.maximumAge
    }

    func validate() throws {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite,
              capturedAt <= Date().addingTimeInterval(60) else {
            throw DictationTransformError.invalidRequest
        }
        switch availability {
        case .application:
            guard nearbyText == nil else { throw DictationTransformError.invalidRequest }
        case .nearbyText:
            guard let nearbyText, !nearbyText.isEmpty,
                  nearbyText.utf16.count <= DictationContextPolicy.maximumNearbyUTF16,
                  nearbyText.utf8.count <= DictationContextPolicy.maximumNearbyUTF8,
                  !nearbyText.utf8.contains(0) else { throw DictationTransformError.invalidRequest }
        }
    }
}

enum DictationContextPolicy {
    static let maximumAge: TimeInterval = 15 * 60
    static let maximumNearbyUTF16 = 256
    static let maximumNearbyUTF8 = 1_024
    /// Copy-only: a multiline paste can run shell input without any Return key event.
    /// Terminals embedded in editors and web apps are caught per field by their xterm.js input instead.
    static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2",
        "dev.warp.Warp-Stable", "dev.warp.Warp", "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio",
        // Electron terminals: Termius (direct download and App Store) and Wave.
        "com.termius-dmg.mac", "com.termius.mac", "dev.commandline.waveterm"
    ]

    /// Selection bytes are deliberately omitted. Walk whole graphemes to avoid splitting
    /// surrogate pairs, combining characters or emoji at the context-window boundary.
    static func excerpt(text: String, selection: NSRange) -> String {
        let count = text.utf16.count
        guard selection.location >= 0, selection.length >= 0, selection.location <= count,
              selection.length <= count - selection.location,
              let selected = Range(selection, in: text),
              (selected.lowerBound == text.endIndex || text.indices.contains(selected.lowerBound)),
              (selected.upperBound == text.endIndex || text.indices.contains(selected.upperBound)) else { return "" }
        let sideLimit = maximumNearbyUTF16 / 2
        var lower = selected.lowerBound
        var prefixUnits = 0
        while lower > text.startIndex {
            let previous = text.index(before: lower)
            let count = text[previous..<lower].utf16.count
            guard count <= sideLimit - prefixUnits else { break }
            prefixUnits += count
            lower = previous
        }
        var upper = selected.upperBound
        var suffixUnits = 0
        while upper < text.endIndex {
            let next = text.index(after: upper)
            let count = text[upper..<next].utf16.count
            guard count <= sideLimit - suffixUnits else { break }
            suffixUnits += count
            upper = next
        }
        let value = String(text[lower..<selected.lowerBound]) + String(text[selected.upperBound..<upper])
        return value.replacingOccurrences(of: "\0", with: "")
    }
}
