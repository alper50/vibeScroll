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

    /// `point` is in the face circle's own coordinates.
    func look(at point: CGPoint, in size: CGSize) {
        guard CardController.shared.followsPointer, !prefersReducedMotion else {
            rest()
            return
        }
        guard size.width > 0, size.height > 0 else { return }
        // The pointer is over the circle, so the offset from the centre spans
        // roughly one radius: at the centre the eyes look straight out, at the
        // rim they look fully that way. No scaling factor needed.
        let next = CGSize(width: clamp(point.x / size.width * 2 - 1),
                          height: clamp(point.y / size.height * 2 - 1))
        // Set without an animation: the eyes should be where the pointer is,
        // not easing toward where it was. The return in `rest` is the part
        // worth animating, because nothing is driving it any more.
        if next != direction { direction = next }
    }

    func rest() {
        guard direction != .zero else { return }
        withAnimation(prefersReducedMotion ? nil : .easeOut(duration: 0.25)) {
            direction = .zero
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(max(value, -1), 1) }
}
