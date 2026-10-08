import Foundation

/// How vibeScroll sits on screen: the floating face, or folded into the notch.
///
/// Only the presentation changes. Sessions, cards, the face's mood, quota and
/// the task queue are the same objects either way; this decides which windows
/// draw them.
public enum DisplayStyle: String, CaseIterable, Sendable {
    /// The face in its own orb, anywhere on the desktop, with the card hanging
    /// off it. What vibeScroll has always been.
    case floating
    /// The face beside the camera housing, opening downward like the notch
    /// itself growing.
    case notch

    /// What is actually on screen.
    ///
    /// The notch style needs a notch. With none connected — the lid closed on
    /// an external display, say — the face falls back to floating rather than
    /// disappearing, and the preference is left alone so the notch comes back
    /// by itself when the built-in display does.
    public static func effective(preferred: DisplayStyle?, notchAvailable: Bool) -> DisplayStyle {
        guard preferred == .notch, notchAvailable else { return .floating }
        return .notch
    }

    /// Whether to ask which style somebody wants.
    ///
    /// Only while nothing has been chosen, and only where there is a choice to
    /// make: a Mac without a notch has one style, and a question with one
    /// answer is a formality. Left unanswered there, so the question comes up
    /// the first time the app starts with a notched display.
    public static func shouldAsk(preferred: DisplayStyle?, notchAvailable: Bool) -> Bool {
        preferred == nil && notchAvailable
    }
}

/// Geometry for the notch style.
///
/// The window is a fixed transparent box around the notch, sized for the
/// largest the island can grow to, and never resized — the island animates its
/// own shape inside it. Resizing a window per frame makes SwiftUI lay the whole
/// thing out again on every step, which is exactly the cost this app has spent
/// its life avoiding.
public enum NotchLayout {
    /// One side of the island: the session quota on the left, the agent doing
    /// the work on the right.
    public static let wing: Double = 56
    /// Keeps content off the flared top corners.
    public static let edgeInset: Double = 12

    /// Used when a notched screen reports no usable width.
    public static let fallbackNotchWidth: Double = 185
    public static let fallbackNotchHeight: Double = 32

    /// The closed island: the notch and both wings.
    public static func islandWidth(notchWidth: Double) -> Double {
        notchWidth + (wing + edgeInset) * 2
    }

    /// How far each side pushes out as the island opens. Mostly it grows
    /// downward; this little sideways give, on a spring that overshoots, is
    /// what makes opening read as a pop rather than a blind being lowered.
    public static let openOutset: Double = 14

    /// The open island.
    public static func openWidth(notchWidth: Double) -> Double {
        islandWidth(notchWidth: notchWidth) + openOutset * 2
    }

    public static let sidePadding: Double = 12

    /// Pages fill the open island. Cards are measured at this width for the
    /// notch.
    public static func contentWidth(notchWidth: Double) -> Double {
        openWidth(notchWidth: notchWidth) - sidePadding * 2
    }

    /// How far a side of the island is drawn in from the open width.
    ///
    /// Closed, every side sits `openOutset` in. A wing with nothing to show —
    /// no quota reading, no agent running — folds the rest of the way into
    /// the notch too: a strip of black beside the camera saying nothing just
    /// covers the menu bar. With both empty the island is only the notch.
    public static func wingInset(state: State, hasContent: Bool) -> Double {
        guard state == .collapsed else { return 0 }
        return openOutset + (hasContent ? 0 : wing + edgeInset)
    }

    /// Whether the closed island shows the quota ring.
    ///
    /// While an agent is running or waiting, always. Idle, only when the face
    /// was asked to stay out when nothing is running: otherwise the ring goes
    /// with the agents, the same way the floating face leaves. A card waiting
    /// to be read does not keep it either: idle means the bare notch.
    public static func showsQuota(hasReading: Bool, agentsLive: Bool, keepWhenIdle: Bool) -> Bool {
        hasReading && (agentsLive || keepWhenIdle)
    }

    /// Who is doing the work, for the right wing.
    public struct AgentSummary: Equatable, Sendable {
        /// The agent with the most sessions running or waiting.
        public let leader: AgentKind
        /// Every running or waiting session, whichever agent.
        public let active: Int
        public let waiting: Int
        /// Sessions per agent, most first, for the tooltip.
        public let breakdown: [(kind: AgentKind, count: Int)]

        public static func == (a: Self, b: Self) -> Bool {
            a.leader == b.leader && a.active == b.active && a.waiting == b.waiting
                && a.breakdown.map(\.kind) == b.breakdown.map(\.kind)
                && a.breakdown.map(\.count) == b.breakdown.map(\.count)
        }
    }

    /// The agent most of the live sessions belong to — Cursor when it is
    /// mostly Cursor, Claude when it is mostly Claude.
    ///
    /// Only sessions running or waiting count; one that finished an hour ago
    /// is not who is working. A tie goes to whichever agent was heard from
    /// last, since that is the one that just did something.
    public static func agentSummary(for sessions: [AgentSession]) -> AgentSummary? {
        let live = sessions.filter { $0.state == .working || $0.state == .waiting }
        guard !live.isEmpty else { return nil }
        var counts: [AgentKind: Int] = [:]
        var latest: [AgentKind: Date] = [:]
        for session in live {
            counts[session.agentKind, default: 0] += 1
            latest[session.agentKind] = max(latest[session.agentKind] ?? .distantPast, session.updatedAt)
        }
        let ranked = counts.keys.sorted { a, b in
            if counts[a]! != counts[b]! { return counts[a]! > counts[b]! }
            if latest[a]! != latest[b]! { return latest[a]! > latest[b]! }
            return a.rawValue < b.rawValue
        }
        return AgentSummary(
            leader: ranked[0],
            active: live.count,
            waiting: live.filter { $0.state == .waiting }.count,
            breakdown: ranked.map { ($0, counts[$0]!) })
    }

    /// The quota the closed island shows: the rolling session window — the
    /// one that runs out in an afternoon — or, from a provider that reports
    /// no such window, whichever is closest to its limit.
    public static func quotaWindow(in snapshot: QuotaSnapshot?) -> QuotaWindow? {
        guard let snapshot else { return nil }
        return snapshot.windows.first { QuotaPace.sessionKinds.contains($0.kind) }
            ?? snapshot.tightest
    }

    /// The page switcher at the top of the open island.
    public static let tabBarHeight: Double = 30
    public static let bottomPadding: Double = 8

    /// A page is as tall as what is on it, between these two.
    public static let minPageHeight: Double = 72
    public static let maxPageHeight: Double = 400

    /// Height below the notch when open, for a page whose content wants
    /// `pageHeight`.
    public static func dropHeight(pageHeight: Double) -> Double {
        tabBarHeight + clampedPageHeight(pageHeight) + bottomPadding
    }

    public static func clampedPageHeight(_ pageHeight: Double) -> Double {
        let page = pageHeight.isFinite ? pageHeight : maxPageHeight
        return min(max(page.rounded(.up), minPageHeight), maxPageHeight)
    }

    /// Room around the island inside its window.
    public static let windowMargin: Double = 24

    /// The fixed window: wide enough for the open island, tall enough for
    /// the tallest page.
    public static func windowSize(notchWidth: Double, notchHeight: Double) -> CGSize {
        CGSize(width: openWidth(notchWidth: notchWidth) + windowMargin * 2,
               height: notchHeight + dropHeight(pageHeight: maxPageHeight) + windowMargin)
    }

    /// What the open island shows, in the order its tabs read.
    public enum Page: Int, CaseIterable, Sendable {
        case sessions, card, tasks

        /// The page a swipe lands on, or `nil` at either end.
        public func neighbour(forward: Bool) -> Page? {
            Page(rawValue: rawValue + (forward ? 1 : -1))
        }
    }

    /// Where opening lands: on the card if one is waiting to be read — that
    /// is the reason somebody clicked — otherwise wherever they left it.
    public static func openingPage(hasUnreadCard: Bool, last: Page) -> Page {
        hasUnreadCard ? .card : last
    }

    public enum State: Equatable, Sendable {
        case collapsed
        /// Open, by hovering or by a click.
        case expanded
    }
}

/// Whether the card waiting in the notch has been seen.
///
/// The notch never unfolds on its own — a card arriving marks itself here and
/// a dot appears on the closed island, and that is all. It is read when somebody opens the card
/// page, or when the card goes away.
public struct NotchInbox: Equatable, Sendable {
    public private(set) var unreadCardID: String?

    public init(unreadCardID: String? = nil) {
        self.unreadCardID = unreadCardID
    }

    public var hasUnread: Bool { unreadCardID != nil }

    /// A card reached the notch. Nothing is unread if it arrived in front of
    /// somebody already looking at the card page — Next, a picked show — or
    /// because they asked for it.
    public mutating func arrived(cardID: String, alreadyVisible: Bool) {
        unreadCardID = alreadyVisible ? nil : cardID
    }

    /// The card page was opened.
    public mutating func viewed() { unreadCardID = nil }

    /// The card left before anyone read it: dismissed, or the cards turned off.
    /// A badge for a card that is no longer there points at nothing.
    public mutating func cardChanged(to currentID: String?) {
        guard let unread = unreadCardID, unread != currentID else { return }
        unreadCardID = nil
    }
}
