import Foundation

/// Where the tongue is, as opposed to how far out it is.
///
/// How far out is the mood — `FaceExpression.tongue`, which follows how hard
/// the agents are working. This is the fidget on top of it, and it lives apart
/// for the same reason the blink does: moving the tip is not a change of mood,
/// and routing it through the expression would republish the whole face for
/// every twitch.
public struct TonguePose: Equatable, Sendable {
    /// -1 the tip at the left corner of the mouth … +1 the right.
    public var side: Double
    /// How far it reaches past the lip, as a multiple of the mood's amount.
    /// Below 1 it is drawn back in; a little above, it pushes out.
    public var reach: Double
    /// -1 … +1, how far the tip leans. Follows `side` loosely: a tongue parked
    /// in a corner points into it.
    public var tilt: Double

    public init(side: Double = 0, reach: Double = 1, tilt: Double = 0) {
        self.side = side
        self.reach = reach
        self.tilt = tilt
    }

    public static let rest = TonguePose()
}

/// When the tongue moves and how.
///
/// A tongue held perfectly still reads as a sticker on the face rather than as
/// concentration — the real thing is never still for long: it creeps to a
/// corner of the mouth, works at something, goes back in for a moment and comes
/// out again. Those three are the gestures here.
///
/// Gestures rather than a continuous drift, and short ones: any animation over
/// the face re-blurs the material orb behind it for as long as it runs, so the
/// tongue moves for well under a second and then holds still for several —
/// the same trade the blink makes.
///
/// Pure, with the randomness passed in as 0...1 samples, so the choreography
/// can be asserted rather than watched.
public enum TongueMotion {

    public enum Gesture: Equatable, Sendable, CaseIterable {
        /// Moves to a corner, or back to the middle, and stays there.
        case shift
        /// A quick left-right working of the tip, then back where it was.
        case wiggle
        /// Drawn most of the way in and pushed back out — the moment of
        /// swallowing a thought.
        case withdraw
    }

    /// One step: the pose to move to and how long to take getting there.
    public struct Keyframe: Equatable, Sendable {
        public let pose: TonguePose
        public let duration: TimeInterval
    }

    /// A lively face fidgets more often than a spent one.
    static let briskInterval: TimeInterval = 2.6
    static let wearyInterval: TimeInterval = 6.0
    static let jitterFraction: Double = 0.5

    /// Gap before the next gesture. `jitter` is a 0...1 sample.
    public static func interval(energy: Double, jitter: Double) -> TimeInterval {
        let energy = clamped(energy)
        let base = wearyInterval + (briskInterval - wearyInterval) * energy
        let spread = base * jitterFraction
        return base - spread / 2 + spread * clamped(jitter)
    }

    /// Which gesture comes next. Shifting is the commonest — it is what makes
    /// the resting position vary — and the withdraw the rarest, because it is
    /// the most noticeable.
    public static func gesture(sample: Double) -> Gesture {
        switch clamped(sample) {
        case ..<0.5:  return .shift
        case ..<0.8:  return .wiggle
        default:      return .withdraw
        }
    }

    /// How far a parked tongue sits from the middle. Never all the way: a tip
    /// at the very corner has nowhere left to go for the next wiggle.
    static let cornerReach = 0.4...0.85

    /// The steps for one gesture, starting from `pose`.
    ///
    /// `a` and `b` are 0...1 samples: `a` picks the destination of a shift and
    /// the direction of a wiggle, `b` how far. A slower face moves slower —
    /// every duration stretches as energy drops.
    public static func keyframes(
        for gesture: Gesture, from pose: TonguePose, energy: Double, a: Double, b: Double
    ) -> [Keyframe] {
        let pace = 1 + (1 - clamped(energy)) * 0.6
        switch gesture {
        case .shift:
            // Back to the middle about a third of the time, otherwise to a
            // corner — the other one if it is already parked in one, so the
            // shift is always visibly a move.
            let target: Double
            if clamped(a) < 0.34, pose.side != 0 {
                target = 0
            } else {
                let direction: Double = pose.side == 0 ? (clamped(a) < 0.67 ? -1 : 1)
                                                       : (pose.side > 0 ? -1 : 1)
                let span = cornerReach.upperBound - cornerReach.lowerBound
                target = direction * (cornerReach.lowerBound + span * clamped(b))
            }
            let settled = TonguePose(side: target, reach: 1, tilt: target * 0.7)
            return [Keyframe(pose: settled, duration: 0.55 * pace)]

        case .wiggle:
            // Two small swings either side of where it is, and home. Kept
            // inside the mouth: a swing past the corner would push the tip out
            // through the cheek.
            let swing = 0.22 + 0.18 * clamped(b)
            let first: Double = clamped(a) < 0.5 ? -1 : 1
            func at(_ offset: Double) -> TonguePose {
                let side = min(max(pose.side + offset, -1), 1)
                return TonguePose(side: side, reach: 1.08, tilt: side * 0.7 + offset * 0.8)
            }
            let beat = 0.12 * pace
            return [
                Keyframe(pose: at(first * swing), duration: beat),
                Keyframe(pose: at(-first * swing), duration: beat * 1.3),
                Keyframe(pose: at(first * swing * 0.6), duration: beat * 1.2),
                Keyframe(pose: pose, duration: beat * 1.4),
            ]

        case .withdraw:
            // In fast, out slower — the same asymmetry as a lid, and for the
            // same reason: equal halves read as a mechanism.
            let drawn = TonguePose(side: pose.side * 0.5, reach: 0.25 + 0.15 * clamped(b),
                                   tilt: pose.tilt * 0.5)
            return [
                Keyframe(pose: drawn, duration: 0.18 * pace),
                Keyframe(pose: pose, duration: 0.42 * pace),
            ]
        }
    }

    /// Below this much tongue there is nothing worth moving, and the schedule
    /// idles rather than animating a shape that draws nothing.
    public static let visibleAbove = 0.05

    private static func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}
