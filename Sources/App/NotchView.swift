import SwiftUI
import VibeScrollCore

/// Pins the island to the top of its fixed window, centred on the notch.
struct NotchRootView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(spacing: 0) {
            if let notch = model.geometry {
                NotchIslandView(model: model, notch: notch)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Black glass, whatever the system appearance: semantic colours then
        // resolve light-on-dark, so the shared rows and the card read here
        // without a second copy of any of them.
        .environment(\.colorScheme, .dark)
    }
}

/// The black island around the notch.
///
/// Closed, it is the notch plus a wing either side: the session quota on the
/// left, the running agents on the right. A wing with nothing to show folds
/// into the notch. Hovering opens it into three pages; so does a click, which
/// also keeps it open. Only its shape moves — the window never resizes.
///
/// Cheap by construction. Black is a fill, not a material; the closed island
/// has no clock of its own and redraws only when the quota or the agents
/// change; nothing inside the open pages exists while it is closed.
struct NotchIslandView: View {
    @ObservedObject var model: NotchModel
    let notch: NotchScreen

    @ObservedObject private var cards = CardController.shared
    @ObservedObject private var usage = UsageProbe.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var controller: NotchWindowController { .shared }
    private var top: Double { notch.notchHeight }

    /// The frame: the open island. Closed, the shape is inset from it.
    private var width: Double { NotchLayout.openWidth(notchWidth: notch.notchWidth) }

    var body: some View {
        let island = model.island(notch: notch)
        let expanded = model.state == .expanded
        let shape = NotchShape(topRadius: 8,
                               bottomRadius: expanded ? 22 : max(10, top * 0.4),
                               leading: island.leading, trailing: island.trailing)
        return ZStack(alignment: .top) {
            shape.fill(Color.black)
            VStack(spacing: 0) {
                notchRow
                    .frame(width: NotchLayout.islandWidth(notchWidth: notch.notchWidth), height: top)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.toggle() }
                // Laid out at full size the whole time they exist and simply
                // uncovered as the island grows over them — a curtain rather
                // than a fade-in, which is what makes it read as the notch
                // opening instead of a panel appearing inside it.
                if model.pagesMounted {
                    NotchPagesView(model: model, width: NotchLayout.contentWidth(notchWidth: notch.notchWidth))
                        .opacity(expanded ? 1 : 0)
                        // Settles into place with the island's overshoot
                        // rather than sitting dead still inside a moving shape.
                        .scaleEffect(expanded ? 1 : 0.94, anchor: .top)
                        .allowsHitTesting(expanded)
                        .frame(width: width, alignment: .top)
                }
            }
        }
        .frame(width: width, height: island.height, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .onHover { controller.hoverChanged($0) }
        // Into the notch when hidden: up and out, as it came.
        .offset(y: model.shown ? 0 : -island.height)
        .animation(reduceMotion ? nil : (expanded ? NotchWindowController.openSpring
                                                 : NotchWindowController.closeSpring),
                   value: model.state)
        .animation(reduceMotion ? nil : NotchWindowController.foldSpring, value: model.hasLeftContent)
        .animation(reduceMotion ? nil : NotchWindowController.foldSpring, value: model.hasRightContent)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: model.shown)
        .animation(reduceMotion ? nil : NotchWindowController.pageSpring, value: model.page)
    }

    // MARK: - Closed

    /// Each wing is a fixed slot, whatever is in it. An empty view given a
    /// frame takes no room in a stack, so a wing with nothing to show used to
    /// vanish from the row and the other slid half a wing towards the middle —
    /// straight behind the camera.
    private func wingSlot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Color.clear
            content()
        }
        .frame(width: NotchLayout.wing, height: top)
    }

    private var notchRow: some View {
        HStack(spacing: 0) {
            wingSlot { quota }
                // Each side fades with its wing rather than being cut by it.
                .opacity(model.hasLeftContent || model.state == .expanded ? 1 : 0)

            Color.clear.frame(width: notch.notchWidth, height: top)

            wingSlot { agents }
                .opacity(model.hasRightContent || model.state == .expanded ? 1 : 0)
        }
        .padding(.horizontal, NotchLayout.edgeInset)
    }

    /// The session quota as a ring with the number inside, and a dot on it
    /// while a card is waiting to be read.
    @ViewBuilder
    private var quota: some View {
        ZStack(alignment: .topTrailing) {
            if model.showsQuota, let window = model.quota {
                QuotaRing(window: window)
                    .frame(width: 26, height: 26)
                    .help(Text(verbatim: "\(window.label) \(window.percentUsed)%"))
                unreadDot(on: model.inbox.hasUnread)
            }
        }
    }

    /// A waiting card, marked on whatever is already there — never a mark of
    /// its own, which would keep a wing out just to say "there is a card" on
    /// an island that is otherwise idle. The card tab in the open island
    /// carries the same dot.
    @ViewBuilder
    private func unreadDot(on: Bool) -> some View {
        if on {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
                .offset(x: 2, y: -1)
                .transition(.scale.combined(with: .opacity))
        }
    }

    /// The agent with the most live sessions — its own app icon when it is
    /// installed, its name when not — and how many sessions are live in
    /// all. The number turns orange while any of them is waiting for you.
    @ViewBuilder
    private var agents: some View {
        if let summary = model.agents {
            HStack(spacing: 4) {
                if let icon = AgentIcon.image(for: summary.leader) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                        // No ring to carry the card's dot: it rides here.
                        .overlay(alignment: .topTrailing) {
                            unreadDot(on: model.inbox.hasUnread && !model.showsQuota)
                        }
                } else {
                    Text(verbatim: TickerFormatter.agentLabel(for: summary.leader))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(verbatim: "\(summary.active)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(summary.waiting > 0 ? Color.orange : .white)
            }
            .help(Text(verbatim: summary.breakdown
                .map { "\(TickerFormatter.agentLabel(for: $0.kind)) \($0.count)" }
                .joined(separator: " \u{00B7} ")))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: summary.leader)
        }
    }
}

/// A usage ring with the percentage written inside it.
///
/// Coloured by the provider's own severity, the way the session list colours
/// the same figure — no threshold is invented here — and red at 100% whatever
/// the provider says, since exhaustion means the same thing everywhere.
struct QuotaRing: View {
    let window: QuotaWindow

    private var fraction: Double { min(max(Double(window.percentUsed) / 100, 0), 1) }

    private var colour: Color {
        if window.isExhausted { return .red }
        switch window.severity {
        case .critical: return .red
        case .warning:  return .orange
        case .normal, .unknown: return .white
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(colour, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            (Text(verbatim: "\(window.percentUsed)")
                .font(.system(size: window.percentUsed >= 100 ? 7.5 : 8.5, weight: .bold, design: .rounded))
             + Text(verbatim: "%")
                .font(.system(size: 6, weight: .bold, design: .rounded)))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .animation(.easeInOut(duration: 0.3), value: window.percentUsed)
    }
}

// MARK: - Open

/// The three pages under the tab row.
///
/// One page at a time, sliding in the direction the tabs read — dragging
/// sideways does the same. Only the visible page exists, so the card's
/// typewriter starts when the card is actually looked at.
struct NotchPagesView: View {
    @ObservedObject var model: NotchModel
    let width: Double
    @ObservedObject private var cards = CardController.shared
    @ObservedObject private var tasks = TaskQueueStore.shared

    var body: some View {
        VStack(spacing: 0) {
            tabs.frame(width: width, height: NotchLayout.tabBarHeight)
            ZStack(alignment: .top) {
                page
                    .frame(width: width, height: pageHeight, alignment: .top)
                    .id(model.page)
                    .transition(slide)
            }
            .frame(width: width, height: pageHeight, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        if value.translation.width < -40 { NotchWindowController.shared.swipe(forward: true) }
                        else if value.translation.width > 40 { NotchWindowController.shared.swipe(forward: false) }
                    }
            )
        }
    }

    private var pageHeight: Double {
        NotchLayout.clampedPageHeight(model.pageHeight(model.page))
    }

    private var slide: AnyTransition {
        let forward = model.forward
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            tab(.sessions, title: String(localized: "Sessions"),
                badge: cards.sessions.isEmpty ? nil : "\(cards.sessions.count)")
            tab(.card, title: String(localized: "Card"), dot: model.inbox.hasUnread)
            tab(.tasks, title: String(localized: "Tasks"),
                badge: pendingTasks > 0 ? "\(pendingTasks)" : nil)
            Spacer(minLength: 2)
            Button {
                NotchWindowController.shared.collapse()
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings \u{2014} right-click the notch for the rest of the menu")
        }
    }

    private var pendingTasks: Int {
        tasks.queue.tasks.filter { $0.status == .pending || $0.status == .running }.count
    }

    private func tab(_ page: NotchLayout.Page, title: String,
                     badge: String? = nil, dot: Bool = false) -> some View {
        let selected = model.page == page
        return Button { NotchWindowController.shared.select(page) } label: {
            HStack(spacing: 4) {
                Text(verbatim: title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                if let badge {
                    Text(verbatim: badge)
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .opacity(0.6)
                }
                if dot {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.12 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .sessions:
            SessionListView(onFocus: { NotchWindowController.shared.collapse() })
                .padding(.horizontal, 8)
                .padding(.vertical, NotchModel.pageInset / 2)
        case .card:
            NotchCardPage(model: model)
        case .tasks:
            NotchTasksPage()
        }
    }
}

/// The card, the show list, the moment, or an invitation to pick a show.
struct NotchCardPage: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var cards = CardController.shared
    @StateObject private var typewriter = TypewriterModel()

    var body: some View {
        if cards.mode == .categories {
            VStack(alignment: .leading, spacing: CardLayout.listSpacing) {
                HStack(spacing: 6) {
                    Text("SHOWS")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    if cards.hasCardBehind {
                        iconButton("chevron.left", help: "Back to card") { cards.showCard() }
                    }
                }
                .frame(height: CardLayout.listHeaderHeight)
                CategoryListView()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, NotchModel.pageInset / 2)
        } else if let card = cards.current {
            cardBody(card).id(card.id)
        } else if let moment = cards.moment {
            VStack(alignment: .leading, spacing: 5) {
                Text(moment.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(moment.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        } else {
            VStack(spacing: 8) {
                Text("No card right now")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Pick a show") { cards.showCategories() }
                    .controlSize(.small)
                    .disabled(cards.browsableCategories.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The same card view the floating panel draws, typed out once. Coming
    /// back to a card already read shows it whole.
    private func cardBody(_ card: InfoCard) -> some View {
        let reveal = TypewriterReveal(title: card.title, body: card.body)
        return CardBodyView(card: card, shown: reveal.text(after: typewriter.elapsed),
                            context: cards.context)
            .contentShape(Rectangle())
            .onTapGesture { typewriter.finish() }
            .onAppear {
                if model.revealedCardID == card.id {
                    // A fresh page has a fresh typewriter that has never been
                    // told how long this card is; `finish` alone would land it
                    // at zero and show nothing but the caret.
                    typewriter.run(duration: reveal.duration)
                    typewriter.finish()
                } else {
                    model.revealedCardID = card.id
                    typewriter.run(duration: reveal.duration)
                }
            }
    }
}

/// The queue at a glance: the same rows as Settings → Tasks, folded, with
/// the gate's reason under them and the way to the full list.
struct NotchTasksPage: View {
    @ObservedObject private var store = TaskQueueStore.shared
    @ObservedObject private var runner = TaskRunner.shared

    var body: some View {
        let tasks = store.queue.tasks.sorted { $0.order < $1.order }
        VStack(alignment: .leading, spacing: 4) {
            if tasks.isEmpty {
                VStack(spacing: 8) {
                    Text("No tasks yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Add a task\u{2026}") { openTasks() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tasks) { task in
                            TaskRowView(task: task, queue: store.queue) { EmptyView() }
                        }
                    }
                }
                HStack(spacing: 6) {
                    if runner.autopilot {
                        Text(verbatim: runner.currentDecision().summary)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button("All tasks\u{2026}") { openTasks() }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
                .frame(height: NotchModel.taskFooterHeight - 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, NotchModel.pageInset / 2)
    }

    private func openTasks() {
        NotchWindowController.shared.collapse()
        SettingsWindowController.shared.show(tab: .tasks)
    }
}

// MARK: - Shape

/// The notch's silhouette: flush with the top edge, with small concave flares
/// where it meets the menu bar and rounder corners underneath. Animating the
/// two radii is what makes opening read as the notch itself growing.
///
/// The flared-top approach follows claude-notch-tracker and pookify (both MIT).
struct NotchShape: Shape {
    var topRadius: Double
    var bottomRadius: Double
    /// How far each side is folded in from the frame's edge. The island is
    /// drawn in a frame of constant width, and a wing tucks away by insetting
    /// its side rather than resizing the frame — so it animates as the same
    /// shape shrinking, and nothing inside has to be laid out again.
    var leading: Double = 0
    var trailing: Double = 0

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), AnimatablePair(leading, trailing)) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            leading = newValue.second.first
            trailing = newValue.second.second
        }
    }

    func path(in frame: CGRect) -> Path {
        let rect = CGRect(x: frame.minX + leading, y: frame.minY,
                          width: max(0, frame.width - leading - trailing), height: frame.height)
        let t = max(0, min(topRadius, rect.height / 2))
        let b = max(0, min(bottomRadius, rect.width / 2 - t, rect.height - t))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                          control: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                          control: CGPoint(x: rect.minX + t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                          control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
