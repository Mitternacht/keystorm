import Foundation
import MLXGuidedGeneration
import MLXLMCommon

/// Model-owned tokenizer and compiled grammar resources. A supported bridge forks a
/// pristine template; the pinned bridge instead lends one matcher exclusively and rolls it
/// back after completed generation. Failed or cancelled jobs discard their matcher.
/// At most one reset matcher per schema remains cached, and every active job has its own state.
final class LocalGrammarCache: @unchecked Sendable {
    /// The pinned GuidedGenerationLoop omits the sampled token from the model cache
    /// whenever a grammar fast-forward follows it. Keep normal grammar-masked sampling
    /// until that upstream path preserves exact history. This retains every constraint
    /// and model check; only the optional structural-token shortcut is disabled.
    /// GuidedGenerationHistoryTests covers the production policy and the upstream defect.
    static let fastForwardEnabled = false

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

    /// An untouched matcher for one job. Scoped users return it through `withConstraint`.
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

    /// Borrows one matcher for a synchronous generation. Only a normally completed operation
    /// may return its exact number of accepted tokens (including fast-forward tokens).
    /// An early emit stop, cancellation or failure must throw: its accepted-token count can
    /// differ from the generation loop's returned count, so that matcher must be discarded.
    /// The matcher must not escape this scope.
    func withConstraint<Value>(
        for schema: Schema,
        _ operation: (GrammarConstraint) throws -> (value: Value, acceptedTokens: Int)
    ) throws -> Value {
        try Task.checkCancellation()
        let matcher = try constraint(for: schema)
        let initial = try matcher.computeMask()
        let result = try operation(matcher)
        try Task.checkCancellation()
        guard let accepted = Int32(exactly: result.acceptedTokens), accepted >= 0 else { return result.value }
        do {
            // The pinned bridge has unlimited rollback history even though it cannot fork.
            // Rewinding an exclusively borrowed matcher preserves its compiled grammar.
            try matcher.rollback(accepted)
            let reset = try matcher.computeMask()
            guard reset.mask == initial.mask, reset.isTerminated == initial.isTerminated,
                  reset.needsApply == initial.needsApply else { return result.value }
            lock.lock()
            if templates[schema] == nil { spares[schema] = matcher }
            lock.unlock()
        } catch {
            // A failed cache reset never invalidates a completed result. Drop this matcher;
            // the next request will compile a fresh one, as it did before reuse existed.
        }
        return result.value
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
            fastForward: Self.fastForwardEnabled && hostTokenizer != nil, hostTokenizer: hostTokenizer)
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
