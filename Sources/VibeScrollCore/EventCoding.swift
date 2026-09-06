import Foundation

/// Shared JSON coders so the CLI helper and the daemon agree on the wire
/// format (notably the date strategy).
public enum EventCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// Default on-disk locations used by both the daemon and the CLI helper.
public enum VibeScrollPaths {
    public static var baseDir: String { NSHomeDirectory() + "/.vibescroll" }
    public static var socketPath: String { baseDir + "/vibescroll.sock" }
    public static var queueDir: String { baseDir + "/queue" }
    /// Cached info cards, so the app still shows something when the backend is
    /// unreachable (first run with no network is the only fully empty case).
    public static var cacheDir: String { baseDir + "/cache" }
}
