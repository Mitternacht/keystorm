import Darwin
import Foundation
import Testing
@testable import Keystorm

/// Opt-in installed-model checks for Email and translation, gated exactly like
/// `DictationTransformRuntimeTests`. Passing them shows that the pinned local model can
/// produce outputs that satisfy the deterministic validators for these fixtures; it does
/// not measure translation quality, idiomatic wording or semantic equivalence.
struct DictationEmailTranslateRuntimeTests {
    private struct Fixture {
        let name: String
        let mode: DictationOutputMode
        let source: String
        let anchors: [String]
        let forbidden: [String]
    }

    @Test("Installed Qwen formats the Müller Email example and translates short EN/DE fixtures",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_DICTATION_TRANSFORM"] == "1"),
          .timeLimit(.minutes(10)))
    func installedModelEmailAndTranslation() async throws {
        let models = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("Keystorm/Models")
        let client = InferenceWorkerClient(modelDirectory: models)
        do {
            let config = try #require(try await client.verifiedConfiguration(for: ModelCatalog.primaryText),
                "Install the pinned Qwen3.5-4B model explicitly before this opt-in local test.")
            let fixtures = [
                Fixture(name: "email-muller-punctuated", mode: .email,
                        source: "Please send die Rechnung to Müller tomorrow, not today.",
                        anchors: ["die Rechnung", "Müller", "tomorrow", "not today"],
                        forbidden: ["Dear", "Hi ", "Hallo", "regards", "Grüße", "invoice"]),
                Fixture(name: "email-muller-unpunctuated", mode: .email,
                        source: "please send die Rechnung to Müller tomorrow not today",
                        anchors: ["die Rechnung", "Müller", "tomorrow", "not today"],
                        forbidden: ["Dear", "Hi ", "Hallo", "regards", "Grüße", "invoice"]),
                Fixture(name: "translate-en-to-de", mode: .translateGerman,
                        source: "Please do not upload the recording before 10:30.",
                        anchors: ["nicht", "10:30"], forbidden: ["<think", "Translation:"]),
                Fixture(name: "translate-de-to-en", mode: .translateEnglish,
                        source: "Bitte schick die 42 Dateien nicht vor Freitag an Müller.",
                        anchors: ["42", "Müller", "not", "Friday"], forbidden: ["<think", "Übersetzung"])
            ]
            var cases: [EmailTranslateSmokeCase] = []
            for fixture in fixtures {
                let request = DictationTransformRequest(sourceRevisionID: UUID(),
                    sourceSHA256: DictationTransformPolicy.sourceDigest(fixture.source), mode: fixture.mode,
                    sourceText: fixture.source, configuration: config)
                let start = ContinuousClock.now
                do {
                    let result = try await client.transform(request)
                    try LocalInference.validateTransformReply(result, request: request)
                    #expect(result.promptTemplateSHA256 == DictationTransformPolicy.promptTemplateSHA256(for: fixture.mode))
                    #expect(result.generatedTokens > 0 && result.generatedTokens < config.outputLimit)
                    for anchor in fixture.anchors {
                        #expect(result.text.localizedCaseInsensitiveContains(anchor),
                            "Actual \(fixture.name) output must retain anchor: \(anchor)")
                    }
                    for word in fixture.forbidden {
                        #expect(!result.text.contains(word), "Actual \(fixture.name) output must not contain: \(word)")
                    }
                    if fixture.mode.translationTarget != nil {
                        #expect(!result.text.utf8.elementsEqual(fixture.source.utf8),
                            "A cross-language fixture needs an actual translation, not an unchanged copy.")
                    }
                    cases.append(EmailTranslateSmokeCase(name: fixture.name, mode: fixture.mode, source: fixture.source,
                        text: result.text, error: nil, elapsedMilliseconds: Self.milliseconds(since: start)))
                } catch {
                    cases.append(EmailTranslateSmokeCase(name: fixture.name, mode: fixture.mode, source: fixture.source,
                        text: (error as? DictationTransformGenerationFailure)?.generatedEnvelope,
                        error: error.localizedDescription, elapsedMilliseconds: Self.milliseconds(since: start)))
                    Issue.record(error, "Local transform failed for fixture \(fixture.name)")
                }
            }
            await client.releaseText()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            Attachment.record(try encoder.encode(cases), named: "dictation-email-translate-runtime.json")
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1_000_000_000_000_000
    }
}

private struct EmailTranslateSmokeCase: Codable {
    let name: String
    let mode: DictationOutputMode
    let source: String
    let text: String?
    let error: String?
    let elapsedMilliseconds: Double
}
