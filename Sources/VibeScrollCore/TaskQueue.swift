import Foundation

/// The ordered list of queued tasks, plus the ledger of when runs were started.
///
/// Pure value type: no clock, no IO, no actor. The app layer owns persistence
/// and hands `now` in, which is what makes the retry rules and the daily cap
/// directly testable.
public struct TaskQueue: Codable, Sendable, Equatable {

    public private(set) var tasks: [QueuedTask]

    /// When each run was started. Kept separately from `QueuedTask.startedAt`
    /// because a retry overwrites that field, and the daily cap has to count
    /// *runs*, not tasks — otherwise a task that failed and retried twice would
    /// spend three windows while reading as one.
    public private(set) var launches: [Date]

    /// How long the ledger is worth keeping. Nothing reads further back than a
    /// day; a week leaves room for a future "where did this week go" view
    /// without the file growing without bound.
    static let launchLedgerRetention: TimeInterval = 7 * 24 * 3600

    public init(tasks: [QueuedTask] = [], launches: [Date] = []) {
        self.tasks = tasks
        self.launches = launches
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent([QueuedTask].self, forKey: .tasks) ?? []
        launches = try c.decodeIfPresent([Date].self, forKey: .launches) ?? []
    }

    // MARK: - Reading

    /// The task that should run next: lowest `order` among pending ones. Ties
    /// break on `createdAt` then `id`, so the choice is stable across calls and
    /// two tasks added in the same drag can't swap places between ticks.
    public var nextPending: QueuedTask? {
        tasks.filter { $0.status == .pending && readiness(of: $0).isReady }
            .min {
                if $0.order != $1.order { return $0.order < $1.order }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id < $1.id
            }
    }

    public var running: QueuedTask? { tasks.first { $0.status == .running } }

    /// Whether any pending task is held back only by the task it builds on.
    /// Told apart from an empty queue, so the gate can say why nothing runs.
    public var hasPendingWaitingOnAnother: Bool {
        tasks.contains { $0.status == .pending && !readiness(of: $0).isReady }
    }

    /// Whether a task can start, as far as the tasks it builds on go.
    public enum Readiness: Equatable, Sendable {
        /// Free to start; `baseBranch` is where it starts from, `nil` for HEAD.
        case ready(baseBranch: String?)
        /// The task it builds on has not finished yet.
        case waiting(on: String)
        /// The task it builds on ended without success. It stays put rather
        /// than starting from HEAD, which would silently drop the earlier step.
        case blocked(by: String)

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    public func readiness(of task: QueuedTask) -> Readiness {
        guard let parentID = task.basedOn, let parent = self.task(id: parentID) else {
            return .ready(baseBranch: nil)
        }
        switch parent.status {
        case .succeeded:
            guard let slug = parent.worktreeName else { return .ready(baseBranch: nil) }
            return .ready(baseBranch: WorktreePlan.branch(slug: slug))
        case .pending, .running:
            return .waiting(on: parentID)
        case .failed, .parked, .cancelled:
            return .blocked(by: parentID)
        }
    }

    /// Tasks a new one in `projectPath` may build on: the same project, and
    /// not already given up on.
    public func buildableBases(for projectPath: String) -> [QueuedTask] {
        let project = ProjectPath.normalize(projectPath)
        return tasks
            .filter { ProjectPath.normalize($0.projectPath) == project }
            .filter { [.pending, .running, .succeeded].contains($0.status) }
            .sorted { $0.order < $1.order }
    }

    public func task(id: String) -> QueuedTask? { tasks.first { $0.id == id } }

    /// Whether `sessionId` belongs to a queued task.
    ///
    /// This is what the session id handed to `--session-id` is *for*: a task's
    /// agent session is otherwise indistinguishable from one a person started,
    /// and the daemon would announce every task a second time in a vocabulary
    /// that knows nothing about rate limits or timeouts.
    ///
    /// Matches finished tasks too, not just the running one. The agent's `Stop`
    /// hook fires before the process exits, so the daemon can reach a session's
    /// final state before the runner has recorded the outcome — a check
    /// narrowed to `running` would lose that race about half the time.
    public func ownsSession(_ sessionId: String) -> Bool {
        tasks.contains { $0.sessionId == sessionId }
    }

    /// Tasks that will never run again on their own. One definition, because
    /// "finished" decides both what the cleanup button sweeps and what the list
    /// stops needing to show.
    public var finished: [QueuedTask] {
        tasks.filter { task in
            switch task.status {
            case .succeeded, .failed, .parked, .cancelled: return true
            case .pending, .running: return false
            }
        }
        .sorted { $0.order < $1.order }
    }

    /// Runs started on the calendar day containing `day`. This is what the
    /// nightly cap counts.
    public func launchCount(on day: Date, calendar: Calendar) -> Int {
        launches.filter { calendar.isDate($0, inSameDayAs: day) }.count
    }

    // MARK: - Editing

    @discardableResult
    public mutating func add(
        projectPath: String, prompt: String, title: String? = nil, doneWhen: String? = nil,
        basedOn: String? = nil, agentKind: AgentKind = .claude, now: Date
    ) -> QueuedTask {
        let nextOrder = (tasks.map(\.order).max() ?? -1) + 1
        // Only a task that exists, in the same project, can be built on — a
        // branch from another repository is not somewhere this one can start.
        let base = basedOn.flatMap { id in
            buildableBases(for: projectPath).contains { $0.id == id } ? id : nil
        }
        let task = QueuedTask(
            agentKind: agentKind, order: nextOrder,
            projectPath: projectPath, prompt: prompt, createdAt: now,
            title: Self.nonEmpty(title), doneWhen: Self.nonEmpty(doneWhen), basedOn: base)
        tasks.append(task)
        return task
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// Removing a task that others build on turns them back into tasks that
    /// start from HEAD. They are kept rather than removed along with it: the
    /// prompts are work somebody wrote, and the list shows the change.
    public mutating func remove(id: String) {
        remove(ids: [id])
    }

    public mutating func remove(ids: Set<String>) {
        tasks.removeAll { ids.contains($0.id) }
        for i in tasks.indices where tasks[i].basedOn.map(ids.contains) == true {
            tasks[i].basedOn = nil
        }
    }

    /// Moves `id` to `index` in the pending order and renumbers, so `order`
    /// stays dense and a later insert can't collide with an existing value.
    public mutating func move(id: String, to index: Int) {
        var ordered = tasks.sorted { $0.order < $1.order }
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let task = ordered.remove(at: from)
        ordered.insert(task, at: min(max(index, 0), ordered.count))
        for (i, var t) in ordered.enumerated() {
            t.order = i
            ordered[i] = t
        }
        let byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.order) })
        for i in tasks.indices {
            if let order = byID[tasks[i].id] { tasks[i].order = order }
        }
    }

    /// Puts a finished or parked task back in line for another run. The manual
    /// escape hatch for everything the automatic retry rule deliberately
    /// refuses to do.
    public mutating func requeue(id: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[i].status != .running else { return }
        tasks[i].status = .pending
        tasks[i].failure = nil
        tasks[i].exitCode = nil
        tasks[i].finishedAt = nil
        tasks[i].attempts = 0
        tasks[i].report = nil
    }

    public mutating func cancel(id: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].status = .cancelled
    }

    // MARK: - Lifecycle

    /// Marks a task as started and records the run in the ledger.
    ///
    /// `sessionId` is generated by the caller and passed to `claude
    /// --session-id`, so the session the hooks report can be matched back to
    /// this task without inferring anything from paths or timing.
    public mutating func markRunning(
        id: String, sessionId: String, worktreeName: String?,
        worktreePath: String? = nil, now: Date
    ) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].status = .running
        tasks[i].startedAt = now
        tasks[i].finishedAt = nil
        tasks[i].sessionId = sessionId
        tasks[i].worktreeName = worktreeName
        tasks[i].worktreePath = worktreePath
        launches.append(now)
        pruneLedger(now: now)
    }

    /// Records the outcome of a run and decides what happens next.
    ///
    /// Only a rate limit earns another go, and only while attempts remain:
    /// every other failure would spend a fresh window arriving at the same
    /// answer. A retryable failure that is out of attempts is *parked*, not
    /// failed — it is waiting for a person, and saying so is the difference
    /// between a queue you can trust and one you have to audit.
    public mutating func markFinished(
        id: String, exitCode: Int32?, failure: QueuedTask.Failure?,
        maxRateLimitRetries: Int, report: TaskReport? = nil, now: Date
    ) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].finishedAt = now
        tasks[i].exitCode = exitCode
        tasks[i].failure = failure
        tasks[i].report = report

        guard let failure else {
            tasks[i].status = .succeeded
            return
        }
        guard failure.isRetryable else {
            tasks[i].status = .failed
            return
        }
        tasks[i].attempts += 1
        tasks[i].status = tasks[i].attempts >= maxRateLimitRetries ? .parked : .pending
    }

    private mutating func pruneLedger(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.launchLedgerRetention)
        launches.removeAll { $0 < cutoff }
    }
}
