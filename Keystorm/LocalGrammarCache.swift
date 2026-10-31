import Foundation
import MLXGuidedGeneration
import MLXLMCommon

/// Model-owned immutable tokenizer resources. Vocabulary discovery and tokenizer
/// construction happen once per loaded model, and so does compiling each schema: the cache
/// keeps one pristine compiled constraint per schema and hands every job its own fork
/// (`GrammarConstraint.clone()` shares the immutable compiled grammar and copies only the
/// matcher state). A job never advances the pristine copy, so every fork starts untouched.
/// If a fork ever fails, the job falls back to compiling its own constraint, as before.
final class LocalGrammarCache: @unchecked Sendable {
    enum Schema: Hashable, Sendable {
        case extraction, edit, dictationTransform, correctionClassification

        var json: String {
            switch self {
            case .extraction: ExtractionEnvelope.schema
            case .edit: BriefEditEnvelope.schema
            case .dictationTransform: DictationTransformEnvelope.schema
            case .correctionClassification: CorrectionClassificationEnvelope.schema
            }
        }
    }
    let tokenizer: GrammarTokenizer
    private let hostTokenizer: (any MLXLMCommon.Tokenizer)?
    private let lock = NSLock()
    private var compilations = 0
    private var matchers = 0
    private var compilationMicroseconds: UInt64 = 0
    private var templates: [Schema: GrammarConstraint] = [:]
    /// A compiled, untouched constraint kept when the pinned xgrammar cannot fork (it needs 0.1.34).
    private var spares: [Schema: GrammarConstraint] = [:]
    let tokenizerMicroseconds: UInt64

    init(hostTokenizer: any MLXLMCommon.Tokenizer) throws {
        let start = ContinuousClock.now
        let vocabulary = TokenizerVocabExtractor.extractForGrammar(from: hostTokenizer)
        tokenizer = try GrammarTokenizer(vocab: vocabulary.vocab, vocabType: vocabulary.vocabType,
            eosTokenId: Int32(hostTokenizer.eosTokenId ?? 0))
        self.hostTokenizer = hostTokenizer
        tokenizerMicroseconds = Self.microseconds(start.duration(to: .now))
    }

    /// Small-vocabulary constructor for matcher isolation tests.
    init(tokenizer: GrammarTokenizer) {
        self.tokenizer = tokenizer
        hostTokenizer = nil
        tokenizerMicroseconds = 0
    }

    /// An untouched matcher for one job. Compiles the schema only the first time.
    func constraint(for schema: Schema) throws -> GrammarConstraint {
        lock.lock()
        defer { lock.unlock() }
        let start = ContinuousClock.now
        let matcher: GrammarConstraint
        if let template = templates[schema], let fork = try? template.clone() {
            matcher = fork
        } else if let spare = spares.removeValue(forKey: schema) {
            matcher = spare
        } else {
            let compiled = try compileLocked(schema)
            // Keep this pristine copy and hand out a fork. If forking fails, hand out the copy
            // itself and cache nothing, which is the behaviour from before templates existed.
            if let fork = try? compiled.clone() {
                templates[schema] = compiled
                matcher = fork
            } else {
                matcher = compiled
            }
        }
        matchers += 1
        compilationMicroseconds += Self.microseconds(start.duration(to: .now))
        return matcher
    }

    /// Compiles a schema ahead of its first job, for example while the text model warms up,
    /// so the first Clean does not pay for it. Hands out nothing; the next job takes the spare
    /// when forking is unavailable.
    func prime(_ schema: Schema) throws {
        lock.lock()
        defer { lock.unlock() }
        guard templates[schema] == nil, spares[schema] == nil else { return }
        let start = ContinuousClock.now
        let compiled = try compileLocked(schema)
        if (try? compiled.clone()) != nil { templates[schema] = compiled } else { spares[schema] = compiled }
        compilationMicroseconds += Self.microseconds(start.duration(to: .now))
    }

    private func compileLocked(_ schema: Schema) throws -> GrammarConstraint {
        let compiled = try GrammarConstraint(tokenizer: tokenizer, jsonSchema: schema.json,
            fastForward: hostTokenizer != nil, hostTokenizer: hostTokenizer)
        compilations += 1
        return compiled
    }

    func statistics() -> [String: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "grammarTokenizerBuilds": 1, "grammarSchemaCompilations": UInt64(compilations),
            "grammarMatchersCreated": UInt64(matchers), "grammarTokenizerMicroseconds": tokenizerMicroseconds,
            "grammarCompilationMicroseconds": compilationMicroseconds
        ]
    }

    private static func microseconds(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        return UInt64(max(0, parts.seconds)) * 1_000_000 + UInt64(max(0, parts.attoseconds)) / 1_000_000_000_000
    }
}
