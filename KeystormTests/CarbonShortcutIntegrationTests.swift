import Carbon
import Foundation
import Testing
@testable import Keystorm

@MainActor
struct CarbonShortcutIntegrationTests {
    @Test func registeredCarbonEventsReachQueuedActionsAndSuppressHeldRepeats() async throws {
        let suite = "Keystorm.CarbonIntegration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults)
        defer { manager.stop() }
        for action in ShortcutAction.allCases { try manager.setShortcut(nil, for: action) }
        let candidates: [(UInt32, String)] = [(80, "F19"), (79, "F18"), (64, "F17"), (90, "F20")]
        let modifiers: ShortcutModifiers = [.command, .option, .control, .shift]
        try manager.setShortcut(.init(keyCode: candidates[0].0, modifiers: modifiers, keyLabel: candidates[0].1), for: .showWorkspace)
        manager.start()
        if manager.registration[.showWorkspace] != .registered {
            for (keyCode, label) in candidates.dropFirst() {
                do {
                    try manager.setShortcut(.init(keyCode: keyCode, modifiers: modifiers, keyLabel: label), for: .showWorkspace)
                    if manager.registration[.showWorkspace] == .registered { break }
                } catch { continue }
            }
        }
        try #require(manager.registration[.showWorkspace] == .registered, "A rare valid hotkey must register before exercising its Carbon event handler.")

        let (stream, continuation) = AsyncStream<ShortcutAction>.makeStream(bufferingPolicy: .bufferingNewest(8))
        defer { continuation.finish() }
        manager.onAction = { continuation.yield($0) }
        func send(_ kind: UInt32) throws {
            var event: EventRef?
            let creation = CreateEvent(nil, OSType(kEventClassKeyboard), kind, GetCurrentEventTime(),
                EventAttributes(kEventAttributeUserEvent), &event)
            try #require(creation == noErr)
            let created = try #require(event)
            defer { ReleaseEvent(created) }
            var identifier = EventHotKeyID(signature: OSType(0x4B53544D), id: ShortcutAction.showWorkspace.carbonID)
            let parameter = SetEventParameter(created, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier)
            try #require(parameter == noErr)
            try #require(SendEventToEventTarget(created, GetApplicationEventTarget()) == noErr)
        }

        // The real Carbon handler receives these synchronously; its app actions are queued on MainActor.
        try send(UInt32(kEventHotKeyPressed))
        try send(UInt32(kEventHotKeyPressed))
        try send(UInt32(kEventHotKeyReleased))
        try send(UInt32(kEventHotKeyReleased))
        try send(UInt32(kEventHotKeyPressed))
        try send(UInt32(kEventHotKeyReleased))
        let received = await withTaskGroup(of: [ShortcutAction].self) { group in
            group.addTask {
                var actions: [ShortcutAction] = []
                for await action in stream {
                    actions.append(action)
                    if actions.count == 2 { break }
                }
                return actions
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
        #expect(received == [.showWorkspace, .showWorkspace])
        #expect(manager.dispatchCount == 2)
        #expect(manager.registration[.showWorkspace] == .registered)
        print("Keystorm Carbon integration: registered \(manager.shortcut(for: .showWorkspace)?.displayName ?? "unknown"); 2 queued actions for 3 pressed/3 released protocol events; held repeat and duplicate release suppressed. This validates registration+handler wiring, not physical keyboard delivery or microphone latency.")
    }
}
