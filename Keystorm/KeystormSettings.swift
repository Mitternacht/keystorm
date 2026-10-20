import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KeystormSettings: View {
    @Bindable var model: WorkspaceModel
    @Bindable var interactions: AppInteractionController
    var body: some View {
        TabView {
            Tab("Shortcuts", systemImage: "command") { ShortcutSettingsView(manager: interactions.shortcuts) }
            Tab("Dictation", systemImage: "text.insert") {
                if let preferences = interactions.dictation?.preferences {
                    DictationDeliverySettingsView(preferences: preferences)
                } else {
                    ContentUnavailableView("Dictation is starting", systemImage: "mic",
                        description: Text("Dictation settings appear once dictation is ready."))
                }
            }
            Tab("Read-back", systemImage: "speaker.wave.2") { ReadbackSettingsView(readback: interactions.readback) }
            Tab("Local models", systemImage: "cpu") { ModelManagerView(model: model) }
            Tab("Performance", systemImage: "gauge.with.dots.needle.50percent") { BriefPerformanceView(model: model, shortcuts: interactions.shortcuts) }
        }.frame(minWidth: 800, idealWidth: 850, minHeight: 580, idealHeight: 650)
    }
}

/// Delivery preferences are snapshotted when a recording starts. Blocked apps and websites are read again at
/// Finish, so blocking one during a recording still prevents writing to it.
struct DictationDeliverySettingsView: View {
    @Bindable var preferences: DictationPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Paste into other apps", isOn: $preferences.pasteIntoOtherApps)
                    .accessibilityHint("Pastes finished dictation into the text field where you started recording.")
                    .accessibilityIdentifier("dictation.pasteIntoOtherApps")
                Text("Paste the finished text into the field you started in. Known terminal apps, recognized terminals inside editors, and password fields are never pasted into. After a confirmed paste your previous clipboard is restored; if a paste can't be confirmed, the result stays on the clipboard instead.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("TextEdit uses verified insertion instead. Other apps can't report what they inserted, so check the result. When this is off, or a field can't be checked, the result stays in Keystorm to copy. Changes apply to the next recording.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Delivery") }
            Section {
                // Verbatim never runs a text model; the speech model's own number style reaches the field as is.
                Text("In Verbatim, numbers stay as the speech model writes them. The model can write spoken numbers as digits: “fünf” becomes “5”.")
                    .accessibilityIdentifier("dictation.verbatimNumbers")
            } header: { Text("Verbatim") }
            DictationAppPresetsSection(preferences: preferences)
            DictationBlockedAppsSection(preferences: preferences)
            DictationBlockedWebsitesSection(preferences: preferences)
            if preferences.hasUnreadableExclusions {
                Section {
                    Label("Some saved blocked apps, websites or presets couldn't be read and are ignored. They stay saved until you change that list.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("dictationSettings")
    }
}

struct BriefPerformanceView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var shortcuts: ShortcutManager
    @State private var showRecentMeasurements = false
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PerformanceSettingsHeader {
                    savePerformanceReport(model: model) { exportError = $0 }
                }
                RuntimeSummaryTable(summaries: model.performanceSummaries)
                    .frame(height: 210)
                GroupBox("Memory & responsiveness") {
                    RuntimeMemoryMeasurements(measurements: model.memoryMeasurements,
                        dispatchCount: shortcuts.dispatchCount,
                        dispatchNanoseconds: shortcuts.lastDispatchNanoseconds)
                        .padding(8)
                }
                RecentRuntimeMeasurements(
                    measurements: model.performanceMeasurements,
                    isExpanded: $showRecentMeasurements
                )
                Text("Up to 128 samples per stage. Reports include hardware, models, timings, and memory, and exclude recordings and brief text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .alert("Could not save performance report",
               isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
}

private struct PerformanceSettingsHeader: View {
    let onSaveReport: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Performance on this Mac")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Local processing times and memory use.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save report…", systemImage: "square.and.arrow.down", action: onSaveReport)
                .accessibilityIdentifier("savePerformanceReport")
        }
    }
}

private struct RecentRuntimeMeasurements: View {
    let measurements: [RuntimeMeasurement]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup("Recent timings", isExpanded: $isExpanded) {
            List(measurements.reversed()) { measurement in
                HStack {
                    Text(RuntimeMetricSummary(kind: measurement.kind, count: 1,
                        p50Milliseconds: 0, p95Milliseconds: 0, p99Milliseconds: 0,
                        maximumMilliseconds: 0).title)
                    Spacer()
                    Text("\(measurement.milliseconds, format: .number.precision(.fractionLength(2))) ms")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
            .frame(height: 150)
            .padding(.top, 8)
        }
    }
}

private struct RuntimeSummaryTable: View {
    let summaries: [RuntimeMetricSummary]
    var body: some View {
        Table(summaries) {
            TableColumn("Stage") { Text($0.title) }.width(min: 200, ideal: 260)
            TableColumn("Samples") { Text($0.count, format: .number).monospacedDigit() }.width(62)
            TableColumn("p50 (ms)") { Text($0.p50Milliseconds, format: .number.precision(.fractionLength(1))).monospacedDigit() }.width(70)
            TableColumn("p95 (ms)") { Text($0.p95Milliseconds, format: .number.precision(.fractionLength(1))).monospacedDigit() }.width(70)
            TableColumn("p99 (ms)") { Text($0.p99Milliseconds, format: .number.precision(.fractionLength(1))).monospacedDigit() }.width(70)
            TableColumn("Max (ms)") { Text($0.maximumMilliseconds, format: .number.precision(.fractionLength(1))).monospacedDigit() }.width(70)
        }.overlay {
            if summaries.isEmpty {
                ContentUnavailableView("No timings yet", systemImage: "gauge.with.dots.needle.50percent",
                    description: Text("Use Keystorm to collect local measurements."))
            }
        }
        .accessibilityLabel("Recent stage latency in milliseconds")
        .accessibilityIdentifier("performanceSummaries")
    }
}

private struct RuntimeMemoryMeasurements: View {
    let measurements: [String: UInt64]
    let dispatchCount: UInt64
    let dispatchNanoseconds: UInt64
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Last shortcut response") {
                if dispatchCount > 0 {
                    Text("\(Double(dispatchNanoseconds) / 1_000_000, format: .number.precision(.fractionLength(2))) ms")
                        .monospacedDigit()
                } else {
                    Text("Not measured")
                }
            }
            ForEach(["processFootprint", "parentFootprint", "workerFootprint", "mlxActive", "mlxCache", "mlxPeak"], id: \.self) { key in
                HStack {
                    if let bytes = measurements[key] {
                        LabeledContent {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory))
                                .monospacedDigit()
                        } label: {
                            Text(memoryLabel(key))
                        }
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
            if measurements["workerMemoryIsCached"] == 1 {
                Text("Memory shows the latest snapshot while processing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func memoryLabel(_ key: String) -> String {
        switch key {
        case "processFootprint": "Combined app and worker footprint"
        case "parentFootprint": "App footprint"
        case "workerFootprint": "Inference worker footprint"
        case "mlxActive": "MLX active allocations"
        case "mlxCache": "MLX allocator cache"
        case "mlxPeak": "MLX allocator peak"
        default: key
        }
    }
}

@MainActor
private func savePerformanceReport(model: WorkspaceModel, onError: @escaping @MainActor (String) -> Void) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "Keystorm-performance.json"
    panel.title = String(localized: "Save local performance report")
    panel.message = String(localized: "Includes hardware, models, timings, and memory. Excludes recordings and brief text.")
    panel.begin { response in
        guard response == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try model.performanceReportData()
                try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
            } catch { onError(error.localizedDescription) }
        }
    }
}

struct KeystormQuickMenu: View {
    @Bindable var model: WorkspaceModel
    @Bindable var interactions: AppInteractionController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Keystorm").font(.headline)
        Button("Show dictation") { openWindow(id: "workspace"); NSApp.activate() }
        if let flow = interactions.dictation {
            Button(flow.hasActiveRecording ? "Finish dictation" : "Start dictation") {
                interactions.perform(.toggleDictation)
            }.disabled(flow.isTransitioning)
            if flow.state == .recording || flow.state == .paused {
                Button(flow.state == .paused ? "Resume dictation" : "Pause dictation") {
                    interactions.perform(.pauseResumeDictation)
                }.disabled(flow.isTransitioning)
            }
            if flow.state == .ready {
                Button("Copy result") { flow.copyResult() }.disabled(flow.isTransitioning || flow.resultText.isEmpty)
            }
        }
        Divider()
        Menu("Developer briefs") {
            Button(model.isRecording ? "Pause take" : "Record material") { interactions.perform(.toggleRecording) }
            Button("Record edit instruction") { interactions.perform(.recordEdit) }
            Button("Read selected section") { interactions.readSelectedSection() }.disabled(model.isRecording)
            if interactions.readback.isSpeaking {
                Button(interactions.readback.isPaused ? "Resume read-back" : "Pause read-back") { interactions.readback.togglePause() }
            }
            Button("Update brief") { Task { await model.prepareBrief() } }.disabled(model.isBusy || model.isRecording)
        }.disabled(interactions.dictation?.hasActiveRecording == true)
        Divider()
        OnboardingMenuCommand()
        Button("Shortcuts & settings…") { openSettings() }
        Button("Quit Keystorm") { NSApp.terminate(nil) }
    }
}
