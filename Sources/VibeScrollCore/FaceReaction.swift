import Foundation

/// A brief reaction to something that just happened.
///
/// The expression is all trend: it reports minutes-long conditions and moves
/// over most of a second. Nothing in it registers a *moment*. An agent that
/// stops and waits for you is a moment, and a face that only eases into a new
/// resting position half a second later has not noticed it.
///
/// Reactions ride on top of the mood rather than replacing it, the same way a
/// blink does — the mood underneath is still true while the face reacts to
/// something on the surface of it.
public enum FaceReaction: Equatable, Sendable, CaseIterable {
    /// An agent stopped and needs you.
    case noticed
    /// An agent finished its turn.
    case pleased
    /// A rate limit. Not a mood change — the fatigue signal already carries the
    /// pattern — but the moment itself is worth a flinch.
    case winced
    /// Somebody clicked the face.
    ///
    /// The other three are reactions to the agents; this one is a reaction to
    /// *you*, and it is the only thing in the app that answers a direct poke.
    /// A control that does nothing visible until its side effect lands feels
    /// broken even when it worked, which is most of why it is here.
    case greeted

    /// How far the face is pushed at the peak, and for how long.
    ///
    /// Deliberately small. These are punctuation on an ambient surface, not
    /// performances; anything larger reads as a cartoon and starts competing
    /// for attention the face is supposed to save you.
    public var impulse: FaceImpulse {
        switch self {
        case .noticed:
            return FaceImpulse(browAngle: 0.5, eyeOpenness: 0.35, mouthCurve: -0.1,
                               rise: 0.12, hold: 0.35, fall: 0.45)
        // Good news does not leave a face the instant it lands. The grin peaks,
        // loosens into a smile, and is still faintly there a second later.
        case .pleased:
            return FaceImpulse(browAngle: 0.2, eyeOpenness: -0.25, mouthCurve: 0.5,
                               rise: 0.16, hold: 0.4,
                               afterglow: 0.35, decay: 0.3, linger: 0.5,
                               fall: 0.55)
        case .winced:
            return FaceImpulse(browAngle: -0.45, eyeOpenness: -0.5, mouthCurve: -0.35,
                               rise: 0.08, hold: 0.25, fall: 0.5)
        // The quickest of the four to *arrive*, and the only one that opens the
        // mouth: a small "oh" on being addressed. Arriving fast is what makes
        // it read as a reply — but leaving just as fast made it read as a
        // twitch, so the grin relaxes into a smile and takes its time going.
        case .greeted:
            return FaceImpulse(browAngle: 0.35, eyeOpenness: 0.3, mouthCurve: 0.4,
                               mouthOpen: 0.3,
                               rise: 0.07, hold: 0.2,
                               afterglow: 0.45, decay: 0.32, linger: 0.75,
                               fall: 0.6)
        }
    }
}

/// The offsets a reaction applies at full strength, and its shape in time.
///
/// The envelope has an optional middle. A reaction either drops straight back
/// to the mood (rise → hold → fall), or relaxes to a lower `afterglow` level
/// and sits there for `linger` before letting go (rise → hold → decay → linger
/// → fall). Warm reactions want the second shape: an expression that vanishes
/// the instant it peaked reads as a sprite being swapped out, while one that
/// loosens and fades from there reads as somebody reacting to you.
public struct FaceImpulse: Equatable, Sendable {
    public var browAngle: Double
    public var eyeOpenness: Double
    public var mouthCurve: Double
    /// Kept separate from `mouthCurve` so a reaction can open the mouth without
    /// also smiling. Defaults to nothing, which is what the three reactions
    /// written before it want.
    public var mouthOpen: Double
    /// Time to reach full strength.
    public var rise: TimeInterval
    /// Time held there.
    public var hold: TimeInterval
    /// How much of the impulse is still applied once the peak has passed, 0…1.
    /// Zero means the reaction has no tail and `decay`/`linger` are skipped,
    /// which is what a flinch wants.
    public var afterglow: Double
    /// Time to relax from the peak down to `afterglow`.
    public var decay: TimeInterval
    /// Time spent sitting at `afterglow` before letting go of it.
    public var linger: TimeInterval
    /// Time to fade the rest of the way back to the mood underneath.
    public var fall: TimeInterval

    public init(browAngle: Double, eyeOpenness: Double, mouthCurve: Double,
                mouthOpen: Double = 0,
                rise: TimeInterval, hold: TimeInterval,
                afterglow: Double = 0, decay: TimeInterval = 0, linger: TimeInterval = 0,
                fall: TimeInterval) {
        self.browAngle = browAngle
        self.eyeOpenness = eyeOpenness
        self.mouthCurve = mouthCurve
        self.mouthOpen = mouthOpen
        self.rise = rise
        self.hold = hold
        self.afterglow = afterglow
        self.decay = decay
        self.linger = linger
        self.fall = fall
    }

    /// Whether the reaction relaxes through a lower level on its way out.
    ///
    /// The one place that decides it, so the player and `total` cannot disagree
    /// about which phases exist — a mismatch there would clear the impulse
    /// while the face was still wearing it.
    public var hasAfterglow: Bool { afterglow > 0 && (decay > 0 || linger > 0) }

    public var total: TimeInterval {
        hasAfterglow ? rise + hold + decay + linger + fall : rise + hold + fall
    }

    /// The furthest past full strength a reaction may be carried.
    ///
    /// The player animates `strength` with a spring, which overshoots on its
    /// way to 1. Allowing a quarter of the impulse again is enough to read as
    /// muscle; more starts reading as a performance, which is the thing these
    /// are explicitly not.
    public static let maxOvershoot: Double = 1.25
}

public extension FaceExpression {
    /// The mood with a reaction laid over it.
    ///
    /// `strength` is 0 at rest and 1 at the peak, so the caller animates one
    /// number and the shape of the reaction stays here. Clamped once at the
    /// end, like the pressures — a startle on an already wide-eyed face must
    /// not open the eyes past 1 and then come back down from somewhere the
    /// face was never at.
    func applying(_ impulse: FaceImpulse, strength: Double) -> FaceExpression {
        // Overshoot is allowed past the peak, because a muscle does not arrive
        // at its target and stop — it passes it and comes back, and a reaction
        // that lands exactly on its mark reads as interpolation. The final
        // `clamped()` still keeps the face in range; this ceiling is only so a
        // mis-tuned spring cannot turn a flinch into a cartoon.
        let amount = min(max(strength, 0), FaceImpulse.maxOvershoot)
        guard amount > 0 else { return self }
        var result = self
        result.browAngle += impulse.browAngle * amount
        result.eyeOpenness += impulse.eyeOpenness * amount
        result.mouthCurve += impulse.mouthCurve * amount
        result.mouthOpen += impulse.mouthOpen * amount
        return result.clamped()
    }
}
