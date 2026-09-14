import Foundation

/// What the session list should say about quota, given who is on screen.
///
/// Quota is per *account*, not per session: four Claude sessions share one
/// allowance, so a percentage on each row would print the same number four
/// times and read as "this session has used 58%", which is not a thing that
/// exists. It belongs under the list, attached to the list rather than to a row.
///
/// The harder half is attribution. Only Claude Code has a quota probe, so a
/// list holding a Claude session and a Codex session must not let one figure
/// look like it covers both. Three cases, and the difference between them is
/// the whole type:
///
///  - nothing on screen is covered → say nothing at all
///  - everything on screen is covered → the figure needs no owner's name
///  - some of it is covered → name the owner, and say how many it leaves out
///
/// Pure, like `QuotaPace` and `FaceMood`, so each of those cases is a test
/// rather than a thing to check by opening the panel and squinting.
public enum QuotaSummary {

    /// Agent kinds a provider's reading actually covers.
    ///
    /// Strictly Claude Code. Droid and Cursor run Claude models against their
    /// own billing, and the probe reads Claude Code's own sign-in — claiming
    /// their sessions were covered by it would be a straightforward lie.
    public static func coveredKinds(provider: String) -> Set<AgentKind> {
        provider == "claude" ? [.claude] : []
    }

    /// One window, reduced to what a 340pt footer can show.
    public struct Window: Equatable, Sendable {
        public let label: String
        public let percentUsed: Int
        public let severity: QuotaWindow.Severity
        /// Percent at or past the limit, which is the exhaustion signal
        /// everywhere else in this app for the same reason: it means the same
        /// thing for every provider and cannot drift when a label is renamed.
        public var isExhausted: Bool { percentUsed >= 100 }

        public init(label: String, percentUsed: Int, severity: QuotaWindow.Severity) {
            self.label = label
            self.percentUsed = percentUsed
            self.severity = severity
        }
    }

    public struct Summary: Equatable, Sendable {
        /// Whose quota this is, or `nil` when every session on screen is covered
        /// by it and naming an owner would be noise.
        public let attribution: String?
        /// Sessions on screen the reading does not cover.
        public let untrackedCount: Int
        public let windows: [Window]

        public init(attribution: String?, untrackedCount: Int, windows: [Window]) {
            self.attribution = attribution
            self.untrackedCount = untrackedCount
            self.windows = windows
        }
    }

    /// Ordering groups, widest-refreshing first. Session before weekly because
    /// the five-hour window is the one that runs out while you are watching.
    private static func groupRank(_ kind: String) -> Int {
        if QuotaPace.sessionKinds.contains(kind) { return 0 }
        if QuotaPace.weeklyKinds.contains(kind) { return 1 }
        return 2
    }

    /// The footer's content, or `nil` when there is nothing honest to show.
    ///
    /// `nil` covers both "the probe is off" and "nothing on screen is covered
    /// by it", which are different reasons for the same correct outcome: the
    /// list carries on looking exactly as it does today.
    public static func summarise(
        sessions: [AgentSession], snapshot: QuotaSnapshot?, limit: Int = 3
    ) -> Summary? {
        guard let snapshot, !snapshot.windows.isEmpty else { return nil }

        let covered = coveredKinds(provider: snapshot.provider)
        let inScope = sessions.filter { covered.contains($0.agentKind) }
        // A reading with nothing on screen to attach it to is not information
        // about this list, and the sessions panel is about this list.
        guard !inScope.isEmpty else { return nil }

        let windows = snapshot.windows
            .sorted {
                let (a, b) = (groupRank($0.kind), groupRank($1.kind))
                // Within a group the tightest goes first: it is the one that
                // will actually stop you, and it is the one that survives the
                // cap below.
                return a == b ? $0.percentUsed > $1.percentUsed : a < b
            }
            .prefix(max(0, limit))
            .map { Window(label: $0.label, percentUsed: $0.percentUsed, severity: $0.severity) }

        guard !windows.isEmpty else { return nil }

        let untracked = sessions.count - inScope.count
        return Summary(
            // Named only when it would otherwise look like it covered
            // everything. An all-Claude list does not need to be told twice.
            attribution: untracked > 0 ? snapshot.displayName : nil,
            untrackedCount: untracked,
            windows: Array(windows))
    }
}
