import CryptoKit
import Foundation

/// A change observed in a destination app, without any claim about who made it.
/// Whole destination fields and Accessibility objects are deliberately absent.
struct ExternalCorrectionObservation: Equatable, Sendable {
    let originalText: String
    let correctedText: String
    let destination: DictationDestinationDescriptor
    let deliveryID: UUID
    let observedAt: Date
}

enum DictationFieldObservationEvent { case valueChanged, invalidated }

@MainActor
protocol ExternalCorrectionCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol ExternalCorrectionScheduling {
    var now: Date { get }
    func schedule(after seconds: TimeInterval,
                  action: @escaping @MainActor () -> Void) -> any ExternalCorrectionCancellation
}

@MainActor
struct SystemExternalCorrectionScheduler: ExternalCorrectionScheduling {
    var now: Date { Date() }
    func schedule(after seconds: TimeInterval,
                  action: @escaping @MainActor () -> Void) -> any ExternalCorrectionCancellation {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return ExternalCorrectionTaskCancellation(task)
    }
}

@MainActor
private final class ExternalCorrectionTaskCancellation: ExternalCorrectionCancellation {
    private var task: Task<Void, Never>?
    init(_ task: Task<Void, Never>) { self.task = task }
    func cancel() { task?.cancel(); task = nil }
}

/// All text here is ephemeral. Exact outside anchors prevent unrelated edits
/// from being interpreted as corrections to the inserted passage.
@MainActor
struct ExternalCorrectionAnchor {
    static let maximumPassageUTF16 = 8_192
    let originalText: String
    private let prefixUTF16: Int
    private let suffixUTF16: Int
    private let prefixDigest: SHA256.Digest
    private let suffixDigest: SHA256.Digest

    enum Change { case unchanged, corrected(String), invalid }

    init?(fieldText: String, insertedRange: NSRange, originalText: String) {
        guard !originalText.isEmpty,
              originalText.utf16.count <= Self.maximumPassageUTF16,
              fieldText.utf16.count <= DictationDeliveryService.maximumFieldUTF16,
              let range = Self.characterRange(insertedRange, in: fieldText),
              fieldText[range].utf8.elementsEqual(originalText.utf8),
              !CorrectionSensitiveContext.contains(fieldText) else { return nil }
        // Repeated passages cannot establish an unambiguous inserted owner.
        let value = fieldText as NSString
        let first = value.range(of: originalText, options: .literal)
        guard first == insertedRange else { return nil }
        let afterFirst = first.location + 1
        if afterFirst < value.length,
           value.range(of: originalText, options: .literal,
                       range: NSRange(location: afterFirst, length: value.length - afterFirst)).location != NSNotFound {
            return nil
        }
        self.originalText = originalText
        let prefix = fieldText[..<range.lowerBound]
        let suffix = fieldText[range.upperBound...]
        prefixUTF16 = prefix.utf16.count
        suffixUTF16 = suffix.utf16.count
        prefixDigest = SHA256.hash(data: Data(prefix.utf8))
        suffixDigest = SHA256.hash(data: Data(suffix.utf8))
    }

    func change(in fieldText: String) -> Change {
        let count = fieldText.utf16.count
        let start = prefixUTF16
        let suffixCount = suffixUTF16
        guard count <= DictationDeliveryService.maximumFieldUTF16,
              count >= start + suffixCount,
              !CorrectionSensitiveContext.contains(fieldText) else { return .invalid }
        let value = fieldText as NSString
        guard SHA256.hash(data: Data(value.substring(with: NSRange(location: 0, length: start)).utf8)) == prefixDigest,
              SHA256.hash(data: Data(value.substring(with: NSRange(location: count - suffixCount, length: suffixCount)).utf8)) == suffixDigest,
              let range = Self.characterRange(NSRange(location: start, length: count - start - suffixCount), in: fieldText) else {
            return .invalid
        }
        let corrected = String(fieldText[range])
        guard !corrected.isEmpty, corrected.utf16.count <= Self.maximumPassageUTF16 else { return .invalid }
        if corrected.utf8.elementsEqual(originalText.utf8) { return .unchanged }
        // A duplicate resulting passage is ambiguous too; never guess an owner.
        let first = value.range(of: corrected, options: .literal)
        guard first == NSRange(range, in: fieldText) else { return .invalid }
        let afterFirst = first.location + 1
        if afterFirst < value.length,
           value.range(of: corrected, options: .literal,
                       range: NSRange(location: afterFirst, length: value.length - afterFirst)).location != NSNotFound {
            return .invalid
        }
        return .corrected(corrected)
    }

    private static func characterRange(_ range: NSRange, in text: String) -> Range<String.Index>? {
        guard range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count, range.length <= text.utf16.count - range.location,
              let result = Range(range, in: text),
              (result.lowerBound == text.endIndex || text.indices.contains(result.lowerBound)),
              (result.upperBound == text.endIndex || text.indices.contains(result.upperBound)) else { return nil }
        return result
    }
}

/// One event-driven, short-lived observation. Timers only debounce events and
/// expire the lease; they never poll another app.
@MainActor
final class ExternalCorrectionLease {
    static let lifetime: TimeInterval = 30
    static let debounce: TimeInterval = 1
    private(set) var isActive = true
    private var anchor: ExternalCorrectionAnchor?
    private let destination: DictationDestinationDescriptor
    private let deliveryID: UUID
    private let scheduler: any ExternalCorrectionScheduling
    private let expiresAt: Date
    private var isEnabled: (@MainActor () -> Bool)?
    private var read: (@MainActor () -> DictationFieldSnapshot?)?
    private var onObservation: (@MainActor (ExternalCorrectionObservation) -> Void)?
    private var observer: (any ExternalCorrectionCancellation)?
    private var expiry: (any ExternalCorrectionCancellation)?
    private var pendingRead: (any ExternalCorrectionCancellation)?
    private var eventGeneration = 0

    init(anchor: ExternalCorrectionAnchor, destination: DictationDestinationDescriptor, deliveryID: UUID,
         scheduler: any ExternalCorrectionScheduling, isEnabled: @escaping @MainActor () -> Bool,
         read: @escaping @MainActor () -> DictationFieldSnapshot?,
         onObservation: @escaping @MainActor (ExternalCorrectionObservation) -> Void) {
        self.anchor = anchor
        self.destination = destination
        self.deliveryID = deliveryID
        self.scheduler = scheduler
        expiresAt = scheduler.now.addingTimeInterval(Self.lifetime)
        self.isEnabled = isEnabled
        self.read = read
        self.onObservation = onObservation
        expiry = scheduler.schedule(after: Self.lifetime) { [weak self] in self?.stop() }
    }

    isolated deinit { stop() }

    func attach(_ observer: any ExternalCorrectionCancellation) {
        guard isActive else { observer.cancel(); return }
        self.observer = observer
    }

    func receive(_ event: DictationFieldObservationEvent) {
        guard isActive else { return }
        guard scheduler.now < expiresAt, isEnabled?() == true else { stop(); return }
        switch event {
        case .invalidated: stop()
        case .valueChanged:
            pendingRead?.cancel()
            eventGeneration += 1
            let generation = eventGeneration
            pendingRead = scheduler.schedule(after: Self.debounce) { [weak self] in
                guard let self, self.isActive, self.eventGeneration == generation else { return }
                self.inspect()
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        eventGeneration += 1
        pendingRead?.cancel(); pendingRead = nil
        expiry?.cancel(); expiry = nil
        observer?.cancel(); observer = nil
        anchor = nil
        isEnabled = nil
        read = nil
        onObservation = nil
    }

    private func inspect() {
        pendingRead = nil
        guard scheduler.now < expiresAt, isEnabled?() == true,
              let snapshot = read?(),
              snapshot.isValid(maximumUTF16: DictationDeliveryService.maximumFieldUTF16),
              let anchor else { stop(); return }
        switch anchor.change(in: snapshot.text) {
        case .unchanged: return
        case .invalid: stop()
        case .corrected(let corrected):
            let observation = ExternalCorrectionObservation(originalText: anchor.originalText, correctedText: corrected,
                destination: destination, deliveryID: deliveryID, observedAt: scheduler.now)
            let callback = onObservation
            stop()
            callback?(observation)
        }
    }
}
