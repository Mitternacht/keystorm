import Foundation
import Testing
@testable import Keystorm

/// Website exclusions: domain normalization, page-address verdicts, and the delivery service at Start and Finish.
/// Addresses come from a fake adapter; no real Accessibility, browser or network is used.
@MainActor
@Suite(.serialized)
struct ExclusionWebsiteTests {
    // MARK: Domains

    @Test("What a user types is normalized to a plain lowercase domain", arguments: [
        ("example.com", "example.com"),
        ("  Example.COM  ", "example.com"),
        ("https://www.example.com/login?next=1#top", "example.com"),
        ("http://user:secret@bank.example.co.uk:8443/path", "bank.example.co.uk"),
        ("*.example.org", "example.org"),
        ("www.com", "www.com"),
        ("example.com.", "example.com"),
        ("xn--mnchen-3ya.de", "xn--mnchen-3ya.de"),
        ("192.168.1.10", "192.168.1.10")
    ])
    func domainNormalization(_ input: String, _ expected: String) {
        #expect(DictationWebsiteExclusion.normalizedDomain(input) == expected)
    }

    @Test("Anything that is not a plain domain name is rejected", arguments: [
        "", "   ", "com", "localhost", "münchen.de", "exa mple.com", "-example.com", "example-.com",
        "example..com", "1.2", "999.1.1.1", "https://", "[::1]", "example.123"
    ])
    func invalidDomainsAreRejected(_ input: String) {
        #expect(DictationWebsiteExclusion.normalizedDomain(input) == nil)
    }

    @Test("A blocked domain covers itself and its subdomains, never look-alike names")
    func hostMatching() {
        #expect(DictationWebsiteExclusion.host("example.com", matches: "example.com"))
        #expect(DictationWebsiteExclusion.host("login.example.com", matches: "example.com"))
        #expect(DictationWebsiteExclusion.host("a.b.example.com", matches: "example.com"))
        #expect(!DictationWebsiteExclusion.host("notexample.com", matches: "example.com"))
        #expect(!DictationWebsiteExclusion.host("example.com.evil.net", matches: "example.com"))
        #expect(!DictationWebsiteExclusion.host("example.co", matches: "example.com"))
    }

    // MARK: Verdicts

    @Test("Page-address verdicts: blocked wins, unreadable fails safe, and nothing is looked at while no website is blocked",
          arguments: [
            WebsiteVerdictCase(name: "no website blocked", lookup: .unavailable, blocked: [], expected: .notChecked),
            WebsiteVerdictCase(name: "native field", lookup: .notWebContent, blocked: ["example.com"], expected: .notWebContent),
            WebsiteVerdictCase(name: "unreadable ancestry", lookup: .unavailable, blocked: ["example.com"], expected: .unverified),
            WebsiteVerdictCase(name: "allowed page", lookup: .webContent([url("https://docs.other.org/a")]),
                               blocked: ["example.com"], expected: .allowed),
            WebsiteVerdictCase(name: "blocked page", lookup: .webContent([url("https://example.com/")]),
                               blocked: ["example.com"], expected: .blocked),
            WebsiteVerdictCase(name: "blocked subdomain, mixed case, trailing dot",
                               lookup: .webContent([url("https://Login.Example.com./x")]),
                               blocked: ["example.com"], expected: .blocked),
            WebsiteVerdictCase(name: "blocked iframe inside an allowed page",
                               lookup: .webContent([url("https://pay.example.com/frame"), url("https://shop.other.org/")]),
                               blocked: ["example.com"], expected: .blocked),
            WebsiteVerdictCase(name: "about:blank frame inside a blocked page",
                               lookup: .webContent([url("about:blank"), url("https://example.com/")]),
                               blocked: ["example.com"], expected: .blocked),
            WebsiteVerdictCase(name: "about:blank frame inside an allowed page",
                               lookup: .webContent([url("about:blank"), url("https://other.org/")]),
                               blocked: ["example.com"], expected: .allowed),
            WebsiteVerdictCase(name: "top-level about:blank", lookup: .webContent([url("about:blank")]),
                               blocked: ["example.com"], expected: .unverified),
            WebsiteVerdictCase(name: "document without an address", lookup: .webContent([nil]),
                               blocked: ["example.com"], expected: .unverified),
            WebsiteVerdictCase(name: "unreadable frame, blocked page",
                               lookup: .webContent([nil, url("https://example.com/")]),
                               blocked: ["example.com"], expected: .blocked),
            WebsiteVerdictCase(name: "data page", lookup: .webContent([url("data:text/html,hello")]),
                               blocked: ["example.com"], expected: .unverified),
            WebsiteVerdictCase(name: "blob page", lookup: .webContent([url("blob:https://example.org/1234")]),
                               blocked: ["example.com"], expected: .unverified),
            WebsiteVerdictCase(name: "local file", lookup: .webContent([url("file:///Users/me/page.html")]),
                               blocked: ["example.com"], expected: .allowed),
            WebsiteVerdictCase(name: "no documents at all", lookup: .webContent([]),
                               blocked: ["example.com"], expected: .unverified)
          ])
    func verdicts(_ fixture: WebsiteVerdictCase) {
        #expect(DictationWebsiteExclusion.verdict(fixture.lookup, blockedDomains: fixture.blocked) == fixture.expected)
    }

    // MARK: Start

    @Test("A field on a blocked website blocks recording at Start, with no context and no selection read",
          arguments: DeliverySafetyPath.allCases)
    func blockedWebsiteRefusedAtStart(_ path: DeliverySafetyPath) throws {
        let adapter = DeliverySafetyAdapter(path)
        adapter.webLookup = .webContent([url("https://login.bank.example/session")])
        let capture = DeliverySafetyAdapter.service(adapter).captureForStart(contextSettings: .init(mode: .nearbyText),
            pasteIntoOtherApps: true, exclusions: DictationUserExclusions(websites: ["bank.example"]))
        let failure = try #require(deliverySafetyFailure(capture.target))
        #expect(failure == .excludedWebsite)
        #expect(failure.blocksRecording)
        #expect(capture.context == nil)
        #expect(adapter.snapshotReads == 0, "Checked before any field text is read.")
        #expect(adapter.selectionReads == 0)
    }

    @Test("A page address that cannot be read fails safe: Copy only, no context, recording continues",
          arguments: DeliverySafetyPath.allCases, [DictationWebDocumentLookup.unavailable, .webContent([nil])])
    func unverifiedWebsiteIsCopyOnly(_ path: DeliverySafetyPath, _ lookup: DictationWebDocumentLookup) throws {
        let adapter = DeliverySafetyAdapter(path)
        adapter.webLookup = lookup
        let capture = DeliverySafetyAdapter.service(adapter).captureForStart(contextSettings: .init(mode: .application),
            pasteIntoOtherApps: true, exclusions: DictationUserExclusions(websites: ["bank.example"]))
        let failure = try #require(deliverySafetyFailure(capture.target))
        #expect(failure == .unverifiedWebsite)
        #expect(!failure.blocksRecording)
        #expect(capture.context == nil)
        #expect(adapter.snapshotReads == 0)
        #expect(adapter.writes == 0)
    }

    @Test("Native fields and allowed pages are captured as before", arguments: DeliverySafetyPath.allCases,
          [DictationWebDocumentLookup.notWebContent, .webContent([url("https://mail.other.org/compose")])])
    func allowedFieldsAreCaptured(_ path: DeliverySafetyPath, _ lookup: DictationWebDocumentLookup) throws {
        let adapter = DeliverySafetyAdapter(path)
        adapter.webLookup = lookup
        let target = try adapter.readyTarget(DeliverySafetyAdapter.service(adapter),
                                             exclusions: DictationUserExclusions(websites: ["bank.example"]))
        #expect(target.descriptor.bundleIdentifier == adapter.app.bundleIdentifier)
        #expect(adapter.webLookups == 1)
    }

    @Test("While no website is blocked, page addresses are never looked up", arguments: DeliverySafetyPath.allCases)
    func noLookupWithoutBlockedWebsites(_ path: DeliverySafetyPath) async throws {
        let adapter = DeliverySafetyAdapter(path)
        adapter.webLookup = .webContent([url("https://bank.example/")])
        let service = DeliverySafetyAdapter.service(adapter)
        let target = try adapter.readyTarget(service, exclusions: DictationUserExclusions(applications: ["com.example.Vault"]))
        #expect(await service.deliver("Hallo", to: target, deliveryID: UUID()).outcome != .failed)
        #expect(adapter.webLookups == 0)
    }

    @Test("A terminal input on a blocked website blocks recording instead of offering Copy")
    func terminalOnBlockedWebsiteBlocks() throws {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        adapter.fieldMetadata.isTerminalInput = true
        adapter.webLookup = .webContent([url("https://console.bank.example/")])
        let failure = try #require(deliverySafetyFailure(DeliverySafetyAdapter.service(adapter)
            .captureTarget(pasteIntoOtherApps: true, exclusions: DictationUserExclusions(websites: ["bank.example"]))))
        #expect(failure == .excludedWebsite)
    }

    @Test("With Paste into other apps off, a browser is not inspected for its address")
    func pasteOffDoesNotInspect() throws {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        adapter.webLookup = .webContent([url("https://bank.example/")])
        let failure = try #require(deliverySafetyFailure(DeliverySafetyAdapter.service(adapter)
            .captureTarget(pasteIntoOtherApps: false, exclusions: DictationUserExclusions(websites: ["bank.example"]))))
        #expect(failure == .unsupportedApplication)
        #expect(adapter.focusRequests.isEmpty)
        #expect(adapter.webLookups == 0)
    }

    // MARK: Finish

    @Test("At Finish, a page that became blocked or unreadable, or a website blocked meanwhile, is never written",
          arguments: DeliverySafetyPath.allCases, WebsiteFinishChange.allCases)
    func websiteChangesAtFinish(_ path: DeliverySafetyPath, _ change: WebsiteFinishChange) async throws {
        let adapter = DeliverySafetyAdapter(path)
        adapter.webLookup = .webContent([url("https://notes.other.org/")])
        let service = DeliverySafetyAdapter.service(adapter)
        let startExclusions = DictationUserExclusions(websites: change == .blockedDuringRecording ? [] : ["bank.example"])
        let target = try adapter.readyTarget(service, exclusions: startExclusions)
        switch change {
        case .navigatedToBlockedPage: adapter.webLookup = .webContent([url("https://bank.example/transfer")])
        case .addressBecameUnreadable: adapter.webLookup = .unavailable
        case .blockedDuringRecording: break
        }
        let finishExclusions = DictationUserExclusions(websites: change == .blockedDuringRecording ?
            ["other.org"] : ["bank.example"])
        let receipt = await service.deliver("Hallo", to: target, deliveryID: UUID(), exclusions: finishExclusions)
        #expect(receipt.outcome == .failed)
        #expect(receipt.message.contains("Nothing was inserted"))
        #expect(adapter.writes == 0)
        #expect(adapter.fallbackPreparations == 0)
        #expect(adapter.snapshotReads == (path == .qualified ? 1 : 0), "Refused before the field text is read again.")
    }

    @Test("A page that turns blocked while the clipboard is staged is not pasted, and the clipboard is restored")
    func websiteChangeDuringStaging() async throws {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        adapter.webLookup = .webContent([url("https://notes.other.org/")])
        let service = DeliverySafetyAdapter.service(adapter)
        let exclusions = DictationUserExclusions(websites: ["bank.example"])
        let target = try adapter.readyTarget(service, exclusions: exclusions)
        adapter.onPrepare = { adapter.webLookup = .webContent([url("https://bank.example/")]) }
        let receipt = await service.deliver("Hallo", to: target, deliveryID: UUID(), exclusions: exclusions)
        #expect(receipt.outcome == .failed)
        #expect(adapter.performCount == 0)
        #expect(adapter.pasteOperation?.restoreCount == 1)
    }

    @Test("The coordinator refuses to record on a blocked website")
    func coordinatorRefusesBlockedWebsite() async {
        let adapter = DeliverySafetyAdapter(.pasteFallback)
        adapter.webLookup = .webContent([url("https://bank.example/")])
        let preferences = DictationPreferences()
        #expect(preferences.blockWebsite("https://www.bank.example/login"))
        let backend = DeliverySafetyBackend()
        let coordinator = DictationCoordinator(backend: backend, delivery: DeliverySafetyAdapter.service(adapter),
                                               preferences: preferences)
        coordinator.toggle()
        await coordinator.waitUntilSettled()
        #expect(coordinator.state == .failed)
        #expect(coordinator.message == DictationCaptureFailure.excludedWebsite.message)
        #expect(backend.beginModes.isEmpty)
        #expect(adapter.selectionReads == 0)
    }
}

private func url(_ string: String) -> URL? { URL(string: string) }

struct WebsiteVerdictCase: Sendable, CustomTestStringConvertible {
    var name: String
    var lookup: DictationWebDocumentLookup
    var blocked: [String]
    var expected: DictationWebsiteVerdict
    var testDescription: String { name }
}

enum WebsiteFinishChange: CaseIterable, Sendable {
    case navigatedToBlockedPage, addressBecameUnreadable, blockedDuringRecording
}
