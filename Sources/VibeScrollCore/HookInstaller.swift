import Foundation

/// Thrown when an agent's settings file exists but cannot be parsed as a JSON
/// object. Rewriting it anyway would replace whatever the user had with just
/// VibeScroll's hooks, so install/uninstall refuse instead.
public enum HookInstallerError: LocalizedError, Equatable {
    case unreadableSettings(path: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableSettings(let path):
            return "\(path) is not valid JSON; fix or remove it and try again."
        }
    }
}

/// Installs/removes VibeScroll's hook entries in an agent's config. Claude Code,
/// Codex, and Gemini share the nested `{"hooks": {...}}` shape; Cursor and
/// Windsurf use flatter JSON shapes; opencode uses a JS plugin file. The shape
/// is selected by `HookStyle`.
///
/// The dictionary transforms are pure (and tested); the `*OnDisk` helpers wrap
/// them with file IO. Our entries are identified by their command string, so
/// install is idempotent and foreign hooks are never touched.
public enum HookInstaller {
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SubagentStop",
    ]

    public static func defaultSettingsPath() -> String {
        NSHomeDirectory() + "/.claude/settings.json"
    }

    static func isOurs(_ command: String) -> Bool {
        command.contains("vibescroll") && command.contains("hook")
    }

    // MARK: - Claude-nested shape (Claude / Codex / Gemini)

    public static func isInstalled(in settings: [String: Any], events: [String] = events) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            if groups.contains(where: groupIsOurs) { return true }
        }
        return false
    }

    public static func install(into settings: [String: Any], command: String, events: [String] = events) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !groupIsOurs($0) }
            groups.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    public static func uninstall(from settings: [String: Any], events: [String] = events) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept = groups.filter { !groupIsOurs($0) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return settings
    }

    private static func groupIsOurs(_ group: [String: Any]) -> Bool {
        guard let inner = group["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String).map(isOurs) ?? false }
    }

    // MARK: - Antigravity named-group shape (~/.gemini/config/hooks.json)
    // Same per-event structure as Claude-nested, but the event map sits under a
    // named hook group key instead of "hooks", alongside any other user groups:
    // {"vibescroll": {Event: [{"hooks": [{"type": "command", "command": ...}]}]}}

    /// The hook-group key VibeScroll owns in an Antigravity hooks.json.
    public static let antigravityGroup = "vibescroll"

    /// Antigravity events that carry a tool `matcher` and a nested `hooks` array,
    /// like Claude. The rest (PreInvocation/PostInvocation/Stop) take a plain
    /// list of handlers directly under the event key.
    static let antigravityMatcherEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    /// A bare handler object `{"type":"command","command":...}` is ours.
    private static func handlerIsOurs(_ h: [String: Any]) -> Bool {
        (h["command"] as? String).map(isOurs) ?? false
    }

    private static func antigravityEntryIsOurs(_ event: String, _ entry: [String: Any]) -> Bool {
        antigravityMatcherEvents.contains(event) ? groupIsOurs(entry) : handlerIsOurs(entry)
    }

    public static func installAntigravity(into settings: [String: Any], command: String, events: [String]) -> [String: Any] {
        var settings = settings
        var group = settings[antigravityGroup] as? [String: Any] ?? [:]
        for event in events {
            var entries = (group[event] as? [[String: Any]] ?? []).filter { !antigravityEntryIsOurs(event, $0) }
            if antigravityMatcherEvents.contains(event) {
                entries.append(["matcher": "*", "hooks": [["type": "command", "command": command]]])
            } else {
                entries.append(["type": "command", "command": command])
            }
            group[event] = entries
        }
        settings[antigravityGroup] = group
        return settings
    }

    public static func uninstallAntigravity(from settings: [String: Any], events: [String]) -> [String: Any] {
        var settings = settings
        guard var group = settings[antigravityGroup] as? [String: Any] else { return settings }
        for event in events {
            guard let entries = group[event] as? [[String: Any]] else { continue }
            let kept = entries.filter { !antigravityEntryIsOurs(event, $0) }
            if kept.isEmpty { group.removeValue(forKey: event) } else { group[event] = kept }
        }
        if group.isEmpty { settings.removeValue(forKey: antigravityGroup) } else { settings[antigravityGroup] = group }
        return settings
    }

    public static func isInstalledAntigravity(in settings: [String: Any], events: [String]) -> Bool {
        guard let group = settings[antigravityGroup] as? [String: Any] else { return false }
        for event in events {
            guard let entries = group[event] as? [[String: Any]] else { continue }
            if entries.contains(where: { antigravityEntryIsOurs(event, $0) }) { return true }
        }
        return false
    }

    // MARK: - Flat shape (Cursor / Windsurf): {"hooks": {event: [{"command": ...}]}}

    private static func flatItemIsOurs(_ item: [String: Any]) -> Bool {
        (item["command"] as? String).map(isOurs) ?? false
    }

    static func installFlat(into settings: [String: Any], command: String, events: [String], style: HookStyle) -> [String: Any] {
        var settings = settings
        if style == .cursorFlat { settings["version"] = settings["version"] ?? 1 }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var items = (hooks[event] as? [[String: Any]] ?? []).filter { !flatItemIsOurs($0) }
            var entry: [String: Any] = ["command": command]
            if style == .cursorFlat { entry["type"] = "command" }
            if style == .windsurfFlat { entry["show_output"] = false }
            items.append(entry)
            hooks[event] = items
        }
        settings["hooks"] = hooks
        return settings
    }

    static func uninstallFlat(from settings: [String: Any], events: [String]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for event in events {
            guard let items = hooks[event] as? [[String: Any]] else { continue }
            let kept = items.filter { !flatItemIsOurs($0) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return settings
    }

    static func isInstalledFlat(in settings: [String: Any], events: [String]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for event in events {
            guard let items = hooks[event] as? [[String: Any]] else { continue }
            if items.contains(where: flatItemIsOurs) { return true }
        }
        return false
    }

    // MARK: - opencode JS plugin

    /// Extracts the vibescroll binary path from a hook command like
    /// `"/path/to/vibescroll" hook --agent opencode` (the first quoted token).
    static func binaryPath(fromCommand command: String) -> String {
        if let first = command.firstIndex(of: "\"") {
            let rest = command[command.index(after: first)...]
            if let second = rest.firstIndex(of: "\"") {
                return String(rest[..<second])
            }
        }
        return command.components(separatedBy: " ").first ?? command
    }

    static func opencodePlugin(binary: String) -> String {
        """
        // VibeScroll integration (auto-generated, safe to delete to uninstall).
        // Reports opencode session lifecycle to VibeScroll's menu bar app.
        const AGENTPET_BIN = \(jsString(binary))
        export const VibeScroll = async ({ directory }) => {
          const sid = "opencode:" + (directory || "default")
          const send = (state) => {
            try {
              Bun.spawn([AGENTPET_BIN, "hook", "--agent", "opencode",
                         "--event", state, "--session", sid, "--project", directory || ""])
            } catch (e) {}
          }
          return {
            "session.created": async () => { send("working") },
            "session.idle": async () => { send("done") },
          }
        }
        """
    }

    // MARK: - Pi TypeScript extension

    static func piExtension(binary: String) -> String {
        """
        // VibeScroll integration (auto-generated, safe to delete to uninstall).
        // Reports Pi session lifecycle to VibeScroll's menu bar app.
        import { spawn } from "node:child_process"
        const AGENTPET_BIN = \(jsString(binary))
        export default function (pi) {
          const send = (state, ctx) => {
            try {
              const cwd = (ctx && ctx.cwd) || process.cwd()
              const file = ctx && ctx.sessionManager && ctx.sessionManager.getSessionFile
                ? ctx.sessionManager.getSessionFile() : null
              const sid = "pi:" + (file || cwd)
              const p = spawn(AGENTPET_BIN, ["hook", "--agent", "pi",
                "--event", state, "--session", sid, "--project", cwd], { stdio: "ignore" })
              if (p && p.unref) p.unref()
            } catch (e) {}
          }
          pi.on("session_start", async (_e, ctx) => send("registered", ctx))
          pi.on("agent_start", async (_e, ctx) => send("working", ctx))
          pi.on("agent_end", async (_e, ctx) => send("done", ctx))
          pi.on("session_shutdown", async (_e, ctx) => send("done", ctx))
        }
        """
    }

    /// JSON-encodes a string for safe embedding in JS source. Slashes are left
    /// unescaped so embedded file paths stay readable (`"/a/b"`, not `"\/a\/b"`).
    private static func jsString(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        if let data = try? encoder.encode(s), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\"\(s)\""
    }

    // MARK: - Disk IO

    /// Reads an agent's settings file. A missing or empty file is an empty
    /// config; a file with content that does not parse as a JSON object throws,
    /// so callers never rewrite (and thereby wipe) settings they could not read.
    public static func readSettings(path: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError.unreadableSettings(path: path)
        }
        return obj
    }

    public static func writeSettings(_ settings: [String: Any], path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        // Atomic so a crash mid-write can never leave a truncated settings file.
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func installToDisk(command: String, path: String = defaultSettingsPath(),
                                     events: [String] = events, style: HookStyle = .claudeNested) throws {
        switch style {
        case .claudeNested:
            try writeSettings(install(into: readSettings(path: path), command: command, events: events), path: path)
        case .cursorFlat, .windsurfFlat, .kiroFlat:
            var s = installFlat(into: try readSettings(path: path), command: command, events: events, style: style)
            // A Kiro agent file needs a name (the filename) to be a valid agent
            // when we create it fresh; preserve any existing agent fields.
            if style == .kiroFlat, s["name"] == nil {
                s["name"] = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            try writeSettings(s, path: path)
        case .antigravityNested:
            try writeSettings(installAntigravity(into: readSettings(path: path), command: command, events: events), path: path)
        case .opencodePlugin, .piExtension:
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let bin = binaryPath(fromCommand: command)
            let source = style == .piExtension ? piExtension(binary: bin) : opencodePlugin(binary: bin)
            try Data(source.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    public static func uninstallFromDisk(path: String = defaultSettingsPath(),
                                         events: [String] = events, style: HookStyle = .claudeNested) throws {
        switch style {
        case .claudeNested:
            try writeSettings(uninstall(from: readSettings(path: path), events: events), path: path)
        case .cursorFlat, .windsurfFlat, .kiroFlat:
            try writeSettings(uninstallFlat(from: readSettings(path: path), events: events), path: path)
        case .antigravityNested:
            try writeSettings(uninstallAntigravity(from: readSettings(path: path), events: events), path: path)
        case .opencodePlugin, .piExtension:
            if isInstalledOnDisk(path: path, events: events, style: style) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    public static func isInstalledOnDisk(path: String = defaultSettingsPath(),
                                         events: [String] = events, style: HookStyle = .claudeNested) -> Bool {
        switch style {
        case .claudeNested:
            return isInstalled(in: (try? readSettings(path: path)) ?? [:], events: events)
        case .cursorFlat, .windsurfFlat, .kiroFlat:
            return isInstalledFlat(in: (try? readSettings(path: path)) ?? [:], events: events)
        case .antigravityNested:
            return isInstalledAntigravity(in: (try? readSettings(path: path)) ?? [:], events: events)
        case .opencodePlugin, .piExtension:
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return isOurs(s)
        }
    }
}

// MARK: - Where an installed hook actually points

/// Whether an agent's installed hook still points at the binary asking.
public enum HookPathStatus: Equatable, Sendable {
    case notInstalled
    case current
    /// Installed, but aimed at a different binary. The path travels with the
    /// case because the caller has to tell two very different situations apart:
    /// a path that no longer exists is an app somebody moved, and a path that
    /// is still there is a second copy that must be left alone.
    case elsewhere(String)
}

extension HookInstaller {

    /// Every command string belonging to us anywhere in a settings tree.
    ///
    /// A recursive walk rather than five per-style readers on purpose: the
    /// layouts differ in *where* the command sits, not in what it looks like,
    /// so one scan cannot fall out of date when a sixth agent is added.
    public static func ourCommands(in node: Any) -> [String] {
        if let text = node as? String { return isOurs(text) ? [text] : [] }
        if let array = node as? [Any] { return array.flatMap(ourCommands(in:)) }
        if let dict = node as? [String: Any] { return dict.values.flatMap(ourCommands(in:)) }
        return []
    }

    /// The binary a generated plugin file points at.
    ///
    /// These files are JavaScript and TypeScript rather than JSON, but we wrote
    /// every line of them, so the path is a plain double-quoted absolute path
    /// and the only one in the file.
    static func pluginBinary(in source: String) -> String? {
        var candidates: [String] = []
        var current: String?
        for character in source {
            if character == "\"" {
                if let value = current { candidates.append(value); current = nil } else { current = "" }
            } else if current != nil {
                current?.append(character)
            }
        }
        return candidates.first { $0.hasPrefix("/") && $0.contains("vibescroll") }
    }

    /// Reads an agent's config and reports whether its hook still points here.
    public static func pathStatus(
        path: String, style: HookStyle, currentBinary: String
    ) -> HookPathStatus {
        switch style {
        case .opencodePlugin, .piExtension:
            guard let source = try? String(contentsOfFile: path, encoding: .utf8),
                  isOurs(source) else { return .notInstalled }
            guard let binary = pluginBinary(in: source) else { return .current }
            return binary == currentBinary ? .current : .elsewhere(binary)

        case .claudeNested, .cursorFlat, .windsurfFlat, .kiroFlat, .antigravityNested:
            guard let settings = try? readSettings(path: path) else { return .notInstalled }
            let paths = ourCommands(in: settings).map(binaryPath(fromCommand:))
            guard let first = paths.first else { return .notInstalled }
            // Any entry pointing here counts as current: a partial rewrite is
            // repaired by reinstalling, which is what the caller does anyway.
            return paths.contains(currentBinary) ? .current : .elsewhere(first)
        }
    }
}
