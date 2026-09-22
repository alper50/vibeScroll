import CoreGraphics
import Foundation

/// When the eyes flick, and where to.
///
/// Between blinks the face is otherwise motionless, and eyes parked dead centre
/// are the single thing that makes it read as a diagram rather than a face.
/// Real eyes do not drift — they fixate, jump, and fixate again — which is
/// lucky, because a drift needs a continuous animation and this app measured
/// one of those at twelve times its whole idle cost. A jump is an event, so it
/// rides the same cheap pattern the blink already uses.
///
/// Pure and with the randomness supplied, like `BlinkRhythm`: the amplitudes
/// below decide whether this reads as alive or as twitchy, and a number tuned
/// by watching is a number nobody can check.
public enum SaccadeRhythm {

    /// A lively face resettles this often…
    static let briskInterval: TimeInterval = 2.4
    /// …and a spent one lets its gaze sit.
    static let wearyInterval: TimeInterval = 7.0
    /// Spread around the base, as a fraction of it.
    static let jitterFraction: Double = 0.5

    /// How far a flick may land from centre, as a fraction of the full gaze
    /// range the pointer can command.
    ///
    /// Deliberately a third. The pointer moving the eyes is the face *looking
    /// at something*; this is only the eyes not being welded in place, and at
    /// full range it would read as the face scanning the room.
    public static let maxOffset: Double = 0.32

    /// How long the jump takes. Saccades are the fastest movement a body makes,
    /// and easing one reads as the eye being dragged.
    public static let moveDuration: TimeInterval = 0.07

    /// How often a flick returns to centre instead of finding a new point.
    /// Without it the gaze random-walks away and settles in a corner.
    static let recentreChance: Double = 0.42

    /// Gap before the next flick. Slower when spent, for the same reason the
    /// blink is.
    public static func interval(energy: Double, jitter: Double) -> TimeInterval {
        let energy = clamped(energy)
        let base = wearyInterval + (briskInterval - wearyInterval) * energy
        let spread = base * jitterFraction
        return base - spread / 2 + spread * clamped(jitter)
    }

    /// Where to look next.
    ///
    /// `x` and `y` are 0...1 samples and `recentre` decides whether this one
    /// goes home. The vertical reach is deliberately shorter than the
    /// horizontal: eyes range further side to side than up and down, and a face
    /// looking straight up is a face doing something rather than idling.
    public static func target(x: Double, y: Double, recentre: Double) -> CGSize {
        guard clamped(recentre) >= recentreChance else { return .zero }
        let dx = (clamped(x) * 2 - 1) * maxOffset
        let dy = (clamped(y) * 2 - 1) * maxOffset * 0.6
        return CGSize(width: dx, height: dy)
    }

    /// A face this spent has its eyes shut; flicking them is not resting.
    /// The same threshold the blink sleeps at, so the two stop together.
    public static func sleeps(atEnergy energy: Double) -> Bool {
        BlinkRhythm.sleeps(atEnergy: energy)
    }

    private static func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}
