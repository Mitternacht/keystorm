import Foundation
import Testing
@testable import Keystorm

/// Independent, predeclared synthetic written edits. These are not human ASR accuracy data.
@Suite(.serialized)
struct LearningAccuracyHeldOutV3Tests {
    private static let corpusSHA256 = "39795580c24db0f61de0586d5659d373be1aec104a564a6882b79ce36f86c973"
    private static let app = "org.keystorm.heldout.editor"

    private struct Corpus: Codable {
        var version: Int
        var `protocol`: String
        var cases: [Fixture]
    }
    private struct Fixture: Codable, Equatable {
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
        var runID: String
        var batchID: Int
        var candidateSourceSHA256: [String: String]
        var automaticPolicyVersion: Int
        var promptTemplateVersion: Int
        var lexiconSHA256: String
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

    @Test("Fresh v3 held-out batch 1: frozen cases 1–25",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_LEARNING_HELDOUT_V3"] == "1"),
          .timeLimit(.minutes(10)))
    func installedModelBatch1() async throws { try await runBatch(1) }

    @Test("Fresh v3 held-out batch 2: frozen cases 26–50",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_LEARNING_HELDOUT_V3"] == "1"),
          .timeLimit(.minutes(10)))
    func installedModelBatch2() async throws { try await runBatch(2) }

    @Test("Fresh v3 held-out batch 3: frozen cases 51–75",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_LEARNING_HELDOUT_V3"] == "1"),
          .timeLimit(.minutes(10)))
    func installedModelBatch3() async throws { try await runBatch(3) }

    @Test("Fresh v3 held-out batch 4: frozen cases 76–100",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_LEARNING_HELDOUT_V3"] == "1"),
          .timeLimit(.minutes(10)))
    func installedModelBatch4() async throws { try await runBatch(4) }

    private func runBatch(_ batchID: Int) async throws {
        let corpus = try Self.frozenCorpus()
        let (runID, outputDirectory) = try Self.runContext()
        let outputURL = Self.reportURL(directory: outputDirectory, runID: runID, batchID: batchID)
        try #require(!FileManager.default.fileExists(atPath: outputURL.path),
            "A first-pass batch report already exists; do not overwrite or silently rerun it.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-HeldOutV3-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let client = InferenceWorkerClient(modelDirectory: models)
        do {
            let config = try #require(try await client.verifiedConfiguration(for: ModelCatalog.primaryText),
                "Requires the already-installed pinned local model; never downloads.")
            var report = Report(runID: runID, batchID: batchID,
                candidateSourceSHA256: try Self.candidateSourceHashes(),
                automaticPolicyVersion: CorrectionLearningPolicy.automaticPolicyVersion,
                promptTemplateVersion: CorrectionLearningPolicy.templateVersion,
                lexiconSHA256: Self.lexiconSHA256,
                corpusSHA256: Self.corpusSHA256, corpusVersion: corpus.version,
                declaredProtocol: corpus.protocol, modelConfiguration: config,
                promptTemplateSHA256: CorrectionLearningPolicy.promptTemplateSHA256, startedAt: Date())
            for fixture in corpus.cases[((batchID - 1) * 25)..<(batchID * 25)] {
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
                print("HELDOUT_V3_PROGRESS \(fixture.id) batch \(batchID) completed \(report.results.count)/25")
            }
            report.finishedAt = Date()
            try Self.save(report, at: outputURL)
            let finalData = try Data(contentsOf: outputURL)
            Attachment.record(finalData, named: "learning-heldout-v3-batch-\(batchID).json")
            print("HELDOUT_V3_REPORT \(outputURL.path)")
            print("HELDOUT_V3_COUNTS positive=\(report.correctAutomaticPositives)/40 negativeWrong=\(report.wrongAutomaticNegatives)/60 protectedWrong=\(report.protectedProbeFailures)")
            #expect(report.results.count == 25)
            #expect(report.results.allSatisfy { $0.error == nil }, "Every fixture must complete repository and retrieval evaluation.")
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

    @Test("Aggregate four first-pass batches against the fixed 40/60 gold corpus",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_LEARNING_HELDOUT_V3"] == "1"))
    func aggregateFirstPass() throws {
        let corpus = try Self.frozenCorpus()
        let (runID, directory) = try Self.runContext()
        let reports = try (1...4).map { batchID in
            try JSONDecoder().decode(Report.self, from: Data(contentsOf:
                Self.reportURL(directory: directory, runID: runID, batchID: batchID)))
        }
        let sourceHashes = try Self.candidateSourceHashes()
        let first = try #require(reports.first)
        for (index, report) in reports.enumerated() {
            try #require(report.runID == runID && report.batchID == index + 1)
            try #require(report.finishedAt != nil)
            try #require(report.corpusSHA256 == Self.corpusSHA256 && report.corpusVersion == corpus.version)
            try #require(report.declaredProtocol == corpus.protocol)
            try #require(report.candidateSourceSHA256 == sourceHashes)
            try #require(report.modelConfiguration == first.modelConfiguration)
            try #require(report.promptTemplateSHA256 == CorrectionLearningPolicy.promptTemplateSHA256)
            try #require(report.promptTemplateVersion == CorrectionLearningPolicy.templateVersion)
            try #require(report.automaticPolicyVersion == CorrectionLearningPolicy.automaticPolicyVersion)
            try #require(report.lexiconSHA256 == Self.lexiconSHA256)
            try #require(report.positiveCount == 40 && report.negativeCount == 60 &&
                         report.minimumCorrectAutomaticPositives == 24)
            let expected = Array(corpus.cases[(index * 25)..<((index + 1) * 25)])
            try #require(report.results.map(\.fixture) == expected,
                "Each partition must contain exactly its frozen cases in order.")
            for result in report.results {
                for session in result.sessions {
                    if let receipt = session.receipt {
                        try #require(receipt.request.configuration == report.modelConfiguration)
                        try #require(receipt.request.evidence == session.evidence)
                        try #require(receipt.request.evidence.sessionID == session.sessionID)
                        try CorrectionLearningPolicy.validate(receipt.result, request: receipt.request)
                        let lexical = try #require(receipt.result.lexicalAssessment)
                        try #require(lexical.lexiconSHA256 == nil || lexical.lexiconSHA256 == report.lexiconSHA256)
                    }
                }
            }
        }
        let results = reports.flatMap(\.results)
        try #require(results.count == 100 && Set(results.map { $0.fixture.id }).count == 100)
        try #require(results.map(\.fixture) == corpus.cases)
        var aggregate = first
        aggregate.batchID = 0
        aggregate.startedAt = reports.map(\.startedAt).min()!
        aggregate.finishedAt = reports.compactMap(\.finishedAt).max()
        aggregate.results = results
        // Recompute from case outputs; do not trust persisted aggregate counters.
        aggregate.correctAutomaticPositives = results.filter {
            $0.fixture.automaticEligible && $0.actual == $0.fixture.after && !$0.appliedTermIDs.isEmpty
        }.count
        aggregate.wrongAutomaticNegatives = results.filter { result in
            !result.fixture.automaticEligible && result.actual.map { $0 != result.fixture.before } == true
        }.count
        aggregate.wrongAutomaticPositives = results.filter { result in
            result.fixture.automaticEligible && result.actual.map {
                $0 != result.fixture.before && !($0 == result.fixture.after && !result.appliedTermIDs.isEmpty)
            } == true
        }.count
        aggregate.prematureApplications = results.filter { result in
            result.firstSessionActual.map { $0 != result.fixture.before } == true
        }.count
        aggregate.protectedProbeFailures = results.flatMap(\.probes).filter { $0.actual != $0.input }.count
        let outputURL = directory.appendingPathComponent("learning-heldout-v3-\(runID)-aggregate.json")
        try #require(!FileManager.default.fileExists(atPath: outputURL.path),
            "Preserve the original aggregate first-pass report.")
        try Self.save(aggregate, at: outputURL)
        Attachment.record(try Data(contentsOf: outputURL), named: "learning-heldout-v3-first-pass-aggregate.json")
        print("HELDOUT_V3_AGGREGATE \(outputURL.path)")
        print("HELDOUT_V3_COUNTS positive=\(aggregate.correctAutomaticPositives)/40 negativeWrong=\(aggregate.wrongAutomaticNegatives)/60 protectedWrong=\(aggregate.protectedProbeFailures)")
        #expect(results.allSatisfy { $0.error == nil })
        #expect(aggregate.correctAutomaticPositives >= 24, "Predeclared minimum useful automatic yield is 24/40.")
        #expect(aggregate.wrongAutomaticNegatives == 0, "No negative gold fixture may be changed automatically.")
        #expect(aggregate.wrongAutomaticPositives == 0)
        #expect(aggregate.prematureApplications == 0, "One session must never auto-promote.")
        #expect(aggregate.protectedProbeFailures == 0, "Learned terms must preserve literal spans and app scope.")
        for result in results {
            #expect(result.sessions.count == 2)
            #expect(Set(result.sessions.map(\.sessionID)).count == 2)
            #expect(result.savedReceiptsAfterRestart == result.sessions.filter { $0.receipt != nil }.count)
        }
    }

    private static var lexiconSHA256: String {
        DictationTransformPolicy.sourceDigest("learning-exclusion-v1\nen:" +
            LearningLexiconResourcePins.englishSHA256 + "\nde:" + LearningLexiconResourcePins.germanSHA256 + "\n")
    }

    private static func frozenCorpus() throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("LearningAccuracyHeldOutV3Fixtures.json")
        let data = try Data(contentsOf: url)
        try #require(DictationTransformPolicy.sourceDigest(String(decoding: data, as: UTF8.self)) == corpusSHA256,
            "The fresh first-pass gold corpus must remain frozen.")
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        try #require(corpus.cases.count == 100 && Set(corpus.cases.map(\.id)).count == 100)
        try #require(corpus.cases.filter(\.automaticEligible).count == 40)
        try #require(corpus.cases.filter { !$0.automaticEligible }.count == 60)
        return corpus
    }

    private static func runContext() throws -> (String, URL) {
        let environment = ProcessInfo.processInfo.environment
        struct RunControl: Decodable {
            var runID: String
            var reportDirectory: String
        }
        let runID: String
        let path: String
        if let environmentRunID = environment["KEYSTORM_LEARNING_HELDOUT_V3_RUN_ID"],
           let environmentDirectory = environment["KEYSTORM_LEARNING_HELDOUT_REPORT_DIRECTORY"] {
            runID = environmentRunID
            path = environmentDirectory
        } else {
            try #require(environment["KEYSTORM_LEARNING_HELDOUT_V3_RUN_ID"] == nil &&
                         environment["KEYSTORM_LEARNING_HELDOUT_REPORT_DIRECTORY"] == nil,
                "Specify both environment values or use the explicit control file.")
            let controlURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("LearningAccuracyHeldOutV3RunControl.json")
            let control = try JSONDecoder().decode(RunControl.self, from: Data(contentsOf: controlURL))
            runID = control.runID
            path = control.reportDirectory
        }
        try #require(!runID.isEmpty && runID.utf8.count <= 64 &&
            runID.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        try #require(path.hasPrefix("/"), "The report directory must be an explicit absolute path.")
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (runID, directory)
    }

    private static func reportURL(directory: URL, runID: String, batchID: Int) -> URL {
        directory.appendingPathComponent("learning-heldout-v3-\(runID)-batch-\(batchID).json")
    }

    private static func candidateSourceHashes() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let paths = ["Keystorm/CorrectionLearning.swift", "Keystorm/CorrectionLexicon.swift",
            "Keystorm/LearningLexiconResourcePins.swift", "Keystorm/LearningRepository.swift",
            "Keystorm/LocalInference.swift", "KeystormTests/LearningAccuracyHeldOutV3Tests.swift"]
        return try Dictionary(uniqueKeysWithValues: paths.map { path in
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            return (path, DictationTransformPolicy.sourceDigest(String(decoding: data, as: UTF8.self)))
        })
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
