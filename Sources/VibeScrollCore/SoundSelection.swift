import Foundation

/// Which sound to play for an event.
///
/// Three sources, one type: silence, one of macOS's built-in sounds, or a file
/// the user chose. Encoding lives here rather than in the settings layer so the
/// round trip through `UserDefaults` — the part that silently loses a user's
/// choice when it goes wrong — is directly testable.
public enum SoundSelection: Equatable, Hashable, Sendable {
    case silent
    /// A sound from `/System/Library/Sounds`, referenced by name. Costs nothing
    /// to ship, carries no licence question, and is already familiar.
    case system(String)
    /// A file the user picked. Copied into the app's own directory at pick
    /// time, so it cannot disappear from under the setting later.
    case custom(URL)
    /// A sound shipped inside the app bundle. Kept distinct from `system`
    /// rather than folded into it: `NSSound(named:)` happens to resolve both,
    /// but one set is Apple's and one is ours, and a picker that says otherwise
    /// is lying about where a sound came from.
    case bundled(String)

    /// The sounds macOS ships. Listed rather than discovered so the order is
    /// stable in the picker; the app filters out any the system cannot load,
    /// so a future macOS dropping one of these degrades quietly.
    public static let systemNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    /// Sounds shipped in `Resources/Sounds/`, cut from a CC0 recording by
    /// `scripts/make-sounds.py` (see NOTICE.md). Listed rather than discovered
    /// for the same reason as `systemNames`: the picker's order should not
    /// depend on how a directory happens to enumerate.
    ///
    /// Four lengths rather than four takes of the same thing — 0.26s and 1.77s
    /// are different alerts, and which one suits depends on how often it fires.
    public static let bundledNames = ["Fart 1", "Fart 2", "Fart 3", "Fart 4"]

    // MARK: - Persistence

    public var encoded: String {
        switch self {
        case .silent: return "silent"
        case .system(let name): return "system:\(name)"
        case .bundled(let name): return "bundled:\(name)"
        case .custom(let url): return "custom:\(url.path)"
        }
    }

    /// Decodes a stored value. Returns `nil` when there is nothing stored or
    /// the value is unusable, so the caller can apply its own default rather
    /// than a corrupt setting silently becoming silence.
    public static func decode(_ raw: String?) -> SoundSelection? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw == "silent" { return .silent }
        if let name = raw.dropPrefix("system:") {
            // An empty or unknown name is not a valid selection: it would
            // resolve to no sound while the picker showed a name.
            guard !name.isEmpty, systemNames.contains(name) else { return nil }
            return .system(name)
        }
        if let name = raw.dropPrefix("bundled:") {
            // A name dropped from a later build must not resolve to silence
            // while the picker still shows it.
            guard !name.isEmpty, bundledNames.contains(name) else { return nil }
            return .bundled(name)
        }
        if let path = raw.dropPrefix("custom:") {
            guard path.hasPrefix("/") else { return nil }
            return .custom(URL(fileURLWithPath: path))
        }
        return nil
    }

    /// Label for the picker.
    public var displayName: String {
        switch self {
        case .silent: return "None"
        case .system(let name): return name
        case .bundled(let name): return name
        case .custom(let url): return url.deletingPathExtension().lastPathComponent
        }
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}

private extension String {
    /// The remainder after `prefix`, or `nil` if the string doesn't start with it.
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
