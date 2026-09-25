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
    /// A short name for the list, the branch and the commit message. `nil` for
    /// tasks written before there was one — `displayTitle` falls back to the
    /// prompt's first line.
    public var title: String?
    /// How to tell the task is finished. Handed to the agent as its own
    /// section: an unattended agent that knows where the finish line is stops
    /// there, instead of stopping wherever it happens to feel done.
    public var doneWhen: String?
    /// The task whose branch this one starts from, so a piece of work can be
    /// split into steps that build on each other. `nil` starts from the
    /// project's current HEAD.
    public var basedOn: String?
    /// What the run left behind, for reading afterwards. `nil` until it ends.
    public var report: TaskReport?

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
        attempts: Int = 0,
        title: String? = nil,
        doneWhen: String? = nil,
        basedOn: String? = nil,
        report: TaskReport? = nil
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
        self.title = title
        self.doneWhen = doneWhen
        self.basedOn = basedOn
        self.report = report
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
        title = try c.decodeIfPresent(String.self, forKey: .title)
        doneWhen = try c.decodeIfPresent(String.self, forKey: .doneWhen)
        basedOn = try c.decodeIfPresent(String.self, forKey: .basedOn)
        // A report this build cannot read is dropped rather than failing the
        // whole queue file, which would lose every task in it.
        report = try? c.decodeIfPresent(TaskReport.self, forKey: .report)
    }
}

extension QueuedTask {
    /// The title if there is one, else the prompt's first line, shortened.
    public var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let line = prompt.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? prompt
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(79)) + "\u{2026}" : trimmed
    }
}

/// What a finished run left behind — the answer to "what did it do?" the next
/// morning, kept on the task rather than only in a notification that is gone
/// once dismissed.
public struct TaskReport: Codable, Sendable, Equatable {
    /// The agent's own closing summary.
    public var summary: String?
    /// The contents of `BLOCKED.md`, if the agent stopped and said why.
    public var blocker: String?
    /// What changed, against the commit the task started from.
    public var changedFiles: [ChangedFile]
    /// Whether the work was committed to the task's branch. A failed run is
    /// left uncommitted on purpose, so its files are listed from the working
    /// tree instead.
    public var committed: Bool
    /// The commit the task started from — the project's HEAD, or the end of
    /// the task it builds on.
    public var baseCommit: String?
    public var durationSeconds: Double?
    public var inputTokens: Int
    public var outputTokens: Int

    public init(summary: String? = nil, blocker: String? = nil, changedFiles: [ChangedFile] = [],
                committed: Bool = false, baseCommit: String? = nil, durationSeconds: Double? = nil,
                inputTokens: Int = 0, outputTokens: Int = 0) {
        self.summary = summary
        self.blocker = blocker
        self.changedFiles = changedFiles
        self.committed = committed
        self.baseCommit = baseCommit
        self.durationSeconds = durationSeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public struct ChangedFile: Codable, Sendable, Equatable {
        public var path: String
        /// Lines added and removed. `nil` for a binary file, or for a new file
        /// git is not yet tracking.
        public var added: Int?
        public var removed: Int?

        public init(path: String, added: Int?, removed: Int?) {
            self.path = path
            self.added = added
            self.removed = removed
        }
    }

    public var totalAdded: Int { changedFiles.compactMap(\.added).reduce(0, +) }
    public var totalRemoved: Int { changedFiles.compactMap(\.removed).reduce(0, +) }

    /// Parses `git diff --numstat`: `<added>\t<removed>\t<path>` per line,
    /// with `-` for both counts on a binary file. A rename is kept as git
    /// prints it; unreadable lines are skipped rather than guessed at.
    public static func parseNumstat(_ text: String) -> [ChangedFile] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[2].isEmpty else { return nil }
            return ChangedFile(path: String(parts[2]), added: Int(parts[0]), removed: Int(parts[1]))
        }
    }
}
