import Foundation

/// Pure formatting and sorting logic for the desktop-pet ticker.
/// Lives in VibeScrollCore so it can be unit-tested without AppKit.
public enum TickerFormatter {

    /// Short display label for an agent kind.
    public static func agentLabel(for kind: AgentKind) -> String {
        switch kind {
        case .claude:    return "Claude"
        case .cursor:    return "Cursor"
        case .codex:     return "Codex"
        case .gemini:    return "Gemini"
        case .opencode:  return "Opencode"
        case .windsurf:  return "Windsurf"
        case .antigravity: return "Antigravity"
        case .copilot:   return "Copilot"
        case .kiroCLI:   return "Kiro"
        case .droid:     return "Droid"
        case .pi:        return "Pi"
        case .grok:      return "Grok"
        case .cli:       return String(localized: "Agent")
        case .unknown:   return String(localized: "Agent")
        }
    }

    /// One ticker line for a single session.
    /// Format: `<AgentLabel> [<project>] → <message>`
    public static func line(for session: AgentSession) -> String {
        let label   = agentLabel(for: session.agentKind)
        let project = session.project.map { ($0 as NSString).lastPathComponent } ?? session.id
        let msg: String
        if let m = session.message, !m.trimmingCharacters(in: .whitespaces).isEmpty {
            msg = m
        } else {
            msg = session.state.label
        }
        return "\(label) [\(project)] → \(msg)"
    }

    /// Compact elapsed label: "5s", "3m", "1h", "1h 4m". Time is passed in
    /// rather than read, so the boundaries are testable.
    public static func elapsed(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return String(localized: "\(seconds)s") }
        let minutes = seconds / 60
        if minutes < 60 { return String(localized: "\(minutes)m") }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? String(localized: "\(hours)h")
            : String(localized: "\(hours)h \(remainder)m")
    }

    /// Compact token count: "512", "3.4k", "847k", "1.2M".
    ///
    /// Precision drops as magnitude rises because the reader only ever needs the
    /// order of magnitude — "1.2M" answers "is this session expensive?" and
    /// "1,203,847" does not answer it any better in a 340pt row.
    public static func tokens(_ count: Int) -> String {
        let n = max(0, count)
        switch n {
        case ..<1_000:
            return "\(n)"
        case ..<10_000:
            // One decimal only in the band where it carries information.
            return String(format: "%.1fk", Double(n) / 1_000)
        case ..<1_000_000:
            return "\(n / 1_000)k"
        default:
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    /// Sort order for the ticker: waiting first, then working (most-recently
    /// updated first), then done. Idle and registered sessions are excluded
    /// before calling this — the caller is responsible for filtering.
    public static func sorted(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { a, b in
            let pa = priority(a.state)
            let pb = priority(b.state)
            if pa != pb { return pa < pb }
            return a.updatedAt > b.updatedAt
        }
    }

    // MARK: - Private

    private static func priority(_ state: AgentState) -> Int {
        switch state {
        case .waiting:    return 0
        case .working:    return 1
        case .done:       return 2
        case .idle:       return 3
        case .registered: return 4
        }
    }
}
