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
        case .pleased:
            return FaceImpulse(browAngle: 0.2, eyeOpenness: -0.25, mouthCurve: 0.5,
                               rise: 0.16, hold: 0.5, fall: 0.6)
        case .winced:
            return FaceImpulse(browAngle: -0.45, eyeOpenness: -0.5, mouthCurve: -0.35,
                               rise: 0.08, hold: 0.25, fall: 0.5)
        // The quickest of the four, and the only one that opens the mouth: a
        // small "oh" on being addressed. The speed is the point — a reply to a
        // click that takes as long as a mood change does not read as a reply.
        case .greeted:
            return FaceImpulse(browAngle: 0.35, eyeOpenness: 0.3, mouthCurve: 0.35,
                               mouthOpen: 0.3,
                               rise: 0.07, hold: 0.14, fall: 0.3)
        }
    }
}

/// The offsets a reaction applies at full strength, and its shape in time.
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
    /// Time to fade back to the mood underneath.
    public var fall: TimeInterval

    public init(browAngle: Double, eyeOpenness: Double, mouthCurve: Double,
                mouthOpen: Double = 0,
                rise: TimeInterval, hold: TimeInterval, fall: TimeInterval) {
        self.browAngle = browAngle
        self.eyeOpenness = eyeOpenness
        self.mouthCurve = mouthCurve
        self.mouthOpen = mouthOpen
        self.rise = rise
        self.hold = hold
        self.fall = fall
    }

    public var total: TimeInterval { rise + hold + fall }
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
        let amount = min(max(strength, 0), 1)
        guard amount > 0 else { return self }
        var result = self
        result.browAngle += impulse.browAngle * amount
        result.eyeOpenness += impulse.eyeOpenness * amount
        result.mouthCurve += impulse.mouthCurve * amount
        result.mouthOpen += impulse.mouthOpen * amount
        return result.clamped()
    }
}
