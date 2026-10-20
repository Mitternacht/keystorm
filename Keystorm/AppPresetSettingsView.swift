import Foundation
import SwiftUI

/// Per-app Quick modes. A preset applies to a recording that starts in that app; the Next recording choice
/// is left alone. Only Verbatim, Clean and Email can be chosen.
struct DictationAppPresetsSection: View {
    @Bindable var preferences: DictationPreferences

    var body: some View {
        Section {
            ForEach(preferences.appPresets) { preset in
                DictationApplicationRow(bundleIdentifier: preset.bundleIdentifier, name: preset.name) {
                    Picker("Mode for \(preset.name)", selection: modeBinding(for: preset)) {
                        ForEach(DictationQuickMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Remove preset for \(preset.name)", systemImage: "minus.circle") {
                        preferences.setPreset(nil, bundleIdentifier: preset.bundleIdentifier, name: preset.name)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove the preset for \(preset.name)")
                }
            }
            DictationApplicationMenu(title: "Add an App Preset",
                                     listed: Set(preferences.appPresets.map(\.bundleIdentifier)),
                                     choosePrompt: String(localized: "Add Preset")) { choice in
                preferences.setPreset(.clean, bundleIdentifier: choice.bundleIdentifier, name: choice.name)
            }
            .accessibilityIdentifier("dictation.addAppPreset")
            Text("When dictation starts in one of these apps, that recording uses the chosen mode. Your Next recording choice doesn't change. Translation is never a preset: it's always a preview you start after recording and apply yourself.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("App presets") }
    }

    private func modeBinding(for preset: DictationAppPreset) -> Binding<DictationQuickMode> {
        Binding(get: { preset.mode },
                set: { preferences.setPreset($0, bundleIdentifier: preset.bundleIdentifier, name: preset.name) })
    }
}
