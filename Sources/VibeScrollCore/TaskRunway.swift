import Foundation

/// Decides whether there is room to start a queued task right now.
///
/// The two rate-limit windows are spent for opposite reasons, so they are
/// gated differently and that asymmetry is the whole design:
///
/// - **The session window is use-it-or-lose-it.** It expires every few hours
///   whether or not it was spent, so filling it is the point. It gets a plain
///   ceiling, only high enough to avoid walking a task into a rate limit.
/// - **The weekly window is the scarce one.** Filling every session window
///   would exhaust it by midweek and leave nothing for real work. It is gated
///   on *pace*: usage is compared against how far through the week we are, so
///   spending is allowed only when it is running behind the clock — plus a
///   reserve that is held back until the week is nearly over and the remainder
///   would expire anyway.
///
/// Pure and `now`-injected, like `CardScheduler`: every rule below is a
/// function of its arguments, so all of them are directly testable without a
/// network, a clock or an agent.
public enum TaskRunway {

    public struct Policy: Sendable, Equatable {
        /// Weekly usage above this holds the queue, so a person always has
        /// headroom left for work they did not schedule.
        public var weeklyReserve: Int
        /// …except this close to the weekly reset, where the reserve would
        /// expire unspent. Holding it back then would waste exactly what this
        /// feature exists to rescue.
        public var reserveLiftsWithin: TimeInterval
        /// How far *behind* pace weekly usage must be, as a fraction, before a
        /// task may start. Zero would launch while sitting exactly on the line.
        public var paceMargin: Double
        /// Session usage above this holds the queue: starting a task with a
        /// nearly spent window buys a rate limit partway through it.
        public var sessionCeiling: Int
        /// How long the keyboard must be quiet. Queued work is meant to use the
        /// hours nobody is working, not to race the person who is.
        public var requireUserIdle: TimeInterval
        /// Cap on runs started per calendar day.
        public var maxLaunchesPerDay: Int
        /// A quota reading older than this is not evidence about now.
        public var snapshotMaxAge: TimeInterval
        /// Quiet gap after a task finishes, so a failing queue cannot spin.
        public var cooldown: TimeInterval
        /// How many times a rate-limited task is retried before it is parked.
        public var maxRateLimitRetries: Int

        public init(
            weeklyReserve: Int = 90,
            reserveLiftsWithin: TimeInterval = 6 * 3600,
            paceMargin: Double = 0.05,
            sessionCeiling: Int = 90,
            requireUserIdle: TimeInterval = 15 * 60,
            maxLaunchesPerDay: Int = 3,
            snapshotMaxAge: TimeInterval = 600,
            cooldown: TimeInterval = 60,
            maxRateLimitRetries: Int = 2
        ) {
            self.weeklyReserve = weeklyReserve
            self.reserveLiftsWithin = reserveLiftsWithin
            self.paceMargin = paceMargin
            self.sessionCeiling = sessionCeiling
            self.requireUserIdle = requireUserIdle
            self.maxLaunchesPerDay = maxLaunchesPerDay
            self.snapshotMaxAge = snapshotMaxAge
            self.cooldown = cooldown
            self.maxRateLimitRetries = maxRateLimitRetries
        }
    }

    /// Why nothing is starting. Carries its numbers so the settings panel can
    /// say "weekly is at 85%, pace is 67%" instead of "waiting" — a queue that
    /// sits still without explaining itself reads as broken.
    public enum Hold: Equatable, Sendable {
        case queueEmpty
        case taskAlreadyRunning
        case dailyLimitReached(started: Int, limit: Int)
        /// No quota reading at all: the probe is off, or has never succeeded.
        case quotaUnavailable
        case quotaStale(age: TimeInterval)
        case sessionWindowSpent(percent: Int)
        case weeklyReserve(percent: Int, reserve: Int)
        case aheadOfPace(usedPercent: Int, elapsedPercent: Int)
        case agentBusy
        case userActive
        case cooldown(remaining: TimeInterval)
    }

    public enum Decision: Equatable, Sendable {
        case launch(QueuedTask)
        case hold(Hold)
    }

    /// Window identifiers that mean "the rolling few-hour allowance".
    static let sessionKinds: Set<String> = ["session", "five_hour"]
    /// …and the weekly ones. Per-model weekly pools are included so that a plan
    /// which reports them is gated on whichever is tightest, rather than on a
    /// combined figure that hides the one about to run out.
    static let weeklyKinds: Set<String> = [
        "weekly_all", "seven_day", "weekly_opus", "seven_day_opus",
        "weekly_sonnet", "seven_day_sonnet",
    ]

    /// Nominal length of a window. The endpoint reports when a window *ends*
    /// but never when it began, so this is the one piece the pace calculation
    /// cannot read and has to know. An unrecognised kind returns `nil` and is
    /// skipped rather than guessed — a wrong duration would silently distort
    /// every pace decision made from it.
    static func duration(forKind kind: String) -> TimeInterval? {
        if sessionKinds.contains(kind) { return 5 * 3600 }
        if weeklyKinds.contains(kind) { return 7 * 24 * 3600 }
        return nil
    }

    /// How far through its window we are, 0...1, or `nil` when the window has
    /// no reset time or an unknown length.
    static func elapsedFraction(_ window: QuotaWindow, now: Date) -> Double? {
        guard let resetsAt = window.resetsAt,
              let duration = duration(forKind: window.kind), duration > 0
        else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return min(max(1 - remaining / duration, 0), 1)
    }

    /// The tightest window of a group — the one that will actually stop you.
    static func tightest(_ windows: [QuotaWindow], in kinds: Set<String>) -> QuotaWindow? {
        windows.filter { kinds.contains($0.kind) }.max { $0.percentUsed < $1.percentUsed }
    }

    /// Gates are ordered so the reason a person sees is the most useful one:
    /// what the queue itself is doing, then what the quota says, and only then
    /// the transient facts about the room.
    ///
    /// `userIdleFor` is `nil` when idle time could not be read, which is
    /// treated as "somebody is here". Starting unattended work on a machine
    /// whose state we cannot see is the one mistake worth being cautious about.
    public static func decide(
        queue: TaskQueue,
        snapshot: QuotaSnapshot?,
        liveSessions: [AgentSession],
        userIdleFor: TimeInterval?,
        lastFinishedAt: Date?,
        policy: Policy,
        calendar: Calendar = .current,
        now: Date
    ) -> Decision {
        if queue.running != nil { return .hold(.taskAlreadyRunning) }
        guard let next = queue.nextPending else { return .hold(.queueEmpty) }

        let started = queue.launchCount(on: now, calendar: calendar)
        guard started < policy.maxLaunchesPerDay else {
            return .hold(.dailyLimitReached(started: started, limit: policy.maxLaunchesPerDay))
        }

        guard let snapshot else { return .hold(.quotaUnavailable) }
        let age = now.timeIntervalSince(snapshot.checkedAt)
        guard age <= policy.snapshotMaxAge else { return .hold(.quotaStale(age: age)) }

        if let session = tightest(snapshot.windows, in: sessionKinds),
           session.percentUsed >= policy.sessionCeiling {
            return .hold(.sessionWindowSpent(percent: session.percentUsed))
        }

        // No weekly reading means the guard that keeps this feature from eating
        // the week is not available, so nothing runs. Failing closed here is
        // deliberate: the cost of holding is a queue that waits, and the cost of
        // proceeding is a week of quota spent unsupervised.
        guard let weekly = tightest(snapshot.windows, in: weeklyKinds) else {
            return .hold(.quotaUnavailable)
        }

        let untilWeeklyReset = weekly.resetsAt?.timeIntervalSince(now) ?? .greatestFiniteMagnitude
        let reserveApplies = untilWeeklyReset > policy.reserveLiftsWithin
        if reserveApplies, weekly.percentUsed >= policy.weeklyReserve {
            return .hold(.weeklyReserve(percent: weekly.percentUsed, reserve: policy.weeklyReserve))
        }

        if let elapsed = elapsedFraction(weekly, now: now) {
            let used = Double(weekly.percentUsed) / 100
            guard used <= elapsed - policy.paceMargin else {
                return .hold(.aheadOfPace(
                    usedPercent: weekly.percentUsed,
                    elapsedPercent: Int((elapsed * 100).rounded())))
            }
        }

        // Nothing is running (checked first), so every working session here
        // belongs to the person, and starting a task would put two agents on the
        // same window at once.
        if liveSessions.contains(where: { $0.state == .working }) { return .hold(.agentBusy) }

        guard let idle = userIdleFor, idle >= policy.requireUserIdle else {
            return .hold(.userActive)
        }

        if let lastFinishedAt {
            let since = now.timeIntervalSince(lastFinishedAt)
            if since < policy.cooldown { return .hold(.cooldown(remaining: policy.cooldown - since)) }
        }

        return .launch(next)
    }
}
