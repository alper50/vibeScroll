import Foundation

/// When the face blinks and how long the lid takes.
///
/// Pure, and the randomness enters as a parameter rather than being drawn
/// inside: a rhythm that cannot be tested is one that gets tuned by guesswork.
///
/// Blinking is the difference between a face and a diagram. It is also the one
/// part that runs forever, so the numbers below are chosen to be unobtrusive
/// rather than lifelike — a face on a panel you are not looking at should not
/// be competing for attention.
public enum BlinkRhythm {

    /// A lively face blinks about as often as a person at rest.
    static let briskInterval: TimeInterval = 3.4
    /// A spent one lets it go longer.
    static let wearyInterval: TimeInterval = 8.0

    /// Spread around the base interval, as a fraction of it. A perfectly
    /// regular blink reads as a metronome, which is worse than none at all.
    static let jitterFraction: Double = 0.45

    /// Gap before the next blink.
    ///
    /// `jitter` is a 0...1 sample the caller supplies, so the same input always
    /// produces the same rhythm and the spread can be asserted rather than
    /// observed.
    public static func interval(energy: Double, jitter: Double) -> TimeInterval {
        let energy = clamped(energy)
        let base = wearyInterval + (briskInterval - wearyInterval) * energy
        let spread = base * jitterFraction
        return base - spread / 2 + spread * clamped(jitter)
    }

    /// Below this the face is asleep and does not blink at all. A shut eye that
    /// keeps twitching is not resting — and the blink is the app's only
    /// continuous animation, so stopping it is also the one place where less
    /// life on screen costs measurably less power.
    public static let sleepingBelow = 0.12

    public static func sleeps(atEnergy energy: Double) -> Bool {
        energy <= sleepingBelow
    }

    /// How long a single blink takes, close and open together. A tired lid is
    /// slower to lift, which reads as weariness without touching the mood.
    public static func duration(energy: Double) -> TimeInterval {
        0.26 - 0.12 * clamped(energy)
    }

    private static func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}
