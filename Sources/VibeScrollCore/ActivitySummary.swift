import Foundation

/// Turns a tool call into a short, literal one-line description of what the
/// agent is doing ("Editing SessionStore.swift", "Running git status").
///
/// Deliberately plain rather than playful: this line sits next to teaching
/// content, so it should read as a status, not a joke.
public enum ActivitySummary {

    public static func message(
        eventName: String,
        toolName: String?,
        toolInput: ToolActivityInput?,
        explicitMessage: String?
    ) -> String? {
        // A Notification event carries the agent's own words — always better
        // than anything we could synthesise.
        if eventName == "Notification" { return trimmed(explicitMessage) }
        if eventName == "UserPromptSubmit" { return "Reading your prompt" }
        if let line = toolLine(toolName: toolName, toolInput: toolInput) { return line }
        return trimmed(explicitMessage)
    }

    private static func toolLine(toolName: String?, toolInput: ToolActivityInput?) -> String? {
        guard let toolName, !toolName.isEmpty else { return nil }
        let verb = CategoryResolver.category(toolName: toolName, target: toolInput?.target)
            .map(verbFor) ?? "Using \(toolName)"

        if let command = toolInput?.command, !command.isEmpty {
            return "\(verb) \(shorten(firstLine(command), to: 48))"
        }
        if let path = toolInput?.filePath, !path.isEmpty {
            return "\(verb) \((path as NSString).lastPathComponent)"
        }
        if let pattern = toolInput?.pattern ?? toolInput?.query, !pattern.isEmpty {
            return "\(verb) \"\(shorten(pattern, to: 32))\""
        }
        if let description = toolInput?.description, !description.isEmpty {
            return shorten(description, to: 60)
        }
        return verb
    }

    private static func verbFor(_ topic: TopicCategory) -> String {
        switch topic {
        case .reading:        return "Reading"
        case .writing:        return "Editing"
        case .running:        return "Running"
        case .searching:      return "Searching"
        case .testing:        return "Testing"
        case .versionControl: return "Running"
        case .dependencies:   return "Installing"
        case .docs:           return "Writing docs"
        case .config:         return "Editing config"
        case .debugging:      return "Debugging"
        case .delegating:     return "Delegating"
        case .research:       return "Fetching"
        case .generic:        return "Working on"
        // Unreachable: this describes what an agent is doing, and
        // `CategoryResolver` cannot resolve one of these. Listed explicitly
        // rather than caught by a `default`, so a real work topic added later
        // still fails to compile here instead of silently reading "Working on".
        case .gameOfThrones, .breakingBad, .strangerThings, .theOffice:
            return "Working on"
        }
    }

    /// State line used when there is no tool activity to describe.
    public static func stateMessage(for state: AgentState) -> String? {
        switch state {
        case .working:    return "Working"
        case .waiting:    return "Waiting for you"
        case .done:       return "Finished"
        case .registered: return "Ready"
        case .idle:       return nil
        }
    }

    // MARK: - Private

    private static func firstLine(_ s: String) -> String {
        s.components(separatedBy: "\n").first ?? s
    }

    private static func shorten(_ s: String, to limit: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > limit else { return t }
        return String(t.prefix(limit - 1)) + "\u{2026}"
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }
}
