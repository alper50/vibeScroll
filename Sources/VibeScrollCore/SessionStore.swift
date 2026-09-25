import Foundation

/// In-memory store of agent sessions.
///
/// Pure logic, deliberately not thread-safe and free of wall-clock reads:
/// callers pass `now` so behaviour is deterministic and testable. The daemon
/// confines all access to the main actor.
public final class SessionStore {
    /// `done` sessions fall back to `idle` after this much quiet time.
    public var doneToIdleAfter: TimeInterval
    /// `idle` sessions are removed after this much quiet time.
    public var removeIdleAfter: TimeInterval
    /// Working/waiting sessions with no update for this long are removed: the
    /// agent almost certainly died without a `Stop` event.
    public var staleActiveAfter: TimeInterval
    /// The same, for a session that went quiet *inside a tool call*. A build or
    /// a test suite reports nothing while it runs, so the short window made a
    /// ten-minute one vanish from the list mid-run and reappear as `done` when
    /// it finished. Silence there is expected, not evidence of death.
    public var staleToolCallAfter: TimeInterval
    /// A merely `registered` session (agent open but never started working) is
    /// dropped sooner: it reappears as `working` the moment the agent does
    /// anything, so a quiet/abandoned one shouldn't linger as "running".
    public var staleRegisteredAfter: TimeInterval

    private var byID: [String: AgentSession] = [:]

    public init(doneToIdleAfter: TimeInterval = 30,
                removeIdleAfter: TimeInterval = 600,
                staleActiveAfter: TimeInterval = 300,
                staleToolCallAfter: TimeInterval = 1800,
                staleRegisteredAfter: TimeInterval = 90) {
        self.doneToIdleAfter = doneToIdleAfter
        self.removeIdleAfter = removeIdleAfter
        self.staleActiveAfter = staleActiveAfter
        self.staleToolCallAfter = staleToolCallAfter
        self.staleRegisteredAfter = staleRegisteredAfter
    }

    public func clear() { byID.removeAll() }

    public func remove(id: String) { byID.removeValue(forKey: id) }

    /// Updates the display title for a session. Called asynchronously after
    /// transcript title resolution completes off the main thread.
    public func updateTitle(id: String, title: String) {
        guard byID[id] != nil else { return }
        byID[id]?.title = title
    }

    /// Updates the display model for a session, picking up a `/model` switch
    /// mid-session that hook payloads don't report.
    public func updateModel(id: String, model: String) {
        guard byID[id] != nil else { return }
        byID[id]?.model = model
    }

    /// Adds a usage delta to a session's running total.
    ///
    /// Deltas, not totals: `TranscriptReader` reads incrementally from a stored
    /// byte offset, so each scan returns only what is new. Adding is therefore
    /// the correct operation, and a scan that races with `prune` deleting the
    /// session is simply dropped rather than resurrecting it.
    public func addUsage(id: String, tokens: Int, costUSD: Double) {
        guard var session = byID[id] else { return }
        session.tokens = (session.tokens ?? 0) + max(0, tokens)
        session.costUSD = (session.costUSD ?? 0) + max(0, costUSD)
        byID[id] = session
    }

    /// Corrects a session's state after the fact — used when an async check
    /// (e.g. reading the transcript to see how the agent ended its turn)
    /// determines the state we set synchronously was wrong.
    ///
    /// Only applies when the session is *still* in `expected` state from the
    /// *same* transition (`since` matches `stateSince`): if a newer event has
    /// already moved the session on, this is a no-op — the correction targets
    /// a transition that no longer exists, and must never clobber fresher
    /// state. `stateSince` is preserved (this corrects the existing
    /// transition; it isn't a new one).
    public func refineState(id: String, from expected: AgentState, to refined: AgentState, since: Date) {
        guard var session = byID[id], session.state == expected, session.stateSince == since else { return }
        session.state = refined
        byID[id] = session
    }

    /// Applies an event, creating or updating the matching session.
    /// Returns the updated session, or `nil` if the event maps to no state.
    @discardableResult
    public func apply(_ event: AgentEvent, now: Date) -> AgentSession? {
        // A session-end event (agent quit/closed) removes the session at once,
        // so it doesn't linger as "done" until the idle timeout.
        if StateMapper.isSessionEnd(for: event.agentKind, eventName: event.eventName) {
            byID.removeValue(forKey: event.sessionId)
            return nil
        }
        guard let state = StateMapper.state(for: event.agentKind, eventName: event.eventName) else {
            return nil
        }

        // Recovered from the transcript's location when the agent reports one
        // (Claude Code does); that beats any `cwd` seen, which may already be
        // a subfolder if the app started mid-session.
        let root = event.project.flatMap { cwd in
            event.transcriptPath.flatMap { ProjectPath.sessionRoot(cwd: cwd, transcriptPath: $0) }
        }

        // A tool event with no usable signal keeps the previous topic rather
        // than resetting to `.generic` — see CategoryResolver.category.
        let resolvedTopic = CategoryResolver.category(
            toolName: event.toolName, target: event.toolTarget
        )

        // Recomputed on every event rather than only being set: any event that
        // is not a tool-call start clears it, which is exactly when the agent
        // has started reporting again.
        let inToolCall = StateMapper.isToolCallStart(
            for: event.agentKind, eventName: event.eventName
        )

        if var existing = byID[event.sessionId] {
            if existing.state != state { existing.stateSince = now }
            existing.state = state
            existing.updatedAt = now
            if let project = event.project { existing.project = project }
            // Sticky: the first folder seen, unless the transcript says better.
            if let root { existing.workspace = root }
            else if existing.workspace == nil { existing.workspace = event.project }
            if let model = event.model { existing.model = model }
            if let program = event.terminalProgram { existing.terminalProgram = program }
            if let tty = event.terminalTTY { existing.terminalTTY = tty }
            if let focusURL = event.terminalFocusURL { existing.terminalFocusURL = focusURL }
            if let host = event.hostBundleID { existing.hostBundleID = host }
            if let toolName = event.toolName { existing.toolName = toolName }
            existing.isInToolCall = inToolCall
            if let resolvedTopic, resolvedTopic != existing.topic {
                existing.topic = resolvedTopic
                existing.topicSince = now
            }
            existing.message = event.message
            byID[event.sessionId] = existing
            return existing
        }

        let session = AgentSession(
            id: event.sessionId,
            agentKind: event.agentKind,
            project: event.project,
            workspace: root ?? event.project,
            state: state,
            message: event.message,
            model: event.model,
            toolName: event.toolName,
            isInToolCall: inToolCall,
            topic: resolvedTopic,
            source: .hook,
            updatedAt: now,
            terminalProgram: event.terminalProgram,
            terminalTTY: event.terminalTTY,
            terminalFocusURL: event.terminalFocusURL,
            hostBundleID: event.hostBundleID
        )
        byID[event.sessionId] = session
        return session
    }

    /// Demotes stale `done` sessions to `idle`, removes long-idle ones, and
    /// drops active sessions that have gone quiet (agent died without `Stop`).
    public func prune(now: Date) {
        for id in Array(byID.keys) {
            guard let session = byID[id] else { continue }
            let quiet = now.timeIntervalSince(session.updatedAt)
            switch session.state {
            case .done:
                if quiet >= doneToIdleAfter {
                    var s = session
                    s.state = .idle
                    s.updatedAt = now
                    s.stateSince = now
                    byID[id] = s
                }
            case .idle:
                if quiet >= removeIdleAfter { byID.removeValue(forKey: id) }
            case .registered:
                if quiet >= staleRegisteredAfter { byID.removeValue(forKey: id) }
            case .working, .waiting:
                // Inside a tool call the agent is *meant* to be silent for as
                // long as the tool takes; only the short window carries the
                // meaning "died without a Stop".
                let limit = session.isInToolCall ? staleToolCallAfter : staleActiveAfter
                if quiet >= limit { byID.removeValue(forKey: id) }
            }
        }
    }

    public var sessions: [AgentSession] { Array(byID.values) }

    /// Sessions ordered by attention priority then recency, for display.
    public var sorted: [AgentSession] {
        byID.values.sorted { lhs, rhs in
            let lp = lhs.state.attentionPriority
            let rp = rhs.state.attentionPriority
            if lp != rp { return lp > rp }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public func session(id: String) -> AgentSession? { byID[id] }
}

extension AgentState {
    /// Higher means more deserving of the user's attention.
    var attentionPriority: Int {
        switch self {
        case .working: return 4
        case .waiting: return 3
        case .done: return 2
        case .registered: return 1
        case .idle: return 0
        }
    }
}
