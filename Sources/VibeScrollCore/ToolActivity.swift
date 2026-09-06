import Foundation

/// Tool arguments an agent sends on its pre/post tool hooks. Field names follow
/// Claude Code's snake_case payload; other agents reuse a subset of the same
/// keys, so one struct decodes them all (absent keys simply stay `nil`).
public struct ToolActivityInput: Decodable, Equatable, Sendable {
    public let filePath: String?
    public let command: String?
    public let description: String?
    public let pattern: String?
    public let query: String?
    public let url: String?
    public let prompt: String?
    public let subagentType: String?

    public init(
        filePath: String? = nil, command: String? = nil, description: String? = nil,
        pattern: String? = nil, query: String? = nil, url: String? = nil,
        prompt: String? = nil, subagentType: String? = nil
    ) {
        self.filePath = filePath; self.command = command; self.description = description
        self.pattern = pattern; self.query = query; self.url = url
        self.prompt = prompt; self.subagentType = subagentType
    }

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case command, description, pattern, query, url, prompt
        case subagentType = "subagent_type"
    }

    /// The single most specific thing this tool was pointed at, for the wire
    /// format. Order matters: a shell command says more about the topic than a
    /// file path, which says more than a free-text query.
    ///
    /// Capped at 200 characters — long enough for `git commit -m "…"` or a deep
    /// path, short enough that a pasted heredoc can't bloat every event.
    public var target: String? {
        let candidates = [command, filePath, pattern, query, url, description]
        guard let hit = candidates.compactMap({ $0 })
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }
        return String(hit.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }
}
