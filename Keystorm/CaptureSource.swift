import AppKit
import AVFoundation
import Foundation

/// Something the audio source reports on its own, outside any call from capture.
enum CaptureSourceEvent: Sendable, Equatable {
    /// The default input, the route or the stream format changed (AirPods connected or removed, a USB mic unplugged).
    case configurationChanged
    /// The Mac is about to sleep.
    case willSleep
}

/// A stop that loses no audio: everything accepted before it is already durable. The take pauses like Pause does
/// and Resume re-opens the microphone on whatever input is the default then.
struct CaptureInterruption: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// The input device or route changed.
        case routeChanged
        /// The Mac went to sleep.
        case systemSleep
        /// Audio stopped arriving while the input was open.
        case stalled
        /// The input never delivered a first buffer.
        case noAudio
    }

    var reason: Reason
    var message: String

    static let routeChanged = CaptureInterruption(reason: .routeChanged,
        message: "The microphone changed. Recording is paused and saved; resume to continue on the current input.")
    static let systemSleep = CaptureInterruption(reason: .systemSleep,
        message: "The Mac is going to sleep. Recording is paused and saved; resume after waking.")
    static let stalled = CaptureInterruption(reason: .stalled,
        message: "Microphone audio stopped arriving. Recording is paused and saved; check the input and resume.")
    static let noAudio = CaptureInterruption(reason: .noAudio,
        message: "The microphone supplied no audio. Recording is paused; check the input and resume.")
}

/// The microphone side of capture, in front of AVAudioEngine so interruptions, configuration changes and the
/// watchdogs can be driven by a fake in unit tests. Inference and persistence never see this type.
@MainActor
protocol CaptureSource: AnyObject {
    /// Asks for microphone permission once; a fake answers without prompting.
    func requestAccess() async -> Bool
    /// Opens the current default input without delivering audio and returns the format it will deliver.
    func open() async throws -> AVAudioFormat
    /// Starts delivery. `deliver` is called on the audio thread; `onEvent` on any thread.
    func start(deliver: @escaping @Sendable (AVReadOnlyAudioPCMBuffer, CaptureTimestamp) -> Void,
               onEvent: @escaping @Sendable (CaptureSourceEvent) -> Void) throws
    /// Stops delivery and releases the input. Safe to call when already stopped or after a failed start.
    func stop()
}

/// Time as the capture watchdogs see it; replaceable so tests never wait.
struct CaptureClock: Sendable {
    var uptime: @Sendable () -> Double
    var sleep: @Sendable (Duration) async throws -> Void

    static let system = CaptureClock(
        uptime: { ProcessInfo.processInfo.systemUptime },
        sleep: { try await Task.sleep(for: $0) })
}

/// The real microphone: one AVAudioEngine per take interval, created fresh on every open so a resume after a route
/// change binds to whichever input is the default by then.
@MainActor
final class EngineCaptureSource: CaptureSource {
    private var engine: AVAudioEngine?
    private var tapNode: AVAudioInputNode?
    private var format: AVAudioFormat?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func open() async throws -> AVAudioFormat {
        var attempts = 0
        while true {
            let engine = AVAudioEngine()
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 {
                self.engine = engine
                self.format = format
                return format
            }
            // Right after a route change the new input can report no format for a moment; give it a short chance.
            attempts += 1
            guard attempts < 4 else {
                throw KeystormError.message("The microphone has no usable audio format. Reconnect it and resume explicitly.")
            }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    func start(deliver: @escaping @Sendable (AVReadOnlyAudioPCMBuffer, CaptureTimestamp) -> Void,
               onEvent: @escaping @Sendable (CaptureSourceEvent) -> Void) throws {
        guard let engine, let format else {
            throw KeystormError.message("The microphone was not opened.")
        }
        let input = engine.inputNode
        // The new tap owns immutable Sendable samples; retaining a buffer does not
        // retain a mutable engine scratch buffer. Admission is bounded before enqueue.
        try input.installAudioTap(
            onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.1), format: format
        ) { buffer, time in
            deliver(buffer, CaptureTimestamp(time))
        }
        tapNode = input
        engine.prepare()
        try engine.start()
        observe(engine: engine, onEvent: onEvent)
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        tapNode?.removeTap(onBus: 0)
        tapNode = nil
        engine?.stop()
        engine = nil
        format = nil
    }

    private func observe(engine: AVAudioEngine, onEvent: @escaping @Sendable (CaptureSourceEvent) -> Void) {
        let center = NotificationCenter.default
        let configuration = center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in onEvent(.configurationChanged) }
        observers.append((center, configuration))
        let workspace = NSWorkspace.shared.notificationCenter
        let sleep = workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { _ in onEvent(.willSleep) }
        observers.append((workspace, sleep))
    }
}
