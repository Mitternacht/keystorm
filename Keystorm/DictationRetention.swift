import Foundation

/// How long saved dictations stay on this Mac. The default keeps everything, as before.
enum DictationRetention: String, CaseIterable, Identifiable, Sendable {
    case forever, days90, days30, days7, noAudio

    var id: String { rawValue }

    static let storageKey = "dictation.historyRetention.v1"
    /// Recent audio stays for this long so a just-finished dictation can still be retried or played back.
    static let audioGraceSeconds: TimeInterval = 120

    var title: LocalizedStringResource {
        switch self {
        case .forever: "Keep forever"
        case .days90: "Delete after 90 days"
        case .days30: "Delete after 30 days"
        case .days7: "Delete after 7 days"
        case .noAudio: "Don’t keep audio"
        }
    }

    /// Whole dictations (audio and text) go away after this many days.
    var days: Int? {
        switch self {
        case .days90: 90
        case .days30: 30
        case .days7: 7
        case .forever, .noAudio: nil
        }
    }

    /// Shown before a choice that deletes data on its own.
    var confirmationMessage: LocalizedStringResource {
        switch self {
        case .forever:
            "Recordings and transcripts stay on this Mac until you delete them."
        case .noAudio:
            "The audio of finished dictations is deleted a couple of minutes after each dictation. Transcripts stay. Deleted audio cannot be recovered."
        case .days90, .days30, .days7:
            "Recordings and transcripts older than \(days ?? 0) days are permanently deleted now, and automatically from now on."
        }
    }

    /// Anything other than Keep forever removes data on its own, so choosing it needs a confirmation.
    var removesData: Bool { self != .forever }

    var removesAudioOnly: Bool { self == .noAudio }

    /// Dictations created before this date are deleted. Nil when retention never deletes whole dictations.
    func deletionCutoff(now: Date) -> Date? {
        days.map { now.addingTimeInterval(-Double($0) * 86_400) }
    }

    /// Audio recorded before this date is discarded. Nil unless the policy is Don’t keep audio.
    func audioCutoff(now: Date) -> Date? {
        removesAudioOnly ? now.addingTimeInterval(-Self.audioGraceSeconds) : nil
    }

    static func load(from defaults: UserDefaults = .standard) -> DictationRetention {
        defaults.string(forKey: storageKey).flatMap(DictationRetention.init(rawValue:)) ?? .forever
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

/// What a deletion or retention pass did. Sessions in use are skipped, never forced.
struct DictationDeletionResult: Equatable, Sendable {
    var deleted = 0
    var skippedInUse = 0
    var failed = 0
    var firstError: String?

    var isEmpty: Bool { deleted == 0 && skippedInUse == 0 && failed == 0 }

    mutating func absorb(_ other: DictationDeletionResult) {
        deleted += other.deleted
        skippedInUse += other.skippedInUse
        failed += other.failed
        firstError = firstError ?? other.firstError
    }
}
