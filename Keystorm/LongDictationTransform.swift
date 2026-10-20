import Foundation

enum LongDictationTransformError: LocalizedError, Equatable {
    case unsupportedMode, unsupportedContext, invalidSource, invalidBounds, oversizedUnit, tooManyChunks
    case staleSource, invalidResult, outputLimit

    var errorDescription: String? {
        switch self {
        case .unsupportedMode: "Long recordings support explicit Summarize or Organize previews. Clean, Email and translation need a shorter passage. The original remains saved."
        case .unsupportedContext: "Long previews currently use transcript text only. The original remains saved."
        case .invalidSource: "Choose a nonempty transcript within the 8 MB long-transform limit."
        case .invalidBounds: "The long-transform chunk bounds are invalid."
        case .oversizedUnit: "A word, literal or spacing run exceeds the local chunk limit. The original remains saved."
        case .tooManyChunks: "This transcript needs more than 1,024 bounded sections. Select a smaller passage."
        case .staleSource: "The transcript changed while the long preview was being prepared."
        case .invalidResult: "A long-preview section no longer matches its source or model settings."
        case .outputLimit: "The long preview exceeds its 1 MB output limit. No partial result was applied."
        }
    }
}

/// Only byte ranges and hashes are retained in the plan. The original text remains
/// the one source authority; the plan does not duplicate it or invent transcripts.
struct LongDictationTransformPlan: Codable, Equatable, Sendable {
    struct Chunk: Codable, Equatable, Identifiable, Sendable {
        var index: Int
        var startUTF8: Int
        var endUTF8: Int
        var sourceSHA256: String
        var id: String { "\(index):\(startUTF8):\(endUTF8):\(sourceSHA256)" }
        var sourceByteCount: Int { endUTF8 - startUTF8 }
        /// Display metadata only. This label is never sent as source or model output.
        var sourceLabel: String { "Section \(index + 1) · source bytes \(startUTF8)–\(endUTF8)" }
    }

    var version = 2
    var sourceRevisionID: UUID
    var sourceSHA256: String
    var sourceRawSHA256: String
    var sourceTranscriptIDs: [UUID]
    var sourceCreatedAt: Date
    var sourceByteCount: Int
    var mode: DictationOutputMode
    var languagePolicy: DictationLanguagePolicy
    var configuration: ProcessingConfiguration
    var contextSHA256: String?
    var chunkUTF8Limit: Int
    var chunks: [Chunk]
}

/// A sequence of individually validated, independent section summaries/organizations.
/// This is not a recursively synthesized global summary. Text is computed to avoid
/// persisting a second copy of every generated section in the same report.
struct LongDictationTransformResult: Codable, Equatable, Sendable {
    var jobID = UUID()
    var plan: LongDictationTransformPlan
    var outputs: [DictationTransformResult]
    var generatedTokens: Int
    var text: String { outputs.map(\.text).joined(separator: "\n\n") }
    var aggregateText: String { text }
    var configurationID: UUID { plan.configuration.id }
    var sourceRevisionID: UUID { plan.sourceRevisionID }
    var sourceSHA256: String { plan.sourceSHA256 }
    var mode: DictationOutputMode { plan.mode }
}

enum LongDictationTransformService {
    static let maximumSourceUTF8 = 8_000_000
    static let maximumChunks = 1_024
    static let maximumOutputUTF8 = 1_024 * 1_024
    static let maximumGeneratedTokens = maximumChunks * (DictationTransformPolicy.maxGeneratedTokens - 1)
    static let defaultChunkUTF8Limit = 8_192

    /// Only independent per-section previews are supported. Translating or email-formatting
    /// isolated sections would lose cross-section context (pronouns, terminology, paragraph
    /// flow) and is unevaluated, so those modes are rejected before any planning or inference.
    static func supports(_ mode: DictationOutputMode) -> Bool {
        switch mode {
        case .summarize, .organize: true
        case .verbatim, .clean, .email, .translateEnglish, .translateGerman: false
        }
    }

    /// Planning is complete before any inference starts. Every source byte belongs
    /// to exactly one range, including whitespace and the final short section.
    static func plan(source: DictationTextRevision, mode: DictationOutputMode,
                     configuration: ProcessingConfiguration,
                     context: DictationContextSnapshot? = nil,
                     chunkUTF8Limit: Int = defaultChunkUTF8Limit) throws -> LongDictationTransformPlan {
        try makePlan(source: source, mode: mode, configuration: configuration, context: context,
            chunkUTF8Limit: chunkUTF8Limit, requiringCurrentModel: true)
    }

    private static func makePlan(source: DictationTextRevision, mode: DictationOutputMode,
                                 configuration: ProcessingConfiguration,
                                 context: DictationContextSnapshot?, chunkUTF8Limit: Int,
                                 requiringCurrentModel: Bool,
                                 preferSentenceBoundaries: Bool = true) throws -> LongDictationTransformPlan {
        guard supports(mode) else { throw LongDictationTransformError.unsupportedMode }
        guard (1...DictationTransformPolicy.maxSourceUTF8).contains(chunkUTF8Limit) else {
            throw LongDictationTransformError.invalidBounds
        }
        guard source.text.utf8.count <= maximumSourceUTF8, source.rawText.utf8.count <= maximumSourceUTF8,
              source.sourceTranscriptIDs.count <= 65_536,
              Set(source.sourceTranscriptIDs).count == source.sourceTranscriptIDs.count,
              !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.text.utf8.contains(0), source.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LongDictationTransformError.invalidSource
        }
        guard context == nil else { throw LongDictationTransformError.unsupportedContext }
        guard (!requiringCurrentModel || configuration.modelID == ModelCatalog.primaryText.id),
              !configuration.modelID.isEmpty, configuration.modelID.utf8.count <= 256,
              configuration.revision.utf8.count <= 4096, configuration.runtime.utf8.count <= 4096,
              configuration.quantization.utf8.count <= 4096, configuration.audioWindowSeconds.isFinite,
              configuration.audioWindowSeconds > 0,
              configuration.artifactHashes.count <= 256,
              configuration.artifactHashes.allSatisfy({ $0.key.utf8.count <= 1024 && DictationTransformPolicy.hasValidDigestFormat($0.value) }),
              !configuration.thinking,
              (1...4096).contains(configuration.inputLimit),
              (2...DictationTransformPolicy.maxGeneratedTokens).contains(configuration.outputLimit) else {
            throw LongDictationTransformError.invalidResult
        }
        let text = source.text
        var chunks: [LongDictationTransformPlan.Chunk] = []
        var chunkStart = text.startIndex
        var chunkStartByte = 0
        var currentByte = 0
        var lastBoundary: (index: String.Index, byte: Int)?
        var lastSentenceBoundary: (index: String.Index, byte: Int)?
        var lastNonWhitespace: Character?
        var cursor = text.startIndex

        func appendChunk(through end: String.Index, byte: Int) throws {
            let substring = text[chunkStart..<end]
            guard byte > chunkStartByte, byte - chunkStartByte <= chunkUTF8Limit,
                  substring.contains(where: { !$0.isWhitespace }) else {
                throw LongDictationTransformError.oversizedUnit
            }
            guard chunks.count < maximumChunks else { throw LongDictationTransformError.tooManyChunks }
            let value = String(substring)
            chunks.append(.init(index: chunks.count, startUTF8: chunkStartByte, endUTF8: byte,
                sourceSHA256: DictationTransformPolicy.sourceDigest(value)))
        }

        while cursor < text.endIndex {
            let character = text[cursor]
            let next = text.index(after: cursor)
            let count = text[cursor..<next].utf8.count
            guard count <= chunkUTF8Limit else { throw LongDictationTransformError.oversizedUnit }
            if currentByte - chunkStartByte + count > chunkUTF8Limit {
                // A word ending exactly at the byte limit can break before its
                // following separator without splitting either word or grapheme.
                let sentence = lastSentenceBoundary.flatMap { candidate in
                    candidate.byte - chunkStartByte >= chunkUTF8Limit / 2 &&
                        currentByte - candidate.byte + count <= chunkUTF8Limit ? candidate : nil
                }
                let boundary = (preferSentenceBoundaries ? sentence : nil) ??
                    lastBoundary ?? (character.isWhitespace ? (cursor, currentByte) : nil)
                guard let boundary, boundary.byte > chunkStartByte else { throw LongDictationTransformError.oversizedUnit }
                try appendChunk(through: boundary.index, byte: boundary.byte)
                chunkStart = boundary.index
                chunkStartByte = boundary.byte
                if let boundary = lastBoundary, boundary.byte <= chunkStartByte { lastBoundary = nil }
                lastSentenceBoundary = nil
                guard currentByte - chunkStartByte + count <= chunkUTF8Limit else {
                    throw LongDictationTransformError.oversizedUnit
                }
            }
            currentByte += count
            if character.isWhitespace {
                lastBoundary = (next, currentByte)
                if let lastNonWhitespace, ".!?".contains(lastNonWhitespace) {
                    lastSentenceBoundary = (next, currentByte)
                }
            } else { lastNonWhitespace = character }
            cursor = next
        }
        if chunkStart < text.endIndex { try appendChunk(through: text.endIndex, byte: currentByte) }
        guard !chunks.isEmpty, chunks.first?.startUTF8 == 0, chunks.last?.endUTF8 == text.utf8.count else {
            throw LongDictationTransformError.invalidBounds
        }
        return LongDictationTransformPlan(sourceRevisionID: source.id,
            sourceSHA256: DictationTransformPolicy.sourceDigest(text),
            sourceRawSHA256: DictationTransformPolicy.sourceDigest(source.rawText),
            sourceTranscriptIDs: source.sourceTranscriptIDs, sourceCreatedAt: source.createdAt,
            sourceByteCount: currentByte,
            mode: mode, languagePolicy: .mixedEnglishGerman, configuration: configuration,
            contextSHA256: context?.digest, chunkUTF8Limit: chunkUTF8Limit, chunks: chunks)
    }

    /// Sequential, bounded and cancellable. There is no automatic delivery or source
    /// mutation here. The caller must keep its normal stale-source and explicit Apply
    /// checks around publication of this complete result.
    static func run(source: DictationTextRevision, mode: DictationOutputMode,
                    configuration: ProcessingConfiguration,
                    context: DictationContextSnapshot? = nil,
                    chunkUTF8Limit: Int = defaultChunkUTF8Limit,
                    onProgress: (@Sendable (Int, Int) async -> Void)? = nil,
                    transform: @Sendable (DictationTransformRequest) async throws -> DictationTransformResult) async throws -> LongDictationTransformResult {
        try Task.checkCancellation()
        let plan = try plan(source: source, mode: mode, configuration: configuration,
            context: context, chunkUTF8Limit: chunkUTF8Limit)
        let bytes = Array(source.text.utf8)
        var outputs: [DictationTransformResult] = []
        outputs.reserveCapacity(plan.chunks.count)
        var outputBytes = 0
        var tokens = 0
        for chunk in plan.chunks {
            try Task.checkCancellation()
            let sourceText = try sourceText(for: chunk, bytes: bytes)
            let request = DictationTransformRequest(sourceRevisionID: source.id,
                sourceSHA256: chunk.sourceSHA256, mode: mode, languagePolicy: plan.languagePolicy,
                sourceText: sourceText, configuration: configuration, context: context)
            try LocalInference.validateTransformRequest(request)
            let result = try await transform(request)
            try Task.checkCancellation()
            try validateChunk(result, request: request)
            let separators = outputs.isEmpty ? 0 : 2
            guard result.text.utf8.count <= maximumOutputUTF8 - outputBytes - separators else {
                throw LongDictationTransformError.outputLimit
            }
            outputBytes += result.text.utf8.count + separators
            tokens += result.generatedTokens
            guard tokens <= maximumGeneratedTokens else { throw LongDictationTransformError.outputLimit }
            outputs.append(result)
            await onProgress?(outputs.count, plan.chunks.count)
            try Task.checkCancellation()
        }
        let result = LongDictationTransformResult(plan: plan, outputs: outputs, generatedTokens: tokens)
        try validate(result, source: source, mode: mode, configuration: configuration, context: context)
        try Task.checkCancellation()
        return result
    }

    /// Rebuild source ranges and verify every individual policy and provenance before
    /// publication. No aggregate token count is passed off as one model generation.
    static func validate(_ result: LongDictationTransformResult, source: DictationTextRevision,
                         mode: DictationOutputMode? = nil, configuration: ProcessingConfiguration,
                         context: DictationContextSnapshot? = nil) throws {
        guard mode == nil || mode == result.plan.mode else { throw LongDictationTransformError.invalidResult }
        try validateHistorical(result, source: source)
        let expected = try plan(source: source, mode: result.plan.mode, configuration: configuration,
            context: context, chunkUTF8Limit: result.plan.chunkUTF8Limit)
        guard result.plan == expected,
              result.plan.sourceSHA256 == DictationTransformPolicy.sourceDigest(source.text),
              result.plan.sourceRevisionID == source.id else { throw LongDictationTransformError.staleSource }
        guard result.outputs.count == expected.chunks.count, !result.outputs.isEmpty,
              Set(result.outputs.map(\.jobID)).count == result.outputs.count else {
            throw LongDictationTransformError.invalidResult
        }
        let bytes = Array(source.text.utf8)
        var totalBytes = 0
        var totalTokens = 0
        for (chunk, output) in zip(expected.chunks, result.outputs) {
            let sourceText = try sourceText(for: chunk, bytes: bytes)
            let request = DictationTransformRequest(jobID: output.jobID, sourceRevisionID: source.id,
                sourceSHA256: chunk.sourceSHA256, mode: expected.mode, languagePolicy: expected.languagePolicy,
                sourceText: sourceText, configuration: configuration, context: context)
            try validateChunk(output, request: request)
            totalBytes += output.text.utf8.count
            totalTokens += output.generatedTokens
        }
        totalBytes += max(0, result.outputs.count - 1) * 2
        guard result.generatedTokens == totalTokens, totalTokens <= maximumGeneratedTokens,
              totalBytes <= maximumOutputUTF8 else { throw LongDictationTransformError.outputLimit }
    }

    /// At-rest validation keeps old model receipts and prompt-template provenance
    /// readable after an upgrade. It proves bounded structure and exact source
    /// lineage, not that historical model text is semantically correct.
    static func validateHistorical(_ result: LongDictationTransformResult,
                                   source: DictationTextRevision) throws {
        guard (1...2).contains(result.plan.version), result.plan.contextSHA256 == nil else {
            throw LongDictationTransformError.invalidResult
        }
        var expected = try makePlan(source: source, mode: result.plan.mode,
            configuration: result.plan.configuration, context: nil,
            chunkUTF8Limit: result.plan.chunkUTF8Limit, requiringCurrentModel: false,
            preferSentenceBoundaries: result.plan.version >= 2)
        expected.version = result.plan.version
        guard result.plan == expected else { throw LongDictationTransformError.staleSource }
        guard !result.outputs.isEmpty, result.outputs.count == expected.chunks.count,
              Set(result.outputs.map(\.jobID)).count == result.outputs.count else {
            throw LongDictationTransformError.invalidResult
        }
        var bytes = max(0, result.outputs.count - 1) * 2
        var tokens = 0
        for (chunk, output) in zip(expected.chunks, result.outputs) {
            guard output.sourceRevisionID == expected.sourceRevisionID,
                  output.sourceSHA256 == chunk.sourceSHA256, output.mode == expected.mode,
                  output.configurationID == expected.configuration.id,
                  output.promptTemplateVersion > 0,
                  DictationTransformPolicy.hasValidDigestFormat(output.promptTemplateSHA256),
                  output.contextSHA256 == nil,
                  output.generatedTokens > 0,
                  output.generatedTokens < min(expected.configuration.outputLimit, DictationTransformPolicy.maxGeneratedTokens),
                  !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  output.text.utf8.count <= DictationTransformPolicy.maxOutputUTF8,
                  !output.text.utf8.contains(0) else { throw LongDictationTransformError.invalidResult }
            bytes += output.text.utf8.count
            tokens += output.generatedTokens
        }
        guard bytes <= maximumOutputUTF8, tokens <= maximumGeneratedTokens,
              result.generatedTokens == tokens else { throw LongDictationTransformError.outputLimit }
    }

    static func sourceText(for chunk: LongDictationTransformPlan.Chunk,
                           in source: DictationTextRevision) throws -> String {
        try sourceText(for: chunk, bytes: Array(source.text.utf8))
    }

    private static func sourceText(for chunk: LongDictationTransformPlan.Chunk,
                                   bytes: [UInt8]) throws -> String {
        guard chunk.startUTF8 >= 0, chunk.endUTF8 > chunk.startUTF8,
              chunk.endUTF8 <= bytes.count else { throw LongDictationTransformError.invalidBounds }
        let value = String(decoding: bytes[chunk.startUTF8..<chunk.endUTF8], as: UTF8.self)
        guard value.utf8.elementsEqual(bytes[chunk.startUTF8..<chunk.endUTF8]),
              DictationTransformPolicy.sourceDigest(value) == chunk.sourceSHA256 else {
            throw LongDictationTransformError.staleSource
        }
        return value
    }

    private static func validateChunk(_ output: DictationTransformResult,
                                      request: DictationTransformRequest) throws {
        try LocalInference.validateTransformRequest(request)
        try LocalInference.validateTransformReply(output, request: request)
        guard output.generatedTokens > 0,
              output.generatedTokens < min(request.configuration.outputLimit, DictationTransformPolicy.maxGeneratedTokens) else {
            throw LongDictationTransformError.invalidResult
        }
    }
}
