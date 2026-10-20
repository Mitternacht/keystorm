import Darwin
import Foundation
import Testing
@testable import Keystorm

struct InferenceWorkerTests {
    @Test("RPC frames preserve IDs and literal source text")
    func frameRoundTrip() throws {
        let source = TranscriptRevision(rawText: "Use café 🧠, not cloud.", text: "Use café 🧠, not cloud.")
        let request = InferenceWorkerRequest(operation: .extraction, transcripts: [source])
        let framed = try InferenceWorkerCodec.frame(request)
        #expect(framed.last == 0x0A)
        let decoded = try InferenceWorkerCodec.decode(InferenceWorkerRequest.self, from: Data(framed.dropLast()))
        #expect(decoded.id == request.id)
        #expect(decoded.transcripts == [source])
        #expect(decoded.version == 1)
    }

    @Test("Oversized and unframed messages are rejected")
    func messageLimits() throws {
        let oversized = InferenceWorkerRequest(operation: .edit,
            command: String(repeating: "x", count: InferenceWorkerCodec.maximumFrameBytes))
        #expect(throws: (any Error).self) { try InferenceWorkerCodec.frame(oversized) }
        #expect(throws: (any Error).self) {
            try InferenceWorkerCodec.decode(InferenceWorkerRequest.self, from: Data("model log output".utf8))
        }
    }

    @Test("Frame reading scans each byte once across chunk and message boundaries")
    func frameReaderLinearScan() throws {
        var contents = Data(repeating: 0x61, count: 32_769)
        contents.append(contentsOf: [0x0A, 0x0A])
        contents.append(Data("last\n".utf8))
        try withReader(contents) { reader in
            let first = try reader.nextLine()
            let empty = try reader.nextLine()
            let last = try reader.nextLine()
            let end = try reader.nextLine()
            #expect(first == Data(repeating: 0x61, count: 32_769))
            #expect(empty == Data())
            #expect(last == Data("last".utf8))
            #expect(end == nil)
            #expect(reader.scannedByteCount == contents.count)
        }
    }

    @Test("Maximum-sized frames stay linear and oversized or truncated frames fail")
    func frameReaderBounds() throws {
        var maximum = Data(repeating: 0x61, count: InferenceWorkerCodec.maximumFrameBytes)
        maximum.append(0x0A)
        try withReader(maximum) { reader in
            let line = try reader.nextLine()
            let end = try reader.nextLine()
            #expect(line?.count == InferenceWorkerCodec.maximumFrameBytes)
            #expect(reader.scannedByteCount == maximum.count)
            #expect(end == nil)
        }
        maximum.insert(0x61, at: maximum.startIndex)
        try withReader(maximum) { reader in
            #expect(throws: (any Error).self) { try reader.nextLine() }
            #expect(reader.scannedByteCount == InferenceWorkerCodec.maximumFrameBytes + 1)
        }
        try withReader(Data("truncated".utf8)) { reader in
            #expect(throws: (any Error).self) { try reader.nextLine() }
        }
    }

    private func withReader(_ contents: Data, body: (InferenceWorkerFrameReader) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Frame-\(UUID().uuidString)")
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try body(InferenceWorkerFrameReader(file: file))
    }

    @Test("Missing executable failures remain recoverable")
    func missingExecutable() async throws {
        let client = InferenceWorkerClient(modelDirectory: FileManager.default.temporaryDirectory,
            executableURL: URL(fileURLWithPath: "/unavailable/Keystorm"))
        await #expect(throws: (any Error).self) { try await client.ping() }
        let snapshot = await client.memorySnapshot()
        #expect(snapshot["workerFootprint"] == 0)
        #expect(snapshot["workerPID"] == 0)
        await client.shutdown()
    }
}

@Suite(.serialized)
struct InferenceWorkerProcessTests {
    @Test("Private worker restarts after a crash and cancellation",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_WORKER_SMOKE"] == "1"),
          .timeLimit(.minutes(2)))
    func privateProcessRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keystorm-Worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = InferenceWorkerClient(modelDirectory: directory)
        let first = try await client.ping()
        #expect(first.protocolVersion == 1)
        #expect(first.processID != getpid())
        let again = try await client.ping()
        #expect(again.processID == first.processID)
        await client.simulateWorkerCrashForTesting()
        let restarted = try await client.ping()
        #expect(restarted.processID != first.processID)
        let wait = Task { try await client.waitInWorkerForTesting() }
        try await Task.sleep(for: .milliseconds(150))
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.value }
        let afterCancellation = try await client.ping()
        #expect(afterCancellation.processID != restarted.processID)
        #expect(kill(restarted.processID, 0) == -1 && errno == ESRCH)
        let memory = await client.memorySnapshot()
        #expect(memory["parentFootprint"] ?? 0 > 0)
        #expect(memory["workerFootprint"] ?? 0 > 0)
        #expect(memory["processFootprint"] == (memory["parentFootprint"] ?? 0) + (memory["workerFootprint"] ?? 0))
        await client.shutdown()
        #expect(kill(afterCancellation.processID, 0) == -1 && errno == ESRCH)
    }
}
