import Foundation

/// The JSON Claude Code writes to a hook's stdin. Only the fields vibeScroll
/// needs are decoded; the rest are ignored.
///
/// Also used verbatim for every agent that copied Claude's snake_case shape:
/// Codex, Gemini, Factory Droid, GitHub Copilot and Kiro CLI. `makeEvent`
/// takes the `kind` so one decoder serves them all.
public struct ClaudeHookPayload: Decodable, Equatable {
    public let sessionId: String?
    public let cwd: String?
    public let hookEventName: String?
    public let message: String?
    public let toolName: String?
    public let toolInput: ToolActivityInput?
    public let model: HookModelInfo?
    /// Absolute path to the conversation's JSONL transcript file.
    public let transcriptPath: String?
    /// Unique identifier of the subagent, present on `SubagentStop` events.
    public let agentId: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case message
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case model
        case transcriptPath = "transcript_path"
        case agentId = "agent_id"
    }

    public static func decode(from data: Data) -> ClaudeHookPayload? {
        try? JSONDecoder().decode(ClaudeHookPayload.self, from: data)
    }

    /// Builds an `AgentEvent`, or `nil` if session id / event name are missing.
    public func makeEvent(now: Date, kind: AgentKind = .claude) -> AgentEvent? {
        guard let sessionId, let hookEventName else { return nil }
        let context = ActivitySummary.message(
            eventName: hookEventName, toolName: toolName,
            toolInput: toolInput, explicitMessage: message
        )
        return AgentEvent(
            sessionId: sessionId, agentKind: kind, eventName: hookEventName,
            project: cwd, message: context, model: model?.displayName,
            transcriptPath: transcriptPath, subagentId: agentId,
            toolName: toolName, toolTarget: toolInput?.target, timestamp: now
        )
    }
}
