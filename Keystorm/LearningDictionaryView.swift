import AppKit
import SwiftUI

struct LearningDictionaryView: View {
    let controller: LearningDictionaryController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LearningDictionaryHeader(isEnabled: controller.isEnabled,
                externalCorrectionsEnabled: controller.externalCorrectionsEnabled,
                isClassifying: controller.isClassifying,
                onToggle: { enabled in Task { await controller.setEnabled(enabled) } },
                onExternalToggle: { enabled in Task { await controller.setExternalCorrectionsEnabled(enabled) } })
            if controller.isEnabled && !controller.isClassifying {
                Button("Review pending corrections on this Mac", systemImage: "arrow.clockwise") {
                    controller.drainPending()
                }
                .accessibilityIdentifier("learning.retry")
            }
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("learning.error")
            }
            if controller.entries.isEmpty {
                ContentUnavailableView("Your terminology, learned locally",
                    systemImage: "character.book.closed",
                    description: Text("Correct a name or term in a saved transcript, or opt in to observing a correction after dictation in TextEdit. Every candidate stays on this Mac and waits for approval."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.entries) { entry in
                    LearnedTermRow(entry: entry,
                        originDescription: (controller.originSummaries[entry.id] ?? .savedEditor).description,
                        onApprove: { Task { await controller.approve(id: entry.id) } },
                        onDisable: { Task { await controller.disable(id: entry.id) } },
                        onForget: { Task { await controller.forget(id: entry.id) } })
                }
                .listStyle(.inset)
                .accessibilityIdentifier("learning.entries")
            }
            LearningDictionaryFooter()
        }
        .padding(24)
        .task { await controller.refresh() }
        // Keyed on the report token, not the text: a repeated outcome or error is announced each time.
        .onChange(of: controller.announcementToken) {
            if let message = controller.announcement { AccessibilityNotification.Announcement(message).post() }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

private struct LearningDictionaryHeader: View {
    let isEnabled: Bool
    let externalCorrectionsEnabled: Bool
    let isClassifying: Bool
    let onToggle: (Bool) -> Void
    let onExternalToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Learning dictionary").font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Remember the names and terms you correct.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if isClassifying {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Reviewing a correction on this Mac")
                }
            }
            Toggle("Learn from my transcript corrections", isOn: Binding(get: { isEnabled }, set: onToggle))
                .toggleStyle(.switch)
                .accessibilityIdentifier("learning.enabled")
            Text("Local AI reviews saved transcript corrections. Approve each exact correction before it can affect future dictation.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Learn corrections in other apps", isOn: Binding(get: { externalCorrectionsEnabled }, set: onExternalToggle))
                .toggleStyle(.switch)
                .disabled(!isEnabled)
                .accessibilityIdentifier("learning.externalCorrectionsEnabled")
            Text("TextEdit only: for up to 30 seconds after insertion, while the same field stays focused, Keystorm can review one correction to its delivered text. A change may come from you or TextEdit; authorship is not verified. Approval is always required.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LearnedTermRow: View {
    let entry: LearnedTerm
    let originDescription: LocalizedStringResource
    let onApprove: () -> Void
    let onDisable: () -> Void
    let onForget: () -> Void

    /// One state decides both the visible title and the spoken label so they never disagree.
    private var undoesLearning: Bool { entry.status == .learned || entry.status == .approved }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.canonical).font(.headline)
                Spacer()
                Text(entry.status.title).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(entry.variant).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Text(entry.canonical)
            }.font(.callout).textSelection(.enabled)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(entry.variant), corrected to \(entry.canonical)",
                    comment: "VoiceOver label for a learned correction. First placeholder is the misheard spelling; second is the corrected term."))
            Text(entry.appBundleID.map { ApplicationDisplayName.name(forBundleID: $0) } ?? String(localized: "All apps"))
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Why this term?") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.whyLearned)
                    Text(originDescription)
                    Text("\(entry.evidenceIDs.count) saved correction events · \(entry.positiveSessionCount) consistent sessions · \(entry.negativeCount) uncertain or wording changes")
                    Text("Evidence counts and AI scores do not enable a correction. Your approval is required before future use. AI confidence scores do not measure accuracy.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            HStack {
                if entry.status != .approved {
                    Button("Approve", action: onApprove)
                        .accessibilityLabel("Approve correction to \(entry.canonical)")
                }
                if entry.status != .disabled {
                    Button(undoesLearning ? "Undo learning" : "Disable", action: onDisable)
                        .accessibilityLabel(undoesLearning
                            ? Text("Undo learning \(entry.canonical)",
                                comment: "VoiceOver label for the button that undoes an approved or learned term. Placeholder is the learned term.")
                            : Text("Disable learned term \(entry.canonical)"))
                }
                Spacer()
                Button("Forget", role: .destructive, action: onForget)
                    .help("Remove this spelling and its evidence. Previously seen correction events stay excluded.")
                    .accessibilityLabel("Forget learned term \(entry.canonical)")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("learning.term.\(entry.id.uuidString)")
    }
}

/// Resolves a bundle identifier to the app's display name once, so rows never show or speak
/// raw identifiers such as com.apple.TextEdit and long lists do not repeat LaunchServices lookups.
@MainActor
private enum ApplicationDisplayName {
    private static var cache: [String: String] = [:]

    static func name(forBundleID bundleID: String) -> String {
        if let cached = cache[bundleID] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
        cache[bundleID] = name
        return name
    }
}

private struct LearningDictionaryFooter: View {
    var body: some View {
        Label("Original transcripts and your manually maintained dictionary are preserved. When learning is on, only terms you have approved can correct future recognition in a matching context. Restore the saved original to undo a correction.",
            systemImage: "lock.shield")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
