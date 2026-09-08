import SwiftUI
import VibeScrollCore

/// The card panel's content: a teaching card, or the list of every live agent
/// session. The face used to sit on top of this; it has its own window now, so
/// this panel is back to being occasional — it appears with a card and leaves
/// with it.
struct InfoCardView: View {
    @ObservedObject private var controller = CardController.shared
    @StateObject private var typewriter = TypewriterModel()

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
        case .sessions:
            sessionsBody
        }
    }

    // MARK: - Card mode

    @ViewBuilder
    private func cardBody(_ card: InfoCard) -> some View {
        let reveal = TypewriterReveal(title: card.title, body: card.body)
        let shown = reveal.text(after: typewriter.elapsed)

        VStack(alignment: .leading, spacing: 8) {
            cardHeader(card)

            Text(shown.title + caret(on: .title, shown))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(shown.body + caret(on: .body, shown))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            cardFooter(card, isComplete: shown.isComplete)
        }
        .padding(14)
        // Clicking the card completes the reveal: some people read faster than
        // it writes, and waiting on decoration is worse than no decoration.
        .contentShape(Rectangle())
        .onTapGesture { typewriter.finish() }
        .onAppear { typewriter.run(duration: reveal.duration) }
    }

    private func cardHeader(_ card: InfoCard) -> some View {
        HStack(spacing: 6) {
            Text(card.category.fallbackLabel.uppercased())
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                .foregroundStyle(Color.accentColor)

            Text(card.level.rawValue)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)

            Spacer()

            iconButton("xmark", help: "Dismiss card") { controller.dismissCard() }
        }
    }

    @ViewBuilder
    private func cardFooter(_ card: InfoCard, isComplete: Bool) -> some View {
        HStack(spacing: 6) {
            if let session = controller.context.first {
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
            .opacity(isComplete ? 1 : 0)
            .disabled(!isComplete)
        }
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
        }
        .padding(14)
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
                Text("\u{00B7}").foregroundStyle(.quaternary).font(.system(size: 11))
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
                Text("\u{00B7}")
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

    // MARK: - Shared

    private func iconButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private enum Field { case title, body }

    /// The caret follows the write head: it sits on the title until the first
    /// body character lands, then moves down with the text.
    private func caret(on field: Field, _ shown: TypewriterReveal.Revealed) -> String {
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
