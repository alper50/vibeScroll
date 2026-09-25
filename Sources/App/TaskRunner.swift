import Foundation
import VibeScrollCore

/// Runs one queued task: isolate, launch, wait, collect.
///
/// This is the part of vibeScroll that *drives* an agent rather than watching
/// one, so the safeguards are structural rather than advisory. The work happens
/// in a git worktree the person is not standing in, the run is bounded by a
/// timeout, and nothing is ever pushed or merged — the branch is left for a
/// human to look at.
@MainActor
final class TaskRunner: ObservableObject {
    static let shared = TaskRunner()

    @Published private(set) var runningTaskID: String?
    /// Last thing that went wrong outside the agent itself — a missing binary,
    /// a worktree that would not create. Surfaced in Settings.
    @Published private(set) var lastError: String?

    static let executableKey = "vibescroll.task.executablePath"
    static let systemPromptKey = "vibescroll.task.systemPrompt"
    static let timeoutKey = "vibescroll.task.timeoutMinutes"

    /// A build-and-test task can legitimately run for a long time; past an hour
    /// it is far more likely to be stuck than working.
    static let defaultTimeoutMinutes = 60

    var timeout: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: Self.timeoutKey)
        return TimeInterval(stored > 0 ? stored : Self.defaultTimeoutMinutes) * 60
    }

    /// The instruction appended to every queued prompt. Editable, because what
    /// counts as "blocked" is a house style, but defaulted because a queue that
    /// silently asks questions into the dark is the failure this prevents.
    var systemPromptSuffix: String {
        get {
            UserDefaults.standard.string(forKey: Self.systemPromptKey)
                ?? AgentLaunch.defaultSystemPromptSuffix
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.systemPromptKey) }
    }

    // MARK: - The automatic gate

    /// Whether the queue is allowed to start work on its own.
    ///
    /// **Off by default, and it stays that way until somebody says otherwise.**
    /// Everything else in vibeScroll watches; this drives an AI agent that
    /// edits files while nobody is looking. A watching tool may reasonably
    /// default to on. A driving one may not.
    @Published var autopilot: Bool =
        UserDefaults.standard.bool(forKey: autopilotKey)
    {
        didSet {
            UserDefaults.standard.set(autopilot, forKey: Self.autopilotKey)
            autopilot ? startPolling() : stopPolling()
        }
    }

    private static let autopilotKey = "vibescroll.task.autopilot"

    /// A minute is far shorter than anything the gate measures — the quota
    /// snapshot is allowed to be ten minutes old, the idle requirement is
    /// fifteen, the cooldown is one. Polling faster would ask the same
    /// questions of the same unchanged numbers.
    private static let pollInterval: TimeInterval = 60

    private var pollTimer: Timer?

    /// Called at launch. Does nothing unless the switch is already on, so a
    /// machine that never opted in never starts a timer.
    func start() {
        if autopilot { startPolling() }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval, repeats: true
        ) { _ in
            Task { @MainActor in TaskRunner.shared.tick() }
        }
        // Turning it on should tell you something straight away rather than
        // leaving you to wonder for a minute whether it took. Safe to do
        // immediately: you just clicked, so `requireUserIdle` holds it — the
        // switch cannot launch anything by being flipped.
        tick()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// One turn of the loop: ask the gate, act only on `launch`.
    ///
    /// Every hold is the gate's business, not this method's — the ordering of
    /// the reasons, what counts as too fast, what happens with no quota
    /// reading, all of it is decided and tested in `TaskRunway`. This exists
    /// to do the one thing a pure function cannot.
    func tick(now: Date = Date(), policy: TaskRunway.Policy = .init()) {
        guard autopilot, runningTaskID == nil else { return }
        guard case .launch(let task) = currentDecision(policy: policy) else { return }

        // Both, and said before the run rather than after: the whole point is
        // to know that something started while you were not watching. The card
        // is the ambient version and answers to the cards switch; the
        // notification does not, because "an agent began editing files on its
        // own" is not a thing to miss because you muted a different feature.
        let project = ProjectPath.displayName(task.projectPath)
        CardController.shared.raise(.taskStarted(project: task.projectPath), now: now)
        NotificationManager.shared.notify(
            title: String(localized: "\(project): queue started a task"),
            body: Self.firstLine(task.prompt))
        run(task, policy: policy)
    }

    // MARK: - Running

    func run(_ task: QueuedTask, policy: TaskRunway.Policy = .init()) {
        guard runningTaskID == nil else { return }
        // A task that builds on another starts from that task's branch, so it
        // cannot start before that branch has its work on it — by hand or not.
        let queue = TaskQueueStore.shared.queue
        guard case .ready(let baseBranch) = queue.readiness(of: task) else { return }
        let previousTitle = task.basedOn.flatMap(queue.task(id:))?.displayTitle

        guard let executable = Self.discoverExecutable() else {
            fail(task, .launchFailed, policy: policy,
                 message: String(localized: "Claude Code executable not found. Set its path in Settings \u{203A} Tasks."))
            return
        }
        // A repository with no commit has no HEAD to branch from, so there is
        // nothing to make a worktree out of.
        guard Git.hasCommits(at: task.projectPath) else {
            fail(task, .notAGitRepo, policy: policy,
                 message: String(localized: "\(task.projectPath) is not a git repository with any commits."))
            return
        }

        let sessionId = UUID().uuidString
        let plan = WorktreePlan.plan(
            projectPath: task.projectPath, prompt: task.displayTitle,
            uniqueSuffix: task.id, worktreeRoot: TaskQueueStore.worktreeRoot)
        let prompt = AgentLaunch.composedPrompt(
            instructions: task.prompt, doneWhen: task.doneWhen, continuesFrom: previousTitle)

        // The session id is handed to the agent rather than discovered from it,
        // so the session its hooks report is matched to this task by identity
        // instead of by guessing from paths or timing.
        guard let launch = AgentLaunch.plan(
            for: task.agentKind, executable: executable, prompt: prompt,
            sessionId: sessionId, workingDirectory: plan.path,
            systemPromptSuffix: systemPromptSuffix)
        else {
            fail(task, .launchFailed, policy: policy,
                 message: String(localized: "No headless invocation is known for \(task.agentKind.rawValue)."))
            return
        }

        runningTaskID = task.id
        lastError = nil
        TaskQueueStore.shared.markRunning(
            id: task.id, sessionId: sessionId, worktreeName: plan.slug, worktreePath: plan.path)

        let timeout = self.timeout
        let logPath = Self.logPath(for: task.id)
        let projectPath = task.projectPath
        let commitMessage = Self.commitMessage(for: task)

        let base = baseBranch ?? "HEAD"
        Task.detached(priority: .utility) {
            let outcome = Self.execute(
                launch: launch, worktree: plan, project: projectPath, base: base,
                logPath: logPath, commitMessage: commitMessage, timeout: timeout)
            await MainActor.run { [weak self] in
                self?.finish(task, outcome: outcome, policy: policy)
            }
        }
    }

    // MARK: - Completion

    private struct Outcome {
        let failure: QueuedTask.Failure?
        let exitCode: Int32?
        let result: AgentRunResult?
        let note: String?
        var report: TaskReport? = nil
    }

    private func finish(_ task: QueuedTask, outcome: Outcome, policy: TaskRunway.Policy) {
        runningTaskID = nil
        if let note = outcome.note { lastError = note }
        TaskQueueStore.shared.markFinished(
            id: task.id, exitCode: outcome.exitCode, failure: outcome.failure,
            maxRateLimitRetries: policy.maxRateLimitRetries, report: outcome.report)
        notify(task: task, failure: outcome.failure, result: outcome.result)
    }

    private func fail(
        _ task: QueuedTask, _ failure: QueuedTask.Failure,
        policy: TaskRunway.Policy, message: String
    ) {
        lastError = message
        TaskQueueStore.shared.markFinished(
            id: task.id, exitCode: nil, failure: failure,
            maxRateLimitRetries: policy.maxRateLimitRetries)
        notify(task: task, failure: failure, result: nil)
    }

    private func notify(
        task: QueuedTask, failure: QueuedTask.Failure?, result: AgentRunResult?
    ) {
        let project = ProjectPath.displayName(task.projectPath)
        guard let failure else {
            NotificationManager.shared.notify(
                title: String(localized: "\(project): task finished"),
                body: result?.text ?? Self.firstLine(task.prompt))
            SoundSettings.shared.play(.done)
            return
        }
        NotificationManager.shared.notify(
            title: String(localized: "\(project): task \(Self.label(for: failure))"),
            body: Self.firstLine(task.prompt))
        // A rate-limited task is going back in line rather than needing
        // attention, so it gets the quota sound rather than the alert one.
        SoundSettings.shared.play(failure == .rateLimit ? .quota : .waiting)
    }

    static func label(for failure: QueuedTask.Failure) -> String {
        switch failure {
        case .rateLimit:        return String(localized: "hit a rate limit")
        case .agentError:       return String(localized: "failed")
        case .nonZeroExit:      return String(localized: "exited with an error")
        case .unreadableResult: return String(localized: "produced no readable result")
        case .timedOut:         return String(localized: "timed out")
        case .launchFailed:     return String(localized: "could not start")
        case .notAGitRepo:      return String(localized: "has no git repository")
        }
    }

    // MARK: - The blocking part

    private nonisolated static func execute(
        launch: AgentLaunch.Plan, worktree: WorktreePlan.Plan, project: String, base: String,
        logPath: String, commitMessage: String, timeout: TimeInterval
    ) -> Outcome {
        var log = "$ git worktree add -b \(worktree.branch) \(worktree.path) \(base)\n"
        let started = Date()

        guard Git.addWorktree(project: project, path: worktree.path, branch: worktree.branch,
                              base: base) else {
            write(log + "worktree creation failed\n", to: logPath)
            return Outcome(failure: .launchFailed, exitCode: nil, result: nil,
                           note: String(localized: "Could not create the worktree at \(worktree.path)."))
        }

        log += "$ \(launch.executable) \(launch.arguments.joined(separator: " "))\n\n"
        let run = runProcess(launch, timeout: timeout)
        log += String(decoding: run.stdout, as: UTF8.self)
        if !run.stderr.isEmpty {
            log += "\n--- stderr ---\n" + String(decoding: run.stderr, as: UTF8.self)
        }

        let (failure, result) = TaskOutcome.classify(
            exitCode: run.exitCode, stdout: run.stdout, timedOut: run.timedOut)
        let baseCommit = Git.head(in: worktree.path)
        // Read before any commit, and whatever the outcome: a blocker is most
        // worth reading exactly when the run did not succeed.
        let blocker = readBlocker(in: worktree.path)
        var committed = false

        // Only a clean run is committed: a half-finished attempt is more useful
        // left as it fell, where the working tree itself shows how far it got.
        var note: String?
        if failure == nil {
            switch Git.commitAll(worktree: worktree.path, message: commitMessage) {
            case .committed:
                committed = true
                log += "\n--- committed to \(worktree.branch) ---\n"
            case .nothingToCommit:
                log += "\n--- nothing to commit ---\n"
            case .failed(let reason):
                // The work is still there and still the point; only the tidy-up
                // failed, so this is reported rather than turned into a failure.
                log += "\n--- commit failed: \(reason) ---\n"
                note = String(localized: "Task finished but the commit failed: \(reason)")
            }
        }

        write(log, to: logPath)
        let report = TaskReport(
            summary: result?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            blocker: blocker,
            changedFiles: Git.changedFiles(in: worktree.path, since: baseCommit,
                                           committed: committed),
            committed: committed,
            baseCommit: baseCommit,
            durationSeconds: Date().timeIntervalSince(started),
            inputTokens: result?.inputTokens ?? 0,
            outputTokens: result?.outputTokens ?? 0)
        return Outcome(failure: failure, exitCode: run.exitCode, result: result, note: note,
                       report: report)
    }

    /// `BLOCKED.md`, where the unattended instructions ask the agent to say
    /// why it stopped. Capped: it is shown in a settings row, not a document
    /// viewer, and the whole file is still in the worktree.
    private nonisolated static func readBlocker(in worktree: String) -> String? {
        let path = (worktree as NSString).appendingPathComponent("BLOCKED.md")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 1500 ? String(trimmed.prefix(1499)) + "\u{2026}" : trimmed
    }

    private struct ProcessRun {
        let exitCode: Int32?
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
    }

    /// Runs the agent, collecting output as it arrives rather than after exit —
    /// a pipe that fills while nobody is draining it deadlocks the child.
    private nonisolated static func runProcess(
        _ plan: AgentLaunch.Plan, timeout: TimeInterval
    ) -> ProcessRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory)

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let buffers = OutputBuffers()
        out.fileHandleForReading.readabilityHandler = { buffers.appendOut($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { buffers.appendErr($0.availableData) }

        do {
            try process.run()
        } catch {
            return ProcessRun(exitCode: nil, stdout: Data(),
                              stderr: Data(error.localizedDescription.utf8), timedOut: false)
        }

        // Recorded by whoever fires the deadline rather than inferred from the
        // exit status afterwards: a process killed for any other reason also
        // exits on a signal, and calling that a timeout would be a lie.
        let expired = Flag()
        let deadline = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            expired.set()
            process.terminate()
            // A SIGTERM the agent ignores must not leave the queue wedged.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        process.waitUntilExit()
        deadline.cancel()
        let timedOut = expired.isSet

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        // The process exiting does not mean every byte has been through the
        // handlers: the last chunk can still be sitting in the pipe. The agent's
        // result JSON is the last thing it writes, so dropping that chunk
        // turned a finished task into "produced no readable result". Whatever
        // is left is read here, now that the writer is gone.
        buffers.appendOut(out.fileHandleForReading.readDataToEndOfFile())
        buffers.appendErr(err.fileHandleForReading.readDataToEndOfFile())

        return ProcessRun(
            exitCode: process.terminationStatus,
            stdout: buffers.out, stderr: buffers.err, timedOut: timedOut)
    }

    /// Set from the timeout queue, read from the waiting thread.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Output arrives on the pipes' own queues, so the buffers need a lock.
    private final class OutputBuffers: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()

        func appendOut(_ data: Data) { lock.lock(); outData.append(data); lock.unlock() }
        func appendErr(_ data: Data) { lock.lock(); errData.append(data); lock.unlock() }
        var out: Data { lock.lock(); defer { lock.unlock() }; return outData }
        var err: Data { lock.lock(); defer { lock.unlock() }; return errData }
    }

    // MARK: - Helpers

    static func logPath(for taskID: String) -> String {
        (TaskQueueStore.logDir as NSString).appendingPathComponent("\(taskID).log")
    }

    private nonisolated static func write(_ text: String, to path: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func firstLine(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).first ?? text
        return line.count > 80 ? String(line.prefix(79)) + "\u{2026}" : line
    }

    static func commitMessage(for task: QueuedTask) -> String {
        "vibescroll: \(task.displayTitle)"
    }

    /// Finds the Claude Code binary.
    ///
    /// PATH is checked last and matters least: the app runs from Launch
    /// Services with a minimal environment, and the common install here ships
    /// inside the VS Code extension, which is not on PATH at all. Newest by
    /// modification time rather than by parsing the version out of the
    /// directory name, which sorts "2.1.9" above "2.1.226".
    static func discoverExecutable() -> String? {
        let fm = FileManager.default
        if let override = UserDefaults.standard.string(forKey: executableKey),
           !override.isEmpty, fm.isExecutableFile(atPath: override) {
            return override
        }

        let extensions = NSHomeDirectory() + "/.vscode/extensions"
        if let entries = try? fm.contentsOfDirectory(atPath: extensions) {
            let candidates = entries
                .filter { $0.hasPrefix("anthropic.claude-code-") }
                .map { extensions + "/" + $0 }
                .sorted { modified($0) > modified($1) }
                .map { $0 + "/resources/native-binary/claude" }
            if let hit = candidates.first(where: fm.isExecutableFile(atPath:)) { return hit }
        }

        let home = NSHomeDirectory()
        for path in [home + "/.claude/local/claude", home + "/.local/bin/claude",
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func modified(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast
    }
}

// MARK: - The gate, read-only for now

import CoreGraphics

extension TaskRunner {
    /// Seconds since the last keyboard or mouse event, or `nil` if it could not
    /// be read. Needs no accessibility permission — unlike an event tap, this
    /// only asks how long ago something happened.
    static func userIdleSeconds() -> TimeInterval? {
        guard let anyInput = CGEventType(rawValue: ~0) else { return nil }
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: anyInput)
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    /// What the queue would do right now.
    func currentDecision(policy: TaskRunway.Policy = .init()) -> TaskRunway.Decision {
        let queue = TaskQueueStore.shared.queue
        return TaskRunway.decide(
            queue: queue,
            snapshot: UsageProbe.shared.snapshot,
            liveSessions: AppDaemon.shared.sessions,
            userIdleFor: Self.userIdleSeconds(),
            lastFinishedAt: queue.tasks.compactMap(\.finishedAt).max(),
            policy: policy,
            now: Date())
    }
}
