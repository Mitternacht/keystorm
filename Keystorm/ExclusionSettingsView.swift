import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Blocked apps: the user's list plus the built-in password managers, which are shown but cannot be removed.
struct DictationBlockedAppsSection: View {
    @Bindable var preferences: DictationPreferences

    var body: some View {
        Section {
            ForEach(preferences.blockedApplications) { application in
                DictationApplicationRow(bundleIdentifier: application.bundleIdentifier, name: application.name) {
                    Button("Remove \(application.name)", systemImage: "minus.circle") {
                        preferences.unblockApplication(application.bundleIdentifier)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove \(application.name) from blocked apps")
                }
            }
            DictationApplicationMenu(title: "Block an App",
                                     listed: Set(preferences.blockedApplications.map(\.bundleIdentifier))
                                        .union(DictationDeliveryService.passwordManagerBundleIdentifiers),
                                     choosePrompt: String(localized: "Block")) { choice in
                preferences.blockApplication(bundleIdentifier: choice.bundleIdentifier, name: choice.name)
            }
            .accessibilityIdentifier("dictation.blockApp")
            DisclosureGroup {
                ForEach(DictationBuiltInExclusion.passwordManagers) { manager in
                    LabeledContent(manager.name) {
                        Text("Built-in").foregroundStyle(.secondary)
                    }
                }
            } label: {
                Text("Password managers: always blocked, can't be removed")
            }
            .accessibilityIdentifier("dictation.builtInExclusions")
            Text("Quick dictation doesn't start while a blocked app is in front, and Keystorm reads nothing from that app and pastes nothing into it. If a blocked app is in front when you finish, nothing is inserted and the result stays in Keystorm to copy. Long Recording, which records only into Keystorm, isn't affected.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Blocked apps") }
    }
}

/// Blocked websites, matched by the address of the page that contains the focused field.
struct DictationBlockedWebsitesSection: View {
    @Bindable var preferences: DictationPreferences
    @State private var draft = ""

    private var draftDomain: String? { DictationWebsiteExclusion.normalizedDomain(draft) }

    var body: some View {
        Section {
            ForEach(preferences.blockedWebsites, id: \.self) { domain in
                HStack {
                    Text(domain)
                    Spacer()
                    Button("Remove \(domain)", systemImage: "minus.circle") {
                        preferences.unblockWebsite(domain)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove \(domain) from blocked websites")
                }
            }
            HStack {
                TextField("Website to block", text: $draft, prompt: Text(verbatim: "example.com"))
                    .autocorrectionDisabled()
                    .onSubmit(add)
                    .accessibilityIdentifier("dictation.blockWebsite.field")
                Button("Block", action: add)
                    .disabled(draftDomain == nil)
                    .accessibilityIdentifier("dictation.blockWebsite.add")
            }
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftDomain == nil {
                Text("Enter a domain such as example.com. For international names, use the form that starts with xn--.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Blocking a domain also blocks its subdomains. When you start, and again before pasting, Keystorm reads the address of the page you're typing in through Accessibility. The address is compared on this Mac and never saved. On a blocked website, dictation doesn't start.")
                .font(.caption).foregroundStyle(.secondary)
            Text("If the address can't be read, nothing is pasted and no context is used; the result stays in Keystorm to copy. Websites are checked only while Paste into other apps is on and Keystorm has Accessibility access, and only when something on the page has keyboard focus. Fields outside the page, such as the address bar, aren't part of a website.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Blocked websites") }
    }

    private func add() {
        guard preferences.blockWebsite(draft) else { return }
        draft = ""
    }
}

/// An app chosen in Settings: from the apps that are open now, or from an app chooser.
struct DictationApplicationChoice: Identifiable, Equatable {
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }

    /// Regular apps that are open now, except Keystorm and apps already listed.
    @MainActor
    static func running(excluding listed: Set<String>) -> [DictationApplicationChoice] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        let choices = NSWorkspace.shared.runningApplications.compactMap { application -> DictationApplicationChoice? in
            guard application.activationPolicy == .regular, let identifier = application.bundleIdentifier,
                  identifier != own, !listed.contains(identifier), seen.insert(identifier).inserted else { return nil }
            return DictationApplicationChoice(bundleIdentifier: identifier, name: application.localizedName ?? identifier)
        }
        return choices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads only the chosen bundle's identifier and display name.
    @MainActor
    static func chooseFromApplications(prompt: String,
                                       onChoose: @escaping @MainActor (DictationApplicationChoice) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = prompt
        panel.begin { response in
            guard response == .OK, let url = panel.url, let identifier = Bundle(url: url)?.bundleIdentifier,
                  identifier != Bundle.main.bundleIdentifier else { return }
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            onChoose(DictationApplicationChoice(bundleIdentifier: identifier, name: name))
        }
    }
}

/// Adds an app from the apps that are open now, or from the Applications folder.
struct DictationApplicationMenu: View {
    let title: LocalizedStringKey
    /// Apps that are already listed and are not offered again.
    let listed: Set<String>
    let choosePrompt: String
    let onChoose: @MainActor (DictationApplicationChoice) -> Void

    var body: some View {
        Menu(title, systemImage: "plus") {
            Section("Open apps") {
                ForEach(DictationApplicationChoice.running(excluding: listed)) { choice in
                    Button(choice.name) { onChoose(choice) }
                }
            }
            Divider()
            Button("Choose from Applications…") {
                DictationApplicationChoice.chooseFromApplications(prompt: choosePrompt) { onChoose($0) }
            }
        }
        .fixedSize()
    }
}

/// One app in a Settings list: icon, name and bundle identifier, with trailing controls.
struct DictationApplicationRow<Trailing: View>: View {
    let bundleIdentifier: String
    let name: String
    @ViewBuilder let trailing: Trailing
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 10) {
            DictationApplicationIcon(bundleIdentifier: bundleIdentifier)
                .frame(width: iconSize, height: iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                Text(verbatim: bundleIdentifier)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// Decorative: the row's name already identifies the app.
private struct DictationApplicationIcon: View {
    let bundleIdentifier: String

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .accessibilityHidden(true)
    }
}
