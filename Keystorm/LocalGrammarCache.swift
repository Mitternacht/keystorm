import Foundation
import MLXGuidedGeneration
import MLXLMCommon

/// Model-owned immutable tokenizer resources. The pinned xgrammar 0.1.30 cannot
/// clone compiled matchers, so each job compiles its own fresh constraint. Vocabulary
/// discovery and tokenizer construction still happen only once per loaded model.
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

    func constraint(for schema: Schema) throws -> GrammarConstraint {
        lock.lock()
        defer { lock.unlock() }
        let start = ContinuousClock.now
        let matcher = try GrammarConstraint(tokenizer: tokenizer, jsonSchema: schema.json,
            fastForward: hostTokenizer != nil, hostTokenizer: hostTokenizer)
        compilations += 1
        matchers += 1
        compilationMicroseconds += Self.microseconds(start.duration(to: .now))
        return matcher
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
