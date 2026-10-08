import AppKit
import SwiftUI
import VibeScrollCore

/// The notch style: the face beside the camera, opening downward on a click.
///
/// A second presentation of the same state, not a second app. What is shown —
/// the sessions, the card, the mood, the queue — is decided by `CardController`
/// and the models behind it exactly as for the floating face; this decides
/// only how it is drawn around the notch.
///
/// **One fixed window.** The panel is sized once for the largest the island
/// can become and never resized. The island animates its own shape inside it,
/// and everything outside the shape is transparent and passes clicks through
/// to the menu bar and the desktop below.
@MainActor
final class NotchWindowController: NSObject {
    static let shared = NotchWindowController()

    let model = NotchModel()

    private var panel: NotchPanel?
    private var host: PassthroughHostingView<NotchRootView>?
    private var wantsVisible = false
    private var outsideClickMonitors: [Any] = []
    private var hoverWork: DispatchWorkItem?

    /// Sliding out of and back into the notch.
    private static let fade: TimeInterval = 0.28
    /// How long the pointer rests on the notch before it opens. Long enough
    /// that sweeping along the menu bar does not throw it open, short enough
    /// that resting there feels like it answered.
    private static let hoverDelay: TimeInterval = 0.3
    /// Grace after the pointer leaves before a hover-opened island closes, so
    /// overshooting its edge by a few points does not snap it shut.
    private static let leaveDelay: TimeInterval = 0.35

    var isVisible: Bool { panel?.isVisible ?? false }

    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Visibility

    /// Called by `CardController.syncPanel` with the same answer the floating
    /// face gets: up while there is anything to watch, down when put away.
    func setVisible(_ visible: Bool) {
        wantsVisible = visible
        model.inbox.cardChanged(to: CardController.shared.current?.id)
        visible ? present() : dismiss()
    }

    private func present() {
        guard let notch = DisplayStyleStore.shared.notch else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        model.geometry = notch

        if !panel.isVisible {
            panel.setFrame(frame(for: notch), display: false)
            panel.alphaValue = prefersReducedMotion ? 1 : 0
            model.shown = prefersReducedMotion
            panel.orderFrontRegardless()
            // A turn of the run loop first, so the closed state has been drawn
            // and the wings have something to grow out of.
            Task { @MainActor [weak self] in self?.model.shown = true }
        }
        guard !prefersReducedMotion else { panel.alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        collapse()
        guard let panel, panel.isVisible else { return }
        model.shown = false
        guard !prefersReducedMotion else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fade
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self, !self.wantsVisible else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    /// Display arrangement changed: follow the notch to wherever it now is.
    func relayout() {
        guard let panel, let notch = DisplayStyleStore.shared.notch else { return }
        model.geometry = notch
        panel.setFrame(frame(for: notch), display: true)
    }

    private func frame(for notch: NotchScreen) -> NSRect {
        let size = NotchLayout.windowSize(notchWidth: notch.notchWidth,
                                          notchHeight: notch.notchHeight)
        return NSRect(x: notch.notchMidX - Double(size.width) / 2,
                      y: Double(notch.frame.maxY) - Double(size.height),
                      width: Double(size.width), height: Double(size.height))
    }

    /// Whether the island rides onto full-screen Spaces.
    ///
    /// Leaving `.fullScreenAuxiliary` out is how a window asks not to appear
    /// over a full-screen app — the window server simply does not put it on
    /// that Space. Nothing is polled and no private API is read, which is the
    /// point: hiding must cost nothing when the option is off, and next to
    /// nothing when it is on.
    func applySpaceBehaviour() {
        guard let panel else { return }
        var behaviour: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if !DisplayStyleStore.shared.hidesInFullscreen { behaviour.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = behaviour
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300))
        let host = PassthroughHostingView(rootView: NotchRootView(model: model))
        host.interactiveRect = { [weak self] bounds in self?.interactiveRect(in: bounds) ?? .zero }
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.host = host
        self.panel = panel
        applySpaceBehaviour()
        installContextMenu()
        return panel
    }

    /// Right-click on the island opens what the menu bar icon's menu held:
    /// in the notch style that icon is hidden, and this is where its menu
    /// went. A monitor rather than a view override, because the click lands
    /// on whichever SwiftUI view is under it, not on the hosting view.
    private func installContextMenu() {
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            let shown = MainActor.assumeIsolated {
                NotchWindowController.shared.showContextMenu(for: event)
            }
            return shown ? nil : event
        }
    }

    private func showContextMenu(for event: NSEvent) -> Bool {
        guard let panel, event.window === panel, let host else { return false }
        hoverWork?.cancel()
        NSMenu.popUpContextMenu(StatusBarController.shared.makeMenu(), with: event, for: host)
        return true
    }

    /// The island's footprint, in the host's (unflipped) coordinates.
    ///
    /// Only this claims the mouse. The rest of the window is transparent and
    /// the window server hands clicks there to whatever is underneath, so the
    /// menu bar beside the notch keeps working.
    private func interactiveRect(in bounds: CGRect) -> CGRect {
        guard model.shown, let notch = model.geometry else { return .zero }
        let island = model.island(notch: notch)
        return CGRect(x: bounds.midX - island.width / 2 + island.leading,
                      y: bounds.maxY - island.height,
                      width: island.width - island.leading - island.trailing,
                      height: island.height)
    }

    // MARK: - Hover, open, close

    /// Hovering opens it all the way; leaving closes it again — unless it was
    /// opened with a click, which pins it until a click elsewhere.
    func hoverChanged(_ inside: Bool) {
        hoverWork?.cancel()
        hoverWork = nil
        if inside {
            guard model.state == .collapsed, !hoverSuppressed else { return }
            schedule(after: Self.hoverDelay) { controller in
                guard controller.model.state == .collapsed else { return }
                controller.expand(pinned: false)
            }
        } else {
            hoverSuppressed = false
            guard model.state == .expanded, !model.pinned else { return }
            schedule(after: Self.leaveDelay) { controller in
                guard !controller.model.pinned else { return }
                controller.collapse()
            }
        }
    }

    private func schedule(after delay: TimeInterval,
                          _ work: @escaping @MainActor (NotchWindowController) -> Void) {
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if let self { work(self) } }
        }
        hoverWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Set when a click closes the island with the pointer still on it, so it
    /// does not open straight back up. Cleared as the pointer leaves.
    private var hoverSuppressed = false

    /// A click on the notch row: open and pin, or close.
    func toggle() {
        if model.state == .expanded {
            collapse()
            hoverSuppressed = true
        } else {
            expand()
        }
    }

    /// Opens, on the card if one is waiting — that is almost certainly why
    /// somebody clicked — or where they last were.
    func expand(page: NotchLayout.Page? = nil, pinned: Bool = true) {
        guard isVisible || wantsVisible else { return }
        hoverWork?.cancel()
        model.pinned = pinned
        guard model.state != .expanded else {
            if let page { select(page) }
            return
        }
        model.page = page ?? NotchLayout.openingPage(hasUnreadCard: model.inbox.hasUnread,
                                                     last: model.lastPage)
        unmountWork?.cancel()
        model.pagesMounted = true
        model.state = .expanded
        if model.page == .card { model.inbox.viewed() }
        installOutsideClickMonitors()
    }

    func collapse() {
        removeOutsideClickMonitors()
        guard model.state != .collapsed else { return }
        model.pinned = false
        model.lastPage = model.page
        model.state = .collapsed
        // The pages stay in place while the island folds over them, the way
        // they were already there as it opened — then leave, so nothing in
        // them (the session list's clock, a task row) runs while it is shut.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.state != .expanded else { return }
                self.model.pagesMounted = false
            }
        }
        unmountWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.foldDuration, execute: work)
        // Somebody who browsed with Next or the show list and then closed the
        // island has stopped browsing. Left set, automatic cards would stay
        // off for good, since there is no dismiss button they will ever press.
        CardController.shared.endBrowsing()
    }

    /// A tab, or a swipe. The pages slide the way the tabs read.
    func select(_ page: NotchLayout.Page) {
        guard page != model.page else { return }
        model.forward = page.rawValue > model.page.rawValue
        withAnimation(prefersReducedMotion ? nil : Self.pageSpring) { model.page = page }
        if page == .card { model.inbox.viewed() }
    }

    func swipe(forward: Bool) {
        if let next = model.page.neighbour(forward: forward) { select(next) }
    }

    /// Opening overshoots a little — down and out, then settles — which is
    /// the pop. Closing does not: something going away should not bounce.
    static let openSpring = Animation.spring(response: 0.46, dampingFraction: 0.7)
    static let closeSpring = Animation.spring(response: 0.42, dampingFraction: 0.92)
    /// Wings folding in and out as agents come and go.
    static let foldSpring = Animation.spring(response: 0.5, dampingFraction: 0.85)
    static let foldDuration: TimeInterval = 0.6
    static let pageSpring = Animation.spring(response: 0.4, dampingFraction: 0.85)
    private var unmountWork: DispatchWorkItem?

    /// A click anywhere else closes it — in another app, on the desktop, or
    /// in one of vibeScroll's own windows.
    private func installOutsideClickMonitors() {
        guard outsideClickMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
                MainActor.assumeIsolated { NotchWindowController.shared.collapse() }
            }) {
            outsideClickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: { event in
                MainActor.assumeIsolated {
                    if event.window !== NotchWindowController.shared.panel {
                        NotchWindowController.shared.collapse()
                    }
                }
                return event
            }) {
            outsideClickMonitors.append(local)
        }
    }

    private func removeOutsideClickMonitors() {
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors.removeAll()
    }

    /// The window's content as drawn, for `vibescroll notch`.
    func snapshot() -> NSBitmapImageRep? {
        guard let host, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    // MARK: - Cards

    /// A card reached the notch.
    ///
    /// The island does not open for it. A dot appears on the quota ring (or
    /// the agent's icon) and stays until the card page is opened — somebody reading their editor
    /// gets a glance's worth of signal, not a panel.
    func cardArrived(_ card: InfoCard, automatic: Bool) {
        guard DisplayStyleStore.shared.effective == .notch else { return }
        let inFront = model.state == .expanded && model.page == .card
        model.inbox.arrived(cardID: card.id, alreadyVisible: inFront || !automatic)
    }
}

// MARK: - Model

/// What the island is doing. Kept apart from `CardController` because none of
/// it means anything to the floating face.
@MainActor
final class NotchModel: ObservableObject {
    @Published var state: NotchLayout.State = .collapsed
    @Published var page: NotchLayout.Page = .sessions
    @Published var inbox = NotchInbox()
    @Published var geometry: NotchScreen?
    /// False while the island is folding away or has not unfolded yet: the
    /// wings are tucked into the notch and nothing claims the mouse.
    @Published var shown = false
    /// Opened with a click rather than by hovering: stays open when the
    /// pointer leaves.
    var pinned = false
    /// Whether the pages exist at all. True from the moment the island starts
    /// opening until it has finished closing.
    @Published var pagesMounted = false
    /// Which way the last page change went, for the slide.
    var forward = true
    var lastPage: NotchLayout.Page = .sessions
    /// The card whose typewriter has already played. Opening the page again
    /// shows it written out, instead of typing the same text twice.
    var revealedCardID: String?

    struct Island {
        /// The frame the island is drawn in: the open width. Closed, the sides
        /// are inset from it rather than the frame shrinking.
        let width: Double
        let height: Double
        /// How much of each side is folded into the notch right now.
        let leading: Double
        let trailing: Double
    }

    /// The island as it stands, which is also the only part of the window
    /// that takes the mouse.
    func island(notch: NotchScreen) -> Island {
        let width = NotchLayout.openWidth(notchWidth: notch.notchWidth)
        let wing = NotchLayout.openOutset + NotchLayout.wing + NotchLayout.edgeInset
        let height = state == .expanded
            ? notch.notchHeight + NotchLayout.dropHeight(pageHeight: pageHeight(page))
            : notch.notchHeight
        // Hidden, both wings are inside the notch; the island is only the
        // notch's own black, which is what it slides back out of.
        guard shown else { return Island(width: width, height: height, leading: wing, trailing: wing) }
        return Island(width: width, height: height,
                      leading: NotchLayout.wingInset(state: state, hasContent: hasLeftContent),
                      trailing: NotchLayout.wingInset(state: state, hasContent: hasRightContent))
    }

    /// The session quota, when the probe has a reading.
    var quota: QuotaWindow? { NotchLayout.quotaWindow(in: UsageProbe.shared.snapshot) }

    /// The quota ring, when it belongs on screen: see `NotchLayout.showsQuota`.
    /// With nothing to show the island is just the notch, and hovering it
    /// still opens the pages.
    var showsQuota: Bool {
        NotchLayout.showsQuota(hasReading: quota != nil, agentsLive: hasRightContent,
                               keepWhenIdle: CardController.shared.showsFaceWhenIdle)
    }

    /// The left wing: the quota ring. A waiting card does not hold a wing
    /// out on its own; it is a dot on whatever is already showing.
    var hasLeftContent: Bool { showsQuota }

    /// Who the live sessions belong to, for the right wing.
    var agents: NotchLayout.AgentSummary? {
        NotchLayout.agentSummary(for: CardController.shared.sessions)
    }

    /// The right wing: an agent running or waiting.
    var hasRightContent: Bool { agents != nil }

    /// How tall a page's content wants to be. One function for the view and
    /// the click area, so the part that takes the mouse is the part you see.
    func pageHeight(_ page: NotchLayout.Page) -> Double {
        let cards = CardController.shared
        switch page {
        case .sessions:
            guard !cards.sessions.isEmpty else { return NotchLayout.minPageHeight }
            let footer = cards.quotaSummary == nil ? 0 : CardLayout.quotaFooterHeight + 6
            return Double(cards.sessions.count) * CardLayout.rowHeight + footer + Self.pageInset
        case .card:
            if cards.mode == .categories {
                let rows = max(cards.browsableCategories.count, 1)
                return CardLayout.listHeaderHeight + CardLayout.listSpacing
                    + Double(rows) * CardLayout.rowHeight + Self.pageInset
            }
            if cards.current != nil { return CardLayout.cardHeight(fitting: cards.notchCardContentHeight) }
            if cards.moment != nil { return CardLayout.momentHeight }
            return NotchLayout.minPageHeight + 24
        case .tasks:
            let count = TaskQueueStore.shared.queue.tasks.count
            guard count > 0 else { return NotchLayout.minPageHeight + 24 }
            return Double(min(count, 6)) * Self.taskRowHeight + Self.taskFooterHeight + Self.pageInset
        }
    }

    /// Vertical breathing room inside a list page.
    static let pageInset: Double = 8
    static let taskRowHeight: Double = 40
    static let taskFooterHeight: Double = 30
}

// MARK: - Window

/// Borderless, non-activating, above the menu bar, on every Space. It can
/// never become key, so clicking it never takes focus from the editor.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the menu bar, which is where the notch is.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Claims the mouse only inside the island.
///
/// `ignoresMouseEvents` is deliberately never set, not even to false: setting
/// it at all turns off the window server's per-pixel click-through for the
/// whole window, and the menu bar either side of the notch would stop
/// answering.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: (CGRect) -> CGRect = { _ in .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect(bounds).contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
