import AppKit
import VibeScrollCore

/// An agent's icon, taken from its app if that app is installed here.
///
/// Nothing is bundled: the icon is the one macOS already shows for the app in
/// the Dock and Finder, read from the user's own copy. Agents that are only a
/// command-line tool — or whose app is not installed — have no icon, and the
/// caller writes the name instead.
@MainActor
enum AgentIcon {
    /// Apps that carry each agent, most specific first. A wrong or missing
    /// identifier costs nothing: it just does not resolve.
    private static let bundleIDs: [AgentKind: [String]] = [
        .claude: ["com.anthropic.claudefordesktop"],
        .cursor: ["com.todesktop.230313mzl4w4u92"],
        .codex: ["com.openai.codex", "com.openai.chat"],
        .windsurf: ["com.exafunction.windsurf"],
        .antigravity: ["com.google.antigravity"],
        .copilot: ["com.microsoft.VSCode"],
        .kiroCLI: ["dev.kiro.desktop"],
    ]

    /// Looked up once per agent. Resolving an app and decoding its icon is
    /// disk work, and the closed island redraws whenever a session changes.
    private static var cache: [AgentKind: NSImage?] = [:]

    static func image(for kind: AgentKind) -> NSImage? {
        if let cached = cache[kind] { return cached }
        let image = bundleIDs[kind, default: []].lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[kind] = .some(image)
        return image
    }
}
