import Foundation

/// A face as numbers rather than a named mood.
///
/// Continuous on purpose. Named moods ("tired", "worried") have to be resolved
/// against each other the moment two signals disagree — is a tired face that is
/// also overspending tired or worried? — and every answer is arbitrary. Numbers
/// simply add, so a session that is both long and over budget lands somewhere
/// between the two instead of picking a winner, and the view can interpolate
/// rather than cut.
public struct FaceExpression: Equatable, Sendable {
    /// -1 drawn together and worried … 0 level … +1 raised and alert.
    public var browAngle: Double
    /// 0 shut … 1 wide.
    public var eyeOpenness: Double
    /// -1 downturned … 0 flat … +1 smiling.
    public var mouthCurve: Double
    /// 0 at ease … 1 visibly under it. Drives whatever the view uses to show
    /// tension, rather than overloading the mouth with two meanings.
    public var strain: Double
    /// 0 barely there … 1 lively. Sets blink rate and how briskly the face
    /// moves, so a spent session reads as slow rather than merely sad.
    public var energy: Double

    public init(
        browAngle: Double = 0, eyeOpenness: Double = 0.8,
        mouthCurve: Double = 0, strain: Double = 0, energy: Double = 0.7
    ) {
        self.browAngle = browAngle
        self.eyeOpenness = eyeOpenness
        self.mouthCurve = mouthCurve
        self.strain = strain
        self.energy = energy
    }

    /// Every field pulled back into range. Pressures accumulate freely and are
    /// clamped once at the end: clamping between each one would make the order
    /// they are applied in matter, which it should not.
    public func clamped() -> FaceExpression {
        FaceExpression(
            browAngle: min(max(browAngle, -1), 1),
            eyeOpenness: min(max(eyeOpenness, 0), 1),
            mouthCurve: min(max(mouthCurve, -1), 1),
            strain: min(max(strain, 0), 1),
            energy: min(max(energy, 0), 1))
    }

    /// Linear blend, for animating between two readings.
    public func blended(towards other: FaceExpression, amount: Double) -> FaceExpression {
        let t = min(max(amount, 0), 1)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return FaceExpression(
            browAngle: mix(browAngle, other.browAngle),
            eyeOpenness: mix(eyeOpenness, other.eyeOpenness),
            mouthCurve: mix(mouthCurve, other.mouthCurve),
            strain: mix(strain, other.strain),
            energy: mix(energy, other.energy))
    }
}
