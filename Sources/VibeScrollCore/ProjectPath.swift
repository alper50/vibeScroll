import Foundation

/// Path normalisation shared by anything that compares project directories
/// (transcript lookup today, per-project card rules later). Split out so the
/// comparison rule lives in exactly one place.
public enum ProjectPath {
    /// Strips a trailing slash and standardises the path.
    public static func normalize(_ path: String) -> String {
        let std = (path as NSString).standardizingPath
        if std.count > 1 && std.hasSuffix("/") { return String(std.dropLast()) }
        return std
    }

    /// True when `path` equals `root` or is a descendant of `root`.
    /// Boundary-aware: "/work/foo" does not contain "/work/foobar".
    public static func contains(root: String, path: String) -> Bool {
        let r = normalize(root), p = normalize(path)
        return p == r || p.hasPrefix(r + "/")
    }

    /// Last path component, for display ("…/projects/vibeScroll" → "vibeScroll").
    public static func displayName(_ path: String) -> String {
        (normalize(path) as NSString).lastPathComponent
    }

    /// The folder name Claude Code files a directory's transcripts under:
    /// every character that is not an ASCII letter or digit becomes "-", so
    /// `/Users/a/.claude/x_y` is `-Users-a--claude-x-y`.
    public static func transcriptFolderName(for path: String) -> String {
        String(normalize(path).map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        })
    }

    /// The directory a Claude Code session started in, recovered from where
    /// its transcript lives.
    ///
    /// The hook's `cwd` is where the agent is *now*, and it wanders: one `cd`
    /// into a subfolder and it no longer names the folder the editor has open.
    /// The transcript does not move — it stays filed under the directory the
    /// session began in — so the nearest ancestor of `cwd` (or `cwd` itself)
    /// whose encoding matches that folder is the session's root.
    ///
    /// The encoding is lossy (`a-b` and `a/b` look the same), which is why
    /// this matches candidates against it rather than trying to decode it.
    /// `nil` when nothing matches: better no answer than a guessed one.
    public static func sessionRoot(cwd: String, transcriptPath: String) -> String? {
        let folder = ((transcriptPath as NSString).deletingLastPathComponent as NSString)
            .lastPathComponent
        guard !folder.isEmpty else { return nil }
        var candidate = normalize(cwd)
        while candidate.hasPrefix("/") {
            if transcriptFolderName(for: candidate) == folder { return candidate }
            guard candidate != "/" else { break }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return nil
    }
}
