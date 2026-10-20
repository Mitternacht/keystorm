import Foundation
import Testing
@testable import Keystorm

struct ShortcutReadbackTests {
    @Test func defaultVoicePrefersAnInstalledNaturalVoice() {
        let albert = ReadbackVoice(id: "com.apple.speech.synthesis.voice.Albert", name: "Albert", language: "en-US")
        let samantha = ReadbackVoice(id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US")
        let daniel = ReadbackVoice(id: "com.apple.voice.super-compact.en-GB.Daniel", name: "Daniel", language: "en-GB")
        #expect(ReadbackVoice.preferredIdentifier(in: [albert, daniel, samantha]) == samantha.id)
        #expect(ReadbackVoice.preferredIdentifier(in: [albert, daniel]) == daniel.id)
        #expect(ReadbackVoice.preferredIdentifier(in: [albert]) == albert.id)
        #expect(ReadbackVoice.preferredIdentifier(in: []) == nil)
    }

    @MainActor @Test func refreshingVoicesPreservesAnExplicitUnavailableChoice() throws {
        let suite = "Keystorm.VoiceSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("previously-selected-installed-voice", forKey: "Keystorm.readback.voice.v1")
        let readback = BriefReadback(defaults: defaults)
        readback.refreshVoices()
        #expect(readback.voiceIdentifier == "previously-selected-installed-voice")
        #expect(defaults.string(forKey: "Keystorm.readback.voice.v1") == "previously-selected-installed-voice")
        readback.read(text: "Never upload audio.", sectionID: "constraints", documentRevisionID: UUID())
        #expect(!readback.isSpeaking)
        #expect(readback.error != nil)
    }

    @Test(arguments: [
        GlobalShortcut(keyCode: 0, modifiers: [], keyLabel: "A"),
        GlobalShortcut(keyCode: 0, modifiers: .shift, keyLabel: "A"),
        GlobalShortcut(keyCode: 8, modifiers: .command, keyLabel: "C"),
        GlobalShortcut(keyCode: 49, modifiers: [.command, .control], keyLabel: "Space"),
        GlobalShortcut(keyCode: 53, modifiers: [.command, .shift], keyLabel: "Escape"),
        GlobalShortcut(keyCode: 56, modifiers: [.command, .shift], keyLabel: "Shift"),
        GlobalShortcut(keyCode: 48, modifiers: [.command, .shift], keyLabel: "Tab"),
        GlobalShortcut(keyCode: 12, modifiers: [.command, .control], keyLabel: "Q"),
        GlobalShortcut(keyCode: 12, modifiers: [.command, .shift], keyLabel: "Q"),
        GlobalShortcut(keyCode: 21, modifiers: [.command, .shift], keyLabel: "4"),
        GlobalShortcut(keyCode: 49, modifiers: [.command, .option], keyLabel: "Space")
    ])
    func rejectsUnsafeAssignments(_ shortcut: GlobalShortcut) {
        #expect(throws: ShortcutError.self) { try shortcut.validate() }
    }

    @Test func preferencesRoundTripPreservesExplicitDisabledActions() throws {
        var value = ShortcutPreferences.defaults
        value.shortcuts[ShortcutAction.toggleRecording.rawValue] = nil
        let decoded = try JSONDecoder().decode(ShortcutPreferences.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(decoded.shortcuts[ShortcutAction.toggleRecording.rawValue] == nil)
    }

    @MainActor @Test func duplicateAssignmentDoesNotOverwriteAndPersistsClear() throws {
        let suite = "Keystorm.ShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults)
        let record = try #require(manager.shortcut(for: .toggleRecording))
        #expect(throws: ShortcutError.duplicate(ShortcutAction.toggleRecording.title)) {
            try manager.setShortcut(record, for: .readSection)
        }
        #expect(manager.shortcut(for: .readSection) == nil)
        try manager.setShortcut(nil, for: .toggleRecording)
        #expect(ShortcutManager(defaults: defaults).shortcut(for: .toggleRecording) == nil)
    }

    @Test func repeatsRequireAReleaseBeforeAnotherDispatch() {
        let gate = ShortcutPressGate()
        #expect(gate.accept(id: 1, pressed: true))
        #expect(!gate.accept(id: 1, pressed: true))
        #expect(gate.accept(id: 2, pressed: true))
        #expect(!gate.accept(id: 1, pressed: false))
        #expect(gate.accept(id: 1, pressed: true))
        gate.reset()
        #expect(gate.accept(id: 2, pressed: true))
    }

    @MainActor @Test func dispatchDoesNotInstallModelsOrRequireGlobalRegistration() throws {
        let suite = "Keystorm.ShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults)
        var received: [ShortcutAction] = []
        manager.onAction = { received.append($0) }
        manager.perform(.showWorkspace)
        manager.perform(.undoBriefEdit)
        #expect(received == [.showWorkspace, .undoBriefEdit])
        #expect(manager.dispatchCount == 2)
        #expect(manager.registration.isEmpty)
    }

    @MainActor @Test func registrationFailureIsVisibleAndDoesNotOverwriteStoredBinding() throws {
        let suite = "Keystorm.ShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var registrationCalls = 0
        let manager = ShortcutManager(defaults: defaults, registerOperation: { _, _, _ in
            registrationCalls += 1
            return -9878 // eventHotKeyExistsErr, without reserving any host keyboard combination.
        })
        for action in ShortcutAction.allCases { try manager.setShortcut(nil, for: action) }
        let original = GlobalShortcut(keyCode: 80, modifiers: [.command, .option, .control, .shift], keyLabel: "F19")
        try manager.setShortcut(original, for: .showWorkspace)
        manager.start()
        defer { manager.stop() }
        let registration = try #require(manager.registration[.showWorkspace])
        guard case .unavailable(let message) = registration else {
            Issue.record("A failed registration must be visible in Settings.")
            return
        }
        #expect(message.contains("-9878"))
        #expect(registrationCalls == 1)
        let attempted = GlobalShortcut(keyCode: 79, modifiers: [.command, .option, .control, .shift], keyLabel: "F18")
        #expect(throws: ShortcutError.registration(-9878)) { try manager.setShortcut(attempted, for: .showWorkspace) }
        #expect(manager.shortcut(for: .showWorkspace) == original)
        #expect(ShortcutManager(defaults: defaults).shortcut(for: .showWorkspace) == original)
        #expect(manager.lastError?.contains("-9878") == true)
        #expect(registrationCalls == 2)
        manager.retryRegistration()
        #expect(registrationCalls == 3)
    }

    @MainActor @Test func interruptedHoldReleasesExactlyOnce() throws {
        let suite = "Keystorm.ShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults)
        var edges: [Bool] = []
        manager.setRecordingBehavior(.hold)
        manager.onHoldRecording = { edges.append($0) }
        manager.handleShortcut(.toggleRecording, pressed: true, enqueuedAt: DispatchTime.now().uptimeNanoseconds)
        manager.handleSystemInterruption()
        manager.handleSystemInterruption()
        #expect(edges == [true, false])
        #expect(!manager.isHoldingRecording)
    }

    @MainActor @Test func warmDispatchBenchmarkRetainsConstantSizeMetrics() throws {
        let suite = "Keystorm.ShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults)
        var callbacks = 0
        manager.onAction = { _ in callbacks += 1 }
        let warmup = 100
        let iterations = 10_000
        for _ in 0..<warmup { manager.perform(.showWorkspace) }
        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0..<iterations { manager.perform(.showWorkspace) }
        let duration = started.duration(to: clock.now).components
        let totalMilliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000
        let meanNanoseconds = totalMilliseconds * 1_000_000 / Double(iterations)
        print("Keystorm dispatch fixture: \(iterations) warm synchronous manager+callback dispatches, \(totalMilliseconds) ms total, \(meanNanoseconds) ns mean; excludes Carbon/main-queue/audio startup; OS=\(ProcessInfo.processInfo.operatingSystemVersionString); logicalCPUs=\(ProcessInfo.processInfo.processorCount).")
        #expect(callbacks == warmup + iterations)
        #expect(manager.dispatchCount == UInt64(warmup + iterations))
        #expect(manager.registration.isEmpty)
        #expect(totalMilliseconds >= 0)
    }

    @MainActor @Test func holdModeDeliversEdgesOnceAndCancelsWhenSuspendedOrRebound() throws {
        let suite = "Keystorm.ShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults)
        var edges: [Bool] = []
        var toggles = 0
        manager.onHoldRecording = { edges.append($0) }
        manager.onAction = { _ in toggles += 1 }
        manager.setRecordingBehavior(.hold)
        manager.handleShortcut(.toggleRecording, pressed: true, enqueuedAt: DispatchTime.now().uptimeNanoseconds)
        manager.handleShortcut(.toggleRecording, pressed: true, enqueuedAt: DispatchTime.now().uptimeNanoseconds)
        manager.handleShortcut(.toggleRecording, pressed: false, enqueuedAt: DispatchTime.now().uptimeNanoseconds)
        manager.handleShortcut(.toggleRecording, pressed: false, enqueuedAt: DispatchTime.now().uptimeNanoseconds)
        #expect(edges == [true, false])
        #expect(toggles == 0)
        manager.handleShortcut(.toggleRecording, pressed: true, enqueuedAt: DispatchTime.now().uptimeNanoseconds)
        manager.suspendForShortcutCapture(true)
        #expect(edges == [true, false, true, false])
        #expect(!manager.isHoldingRecording)
        #expect(ShortcutManager(defaults: defaults).recordingBehavior == .hold)
        manager.suspendForShortcutCapture(false)
        manager.handleShortcut(.toggleRecording, pressed: true, enqueuedAt: DispatchTime.now().uptimeNanoseconds)
        try manager.setShortcut(nil, for: .toggleRecording)
        #expect(edges == [true, false, true, false, true, false])
        manager.handleShortcut(.toggleRecording, pressed: true, enqueuedAt: DispatchTime.now().uptimeNanoseconds)
        manager.stop()
        #expect(edges.suffix(2) == [true, false])
    }

    @Test func boundedSpeechChunksReconstructUnicodeWithoutOffsetDrift() {
        let text = String(repeating: "Constraint: do not alter /src/Ä.swift; keep 42 and 👩🏽‍💻 exact.\n", count: 180)
        let chunks = ReadbackChunker.chunks(text, limit: 128)
        #expect(chunks.count > 2)
        #expect(chunks.map(\.text).joined() == text)
        #expect(chunks.allSatisfy { $0.text.utf16.count <= 128 })
        var offset = 0
        for chunk in chunks {
            #expect(chunk.utf16Offset == offset)
            offset += chunk.text.utf16.count
        }
        #expect(offset == text.utf16.count)
    }

    @Test func highlightRangesUseUTF16AndRejectSplitSurrogates() throws {
        let chunk = ReadbackChunk(text: "🚀 test", utf16Offset: 70)
        #expect(ReadbackChunker.globalRange(NSRange(location: 3, length: 4), chunk: chunk) == NSRange(location: 73, length: 4))
        #expect(ReadbackChunker.globalRange(NSRange(location: 1, length: 1), chunk: chunk) == nil)
        #expect(ReadbackChunker.globalRange(NSRange(location: 0, length: 1), chunk: chunk) == nil)
        #expect(ReadbackChunker.globalRange(NSRange(location: 0, length: 2), chunk: chunk) == NSRange(location: 70, length: 2))
        #expect(ReadbackChunker.globalRange(NSRange(location: 4, length: 20), chunk: chunk) == nil)
        #expect(ReadbackChunker.globalRange(NSRange(location: NSNotFound, length: 0), chunk: chunk) == nil)
    }

    @MainActor @Test func emptyReadbackRequiresNoVoiceAndStopClearsIdentity() throws {
        let suite = "Keystorm.ReadbackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let readback = BriefReadback(defaults: defaults)
        readback.read(text: "  \n", sectionID: "constraints", documentRevisionID: UUID())
        #expect(!readback.isSpeaking)
        #expect(readback.error != nil)
        readback.stop()
        #expect(readback.sectionID == nil)
        #expect(readback.documentRevisionID == nil)
        #expect(readback.currentRange == nil)
    }
}
