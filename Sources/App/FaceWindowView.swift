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
    @ObservedObject private var blink = BlinkModel.shared
    @ObservedObject private var reaction = ReactionModel.shared
    @ObservedObject private var presentation = FaceWindowController.shared.presentation
    @State private var hovering = false
    /// Distinguishes a click from a drag. A `DragGesture` reports cumulative
    /// translation, so the last one is kept to move by the difference rather
    /// than by the total each time.
    @State private var dragging = false
    /// Whether the pointer is currently down on the face. The grab offset the
    /// drag works from is taken once, on the first event of the press.
    @State private var grabbed = false
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
            blob.frame(width: CardLayout.faceSlot, height: CardLayout.faceSlot)
            hoverRow.frame(height: CardLayout.faceLabelHeight)
        }
        .frame(width: CardLayout.faceWindowWidth, height: CardLayout.faceWindowHeight,
               alignment: .top)
        // Both stop with the window. A face nobody can see has no reason to
        // keep a timer alive, which is the whole reason either of these is
        // affordable — they sleep for seconds and animate for milliseconds.
        .onAppear { blink.start(); GazeModel.shared.startIdleMotion() }
        .onDisappear { blink.stop(); GazeModel.shared.stopIdleMotion() }
    }

    private var blob: some View {
        ZStack {
            orb

            // `GazeModel.shared` is handed over rather than observed here.
            // A pointer crossing the circle publishes on every mouse-move
            // event, and this body draws the material orb; observing it up
            // here would re-blur that orb all the way across.
            AnimatedFace(blink: blink, reaction: reaction, gaze: GazeModel.shared,
                         expression: face.expression)
                .padding(CardLayout.faceRestingSize * 0.16)
        }
        // Every dimension inside is fixed; only the transform moves.
        .frame(width: CardLayout.faceRestingSize, height: CardLayout.faceRestingSize)
        // Only the visible circle is a hover target and a drag handle. Scaled
        // along with the view, so the target only ever gains area.
        .contentShape(Circle())
        .scaleEffect(scale)
        .onHover { hovering = $0; hovering ? GazeModel.shared.beginTracking()
                                             : GazeModel.shared.rest() }
        .gesture(clickOrDrag)
        .help("Click to show or hide all sessions, drag to move")
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.72),
                   value: hovering)
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.68),
                   value: presentation.shown)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: face.expression)
    }

    /// The material disc, lit like a sphere.
    ///
    /// Flat it read as a sticker. The depth is entirely lighting — a highlight
    /// up and left, shade falling away to the lower right, and a rim that is
    /// bright on top and dark underneath. No gloss and no bevel: the point is
    /// for it to stop looking cut out, not to look like a button.
    ///
    /// White and black at low opacity rather than semantic colours, because
    /// this is light rather than content: the same overlay reads correctly on
    /// a light material and a dark one, which a hand-picked pair would not.
    ///
    /// All of it is static. Gradients are composited once and cached; the
    /// breathing animation that cost 10.7% of a core was expensive because it
    /// never stopped, not because it was drawing.
    private var orb: some View {
        let size = CardLayout.faceRestingSize
        return ZStack {
            // Under it, and only under it. The symmetric drop shadow this
            // replaces spread evenly in every direction, which is the shadow of
            // something floating; a sphere sitting in a light has its darkest
            // shadow directly beneath.
            Ellipse()
                .fill(RadialGradient(
                    colors: [Color.black.opacity(0.26), Color.black.opacity(0)],
                    center: .center, startRadius: 0, endRadius: size * 0.30))
                .frame(width: size * 0.80, height: size * 0.24)
                .offset(y: size * 0.46)

            Circle()
                .fill(.regularMaterial)
                .overlay {
                    // The key light, with a real terminator. Four stops rather
                    // than three: the previous pair ran white straight into
                    // black across the whole radius, which shades a disc
                    // evenly. A sphere holds its light over the near half and
                    // then falls away quickly, and where it falls away is the
                    // line that makes it read as round.
                    Circle().fill(
                        RadialGradient(
                            stops: [
                                .init(color: .white.opacity(0.30), location: 0),
                                .init(color: .white.opacity(0.06), location: 0.42),
                                .init(color: .black.opacity(0.10), location: 0.78),
                                .init(color: .black.opacity(0.26), location: 1),
                            ],
                            center: UnitPoint(x: 0.32, y: 0.26),
                            startRadius: 0,
                            endRadius: size * 0.85))
                }
                .overlay {
                    // Bounce. The cue the old shading had no notion of: a real
                    // sphere's shadow side is lifted by light coming back off
                    // whatever it is sitting on, and without it the dark half
                    // just looks like paint.
                    Circle().fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.16), Color.white.opacity(0)],
                            center: UnitPoint(x: 0.72, y: 0.80),
                            startRadius: 0,
                            endRadius: size * 0.55))
                }
                .overlay(alignment: .topLeading) {
                    // The specular. A radial fill rather than a blurred
                    // ellipse: soft edges without paying for a filter pass.
                    // Smaller and harder than it was — the old one was wide and
                    // faint enough to read as a glow rather than as a gloss.
                    Ellipse()
                        .fill(RadialGradient(
                            stops: [
                                .init(color: .white.opacity(0.55), location: 0),
                                .init(color: .white.opacity(0.12), location: 0.55),
                                .init(color: .white.opacity(0), location: 1),
                            ],
                            center: .center, startRadius: 0, endRadius: size * 0.12))
                        .frame(width: size * 0.30, height: size * 0.21)
                        .rotationEffect(.degrees(-20))
                        .offset(x: size * 0.09, y: size * 0.06)
                }
                .overlay {
                    // Bright where the key grazes the edge, dark through the
                    // middle, bright again at the bottom right where the bounce
                    // comes back. The old rim was a plain top-to-bottom fade,
                    // which is how you light a disc, not a ball.
                    Circle().strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.55), location: 0),
                                .init(color: .black.opacity(0.14), location: 0.38),
                                .init(color: .black.opacity(0.10), location: 0.72),
                                .init(color: .white.opacity(0.30), location: 1),
                            ],
                            startPoint: UnitPoint(x: 0.15, y: 0),
                            endPoint: UnitPoint(x: 0.85, y: 1)),
                        lineWidth: 1.1)
                }
                // Kept, and quieter than it was: the contact shadow grounds it,
                // this only separates the edge from a busy wallpaper.
                .shadow(color: .black.opacity(0.12), radius: size * 0.05, y: size * 0.02)
        }
    }

    /// Click opens the session list; a drag moves the window.
    ///
    /// Both are on the face itself. The list used to be reached through a
    /// button under it, which could not be clicked: moving the pointer down to
    /// the button left the circle, `hovering` went false, and the row vanished
    /// before anyone got there. A control that only exists while you are not
    /// looking at it is not a control.
    ///
    /// Three points of slack, so a click with a shaky hand is still a click.
    /// The distance is measured on screen rather than from the gesture, which
    /// reads near zero once the window starts following the pointer — see
    /// `FaceWindowController.dragGrab`.
    private var clickOrDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !grabbed {
                    grabbed = true
                    FaceWindowController.shared.beginDrag()
                }
                if !dragging, FaceWindowController.shared.dragDistance > 3 {
                    dragging = true
                }
                if dragging { FaceWindowController.shared.dragToPointer() }
            }
            .onEnded { _ in
                // Either way the face has been handled, which is the same
                // thing to a sleeping face as an agent doing something.
                FaceModel.shared.wake()
                if dragging {
                    FaceWindowController.shared.persistOrigin()
                } else {
                    ReactionModel.shared.noteClick()
                    controller.toggleSessions()
                }
                dragging = false
                grabbed = false
            }
    }

    /// What the face is reacting to. Read while hovering the circle, so it
    /// never has to be reached for.
    @ViewBuilder
    private var hoverRow: some View {
        if hovering {
            HStack(spacing: 6) {
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
    @ObservedObject var gaze: GazeModel
    var expression: FaceExpression

    // A slow breathing scale was tried here and measured at 10.7% of a core —
    // twelve times the whole app. Any *continuous* animation sits on top of the
    // material circle and re-blurs it on every frame, which is the same cost
    // that made the blink expensive, except a breath never stops. A sleeping
    // face is still instead, and free.

    var body: some View {
        FaceView(expression: reacted, blink: blink.amount, gaze: gaze.direction)
    }

    private var reacted: FaceExpression {
        guard let impulse = reaction.impulse else { return expression }
        return expression.applying(impulse, strength: reaction.strength)
    }
}
