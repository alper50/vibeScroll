import AppKit
import SwiftUI
import VibeScrollCore

/// Plays a reaction over the mood.
///
/// Lives beside `BlinkModel` and for the same reason: a reaction is not a
/// change of mood, so routing it through the published expression would
/// republish the mood to say something the mood is not saying. Both are read
/// inside `AnimatedFace`, which is what keeps the material circle out of every
/// frame — that isolation was measured at 0.85% of a core.
@MainActor
final class ReactionModel: ObservableObject {
    static let shared = ReactionModel()

    @Published private(set) var impulse: FaceImpulse?
    /// 0 at rest, 1 at the peak.
    @Published private(set) var strength: Double = 0

    private var pending: [DispatchWorkItem] = []

    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Reacts to a state change, if it is one worth reacting to.
    ///
    /// Only transitions, never the state itself: a session that is already
    /// waiting when the app launches has not just started waiting, and a face
    /// that startles at everything it finds is a face nobody reads.
    func note(transition before: AgentState?, to after: AgentState) {
        guard before != after else { return }
        switch after {
        case .waiting:
            fire(.noticed)
            // People blink when something startles them, and the lid arriving
            // before the eyes go wide is most of what makes a startle read as
            // one. Fired here rather than inside `fire`, because only this
            // reaction is a startle — a turn finishing is good news, not a jolt.
            BlinkModel.shared.blinkNow()
        case .done:
            fire(.pleased)
        default:
            break
        }
    }

    func noteRateLimit() { fire(.winced) }

    /// The face was clicked. Fires whichever way the session list is about to
    /// go: opening it and putting it away are both somebody addressing the
    /// face, and it should answer either way.
    func noteClick() { fire(.greeted) }

    func fire(_ reaction: FaceReaction) {
        guard !prefersReducedMotion else { return }
        // A new reaction replaces whatever was playing rather than queueing.
        // Two agents finishing together is one event to a person watching.
        cancelPending()

        let impulse = reaction.impulse
        self.impulse = impulse

        // A spring rather than an ease, so the impulse passes its mark and
        // comes back. A muscle does not arrive at a target and stop; an ease
        // does, which is why the old version read as interpolation. The
        // overshoot is bounded by `FaceImpulse.maxOvershoot`, not by this curve.
        withAnimation(.spring(response: impulse.rise * 1.7, dampingFraction: 0.62)) {
            strength = 1
        }

        let peakEnds = impulse.rise + impulse.hold
        if impulse.hasAfterglow {
            // Down to the afterglow, wait there, and only then let go. Two
            // gentle moves rather than one drop, because the level is the whole
            // point: the face is still reacting while it sits at it, which is
            // what a smile does and what dropping straight to the mood did not.
            schedule(after: peakEnds) { [weak self] in
                withAnimation(.easeInOut(duration: impulse.decay)) {
                    self?.strength = impulse.afterglow
                }
            }
            schedule(after: peakEnds + impulse.decay + impulse.linger) { [weak self] in
                withAnimation(.easeInOut(duration: impulse.fall)) { self?.strength = 0 }
            }
        } else {
            schedule(after: peakEnds) { [weak self] in
                withAnimation(.easeInOut(duration: impulse.fall)) { self?.strength = 0 }
            }
        }
        // Cleared only once the fade has finished, so the expression it was
        // being added to stays put until there is nothing left to add.
        schedule(after: impulse.total + 0.05) { [weak self] in
            guard let self, self.strength == 0 else { return }
            self.impulse = nil
        }
    }

    private func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        pending.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelPending() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
    }
}
