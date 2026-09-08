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
        }
    }
}

/// The offsets a reaction applies at full strength, and its shape in time.
public struct FaceImpulse: Equatable, Sendable {
    public var browAngle: Double
    public var eyeOpenness: Double
    public var mouthCurve: Double
    /// Time to reach full strength.
    public var rise: TimeInterval
    /// Time held there.
    public var hold: TimeInterval
    /// Time to fade back to the mood underneath.
    public var fall: TimeInterval

    public init(browAngle: Double, eyeOpenness: Double, mouthCurve: Double,
                rise: TimeInterval, hold: TimeInterval, fall: TimeInterval) {
        self.browAngle = browAngle
        self.eyeOpenness = eyeOpenness
        self.mouthCurve = mouthCurve
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
        return result.clamped()
    }
}
