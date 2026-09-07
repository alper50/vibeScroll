import Foundation

/// One unit of work to hand to an agent when there is quota to spare.
///
/// A task is a prompt plus the project it runs against — deliberately not a
/// shell command. The point of the queue is to spend a rate-limited window that
/// would otherwise expire unused, and only an agent turn spends one.
public struct QueuedTask: Codable, Identifiable, Sendable, Equatable {

    public enum Status: String, Codable, Sendable {
        /// Waiting for a window with room in it.
        case pending
        case running
        case succeeded
        /// Failed for a reason that re-running would not fix.
        case failed
        /// Retried as far as the policy allows and still failing. Parked rather
        /// than failed so it is visibly waiting for a human, not silently over.
        case parked
        case cancelled
    }

    /// Why a run ended badly. Only `rateLimit` is worth retrying: it is the one
    /// cause that is about the moment rather than about the task, and every
    /// other retry spends quota to reach the same result.
    public enum Failure: String, Codable, Sendable {
        case rateLimit
        /// The agent itself reported the run as failed.
        case agentError
        case nonZeroExit
        /// Exited cleanly but wrote nothing a result could be read from.
        case unreadableResult
        case timedOut
        case launchFailed
        case notAGitRepo

        public var isRetryable: Bool { self == .rateLimit }
    }

    public let id: String
    /// Which agent runs this task. Only Claude Code has a verified headless
    /// invocation today (see `AgentLaunch`), but the field is carried so adding
    /// a second one is a new case rather than a new column.
    public var agentKind: AgentKind
    /// Manual position in the queue. Lower runs first.
    public var order: Int
    public var projectPath: String
    public var prompt: String
    public var status: Status
    public var failure: Failure?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    /// The UUID handed to `claude --session-id`, which is what lets the running
    /// task be matched back to the session the hooks report. Assigned at launch,
    /// and re-assigned on a retry so two runs never share a transcript.
    public var sessionId: String?
    /// Slug of the git worktree the run happened in. The branch derives from it
    /// via `WorktreePlan.branch(slug:)`.
    public var worktreeName: String?
    /// Absolute path of that checkout. Stored rather than recomputed: cleanup
    /// must delete the directory that was actually used, not the one a
    /// since-edited prompt would name today.
    public var worktreePath: String?
    public var exitCode: Int32?
    /// Runs so far. Only ever advanced by a retryable failure.
    public var attempts: Int

    public init(
        id: String = UUID().uuidString,
        agentKind: AgentKind = .claude,
        order: Int,
        projectPath: String,
        prompt: String,
        status: Status = .pending,
        failure: Failure? = nil,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        sessionId: String? = nil,
        worktreeName: String? = nil,
        worktreePath: String? = nil,
        exitCode: Int32? = nil,
        attempts: Int = 0
    ) {
        self.id = id
        self.agentKind = agentKind
        self.order = order
        self.projectPath = projectPath
        self.prompt = prompt
        self.status = status
        self.failure = failure
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.sessionId = sessionId
        self.worktreeName = worktreeName
        self.worktreePath = worktreePath
        self.exitCode = exitCode
        self.attempts = attempts
    }

    /// Decoding tolerates a file written by an older build: anything beyond the
    /// four fields a task cannot exist without falls back to a default, so a
    /// added field never strands somebody's whole queue.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let rawKind = try c.decodeIfPresent(String.self, forKey: .agentKind)
        agentKind = rawKind.flatMap(AgentKind.init(rawValue:)) ?? .claude
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        projectPath = try c.decode(String.self, forKey: .projectPath)
        prompt = try c.decode(String.self, forKey: .prompt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status)
        status = rawStatus.flatMap(Status.init(rawValue:)) ?? .pending
        let rawFailure = try c.decodeIfPresent(String.self, forKey: .failure)
        failure = rawFailure.flatMap(Failure.init(rawValue:))
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        worktreeName = try c.decodeIfPresent(String.self, forKey: .worktreeName)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
    }
}
