import Foundation
import VibeScrollCore

/// Turns session activity into card impressions, and owns manual navigation.
///
/// The daemon calls `consider(sessions:)` on every refresh (which is often —
/// several times a second under load). All pacing lives in `CardScheduler`, so
/// this type stays a thin translation layer: resolve the topic, ask the
/// scheduler, hand the winner to the window.
@MainActor
final class CardController: ObservableObject {
    static let shared = CardController()

    /// The card currently on screen, or `nil` when nothing is showing.
    @Published private(set) var current: InfoCard?
    /// Sessions that justified the current card, for the card's context line.
    @Published private(set) var context: [AgentSession] = []

    /// Set once the user presses Next, cleared when they dismiss.
    ///
    /// Pressing Next is an explicit "I am reading this". While it is set, an
    /// automatic card must not replace what is on screen — otherwise the
    /// surface would yank itself out from under the person using it. Cards no
    /// longer auto-dismiss, so `dismiss()` is the only thing that clears it.
    @Published private(set) var isBrowsing = false

    /// Topic that triggered the visible card. Manual navigation stays inside it
    /// until its material runs out.
    private var activeTopic: TopicCategory?

    /// What the panel is showing.
    enum Mode { case card, sessions }
    @Published private(set) var mode: Mode = .card

    /// Every live session, refreshed by the daemon. Kept up to date even while
    /// the panel is hidden so opening the list is instant and never stale.
    @Published private(set) var sessions: [AgentSession] = []

    /// Master switch, mirrored into Settings.
    @Published var enabled: Bool = (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            // Cards off, face unaffected: they are separate features that
            // happen to share a window.
            if !enabled { dismissCard() } else { scheduler.reset() }
        }
    }

    private static let enabledKey = "vibescroll.cardsEnabled"

    /// Whether the face stays out when nothing is running.
    ///
    /// On by default. The face asleep is still telling you something — that
    /// vibeScroll is running and no agent is — and an app whose only surface
    /// appears once you have already started working is hard to trust is
    /// working at all.
    @Published var showsFaceWhenIdle: Bool =
        (UserDefaults.standard.object(forKey: faceWhenIdleKey) as? Bool) ?? true
    {
        didSet {
            UserDefaults.standard.set(showsFaceWhenIdle, forKey: Self.faceWhenIdleKey)
            syncPanel()
        }
    }

    private static let faceWhenIdleKey = "vibescroll.showFaceWhenIdle"

    private let scheduler = CardScheduler()

    /// Applies a pacing policy (Settings exposes a "calm / normal / eager" preset).
    func apply(policy: CardScheduler.Policy) {
        scheduler.update(policy: policy)
    }

    // MARK: - Automatic

    /// Called on every session refresh. Cheap and idempotent: the scheduler
    /// rejects almost every call, which is the point.
    func consider(sessions: [AgentSession], now: Date = Date()) {
        // Recorded before any gate: the sessions list must stay live even when
        // cards are paused, the user is browsing, or the list itself is open.
        let previousCount = self.sessions.count
        let wasEmpty = self.sessions.isEmpty
        self.sessions = sessions
        // A first session brings the panel back after everything went quiet;
        // the last one leaving takes it away again.
        if wasEmpty != sessions.isEmpty {
            if !sessions.isEmpty { suppressed = false }
            syncPanel()
        } else if mode == .sessions, sessions.count != previousCount {
            // Otherwise only resize when the row count actually changed: the
            // daemon refreshes several times a second and resizing on every
            // tick would make the panel visibly jitter.
            syncPanel()
        }

        guard enabled, !isBrowsing, mode == .card else { return }
        guard let topic = CategoryResolver.aggregate(sessions) else { return }
        // `aggregate` already picked the session; find it again for the dwell
        // clock and the context line.
        let relevant = sessions.filter { $0.state == .working && $0.topic == topic }
        guard let leader = relevant.max(by: { $0.topicSince < $1.topicSince }) else { return }

        let candidates = ContentStore.shared.cards(for: topic)
        guard !candidates.isEmpty else { return }

        guard let card = scheduler.next(
            topic: topic, topicSince: leader.topicSince, candidates: candidates, now: now
        ) else { return }

        activeTopic = topic
        present(card, context: relevant)
    }

    // MARK: - Manual

    /// Advances to the next card. Answers to none of the pacing gates: the user
    /// asked, so they get one. Keeps the existing context line — the agent is
    /// still doing whatever it was doing.
    func showNext(now: Date = Date()) {
        guard let card = scheduler.advance(
            from: ContentStore.shared.allCards,
            topic: activeTopic,
            excluding: current?.id,
            now: now
        ) else { return }

        isBrowsing = true
        // Manual reads count: a card browsed to now won't resurface
        // automatically inside its repeat window.
        scheduler.recordShown(card, now: now)
        present(card, context: context)
    }

    /// Shows a card immediately, bypassing every gate. Used by the Settings
    /// preview button — it must not consume the real pacing budget, so it does
    /// not go through the scheduler at all.
    func preview(_ card: InfoCard) {
        activeTopic = card.category
        present(card, context: [])
    }

    // MARK: - Modes

    /// Switches the panel to the session list. Suppresses automatic cards for
    /// the same reason browsing does: the user is looking at something.
    func showSessions() {
        mode = .sessions
        suppressed = false
        syncPanel()
    }

    /// Back to the card. If nothing was showing (the list was opened from an
    /// empty panel) there is nothing to go back to, so close instead.
    func showCard() {
        mode = .card
        syncPanel()
    }

    /// Opens the list from outside the panel (the menu bar), showing it even
    /// when no card is on screen.
    func openSessions() {
        guard current != nil || !sessions.isEmpty else { return }
        showSessions()
    }

    /// Menu bar toggle: away if it is up, back if it is not.
    func togglePanel() {
        if suppressed || FaceWindowController.shared.frame == nil {
            suppressed = false
            syncPanel()
        } else {
            hidePanel()
        }
    }

    func focus(_ session: AgentSession) {
        SessionFocus.focus(session)
    }

    /// Closes the card and leaves the face behind.
    ///
    /// The close button used to mean "close the panel", which was the same
    /// thing when the panel was only ever a card. With an always-on face it no
    /// longer is: dismissing what you have read should not also take away the
    /// status you were glancing at.
    func dismissCard() {
        current = nil
        context = []
        activeTopic = nil
        isBrowsing = false
        mode = .card
        syncPanel()
    }

    /// Puts the whole panel away until something happens. The menu bar's escape
    /// hatch, and what an empty session store does on its own.
    /// Puts both windows away.
    func hidePanel() {
        current = nil
        context = []
        activeTopic = nil
        isBrowsing = false
        mode = .card
        suppressed = true
        CardWindowController.shared.hide()
        FaceWindowController.shared.setVisible(false)
    }

    /// Set by `hidePanel`, cleared the moment anything new happens. A panel
    /// dismissed by hand should stay away, but not for ever: the next agent to
    /// start is a new reason to be on screen.
    private var suppressed = false

    // MARK: - Panel state

    /// What sits under the face right now.
    var panelContent: CardLayout.PanelContent {
        switch mode {
        case .sessions: return .sessions(count: sessions.count)
        case .card:     return current == nil ? .none : .card
        }
    }

    /// Whether the face belongs on screen right now.
    private var shouldShowFace: Bool {
        guard !suppressed else { return false }
        return showsFaceWhenIdle || !sessions.isEmpty || current != nil
    }

    /// The single place either window is shown or hidden.
    ///
    /// Two windows with opposite lifetimes: the face is the ambient layer and
    /// is up whenever there is an agent to watch, while the card is occasional
    /// and only up when it has something in it.
    private func syncPanel() {
        FaceWindowController.shared.setVisible(shouldShowFace)

        // The card is occasional whatever the face is doing: it appears when it
        // has something in it and leaves when it does not.
        guard !suppressed, panelContent != .none else {
            CardWindowController.shared.hide()
            return
        }
        CardWindowController.shared.show(height: CardLayout.panelHeight(for: panelContent))
    }

    /// Puts the face on screen at launch.
    ///
    /// `consider` only syncs when the session list crosses between empty and
    /// not, which never happens on a quiet machine — so without this the face
    /// would wait for the first agent even when it is meant to be resting in
    /// plain sight.
    func start() {
        syncPanel()
    }

    private func present(_ card: InfoCard, context: [AgentSession]) {
        current = card
        self.context = context
        mode = .card
        suppressed = false
        syncPanel()
    }
}
