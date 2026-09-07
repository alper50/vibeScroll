import Foundation

/// Maps an agent-native event name to a normalised `AgentState`.
///
/// Returns `nil` for events that should not change state (unknown or
/// irrelevant events are ignored rather than treated as an error).
public enum StateMapper {
    /// Events that mean the whole session ended (the agent was quit/closed), so
    /// the session should be removed immediately rather than lingering as done.
    public static func isSessionEnd(for kind: AgentKind, eventName: String) -> Bool {
        switch kind {
        case .claude: return eventName == "SessionEnd"
        case .gemini: return eventName == "SessionEnd"
        case .cursor: return eventName == "sessionEnd"
        case .droid: return eventName == "SessionEnd"
        case .grok: return eventName == "session_end"
        default: return false
        }
    }

    /// Events that mean the agent just *entered* a tool call, and so will be
    /// silent until that call returns.
    ///
    /// Nothing is emitted while a tool runs, which makes a ten-minute build look
    /// exactly like a dead agent to `SessionStore.prune`. Knowing the session is
    /// inside a call is what lets pruning wait longer before declaring it gone.
    ///
    /// There is deliberately no matching "tool ended" list: the flag is cleared
    /// by the next event of any kind, so it stays set for precisely the window
    /// where the agent is legitimately quiet. Agents whose `PreToolUse` we
    /// refuse to register (Copilot, Kiro, Grok) simply keep the short window.
    public static func isToolCallStart(for kind: AgentKind, eventName: String) -> Bool {
        switch kind {
        case .claude, .codex, .droid, .copilot, .antigravity:
            return eventName == "PreToolUse"
        case .kiroCLI:
            return eventName == "preToolUse" || eventName == "PreToolUse"
        case .cursor:
            return eventName == "preToolUse" || eventName == "beforeShellExecution"
        case .gemini:
            return eventName == "BeforeTool"
        case .grok:
            return eventName == "pre_tool_use"
        case .pi:
            return eventName == "tool_execution_start"
        // Windsurf and opencode report only turn boundaries, and the `run`
        // wrapper sends normalised states on its own heartbeat.
        case .windsurf, .opencode, .cli, .unknown:
            return false
        }
    }

    public static func state(for kind: AgentKind, eventName: String) -> AgentState? {
        // Generic: any caller (e.g. the `vibescroll run` wrapper) can send a
        // normalised state name directly.
        if let direct = AgentState(rawValue: eventName) { return direct }

        switch kind {
        case .claude:
            switch eventName {
            case "SessionStart": return .registered
            case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .working
            case "Notification": return .waiting
            case "Stop": return .done
            // SubagentStop fires when a Task() subagent finishes mid-session —
            // not when the main session is done. Ignoring it (nil = "no state
            // change") avoids a false done→working flicker.
            case "SubagentStop": return nil
            default: return nil
            }
        case .codex:
            switch eventName {
            case "SessionStart": return .registered
            case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart": return .working
            case "PermissionRequest": return .waiting
            case "Stop", "SubagentStop": return .done
            default: return nil
            }
        case .gemini:
            switch eventName {
            case "SessionStart": return .registered
            case "BeforeAgent", "BeforeModel", "BeforeTool", "AfterTool", "BeforeToolSelection", "AfterModel": return .working
            case "Notification": return .waiting
            case "AfterAgent", "SessionEnd": return .done
            default: return nil
            }
        case .cursor:
            switch eventName {
            case "sessionStart": return .registered
            case "beforeSubmitPrompt", "preToolUse", "beforeShellExecution": return .working
            case "stop", "subagentStop", "sessionEnd": return .done
            default: return nil
            }
        case .windsurf:
            switch eventName {
            case "pre_user_prompt": return .working
            case "post_cascade_response", "post_cascade_response_with_transcript": return .done
            default: return nil
            }
        case .opencode:
            // The plugin sends normalised states directly (handled above); these
            // map the raw opencode event names as a fallback.
            switch eventName {
            case "session.created": return .working
            case "session.idle": return .done
            default: return nil
            }
        case .antigravity:
            switch eventName {
            case "PreInvocation", "PreToolUse", "PostToolUse", "PostInvocation": return .working
            case "Stop": return .done
            default: return nil
            }
        case .copilot:
            // PascalCase events; PreToolUse is intentionally not registered
            // (its command hook is fail-closed and could block tools).
            switch eventName {
            case "SessionStart": return .registered
            case "UserPromptSubmit", "UserPromptSubmitted", "PostToolUse", "PreToolUse": return .working
            case "Notification", "PermissionRequest": return .waiting
            case "Stop", "AgentStop", "SessionEnd": return .done
            default: return nil
            }
        case .kiroCLI:
            // Kiro CLI sends camelCase event names; tolerate PascalCase too.
            switch eventName {
            case "agentSpawn", "AgentSpawn": return .registered
            case "userPromptSubmit", "UserPromptSubmit", "preToolUse", "PreToolUse",
                 "postToolUse", "PostToolUse": return .working
            case "notification", "Notification": return .waiting
            case "stop", "Stop": return .done
            default: return nil
            }
        case .droid:
            // Factory Droid CLI uses Claude-style PascalCase event names.
            switch eventName {
            case "SessionStart": return .registered
            case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .working
            case "Notification": return .waiting
            case "Stop": return .done
            // SubagentStop fires when a sub-droid task finishes mid-session, not
            // when the main session is done; ignore it to avoid a done→working flicker.
            case "SubagentStop": return nil
            default: return nil
            }
        case .pi:
            // The Pi extension sends normalised state names directly (handled by
            // the AgentState(rawValue:) check above). These map Pi's native event
            // names too, as a fallback. Pi has no approval gate, so no "waiting".
            switch eventName {
            case "session_start": return .registered
            case "agent_start", "turn_start", "tool_execution_start": return .working
            case "agent_end", "session_shutdown": return .done
            default: return nil
            }
        case .grok:
            // Grok Build sends snake_case event VALUES in its payload. PreToolUse
            // is deliberately not registered (its deny gate is risky), so tool
            // activity surfaces via post_tool_use. notification → waiting (a
            // permission/approval prompt), stop → done.
            switch eventName {
            case "session_start": return .registered
            case "user_prompt_submit", "pre_tool_use", "post_tool_use": return .working
            case "notification": return .waiting
            case "stop": return .done
            default: return nil
            }
        case .cli, .unknown:
            return nil
        }
    }
}
