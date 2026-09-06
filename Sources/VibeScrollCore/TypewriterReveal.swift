import Foundation

/// Reveals a card's text progressively, the way an assistant writes it.
///
/// Pure and time-injected: the caller passes `elapsed` and gets back exactly
/// what should be on screen at that moment. Nothing here reads a clock, starts
/// a timer or touches a view, so every boundary — nothing revealed, mid-title,
/// the title/body handover, completion — is directly testable.
///
/// Title and body are treated as one continuous stream rather than two separate
/// animations: the card reads as a single document being written, and the body
/// starts the instant the title finishes with no dead pause between them.
public struct TypewriterReveal: Equatable, Sendable {

    /// Characters per second. Tuned so a full card (roughly 40 characters of
    /// title plus 280 of body) lands in about three and a half seconds — fast
    /// enough not to make the reader wait, slow enough to read as typing.
    public static let defaultRate: Double = 90

    public let title: String
    public let body: String
    public let charactersPerSecond: Double

    public init(title: String, body: String, charactersPerSecond: Double = defaultRate) {
        self.title = title
        self.body = body
        self.charactersPerSecond = charactersPerSecond
    }

    /// Counted in `Character`s, not bytes, so a multi-scalar grapheme (an emoji,
    /// a combining accent) is revealed whole instead of being split into
    /// garbage mid-animation.
    public var totalCharacters: Int { title.count + body.count }

    /// How long the whole reveal takes. The view uses this to know when to stop
    /// its timer.
    public var duration: TimeInterval {
        guard charactersPerSecond > 0 else { return 0 }
        return Double(totalCharacters) / charactersPerSecond
    }

    /// Characters revealed after `elapsed` seconds, clamped to the total.
    public func revealedCount(after elapsed: TimeInterval) -> Int {
        guard charactersPerSecond > 0 else { return totalCharacters }
        guard elapsed > 0 else { return 0 }
        // Compared as a Double before converting: a caller that jumps `elapsed`
        // to a huge value to skip the animation would otherwise overflow Int.
        let raw = elapsed * charactersPerSecond
        guard raw < Double(totalCharacters) else { return totalCharacters }
        return Int(raw)
    }

    /// What should be on screen after `elapsed` seconds.
    public func text(after elapsed: TimeInterval) -> Revealed {
        let revealed = revealedCount(after: elapsed)
        let titleCount = title.count
        return Revealed(
            title: String(title.prefix(revealed)),
            body: revealed > titleCount ? String(body.prefix(revealed - titleCount)) : "",
            isComplete: revealed >= totalCharacters
        )
    }

    public struct Revealed: Equatable, Sendable {
        public let title: String
        public let body: String
        public let isComplete: Bool

        public init(title: String, body: String, isComplete: Bool) {
            self.title = title
            self.body = body
            self.isComplete = isComplete
        }
    }
}
