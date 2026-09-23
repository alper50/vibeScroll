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
        if eventName == "UserPromptSubmit" { return String(localized: "Reading your prompt") }
        if let line = toolLine(toolName: toolName, toolInput: toolInput) { return line }
        return trimmed(explicitMessage)
    }

    private static func toolLine(toolName: String?, toolInput: ToolActivityInput?) -> String? {
        guard let toolName, !toolName.isEmpty else { return nil }
        let topic = CategoryResolver.category(toolName: toolName, target: toolInput?.target)

        let object: String?
        if let command = toolInput?.command, !command.isEmpty {
            object = shorten(firstLine(command), to: 48)
        } else if let path = toolInput?.filePath, !path.isEmpty {
            object = (path as NSString).lastPathComponent
        } else if let pattern = toolInput?.pattern ?? toolInput?.query, !pattern.isEmpty {
            object = "\"\(shorten(pattern, to: 32))\""
        } else if let description = toolInput?.description, !description.isEmpty {
            return shorten(description, to: 60)
        } else {
            object = nil
        }

        guard let topic else {
            return object.map { String(localized: "Using \(toolName) \($0)") }
                ?? String(localized: "Using \(toolName)")
        }
        return object.map { phrase(for: topic, object: $0) } ?? verb(for: topic)
    }

    /// The verb on its own, for a tool call with nothing to name.
    private static func verb(for topic: TopicCategory) -> String {
        switch topic {
        case .reading:        return String(localized: "Reading")
        case .writing:        return String(localized: "Editing")
        case .running:        return String(localized: "Running")
        case .searching:      return String(localized: "Searching")
        case .testing:        return String(localized: "Testing")
        case .versionControl: return String(localized: "Running")
        case .dependencies:   return String(localized: "Installing")
        case .docs:           return String(localized: "Writing docs")
        case .config:         return String(localized: "Editing config")
        case .debugging:      return String(localized: "Debugging")
        case .delegating:     return String(localized: "Delegating")
        case .research:       return String(localized: "Fetching")
        case .generic:        return String(localized: "Working on")
        }
    }

    /// The verb with what it acts on, as one localizable sentence rather than
    /// two strings glued together: word order is the translator's call, and in
    /// Turkish the object comes first ("Store.swift düzenleniyor").
    private static func phrase(for topic: TopicCategory, object: String) -> String {
        switch topic {
        case .reading:        return String(localized: "Reading \(object)")
        case .writing:        return String(localized: "Editing \(object)")
        case .running:        return String(localized: "Running \(object)")
        case .searching:      return String(localized: "Searching \(object)")
        case .testing:        return String(localized: "Testing \(object)")
        case .versionControl: return String(localized: "Running \(object)")
        case .dependencies:   return String(localized: "Installing \(object)")
        case .docs:           return String(localized: "Writing docs \(object)")
        case .config:         return String(localized: "Editing config \(object)")
        case .debugging:      return String(localized: "Debugging \(object)")
        case .delegating:     return String(localized: "Delegating \(object)")
        case .research:       return String(localized: "Fetching \(object)")
        case .generic:        return String(localized: "Working on \(object)")
        }
    }

    /// State line used when there is no tool activity to describe.
    public static func stateMessage(for state: AgentState) -> String? {
        switch state {
        case .working:    return String(localized: "Working")
        case .waiting:    return String(localized: "Waiting for you")
        case .done:       return String(localized: "Finished")
        case .registered: return String(localized: "Ready")
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
