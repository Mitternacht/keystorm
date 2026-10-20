import Foundation
import Testing
@testable import Keystorm

@MainActor
struct BriefTypingPerformanceTests {
    @Test func typingOnePassageInALargePersistedSessionMeasuresTheRealModelPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Typing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(root: root)
        await model.initialize(loadLibrary: true)
        var session = VoiceSession()
        session.title = "Large local brief fixture"
        let sourceText = String(repeating: "Keep the technical requirement and its caveat. ", count: 20)
        session.transcripts = (0..<1_080).map { index in
            TranscriptRevision(rawText: sourceText, text: sourceText, origin: .imported,
                startTime: Double(index * 5), endTime: Double(index * 5 + 5))
        }
        var document = BriefDocument()
        let passages = (0..<1_000).map { index in
            BriefBlock(text: "Requirement \(index): " + String(repeating: "Preserve names, numbers, and the explicit negation. ", count: 8))
        }
        try document.apply(passages.map { .append(section: .changes, block: $0) },
            expectedRevision: document.revisionID, label: "Fixture")
        session.brief = document
        try await model.registerImportedSession(session)
        model.selectedSessionID = session.id
        let target = passages[500]
        let untouched = passages[499]
        let sourceIDs = session.transcripts.map(\.id)
        let initialJournalBytes = document.journalTextBytes
        let edits = 200
        let clock = ContinuousClock()
        let started = clock.now
        var expected = target.text
        var editMilliseconds: [Double] = []
        editMilliseconds.reserveCapacity(edits)
        // No await in this burst: measure actual in-memory controller/document edits,
        // excluding setup and the deliberately debounced durable save.
        for index in 0..<edits {
            expected = target.text + " Typed revision \(index)."
            let editStarted = clock.now
            model.updateBriefBlock(id: target.id, text: expected)
            let duration = editStarted.duration(to: clock.now).components
            editMilliseconds.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000)
        }
        let elapsed = started.duration(to: clock.now).components
        let totalMilliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        guard let current = model.currentBrief else {
            await model.stopForTermination()
            Issue.record("Typing unexpectedly removed the current brief.")
            return
        }
        #expect(model.error == nil)
        #expect(current.block(target.id)?.text.utf8.elementsEqual(expected.utf8) == true)
        #expect(current.block(untouched.id) == untouched)
        #expect(model.selectedSession?.transcripts.map(\.id) == sourceIDs)
        #expect(current.history.dropFirst().allSatisfy { $0.changes.count == 1 && $0.changes[0].blockID == target.id })
        #expect(current.journalTextBytes - initialJournalBytes < edits * (target.text.utf8.count + expected.utf8.count + 1))
        print("Keystorm real typing path fixture: \(edits) edits; 1000 passages; \(passages.reduce(0) { $0 + $1.text.utf8.count }) document UTF8 bytes; 1080 source revisions; \(session.transcripts.reduce(0) { $0 + $1.text.utf8.count }) transcript UTF8 bytes; \(totalMilliseconds) ms total; \(totalMilliseconds / Double(edits)) ms/edit mean. Includes controller, revision checks, undo journal and debounce scheduling; excludes disk/layout/inference and is not an end-to-end typing latency guarantee.")
        let ordered = editMilliseconds.sorted()
        func percentile(_ fraction: Double) -> Double { ordered[max(0, Int(ceil(Double(ordered.count) * fraction)) - 1)] }
        let flushStarted = clock.now
        await model.flushBriefEdits()
        let flush = flushStarted.duration(to: clock.now).components
        let report: [String: Any] = [
            "samples": edits, "passages": passages.count, "sourceRevisions": session.transcripts.count,
            "hardware": RuntimePerformanceReport.hardwareModel,
            "ramBytes": ProcessInfo.processInfo.physicalMemory,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "configuration": "Debug; same-process warm burst; no concurrent inference",
            "p50Milliseconds": percentile(0.5), "p95Milliseconds": percentile(0.95),
            "p99Milliseconds": percentile(0.99), "maximumMilliseconds": ordered.last!,
            "totalMilliseconds": totalMilliseconds,
            "flushMilliseconds": Double(flush.seconds) * 1_000 + Double(flush.attoseconds) / 1_000_000_000_000_000,
            "scope": "Production in-memory controller/document path including bounded telemetry and undo/debounce; excludes keyboard dispatch, SwiftUI layout/paint and inference. Flush measured separately."
        ]
        print("KEYSTORM_TYPING_REPORT " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        #expect(model.error == nil)
        await model.stopForTermination()
    }
}
