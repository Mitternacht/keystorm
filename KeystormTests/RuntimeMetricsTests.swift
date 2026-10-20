import Foundation
import Testing
@testable import Keystorm

struct RuntimeMetricsTests {
    @Test func nearestRankPercentilesKeepCaptureSamplesAcrossFrequentPreviews() throws {
        var samples = RuntimeMetricSamples()
        let firstValue = samples.record(kind: "capture.engineStart", milliseconds: 42)
        let first = try #require(firstValue)
        #expect(first.count == 1 && first.p50Milliseconds == 42)
        for value in 1...1_000 { _ = samples.record(kind: "speech.preview", milliseconds: Double(value)) }
        let captureValue = samples.record(kind: "capture.engineStart", milliseconds: 44)
        let capture = try #require(captureValue)
        #expect(capture.count == 2 && capture.p95Milliseconds == 44)
        let previewValue = samples.record(kind: "speech.preview", milliseconds: 1_001)
        let preview = try #require(previewValue)
        #expect(preview.count == 128)
        #expect(preview.p50Milliseconds == 937)
        #expect(preview.p95Milliseconds == 995)
        #expect(preview.p99Milliseconds == 1_000)
        #expect(preview.maximumMilliseconds == 1_001)
    }

    @Test func `Prewarm and Finish join timings have readable titles and their own bounded rings`() throws {
        var samples = RuntimeMetricSamples()
        for value in 1...200 { _ = samples.record(kind: "speech.preview", milliseconds: Double(value)) }
        let prewarmValue = samples.record(kind: TextPrewarmPolicy.metricKind, milliseconds: 2_400)
        let prewarm = try #require(prewarmValue)
        #expect(prewarm.count == 1 && prewarm.p95Milliseconds == 2_400)
        #expect(prewarm.title == "Text model prewarm (load)")
        let joinValue = samples.record(kind: TextPrewarmPolicy.finishJoinMetricKind, milliseconds: 120)
        let join = try #require(joinValue)
        #expect(join.count == 1)
        #expect(join.title == "Finish wait for in-flight model work")
    }

    @Test func malformedMetricsCannotGrowTheRetainedState() {
        var samples = RuntimeMetricSamples()
        for value in [Double.nan, .infinity, -.infinity, -1] {
            let result = samples.record(kind: "invalid", milliseconds: value)
            #expect(result == nil)
        }
        let empty = samples.record(kind: "", milliseconds: 1)
        let oversized = samples.record(kind: String(repeating: "x", count: 129), milliseconds: 1)
        #expect(empty == nil)
        #expect(oversized == nil)
        for index in 0..<RuntimeMetricSamples.maximumMetrics {
            let result = samples.record(kind: "metric.\(index)", milliseconds: 0)
            #expect(result != nil)
        }
        let overflow = samples.record(kind: "overflow", milliseconds: 0)
        let retained = samples.record(kind: "metric.0", milliseconds: 1)
        #expect(overflow == nil)
        #expect(retained?.count == 2)
    }

    @MainActor @Test func reportContainsConfigurationAndBoundedTimingsWithoutSessionContent() throws {
        let model = WorkspaceModel()
        for index in 0..<200 { model.recordPerformance(kind: "speech.preview", milliseconds: Double(index)) }
        model.recordPerformance(kind: "capture.engineStart", milliseconds: 7)
        let data = try model.performanceReportData()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(RuntimePerformanceReport.self, from: data)
        #expect(report.schemaVersion == 1)
        #expect(report.recentMeasurements.count == 100)
        #expect(report.summaries.first(where: { $0.kind == "speech.preview" })?.count == 128)
        #expect(report.summaries.first(where: { $0.kind == "capture.engineStart" })?.count == 1)
        #expect(report.physicalMemoryBytes > 0 && report.logicalProcessors > 0)
        #expect(!report.hardwareModel.isEmpty)
        #expect(report.limitations.contains("cold/warm"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["sessions"] == nil && json["transcripts"] == nil && json["projectPath"] == nil)
    }

    @MainActor @Test func importedCorrectionsRetainEditIdentityInAnyArrayOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Lineage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(root: directory)
        await model.initialize(loadLibrary: true)
        let original = TranscriptRevision(rawText: "append to constraints: Keep it private.", text: "append to constraints: Keep it private.", origin: .imported)
        let middle = TranscriptRevision(replacesID: original.id, rawText: original.rawText,
            text: "append to constraints: Keep all audio local.", origin: .imported)
        let latest = TranscriptRevision(replacesID: middle.id, rawText: original.rawText,
            text: "append to constraints: Never upload audio.", origin: .imported)
        var session = VoiceSession()
        var brief = BriefDocument()
        brief.takes = [BriefTake(intent: .editBrief, targetSection: .constraints,
            expectedRevision: brief.revisionID, status: .pending, transcriptIDs: [original.id])]
        session.brief = brief
        session.transcripts = [latest, middle, original]
        try await model.registerImportedSession(session)
        await model.addFact(transcriptID: latest.id, text: latest.text, kind: .requirement, status: .confirmed)
        #expect(model.selectedSession?.facts.isEmpty == true)
        await model.prepareBrief()
        #expect(model.error == nil)
        #expect(model.pendingBriefProposal?.edits.count == 1)
        await model.acceptBriefProposal()
        #expect(model.currentBrief?.section(.constraints).blocks.first?.text == "Never upload audio.")
        #expect(model.currentBrief?.section(.constraints).blocks.first?.sources.first?.transcriptID == latest.id)
        #expect(model.performanceSummaries.first { $0.kind == "brief.proposal" }?.count == 1)
        await model.prepareBrief()
        #expect(model.error != nil)
        #expect(model.pendingBriefProposal == nil)
        #expect(model.performanceSummaries.first { $0.kind == "brief.proposal" }?.count == 1)
        #expect(model.performanceSummaries.first { $0.kind == "brief.prepareAttempt" }?.count == 2)
        await model.stopForTermination()
    }

    @MainActor @Test func reviewCacheInvalidatesWhenSourcesChangeAndExactDeletionRequiresUnlock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-MetricReview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(root: directory)
        await model.initialize(loadLibrary: true)
        #expect(model.briefReviewIssues.contains { $0.kind == .emptyDocument })
        await model.appendBriefBlock(text: "Keep every byte.")
        #expect(!model.briefReviewIssues.contains { $0.kind == .emptyDocument })
        await model.insertExactReference(text: "  /tmp/cafe\u{301}.swift\n")
        let exact = try #require(model.currentBrief?.blocks.last)
        await model.removeBriefBlock(id: exact.id)
        #expect(model.currentBrief?.block(exact.id)?.exact == true)
        #expect(model.selectedBlockIDs.contains(exact.id))
        await model.unlockBriefBlock(id: exact.id)
        await model.removeBriefBlock(id: exact.id)
        #expect(model.currentBrief?.block(exact.id) == nil)
        await model.importTranscript(text: "There is more material to review.")
        #expect(model.briefReviewIssues.contains { $0.kind == .pendingTake })
        await model.stopForTermination()
    }
}
