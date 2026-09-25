import Foundation
import VibeScrollCore

/// Owns the task queue and its file.
///
/// Every mutation writes immediately and atomically. The queue is the one piece
/// of state in this app that cannot be reconstructed — sessions and cards are
/// both derived from something else, but a task list exists only here, and a
/// crash between "task added" and "file written" would lose work somebody typed.
@MainActor
final class TaskQueueStore: ObservableObject {
    static let shared = TaskQueueStore()

    @Published private(set) var queue = TaskQueue()
    /// Set when the file could not be written. Surfaced in Settings: silently
    /// dropping a queue edit is worse than saying so.
    @Published private(set) var lastError: String?

    /// Where task worktrees are checked out — outside every repository, so a
    /// project's own `git status` is never disturbed by queued work.
    static var worktreeRoot: String { VibeScrollPaths.baseDir + "/worktrees" }
    static var logDir: String { VibeScrollPaths.baseDir + "/logs" }

    private var fileURL: URL {
        URL(fileURLWithPath: VibeScrollPaths.baseDir).appendingPathComponent("queue.json")
    }

    private init() { load() }

    /// Whether an agent session belongs to a queued task. Read by `AppDaemon`
    /// so a task is announced once, by the runner that knows how it ended.
    func ownsSession(_ sessionId: String) -> Bool { queue.ownsSession(sessionId) }

    // MARK: - Editing

    func add(projectPath: String, prompt: String, title: String?, doneWhen: String?,
             basedOn: String?) {
        var q = queue
        q.add(projectPath: projectPath, prompt: prompt, title: title, doneWhen: doneWhen,
              basedOn: basedOn, now: Date())
        apply(q)
    }

    /// What happened to one removal attempt.
    enum Removal: Equatable {
        case removed
        /// The checkout holds changes that exist nowhere else. The row stays
        /// so the second, deliberate attempt has something to act on.
        case blockedByUncommittedWork
        case failed(String)
    }

    /// Removes a task and everything it left behind: the checkout, the log, the
    /// row. The branch is kept whenever it carries work — see
    /// `Git.deleteBranchIfEmpty`.
    ///
    /// `force` is the second click. Without it a checkout with uncommitted
    /// changes is refused rather than discarded, because that is a night of
    /// work with no other copy.
    @discardableResult
    func remove(id: String, force: Bool = false) -> Removal {
        guard let task = queue.task(id: id) else { return .removed }
        guard task.status != .running else {
            return .failed(String(localized: "This task is still running."))
        }

        if let path = task.worktreePath {
            switch Git.removeWorktree(project: task.projectPath, path: path, force: force) {
            case .dirty:
                return .blockedByUncommittedWork
            case .failed(let reason):
                return .failed(reason)
            case .removed:
                // Only now: git will not delete a branch still checked out.
                if let slug = task.worktreeName {
                    Git.deleteBranchIfEmpty(
                        project: task.projectPath, branch: WorktreePlan.branch(slug: slug))
                }
            }
        }

        try? FileManager.default.removeItem(atPath: TaskRunner.logPath(for: id))
        var q = queue
        q.remove(id: id)
        apply(q)
        return .removed
    }

    struct CleanupReport: Equatable {
        var removed = 0
        var blocked = 0
        var failed = 0

        var isEmpty: Bool { removed == 0 && blocked == 0 && failed == 0 }
    }

    /// Sweeps every task that will never run again. Tasks holding uncommitted
    /// work are counted and left alone rather than forced — a bulk button is
    /// the worst possible place to discard something irreplaceable.
    @discardableResult
    func cleanUpFinished() -> CleanupReport {
        var report = CleanupReport()
        for task in queue.finished {
            switch remove(id: task.id) {
            case .removed: report.removed += 1
            case .blockedByUncommittedWork: report.blocked += 1
            case .failed: report.failed += 1
            }
        }
        return report
    }

    func move(id: String, to index: Int) {
        var q = queue
        q.move(id: id, to: index)
        apply(q)
    }

    func requeue(id: String) {
        var q = queue
        q.requeue(id: id)
        apply(q)
    }

    func cancel(id: String) {
        var q = queue
        q.cancel(id: id)
        apply(q)
    }

    // MARK: - Lifecycle, called by the runner

    func markRunning(id: String, sessionId: String, worktreeName: String?, worktreePath: String?) {
        var q = queue
        q.markRunning(id: id, sessionId: sessionId, worktreeName: worktreeName,
                      worktreePath: worktreePath, now: Date())
        apply(q)
    }

    func markFinished(
        id: String, exitCode: Int32?, failure: QueuedTask.Failure?, maxRateLimitRetries: Int,
        report: TaskReport? = nil
    ) {
        var q = queue
        q.markFinished(id: id, exitCode: exitCode, failure: failure,
                       maxRateLimitRetries: maxRateLimitRetries, report: report, now: Date())
        apply(q)
    }

    /// Clears a `running` task left behind by a crash or a force quit. Called at
    /// launch: the process is long gone, so a row still claiming to run would
    /// block the queue forever.
    func reconcileAfterRestart() {
        guard let orphan = queue.running else { return }
        var q = queue
        q.markFinished(id: orphan.id, exitCode: nil, failure: .launchFailed,
                       maxRateLimitRetries: 0, now: Date())
        apply(q)
    }

    // MARK: - Disk

    private func apply(_ new: TaskQueue) {
        queue = new
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode(TaskQueue.self, from: data) else {
            lastError = String(localized: "queue.json could not be read; starting from an empty queue.")
            return
        }
        queue = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                atPath: VibeScrollPaths.baseDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Atomic: a crash mid-write must not leave a truncated file that
            // then fails to decode and reads as an empty queue.
            try encoder.encode(queue).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
