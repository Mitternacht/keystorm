import Foundation
import Observation

/// What the menu-bar icon shows. One state per thing the person needs to notice from across the screen.
enum MenuBarState: Equatable, Sendable {
    case idle, recording, paused, processing, ready, failed

    var symbolName: String {
        switch self {
        case .idle: "waveform"
        case .recording: "mic.fill"
        case .paused: "pause.circle.fill"
        case .processing: "ellipsis.circle.fill"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// The icon's accessibility label and the first line of the menu.
    var title: LocalizedStringResource {
        switch self {
        case .idle: "Keystorm"
        case .recording: "Keystorm, recording"
        case .paused: "Keystorm, recording paused"
        case .processing: "Keystorm, working on your dictation"
        case .ready: "Keystorm, dictation ready"
        case .failed: "Keystorm, needs attention"
        }
    }

    /// Ready and failed describe a finished take. They fall back to idle on their own, because the
    /// coordinator keeps them until the next Start.
    var isTransient: Bool { self == .ready || self == .failed }

    /// A dictation in progress wins over a developer-brief recording. A finished or idle dictation
    /// yields to a brief recording, which still has the microphone open.
    static func resolve(flow: DictationFlowState?, briefRecording: Bool) -> MenuBarState {
        switch flow {
        case .starting, .recording: .recording
        case .paused: .paused
        case .processing: .processing
        case .ready: briefRecording ? .recording : .ready
        case .failed: briefRecording ? .recording : .failed
        case .idle, nil: briefRecording ? .recording : .idle
        }
    }
}

/// The state the icon displays. It follows the coordinator immediately and lets a finished take expire.
@MainActor @Observable
final class MenuBarStatus {
    private(set) var state: MenuBarState = .idle
    @ObservationIgnored private var source: MenuBarState = .idle
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private let readyHold: Duration
    @ObservationIgnored private let failedHold: Duration

    init(readyHold: Duration = .seconds(3), failedHold: Duration = .seconds(10)) {
        self.readyHold = readyHold
        self.failedHold = failedHold
    }

    /// Call with the state derived from the coordinator whenever it changes. Repeats are ignored,
    /// so a transient state is shown once per take.
    func apply(_ next: MenuBarState) {
        guard next != source else { return }
        source = next
        expiry?.cancel()
        expiry = nil
        state = next
        guard next.isTransient else { return }
        let hold = next == .ready ? readyHold : failedHold
        expiry = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard let self, !Task.isCancelled, self.source == next else { return }
            self.state = .idle
        }
    }
}

/// Text for the menu's last-result line and notice items.
enum MenuBarText {
    /// One line of the last dictation, or nil when there is nothing to show.
    static func preview(of text: String, limit: Int = 48) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Startup and maintenance messages the workspace collects (`WorkspaceModel.recoveryMessages`) and
/// that nothing used to show. Dismissing is local to this launch: the workspace re-reports on the next one.
@MainActor @Observable
final class RecoveryNotices {
    private(set) var dismissed: Set<String> = []

    /// Messages not yet dismissed, in the workspace's order and without repeats.
    func visible(from messages: [String]) -> [String] {
        var seen = Set<String>()
        return messages.filter { message in
            !dismissed.contains(message) && seen.insert(message).inserted
        }
    }

    func dismiss(_ message: String) { dismissed.insert(message) }

    func dismissAll(_ messages: [String]) { dismissed.formUnion(messages) }
}
