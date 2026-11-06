import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Words typed by hand. They apply in every app and in both languages, even with learning off.
struct ManualVocabularyView: View {
    let controller: LearningDictionaryController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("My words").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Names, products and terms that dictation should spell your way. They apply in every app, in English and German, and they work even when learning is off. Matching ignores capitalization.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VocabularyAddForm { word, spoken in
                await controller.addVocabularyWord(word, soundsLike: spoken)
            }
            if let message = controller.vocabularyErrorMessage ?? controller.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vocabulary.error")
            }
            if controller.vocabulary.isEmpty {
                ContentUnavailableView("No words yet",
                    systemImage: "text.badge.plus",
                    description: Text("Add a name or term above. Add a “sounds like” spelling when dictation keeps writing it differently, for example “cube er net ease” for Kubernetes."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.vocabulary) { entry in
                    VocabularyRow(entry: entry,
                        onSave: { word, spoken in
                            await controller.updateVocabularyEntry(id: entry.id, word: word, soundsLike: spoken)
                        },
                        onDelete: { Task { await controller.deleteVocabularyEntry(id: entry.id) } })
                }
                .listStyle(.inset)
                .accessibilityIdentifier("vocabulary.entries")
            }
            HStack(spacing: 12) {
                Button("Import…", systemImage: "square.and.arrow.down", action: importWords)
                    .accessibilityIdentifier("vocabulary.import")
                Button("Export…", systemImage: "square.and.arrow.up", action: exportWords)
                    .disabled(controller.vocabulary.isEmpty)
                    .accessibilityIdentifier("vocabulary.export")
                if let message = controller.vocabularyStatusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("vocabulary.status")
                }
                Spacer()
            }
            Text("Plain text, one entry per line: a word, or “sounds like, sounds like => Word”.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func importWords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a text file with one word per line.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.importVocabulary(from: url) }
    }

    private func exportWords() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = String(localized: "Keystorm vocabulary.txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.exportVocabulary(to: url) }
    }
}

private struct VocabularyAddForm: View {
    let onAdd: (String, [String]) async -> Bool
    @State private var word = ""
    @State private var soundsLike = ""
    @State private var isSaving = false
    @FocusState private var wordFocused: Bool

    private var canAdd: Bool { !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField("Word or name", text: $word)
                .focused($wordFocused)
                .onSubmit(add)
                .accessibilityIdentifier("vocabulary.word")
            TextField("Sounds like (optional)", text: $soundsLike, prompt: Text("Sounds like, comma separated"))
                .onSubmit(add)
                .accessibilityIdentifier("vocabulary.soundsLike")
            Button("Add", action: add)
                .disabled(!canAdd)
                .accessibilityIdentifier("vocabulary.add")
        }
        .textFieldStyle(.roundedBorder)
    }

    private func add() {
        guard canAdd else { return }
        isSaving = true
        let spoken = soundsLike.split(separator: ",").map { String($0) }
        let text = word
        Task {
            let saved = await onAdd(text, spoken)
            isSaving = false
            if saved {
                word = ""
                soundsLike = ""
                wordFocused = true
            }
        }
    }
}

private struct VocabularyRow: View {
    let entry: VocabularyEntry
    let onSave: (String, [String]) async -> Bool
    let onDelete: () -> Void
    @State private var isEditing = false
    @State private var word = ""
    @State private var soundsLike = ""
    @State private var isSaving = false

    var body: some View {
        Group {
            if isEditing { editor } else { summary }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vocabulary.entry.\(entry.id.uuidString)")
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.word).font(.headline).textSelection(.enabled)
                if !entry.soundsLike.isEmpty {
                    Text("Sounds like: \(entry.soundsLike.formatted(.list(type: .and)))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Edit", action: beginEditing)
                .accessibilityLabel("Edit \(entry.word)")
            Button("Delete", role: .destructive, action: onDelete)
                .accessibilityLabel("Delete \(entry.word)")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private var editor: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField("Word or name", text: $word)
                .onSubmit(save)
            TextField("Sounds like (optional)", text: $soundsLike, prompt: Text("Sounds like, comma separated"))
                .onSubmit(save)
            Button("Save", action: save)
                .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            Button("Cancel") { isEditing = false }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func beginEditing() {
        word = entry.word
        soundsLike = entry.soundsLike.joined(separator: ", ")
        isEditing = true
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let text = word
        let spoken = soundsLike.split(separator: ",").map { String($0) }
        Task {
            let saved = await onSave(text, spoken)
            isSaving = false
            if saved { isEditing = false }
        }
    }
}
