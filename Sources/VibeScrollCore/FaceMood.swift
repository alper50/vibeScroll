import Foundation

/// Everything the face reacts to. All of it already exists elsewhere in the
/// app; none of it is currently visible anywhere.
public struct FaceInputs: Equatable, Sendable {
    public var sessions: [AgentSession]
    /// `nil` when the quota probe is off or has never succeeded.
    public var quota: QuotaSnapshot?
    /// When rate limits were seen recently, in any order.
    public var rateLimits: [Date]

    public init(sessions: [AgentSession] = [], quota: QuotaSnapshot? = nil,
                rateLimits: [Date] = []) {
        self.sessions = sessions
        self.quota = quota
        self.rateLimits = rateLimits
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

        public init(
            thrashBegins: TimeInterval = 20 * 60,
            thrashFull: TimeInterval = 45 * 60,
            longSessionBegins: TimeInterval = 3 * 3600,
            longSessionFull: TimeInterval = 6 * 3600,
            rateLimitWindow: TimeInterval = 3600,
            rateLimitsForFull: Int = 3,
            overspendForFull: Double = 0.20
        ) {
            self.thrashBegins = thrashBegins
            self.thrashFull = thrashFull
            self.longSessionBegins = longSessionBegins
            self.longSessionFull = longSessionFull
            self.rateLimitWindow = rateLimitWindow
            self.rateLimitsForFull = rateLimitsForFull
            self.overspendForFull = overspendForFull
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

        /// One line, for the label under the face.
        public var summary: String {
            switch self {
            case .steady(let state):
                return state.flatMap(ActivitySummary.stateMessage(for:)) ?? "Nothing running"
            case .overBudget(let used, let elapsed):
                return "Weekly \(used)% spent, \(elapsed)% of the week gone"
            case .circling(let topic, let minutes):
                return "Circling \(topic?.fallbackLabel.lowercased() ?? "one topic") for \(minutes) min"
            case .longSession(let minutes):
                return minutes >= 60
                    ? "\(minutes / 60)h \(minutes % 60)m in"
                    : "\(minutes)m in"
            case .rateLimited(let count):
                return "\(count) rate limit\(count == 1 ? "" : "s") this hour"
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
        let thrash = thrashPressure(inputs.sessions, policy: policy, now: now)
        let tired = fatigue(inputs.sessions, rateLimits: inputs.rateLimits,
                            policy: policy, now: now)

        let strongest = max(quota, max(thrash, tired))
        guard strongest >= minimumWorthNaming else {
            return .steady(dominantState(inputs.sessions))
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
