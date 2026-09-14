import Foundation

/// One rate-limit window reported by a provider (a rolling session window, a
/// weekly one, and so on).
public struct QuotaWindow: Equatable, Sendable {
    /// How urgent the provider itself considers this window.
    ///
    /// The provider classifies for us, so no threshold is invented here. Only
    /// the values actually observed are mapped; anything else becomes
    /// `.unknown` rather than being guessed upward — treating an unrecognised
    /// string as critical would fire false alarms on every field they add.
    public enum Severity: String, Sendable {
        case normal, warning, critical, unknown

        static func parse(_ raw: String?) -> Severity {
            guard let raw else { return .unknown }
            return Severity(rawValue: raw) ?? .unknown
        }
    }

    /// Provider's identifier for the window, e.g. `"session"`, `"weekly_all"`.
    public let kind: String
    public let percentUsed: Int
    public let severity: Severity
    public let resetsAt: Date?
    /// Whether the provider currently counts this window against you.
    public let isActive: Bool

    public init(kind: String, percentUsed: Int, severity: Severity,
                resetsAt: Date?, isActive: Bool) {
        self.kind = kind
        self.percentUsed = percentUsed
        self.severity = severity
        self.resetsAt = resetsAt
        self.isActive = isActive
    }

    /// Short human label. Unknown kinds fall back to the raw identifier so a
    /// window we have never seen still displays something truthful.
    ///
    /// Every kind `QuotaPace.weeklyKinds` knows about is named here. The Sonnet
    /// pools used to fall through to the default and render as "Weekly Sonnet"
    /// beside an Opus pool rendering as "Weekly (Opus)" — two spellings for the
    /// same idea, in the same list, one line apart.
    public var label: String {
        switch kind {
        case "session", "five_hour": return "Session"
        case "weekly_all", "seven_day": return "Weekly"
        case "weekly_opus", "seven_day_opus": return "Weekly (Opus)"
        case "weekly_sonnet", "seven_day_sonnet": return "Weekly (Sonnet)"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Percent >= 100 is the exhaustion signal, not a severity string: it means
    /// the same thing for every provider and cannot drift when they rename a
    /// label.
    public var isExhausted: Bool { percentUsed >= 100 }
}

/// A provider's quota at a point in time.
public struct QuotaSnapshot: Equatable, Sendable {
    public let provider: String
    public let displayName: String
    public let windows: [QuotaWindow]
    public let checkedAt: Date

    public init(provider: String, displayName: String,
                windows: [QuotaWindow], checkedAt: Date) {
        self.provider = provider
        self.displayName = displayName
        self.windows = windows
        self.checkedAt = checkedAt
    }

    /// The window closest to its limit — the one that will actually stop you.
    public var tightest: QuotaWindow? {
        windows.max { $0.percentUsed < $1.percentUsed }
    }

    /// True once any window is spent. This is what fires the alert.
    public var isExhausted: Bool { windows.contains(where: \.isExhausted) }

    public var isWarning: Bool {
        windows.contains { $0.severity == .warning || $0.severity == .critical }
    }
}

/// Parses Anthropic's OAuth usage response.
///
/// The endpoint is undocumented, so this is written defensively: it prefers the
/// structured `limits` array, falls back to the older top-level `five_hour` /
/// `seven_day` objects when that is absent, and drops any entry it cannot read
/// rather than failing the whole parse. The response also carries a dozen
/// null-valued internal codenames which are ignored by only reading what we
/// name explicitly.
public enum ClaudeUsageParser {

    public static func parse(_ json: [String: Any], now: Date) -> QuotaSnapshot? {
        var windows = parseLimits(json)
        if windows.isEmpty { windows = parseLegacyWindows(json) }
        guard !windows.isEmpty else { return nil }
        return QuotaSnapshot(provider: "claude", displayName: "Claude",
                             windows: windows, checkedAt: now)
    }

    /// The modern shape: `limits: [{kind, percent, severity, resets_at, is_active}]`.
    private static func parseLimits(_ json: [String: Any]) -> [QuotaWindow] {
        guard let limits = json["limits"] as? [[String: Any]] else { return [] }
        return limits.compactMap { entry in
            guard let kind = entry["kind"] as? String,
                  let percent = intValue(entry["percent"]) else { return nil }
            return QuotaWindow(
                kind: kind,
                percentUsed: percent,
                severity: .parse(entry["severity"] as? String),
                resetsAt: date(from: entry["resets_at"]),
                isActive: entry["is_active"] as? Bool ?? false
            )
        }
    }

    /// The older shape, kept as a fallback: top-level objects carrying
    /// `utilization` instead of `percent`, and no severity at all.
    private static func parseLegacyWindows(_ json: [String: Any]) -> [QuotaWindow] {
        ["five_hour", "seven_day"].compactMap { key in
            guard let window = json[key] as? [String: Any],
                  let used = intValue(window["utilization"]) else { return nil }
            return QuotaWindow(
                kind: key,
                percentUsed: used,
                severity: .unknown,   // this shape does not report one
                resetsAt: date(from: window["resets_at"]),
                isActive: true
            )
        }
    }

    /// `percent` arrives as an Int, `utilization` as a Double — accept either,
    /// and round rather than truncate so 99.6% does not read as 99%.
    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d.rounded()) }
        return nil
    }

    /// `resets_at` is ISO-8601 with fractional seconds; the formatter that
    /// omits them returns nil for these, so both are tried.
    static func date(from any: Any?) -> Date? {
        if let seconds = any as? Double { return Date(timeIntervalSince1970: seconds) }
        guard let raw = any as? String, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }
}
