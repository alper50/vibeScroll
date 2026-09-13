import AppKit
import SwiftUI
import VibeScrollCore

/// Points the eyes at the pointer while it is over the face.
///
/// Lives beside `BlinkModel` and `ReactionModel`, and is read in the same
/// place: inside `AnimatedFace`, which is what keeps the material circle out of
/// the frames it produces. That isolation matters more here than for either of
/// the others — a blink publishes twice, a reaction four times, but a pointer
/// crossing the face publishes on every mouse-move event. Whoever writes here
/// must not also observe it.
///
/// Entirely event-driven, so an idle face costs exactly what it did before. No
/// timer was added, deliberately: the drifting-gaze version of this needed one,
/// and the last continuous animation measured here cost 10.7% of a core.
@MainActor
final class GazeModel: ObservableObject {
    static let shared = GazeModel()

    /// -1…1 on each axis, 0 being straight ahead.
    @Published private(set) var direction: CGSize = .zero

    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Follows the pointer for as long as it is over the face.
    ///
    /// A short timer reading `NSEvent.mouseLocation`, rather than SwiftUI's
    /// `onContinuousHover`. That modifier depends on the window being told
    /// about mouse-moved events, and this window is a non-activating accessory
    /// panel that is essentially never the active app — whether hover
    /// positions arrive there is not something to take on faith, and it could
    /// not be verified here. `mouseLocation` is the same call the drag handler
    /// already makes in this exact window, and that demonstrably works.
    ///
    /// Nothing runs while the pointer is elsewhere, so an idle face costs what
    /// it always did. The interval is a rendering choice rather than a sampling
    /// one: a tick redraws the two eye shapes, not the material behind them.
    private static let interval: TimeInterval = 1.0 / 30

    private var timer: Timer?

    /// The pointer arrived.
    func beginTracking() {
        guard CardController.shared.followsPointer, !prefersReducedMotion else { return }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in GazeModel.shared.sample() }
        }
        sample()
    }

    private func sample() {
        guard let frame = FaceWindowController.shared.frame else { return }
        // The blob is centred across the window and sits in the slot at its
        // top, with the label taking the rest. Screen coordinates here, so the
        // window's own y grows upward.
        let centre = CGPoint(x: frame.midX, y: frame.maxY - CardLayout.faceSlot / 2)
        let radius = CardLayout.faceRestingSize / 2
        let mouse = NSEvent.mouseLocation

        // Negated on y: this becomes a SwiftUI offset, where y grows down.
        let next = CGSize(width: clamp((mouse.x - centre.x) / radius),
                          height: clamp((centre.y - mouse.y) / radius))
        // Set without an animation: the eyes should be where the pointer is,
        // not easing toward where it was. The return in `rest` is the part
        // worth animating, because nothing is driving it any more.
        if next != direction { direction = next }
    }

    /// The pointer left, or the setting went off.
    func rest() {
        timer?.invalidate()
        timer = nil
        guard direction != .zero else { return }
        withAnimation(prefersReducedMotion ? nil : .easeOut(duration: 0.25)) {
            direction = .zero
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(max(value, -1), 1) }
}
