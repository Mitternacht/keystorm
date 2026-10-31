import Foundation
import Observation

/// The result of asking Keystorm to undo its last insertion. Nothing is ever undone unless the destination is
/// verifiably unchanged since the insertion, so a refusal is an ordinary outcome and says why.
struct DictationUndoReceipt: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The inserted text is gone (or the app's own undo was sent and the cursor went back).
        case undone
        /// There was no recent confirmed insertion.
        case nothingToUndo
        /// Nothing was changed: the destination, text or cursor no longer matches the insertion.
        case refused
        /// An undo was sent or attempted, but its effect could not be confirmed.
        case uncertain
    }

    var outcome: Outcome
    var message: String
    var destination: DictationDestinationDescriptor?
}

/// What the menu item, shortcut and HUD button observe: whether an undo is on offer, and in which app.
/// Holds names only, never text or Accessibility objects.
@MainActor @Observable
final class DictationUndoState {
    private(set) var destinationName: String?
    var isAvailable: Bool { destinationName != nil }

    func publish(destinationName: String?) {
        self.destinationName = destinationName
    }
}
