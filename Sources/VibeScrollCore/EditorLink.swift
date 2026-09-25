import Foundation

/// Builds the deep link that focuses the window an agent session lives in.
///
/// VS Code and its forks expose no scripting dictionary and no API for
/// selecting a terminal tab, so tab-level focus is impossible. What they do
/// offer is a URL scheme that *reuses the window already holding a folder* —
/// so opening the session's project path lands on the right window. That is the
/// path that matters when an agent runs as an IDE extension, where there is no
/// `TERM_PROGRAM` and no controlling tty to target.
///
/// Pure string work, kept out of the app layer so the encoding rules — which
/// break silently on any project path containing a space — have tests.
public enum EditorLink {

    /// Bundle id → URL scheme. The VS Code and Cursor ids were confirmed
    /// against installed applications; the others are best effort. An id that
    /// is missing or wrong yields `nil`, and the caller falls back to simply
    /// activating the app, so a bad guess degrades instead of failing.
    public static let schemesByBundleID: [String: String] = [
        "com.microsoft.VSCode": "vscode",
        "com.microsoft.VSCodeInsiders": "vscode-insiders",
        "com.visualstudio.code.oss": "code-oss",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
        "com.google.antigravity": "antigravity",
    ]

    public static func scheme(forBundleID bundleID: String) -> String? {
        schemesByBundleID[bundleID]
    }

    /// `<scheme>://file<absolute path>?windowId=_blank`, percent-encoded.
    ///
    /// **`windowId=_blank` is what makes a click safe.** Handed a folder that
    /// no window has open, VS Code (and every fork built on it) does not open
    /// a new window by default: it reuses the last active one and loads the
    /// folder into it — reloading that window and killing whatever agent
    /// session was running there. A click meant to *find* a session could
    /// close a different one. With `_blank` a folder nobody has open gets a
    /// window of its own; one that is already open is still just focused,
    /// because VS Code checks for an existing window before it looks at the
    /// flag at all.
    ///
    /// Returns `nil` for a relative path: the scheme requires an absolute one,
    /// and a relative path would resolve against whatever directory the editor
    /// happens to be in — landing on the wrong window, or none.
    public static func url(scheme: String, projectPath: String) -> URL? {
        guard !scheme.isEmpty else { return nil }
        let normalized = ProjectPath.normalize(projectPath)
        guard normalized.hasPrefix("/") else { return nil }
        guard let encoded = normalized.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(scheme)://file\(encoded)?windowId=_blank")
    }

    /// Convenience: the link for a session's host, or `nil` when the host is
    /// not a known editor or the session has no project.
    public static func url(bundleID: String?, projectPath: String?) -> URL? {
        guard let bundleID, let scheme = scheme(forBundleID: bundleID),
              let projectPath, !projectPath.isEmpty else { return nil }
        return url(scheme: scheme, projectPath: projectPath)
    }
}
