import SwiftUI
import VibeScrollCore

/// The card panel's content: a teaching card, or the list of every live agent
/// session. The face used to sit on top of this; it has its own window now, so
/// this panel is back to being occasional — it appears with a card and leaves
/// with it.
struct InfoCardView: View {
    @ObservedObject private var controller = CardController.shared
    @ObservedObject private var presentation = CardWindowController.shared.presentation
    @StateObject private var typewriter = TypewriterModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .frame(width: CardLayout.width,
                   height: CardLayout.panelHeight(for: controller.panelContent),
                   alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // Anchored to the bottom edge, which is the one facing the face, so
            // the card unfolds upward out of it rather than appearing whole.
            // Scale alone does the travelling: an offset would push the content
            // past the window's fixed frame and clip it on the way in.
            .scaleEffect(presentation.shown ? 1 : 0.9, anchor: .bottom)
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78),
                       value: presentation.shown)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.panelContent {
        case .none:
            EmptyView()
        case .card:
            if let card = controller.current {
                // A fresh identity per card re-fires `onAppear`, which is how
                // the typewriter restarts. `.onChange(of:)` changed signature
                // in macOS 14; this works on 13 and 14 alike.
                cardBody(card).id(card.id)
            }
        case .moment:
            if let moment = controller.moment {
                momentBody(moment)
            }
        case .sessions:
            sessionsBody
        case .categories:
            categoriesBody
        }
    }

    // MARK: - Moment mode

    /// Two lines and nothing around them.
    ///
    /// No category strip, no level, no footer: every one of those says
    /// something about a teaching card that is not true of a remark about
    /// right now. No typewriter either — the reveal is what makes a card feel
    /// worth reading, and a moment that took two seconds to type would have
    /// been quicker to just say.
    @ViewBuilder
    private func momentBody(_ moment: Moment) -> some View {
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
        .padding(.vertical, 14)
    }

    // MARK: - Card mode

    /// The live card: `CardBodyView` fed the typewriter's current text.
    ///
    /// The view itself lives on its own so the panel can be sized by laying the
    /// very same view out with the *finished* text — see `CardMeasure`. The
    /// size is decided once, before the first letter lands, so the panel never
    /// grows while the card is still writing.
    private func cardBody(_ card: InfoCard) -> some View {
        let reveal = TypewriterReveal(title: card.title, body: card.body)
        return CardBodyView(card: card, shown: reveal.text(after: typewriter.elapsed),
                            context: controller.context)
            // Clicking the card completes the reveal: some people read faster
            // than it writes, and waiting on decoration is worse than no
            // decoration.
            .contentShape(Rectangle())
            .onTapGesture { typewriter.finish() }
            .onAppear { typewriter.run(duration: reveal.duration) }
    }

    // MARK: - Sessions mode

    private var sessionsBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("SESSIONS")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    .foregroundStyle(Color.accentColor)

                Spacer()

                if controller.current != nil {
                    iconButton("chevron.left", help: "Back to card") { controller.showCard() }
                }
                    iconButton("xmark", help: "Close") { controller.dismissCard() }
            }

            if controller.sessions.isEmpty {
                Spacer()
                Text("No active agents")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // One timeline drives every row's elapsed label, so the list
                // ticks with a single redraw a second instead of one per row.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(controller.sessions) { session in
                                row(for: session, now: context.date)
                            }
                        }
                    }
                }
            }

            if let quota = controller.quotaSummary {
                quotaFooter(quota)
            }
        }
        .padding(14)
    }

    /// Quota under the list rather than on each row.
    ///
    /// One account, one allowance: four Claude sessions would otherwise each
    /// print the same 58% and read as a per-session figure, which is not a
    /// thing that exists. Absent entirely when the probe is off, which is the
    /// default — the list then looks exactly as it always has.
    @ViewBuilder
    private func quotaFooter(_ quota: QuotaSummary.Summary) -> some View {
        HStack(spacing: 5) {
            if let owner = quota.attribution {
                // Shown only when the list holds agents this reading does not
                // cover, so one figure cannot look like it covers all of them.
                Text(owner)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(quota.windows.enumerated()), id: \.offset) { index, window in
                if index > 0 || quota.attribution != nil {
                    Text(verbatim: "\u{00B7}").foregroundStyle(.quaternary).font(.system(size: 10))
                }
                Text(window.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("\(window.percentUsed)%")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(color(for: window))
            }

            Spacer(minLength: 4)

            if quota.untrackedCount > 0 {
                // The other agents write no quota we can read. Said as a count
                // rather than left blank, so a missing figure reads as "not
                // measured" instead of "nothing spent".
                Text("\(quota.untrackedCount) untracked")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .fixedSize()
            }
        }
        .lineLimit(1)
        .frame(height: CardLayout.quotaFooterHeight, alignment: .leading)
    }

    /// Severity comes from the provider, so no threshold is invented here —
    /// except exhaustion, which is keyed off the percentage for the same reason
    /// it is everywhere else: it cannot drift when a label is renamed.
    private func color(for window: QuotaSummary.Window) -> Color {
        if window.isExhausted { return .red }
        switch window.severity {
        case .critical: return .red
        case .warning:  return .orange
        case .normal:   return .secondary
        case .unknown:  return .secondary
        }
    }

    // MARK: - Show picker

    /// Built like the session list rather than as a pop-up menu.
    ///
    /// The panel is a `.nonactivatingPanel` — it must never take focus from the
    /// terminal you are typing in — and a menu that opens outside the bounds of
    /// a window that cannot become key is a fight with AppKit for no gain. The
    /// panel already knows how to be a list and how to resize to one, so this
    /// is the same move the sessions button makes.
    @ViewBuilder
    private var categoriesBody: some View {
        let topics = controller.browsableCategories
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("SHOWS")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    .foregroundStyle(Color.accentColor)

                Spacer()

                if controller.hasCardBehind {
                    iconButton("chevron.left", help: "Back to card") { controller.showCard() }
                }
                iconButton("xmark", help: "Close") { controller.dismissCard() }
            }

            if topics.isEmpty {
                Spacer()
                Text("No cards yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(topics, id: \.category) { topic in
                            categoryRow(topic.category, count: topic.count)
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func categoryRow(_ category: CardCategory, count: Int) -> some View {
        // The show the visible card came from, not whatever the agent is on:
        // this list sits in front of a card, and marking a different row would
        // be pointing at something the user cannot see.
        let isCurrent = controller.current?.category == category
        return Button { controller.showCategory(category) } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isCurrent ? Color.accentColor : Color.clear)
                    .frame(width: 6, height: 6)

                Text(verbatim: category.label)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(verbatim: "\(count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)
            .frame(height: CardLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(for session: AgentSession, now: Date) -> some View {
        let clickable = SessionFocus.canFocus(session)
        return HStack(spacing: 6) {
            Circle()
                .fill(color(for: session.state))
                .frame(width: 6, height: 6)

            Text(TickerFormatter.agentLabel(for: session.agentKind))
                .font(.system(size: 11, weight: .medium))
                .fixedSize()

            if let project = session.project {
                Text(verbatim: "\u{00B7}").foregroundStyle(.quaternary).font(.system(size: 11))
                Text(ProjectPath.displayName(project))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            // Only Claude and Codex expose a readable transcript, so most rows
            // have no count at all. Shown only once there is something to show:
            // a fresh session reading "0" would look like a stalled one.
            if let tokens = session.tokens, tokens > 0 {
                Text(TickerFormatter.tokens(tokens))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Text(verbatim: "\u{00B7}")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }

            Text(TickerFormatter.elapsed(since: session.stateSince, now: now))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .fixedSize()

            // Only shown when the click can actually land somewhere, so the
            // list never advertises an action it cannot perform.
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .opacity(clickable ? 1 : 0)
        }
        .frame(height: CardLayout.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { if clickable { controller.focus(session) } }
        .help(clickable ? "Open this session's window" : "")
    }

    private func color(for state: AgentState) -> Color {
        switch state {
        case .working:    return .accentColor
        case .waiting:    return .orange
        case .done:       return .green
        case .registered: return .secondary
        case .idle:       return .gray.opacity(0.5)
        }
    }
}

// MARK: - Card body

/// A card, laid out: header, title, body, footer.
///
/// Plain inputs and no state of its own, so it can be drawn twice — once on
/// screen with the typewriter's partial text, and once off screen with the
/// finished text, to find out how tall the panel has to be. One layout, used
/// for both, is what keeps the measurement honest: a second copy of these
/// fonts and paddings would drift the first time either was touched.
struct CardBodyView: View {
    let card: InfoCard
    let shown: TypewriterReveal.Revealed
    let context: [AgentSession]

    private var controller: CardController { CardController.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Text(shown.title + caret(on: .title))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(shown.body + caret(on: .body))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)

            // Zero at its minimum, so a measurement sees the text and nothing
            // else; on screen the panel already fits, and this only absorbs
            // rounding.
            Spacer(minLength: 0)

            footer
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 6) {
            // The badge was a label for as long as there was nothing else to
            // look at. It is the one piece of chrome already naming a topic, so
            // it is the obvious place to ask for a different one.
            Button { controller.showCategories() } label: {
                HStack(spacing: 3) {
                    Text(verbatim: card.category.label.uppercased())
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .opacity(0.7)
                }
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                .foregroundStyle(Color.accentColor)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Browse another show")

            Spacer()

            iconButton("xmark", help: "Dismiss card") { controller.dismissCard() }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let session = context.first {
                Text(contextLine(for: session))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let source = card.source {
                Text(source)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let link = card.link {
                Link(destination: link) {
                    Text("Read more").font(.system(size: 10, weight: .medium))
                }
            }

            // Hidden until the card has finished writing — offering "next"
            // mid-sentence invites skipping past text that hasn't arrived.
            // Held in the layout rather than removed from it, so the footer
            // doesn't jump at the moment the reveal completes.
            Button {
                controller.showNext()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("Next card")
            .opacity(shown.isComplete ? 1 : 0)
            .disabled(!shown.isComplete)
        }
    }

    private enum Field { case title, body }

    /// The caret follows the write head: it sits on the title until the first
    /// body character lands, then moves down with the text.
    private func caret(on field: Field) -> String {
        guard !shown.isComplete else { return "" }
        let caret = "\u{258D}"
        switch field {
        case .title: return shown.body.isEmpty ? caret : ""
        case .body:  return shown.body.isEmpty ? "" : caret
        }
    }

    /// "Claude · vibeScroll · Running git status" — enough to see why this card
    /// appeared without opening anything.
    private func contextLine(for session: AgentSession) -> String {
        var parts = [TickerFormatter.agentLabel(for: session.agentKind)]
        if let project = session.project { parts.append(ProjectPath.displayName(project)) }
        if let message = session.message, !message.isEmpty { parts.append(message) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Measuring

/// How tall a card's content is, found by laying `CardBodyView` out off
/// screen with the finished text.
///
/// Measured rather than estimated from character counts: the same 160
/// characters wrap to three lines or four depending on the words, the font and
/// the language, and a panel sized from a guess is either clipped or half
/// empty. A hosting view per card is cheap next to what it replaces — this runs
/// once when a card arrives, not per frame.
@MainActor
enum CardMeasure {
    static func contentHeight(of card: InfoCard, context: [AgentSession]) -> Double {
        let finished = TypewriterReveal.Revealed(title: card.title, body: card.body,
                                                 isComplete: true)
        let host = NSHostingView(rootView:
            CardBodyView(card: card, shown: finished, context: context)
                .frame(width: CardLayout.width))
        return Double(host.fittingSize.height)
    }
}

// MARK: - Shared

func iconButton(
    _ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
    }
    .buttonStyle(.plain)
    .help(help)
}
