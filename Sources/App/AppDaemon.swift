import Foundation
import VibeScrollCore

/// Owns the live session state inside the running app: starts the socket
/// server, drains any queued events on launch, applies incoming events and
/// prunes stale ones, and publishes a display-ordered list to the UI.
///
/// All `SessionStore` access is confined to the main actor. Transcript reads
/// happen off it — they are file IO plus JSON parsing, and running them inline
/// would stutter the UI during heavy agent activity.
@MainActor
final class AppDaemon: ObservableObject {
    static let shared = AppDaemon()

    @Published private(set) var sessions: [AgentSession] = []

    private let store = SessionStore()
    fileprivate let server = EventSocketServer(path: VibeScrollPaths.socketPath)
    private var pruneTimer: Timer?

    func start() {
        // A stray write to a peer that already went away must return EPIPE, not
        // SIGPIPE-kill the whole app.
        signal(SIGPIPE, SIG_IGN)
        try? FileManager.default.createDirectory(
            atPath: VibeScrollPaths.baseDir, withIntermediateDirectories: true
        )

        // Replay queued events with their original timestamps (not "now"), so
        // sessions that ended while the app was closed look stale and get
        // pruned immediately instead of resurrecting as "working".
        EventSocketServer.drainQueue(directory: VibeScrollPaths.queueDir) { [store] event in
            store.apply(event, now: event.timestamp)
        }
        store.prune(now: Date())
        refresh()

        try? server.start { event in
            Task { @MainActor [weak self] in self?.ingest(event) }
        }

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.prune() }
        }
    }

    func clearSessions() {
        store.clear()
        refresh()
    }

    func removeSession(_ id: String) {
        store.remove(id: id)
        refresh()
    }

    // MARK: - Ingest

    private func ingest(_ event: AgentEvent) {
        let before = store.session(id: event.sessionId)?.state
        guard let updated = store.apply(event, now: Date()) else {
            // Events that map to no state still carry usage — a finished
            // subagent is the main one, and its tokens belong to the parent.
            feedSubagentUsage(for: event)
            refresh()
            return
        }
        resolveTitle(for: event)
        resolveModel(for: event)
        feedUsage(for: event)

        // Claude's Stop hook fires identically whether the agent is truly done
        // or just ended its turn by asking the user a question — hold the
        // notification until an async transcript check resolves, so we fire
        // exactly one notification reflecting the true final state.
        if event.agentKind == .claude, event.eventName == "Stop", updated.state == .done {
            refineDoneIfQuestion(event: event, before: before, session: updated)
        } else {
            notifyIfNeeded(before: before, session: updated)
        }
        refresh()
    }

    /// The agent's transcript for this event: the path the hook reported, or the
    /// one Claude Code's layout implies. One helper because three separate
    /// features need the same fallback and must never disagree about it.
    private func transcriptPath(for event: AgentEvent) -> String? {
        event.transcriptPath
            ?? event.project.map { TranscriptReader.inferredPath(sessionId: event.sessionId, cwd: $0) }
    }

    // MARK: - Token usage

    /// Reading a transcript is the heaviest per-event work in the app, and tool
    /// events arrive several times a second. Ten seconds is frequent enough for
    /// a number the user glances at, and reads are incremental so nothing is
    /// lost by skipping a scan — the next one picks up everything since.
    private let usageThrottle = PerKeyThrottle(interval: 10)

    /// Resolved rollout path per Codex session. Finding it means enumerating
    /// `~/.codex/sessions`, so it is done once per session, not once per event.
    private var codexPathBySession: [String: String] = [:]

    private func feedUsage(for event: AgentEvent) {
        switch event.agentKind {
        case .claude:
            // Claude's Stop is handled in refineDoneIfQuestion, which already
            // reads this file — feeding here too would double the IO.
            guard event.eventName != "Stop" else { return }
            guard usageThrottle.shouldRun(event.sessionId, now: Date()) else { return }
            guard let path = transcriptPath(for: event) else { return }
            readClaudeUsage(at: path, creditingSession: event.sessionId)
        case .codex:
            feedCodexUsage(for: event)
        default:
            // The other nine agents write no transcript we can read, so their
            // sessions keep `tokens == nil` — unknown, deliberately not zero.
            return
        }
    }

    /// A finished subagent's tokens belong to the session that spawned it.
    /// `SubagentStop` maps to no state change, so this runs off the branch
    /// where `apply` returned nil.
    private func feedSubagentUsage(for event: AgentEvent) {
        guard event.eventName == "SubagentStop" || event.eventName == "subagentStop" else { return }
        guard event.agentKind == .claude || event.agentKind == .droid else { return }
        guard let agentId = event.subagentId, let parent = transcriptPath(for: event) else { return }
        let path = TranscriptReader.subagentTranscriptPath(
            parentTranscriptPath: parent, agentId: agentId)
        readClaudeUsage(at: path, creditingSession: event.sessionId)
    }

    /// Scans `path` for usage appended since the last scan and adds it to
    /// `sessionId`'s total. Offsets are held per path inside `TranscriptReader`,
    /// so a subagent file and its parent never double-count each other.
    private func readClaudeUsage(at path: String, creditingSession sessionId: String) {
        Task.detached(priority: .utility) { [weak self] in
            guard let delta = TranscriptReader.newUsageDelta(at: path) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if delta.tokens > 0 {
                    self.store.addUsage(id: sessionId, tokens: delta.tokens, costUSD: delta.costUSD)
                    self.refresh()
                }
                self.reportRateLimit(delta.apiErrors, sessionId: sessionId)
            }
        }
    }

    /// Alerts when the agent gave up on a rate limit.
    ///
    /// Two filters, both deliberate. Only `.rateLimit`: a 529 overload means the
    /// provider is busy, not that your quota is gone, and conflating them would
    /// send people to check a limit they have not hit. Only the final attempt:
    /// earlier ones usually recover on their own — in real transcripts a single
    /// stall produced ten error records, of which nine resolved themselves.
    private func reportRateLimit(_ errors: [TranscriptAPIError], sessionId: String) {
        guard errors.contains(where: { $0.kind == .rateLimit && $0.isFinalAttempt }) else { return }
        // Same reason as `notifyIfNeeded`: a rate-limited task is put back in
        // line by the runner, which says so itself.
        guard !TaskQueueStore.shared.ownsSession(sessionId) else { return }
        let project = store.session(id: sessionId)?.project.map(ProjectPath.displayName)
            ?? sessionId
        NotificationManager.shared.notify(
            title: "\(project) hit a rate limit",
            body: "The agent gave up after exhausting its retries.")
        SoundSettings.shared.play(.quota)
    }

    private func feedCodexUsage(for event: AgentEvent) {
        // Stop bypasses the throttle: the final turn's tokens land right before
        // it, and a throttled skip there would lose them for good.
        let isStop = event.eventName == "Stop"
        if !isStop, !usageThrottle.shouldRun(event.sessionId, now: Date()) { return }

        let sessionId = event.sessionId
        let project = event.project
        let cachedPath = codexPathBySession[sessionId]
        Task.detached(priority: .utility) { [weak self] in
            guard let path = cachedPath
                ?? TranscriptReader.codexRolloutPath(sessionId: sessionId, cwd: project) else { return }
            let tokens = TranscriptReader.newCodexUsageTokens(at: path) ?? 0
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.codexPathBySession[sessionId] = path
                guard tokens > 0 else { return }
                // Codex's rollout reports counts without a per-model breakdown,
                // so there is nothing to price — cost stays at zero rather than
                // being guessed.
                self.store.addUsage(id: sessionId, tokens: tokens, costUSD: 0)
                self.refresh()
            }
        }
    }

    // MARK: - Async refinements

    /// Reads the transcript off-thread to check whether the agent ended its turn
    /// by asking the user something; if so, corrects `.done` to `.waiting`.
    /// Either way, banks the turn's tokens and fires the single, final-state
    /// notification afterwards.
    private func refineDoneIfQuestion(event: AgentEvent, before: AgentState?, session: AgentSession) {
        let sessionId = event.sessionId
        let stateSince = session.stateSince
        guard let path = transcriptPath(for: event) else {
            notifyIfNeeded(before: before, session: session)
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let isQuestion = TranscriptReader.latestAssistantText(at: path)
                .map(QuestionDetector.looksLikeQuestion) ?? false
            // The turn just ended either way — bank whatever it burned.
            let delta = TranscriptReader.newUsageDelta(at: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let delta, delta.tokens > 0 {
                    self.store.addUsage(id: sessionId, tokens: delta.tokens, costUSD: delta.costUSD)
                }
                if let delta { self.reportRateLimit(delta.apiErrors, sessionId: sessionId) }
                if isQuestion {
                    self.store.refineState(id: sessionId, from: .done, to: .waiting, since: stateSince)
                }
                guard let final = self.store.session(id: sessionId) else { return }
                self.notifyIfNeeded(before: before, session: final)
                self.refresh()
            }
        }
    }

    private func resolveTitle(for event: AgentEvent) {
        // A title, once resolved, is stable — stop re-reading the transcript
        // head on every subsequent event of the same session.
        guard store.session(id: event.sessionId)?.title == nil else { return }
        let sessionId = event.sessionId
        guard let path = transcriptPath(for: event) else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let title = TranscriptReader.title(at: path) else { return }
            await MainActor.run { [weak self] in
                self?.store.updateTitle(id: sessionId, title: title)
                self?.refresh()
            }
        }
    }

    /// Reading the transcript tail to detect a `/model` switch is expensive
    /// (128 KB read plus a JSON parse per line). The model rarely changes
    /// mid-session and its initial value already comes from the hook payload,
    /// so throttle this hard rather than running it on every event.
    private let modelResolveThrottle = PerKeyThrottle(interval: 30)

    private func resolveModel(for event: AgentEvent) {
        guard event.agentKind == .claude else { return }
        guard modelResolveThrottle.shouldRun(event.sessionId, now: Date()) else { return }
        let sessionId = event.sessionId
        guard let path = transcriptPath(for: event) else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let model = TranscriptReader.latestAssistantModel(at: path) else { return }
            await MainActor.run { [weak self] in
                self?.store.updateModel(id: sessionId, model: model)
                self?.refresh()
            }
        }
    }

    private func notifyIfNeeded(before: AgentState?, session: AgentSession) {
        guard session.state != before else { return }
        // A queued task announces its own outcome, and does it better: the
        // runner knows whether the run hit a rate limit, timed out or simply
        // failed, none of which a state transition can tell apart. Alerting
        // here as well would report every task twice.
        guard !TaskQueueStore.shared.ownsSession(session.id) else { return }
        let project = session.project.map(ProjectPath.displayName) ?? session.id
        switch session.state {
        case .waiting:
            NotificationManager.shared.notify(
                title: "\(project) needs input", body: session.message ?? "Waiting for you")
            SoundSettings.shared.play(.waiting)
        case .done:
            NotificationManager.shared.notify(
                title: "\(project) finished", body: "Agent completed its turn")
            SoundSettings.shared.play(.done)
        default:
            break
        }
    }

    private func prune() {
        store.prune(now: Date())
        guard store.sorted != sessions else { return }
        refresh()
    }

    private func refresh() {
        sessions = store.sorted
        StatusBarController.shared.updateStatus(sessions)
        CardController.shared.consider(sessions: sessions)
    }
}

extension AppDaemon {
    /// Closes the listen socket and unlinks its path. Called at termination so
    /// the next launch binds cleanly; until then hooks fall back to the queue.
    func stopServer() {
        server.stop()
    }
}
