import Foundation

/// A single state-change report from an agent, sent by the CLI helper to the
/// daemon. `eventName` is the agent-native event (e.g. Claude Code's "Stop");
/// `StateMapper` turns it into an `AgentState`.
///
/// Unlike a pure monitor, vibeScroll also needs the *subject* of the work, so
/// the raw category signal travels on the event: `toolName` plus `toolTarget`
/// (the file path, shell command or query the tool was given). The daemon runs
/// `CategoryResolver` over those to pick the topic — keeping the wire format
/// small and the classification in one testable place.
public struct AgentEvent: Codable, Sendable, Equatable {
    public var sessionId: String
    public var agentKind: AgentKind
    public var eventName: String
    public var project: String?
    public var message: String?
    /// Display name of the LLM model in use (e.g. "Sonnet 4.6"), if the hook
    /// payload included one. `nil` when the agent doesn't report it.
    public var model: String?
    /// Path to the agent's conversation transcript file (e.g. Claude Code JSONL).
    /// Used to derive a human-readable title and to read usage.
    public var transcriptPath: String?
    /// Subagent identifier from a `SubagentStop` event (e.g. `"agent-abc123"`).
    public var subagentId: String?
    /// Tool the agent is invoking (e.g. `"Bash"`, `"Edit"`, `"read_file"`).
    /// Primary category signal.
    public var toolName: String?
    /// What the tool was pointed at: file path, shell command, search pattern or
    /// URL — whichever the payload carried. Refines `toolName` into a topic
    /// (e.g. `Bash` + `git commit` → `.versionControl`). Truncated at the hook.
    public var toolTarget: String?
    /// `TERM_PROGRAM` of the terminal the agent runs in (e.g. `"iTerm.app"`).
    /// Used to focus that terminal when the user clicks a card's session row.
    public var terminalProgram: String?
    /// Controlling TTY device of the terminal (e.g. `"/dev/ttys003"`), used to
    /// activate the exact window/tab in Terminal.app and iTerm2.
    public var terminalTTY: String?
    /// Deep link that focuses the exact tab/pane (Warp's `WARP_FOCUS_URL`).
    public var terminalFocusURL: String?
    /// Bundle id of the app hosting this session (see `TerminalInfo.Captured`).
    public var hostBundleID: String?
    public var timestamp: Date

    public init(
        sessionId: String,
        agentKind: AgentKind,
        eventName: String,
        project: String? = nil,
        message: String? = nil,
        model: String? = nil,
        transcriptPath: String? = nil,
        subagentId: String? = nil,
        toolName: String? = nil,
        toolTarget: String? = nil,
        terminalProgram: String? = nil,
        terminalTTY: String? = nil,
        terminalFocusURL: String? = nil,
        hostBundleID: String? = nil,
        timestamp: Date
    ) {
        self.sessionId = sessionId
        self.agentKind = agentKind
        self.eventName = eventName
        self.project = project
        self.message = message
        self.model = model
        self.transcriptPath = transcriptPath
        self.subagentId = subagentId
        self.toolName = toolName
        self.toolTarget = toolTarget
        self.terminalProgram = terminalProgram
        self.terminalTTY = terminalTTY
        self.terminalFocusURL = terminalFocusURL
        self.hostBundleID = hostBundleID
        self.timestamp = timestamp
    }
}
