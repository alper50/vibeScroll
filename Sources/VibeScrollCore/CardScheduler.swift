import Foundation

/// Decides *whether* to surface a card right now and *which* one.
///
/// Two vocabularies meet here. The *when* is driven by the agent's activity
/// (`TopicCategory`); the *which* is drawn from the catalogue (`CardCategory`).
/// They are independent on purpose — what the agent is doing sets the rhythm,
/// not the subject.
///
/// The failure mode this exists to prevent: an agent fires tool events several
/// times a second, so a naive "topic changed → show a card" would strobe. Four
/// gates, all deterministic and `now`-injected so every rule is unit-testable:
///
///  1. **Dwell** — the topic must have been stable for `minimumDwell` before it
///     counts as "what the user is actually doing".
///  2. **Global cooldown** — a minimum gap between any two cards, whatever the
///     topic, so the surface never feels chatty.
///  3. **Per-topic cooldown** — the same activity can't trigger again for a
///     while, so a long debugging stretch is one card, not one every gap.
///  4. **Card repeat window** — a specific card id isn't shown twice inside
///     `cardRepeatWindow`, so the user sees the whole pool before repeats.
///
/// Two kinds of state, kept deliberately apart. The pacing gates (last card,
/// last card per activity) live in memory: a restart earning one extra card is
/// a fair trade. What has been *read* (`history`) is handed in and read back
/// out so the app can keep it on disk — losing it meant every relaunch started
/// the catalogue over from the same first card, which is the one thing a
/// reader notices immediately.
public final class CardScheduler {

    public struct Policy: Sendable, Equatable {
        /// How long a topic must hold before it can trigger a card.
        public var minimumDwell: TimeInterval
        /// Minimum gap between any two cards.
        public var globalCooldown: TimeInterval
        /// Minimum gap between two cards triggered by the same activity.
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
    private let orderSeed: UInt64

    /// - Parameters:
    ///   - history: when each card was last shown, as saved from a previous run.
    ///   - orderSeed: fixes the order unseen cards come in. One value per
    ///     install, so the order is stable from call to call and launch to
    ///     launch, but is not the alphabetical order of card ids — which put
    ///     every Breaking Bad card ahead of everything else.
    public init(policy: Policy = Policy(), history: [String: Date] = [:], orderSeed: UInt64 = 0) {
        self.policy = policy
        self.lastShownAt = history
        self.orderSeed = orderSeed
    }

    /// When each card was last shown — the part worth saving across launches.
    public var history: [String: Date] { lastShownAt }

    /// `history` without entries older than `keepFor`. Bounds what is kept
    /// on disk once cards are retired from the catalogue: nothing is lost by
    /// forgetting a card that was shown three months ago, it simply counts as
    /// unseen again.
    public static func pruned(
        _ history: [String: Date], now: Date, keepFor: TimeInterval = 90 * 24 * 3600
    ) -> [String: Date] {
        history.filter { now.timeIntervalSince($0.value) <= keepFor }
    }

    public func update(policy: Policy) {
        self.policy = policy
    }

    /// Clears the pacing gates (e.g. the user re-enabled cards after muting).
    ///
    /// Not the reading history: turning cards off and on again is not a
    /// reason to be shown the same cards again.
    public func reset() {
        lastCardAt = nil
        lastTopicAt.removeAll()
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
    /// Three keys, in order:
    ///  1. When the card was last shown — never-shown first, then oldest.
    ///  2. When its *show* was last shown, so among cards equally unseen the
    ///     shows take turns instead of one show's whole run coming first.
    ///  3. The install's shuffled order (`orderSeed`), then the id — never a
    ///     tie left open, so the same state always gives the same card and
    ///     the surface cannot flicker between two.
    public func leastRecentlyShown(in candidates: [InfoCard], now: Date) -> InfoCard? {
        var showLastSeen: [CardCategory: Date] = [:]
        for card in candidates {
            guard let shown = lastShownAt[card.id] else { continue }
            showLastSeen[card.category] = max(showLastSeen[card.category] ?? .distantPast, shown)
        }
        return candidates.min { a, b in
            let shownA = lastShownAt[a.id] ?? .distantPast
            let shownB = lastShownAt[b.id] ?? .distantPast
            if shownA != shownB { return shownA < shownB }
            let showA = showLastSeen[a.category] ?? .distantPast
            let showB = showLastSeen[b.category] ?? .distantPast
            if showA != showB { return showA < showB }
            let keyA = Self.orderKey(a.id, seed: orderSeed)
            let keyB = Self.orderKey(b.id, seed: orderSeed)
            return keyA != keyB ? keyA < keyB : a.id < b.id
        }
    }

    /// A stable pseudo-random rank for a card: FNV-1a over the seed and the id.
    ///
    /// Written out rather than using `Hasher`, which Swift re-seeds on every
    /// launch — the order would change each time the app started, which is
    /// the opposite of the point.
    static func orderKey(_ id: String, seed: UInt64) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        withUnsafeBytes(of: seed.littleEndian) { $0.forEach(mix) }
        id.utf8.forEach(mix)
        return hash
    }

    /// Manual navigation ("Next"), which answers to none of the pacing gates —
    /// the user asked for the next card, so they get one.
    ///
    /// Three tiers, in order:
    ///  1. Unseen material in `category`, so browsing stays on the show being
    ///     read.
    ///  2. Unseen material anywhere else, once that category is exhausted.
    ///  3. The least recently shown card of all, ignoring repeat windows.
    ///
    /// Tier 3 is what stops the button dead-ending: once the user has seen the
    /// whole catalogue, Next cycles the oldest material rather than going inert.
    /// Returns `nil` only when there is genuinely nothing else to show.
    public func advance(
        from all: [InfoCard], category: CardCategory?, excluding currentID: String?, now: Date
    ) -> InfoCard? {
        let pool = all.filter { $0.id != currentID }
        guard !pool.isEmpty else { return nil }

        if let category {
            if let hit = pick(from: pool.filter { $0.category == category }, now: now) { return hit }
            if let hit = pick(from: pool.filter { $0.category != category }, now: now) { return hit }
        } else if let hit = pick(from: pool, now: now) {
            return hit
        }
        return leastRecentlyShown(in: pool, now: now)
    }

    /// Records that `card` was actually shown. Must be called by the presenter,
    /// not by `pick`, so a card that was selected but suppressed downstream
    /// (window hidden, user muted) doesn't burn its repeat window.
    ///
    /// `topic` is the activity that triggered it, and starts that activity's
    /// cooldown. A card the user browsed to has none: reading is not the agent
    /// doing anything, so it holds back the global gap but no topic.
    public func recordShown(_ card: InfoCard, topic: TopicCategory? = nil, now: Date) {
        lastCardAt = now
        if let topic { lastTopicAt[topic] = now }
        lastShownAt[card.id] = now
    }

    /// Convenience: gate, pick and record in one call. Returns the card to show,
    /// or `nil` if any gate blocked it.
    public func next(
        topic: TopicCategory, topicSince: Date, candidates: [InfoCard], now: Date
    ) -> InfoCard? {
        guard mayShow(topic: topic, topicSince: topicSince, now: now) else { return nil }
        guard let card = pick(from: candidates, now: now) else { return nil }
        recordShown(card, topic: topic, now: now)
        return card
    }
}
