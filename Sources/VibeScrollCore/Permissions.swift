import Foundation

// MARK: - Model

/// The agents whose saved permissions vibeScroll can read.
public enum PermissionAgent: String, CaseIterable, Sendable, Hashable {
    case claude, codex, cursor

    public var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        }
    }
}

/// Which file a permission came from, and how far it reaches.
public struct PermissionSource: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        /// Set by an administrator's policy. Never edited from here.
        case managed
        /// Yours, everywhere.
        case user
        /// One project. `shared` when git tracks the file: an edit still
        /// works, but it becomes a change to commit, and once committed it
        /// changes the file for everyone who has the repository.
        case project(root: String, shared: Bool)
    }

    /// How the file is written, which decides how it is read and edited.
    public enum Format: Hashable, Sendable {
        case claudeSettings, cursorPermissions, cursorCLI, codexConfig, codexRules
    }

    public let path: String
    public let agent: PermissionAgent
    public let scope: Scope
    public let format: Format

    public init(path: String, agent: PermissionAgent, scope: Scope, format: Format) {
        self.path = path
        self.agent = agent
        self.scope = scope
        self.format = format
    }

    public var projectRoot: String? {
        if case .project(let root, _) = scope { return root }
        return nil
    }

    /// Whether vibeScroll may change this file at all. Everything but an
    /// administrator's policy.
    public var isEditable: Bool {
        if case .managed = scope { return false }
        return true
    }

    /// Whether an edit here is also a change to a file others share.
    public var isSharedWithTeam: Bool {
        if case .project(_, let shared) = scope { return shared }
        return false
    }
}

/// One saved permission, with what it means in plain words.
public struct PermissionEntry: Identifiable, Hashable, Sendable {
    public enum Effect: Hashable, Sendable {
        /// Done without asking.
        case allow
        /// Always asks, even where something else would allow it.
        case ask
        /// Never done.
        case deny
        /// A folder the agent can work in beyond the project.
        case directory
        /// A setting that changes how much is asked at all.
        case setting
    }

    public enum Risk: Int, Comparable, Sendable {
        case low, medium, high
        public static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }
    }

    /// Where the entry lives, precisely enough to remove exactly it.
    public enum Location: Hashable, Sendable {
        /// An element of a JSON array, reached through these keys.
        case jsonArray(keyPath: [String])
        /// A span of text, removed verbatim.
        case text
        /// Not removable from here (a TOML setting, a policy value).
        case fixed
    }

    public let source: PermissionSource
    public let effect: Effect
    /// Exactly as stored — the rule, the path, or the whole `prefix_rule(...)`.
    public let raw: String
    public let location: Location
    public let summary: String
    public let risk: Risk

    public init(source: PermissionSource, effect: Effect, raw: String, location: Location,
                summary: String, risk: Risk) {
        self.source = source
        self.effect = effect
        self.raw = raw
        self.location = location
        self.summary = summary
        self.risk = risk
    }

    public var id: String {
        let key: String
        switch location {
        case .jsonArray(let path): key = path.joined(separator: ".")
        case .text: key = "text"
        case .fixed: key = "fixed"
        }
        return "\(source.path)|\(key)|\(raw)"
    }

    /// Whether the Remove button applies: not a managed policy, and an entry
    /// that can be taken out without rewriting anything else. A shared file
    /// is removable too — it is usually your own repository — but the
    /// confirmation says what that means (`source.isSharedWithTeam`).
    public var isRemovable: Bool {
        source.isEditable && location != .fixed
    }
}

// MARK: - Reading

/// Turns each agent's permission files into entries. Pure: the app reads the
/// files and hands over their contents, so every format is testable here.
public enum PermissionParser {

    // MARK: Claude Code

    /// `permissions.allow|ask|deny`, `permissions.additionalDirectories` and
    /// `permissions.defaultMode` from a Claude Code settings file.
    public static func claude(settings: [String: Any], source: PermissionSource) -> [PermissionEntry] {
        guard let permissions = settings["permissions"] as? [String: Any] else { return [] }
        var entries: [PermissionEntry] = []
        for (key, effect) in [("allow", PermissionEntry.Effect.allow), ("ask", .ask), ("deny", .deny)] {
            for rule in permissions[key] as? [String] ?? [] {
                let described = PermissionExplainer.claudeRule(rule, effect: effect,
                                                                root: source.projectRoot)
                entries.append(PermissionEntry(
                    source: source, effect: effect, raw: rule,
                    location: .jsonArray(keyPath: ["permissions", key]),
                    summary: described.summary, risk: described.risk))
            }
        }
        for directory in permissions["additionalDirectories"] as? [String] ?? [] {
            entries.append(PermissionEntry(
                source: source, effect: .directory, raw: directory,
                location: .jsonArray(keyPath: ["permissions", "additionalDirectories"]),
                summary: String(localized: "Works in \(PermissionExplainer.displayPath(directory, root: source.projectRoot)) as if it were part of the project"),
                risk: PermissionExplainer.directoryRisk(directory)))
        }
        if let mode = permissions["defaultMode"] as? String {
            let described = PermissionExplainer.claudeMode(mode)
            entries.append(PermissionEntry(
                source: source, effect: .setting, raw: "defaultMode: \(mode)", location: .fixed,
                summary: described.summary, risk: described.risk))
        }
        return entries
    }

    // MARK: Cursor

    /// `permissions.json`: the terminal and MCP allowlists, and the auto-run
    /// instructions.
    public static func cursorPermissions(json: [String: Any], source: PermissionSource) -> [PermissionEntry] {
        var entries: [PermissionEntry] = []
        for command in json["terminalAllowlist"] as? [String] ?? [] {
            entries.append(PermissionEntry(
                source: source, effect: .allow, raw: command,
                location: .jsonArray(keyPath: ["terminalAllowlist"]),
                summary: String(localized: "Runs “\(command)” commands without asking"),
                risk: PermissionExplainer.commandRisk(command)))
        }
        for tool in json["mcpAllowlist"] as? [String] ?? [] {
            entries.append(PermissionEntry(
                source: source, effect: .allow, raw: tool,
                location: .jsonArray(keyPath: ["mcpAllowlist"]),
                summary: String(localized: "Uses the MCP tool “\(tool)” without asking"),
                risk: tool.hasSuffix(":*") || tool == "*" ? .medium : .low))
        }
        if let autoRun = json["autoRun"] as? [String: Any] {
            for (key, effect) in [("allow_instructions", PermissionEntry.Effect.allow),
                                  ("block_instructions", .deny)] {
                for instruction in autoRun[key] as? [String] ?? [] {
                    entries.append(PermissionEntry(
                        source: source, effect: effect, raw: instruction,
                        location: .jsonArray(keyPath: ["autoRun", key]),
                        summary: effect == .allow
                            ? String(localized: "Auto-review instruction: allow")
                            : String(localized: "Auto-review instruction: block"),
                        risk: .low))
                }
            }
        }
        return entries
    }

    /// The Cursor CLI's `permissions.allow|deny`: `Shell(…)`, `Read(…)`,
    /// `Write(…)`, `WebFetch(…)`.
    public static func cursorCLI(json: [String: Any], source: PermissionSource) -> [PermissionEntry] {
        guard let permissions = json["permissions"] as? [String: Any] else { return [] }
        var entries: [PermissionEntry] = []
        for (key, effect) in [("allow", PermissionEntry.Effect.allow), ("deny", .deny)] {
            for rule in permissions[key] as? [String] ?? [] {
                let described = PermissionExplainer.cursorRule(rule, effect: effect,
                                                                root: source.projectRoot)
                entries.append(PermissionEntry(
                    source: source, effect: effect, raw: rule,
                    location: .jsonArray(keyPath: ["permissions", key]),
                    summary: described.summary, risk: described.risk))
            }
        }
        return entries
    }

    // MARK: Codex

    /// The settings in `config.toml` that decide how much Codex may do
    /// unasked. Read-only here: rewriting TOML safely is not worth the risk
    /// of damaging somebody's config, and each entry says where to change it.
    public static func codexConfig(toml: String, source: PermissionSource) -> [PermissionEntry] {
        let values = MiniTOML.parse(toml)
        var entries: [PermissionEntry] = []
        func setting(_ raw: String, _ described: (summary: String, risk: PermissionEntry.Risk)) {
            entries.append(PermissionEntry(source: source, effect: .setting, raw: raw,
                                           location: .fixed, summary: described.summary,
                                           risk: described.risk))
        }
        if case .string(let policy)? = values[["approval_policy"]] {
            setting("approval_policy = \"\(policy)\"", PermissionExplainer.codexApproval(policy))
        }
        if case .string(let mode)? = values[["sandbox_mode"]] {
            setting("sandbox_mode = \"\(mode)\"", PermissionExplainer.codexSandbox(mode))
        }
        if case .string(let profile)? = values[["default_permissions"]] {
            setting("default_permissions = \"\(profile)\"", PermissionExplainer.codexSandbox(
                profile.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                    .replacingOccurrences(of: "workspace", with: "workspace-write")))
        }
        if case .strings(let roots)? = values[["sandbox_workspace_write", "writable_roots"]] {
            for root in roots {
                entries.append(PermissionEntry(
                    source: source, effect: .directory, raw: root, location: .fixed,
                    summary: String(localized: "Can write in \(PermissionExplainer.displayPath(root, root: nil))"),
                    risk: PermissionExplainer.directoryRisk(root)))
            }
        }
        if case .bool(true)? = values[["sandbox_workspace_write", "network_access"]] {
            setting("network_access = true",
                    (String(localized: "Sandboxed commands can reach the network"), .medium))
        }
        for (key, value) in values where key.count == 3 && key[0] == "projects" && key[2] == "trust_level" {
            if case .string(let level) = value, level == "trusted" {
                setting("[projects.\"\(key[1])\"] trust_level = \"trusted\"",
                        (String(localized: "Trusts the project \(PermissionExplainer.displayPath(key[1], root: nil))"), .low))
            }
        }
        return entries.sorted { $0.raw < $1.raw }
    }

    /// `prefix_rule(...)` calls in a Codex `.rules` file — where Codex writes
    /// the commands you told it to stop asking about.
    public static func codexRules(text: String, source: PermissionSource) -> [PermissionEntry] {
        PrefixRuleScanner.calls(in: text).map { call in
            let command = call.pattern.joined(separator: " ")
            let effect: PermissionEntry.Effect
            let summary: String
            switch call.decision {
            case "allow":
                effect = .allow
                summary = String(localized: "Runs “\(command)” commands without asking")
            case "forbidden":
                effect = .deny
                summary = String(localized: "Never runs “\(command)” commands")
            default:
                effect = .ask
                summary = String(localized: "Always asks before “\(command)” commands")
            }
            return PermissionEntry(
                source: source, effect: effect, raw: call.text, location: .text, summary: summary,
                risk: effect == .allow ? PermissionExplainer.commandRisk(command) : .low)
        }
    }
}

// MARK: - Explaining

/// Plain-language descriptions and a rough risk for each kind of rule.
///
/// The risk is a reading aid, not a verdict: high is "worth a second look" —
/// any command, any file, or no questions asked at all.
public enum PermissionExplainer {

    /// Commands that are a whole shell or interpreter by themselves: allowing
    /// one of these is allowing anything.
    static let unboundedCommands: Set<String> = [
        "*", "bash", "sh", "zsh", "fish", "sudo", "python", "python3", "node", "ruby", "perl",
        "osascript", "eval", "env", "xargs",
    ]

    /// Commands that change or reach beyond the project in ways worth a look.
    static let consequentialCommands: Set<String> = [
        "rm", "git", "curl", "wget", "npx", "docker", "kubectl", "ssh", "scp", "chmod", "chown",
    ]

    /// Judged on the first word, with any trailing `*` dropped: `npm*` is npm.
    public static func commandRisk(_ command: String) -> PermissionEntry.Risk {
        let first = command.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == ":" }).first
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "*")) } ?? ""
        if first.isEmpty || unboundedCommands.contains(first) { return .high }
        if consequentialCommands.contains(first) { return .medium }
        return .low
    }

    /// Everything, or somewhere as wide as the home folder, is high.
    public static func directoryRisk(_ path: String) -> PermissionEntry.Risk {
        let trimmed = path.replacingOccurrences(of: "/**", with: "")
            .replacingOccurrences(of: "**", with: "")
        let home = NSHomeDirectory()
        if ["", "/", "~", "//", home, home + "/"].contains(trimmed) { return .high }
        return .medium
    }

    /// Claude Code rule paths, in words: `//abs` is absolute, `~/` is home,
    /// `/x` is relative to the settings file's project.
    public static func displayPath(_ path: String, root: String?) -> String {
        if path.hasPrefix("//") { return String(path.dropFirst()) }
        if path.hasPrefix("~/") || path == "~" { return path }
        if path.hasPrefix("/"), let root {
            return (root as NSString).appendingPathComponent(String(path.dropFirst()))
        }
        return path
    }

    /// `Tool(specifier)` → ("Tool", "specifier"); a bare `Tool` → ("Tool", nil).
    static func split(_ rule: String) -> (tool: String, spec: String?) {
        guard let open = rule.firstIndex(of: "("), rule.hasSuffix(")") else { return (rule, nil) }
        let tool = String(rule[..<open])
        let spec = String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)])
        return (tool, spec)
    }

    static func claudeRule(_ rule: String, effect: PermissionEntry.Effect,
                           root: String?) -> (summary: String, risk: PermissionEntry.Risk) {
        let (tool, spec) = split(rule)
        let action: String
        var risk = PermissionEntry.Risk.low
        switch tool {
        case "Bash", "PowerShell":
            let command = (spec ?? "*").replacingOccurrences(of: ":*", with: " *")
                .trimmingCharacters(in: .whitespaces)
            if command == "*" || command.isEmpty {
                action = String(localized: "any shell command")
                risk = .high
            } else {
                let shown = command.hasSuffix(" *") ? String(command.dropLast(2)) + "…"
                    : command.hasSuffix("*") ? String(command.dropLast()) + "…" : command
                action = String(localized: "the command “\(shown)”")
                risk = commandRisk(command)
            }
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            let path = spec.map { displayPath($0, root: root) }
            let editing = tool != "Read"
            if let path {
                action = editing ? String(localized: "editing files in \(path)")
                                 : String(localized: "reading files in \(path)")
                if path.hasPrefix("/") || path.hasPrefix("~") {
                    risk = directoryRisk(path) == .high ? .high : (editing ? .medium : .low)
                }
            } else {
                action = editing ? String(localized: "editing any file") : String(localized: "reading any file")
                risk = editing ? .high : .medium
            }
        case "WebFetch":
            if let spec, spec.hasPrefix("domain:") {
                action = String(localized: "fetching from \(String(spec.dropFirst("domain:".count)))")
            } else {
                action = String(localized: "fetching from any website")
                risk = .medium
            }
        case "WebSearch":
            action = String(localized: "web searches")
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.dropFirst(5).components(separatedBy: "__")
                let server = parts.first ?? tool
                // `mcp__server`, `mcp__server__*` and `mcp__server__:*` all
                // mean the whole server; only a real name after it is one tool.
                let toolName = parts.count > 1
                    ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ":*")) : ""
                action = toolName.isEmpty
                    ? String(localized: "every tool of the MCP server “\(server)”")
                    : String(localized: "the MCP tool “\(toolName)” from “\(server)”")
            } else {
                action = String(localized: "the \(tool) tool")
            }
        }
        switch effect {
        case .allow: return (String(localized: "Allowed without asking: \(action)"), risk)
        case .ask:   return (String(localized: "Always asks first: \(action)"), .low)
        default:     return (String(localized: "Never allowed: \(action)"), .low)
        }
    }

    static func cursorRule(_ rule: String, effect: PermissionEntry.Effect,
                           root: String?) -> (summary: String, risk: PermissionEntry.Risk) {
        let (tool, spec) = split(rule)
        switch tool {
        case "Shell":
            return claudeRule("Bash(\(spec ?? "*"))", effect: effect, root: root)
        case "Read":
            return claudeRule("Read(\(spec ?? "**"))", effect: effect, root: root)
        case "Write":
            return claudeRule("Edit(\(spec ?? "**"))", effect: effect, root: root)
        case "WebFetch":
            return claudeRule(spec.map { "WebFetch(domain:\($0))" } ?? "WebFetch", effect: effect, root: root)
        default:
            return claudeRule(rule, effect: effect, root: root)
        }
    }

    static func claudeMode(_ mode: String) -> (summary: String, risk: PermissionEntry.Risk) {
        switch mode {
        case "bypassPermissions":
            return (String(localized: "Starts sessions without asking for anything at all"), .high)
        case "acceptEdits":
            return (String(localized: "Starts sessions accepting file edits without asking"), .medium)
        case "auto":
            return (String(localized: "Starts sessions with a classifier deciding instead of you"), .medium)
        case "dontAsk":
            return (String(localized: "Starts sessions refusing anything not already allowed"), .low)
        case "plan":
            return (String(localized: "Starts sessions in plan mode, without editing"), .low)
        default:
            return (String(localized: "Starts sessions asking as usual"), .low)
        }
    }

    static func codexApproval(_ policy: String) -> (summary: String, risk: PermissionEntry.Risk) {
        switch policy {
        case "never":
            return (String(localized: "Never asks before running commands"), .high)
        case "on-failure":
            return (String(localized: "Asks only after a command fails in the sandbox"), .medium)
        case "untrusted":
            return (String(localized: "Asks before anything not known to be safe"), .low)
        default:
            return (String(localized: "Asks when it needs to leave the sandbox"), .low)
        }
    }

    static func codexSandbox(_ mode: String) -> (summary: String, risk: PermissionEntry.Risk) {
        switch mode {
        case "danger-full-access":
            return (String(localized: "Runs without a sandbox: full access to the computer"), .high)
        case "workspace-write":
            return (String(localized: "Can write inside the project; the rest is read-only"), .low)
        default:
            return (String(localized: "Read-only sandbox"), .low)
        }
    }
}

// MARK: - Removing

/// Takes one entry out of its file's contents, touching nothing else.
public enum PermissionEditor {

    /// The JSON with the entry's value removed from its array, or `nil` when
    /// it is not there — the file changed since it was read, and writing
    /// anyway would be acting on a stale view.
    public static func removing(_ entry: PermissionEntry, from json: [String: Any]) -> [String: Any]? {
        guard case .jsonArray(let keyPath) = entry.location, !keyPath.isEmpty else { return nil }
        return removing(entry.raw, at: keyPath[...], in: json)
    }

    private static func removing(_ value: String, at path: ArraySlice<String>,
                                 in object: [String: Any]) -> [String: Any]? {
        guard let key = path.first else { return nil }
        var object = object
        if path.count == 1 {
            guard var array = object[key] as? [Any],
                  let index = array.firstIndex(where: { ($0 as? String) == value }) else { return nil }
            array.remove(at: index)
            object[key] = array
            return object
        }
        guard let child = object[key] as? [String: Any],
              let updated = removing(value, at: path.dropFirst(), in: child) else { return nil }
        object[key] = updated
        return object
    }

    /// The text with the entry's span removed, along with the line break after
    /// it, or `nil` when the span is no longer there.
    public static func removing(_ entry: PermissionEntry, fromText text: String) -> String? {
        guard entry.location == .text, let range = text.range(of: entry.raw) else { return nil }
        var end = range.upperBound
        if end < text.endIndex, text[end] == "\n" { end = text.index(after: end) }
        return text.replacingCharacters(in: range.lowerBound..<end, with: "")
    }
}

// MARK: - Codex formats

/// Just enough TOML for the handful of Codex keys read here: tables with
/// bare or quoted keys, and string, boolean and string-array values — arrays
/// may span lines. Anything else is skipped rather than guessed at.
public enum MiniTOML {
    public enum Value: Equatable, Sendable {
        case string(String), bool(Bool), strings([String])
    }

    public static func parse(_ text: String) -> [[String]: Value] {
        var result: [[String]: Value] = [:]
        var table: [String] = []
        var pending = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if !pending.isEmpty {
                pending += " " + line
                guard balanced(pending) else { continue }
                assign(pending, table: table, into: &result)
                pending = ""
                continue
            }
            if line.isEmpty { continue }
            if line.hasPrefix("[") && !line.hasPrefix("[[") && line.hasSuffix("]") {
                table = keyPath(String(line.dropFirst().dropLast()))
                continue
            }
            if line.contains("="), !balanced(line) {
                pending = line
                continue
            }
            assign(line, table: table, into: &result)
        }
        return result
    }

    private static func assign(_ line: String, table: [String], into result: inout [[String]: Value]) {
        guard let equals = line.firstIndex(of: "=") else { return }
        let key = keyPath(String(line[..<equals]).trimmingCharacters(in: .whitespaces))
        let raw = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard let value = value(raw) else { return }
        result[table + key] = value
    }

    private static func value(_ raw: String) -> Value? {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if let string = quoted(raw) { return .string(string) }
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            return .strings(strings(in: String(raw.dropFirst().dropLast())))
        }
        return nil
    }

    /// Dotted key path, where a part may be quoted: `projects."/a/b.c"`.
    static func keyPath(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let q = quote {
                if character == q { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }

    static func quoted(_ raw: String) -> String? {
        guard raw.count >= 2, let first = raw.first, first == "\"" || first == "'",
              raw.last == first else { return nil }
        return String(raw.dropFirst().dropLast())
    }

    static func strings(in list: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        for character in list {
            if let q = quote {
                if character == q { out.append(current); current = ""; quote = nil }
                else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            }
        }
        return out
    }

    static func stripComment(_ line: String) -> String {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if let q = quote { if character == q { quote = nil } }
            else if character == "\"" || character == "'" { quote = character }
            else if character == "#" { return String(line[..<index]) }
        }
        return line
    }

    static func balanced(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        for character in text {
            if let q = quote { if character == q { quote = nil } }
            else if character == "\"" || character == "'" { quote = character }
            else if character == "[" { depth += 1 }
            else if character == "]" { depth -= 1 }
        }
        return depth <= 0
    }
}

/// Finds `prefix_rule(...)` calls in a Codex rules file (Starlark), keeping
/// each call's exact text so it can be removed verbatim.
enum PrefixRuleScanner {
    struct Call: Equatable {
        let text: String
        let pattern: [String]
        let decision: String
    }

    static func calls(in text: String) -> [Call] {
        var calls: [Call] = []
        var searchStart = text.startIndex
        while let start = text.range(of: "prefix_rule(", range: searchStart..<text.endIndex) {
            // Skip a commented-out call.
            let lineStart = text[..<start.lowerBound].lastIndex(of: "\n").map(text.index(after:))
                ?? text.startIndex
            if text[lineStart..<start.lowerBound].contains("#") {
                searchStart = start.upperBound
                continue
            }
            var depth = 1
            var quote: Character?
            var index = start.upperBound
            while index < text.endIndex, depth > 0 {
                let character = text[index]
                if let q = quote { if character == q { quote = nil } }
                else if character == "\"" || character == "'" { quote = character }
                else if character == "(" { depth += 1 }
                else if character == ")" { depth -= 1 }
                index = text.index(after: index)
            }
            guard depth == 0 else { break }
            let callText = String(text[start.lowerBound..<index])
            let body = String(callText.dropFirst("prefix_rule(".count).dropLast())
            calls.append(Call(text: callText, pattern: pattern(in: body),
                              decision: decision(in: body)))
            searchStart = index
        }
        return calls
    }

    private static func pattern(in body: String) -> [String] {
        guard let key = body.range(of: "pattern"),
              let open = body[key.upperBound...].firstIndex(of: "[") else { return [] }
        var depth = 0
        var end = open
        for index in body[open...].indices {
            if body[index] == "[" { depth += 1 }
            if body[index] == "]" { depth -= 1; if depth == 0 { end = index; break } }
        }
        return MiniTOML.strings(in: String(body[body.index(after: open)..<end]))
    }

    private static func decision(in body: String) -> String {
        guard let key = body.range(of: "decision"),
              let equals = body[key.upperBound...].firstIndex(of: "=") else { return "prompt" }
        let rest = body[body.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return MiniTOML.strings(in: String(rest.prefix(while: { $0 != "," && $0 != "\n" }))).first
            ?? "prompt"
    }
}
