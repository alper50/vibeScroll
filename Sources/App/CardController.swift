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

    /// A remark about something that just happened, laid over whatever card
    /// was showing. Clears itself; the card underneath comes back.
    @Published private(set) var moment: Moment?

    /// Set once the user presses Next, cleared when they dismiss.
    ///
    /// Pressing Next is an explicit "I am reading this". While it is set, an
    /// automatic card must not replace what is on screen — otherwise the
    /// surface would yank itself out from under the person using it. Cards no
    /// longer auto-dismiss, so `dismiss()` is the only thing that clears it.
    @Published private(set) var isBrowsing = false

    /// Show the visible card belongs to. Manual navigation stays inside it
    /// until its material runs out.
    private var activeCategory: CardCategory?

    /// What the panel is showing.
    enum Mode { case card, sessions, categories }
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
            // The gate is reset alongside the scheduler: a session that
            // started while cards were off should not count against the first
            // moment after they come back.
            if !enabled { dismissCard() } else { scheduler.reset(); momentGate.reset() }
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

    /// Whether the eyes follow the pointer while it is over the face.
    ///
    /// On by default, and cheap to leave on: it is driven by mouse-move events
    /// and does nothing at all when nothing is over the face. Off is still
    /// worth offering — a face that watches the cursor is charming to some
    /// people and distracting to others, and that is not a judgement the app
    /// gets to make for anyone.
    @Published var followsPointer: Bool =
        (UserDefaults.standard.object(forKey: followsPointerKey) as? Bool) ?? true
    {
        didSet {
            UserDefaults.standard.set(followsPointer, forKey: Self.followsPointerKey)
            // Turning it off with the pointer already on the face would
            // otherwise leave the eyes stuck where they last looked. It governs
            // the idle flicks too: somebody who asked for still eyes meant
            // still, not "still except when you are not looking".
            if !followsPointer {
                GazeModel.shared.stopIdleMotion()
                GazeModel.shared.rest()
            } else if FaceMotion.running {
                // Only while a face is on screen. In the notch style there
                // are no eyes to move, and `FaceMotion` starts this when the
                // floating face comes back.
                GazeModel.shared.startIdleMotion()
            }
        }
    }

    private static let faceWhenIdleKey = "vibescroll.showFaceWhenIdle"
    private static let followsPointerKey = "vibescroll.faceFollowsPointer"

    /// Starts from what was read in earlier runs, so a relaunch carries on
    /// through the catalogue instead of opening on the same first card.
    private let scheduler = CardScheduler(history: CardHistory.load(),
                                          orderSeed: CardHistory.orderSeed)
    private var momentGate = MomentGate()
    private var momentExpiry: DispatchWorkItem?

    /// Applies a pacing policy (Settings exposes a "calm / normal / eager" preset).
    func apply(policy: CardScheduler.Policy) {
        scheduler.update(policy: policy)
    }

    // MARK: - Automatic

    /// Called on every session refresh. Cheap and idempotent: the scheduler
    /// rejects almost every call, which is the point.
    ///
    /// The agent's activity decides *when* a card may appear — its topic has to
    /// hold for the dwell and clear its own cooldown — and the whole catalogue
    /// is the pool, least recently shown first, so the shows take turns.
    func consider(sessions: [AgentSession], now: Date = Date()) {
        // Recorded before any gate: the sessions list must stay live even when
        // cards are paused, the user is browsing, or the list itself is open.
        let previousCount = self.sessions.count
        let wasEmpty = self.sessions.isEmpty
        self.sessions = sessions
        // A first session brings the panel back after everything went quiet;
        // the last one leaving takes it away again.
        if wasEmpty != sessions.isEmpty {
            if !sessions.isEmpty {
                suppressed = false
            } else if mode == .sessions {
                // The list has nothing left to list. `openSessions` already
                // refuses to open an empty one, so leaving this one up would
                // contradict it — and "No active agents" is not what somebody
                // who asked to see their agents wants left on screen. Back to
                // the card if there is one, closed if there is not.
                mode = .card
            }
            syncPanel()
        } else if mode == .sessions, sessions.count != previousCount {
            // Otherwise only resize when the row count actually changed: the
            // daemon refreshes several times a second and resizing on every
            // tick would make the panel visibly jitter.
            syncPanel()
        }
        // Read before the gates below, and deliberately not remembered past
        // them: "they have all just stopped" is true for a moment, and a gate
        // that held it would have the face announce it once cards came back on
        // — about something that finished half an hour ago.
        let justWentQuiet = noteWorkingCount(sessions, now: now)

        guard enabled, !isBrowsing, mode == .card else { return }
        raiseMilestones(sessions, justWentQuiet: justWentQuiet, now: now)
        guard let topic = CategoryResolver.aggregate(sessions) else { return }
        // `aggregate` already picked the session; find it again for the dwell
        // clock and the context line.
        let relevant = sessions.filter { $0.state == .working && $0.topic == topic }
        guard let leader = relevant.max(by: { $0.topicSince < $1.topicSince }) else { return }

        let candidates = ContentStore.shared.allCards
        guard !candidates.isEmpty else { return }

        guard let card = scheduler.next(
            topic: topic, topicSince: leader.topicSince, candidates: candidates, now: now
        ) else { return }

        activeCategory = card.category
        present(card, context: relevant, automatic: true)
    }

    // MARK: - Manual

    /// Advances to the next card. Answers to none of the pacing gates: the user
    /// asked, so they get one. Keeps the existing context line — the agent is
    /// still doing whatever it was doing.
    func showNext(now: Date = Date()) {
        guard let card = scheduler.advance(
            from: ContentStore.shared.allCards,
            category: activeCategory,
            excluding: current?.id,
            now: now
        ) else { return }

        isBrowsing = true
        // Manual reads count: a card browsed to now won't resurface
        // automatically inside its repeat window.
        scheduler.recordShown(card, now: now)
        present(card, context: context, automatic: false)
    }

    /// What the session list should say about quota, or `nil` when there is
    /// nothing honest to say — the probe is off, or nothing on screen is
    /// covered by it. Recomputed on read: both inputs are already published,
    /// and the alternative is a third copy of them to keep in step.
    var quotaSummary: QuotaSummary.Summary? {
        QuotaSummary.summarise(sessions: sessions, snapshot: UsageProbe.shared.snapshot)
    }

    /// Shows that actually have cards, with their counts.
    ///
    /// Empty categories are left out rather than shown disabled: a picker whose
    /// rows do nothing teaches the user to distrust the rest of them, and which
    /// shows have content is the backend's business to change, not something
    /// worth reporting as a gap here.
    var browsableCategories: [(category: CardCategory, count: Int)] {
        CardCategory.allCases.compactMap { category in
            let count = ContentStore.shared.cards(for: category).count
            return count > 0 ? (category, count) : nil
        }
    }

    /// Opens the topic picker from the card's category badge.
    func showCategories() {
        guard !browsableCategories.isEmpty else { return }
        mode = .categories
        suppressed = false
        syncPanel()
    }

    /// Jumps to a show the user picked.
    ///
    /// Manual navigation, like `showNext`, and it answers to none of the pacing
    /// gates for the same reason: they exist to stop the surface talking over
    /// you, and this is you asking. `isBrowsing` is set so an automatic card
    /// cannot replace what was just requested, and the pick counts as seen.
    ///
    /// `activeCategory` moves too, so the Next button carries on inside the show
    /// that was chosen.
    func showCategory(_ category: CardCategory, now: Date = Date()) {
        let candidates = ContentStore.shared.cards(for: category)
        // Being inside its repeat window is not a reason to refuse a show
        // somebody explicitly asked for. Same escape as `advance`'s last tier,
        // which is what stops Next dead-ending once the catalogue has been seen.
        guard let card = scheduler.pick(from: candidates, now: now)
                ?? scheduler.leastRecentlyShown(in: candidates, now: now)
        else { return }

        activeCategory = category
        isBrowsing = true
        scheduler.recordShown(card, now: now)
        present(card, context: context, automatic: false)
    }

    /// Shows a card immediately, bypassing every gate. Used by the Settings
    /// preview button — it must not consume the real pacing budget, so it does
    /// not go through the scheduler at all.
    func preview(_ card: InfoCard) {
        activeCategory = card.category
        present(card, context: [], automatic: false)
        // The notch does not open for cards by itself, but a preview is
        // somebody asking to see one.
        if DisplayStyleStore.shared.effective == .notch {
            NotchWindowController.shared.expand(page: .card)
        }
    }

    /// Working sessions at the last refresh, for the edge where the last one
    /// stops.
    private var previousWorkingCount = 0
    /// When the last working session stopped — or, on a machine where nothing
    /// has started yet, when the app first looked. `nil` while an agent is up.
    private var quietSince: Date?
    /// Quiet milestones already remarked on, forgotten as soon as work resumes.
    private var quietMilestonesShown: Set<Int> = []

    /// Updates the quiet clock. Returns whether the last working session
    /// stopped on *this* refresh.
    ///
    /// Only `working` counts. A session sitting in `waiting` has stopped for as
    /// long as you have taken to answer it, which is not the room going quiet —
    /// it is the room waiting for you, and the face already says that.
    private func noteWorkingCount(_ sessions: [AgentSession], now: Date) -> Bool {
        let working = sessions.filter { $0.state == .working }.count
        defer { previousWorkingCount = working }

        guard working == 0 else {
            quietSince = nil
            quietMilestonesShown.removeAll()
            return false
        }
        if quietSince == nil { quietSince = now }
        return previousWorkingCount > 0
    }

    /// Thresholds worth remarking on. All floored to a whole step so the key is
    /// stable — the gate rate-limits per key, and a key that changed every
    /// second would defeat it.
    private func raiseMilestones(
        _ sessions: [AgentSession], justWentQuiet: Bool, now: Date
    ) {
        let live = sessions.filter { $0.state == .working || $0.state == .waiting }
        if live.count >= 3 {
            raise(.crowd(count: live.count), now: now)
        }
        if let oldest = sessions.map(\.createdAt).min() {
            let hours = Int(now.timeIntervalSince(oldest) / 3600)
            if hours >= 3 { raise(.longHaul(hours: hours), now: now) }
        }
        // Worth saying while the sessions are still listed to point at. Once
        // they have been pruned there is nothing left to have stopped.
        if justWentQuiet, !sessions.isEmpty {
            raise(.allQuiet(count: sessions.count), now: now)
        }
        raiseQuietCheckIn(now: now)
    }

    /// The face making conversation when there is nothing to report.
    ///
    /// A milestone is recorded only once it actually got through: one the gate
    /// swallowed has not been made, and marking it made would skip it for good.
    private func raiseQuietCheckIn(now: Date) {
        guard let quietSince else { return }
        let minutes = Int(now.timeIntervalSince(quietSince) / 60)
        guard let milestone = Moment.quietMilestones.last(where: { $0 <= minutes }),
              !quietMilestonesShown.contains(milestone)
        else { return }
        if raise(.stillHere(quietForMinutes: milestone), now: now) {
            quietMilestonesShown.insert(milestone)
        }
    }

    // MARK: - Moments

    /// Shows a moment, if the gate lets it through.
    ///
    /// Answers to the same switches a card does — off means off, and somebody
    /// reading a card they asked for should not have it covered. The session
    /// list is left alone for the same reason: it is a thing being used.
    @discardableResult
    func raise(_ moment: Moment, now: Date = Date()) -> Bool {
        guard enabled, !isBrowsing, mode == .card else { return false }
        // A panel put away by hand stays away for small talk. News earns its
        // way back on screen; a check-in has not earned anything.
        if moment.isAmbient, suppressed { return false }
        guard momentGate.admit(moment, now: now) else { return false }

        self.moment = moment
        // Like a card: something worth saying is a reason to be back on screen.
        if !moment.isAmbient { suppressed = false }
        syncPanel()

        momentExpiry?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { self.clearMoment() } }
        momentExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + momentGate.policy.dwell, execute: work)
        return true
    }

    private func clearMoment() {
        guard moment != nil else { return }
        moment = nil
        // Straight back to whatever was underneath, which `syncPanel` works
        // out on its own — a card, or nothing at all.
        syncPanel()
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

    /// What a click on the face does: bring the session list up, or put it
    /// away again. `showCard` is the right way back — with a card underneath
    /// it returns to that, and with nothing underneath the panel closes, which
    /// is what "away" means when there was never anything else there.
    ///
    /// `suppressed` needs no test here: it hides the face too, so there is no
    /// face to click while it is set.
    func toggleSessions() {
        mode == .sessions ? showCard() : showSessions()
    }

    /// Whether there is a card to go back to from a list mode.
    var hasCardBehind: Bool { current != nil }

    /// Opens the list from outside the panel (the menu bar), showing it even
    /// when no card is on screen.
    func openSessions() {
        guard current != nil || !sessions.isEmpty else { return }
        if DisplayStyleStore.shared.effective == .notch {
            suppressed = false
            syncPanel()
            NotchWindowController.shared.expand(page: .sessions)
            return
        }
        showSessions()
    }

    /// Menu bar toggle: away if it is up, back if it is not.
    func togglePanel() {
        let faceUp = DisplayStyleStore.shared.effective == .notch
            ? NotchWindowController.shared.isVisible
            : FaceWindowController.shared.frame != nil
        if suppressed || !faceUp {
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
        momentExpiry?.cancel()
        moment = nil
        activeCategory = nil
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
        momentExpiry?.cancel()
        moment = nil
        activeCategory = nil
        isBrowsing = false
        mode = .card
        suppressed = true
        syncPanel()
    }

    /// vibeScroll was opened again while already running. With the menu bar
    /// icon gone in the notch style, that is the way back after the panel
    /// has been hidden by hand.
    func reveal() {
        suppressed = false
        syncPanel()
    }

    /// The notch closed. Whatever was being browsed there has been put down,
    /// so automatic cards may come again — the floating panel gets the same
    /// from its close button, which the notch does not have.
    func endBrowsing() {
        guard isBrowsing || mode != .card else { return }
        isBrowsing = false
        mode = .card
        syncPanel()
    }

    /// The style changed, or the notch came or went with a display.
    func displayStyleChanged() {
        NotchWindowController.shared.collapse()
        if let current, DisplayStyleStore.shared.effective == .notch {
            notchCardContentHeight = CardMeasure.contentHeight(
                of: current, context: context,
                width: NotchLayout.contentWidth(notchWidth: DisplayStyleStore.shared.notch?.notchWidth
                                                ?? NotchLayout.fallbackNotchWidth))
        }
        syncPanel()
    }

    /// Set by `hidePanel`, cleared the moment anything new happens. A panel
    /// dismissed by hand should stay away, but not for ever: the next agent to
    /// start is a new reason to be on screen.
    private var suppressed = false

    // MARK: - Panel state

    /// What sits under the face right now.
    var panelContent: CardLayout.PanelContent {
        switch mode {
        case .sessions:
            return .sessions(count: sessions.count, hasQuota: quotaSummary != nil)
        case .categories: return .categories(count: browsableCategories.count)
        // The moment wins while it is up. It is the only content here with an
        // expiry, so the card it covers is still there when it goes.
        case .card:     return moment != nil ? .moment
                            : (current == nil ? .none : .card(contentHeight: cardContentHeight))
        }
    }

    /// Which windows belong on screen. The rule itself is in `CardLayout`, so
    /// the one invariant that broke here — a card with no face under it — is a
    /// test rather than something you meet by going idle with the list open.
    private var visibility: CardLayout.PanelVisibility {
        CardLayout.visibility(
            content: panelContent,
            hasSessions: !sessions.isEmpty,
            hasCard: current != nil,
            showsFaceWhenIdle: showsFaceWhenIdle,
            suppressed: suppressed)
    }

    /// The single place either window is shown or hidden.
    ///
    /// Two windows with opposite lifetimes: the face is the ambient layer and
    /// is up whenever there is an agent to watch, while the card is occasional
    /// and only up when it has something in it.
    ///
    /// The notch style draws the same state in one window instead of two: the
    /// face goes up and down with the same rule, and the card waits inside it
    /// rather than opening a panel of its own.
    private func syncPanel() {
        let windows = visibility
        let notch = DisplayStyleStore.shared.effective == .notch
        // Only while the floating face is on screen: the notch draws none.
        FaceMotion.setRunning(windows.face && !notch)
        StatusBarController.shared.setVisible(!notch)

        if notch {
            FaceWindowController.shared.setVisible(false)
            CardWindowController.shared.hide()
            // Up whenever it has not been put away by hand. When there is
            // nothing to show it is only the notch — no wings, nothing drawn
            // beside the camera — and costs nothing, while hovering the notch
            // still opens the sessions and tasks behind it.
            NotchWindowController.shared.setVisible(!suppressed)
            return
        }
        NotchWindowController.shared.setVisible(false)
        FaceWindowController.shared.setVisible(windows.face)

        guard windows.card else {
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
        greetOnFirstRun()
    }

    private static let welcomedKey = "vibescroll.welcomed"

    /// Once ever, and not on the same turn as the window appearing — the face
    /// is still fading in, and a card unfolding out of something that is not
    /// there yet has nothing to unfold from.
    private func greetOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: Self.welcomedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.welcomedKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated { _ = CardController.shared.raise(.welcome) }
        }
    }

    /// The visible card's measured height, taken once when it arrives.
    ///
    /// With the finished text rather than whatever the typewriter has shown so
    /// far, so the panel is the right size before the first letter and never
    /// grows while the card writes itself out.
    private(set) var cardContentHeight: Double = CardLayout.maxCardHeight
    /// The same card laid out at the notch island's width.
    private(set) var notchCardContentHeight: Double = CardLayout.maxCardHeight

    /// `automatic` is a card the scheduler chose rather than one somebody asked
    /// for. Only those raise the notch's badge and make the face look up.
    private func present(_ card: InfoCard, context: [AgentSession], automatic: Bool) {
        cardContentHeight = CardMeasure.contentHeight(of: card, context: context)
        // Only when the notch is what will show it: a second off-screen
        // layout per card is cheap, but not free, and the floating face never
        // reads this. A style switch mid-card lands on the clamp at worst.
        if DisplayStyleStore.shared.effective == .notch {
            notchCardContentHeight = CardMeasure.contentHeight(
                of: card, context: context,
                width: NotchLayout.contentWidth(notchWidth: DisplayStyleStore.shared.notch?.notchWidth
                                                ?? NotchLayout.fallbackNotchWidth))
        }
        // Every way a card reaches the screen — automatic, Next, the picker —
        // comes through here, having just been recorded as shown. Saved here
        // once, so no path can forget to.
        CardHistory.save(scheduler.history)
        current = card
        self.context = context
        mode = .card
        suppressed = false
        syncPanel()
        NotchWindowController.shared.cardArrived(card, automatic: automatic)
    }
}
