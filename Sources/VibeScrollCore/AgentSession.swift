import Foundation

/// Current known state of one agent session.
public struct AgentSession: Identifiable, Sendable, Equatable {
    public let id: String
    public var agentKind: AgentKind
    public var project: String?
    /// Human-readable conversation title (e.g. Claude Code's summary, or first
    /// user message). Populated lazily from the transcript when available.
    public var title: String?
    public var state: AgentState
    public var message: String?
    /// Display name of the LLM model in use. Sticky: once set, persists across
    /// later events that omit it.
    public var model: String?
    /// Tool the agent last invoked. Sticky within a state, cleared on `done`.
    public var toolName: String?
    /// Whether the last event was the *start* of a tool call, meaning the agent
    /// is inside one and will report nothing until it returns. Pruning reads it
    /// to tell a long build apart from an agent that died — see
    /// `StateMapper.isToolCallStart`.
    public var isInToolCall: Bool
    /// Topic the session is currently working on, resolved by `CategoryResolver`
    /// from the latest tool event. Drives which info card is shown. Sticky: a
    /// tool event with no usable signal keeps the previous topic rather than
    /// dropping to `.generic`, so the card doesn't flicker between tool calls.
    public var topic: TopicCategory?
    public var source: AgentSource
    public var updatedAt: Date
    /// When the session entered its current `state`; resets on state change.
    public var stateSince: Date
    /// When the session was first created (first `apply` event).
    public var createdAt: Date
    /// When `topic` last changed. Lets the card scheduler avoid re-showing a
    /// card for a topic the session has been sitting on.
    public var topicSince: Date
    public var terminalProgram: String?
    public var terminalTTY: String?
    public var terminalFocusURL: String?
    /// Bundle id of the app hosting this session. Sticky — it is what routes a
    /// click on the session row to the right window.
    public var hostBundleID: String?
    /// Tokens this session has burned so far, accumulated from the agent's
    /// transcript. `nil` means *unknown*, not zero: only Claude and Codex write
    /// a transcript we can read, and reporting 0 for the other nine agents
    /// would be a lie rather than a gap.
    public var tokens: Int?
    /// Estimated USD for those tokens, accumulated from the same scan. Recorded
    /// but not displayed — `ModelPricing` matches model families by substring
    /// against a hardcoded rate table, so it drifts silently when prices change.
    /// A wrong number with a currency symbol is worse than no number.
    public var costUSD: Double?

    public init(
        id: String,
        agentKind: AgentKind,
        project: String? = nil,
        title: String? = nil,
        state: AgentState,
        message: String? = nil,
        model: String? = nil,
        toolName: String? = nil,
        isInToolCall: Bool = false,
        topic: TopicCategory? = nil,
        source: AgentSource,
        updatedAt: Date,
        stateSince: Date? = nil,
        createdAt: Date? = nil,
        topicSince: Date? = nil,
        terminalProgram: String? = nil,
        terminalTTY: String? = nil,
        terminalFocusURL: String? = nil,
        hostBundleID: String? = nil,
        tokens: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.id = id
        self.agentKind = agentKind
        self.project = project
        self.title = title
        self.state = state
        self.message = message
        self.model = model
        self.toolName = toolName
        self.isInToolCall = isInToolCall
        self.topic = topic
        self.source = source
        self.updatedAt = updatedAt
        self.stateSince = stateSince ?? updatedAt
        self.createdAt = createdAt ?? updatedAt
        self.topicSince = topicSince ?? updatedAt
        self.terminalProgram = terminalProgram
        self.terminalTTY = terminalTTY
        self.terminalFocusURL = terminalFocusURL
        self.hostBundleID = hostBundleID
        self.tokens = tokens
        self.costUSD = costUSD
    }
}
