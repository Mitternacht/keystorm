import Foundation
import Testing
@testable import Keystorm

/// Independent, predeclared synthetic written edits. These are not human ASR accuracy data.
@Suite(.serialized)
struct LearningAccuracyHeldOutTests {
    private static let corpusSHA256 = "262f7f662aac7af55b6744490077a79bf3f9f05319ec4e4dd33e623a92df2d79"
    private static let app = "org.keystorm.heldout.editor"

    private struct Corpus: Codable {
        var version: Int
        var `protocol`: String
        var cases: [Fixture]
    }
    private struct Fixture: Codable {
        var id: String
        var category: String
        var language: String
        var automaticEligible: Bool
        var goldLabel: String
        var before: String
        var after: String
    }
    private struct SessionResult: Codable {
        var sessionID: UUID
        var evidence: CorrectionEvidence?
        var receipt: CorrectionClassificationReceipt?
        var automaticVote: Bool?
        var error: String?
        var milliseconds: Double
    }
    private struct Probe: Codable {
        var kind: String
        var input: String
        var actual: String
        var appliedTermIDs: [UUID]
    }
    private struct CaseResult: Codable {
        var fixture: Fixture
        var sessions: [SessionResult] = []
        var firstSessionActual: String?
        var actual: String?
        var appliedTermIDs: [UUID] = []
        var savedReceiptsAfterRestart = 0
        var termStatuses: [String] = []
        var probes: [Probe] = []
        var error: String?
    }
    private struct Report: Codable {
        var corpusSHA256: String
        var corpusVersion: Int
        var declaredProtocol: String
        var modelConfiguration: ProcessingConfiguration
        var promptTemplateSHA256: String
        var startedAt: Date
        var finishedAt: Date?
        var positiveCount = 40
        var negativeCount = 60
        var minimumCorrectAutomaticPositives = 24
        var correctAutomaticPositives = 0
        var wrongAutomaticNegatives = 0
        var wrongAutomaticPositives = 0
        var prematureApplications = 0
        var protectedProbeFailures = 0
        var results: [CaseResult] = []
    }

    @Test("Frozen independent held-out learning accuracy and two-session application",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_LEARNING_HELDOUT"] == "1"),
          .timeLimit(.minutes(60)))
    func installedModelHeldOutCorpus() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("LearningAccuracyHeldOutFixtures.json")
        let data = try Data(contentsOf: fixtureURL)
        try #require(DictationTransformPolicy.sourceDigest(String(decoding: data, as: UTF8.self)) == Self.corpusSHA256,
                "The first-pass held-out gold corpus must remain frozen.")
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        try #require(corpus.cases.count == 100)
        try #require(corpus.cases.filter(\.automaticEligible).count == 40)
        try #require(corpus.cases.filter { !$0.automaticEligible }.count == 60)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-HeldOut-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outputDirectory = ProcessInfo.processInfo.environment["KEYSTORM_LEARNING_HELDOUT_REPORT_DIRECTORY"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appendingPathComponent("learning-heldout-\(UUID()).json")
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let client = InferenceWorkerClient(modelDirectory: models)
        do {
            let config = try #require(try await client.verifiedConfiguration(for: ModelCatalog.primaryText),
                "Requires the already-installed pinned local model; never downloads.")
            var report = Report(corpusSHA256: Self.corpusSHA256, corpusVersion: corpus.version,
                declaredProtocol: corpus.protocol, modelConfiguration: config,
                promptTemplateSHA256: CorrectionLearningPolicy.promptTemplateSHA256, startedAt: Date())
            for fixture in corpus.cases {
                var result = CaseResult(fixture: fixture)
                do {
                    let url = root.appendingPathComponent("\(fixture.id).json")
                    let repository = try LearningRepository(url: url)
                    try await repository.setEnabled(true)
                    for index in 0..<2 {
                        let sessionID = UUID()
                        let start = ContinuousClock.now
                        let source = DictationTextRevision(rawText: fixture.before, text: fixture.before, sourceTranscriptIDs: [])
                        let edited = DictationTextRevision(rawText: fixture.before, text: fixture.after, sourceTranscriptIDs: [])
                        let evidence = CorrectionLearningPolicy.evidence(source: source, edited: edited,
                            sessionID: sessionID, takeID: UUID(), appBundleID: Self.app)
                        var session = SessionResult(sessionID: sessionID, evidence: evidence, milliseconds: 0)
                        if let evidence {
                            do {
                                try #require(try await repository.enqueue(evidence))
                                let request = CorrectionClassificationRequest(evidence: evidence, configuration: config)
                                let classification = try await client.classifyCorrection(request)
                                try CorrectionLearningPolicy.validate(classification, request: request)
                                let receipt = CorrectionClassificationReceipt(request: request, result: classification)
                                session.receipt = receipt
                                session.automaticVote = CorrectionLearningPolicy.isAutomaticVote(classification, evidence: evidence)
                                try await repository.classify(receipt)
                            } catch {
                                session.error = String(describing: error)
                            }
                        }
                        session.milliseconds = Self.milliseconds(start.duration(to: .now))
                        result.sessions.append(session)
                        if index == 0 {
                            let suggestions = await repository.suggestions(for: fixture.before, appBundleID: Self.app)
                            result.firstSessionActual = LearnedTermApplicator.apply(suggestions: suggestions, to: fixture.before).text
                        }
                    }
                    let reopened = try LearningRepository(url: url)
                    let snapshot = await reopened.snapshot()
                    result.savedReceiptsAfterRestart = snapshot.evidence.filter { $0.receipt != nil }.count
                    result.termStatuses = snapshot.terms.map { $0.status.rawValue }
                    let suggestions = await reopened.suggestions(for: fixture.before, appBundleID: Self.app)
                    let applied = LearnedTermApplicator.apply(suggestions: suggestions, to: fixture.before)
                    result.actual = applied.text
                    result.appliedTermIDs = applied.termIDs
                    if fixture.automaticEligible, let evidence = result.sessions.first?.evidence {
                        for (kind, replacement) in [
                            ("inline-code", "`\(evidence.variant)`"),
                            ("path", "/tmp/\(evidence.variant)"),
                            ("url", "https://example.org/\(evidence.variant)"),
                            ("email", "\(evidence.variant)@example.org")
                        ] {
                            let probe = fixture.before.replacingOccurrences(of: evidence.variant, with: replacement)
                            let qualified = await reopened.suggestions(for: probe, appBundleID: Self.app)
                            let output = LearnedTermApplicator.apply(suggestions: qualified, to: probe)
                            result.probes.append(Probe(kind: kind, input: probe, actual: output.text, appliedTermIDs: output.termIDs))
                        }
                        let foreign = await reopened.suggestions(for: fixture.before, appBundleID: "org.keystorm.heldout.other")
                        let output = LearnedTermApplicator.apply(suggestions: foreign, to: fixture.before)
                        result.probes.append(Probe(kind: "foreign-app", input: fixture.before,
                            actual: output.text, appliedTermIDs: output.termIDs))
                    }
                } catch {
                    result.error = String(describing: error)
                }
                if result.firstSessionActual.map({ $0 != fixture.before }) ?? false { report.prematureApplications += 1 }
                if fixture.automaticEligible {
                    if result.actual == fixture.after && !result.appliedTermIDs.isEmpty {
                        report.correctAutomaticPositives += 1
                    } else if let actual = result.actual, actual != fixture.before {
                        report.wrongAutomaticPositives += 1
                    }
                } else if result.actual.map({ $0 != fixture.before }) ?? false {
                    report.wrongAutomaticNegatives += 1
                }
                report.protectedProbeFailures += result.probes.filter { $0.actual != $0.input }.count
                report.results.append(result)
                try Self.save(report, at: outputURL)
                print("HELDOUT_PROGRESS \(fixture.id) completed \(report.results.count)/100")
            }
            report.finishedAt = Date()
            try Self.save(report, at: outputURL)
            let finalData = try Data(contentsOf: outputURL)
            Attachment.record(finalData, named: "learning-heldout-first-pass.json")
            print("HELDOUT_REPORT \(outputURL.path)")
            print("HELDOUT_COUNTS positive=\(report.correctAutomaticPositives)/40 negativeWrong=\(report.wrongAutomaticNegatives)/60 protectedWrong=\(report.protectedProbeFailures)")
            #expect(report.results.count == 100)
            #expect(report.results.allSatisfy { $0.error == nil }, "Every fixture must complete repository and retrieval evaluation.")
            #expect(report.correctAutomaticPositives >= 24, "Predeclared minimum useful automatic yield is 24/40.")
            #expect(report.wrongAutomaticNegatives == 0, "No negative gold fixture may be changed automatically.")
            #expect(report.wrongAutomaticPositives == 0)
            #expect(report.prematureApplications == 0, "One session must never auto-promote.")
            #expect(report.protectedProbeFailures == 0, "Learned terms must preserve literal spans and app scope.")
            for result in report.results {
                #expect(result.sessions.count == 2)
                #expect(Set(result.sessions.map(\.sessionID)).count == 2)
                #expect(result.savedReceiptsAfterRestart == result.sessions.filter { $0.receipt != nil }.count)
            }
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private static func save(_ report: Report, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
}
