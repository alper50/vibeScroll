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
        closeDuration(energy: energy) + openDuration(energy: energy)
    }

    /// How much of a blink is the lid going down.
    ///
    /// A lid drops faster than it lifts — roughly one part closing to two parts
    /// opening. Splitting the total evenly is what anyone writes first, and it
    /// is the single thing that makes a blink read as a shutter rather than an
    /// eyelid. The asymmetry costs nothing: it is the same animation with the
    /// halves sized differently.
    static let closeShare: Double = 0.34

    private static func total(energy: Double) -> TimeInterval {
        0.26 - 0.12 * clamped(energy)
    }

    public static func closeDuration(energy: Double) -> TimeInterval {
        total(energy: energy) * closeShare
    }

    public static func openDuration(energy: Double) -> TimeInterval {
        total(energy: energy) * (1 - closeShare)
    }

    /// How often a blink comes as a pair.
    ///
    /// People double-blink constantly. Without it the rhythm reads as metronomic
    /// even with the interval jittered, because every blink is the same shape —
    /// jitter varies the gaps, this varies the blinks themselves.
    static let doubleChance: Double = 0.18

    /// Gap between the two, lid-open to lid-closing again.
    public static let doubleGap: TimeInterval = 0.11

    /// Whether this blink is a pair. `sample` is a 0...1 the caller supplies,
    /// for the same reason `interval` takes its jitter: a rhythm decided by a
    /// private random number is one that gets tuned by guesswork.
    public static func isDouble(sample: Double) -> Bool {
        clamped(sample) < doubleChance
    }

    /// How far into a reaction the lid stops interrupting.
    ///
    /// Nobody blinks mid-startle: the eyes are doing something, and a lid
    /// arriving across it reads as a glitch rather than as two things at once.
    /// Only the *scheduled* blink answers to this — a startle fires its own,
    /// which is part of the startle rather than an interruption of it.
    public static let suppressedAboveReaction: Double = 0.3

    private static func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}
