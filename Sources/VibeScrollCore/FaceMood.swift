import Foundation

/// Everything the face reacts to. All of it already exists elsewhere in the
/// app; none of it is currently visible anywhere.
///
/// Accumulated dollars used to be here and are not any more. Nothing that only
/// ever goes up can drive an expression: it crosses its threshold once and the
/// face is stuck with it. See `discord`, which took the brow over.
public struct FaceInputs: Equatable, Sendable {
    public var sessions: [AgentSession]
    /// `nil` when the quota probe is off or has never succeeded.
    public var quota: QuotaSnapshot?
    /// When rate limits were seen recently, in any order.
    public var rateLimits: [Date]
    /// Tokens per minute across everything running. Derived by the caller,
    /// which is the only part of the app that keeps enough history to know it.
    public var tokensPerMinute: Double
    /// When the face was last touched. Counts as activity, so a face somebody
    /// just clicked is awake whatever the agents are doing.
    public var lastInteraction: Date?

    public init(sessions: [AgentSession] = [], quota: QuotaSnapshot? = nil,
                rateLimits: [Date] = [], tokensPerMinute: Double = 0,
                lastInteraction: Date? = nil) {
        self.sessions = sessions
        self.quota = quota
        self.rateLimits = rateLimits
        self.tokensPerMinute = tokensPerMinute
        self.lastInteraction = lastInteraction
    }
}

/// Turns what is happening into an expression.
///
/// Pure and `now`-injected, like `CardScheduler` and `TaskRunway`. The point of
/// the face is to show what a person cannot otherwise see — that spending is
/// ahead of the week, that an agent has been circling one topic for an hour,
/// that this has been a long session — so each of those is its own testable
/// function rather than a branch buried in a view.
public enum FaceMood {

    public struct Policy: Sendable, Equatable {
        /// A topic held this long stops reading as thorough…
        public var thrashBegins: TimeInterval
        /// …and by this long it reads as stuck.
        public var thrashFull: TimeInterval
        /// A session running this long starts to show…
        public var longSessionBegins: TimeInterval
        /// …and by here it is a long day.
        public var longSessionFull: TimeInterval
        /// How far back rate limits still count.
        public var rateLimitWindow: TimeInterval
        /// Rate limits inside that window for full weariness.
        public var rateLimitsForFull: Int
        /// Spending this far ahead of the clock is full pressure. 0.20 means
        /// twenty points over — 85% spent at 65% elapsed.
        public var overspendForFull: Double
        /// Quiet for this long and the face starts to settle…
        public var drowsyAfter: TimeInterval
        /// …and by here it is asleep.
        public var asleepAfter: TimeInterval
        /// This many agents at once is a full house.
        public var crowdedAt: Int
        /// Tokens per minute that counts as going flat out. A first guess,
        /// meant to be tuned by watching rather than derived.
        public var briskTokensPerMinute: Double
        /// This many sessions out of step with the rest is a full raised brow.
        public var discordAt: Int
        /// Spending this far ahead inside the five-hour window is full
        /// pressure. Looser than the weekly figure on purpose: nobody works
        /// uniformly across five hours, so being twenty points ahead at the
        /// start of one is normal rather than news.
        public var sessionOverspendForFull: Double

        public init(
            thrashBegins: TimeInterval = 20 * 60,
            thrashFull: TimeInterval = 45 * 60,
            longSessionBegins: TimeInterval = 3 * 3600,
            longSessionFull: TimeInterval = 6 * 3600,
            rateLimitWindow: TimeInterval = 3600,
            rateLimitsForFull: Int = 3,
            overspendForFull: Double = 0.20,
            drowsyAfter: TimeInterval = 5 * 60,
            asleepAfter: TimeInterval = 20 * 60,
            crowdedAt: Int = 4,
            briskTokensPerMinute: Double = 3000,
            discordAt: Int = 2,
            sessionOverspendForFull: Double = 0.35
        ) {
            self.thrashBegins = thrashBegins
            self.thrashFull = thrashFull
            self.longSessionBegins = longSessionBegins
            self.longSessionFull = longSessionFull
            self.rateLimitWindow = rateLimitWindow
            self.rateLimitsForFull = rateLimitsForFull
            self.overspendForFull = overspendForFull
            self.drowsyAfter = drowsyAfter
            self.asleepAfter = asleepAfter
            self.crowdedAt = crowdedAt
            self.briskTokensPerMinute = briskTokensPerMinute
            self.discordAt = discordAt
            self.sessionOverspendForFull = sessionOverspendForFull
        }
    }

    // MARK: - The resting face

    /// The expression before anything is weighing on it. `nil` means no
    /// sessions at all, which is asleep rather than merely idle.
    public static func base(for state: AgentState?) -> FaceExpression {
        switch state {
        case .working:    return FaceExpression(browAngle: 0.1, eyeOpenness: 0.75, mouthCurve: 0.25, energy: 0.8)
        case .waiting:    return FaceExpression(browAngle: 0.8, eyeOpenness: 1.0, mouthCurve: 0.0, strain: 0.2, energy: 0.9)
        case .done:       return FaceExpression(browAngle: 0.2, eyeOpenness: 0.85, mouthCurve: 0.9, energy: 0.7)
        case .registered: return FaceExpression(browAngle: 0.3, eyeOpenness: 0.8, mouthCurve: 0.4, energy: 0.6)
        // Level rather than slightly furrowed: a sleepy face is not a cross
        // one, and the heavy lids already carry it.
        case .idle:       return FaceExpression(browAngle: 0, eyeOpenness: 0.35, mouthCurve: 0.1, energy: 0.3)
        case nil:         return FaceExpression(browAngle: 0, eyeOpenness: 0.05, mouthCurve: 0.05, energy: 0.1)
        }
    }

    /// The session the face is about: the one most deserving of attention,
    /// which is the same order the session list already sorts by.
    static func dominantState(_ sessions: [AgentSession]) -> AgentState? {
        sessions.max { $0.state.attentionPriority < $1.state.attentionPriority }?.state
    }

    // MARK: - What is weighing on it

    /// Spending ahead of the week, 0…1.
    ///
    /// Zero when there is no reading. `TaskRunway` refuses to launch without
    /// one because the risk there is spending unsupervised; here the risk is
    /// only a wrong face, and a worried one over a budget nobody measured would
    /// be a lie.
    public static func quotaPressure(
        _ quota: QuotaSnapshot?, policy: Policy = .init(), now: Date
    ) -> Double {
        guard let quota,
              let weekly = QuotaPace.tightest(quota.windows, in: QuotaPace.weeklyKinds),
              let over = QuotaPace.overspend(weekly, now: now)
        else { return 0 }
        return ramp(over, from: 0, to: policy.overspendForFull)
    }

    /// How hard the five-hour window is being burned, 0…1.
    ///
    /// The weekly figure and this one are the same arithmetic on different
    /// clocks, and they are deliberately kept apart. Weekly is the slow worry
    /// and shows in the brow; this is the immediate one and shows as a squint,
    /// because it is the window that runs out while you are watching. It is
    /// also the window the task queue waits on, so the face and `TaskRunway`
    /// are reading the same number.
    public static func sessionPressure(
        _ quota: QuotaSnapshot?, policy: Policy = .init(), now: Date
    ) -> Double {
        guard let quota,
              let window = QuotaPace.tightest(quota.windows, in: QuotaPace.sessionKinds),
              let over = QuotaPace.overspend(window, now: now)
        else { return 0 }
        return ramp(over, from: 0, to: policy.sessionOverspendForFull)
    }

    /// How long the busiest agent has been circling one topic, 0…1.
    ///
    /// Only `working` sessions count: a session sitting in `waiting` has held
    /// its topic for as long as the person has taken to answer, which says
    /// nothing about the agent being stuck.
    public static func thrashPressure(
        _ sessions: [AgentSession], policy: Policy = .init(), now: Date
    ) -> Double {
        let longest = sessions
            .filter { $0.state == .working }
            .map { now.timeIntervalSince($0.topicSince) }
            .max() ?? 0
        return ramp(longest, from: policy.thrashBegins, to: policy.thrashFull)
    }

    /// How long this has been going on, and how badly, 0…1.
    ///
    /// Session length and rate limits are combined rather than separate because
    /// they mean the same thing to a face: keep going and it gets harder. The
    /// larger of the two wins, so three rate limits in an hour show immediately
    /// instead of waiting for the clock to catch up.
    public static func fatigue(
        _ sessions: [AgentSession], rateLimits: [Date],
        policy: Policy = .init(), now: Date
    ) -> Double {
        let oldest = sessions.map(\.createdAt).min()
        let age = oldest.map { now.timeIntervalSince($0) } ?? 0
        let fromClock = ramp(age, from: policy.longSessionBegins, to: policy.longSessionFull)

        let recent = rateLimits.filter { now.timeIntervalSince($0) <= policy.rateLimitWindow }
        let fromLimits = ramp(Double(recent.count), from: 0, to: Double(policy.rateLimitsForFull))

        return max(fromClock, fromLimits)
    }

    // MARK: - Why

    /// The strongest pressure, with the numbers behind it.
    ///
    /// The expression says something is off; this says what. A mood you cannot
    /// interrogate is decoration — "worried" is not actionable, and the four
    /// things that produce it call for four different responses.
    public enum Reason: Equatable, Sendable {
        /// Nothing is weighing on it, so the agent's own state is the story.
        case steady(AgentState?)
        case overBudget(usedPercent: Int, elapsedPercent: Int)
        case circling(topic: TopicCategory?, minutes: Int)
        case longSession(minutes: Int)
        case rateLimited(count: Int)
        case burningWindow(usedPercent: Int, minutesLeft: Int)

        /// One line, for the label under the face.
        public var summary: String {
            switch self {
            case .steady(let state):
                return state.flatMap(ActivitySummary.stateMessage(for:))
                    ?? String(localized: "Nothing running")
            case .overBudget(let used, let elapsed):
                return String(localized: "Weekly \(used)% spent, \(elapsed)% of the week gone")
            case .circling(let topic, let minutes):
                guard let topic else {
                    return String(localized: "Circling one topic for \(minutes) min")
                }
                return String(localized: "Circling \(topic.label.localizedLowercase) for \(minutes) min")
            case .longSession(let minutes):
                return minutes >= 60
                    ? String(localized: "\(minutes / 60)h \(minutes % 60)m in")
                    : String(localized: "\(minutes)m in")
            case .rateLimited(let count):
                return count == 1
                    ? String(localized: "1 rate limit this hour")
                    : String(localized: "\(count) rate limits this hour")
            case .burningWindow(let used, let minutesLeft):
                return String(localized: "5h window \(used)% spent, \(minutesLeft) min left")
            }
        }
    }

    /// Below this, nothing is worth naming and the state alone is the answer.
    /// Without a floor the label would report a trace of pressure as though it
    /// were news.
    static let minimumWorthNaming = 0.15

    public static func dominantReason(
        for inputs: FaceInputs, policy: Policy = .init(), now: Date
    ) -> Reason {
        let quota = quotaPressure(inputs.quota, policy: policy, now: now)
        let burning = sessionPressure(inputs.quota, policy: policy, now: now)
        let thrash = thrashPressure(inputs.sessions, policy: policy, now: now)
        let tired = fatigue(inputs.sessions, rateLimits: inputs.rateLimits,
                            policy: policy, now: now)

        let strongest = max(max(quota, burning), max(thrash, tired))
        guard strongest >= minimumWorthNaming else {
            return .steady(dominantState(inputs.sessions))
        }

        // Ahead of the weekly line: the five-hour window is the one that runs
        // out inside the afternoon, so when both are lit it is the one worth
        // naming — it is also the one you can do something about.
        if burning == strongest,
           let window = QuotaPace.tightest(inputs.quota?.windows ?? [], in: QuotaPace.sessionKinds) {
            let left = window.resetsAt.map { max(0, $0.timeIntervalSince(now)) } ?? 0
            return .burningWindow(usedPercent: window.percentUsed,
                                  minutesLeft: Int(left / 60))
        }
        if quota == strongest,
           let weekly = QuotaPace.tightest(inputs.quota?.windows ?? [], in: QuotaPace.weeklyKinds),
           let elapsed = QuotaPace.elapsedFraction(weekly, now: now) {
            return .overBudget(usedPercent: weekly.percentUsed,
                               elapsedPercent: Int((elapsed * 100).rounded()))
        }
        if thrash == strongest, let leader = longestWorkingTopic(inputs.sessions, now: now) {
            return .circling(topic: leader.session.topic,
                             minutes: Int(leader.age / 60))
        }
        // Fatigue is the larger of two very different causes, so the label has
        // to say which one it was rather than reporting "tired".
        let recent = inputs.rateLimits.filter { now.timeIntervalSince($0) <= policy.rateLimitWindow }
        let fromLimits = ramp(Double(recent.count), from: 0, to: Double(policy.rateLimitsForFull))
        let age = inputs.sessions.map(\.createdAt).min().map { now.timeIntervalSince($0) } ?? 0
        let fromClock = ramp(age, from: policy.longSessionBegins, to: policy.longSessionFull)

        if fromLimits >= fromClock, !recent.isEmpty {
            return .rateLimited(count: recent.count)
        }
        return .longSession(minutes: Int(age / 60))
    }

    /// The working session that has held its topic longest — the one thrash is
    /// measured from, so the label names the same session the face reacted to.
    static func longestWorkingTopic(
        _ sessions: [AgentSession], now: Date
    ) -> (session: AgentSession, age: TimeInterval)? {
        sessions
            .filter { $0.state == .working }
            .map { ($0, now.timeIntervalSince($0.topicSince)) }
            .max { $0.1 < $1.1 }
            .map { (session: $0.0, age: $0.1) }
    }

    /// How many agents are going at once, 0…1.
    ///
    /// One agent is a conversation; four at once is a room. The face opens its
    /// mouth slightly — the look of taking in more than one thing — rather than
    /// frowning, because this is busy rather than bad.
    public static func crowding(_ sessions: [AgentSession], policy: Policy = .init()) -> Double {
        let live = sessions.filter { $0.state == .working || $0.state == .waiting }.count
        return ramp(Double(live), from: 1, to: Double(policy.crowdedAt))
    }

    /// How fast tokens are going, 0…1.
    ///
    /// Shown as the tongue. Sticking it out under concentration is a real
    /// reflex and it is the one expression that reads as effort without reading
    /// as distress — which is right, because burning tokens quickly is what
    /// working looks like, not what going wrong looks like.
    public static func exertion(tokensPerMinute: Double, policy: Policy = .init()) -> Double {
        ramp(tokensPerMinute, from: policy.briskTokensPerMinute * 0.25,
             to: policy.briskTokensPerMinute)
    }

    /// How much the other sessions disagree with the one the face is about,
    /// -1…1, where the sign picks which brow goes up.
    ///
    /// A single raised brow is scepticism, and what it is sceptical about is
    /// the summary: `base` is built from one session, the loudest, so a face
    /// reporting "working" while something else sits there waiting for an
    /// answer is telling half the story. The brow is the other half.
    ///
    /// This replaced total dollars spent, which could not work: session cost
    /// only ever goes up, so once it crossed the threshold the brow stayed up
    /// for the rest of the day. Anything driving an expression has to be able
    /// to come back down, and disagreement does — the moment the sessions
    /// agree again it is zero.
    ///
    /// Only `working` and `waiting` count. A finished session next to a busy
    /// one is not a discrepancy, it is just yesterday.
    public static func discord(_ sessions: [AgentSession], policy: Policy = .init()) -> Double {
        let live = sessions.filter { $0.state == .working || $0.state == .waiting }
        guard let loudest = live.max(by: { $0.state.attentionPriority < $1.state.attentionPriority })
        else { return 0 }
        let odd = live.filter { $0.state != loudest.state }
        guard let marker = odd.map(\.id).min() else { return 0 }

        let strength = ramp(Double(odd.count), from: 0, to: Double(policy.discordAt))
        // Which brow, derived from the odd session's id so it is stable for as
        // long as that session is. `hashValue` would have been the obvious
        // choice and is the wrong one: Swift seeds it per process, so the brow
        // would swap sides on every restart for an unchanged set of sessions.
        let seed = marker.utf8.reduce(0) { $0 &+ Int($1) }
        return seed.isMultiple(of: 2) ? strength : -strength
    }

    /// How long since anything happened, 0…1.
    ///
    /// The opposite of fatigue, which is about how long you have been working.
    /// This is about how long you have not: a machine quiet for twenty minutes
    /// should be asleep, not merely tired.
    ///
    /// Any session actually `working` holds it at zero, whatever the clock
    /// says. Events stop entirely during a long tool call — that is the same
    /// silence `SessionStore.prune` had to learn to read — and a face that
    /// dozes off while a build runs has misread it in the same way.
    public static func drowsiness(
        _ sessions: [AgentSession], lastInteraction: Date? = nil,
        policy: Policy = .init(), now: Date
    ) -> Double {
        guard !sessions.contains(where: { $0.state == .working }) else { return 0 }
        // Being touched counts as something happening, exactly like an agent
        // event does. Without this a click on a sleeping face could only ever
        // be a reaction laid over a sleeping mood — the eyes cracked open for
        // half a second and shut again, which reads as a twitch rather than as
        // waking up. The cause is the mood, so the mood is what has to change.
        let newest = [sessions.map(\.updatedAt).max(), lastInteraction]
            .compactMap { $0 }
            .max()
        guard let newest else { return 1 }
        return ramp(now.timeIntervalSince(newest),
                    from: policy.drowsyAfter, to: policy.asleepAfter)
    }

    /// How recently the face was touched, 1 down to 0.
    ///
    /// Suppressing `drowsiness` is not enough on its own to wake anything up.
    /// With no sessions at all the resting face is already `base(for: nil)` —
    /// eyes at 0.05, because nothing is happening — so a face that had merely
    /// stopped being sleepy would still be sitting there with its eyes shut.
    /// Something has to open them.
    ///
    /// Decays over exactly `drowsyAfter`, so it reaches zero at the moment
    /// drowsiness starts to climb and the two hand over without a gap in which
    /// the face is neither awake nor asleep.
    public static func alertness(
        lastInteraction: Date?, policy: Policy = .init(), now: Date
    ) -> Double {
        guard let lastInteraction else { return 0 }
        return 1 - ramp(now.timeIntervalSince(lastInteraction), from: 0, to: policy.drowsyAfter)
    }

    // MARK: - Composition

    /// The face right now.
    ///
    /// Pressures are added to the resting expression rather than replacing it,
    /// and clamped once at the end, so no signal can silence another and the
    /// order they are applied in does not matter.
    public static func expression(
        for inputs: FaceInputs, policy: Policy = .init(), now: Date
    ) -> FaceExpression {
        var face = base(for: dominantState(inputs.sessions))

        let quota = quotaPressure(inputs.quota, policy: policy, now: now)
        face.browAngle -= 0.9 * quota
        face.mouthCurve -= 0.6 * quota
        face.strain += quota

        let thrash = thrashPressure(inputs.sessions, policy: policy, now: now)
        face.eyeOpenness -= 0.35 * thrash
        face.mouthCurve -= 0.5 * thrash
        face.strain += 0.5 * thrash

        let tired = fatigue(inputs.sessions, rateLimits: inputs.rateLimits,
                            policy: policy, now: now)
        face.eyeOpenness -= 0.5 * tired
        face.energy -= 0.7 * tired
        face.browAngle -= 0.2 * tired

        // The three that describe the shape of the work rather than trouble
        // with it. Each drives exactly one feature, so the face stays readable:
        // a raised brow always means the same thing, whatever else is going on.
        let crowded = crowding(inputs.sessions, policy: policy)
        face.mouthOpen += 0.45 * crowded
        face.eyeOpenness += 0.12 * crowded
        face.strain += 0.25 * crowded

        let effort = exertion(tokensPerMinute: inputs.tokensPerMinute, policy: policy)
        face.tongue += 0.85 * effort
        face.mouthOpen += 0.3 * effort

        face.browSkew += 0.9 * discord(inputs.sessions, policy: policy)

        // A squint rather than a frown: the five-hour window running hot is
        // something to look harder at, not something to be unhappy about. It
        // deliberately lands on different features from the weekly pressure
        // above, so a face under both reads as under both.
        let burning = sessionPressure(inputs.quota, policy: policy, now: now)
        face.eyeOpenness -= 0.3 * burning
        face.strain += 0.35 * burning

        // Applied last and hardest: a sleeping face is not a worried one, so
        // the lids and the energy go down regardless of what the pressures
        // above did to them. The brow is left where it was — a frown that
        // survives into sleep is closer to how a face actually rests than one
        // that smooths out the moment the eyes close.
        let sleepy = drowsiness(inputs.sessions, lastInteraction: inputs.lastInteraction,
                                policy: policy, now: now)
        face.eyeOpenness -= 0.95 * sleepy
        face.energy -= 0.9 * sleepy
        // A sleeping face with its mouth open and its tongue out is not asleep,
        // it is unwell.
        face.mouthOpen -= sleepy
        face.tongue -= sleepy

        // A floor, and the one thing here that is not a pressure — which is
        // why it is last and why it says so. Adding would have been wrong in
        // the obvious way: a click on an already wide-eyed working face would
        // push it past 1 and pin it there for five minutes. Raising a floor
        // wakes a shut face and leaves an open one alone.
        let awake = alertness(lastInteraction: inputs.lastInteraction, policy: policy, now: now)
        if awake > 0 {
            face.eyeOpenness = max(face.eyeOpenness, 0.72 * awake)
            face.energy = max(face.energy, 0.55 * awake)
        }

        return face.clamped()
    }

    // MARK: - Helpers

    /// 0 below `from`, 1 above `to`, linear between. Degenerate ranges return a
    /// clean 0/1 rather than dividing by zero.
    static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        return min(max((value - from) / (to - from), 0), 1)
    }
}
