import AVFAudio
import Foundation
import Observation

struct ReadbackVoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let language: String

    /// Prefer an installed natural voice over the alphabetically first novelty voice.
    static func preferredIdentifier(in voices: [ReadbackVoice]) -> String? {
        let samantha = "com.apple.voice.compact.en-US.Samantha"
        let alex = "com.apple.speech.synthesis.voice.Alex"
        return voices.first(where: { $0.id == samantha })?.id
            ?? voices.first(where: { $0.language == "en-US" && $0.id.hasPrefix("com.apple.voice.") })?.id
            ?? voices.first(where: { $0.id == alex })?.id
            ?? voices.first(where: { $0.id.hasPrefix("com.apple.voice.") })?.id
            ?? voices.first(where: { $0.language == "en-US" })?.id
            ?? voices.first?.id
    }
}

struct ReadbackChunk: Equatable, Sendable {
    let text: String
    let utf16Offset: Int
}

/// Bounded utterances preserve offsets into the exact section text, including Unicode and whitespace.
enum ReadbackChunker {
    static func chunks(_ text: String, limit: Int = 2_048) -> [ReadbackChunk] {
        guard limit >= 2, !text.isEmpty else { return [] }
        var result: [ReadbackChunk] = []
        var start = text.startIndex
        var offset = 0
        while start < text.endIndex {
            var end = start
            var units = 0
            var boundary: String.Index?
            while end < text.endIndex {
                let next = text.index(after: end)
                let size = text[end..<next].utf16.count
                guard units + size <= limit || end == start else { break }
                units += size
                if text[end].isWhitespace { boundary = next }
                end = next
            }
            if end < text.endIndex, let boundary, text[start..<boundary].utf16.count >= limit / 2 { end = boundary }
            let value = String(text[start..<end])
            result.append(.init(text: value, utf16Offset: offset))
            offset += value.utf16.count
            start = end
        }
        return result
    }

    static func globalRange(_ local: NSRange, chunk: ReadbackChunk) -> NSRange? {
        guard local.location != NSNotFound, local.location >= 0, local.length >= 0,
              local.location <= chunk.text.utf16.count,
              local.length <= chunk.text.utf16.count - local.location else { return nil }
        let units = chunk.text.utf16
        func isScalarBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < units.count else { return true }
            let index = units.index(units.startIndex, offsetBy: offset)
            let before = units[units.index(before: index)]
            let after = units[index]
            return !(0xD800...0xDBFF).contains(before) || !(0xDC00...0xDFFF).contains(after)
        }
        guard isScalarBoundary(local.location), isScalarBoundary(local.location + local.length) else { return nil }
        return NSRange(location: chunk.utf16Offset + local.location, length: local.length)
    }
}

private enum ReadbackEvent: Sendable {
    case started(ObjectIdentifier), paused(ObjectIdentifier), continued(ObjectIdentifier)
    case range(ObjectIdentifier, NSRange), finished(ObjectIdentifier), cancelled(ObjectIdentifier)
    var utteranceID: ObjectIdentifier {
        switch self {
        case .started(let id), .paused(let id), .continued(let id), .finished(let id), .cancelled(let id): id
        case .range(let id, _): id
        }
    }
}

private final class ReadbackDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private weak var registeredUtterance: AVSpeechUtterance?
    private var token = 0
    let deliver: @Sendable (ReadbackEvent, Int) -> Void
    init(deliver: @escaping @Sendable (ReadbackEvent, Int) -> Void) { self.deliver = deliver }
    func register(_ utterance: AVSpeechUtterance, token: Int) {
        lock.lock(); registeredUtterance = utterance; self.token = token; lock.unlock()
    }
    private func send(_ event: ReadbackEvent) {
        lock.lock()
        let valid = registeredUtterance.map { ObjectIdentifier($0) == event.utteranceID } == true
        let currentToken = token
        lock.unlock()
        if valid { deliver(event, currentToken) }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { send(.started(ObjectIdentifier(utterance))) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) { send(.paused(ObjectIdentifier(utterance))) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) { send(.continued(ObjectIdentifier(utterance))) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { send(.finished(ObjectIdentifier(utterance))) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { send(.cancelled(ObjectIdentifier(utterance))) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        send(.range(ObjectIdentifier(utterance), range))
    }
}

@MainActor @Observable
final class BriefReadback {
    private(set) var isSpeaking = false
    private(set) var isPaused = false
    private(set) var sectionID: String?
    private(set) var documentRevisionID: UUID?
    private(set) var currentRange: NSRange?
    private(set) var availableVoices: [ReadbackVoice] = []
    private(set) var voiceIdentifier: String?
    private(set) var error: String?
    var rate: Double {
        didSet {
            let bounded = min(0.65, max(0.3, rate.isFinite ? rate : 0.5))
            if bounded != rate { rate = bounded }
            defaults.set(bounded, forKey: Self.rateKey)
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var delegate: ReadbackDelegate?
    @ObservationIgnored private var utterance: AVSpeechUtterance?
    @ObservationIgnored private var chunks: [ReadbackChunk] = []
    @ObservationIgnored private var chunkIndex = 0
    @ObservationIgnored private var waitingForNextChunk = false
    @ObservationIgnored private var originalText = ""
    @ObservationIgnored private var generation: UInt64 = 0
    private static let voiceKey = "Keystorm.readback.voice.v1"
    private static let rateKey = "Keystorm.readback.rate.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rate = min(0.65, max(0.3, defaults.object(forKey: Self.rateKey) == nil ? 0.5 : defaults.double(forKey: Self.rateKey)))
        voiceIdentifier = defaults.string(forKey: Self.voiceKey)
    }

    isolated deinit {
        synthesizer?.delegate = nil
        _ = synthesizer?.stopSpeaking(at: .immediate)
    }

    /// Queries voices already exposed by the device. No voice/model download is requested.
    func refreshVoices() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && $0.identifier.hasPrefix("com.apple.") }
            .sorted { ($0.name, $0.identifier) < ($1.name, $1.identifier) }
        availableVoices = voices.map { .init(id: $0.identifier, name: $0.name, language: $0.language) }
        if voiceIdentifier == nil, let preferred = ReadbackVoice.preferredIdentifier(in: availableVoices) {
            voiceIdentifier = preferred
            defaults.set(preferred, forKey: Self.voiceKey)
        }
    }

    func setVoiceIdentifier(_ identifier: String) {
        guard availableVoices.contains(where: { $0.id == identifier }) else { error = "That installed English voice is unavailable."; return }
        stop()
        voiceIdentifier = identifier
        defaults.set(identifier, forKey: Self.voiceKey)
        error = nil
    }

    func read(text: String, sectionID: String, documentRevisionID: UUID) {
        stop()
        error = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "The selected section is empty."; return }
        guard text.utf8.count <= 1_048_576 else { error = "Select a smaller section for read-back."; return }
        if availableVoices.isEmpty { refreshVoices() }
        guard let voiceIdentifier, availableVoices.contains(where: { $0.id == voiceIdentifier }),
              AVSpeechSynthesisVoice(identifier: voiceIdentifier) != nil else {
            error = "Choose an installed English voice in Read-back settings."; return
        }
        self.sectionID = sectionID
        self.documentRevisionID = documentRevisionID
        originalText = text
        chunks = ReadbackChunker.chunks(text)
        chunkIndex = 0
        let currentGeneration = generation
        let newDelegate = ReadbackDelegate { [weak self] event, chunkToken in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration, self.chunkIndex == chunkToken else { return }
                self.receive(event)
            }
        }
        let newSynthesizer = AVSpeechSynthesizer()
        newSynthesizer.delegate = newDelegate
        delegate = newDelegate
        synthesizer = newSynthesizer
        isSpeaking = true
        speakNext()
    }

    func togglePause() {
        guard let synthesizer, isSpeaking else { return }
        if isPaused {
            if waitingForNextChunk {
                waitingForNextChunk = false; isPaused = false; speakNext()
            } else if synthesizer.continueSpeaking() { isPaused = false }
        } else if synthesizer.pauseSpeaking(at: .word) { isPaused = true }
    }

    func pause() {
        guard !isPaused, isSpeaking, let synthesizer else { return }
        if synthesizer.pauseSpeaking(at: .word) { isPaused = true }
    }

    func stop() {
        generation &+= 1
        let previous = synthesizer
        // Clear identity before cancellation; delayed callbacks cannot affect a later reading.
        utterance = nil; synthesizer = nil; delegate = nil
        previous?.delegate = nil
        _ = previous?.stopSpeaking(at: .immediate)
        chunks.removeAll(keepingCapacity: false); originalText = ""; chunkIndex = 0; waitingForNextChunk = false
        isSpeaking = false; isPaused = false; currentRange = nil
        sectionID = nil; documentRevisionID = nil
    }

    func validate(sectionID: String?, documentRevisionID: UUID?, text: String) {
        guard isSpeaking else { return }
        if self.sectionID != sectionID || self.documentRevisionID != documentRevisionID || originalText != text { stop() }
    }

    private func speakNext() {
        guard chunkIndex < chunks.count, let synthesizer, let voiceIdentifier,
              let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else { stop(); return }
        let next = AVSpeechUtterance(string: chunks[chunkIndex].text)
        next.voice = voice
        next.rate = Float(rate)
        next.prefersAssistiveTechnologySettings = false
        utterance = next
        delegate?.register(next, token: chunkIndex)
        synthesizer.speak(next)
    }

    private func receive(_ event: ReadbackEvent) {
        guard let utterance, ObjectIdentifier(utterance) == event.utteranceID, chunkIndex < chunks.count else { return }
        switch event {
        case .started: isSpeaking = true
        case .paused: isPaused = true
        case .continued: isPaused = false
        case .range(_, let range): currentRange = ReadbackChunker.globalRange(range, chunk: chunks[chunkIndex])
        case .finished:
            self.utterance = nil
            chunkIndex += 1
            currentRange = nil
            if chunkIndex == chunks.count { stop() }
            else if isPaused { waitingForNextChunk = true }
            else { speakNext() }
        case .cancelled: stop()
        }
    }
}
