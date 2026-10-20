import Darwin
import Dispatch
import SwiftUI

/// AppKit owns the UI event loop directly; it must not be nested in an async main task.
@main
enum KeystormEntry {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains(InferenceWorkerDaemon.argument) {
            // The child has no SwiftUI lifecycle. Its dispatch loop services async model work.
            Task.detached {
                await InferenceWorkerDaemon.run()
                Darwin.exit(0)
            }
            dispatchMain()
        } else {
            KeystormApp.main()
        }
    }
}
