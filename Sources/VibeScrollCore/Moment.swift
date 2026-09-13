import Foundation

/// Something that just happened, said in one line.
///
/// The teaching cards are the opposite of this: they come from the backend,
/// they are about a topic rather than about right now, and they would read the
/// same yesterday. A moment is local, timely, and worthless five minutes later
/// — which is why it is a separate type rather than an `InfoCard` with a
/// special id. Two kinds of content with two lifetimes and two sources.
///
/// All of it is derived from what the app already knows, so a moment shows on
/// a machine that has never reached the backend.
public enum Moment: Equatable, Sendable {
    /// First launch.
    case welcome
    case sessionStarted(agent: AgentKind, project: String?)
    case turnFinished(agent: AgentKind, project: String?)
    case waitingOnYou(agent: AgentKind, project: String?)
    case rateLimited(count: Int)
    /// The five-hour window rolled over and there is quota again.
    case windowRenewed
    case longHaul(hours: Int)
    case crowd(count: Int)
    /// The queue started something by itself.
    case taskStarted(project: String)

    public var title: String {
        switch self {
        case .welcome:            return "vibeScroll is running"
        case .sessionStarted:     return "Session started"
        case .turnFinished:       return "Turn finished"
        case .waitingOnYou:       return "Waiting on you"
        case .rateLimited:        return "Rate limited"
        case .windowRenewed:      return "Five-hour window renewed"
        case .longHaul(let h):    return "\(h) hours in"
        case .crowd(let count):   return "\(count) agents at once"
        case .taskStarted:        return "Queue started a task"
        }
    }

    /// The second line. Short enough that the card never needs two of them.
    public var detail: String {
        switch self {
        case .welcome:
            return "It watches your agents. Nothing to set up."
        case .sessionStarted(let agent, let project),
             .turnFinished(let agent, let project),
             .waitingOnYou(let agent, let project):
            return Self.label(agent: agent, project: project)
        case .rateLimited(let count):
            return count <= 1 ? "First one this hour." : "\(count) this hour."
        case .windowRenewed:
            return "Nothing spent yet."
        case .longHaul:
            return "Since your first agent started."
        case .crowd:
            return "Click the face for the full list."
        case .taskStarted(let project):
            return ProjectPath.displayName(project)
        }
    }

    private static func label(agent: AgentKind, project: String?) -> String {
        let name = TickerFormatter.agentLabel(for: agent)
        guard let project, !project.isEmpty else { return name }
        return "\(name) \u{00B7} \(ProjectPath.displayName(project))"
    }

    /// What the gate rate-limits against.
    ///
    /// Kinds share a bucket, so two projects starting together is one card
    /// rather than two — the point is that work began, not which work. The two
    /// milestones are the exception: each threshold is its own key so crossing
    /// four hours does not silence crossing five.
    public var throttleKey: String {
        switch self {
        case .welcome:          return "welcome"
        case .sessionStarted:   return "sessionStarted"
        case .turnFinished:     return "turnFinished"
        case .waitingOnYou:     return "waitingOnYou"
        case .rateLimited:      return "rateLimited"
        case .windowRenewed:    return "windowRenewed"
        case .longHaul(let h):  return "longHaul-\(h)"
        case .crowd(let count): return "crowd-\(count)"
        case .taskStarted:      return "taskStarted"
        }
    }
}

/// Decides whether a moment is worth interrupting for.
///
/// Pure and `now`-injected, like `CardScheduler` and `TaskRunway`. Moments are
/// cheap to produce and the app sees a great many of them, so the whole
/// question of whether this surface becomes noise lives in one testable place
/// rather than being spread across the call sites that raise them.
public struct MomentGate: Sendable {
    public struct Policy: Sendable, Equatable {
        /// How often one kind may repeat.
        public var perKind: TimeInterval
        /// The floor between any two moments, whatever their kind. Without it
        /// a rate limit during a busy minute stacks on top of a session start
        /// and the panel flickers between them.
        public var betweenAny: TimeInterval
        /// How long a moment stays up before the card underneath comes back.
        public var dwell: TimeInterval

        public init(perKind: TimeInterval = 300,
                    betweenAny: TimeInterval = 45,
                    dwell: TimeInterval = 7) {
            self.perKind = perKind
            self.betweenAny = betweenAny
            self.dwell = dwell
        }
    }

    public var policy: Policy
    private var lastByKey: [String: Date] = [:]
    private var lastAny: Date?

    public init(policy: Policy = .init()) {
        self.policy = policy
    }

    /// Records and allows, or refuses. Mutating because a gate that does not
    /// remember what it let through cannot rate-limit anything.
    public mutating func admit(_ moment: Moment, now: Date) -> Bool {
        if let lastAny, now.timeIntervalSince(lastAny) < policy.betweenAny { return false }
        if let last = lastByKey[moment.throttleKey],
           now.timeIntervalSince(last) < policy.perKind { return false }

        lastByKey[moment.throttleKey] = now
        lastAny = now
        return true
    }

    /// Forgets everything. For the master switch coming back on, so a session
    /// started while cards were off does not count against the first one after.
    public mutating func reset() {
        lastByKey.removeAll()
        lastAny = nil
    }
}
