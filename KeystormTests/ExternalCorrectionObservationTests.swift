import Foundation
import Testing
@testable import Keystorm

@MainActor
struct ExternalCorrectionObservationTests {
    @Test("A confirmed insertion observes one bounded EN/DE correction after a quiet second", arguments: [
        ["The Kubernettes deployment ist bereit.", "The Kubernetes deployment ist bereit."],
        ["Grüße 👩🏽‍💻 an Muller in München.", "Grüße 👩🏽‍💻 an Müller in München."],
        ["Cafe\u{301} und Datenshutz bleiben lokal.", "Cafe\u{301} und Datenschutz bleiben lokal."]
    ])
    func observesMixedLanguageCorrection(_ pair: [String]) async throws {
        let fixture = try await makeFixture(original: pair[0])
        #expect(fixture.arm())
        let reads = fixture.adapter.snapshotReads
        fixture.adapter.setText(fixture.prefix + pair[1] + fixture.suffix)
        fixture.adapter.emit(.valueChanged)
        fixture.clock.advance(by: 0.5)
        fixture.adapter.emit(.valueChanged)
        fixture.clock.advance(by: 0.75)
        #expect(fixture.box.values.isEmpty)
        #expect(fixture.adapter.snapshotReads == reads)
        fixture.clock.advance(by: 0.25)
        let observation = try #require(fixture.box.values.first)
        #expect(fixture.box.values.count == 1)
        #expect(observation.originalText.utf8.elementsEqual(pair[0].utf8))
        #expect(observation.correctedText.utf8.elementsEqual(pair[1].utf8))
        #expect(observation.destination == fixture.target.descriptor)
        #expect(observation.deliveryID == fixture.deliveryID)
        #expect(!observation.originalText.contains(fixture.prefix))
        #expect(!fixture.service.hasActiveCorrectionObservation)
        #expect(fixture.adapter.observerCancelCount == 1)
        #expect(fixture.adapter.writeCount == 1)
        fixture.adapter.emitLate(.valueChanged)
        fixture.clock.advance(by: 2)
        #expect(fixture.box.values.count == 1)
        #expect(fixture.adapter.snapshotReads == reads + 1)
    }

    @Test("Unchanged notifications do not create evidence or periodic reads")
    func unchangedNotificationAndIdleDoNotPoll() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.arm())
        let reads = fixture.adapter.snapshotReads
        fixture.clock.advance(by: 10)
        #expect(fixture.adapter.snapshotReads == reads)
        fixture.adapter.emit(.valueChanged)
        fixture.clock.advance(by: 1)
        #expect(fixture.box.values.isEmpty)
        #expect(fixture.service.hasActiveCorrectionObservation)
        #expect(fixture.adapter.snapshotReads == reads + 1)
        fixture.service.stopCorrectionObservation()
    }

    @Test("Outside text changes and ambiguous corrected passages stop observation", arguments: [0, 1, 2])
    func unrelatedOrAmbiguousChangesAreDiscarded(_ kind: Int) async throws {
        let fixture = try await makeFixture(original: "Kubernettes", prefix: "Prefix Kubernetes. ", suffix: " Suffix.")
        #expect(fixture.arm())
        switch kind {
        case 0: fixture.adapter.setText("Changed prefix. Kubernetes" + fixture.suffix)
        case 1: fixture.adapter.setText(fixture.prefix + "Kubernetes Changed suffix.")
        default: fixture.adapter.setText(fixture.prefix + "Kubernetes" + fixture.suffix)
        }
        fixture.adapter.emit(.valueChanged)
        fixture.clock.advance(by: 1)
        #expect(fixture.box.values.isEmpty)
        #expect(!fixture.service.hasActiveCorrectionObservation)
    }

    @Test("Repeated original passages refuse an observation lease")
    func repeatedOriginalIsNotAttributed() async throws {
        let fixture = try await makeFixture(original: "Kubernettes", prefix: "Earlier Kubernettes. ")
        #expect(!fixture.arm())
        #expect(fixture.adapter.observerStarts == 0)
        #expect(fixture.adapter.writeCount == 1)
    }

    @Test("Insertion ranges splitting an extended grapheme cannot be observed")
    func graphemeSplitIsNotObserved() async throws {
        let fixture = try await makeFixture(original: "\u{301}", prefix: "e", suffix: " remains.")
        #expect(!fixture.arm())
        #expect(fixture.adapter.observerStarts == 0)
    }

    @Test("Credential labels outside the inserted passage veto capture", arguments: ["Password: ", "Passwort: ", "API key: "])
    func surroundingCredentialLabelIsNotLost(_ label: String) async throws {
        let fixture = try await makeFixture(original: "Kubernettes", prefix: label)
        #expect(!fixture.arm())
        #expect(fixture.adapter.observerStarts == 0)
        #expect(fixture.box.values.isEmpty)
    }

    @Test("Sensitive content appearing inside the passage is discarded before callback")
    func sensitiveCorrectionIsDiscarded() async throws {
        let fixture = try await makeFixture(original: "The deployment is ready.")
        #expect(fixture.arm())
        fixture.adapter.setText(fixture.prefix + "Password is Kubernetes." + fixture.suffix)
        fixture.adapter.emit(.valueChanged)
        fixture.clock.advance(by: 1)
        #expect(fixture.box.values.isEmpty)
        #expect(!fixture.service.hasActiveCorrectionObservation)
    }

    @Test("The thirty-second expiry stops without reading a destination")
    func expiryDoesNotRead() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.arm())
        let reads = fixture.adapter.snapshotReads
        fixture.clock.advance(by: 30)
        #expect(!fixture.service.hasActiveCorrectionObservation)
        #expect(fixture.adapter.observerCancelCount == 1)
        fixture.adapter.setText(fixture.prefix + "Kubernetes" + fixture.suffix)
        fixture.adapter.emitLate(.valueChanged)
        fixture.clock.advance(by: 2)
        #expect(fixture.box.values.isEmpty)
        #expect(fixture.adapter.snapshotReads == reads)
    }

    @Test("A queued change cannot outlive the lease expiry")
    func pendingDebounceExpires() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.arm())
        fixture.clock.advance(by: 29.5)
        fixture.adapter.setText(fixture.prefix + "Kubernetes" + fixture.suffix)
        fixture.adapter.emit(.valueChanged)
        let reads = fixture.adapter.snapshotReads
        fixture.clock.advance(by: 1)
        #expect(fixture.adapter.snapshotReads == reads)
        #expect(fixture.box.values.isEmpty)
        #expect(!fixture.service.hasActiveCorrectionObservation)
    }

    @Test("Opt-out stops before any destination read")
    func optOutDoesNotRead() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.arm())
        let reads = fixture.adapter.snapshotReads
        fixture.box.isEnabled = false
        fixture.adapter.emit(.valueChanged)
        fixture.clock.advance(by: 2)
        #expect(fixture.adapter.snapshotReads == reads)
        #expect(fixture.box.values.isEmpty)
        #expect(!fixture.service.hasActiveCorrectionObservation)
    }

    @Test("Permission, field identity and secure state are revalidated before reading", arguments: [0, 1, 2, 3, 4])
    func unsafeDestinationDoesNotRead(_ kind: Int) async throws {
        let fixture = try await makeFixture()
        #expect(fixture.arm())
        let reads = fixture.adapter.snapshotReads
        switch kind {
        case 0: fixture.adapter.isTrusted = false
        case 1: fixture.adapter.field = ExternalObservationTestField()
        case 2: fixture.adapter.metadata.isProtected = true
        case 3: fixture.adapter.app.bundleIdentifier = "com.example.Other"
        default: fixture.adapter.metadata.isEnabled = false
        }
        fixture.adapter.emit(.valueChanged)
        fixture.clock.advance(by: 1)
        #expect(fixture.adapter.snapshotReads == reads)
        #expect(fixture.box.values.isEmpty)
        #expect(!fixture.service.hasActiveCorrectionObservation)
    }

    @Test("A focus-away event irreversibly invalidates a lease even after returning")
    func focusLeaveAndReturnCannotResumeLease() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.arm())
        let reads = fixture.adapter.snapshotReads
        fixture.adapter.setText(fixture.prefix + "Kubernetes" + fixture.suffix)
        fixture.adapter.emit(.valueChanged)
        fixture.adapter.emit(.invalidated)
        fixture.adapter.emitLate(.valueChanged)
        fixture.clock.advance(by: 2)
        #expect(fixture.box.values.isEmpty)
        #expect(fixture.adapter.snapshotReads == reads)
        #expect(!fixture.service.hasActiveCorrectionObservation)
    }

    @Test("Unsupported adapter observation preserves successful delivery")
    func unsupportedObservationIsASeparateCapability() async throws {
        let fixture = try await makeFixture()
        fixture.adapter.supportsObservation = false
        #expect(!fixture.arm())
        #expect(fixture.adapter.writeCount == 1)
        #expect(fixture.adapter.state.text == fixture.prefix + fixture.original + fixture.suffix)
        #expect(!fixture.service.hasActiveCorrectionObservation)
        #expect(fixture.box.values.isEmpty)
    }

    @Test("Failed delivery and mismatched delivery identity cannot arm learning")
    func onlyConfirmedExactDeliveryMayArm() async throws {
        let fixture = try await makeFixture()
        let mismatchedText = fixture.service.startCorrectionObservation(to: fixture.target, deliveredText: "different", deliveryID: fixture.deliveryID,
            isEnabled: { true }, onObservation: { _ in Issue.record("Unexpected observation") })
        #expect(!mismatchedText)
        let mismatchedID = fixture.service.startCorrectionObservation(to: fixture.target, deliveredText: fixture.original, deliveryID: UUID(),
            isEnabled: { true }, onObservation: { _ in Issue.record("Unexpected observation") })
        #expect(!mismatchedID)
        let adapter = ExternalObservationTestAdapter(text: "")
        adapter.acknowledgment = .rejected
        let service = DictationDeliveryService(adapter: adapter, ownBundleIdentifier: "test.keystorm", ownProcessIdentifier: 900,
            correctionObservationScheduler: fixture.clock)
        let target = try capture(service)
        let id = UUID()
        #expect(await service.deliver("Kubernettes", to: target, deliveryID: id).outcome == .failed)
        let armedAfterFailure = service.startCorrectionObservation(to: target, deliveredText: "Kubernettes", deliveryID: id,
            isEnabled: { true }, onObservation: { _ in Issue.record("Unexpected observation") })
        #expect(!armedAfterFailure)
        #expect(adapter.observerStarts == 0)
    }

    @Test("Cancellation and new capture invalidate delayed observer and timer callbacks", arguments: [false, true])
    func stopAndNewCaptureRejectLateCallbacks(_ newCapture: Bool) async throws {
        let fixture = try await makeFixture()
        #expect(fixture.arm())
        fixture.adapter.setText(fixture.prefix + "Kubernetes" + fixture.suffix)
        fixture.adapter.emit(.valueChanged)
        if newCapture { _ = fixture.service.captureTarget() }
        else { fixture.service.stopCorrectionObservation() }
        let reads = fixture.adapter.snapshotReads
        fixture.adapter.emitLate(.valueChanged)
        fixture.clock.fireCancelledActions()
        fixture.clock.advance(by: 2)
        #expect(fixture.adapter.snapshotReads == reads)
        #expect(fixture.box.values.isEmpty)
        #expect(!fixture.service.hasActiveCorrectionObservation)
    }

    @Test("Changing the destination during observer registration refuses the lease")
    func registrationRaceFailsClosed() async throws {
        let fixture = try await makeFixture()
        fixture.adapter.onObserve = { [adapter = fixture.adapter] in adapter.setText("Different document") }
        #expect(!fixture.arm())
        #expect(fixture.adapter.observerCancelCount == 1)
        #expect(fixture.box.values.isEmpty)
    }

    @Test("Releasing a service cancels its observation and queued timer")
    func serviceLifetimeCancelsObservation() async throws {
        let adapter = ExternalObservationTestAdapter(text: "Prefix. ")
        let clock = ExternalObservationTestScheduler()
        var service: DictationDeliveryService? = DictationDeliveryService(adapter: adapter, ownBundleIdentifier: "test.keystorm",
            ownProcessIdentifier: 900, correctionObservationScheduler: clock)
        let target = try capture(try #require(service))
        let id = UUID()
        #expect(await service?.deliver("Kubernettes", to: target, deliveryID: id).outcome == .confirmed)
        #expect(service?.startCorrectionObservation(to: target, deliveredText: "Kubernettes", deliveryID: id,
            isEnabled: { true }, onObservation: { _ in Issue.record("Unexpected observation") }) == true)
        service = nil
        #expect(adapter.observerCancelCount == 1)
        adapter.emitLate(.valueChanged)
        clock.advance(by: 31)
    }

    private func makeFixture(original: String = "Kubernettes", prefix: String = "Keep 👩🏽‍💻. ",
                             suffix: String = " Ende.") async throws -> ExternalObservationFixture {
        let adapter = ExternalObservationTestAdapter(text: prefix + suffix)
        adapter.state.selection = NSRange(location: prefix.utf16.count, length: 0)
        let clock = ExternalObservationTestScheduler()
        let service = DictationDeliveryService(adapter: adapter, ownBundleIdentifier: "test.keystorm", ownProcessIdentifier: 900,
            correctionObservationScheduler: clock)
        let target = try capture(service)
        let deliveryID = UUID()
        try #require(await service.deliver(original, to: target, deliveryID: deliveryID).outcome == .confirmed)
        return ExternalObservationFixture(service: service, adapter: adapter, clock: clock, target: target,
            deliveryID: deliveryID, original: original, prefix: prefix, suffix: suffix)
    }

    private func capture(_ service: DictationDeliveryService) throws -> DictationCapturedTarget {
        guard case .ready(let target) = service.captureTarget() else { throw ExternalObservationTestError.noTarget }
        return target
    }
}

private enum ExternalObservationTestError: Error { case noTarget }

@MainActor
private final class ExternalObservationBox {
    var isEnabled = true
    var values: [ExternalCorrectionObservation] = []
}

@MainActor
private struct ExternalObservationFixture {
    let service: DictationDeliveryService
    let adapter: ExternalObservationTestAdapter
    let clock: ExternalObservationTestScheduler
    let target: DictationCapturedTarget
    let deliveryID: UUID
    let original: String
    let prefix: String
    let suffix: String
    let box = ExternalObservationBox()

    func arm() -> Bool {
        service.startCorrectionObservation(to: target, deliveredText: original, deliveryID: deliveryID,
            isEnabled: { box.isEnabled }, onObservation: { box.values.append($0) })
    }
}

@MainActor
final class ExternalObservationTestScheduler: ExternalCorrectionScheduling {
    struct Pending {
        let id: Int
        let date: Date
        let action: @MainActor () -> Void
    }
    private(set) var now = Date(timeIntervalSince1970: 1_000)
    private var nextID = 0
    private var actions: [Int: Pending] = [:]
    private var cancelled: [@MainActor () -> Void] = []

    func schedule(after seconds: TimeInterval, action: @escaping @MainActor () -> Void) -> any ExternalCorrectionCancellation {
        nextID += 1
        let id = nextID
        actions[id] = Pending(id: id, date: now.addingTimeInterval(seconds), action: action)
        return ExternalObservationTestCancellation { [weak self] in
            guard let self, let pending = self.actions.removeValue(forKey: id) else { return }
            self.cancelled.append(pending.action)
        }
    }

    func advance(by seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let next = actions.values.filter({ $0.date <= end }).sorted(by: {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }).first {
            actions.removeValue(forKey: next.id)
            now = next.date
            next.action()
        }
        now = end
    }

    func fireCancelledActions() {
        let callbacks = cancelled
        cancelled.removeAll()
        for callback in callbacks { callback() }
    }
}

@MainActor
final class ExternalObservationTestCancellation: ExternalCorrectionCancellation {
    private var action: (@MainActor () -> Void)?
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func cancel() { let callback = action; action = nil; callback?() }
}

@MainActor
final class ExternalObservationTestField: DictationDeliveryField {}

@MainActor
final class ExternalObservationTestAdapter: DictationDeliveryAdapter {
    var isTrusted = true
    var app = DictationDeliveryApplication(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
    var field = ExternalObservationTestField()
    var metadata = DictationFieldMetadata(processIdentifier: 42, role: "AXTextArea", subrole: nil,
        isEnabled: true, isProtected: false, selectedTextIsSettable: true)
    var state: DictationFieldSnapshot
    var acknowledgment: DictationReplacementAcknowledgment = .accepted
    var supportsObservation = true
    var snapshotReads = 0
    var writeCount = 0
    var observerStarts = 0
    var observerCancelCount = 0
    var onObserve: (@MainActor () -> Void)?
    private var event: (@MainActor (DictationFieldObservationEvent) -> Void)?
    private var lateEvent: (@MainActor (DictationFieldObservationEvent) -> Void)?

    init(text: String) { state = DictationFieldSnapshot(text: text, selection: NSRange(location: text.utf16.count, length: 0)) }
    func requestPermission() {}
    func openSettings() {}
    func frontmostApplication() -> DictationDeliveryApplication? { app }
    func focusedField(in application: DictationDeliveryApplication) throws -> any DictationDeliveryField { field }
    func sameField(_ lhs: any DictationDeliveryField, _ rhs: any DictationDeliveryField) -> Bool { lhs === rhs }
    func metadata(for field: any DictationDeliveryField) throws -> DictationFieldMetadata { metadata }
    func snapshot(of field: any DictationDeliveryField, maximumUTF16: Int) throws -> DictationFieldSnapshot {
        snapshotReads += 1
        return state
    }
    func replaceSelectedText(_ text: String, in field: any DictationDeliveryField) -> DictationReplacementAcknowledgment {
        writeCount += 1
        if acknowledgment != .rejected {
            let location = state.selection.location
            state.text = (state.text as NSString).replacingCharacters(in: state.selection, with: text)
            state.selection = NSRange(location: location + text.utf16.count, length: 0)
        }
        return acknowledgment
    }
    func observeChanges(of field: any DictationDeliveryField, processIdentifier: Int32,
                        onEvent: @escaping @MainActor (DictationFieldObservationEvent) -> Void) -> (any ExternalCorrectionCancellation)? {
        observerStarts += 1
        guard supportsObservation else { return nil }
        event = onEvent
        lateEvent = onEvent
        onObserve?()
        return ExternalObservationTestCancellation { [weak self] in
            self?.observerCancelCount += 1
            self?.event = nil
        }
    }
    func setText(_ text: String) {
        state = DictationFieldSnapshot(text: text, selection: NSRange(location: text.utf16.count, length: 0))
    }
    func emit(_ value: DictationFieldObservationEvent) { event?(value) }
    func emitLate(_ value: DictationFieldObservationEvent) { lateEvent?(value) }
}
