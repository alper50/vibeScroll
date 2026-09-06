import Foundation

/// Decides *whether* to surface a card right now and *which* one.
///
/// The failure mode this exists to prevent: an agent fires tool events several
/// times a second, so a naive "topic changed → show a card" would strobe. Four
/// gates, all deterministic and `now`-injected so every rule is unit-testable:
///
///  1. **Dwell** — the topic must have been stable for `minimumDwell` before it
///     counts as "what the user is actually doing".
///  2. **Global cooldown** — a minimum gap between any two cards, whatever the
///     topic, so the surface never feels chatty.
///  3. **Per-topic cooldown** — the same topic can't teach again for a while.
///  4. **Card repeat window** — a specific card id isn't shown twice inside
///     `cardRepeatWindow`, so the user sees the whole pool before repeats.
///
/// State is intentionally in-memory: a restart earning the user one extra card
/// is a better trade than persisting a schedule that can go stale.
public final class CardScheduler {

    public struct Policy: Sendable, Equatable {
        /// How long a topic must hold before it can trigger a card.
        public var minimumDwell: TimeInterval
        /// Minimum gap between any two cards.
        public var globalCooldown: TimeInterval
        /// Minimum gap between two cards of the same topic.
        public var topicCooldown: TimeInterval
        /// How long a specific card id stays suppressed after being shown.
        public var cardRepeatWindow: TimeInterval

        public init(
            minimumDwell: TimeInterval = 8,
            globalCooldown: TimeInterval = 90,
            topicCooldown: TimeInterval = 900,
            cardRepeatWindow: TimeInterval = 6 * 3600
        ) {
            self.minimumDwell = minimumDwell
            self.globalCooldown = globalCooldown
            self.topicCooldown = topicCooldown
            self.cardRepeatWindow = cardRepeatWindow
        }

        /// Everything off. For the settings preview and for tests that only care
        /// about selection, not pacing.
        public static let unthrottled = Policy(
            minimumDwell: 0, globalCooldown: 0, topicCooldown: 0, cardRepeatWindow: 0
        )
    }

    public private(set) var policy: Policy
    private var lastCardAt: Date?
    private var lastTopicAt: [TopicCategory: Date] = [:]
    private var lastShownAt: [String: Date] = [:]

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    public func update(policy: Policy) {
        self.policy = policy
    }

    /// Clears all pacing state (e.g. the user re-enabled cards after muting).
    public func reset() {
        lastCardAt = nil
        lastTopicAt.removeAll()
        lastShownAt.removeAll()
    }

    /// Whether `topic` may show a card now. `topicSince` is when the session
    /// entered that topic, which is what the dwell gate measures.
    public func mayShow(topic: TopicCategory, topicSince: Date, now: Date) -> Bool {
        guard now.timeIntervalSince(topicSince) >= policy.minimumDwell else { return false }
        if let last = lastCardAt, now.timeIntervalSince(last) < policy.globalCooldown { return false }
        if let last = lastTopicAt[topic], now.timeIntervalSince(last) < policy.topicCooldown {
            return false
        }
        return true
    }

    /// Picks the least recently shown eligible card, so the pool cycles instead
    /// of favouring whatever the backend happened to list first. Returns `nil`
    /// when every candidate is still inside its repeat window.
    public func pick(from candidates: [InfoCard], now: Date) -> InfoCard? {
        let eligible = candidates.filter { card in
            guard let shown = lastShownAt[card.id] else { return true }
            return now.timeIntervalSince(shown) >= policy.cardRepeatWindow
        }
        return leastRecentlyShown(in: eligible, now: now)
    }

    /// Least recently shown card, ignoring the repeat window entirely. Returns
    /// `nil` only for an empty list.
    ///
    /// Never-shown cards sort ahead of ever-shown ones (`distantPast`), then
    /// oldest-shown first. Ties break on id, so repeated calls with the same
    /// state can never return a different card and flicker the surface.
    public func leastRecentlyShown(in candidates: [InfoCard], now: Date) -> InfoCard? {
        candidates.min {
            let a = lastShownAt[$0.id] ?? .distantPast
            let b = lastShownAt[$1.id] ?? .distantPast
            return a == b ? $0.id < $1.id : a < b
        }
    }

    /// Manual navigation ("Next"), which answers to none of the pacing gates —
    /// the user asked for the next card, so they get one.
    ///
    /// Three tiers, in order:
    ///  1. Unseen material in `topic`, so browsing stays on what the agent is
    ///     actually doing.
    ///  2. Unseen material anywhere else, once the topic is exhausted.
    ///  3. The least recently shown card of all, ignoring repeat windows.
    ///
    /// Tier 3 is what stops the button dead-ending: once the user has seen the
    /// whole catalogue, Next cycles the oldest material rather than going inert.
    /// Returns `nil` only when there is genuinely nothing else to show.
    public func advance(
        from all: [InfoCard], topic: TopicCategory?, excluding currentID: String?, now: Date
    ) -> InfoCard? {
        let pool = all.filter { $0.id != currentID }
        guard !pool.isEmpty else { return nil }

        if let topic {
            if let hit = pick(from: pool.filter { $0.category == topic }, now: now) { return hit }
            if let hit = pick(from: pool.filter { $0.category != topic }, now: now) { return hit }
        } else if let hit = pick(from: pool, now: now) {
            return hit
        }
        return leastRecentlyShown(in: pool, now: now)
    }

    /// Records that `card` was actually shown. Must be called by the presenter,
    /// not by `pick`, so a card that was selected but suppressed downstream
    /// (window hidden, user muted) doesn't burn its repeat window.
    public func recordShown(_ card: InfoCard, now: Date) {
        lastCardAt = now
        lastTopicAt[card.category] = now
        lastShownAt[card.id] = now
    }

    /// Convenience: gate, pick and record in one call. Returns the card to show,
    /// or `nil` if any gate blocked it.
    public func next(
        topic: TopicCategory, topicSince: Date, candidates: [InfoCard], now: Date
    ) -> InfoCard? {
        guard mayShow(topic: topic, topicSince: topicSince, now: now) else { return nil }
        guard let card = pick(from: candidates, now: now) else { return nil }
        recordShown(card, now: now)
        return card
    }
}
