import Foundation
import Testing
@testable import Keystorm

@MainActor
struct TranscriptionWindowTests {
    @Test func `Three adjacent five second segments form a full three segment window`() throws {
        let take = adjacentSegments(count: 3, frames: 240_000)
        let window = try #require(WorkspaceModel.transcriptionWindow(for: take[1], in: take))
        #expect(window.segments.map(\.id) == take.map(\.id))
        #expect(window.hasRightContext)
        #expect(totalDuration(window.segments) <= LocalInference.maximumWindowSeconds)
    }

    @Test func `Segments lengthened by a hardware buffer still fit the worker cap`() throws {
        // 5 s at 48 kHz plus one 4096-frame HAL buffer is about 5.085 s, so three exceed 15 s.
        let take = adjacentSegments(count: 3, frames: 240_000 + 4_096)
        #expect(totalDuration(take) > LocalInference.maximumWindowSeconds)
        let core = take[1]
        let window = try #require(WorkspaceModel.transcriptionWindow(for: core, in: take))
        #expect(totalDuration(window.segments) <= LocalInference.maximumWindowSeconds)
        #expect(window.segments.contains { $0.id == core.id })
        #expect(window.segments.map(\.id) == [take[0].id, core.id])
        #expect(window.hasRightContext)
    }

    @Test func `A core without neighbours is a single segment window`() throws {
        let core = segment(interval: UUID(), start: 0, frames: 240_000)
        let window = try #require(WorkspaceModel.transcriptionWindow(for: core, in: [core]))
        #expect(window.segments.map(\.id) == [core.id])
        #expect(!window.hasRightContext)
    }

    @Test func `A right neighbour from another capture interval is not context`() throws {
        let core = segment(interval: UUID(), start: 0, frames: 240_000)
        let other = segment(interval: UUID(), start: core.endTime, frames: 240_000)
        let window = try #require(WorkspaceModel.transcriptionWindow(for: core, in: [core, other]))
        #expect(window.segments.map(\.id) == [core.id])
        #expect(!window.hasRightContext)
    }

    private func adjacentSegments(count: Int, frames: Int64) -> [AudioSegment] {
        let interval = UUID()
        var result: [AudioSegment] = []
        for _ in 0..<count {
            result.append(segment(interval: interval, start: result.last?.endTime ?? 0, frames: frames))
        }
        return result
    }

    private func segment(interval: UUID, start: Double, frames: Int64) -> AudioSegment {
        AudioSegment(intervalID: interval, fileName: "fixture.caf", startTime: start,
            frameCount: frames, sampleRate: 48_000, channelCount: 1, sha256: "fixture")
    }

    private func totalDuration(_ segments: [AudioSegment]) -> Double {
        segments.reduce(0) { $0 + $1.duration }
    }
}
