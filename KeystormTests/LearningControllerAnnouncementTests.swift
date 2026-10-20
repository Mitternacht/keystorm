import Foundation
import Testing
@testable import Keystorm

/// The Learning dictionary announces each reported outcome or error, even when its text repeats.
extension LearningControllerTests {
    @Test("A repeated identical error is reported again for VoiceOver")
    func repeatedErrorAdvancesAnnouncement() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"))
        let controller = LearningDictionaryController(repository: repository) { LearningFixture.receipt($0) }
        #expect(controller.announcementToken == 0)
        #expect(controller.announcement == nil)
        let missing = UUID()
        await controller.approve(id: missing)
        let first = controller.announcementToken
        let message = try #require(controller.announcement)
        #expect(controller.errorMessage == message)
        await controller.approve(id: missing)
        #expect(controller.announcementToken == first + 1)
        #expect(controller.announcement == message)
    }

    @Test("A later success that clears the error keeps the reported announcement and reports nothing new")
    func clearedErrorKeepsReportedAnnouncement() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"))
        let controller = LearningDictionaryController(repository: repository) { LearningFixture.receipt($0) }
        await controller.approve(id: UUID())
        let token = controller.announcementToken
        let message = try #require(controller.errorMessage)
        // Succeeds and clears the visible error before a view could react to the error's token.
        await controller.setEnabled(true)
        await controller.waitUntilSettled()
        #expect(controller.errorMessage == nil)
        #expect(controller.announcementToken == token)
        #expect(controller.announcement == message)
    }

    @Test("A repeated review outcome is reported again and replaces an earlier error")
    func repeatedStatusAdvancesAnnouncement() async throws {
        let dir = try LearningFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try LearningRepository(url: dir.appendingPathComponent("learning.json"))
        try await repository.setEnabled(true)
        let controller = LearningDictionaryController(repository: repository) { LearningFixture.receipt($0) }
        await controller.refresh()
        await controller.approve(id: UUID())
        #expect(controller.errorMessage != nil)

        _ = try await repository.enqueue(LearningFixture.evidence())
        controller.drainPending()
        await controller.waitUntilSettled()
        let first = controller.announcementToken
        #expect(controller.errorMessage == nil)
        #expect(!controller.status.isEmpty)
        #expect(controller.announcement == controller.status)

        let status = controller.status
        _ = try await repository.enqueue(LearningFixture.evidence(old: "Compile swifft in Xcode.", new: "Compile Swift in Xcode."))
        controller.drainPending()
        await controller.waitUntilSettled()
        #expect(controller.announcementToken == first + 1)
        #expect(controller.status == status)
        #expect(controller.announcement == status)
    }
}
