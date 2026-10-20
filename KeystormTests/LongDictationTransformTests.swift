import Foundation
import Testing
@testable import Keystorm

struct LongDictationTransformTests {
    @Test("Mixed English/German plans preserve exact bytes, complete graphemes and the final tail")
    func unicodeCoverageAndDeterminism() throws {
        let text = String(repeating: "Bitte Müller, don't upload Größe 👩🏽‍💻 e\u{0301} /tmp/Überblick.swift.\n", count: 7) + "FINAL ÄÖÜ ß tail."
        let source = revision(text)
        let configuration = configuration()
        let first = try LongDictationTransformService.plan(source: source, mode: .organize,
            configuration: configuration, chunkUTF8Limit: 96)
        let second = try LongDictationTransformService.plan(source: source, mode: .organize,
            configuration: configuration, chunkUTF8Limit: 96)
        #expect(first == second)
        #expect(first.chunks.count > 1)
        var bytes: [UInt8] = []
        var boundaries: Set<Int> = [0]
        var offset = 0
        for character in text {
            offset += String(character).utf8.count
            boundaries.insert(offset)
        }
        for (index, chunk) in first.chunks.enumerated() {
            #expect(chunk.index == index)
            #expect(chunk.startUTF8 == bytes.count)
            #expect(chunk.sourceByteCount <= 96)
            #expect(boundaries.contains(chunk.startUTF8) && boundaries.contains(chunk.endUTF8))
            let part = try LongDictationTransformService.sourceText(for: chunk, in: source)
            #expect(DictationTransformPolicy.sourceDigest(part) == chunk.sourceSHA256)
            bytes.append(contentsOf: part.utf8)
        }
        #expect(bytes.elementsEqual(text.utf8))
        #expect(first.chunks.last?.endUTF8 == text.utf8.count)
        #expect(first.sourceRawSHA256 == DictationTransformPolicy.sourceDigest(source.rawText))
        #expect(first.sourceTranscriptIDs == source.sourceTranscriptIDs)
    }

    @Test("Long plans prefer complete sentences and retain exact coverage for a sentence exceeding one section")
    func sentenceBoundaryAndLongSentenceFallback() throws {
        let text = String(repeating: "Send die Rechnung to Müller. Keep 42 Dateien local. ", count: 30)
        let source = revision(text)
        let plan = try LongDictationTransformService.plan(source: source, mode: .summarize,
            configuration: configuration(), chunkUTF8Limit: 96)
        #expect(plan.version == 2)
        let pieces = try plan.chunks.map { try LongDictationTransformService.sourceText(for: $0, in: source) }
        #expect(pieces.joined().utf8.elementsEqual(text.utf8))
        #expect(pieces.dropLast().allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).last == "."
        })
        let long = revision(String(repeating: "Müller Dateien ", count: 50) + "tail.")
        let fallback = try LongDictationTransformService.plan(source: long, mode: .summarize,
            configuration: configuration(), chunkUTF8Limit: 96)
        let parts = try fallback.chunks.map { try LongDictationTransformService.sourceText(for: $0, in: long) }
        #expect(parts.joined().utf8.elementsEqual(long.text.utf8))
        #expect(parts.allSatisfy { $0.utf8.count <= 96 })
    }

    @Test("Sentence preferences preserve carried whitespace and legacy word-boundary receipts")
    func carriedBoundaryAndLegacyPlanCompatibility() throws {
        let text = "First thing. x abcdefghijklmnopqrs next"
        let source = revision(text)
        let fresh = try LongDictationTransformService.plan(source: source, mode: .summarize,
            configuration: configuration(), chunkUTF8Limit: 20)
        let pieces = try fresh.chunks.map { try LongDictationTransformService.sourceText(for: $0, in: source) }
        #expect(pieces.joined().utf8.elementsEqual(text.utf8))
        #expect(pieces.allSatisfy { $0.utf8.count <= 20 })

        let legacyParts = ["First complete sentence. second ", "third fourth."]
        let legacySource = revision(legacyParts.joined())
        var legacy = try LongDictationTransformService.plan(source: legacySource, mode: .summarize,
            configuration: configuration(), chunkUTF8Limit: 32)
        #expect(try LongDictationTransformService.sourceText(for: legacy.chunks[0], in: legacySource) != legacyParts[0])
        legacy.version = 1
        var offset = 0
        legacy.chunks = legacyParts.enumerated().map { index, part in
            let start = offset
            offset += part.utf8.count
            return .init(index: index, startUTF8: start, endUTF8: offset,
                sourceSHA256: DictationTransformPolicy.sourceDigest(part))
        }
        let outputs = zip(legacy.chunks, legacyParts).map { chunk, part in
            DictationTransformResult(jobID: UUID(), sourceRevisionID: legacySource.id,
                sourceSHA256: chunk.sourceSHA256, mode: .summarize, text: part, generatedTokens: 2,
                configurationID: legacy.configuration.id,
                promptTemplateVersion: DictationTransformPolicy.templateVersion,
                promptTemplateSHA256: DictationTransformPolicy.promptTemplateSHA256(for: .summarize))
        }
        let oldReceipt = LongDictationTransformResult(plan: legacy, outputs: outputs, generatedTokens: 4)
        try LongDictationTransformService.validateHistorical(oldReceipt, source: legacySource)
        #expect(throws: (any Error).self) {
            try LongDictationTransformService.validate(oldReceipt, source: legacySource, configuration: legacy.configuration)
        }
    }

    @Test("Oversized source, literal, grapheme, spacing and chunk count fail before inference")
    func planningBounds() throws {
        let configuration = configuration()
        let cases = [
            String(repeating: "x", count: LongDictationTransformService.maximumSourceUTF8 + 1),
            "https://example.test/" + String(repeating: "a", count: 9_000),
            "a" + String(repeating: "\u{0301}", count: 9_000),
            "hello" + String(repeating: " ", count: 25_000) + "tail",
            " \n "
        ]
        for text in cases {
            #expect(throws: (any Error).self) {
                try LongDictationTransformService.plan(source: revision(text), mode: .summarize,
                    configuration: configuration)
            }
        }
        #expect(throws: LongDictationTransformError.tooManyChunks) {
            try LongDictationTransformService.plan(source: revision(String(repeating: "one ", count: 1_025)),
                mode: .summarize, configuration: configuration, chunkUTF8Limit: 4)
        }
        #expect(throws: LongDictationTransformError.unsupportedMode) {
            try LongDictationTransformService.plan(source: revision("Keep die Rechnung local."), mode: .clean,
                configuration: configuration)
        }
        #expect(throws: LongDictationTransformError.unsupportedContext) {
            try LongDictationTransformService.plan(source: revision("Keep die Rechnung local."), mode: .summarize,
                configuration: configuration, context: DictationContextSnapshot(profile: .email, availability: .application))
        }
    }

    @Test("Long previews call the existing policy sequentially and retain range provenance",
          arguments: [DictationOutputMode.summarize, .organize])
    func sequentialBoundedPreview(mode: DictationOutputMode) async throws {
        let source = revision(String(repeating: "Bitte keep 42 Dateien local, not online. ", count: 19) + "Final München tail.")
        let engine = LongTransformRecorder()
        let result = try await LongDictationTransformService.run(source: source, mode: mode,
            configuration: configuration(), chunkUTF8Limit: 96) { request in
                try await engine.transform(request)
            }
        try LongDictationTransformService.validate(result, source: source, mode: mode,
            configuration: result.plan.configuration)
        let requests = await engine.requests
        #expect(requests.count == result.plan.chunks.count && requests.count > 1)
        #expect(await engine.maximumConcurrent == 1)
        #expect(result.outputs.count == requests.count)
        #expect(result.generatedTokens == requests.count * 16)
        #expect(result.text == result.outputs.map(\.text).joined(separator: "\n\n"))
        #expect(result.outputs.last?.text.contains("tail.") == true)
        #expect(requests.allSatisfy { $0.sourceRevisionID == source.id && $0.mode == mode })
        #expect(requests.flatMap { Array($0.sourceText.utf8) }.elementsEqual(source.text.utf8))
        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(LongDictationTransformResult.self, from: encoded)
        #expect(decoded == result)
        try LongDictationTransformService.validateHistorical(decoded, source: source)
    }

    @Test("Cancellation before planning never invokes a model")
    func cancelledBeforeFirstChunk() async throws {
        let engine = LongTransformRecorder()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LongDictationTransformService.run(source: revision("Bitte keep die Rechnung local."),
                mode: .summarize, configuration: configuration()) { request in
                    try await engine.transform(request)
                }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await engine.requests.isEmpty)
    }

    @Test("A noncooperative late response after cancellation cannot publish a partial long preview")
    func cancellationAfterNoncooperativeReply() async throws {
        let gate = LongTransformGate()
        let engine = LongTransformRecorder()
        let source = revision(String(repeating: "Keep die Rechnung local, not online. ", count: 10))
        let task = Task {
            try await LongDictationTransformService.run(source: source, mode: .organize,
                configuration: configuration(), chunkUTF8Limit: 64) { request in
                    await gate.enterAndWait()
                    return try await engine.transform(request)
                }
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await engine.requests.count == 1)
    }

    @Test("Cancelling between sections prevents the next request")
    func cancellationBetweenChunks() async throws {
        let engine = LongTransformRecorder()
        let task = Task {
            try await LongDictationTransformService.run(
                source: revision(String(repeating: "Bitte keep the files local. ", count: 20)),
                mode: .summarize, configuration: configuration(), chunkUTF8Limit: 64,
                onProgress: { _, _ in withUnsafeCurrentTask { $0?.cancel() } }) { request in
                    try await engine.transform(request)
                }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await engine.requests.count == 1)
    }

    @Test("Wrong jobs, sources, modes, configuration, template, tokens and invented words reject the entire preview",
          arguments: LongResultTamper.allCases)
    func tamperedChunkIsRejected(tamper: LongResultTamper) async throws {
        let source = revision(String(repeating: "Bitte keep 42 Dateien local, not online. ", count: 5))
        await #expect(throws: (any Error).self) {
            try await LongDictationTransformService.run(source: source, mode: .organize,
                configuration: configuration(), chunkUTF8Limit: 96) { request in
                    var result = validResult(request)
                    switch tamper {
                    case .job: result.jobID = UUID()
                    case .sourceID: result.sourceRevisionID = UUID()
                    case .sourceHash: result.sourceSHA256 = String(repeating: "0", count: 64)
                    case .mode: result.mode = .summarize
                    case .configuration: result.configurationID = UUID()
                    case .template: result.promptTemplateSHA256 = String(repeating: "a", count: 64)
                    case .tokens: result.generatedTokens = request.configuration.outputLimit
                    case .inventedWord: result.text += " BANANA"
                    }
                    return result
                }
        }
    }

    @Test("Historical receipts survive a prompt/model upgrade while fresh application still checks current settings")
    func historicalReceiptsRemainReadable() async throws {
        let source = revision(String(repeating: "Keep die Rechnung local. ", count: 8))
        var result = try await LongDictationTransformService.run(source: source, mode: .summarize,
            configuration: configuration(), chunkUTF8Limit: 64) { validResult($0) }
        result.plan.configuration.modelID = "older-local-model"
        result.plan.configuration.revision = "historical-revision"
        for index in result.outputs.indices {
            result.outputs[index].promptTemplateVersion = 1
            result.outputs[index].promptTemplateSHA256 = String(repeating: "b", count: 64)
        }
        try LongDictationTransformService.validateHistorical(result, source: source)
        #expect(throws: (any Error).self) {
            try LongDictationTransformService.validate(result, source: source,
                configuration: result.plan.configuration)
        }
    }

    @Test("Historical gap, tail, source, configuration, token and hash forgeries fail")
    func historicalForgeryRejected() async throws {
        let source = revision(String(repeating: "Keep die Rechnung local. ", count: 8))
        let result = try await LongDictationTransformService.run(source: source, mode: .organize,
            configuration: configuration(), chunkUTF8Limit: 64) { validResult($0) }
        var forgeries: [LongDictationTransformResult] = []
        var copy = result
        copy.plan.chunks.removeLast()
        copy.outputs.removeLast()
        copy.generatedTokens = copy.outputs.reduce(0) { $0 + $1.generatedTokens }
        forgeries.append(copy)
        copy = result; copy.plan.chunks[1].startUTF8 += 1; forgeries.append(copy)
        copy = result; copy.plan.chunks[0].sourceSHA256 = String(repeating: "0", count: 64); forgeries.append(copy)
        copy = result; copy.plan.sourceSHA256 = String(repeating: "0", count: 64); forgeries.append(copy)
        copy = result; copy.plan.sourceRawSHA256 = String(repeating: "0", count: 64); forgeries.append(copy)
        copy = result; copy.plan.sourceTranscriptIDs = [UUID()]; forgeries.append(copy)
        copy = result; copy.outputs[0].configurationID = UUID(); forgeries.append(copy)
        copy = result; copy.outputs[0].promptTemplateSHA256 = "malformed"; forgeries.append(copy)
        copy = result; copy.outputs[0].generatedTokens = 0; forgeries.append(copy)
        copy = result; copy.generatedTokens += 1; forgeries.append(copy)
        copy = result; copy.outputs[1].jobID = copy.outputs[0].jobID; forgeries.append(copy)
        copy = result; copy.plan.version = 3; forgeries.append(copy)
        for forgery in forgeries {
            #expect(throws: (any Error).self) {
                try LongDictationTransformService.validateHistorical(forgery, source: source)
            }
        }
        var edited = source
        edited.text += " New tail."
        #expect(throws: (any Error).self) {
            try LongDictationTransformService.validateHistorical(result, source: edited)
        }
        edited = source; edited.rawText += " Changed original."
        #expect(throws: (any Error).self) {
            try LongDictationTransformService.validateHistorical(result, source: edited)
        }
        edited = source; edited.id = UUID()
        #expect(throws: (any Error).self) {
            try LongDictationTransformService.validateHistorical(result, source: edited)
        }
    }

    @Test("Aggregate output over one MiB fails without returning a truncated preview", .timeLimit(.minutes(2)))
    func aggregateOutputBound() async throws {
        let source = revision(String(repeating: "word ", count: 210_000))
        await #expect(throws: LongDictationTransformError.outputLimit) {
            try await LongDictationTransformService.run(source: source, mode: .summarize,
                configuration: configuration()) { validResult($0) }
        }
    }
}

enum LongResultTamper: CaseIterable, Sendable {
    case job, sourceID, sourceHash, mode, configuration, template, tokens, inventedWord
}

private actor LongTransformRecorder {
    private(set) var requests: [DictationTransformRequest] = []
    private var active = 0
    private(set) var maximumConcurrent = 0

    func transform(_ request: DictationTransformRequest) async throws -> DictationTransformResult {
        requests.append(request)
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        defer { active -= 1 }
        await Task.yield()
        return validResult(request)
    }
}

private actor LongTransformGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func enterAndWait() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters = []
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private func revision(_ text: String) -> DictationTextRevision {
    DictationTextRevision(rawText: text, text: text, sourceTranscriptIDs: [UUID()])
}

private func configuration() -> ProcessingConfiguration {
    ProcessingConfiguration(modelID: ModelCatalog.primaryText.id, revision: ModelCatalog.primaryText.revision ?? "",
        runtime: "Long-transform fixture", quantization: "4-bit", inputLimit: 4096, outputLimit: 2048)
}

private func validResult(_ request: DictationTransformRequest) -> DictationTransformResult {
    DictationTransformResult(jobID: request.jobID, sourceRevisionID: request.sourceRevisionID,
        sourceSHA256: request.sourceSHA256, mode: request.mode,
        text: request.mode == .organize ? "- " + request.sourceText : request.sourceText,
        generatedTokens: 16, configurationID: request.configuration.id,
        promptTemplateVersion: DictationTransformPolicy.templateVersion,
        promptTemplateSHA256: DictationTransformPolicy.promptTemplateSHA256(for: request.mode, context: request.context),
        contextSHA256: request.context?.digest)
}
