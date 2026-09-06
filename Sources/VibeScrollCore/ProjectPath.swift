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
}
