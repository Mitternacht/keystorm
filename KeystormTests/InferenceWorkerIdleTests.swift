import Darwin
import Foundation
import Testing
@testable import Keystorm

@Suite(.serialized)
struct InferenceWorkerIdleTests {
    @Test("A resident idle worker does not schedule footprint sampling",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_RESIDENCY"] == "1"),
          .exclusiveModelUse,
          .timeLimit(.minutes(2)))
    func idleWorkerDoesNotSample() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-IdleWorker-\(UUID().uuidString)")
        let client = InferenceWorkerClient(modelDirectory: directory, idleRetention: .seconds(30))
        do {
            let identity = try await client.ping()
            let before = await client.memorySnapshot()
            let initialSamples = try #require(before["workerFootprintSamples"])
            try await Task.sleep(for: .milliseconds(1_200))
            let after = await client.memorySnapshot()
            let finalSamples = try #require(after["workerFootprintSamples"])
            let samples = try JSONEncoder().encode(["before": before, "after": after])
            Attachment.record(samples, named: "idle-worker-samples.json")
            print("IDLE_WORKER_SAMPLES before=\(initialSamples) after=\(finalSamples) interval_ms=1200")
            #expect(after["workerPID"] == UInt64(identity.processID))
            #expect(finalSamples == initialSamples)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    @Test("An idle private worker exits cleanly when its parent closes stdin",
          .enabled(if: ProcessInfo.processInfo.environment["KEYSTORM_RUN_RESIDENCY"] == "1"),
          .exclusiveModelUse,
          .timeLimit(.minutes(2)))
    func idleWorkerExitsOnInputEOF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keystorm-IdleEOF-\(UUID().uuidString)")
        let executable = try #require(Bundle.main.executableURL)
        try #require(executable.lastPathComponent == "Keystorm")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [InferenceWorkerDaemon.argument, "--model-directory", directory.path]
        process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("XCTest") && !$0.key.hasPrefix("XCInject") && !$0.key.hasPrefix("DYLD_")
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try #require(fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0)
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        try #require(flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0)
        try process.run()
        defer {
            // Signals are exclusively failure cleanup; a passing test only delivers EOF.
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            try? input.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        do {
            // Foundation may already close these parent-side copies during launch.
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            let request = InferenceWorkerRequest(operation: .ping)
            try input.fileHandleForWriting.write(contentsOf: InferenceWorkerCodec.frame(request))
            var buffer = Data()
            var scratch = [UInt8](repeating: 0, count: 8_192)
            var ping: InferenceWorkerReply?
            let pingDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ping == nil && process.isRunning && ContinuousClock.now < pingDeadline {
                let count = scratch.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    buffer.append(contentsOf: scratch.prefix(count))
                    try #require(buffer.count <= InferenceWorkerCodec.maximumFrameBytes)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard line.starts(with: InferenceWorkerCodec.prefix) else { continue }
                        ping = try InferenceWorkerCodec.decode(InferenceWorkerReply.self, from: line)
                    }
                } else if count < 0 && ![EAGAIN, EWOULDBLOCK, EINTR].contains(errno) {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if ping == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            let reply = try #require(ping, "The private worker must answer ping within ten seconds.")
            try #require(reply.id == request.id && reply.succeeded && reply.processID == process.processIdentifier)
            let closedAt = ContinuousClock.now
            try input.fileHandleForWriting.close()
            let exitDeadline = closedAt.advanced(by: .seconds(5))
            while process.isRunning && ContinuousClock.now < exitDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!process.isRunning, "Idle EOF must terminate the worker without a signal.")
            #expect(process.terminationReason == .exit)
            #expect(process.terminationStatus == 0)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            print("IDLE_WORKER_EOF elapsed=\(closedAt.duration(to: .now)) status=\(process.terminationStatus)")
        } catch {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning && ContinuousClock.now < cleanupDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(!process.isRunning, "Failure cleanup must not leave a private worker running.")
            throw error
        }
    }

    @Test("Completing a request clears the footprint guard's delivery identity")
    func completedRequestCannotReportStaleFailure() throws {
        let guardrail = InferenceWorkerFootprintGuard()
        let requestID = UUID()
        guardrail.setCeiling(1_000)
        guardrail.setRequest(requestID)
        let activeFailure = try #require(guardrail.failureReplyIfExceeded(by: 1_001, processID: 42))
        #expect(activeFailure.id == requestID)
        guardrail.endRequest()
        #expect(guardrail.failureReplyIfExceeded(by: 1_001, processID: 42) == nil)
    }
}
