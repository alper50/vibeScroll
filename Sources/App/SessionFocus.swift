import AppKit
import Foundation
import VibeScrollCore

/// Brings the window running a given agent session to the front.
///
/// How precisely we can land depends entirely on what the host exposes, and the
/// honest answer differs per app:
///
/// - **Terminal.app / iTerm2** — both publish a per-tab `tty` over AppleScript,
///   so we focus the *exact* window and tab.
/// - **Warp** — no tab scripting, but it sets `WARP_FOCUS_URL`, a deep link to
///   the exact pane.
/// - **VS Code, Cursor, Windsurf** — no scripting dictionary and no API for
///   selecting a terminal tab, so tab-level focus is impossible. Their URL
///   scheme does reuse the window already holding a folder, so opening the
///   session's project lands on the right *window*. This is the path that
///   matters for an agent running as an IDE extension, where there is no
///   `TERM_PROGRAM` and no tty at all.
/// - **Anything else** — activate the app and stop there.
enum SessionFocus {

    /// osascript can block for a beat while the target app comes forward; keep
    /// it off the main thread so the card stays responsive.
    private static let queue = DispatchQueue(label: "vibescroll.session-focus", qos: .userInitiated)

    /// Bundle id per `TERM_PROGRAM`, for terminals we can't script.
    private static let bundleIDsByTermProgram: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "vscode": "com.microsoft.VSCode",
        "ghostty": "com.mitchellh.ghostty",
        "Hyper": "co.zeit.hyper",
        "Tabby": "org.tabby",
        "kitty": "net.kovidgoyal.kitty",
        "alacritty": "org.alacritty",
    ]

    /// True when clicking this session can do anything at all. The row is only
    /// made clickable when this is true, so a dead click is impossible.
    static func canFocus(_ session: AgentSession) -> Bool {
        target(for: session) != nil
    }

    static func focus(_ session: AgentSession) {
        guard let target = target(for: session) else { return }
        queue.async {
            switch target {
            case .appleTerminalTab(let tty):
                runScript(appleTerminalScript(tty: tty))
            case .iTermTab(let tty):
                runScript(iTermScript(tty: tty))
            case .url(let url):
                NSWorkspace.shared.open(url)
            case .activate(let bundleID):
                activate(bundleID: bundleID)
            }
        }
    }

    // MARK: - Routing

    private enum Target {
        case appleTerminalTab(tty: String)
        case iTermTab(tty: String)
        case url(URL)
        case activate(bundleID: String)
    }

    /// Resolution order runs most precise first: exact tab, then exact pane,
    /// then the right editor window, then merely the right app.
    private static func target(for session: AgentSession) -> Target? {
        if let tty = session.terminalTTY {
            switch session.terminalProgram {
            case "Apple_Terminal": return .appleTerminalTab(tty: tty)
            case "iTerm.app":      return .iTermTab(tty: tty)
            default:               break
            }
        }
        if let raw = session.terminalFocusURL, let url = URL(string: raw), url.scheme != nil {
            return .url(url)
        }
        let bundleID = session.hostBundleID
            ?? session.terminalProgram.flatMap { bundleIDsByTermProgram[$0] }
        guard let bundleID else { return nil }

        if let url = EditorLink.url(bundleID: bundleID, projectPath: session.project) {
            return .url(url)
        }
        return .activate(bundleID: bundleID)
    }

    private static func activate(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: - AppleScript

    private static func appleTerminalScript(tty: String) -> String {
        """
        tell application id "com.apple.Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (tty of t) is "\(tty)" then
                            set selected of t to true
                            set frontmost of w to true
                            return
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
    }

    private static func iTermScript(tty: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if (tty of s) is "\(tty)" then
                                select w
                                select t
                                select s
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    private static func runScript(_ source: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        try? process.run()
    }
}
