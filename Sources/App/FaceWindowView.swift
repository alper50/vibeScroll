import SwiftUI
import VibeScrollCore

/// The face as its own small thing on the desktop.
///
/// A circle of the system's own material rather than bare shapes on the
/// wallpaper: the face is five thin strokes in the accent colour, and on a
/// wallpaper near that colour it would simply disappear. The material also
/// handles light and dark for free, which a hand-picked translucent fill would
/// not.
struct FaceWindowView: View {
    @ObservedObject private var face = FaceModel.shared
    @ObservedObject private var controller = CardController.shared
    @StateObject private var blink = BlinkModel()
    @ObservedObject private var reaction = ReactionModel.shared
    @ObservedObject private var presentation = FaceWindowController.shared.presentation
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Both growths are one transform.
    ///
    /// Hover used to change the frame, which makes SwiftUI re-lay-out on every
    /// step; that was survivable alone but went visibly rough once the entrance
    /// scale animated at the same time. A `scaleEffect` is a pure transform, so
    /// nothing below it is measured again and the two can overlap freely.
    ///
    /// The window never resizes either way. Resizing it on hover is the obvious
    /// approach and it oscillates: shrinking moves the frame out from under the
    /// pointer, which ends the hover, which grows it again.
    private var scale: Double {
        let hover = hovering ? CardLayout.faceHoverSize / CardLayout.faceRestingSize : 1
        let entrance = presentation.shown ? 1.0 : 0.72
        return hover * entrance
    }

    var body: some View {
        // The label sits in a slot that is always there, empty or not. Letting
        // the stack collapse when it is hidden would move the blob every time
        // the pointer arrives, which is the one thing a hover must not do.
        VStack(spacing: 4) {
            blob.frame(width: CardLayout.faceHoverSize, height: CardLayout.faceHoverSize)
            hoverRow.frame(height: CardLayout.faceLabelHeight)
        }
        .frame(width: CardLayout.faceWindowWidth, height: CardLayout.faceWindowHeight,
               alignment: .top)
        .onAppear { blink.start() }
        .onDisappear { blink.stop() }
    }

    private var blob: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

            AnimatedFace(blink: blink, reaction: reaction, expression: face.expression)
                .padding(CardLayout.faceRestingSize * 0.16)
        }
        // Every dimension inside is fixed; only the transform moves.
        .frame(width: CardLayout.faceRestingSize, height: CardLayout.faceRestingSize)
        // Only the visible circle is a hover target and a drag handle. Scaled
        // along with the view, so the target only ever gains area.
        .contentShape(Circle())
        .scaleEffect(scale)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.72),
                   value: hovering)
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.68),
                   value: presentation.shown)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: face.expression)
    }

    /// What the face is reacting to, and the way into the session list.
    ///
    /// Both live here rather than floating over the blob: one hover affordance
    /// is easier to find than two, and text over a face is unreadable.
    @ViewBuilder
    private var hoverRow: some View {
        if hovering {
            HStack(spacing: 6) {
                if !controller.sessions.isEmpty {
                    Button { controller.showSessions() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "list.bullet")
                            Text("\(controller.sessions.count)").monospacedDigit()
                        }
                        .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Show all sessions")

                    Text("\u{00B7}").foregroundStyle(.quaternary)
                }

                Text(face.reason.summary)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: hovering)
        }
    }
}

/// Reads the blink and the reaction itself, so the view above it does not.
///
/// The material circle is the face's sibling. While `blink.amount` was read in
/// the parent's body, every frame of every blink re-ran that body and the blur
/// recomposited with it — measured at 0.85% of a core, about half of what the
/// app costs at idle, to move two capsules. Both transient animations are
/// confined here for that reason; the mood above changes rarely enough not to
/// matter.
private struct AnimatedFace: View {
    @ObservedObject var blink: BlinkModel
    @ObservedObject var reaction: ReactionModel
    var expression: FaceExpression

    var body: some View {
        FaceView(expression: reacted, blink: blink.amount)
    }

    private var reacted: FaceExpression {
        guard let impulse = reaction.impulse else { return expression }
        return expression.applying(impulse, strength: reaction.strength)
    }
}
