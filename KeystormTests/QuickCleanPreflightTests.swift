import AVFoundation
import Foundation
import Testing
@testable import Keystorm

@MainActor
struct QuickCleanPreflightTests {
    @Test("Production Clean preflight rejects missing assets before creating a recording or requesting the microphone")
    func missingTextModelDoesNotBeginCapture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-CleanPreflight-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("EmptyModels", isDirectory: true)
        let model = WorkspaceModel(root: root, modelDirectory: models)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            await model.initialize(loadLibrary: true)
            try #require(model.error == nil, "\(model.error ?? "")")
            let store = try #require(model.store)
            #expect(model.installedModelIDs.isEmpty)
            let baselineSessions = model.sessions
            let baselineSelection = model.selectedSessionID
            let baselineAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
            #expect(!model.isRecording)
            #expect(!model.isCaptureTransitioning)
            #expect(!model.hasOpenTake)

            var failure: String?
            do {
                _ = try await model.dictationBegin(mode: .clean)
            } catch {
                failure = error.localizedDescription
            }

            #expect(failure == "Install the local text model before recording in Clean mode, or choose Verbatim.")
            #expect(model.sessions == baselineSessions)
            #expect(model.sessions.count == baselineSessions.count)
            #expect(model.selectedSessionID == baselineSelection)
            #expect(!model.isRecording)
            #expect(!model.isCaptureTransitioning)
            #expect(!model.hasOpenTake)
            #expect(!model.isBusy)
            #expect(model.sessions.allSatisfy { session in
                session.intervals.isEmpty && session.segments.isEmpty &&
                (session.brief?.takes.isEmpty ?? true) && session.dictation == nil
            })
            #expect(AVCaptureDevice.authorizationStatus(for: .audio) == baselineAuthorization)
            let persisted = try await store.loadSessions()
            #expect(persisted == baselineSessions)
            await model.stopForTermination()
        } catch {
            await model.stopForTermination()
            throw error
        }
    }
}
