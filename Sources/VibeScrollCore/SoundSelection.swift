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

    /// The sounds macOS ships. Listed rather than discovered so the order is
    /// stable in the picker; the app filters out any the system cannot load,
    /// so a future macOS dropping one of these degrades quietly.
    public static let systemNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    // MARK: - Persistence

    public var encoded: String {
        switch self {
        case .silent: return "silent"
        case .system(let name): return "system:\(name)"
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
