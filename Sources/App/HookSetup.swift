import Foundation
import VibeScrollCore

/// Installs and removes vibeScroll's hook entries in each agent's own config.
///
/// The command we write points at *this* binary's absolute path, so a user with
/// the app in `~/Applications` and one in `/Applications` never cross-wire. The
/// entry is identified by that command string, which is what makes install
/// idempotent and leaves foreign hooks untouched.
@MainActor
enum HookSetup {

    /// Absolute path to the running binary, quoted for the shell.
    static var binaryPath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "vibescroll"
    }

    static func command(for kind: AgentKind) -> String {
        "\"\(binaryPath)\" hook --agent \(kind.rawValue)"
    }

    static func isInstalled(_ kind: AgentKind) -> Bool {
        guard let spec = AgentHooks.spec(for: kind) else { return false }
        return HookInstaller.isInstalledOnDisk(
            path: spec.settingsPath, events: spec.events, style: spec.style)
    }

    /// Installs the hook. Throws `HookInstallerError.unreadableSettings` when
    /// the agent's config exists but isn't valid JSON — rewriting it would
    /// silently destroy the user's own settings, so we refuse and report.
    static func install(_ kind: AgentKind) throws {
        guard let spec = AgentHooks.spec(for: kind) else { return }
        try HookInstaller.installToDisk(
            command: command(for: kind), path: spec.settingsPath,
            events: spec.events, style: spec.style)
        // Codex only reads its hooks.json when the feature flag is on. Older
        // versions ship it off, so set it conservatively — this never touches
        // any other key in config.toml.
        if kind == .codex {
            try? CodexHookConfig.enableHooksOnDisk()
        }
    }

    static func uninstall(_ kind: AgentKind) throws {
        guard let spec = AgentHooks.spec(for: kind) else { return }
        try HookInstaller.uninstallFromDisk(
            path: spec.settingsPath, events: spec.events, style: spec.style)
    }
}
