import AppKit
import SwiftUI
import VibeScrollCore

/// Draws a `FaceExpression`.
///
/// Features on the panel's own material rather than a head with a border: this
/// is an ambient status surface, and vibeScroll deliberately left AgentPet's
/// pet sprites behind. Everything is a plain SwiftUI shape, so there is no
/// asset to license — the same trap the sound work had to walk around twice.
///
/// Each element is driven by exactly one field of the expression. That is what
/// keeps the drawing debuggable: if the face looks wrong, one number is wrong,
/// and the preview (`vibescroll face`) shows which.
struct FaceView: View {
    var expression: FaceExpression
    /// 0 open … 1 fully shut. Kept out of the expression because a blink is not
    /// a change of mood; it multiplies into the lids at drawing time.
    var blink: Double = 0

    /// Design canvas. Everything is expressed against this and scaled once, so
    /// the same face works in a 110pt strip and in the preview at 3×.
    static let designSize = CGSize(width: 96, height: 72)

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / Self.designSize.width,
                            geometry.size.height / Self.designSize.height)
            ZStack {
                brow(side: -1)
                brow(side: 1)
                eye(side: -1)
                eye(side: 1)
                mouth
            }
            .frame(width: Self.designSize.width, height: Self.designSize.height)
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .foregroundStyle(tint)
    }

    // MARK: - Colour

    /// Calm reads in the accent colour; strain warms it. Colour carries the
    /// tension rather than adding a glyph for it, so the face stays five shapes
    /// and cannot drift into a cartoon.
    private var tint: Color {
        let base = NSColor.controlAccentColor
        let warm = NSColor.systemOrange
        let blended = base.blended(withFraction: expression.strain, of: warm) ?? base
        return Color(nsColor: blended)
    }

    // MARK: - Eyes

    private static let eyeOffsetX: CGFloat = 19
    private static let eyeCentreY: CGFloat = -5
    private static let eyeWidth: CGFloat = 16
    private static let eyeHeight: CGFloat = 22

    /// The frame is fixed and the shape draws inside it, rather than the frame
    /// shrinking as the eye closes. Nothing is re-laid-out on a blink, and the
    /// corners stay put — an eye whose corners move is a shape changing size,
    /// not a lid coming down.
    private func eye(side: CGFloat) -> some View {
        EyeShape(openness: expression.eyeOpenness * (1 - min(max(blink, 0), 1)))
            .frame(width: Self.eyeWidth, height: Self.eyeHeight)
            .offset(x: side * Self.eyeOffsetX, y: Self.eyeCentreY)
    }

    // MARK: - Brows

    private static let browWidth: CGFloat = 18
    private static let browHeight: CGFloat = 5
    private static let browRestY: CGFloat = -22

    /// One axis carries both height and tilt, because they move together on a
    /// real face: raised brows are high and *level*, a furrowed pair is low
    /// with the inner ends pulled down.
    private func brow(side: CGFloat) -> some View {
        let angle = expression.browAngle
        // Negative y is up, so a positive angle lifts. Skew lifts one and drops
        // the other: `side` is +1 on the right, which is the one a positive
        // skew raises.
        let lift = -angle * 7 - expression.browSkew * side * 6
        // Tilt only ever furrows. Rotating in the positive direction too would
        // raise the inner ends, which is the sad brow, not the alert one — the
        // two are opposite expressions and only one of them belongs on a face
        // that is paying attention.
        let tilt = Angle.degrees(min(angle, 0) * 15 * side)
        // `side` is -1 on the left of the face, where the inner end is the
        // right one. The shape mirrors itself rather than being flipped by a
        // transform, which would also invert the rotation above.
        return BrowShape(thickEndLeading: side > 0)
            .frame(width: Self.browWidth, height: Self.browHeight)
            .rotationEffect(tilt)
            .offset(x: side * Self.eyeOffsetX, y: Self.browRestY + lift)
    }

    // MARK: - Mouth

    private static let mouthWidth: CGFloat = 38
    private static let mouthHeight: CGFloat = 18
    private static let mouthY: CGFloat = 22

    @ViewBuilder
    private var mouth: some View {
        // The tongue is drawn first so the mouth's own outline sits over it,
        // which is what makes it read as coming from inside rather than being
        // stuck on the chin.
        if expression.tongue > 0.01 {
            TongueShape()
                .opacity(0.85)
                .frame(width: Self.mouthWidth * 0.40,
                       height: Self.mouthHeight * 0.85 * expression.tongue)
                .offset(y: Self.mouthY + Self.mouthHeight * 0.34)
        }
        MouthShape(curve: expression.mouthCurve, open: expression.mouthOpen)
            .frame(width: Self.mouthWidth, height: Self.mouthHeight)
            .offset(y: Self.mouthY)
    }
}

/// An eye, drawn as two arcs meeting at the corners.
///
/// A capsule was the obvious shape and it reads as a pill: flat-sided, blunt,
/// symmetrical. A real eye tapers to points at the corners, and its upper lid
/// travels much further than its lower one — so the two arcs are given
/// different depths, and closing moves mostly the top. Shrinking both equally
/// looks like an aperture rather than a blink.
struct EyeShape: Shape {
    var openness: Double

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let open = min(max(openness, 0), 1)
        let middle = rect.midY
        // Deep enough that a fully open eye is taller than it is wide. The
        // first pass used shallow arcs meeting at sharp points, which reads as
        // a long narrow lens rather than an eye — roundness is what fixes it,
        // not the tilt, because there is none.
        let upper = rect.height * 0.60 * open
        let lower = rect.height * 0.34 * open
        // A shut eye is a line, and a line still has to be drawn or the face
        // loses half its features every time it blinks.
        let closed = rect.height * 0.055

        var path = Path()
        let inner = CGPoint(x: rect.minX, y: middle)
        let outer = CGPoint(x: rect.maxX, y: middle)
        path.move(to: inner)
        path.addQuadCurve(to: outer, control: CGPoint(x: rect.midX, y: middle - upper - closed))
        path.addQuadCurve(to: inner, control: CGPoint(x: rect.midX, y: middle + lower + closed))
        path.closeSubpath()
        return path
    }
}

/// A brow: blunt and thick at the end nearest the nose, tapering to a point,
/// with a slight arch over the middle. A uniform capsule reads as a dash.
struct BrowShape: Shape {
    /// True when the thick end is on the left of this shape's own rect. The
    /// face mirrors it rather than flipping the view, so the rotation applied
    /// outside is not inverted along with it.
    var thickEndLeading: Bool

    func path(in rect: CGRect) -> Path {
        /// 0 at the thick end, 1 at the tip.
        func x(_ t: CGFloat) -> CGFloat {
            thickEndLeading ? rect.minX + rect.width * t : rect.maxX - rect.width * t
        }
        let tip = CGPoint(x: x(1), y: rect.midY)

        var path = Path()
        path.move(to: CGPoint(x: x(0), y: rect.minY + rect.height * 0.25))
        path.addQuadCurve(to: tip, control: CGPoint(x: x(0.55), y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: x(0), y: rect.maxY),
                          control: CGPoint(x: x(0.55), y: rect.maxY - rect.height * 0.1))
        path.closeSubpath()
        return path
    }
}

/// A mouth, filled rather than stroked so it can taper.
///
/// A stroked curve has one width along its whole length, which is the line of a
/// diagram. Building the outline from two curves lets the corners come to a
/// point while the middle keeps its weight.
struct MouthShape: Shape {
    var curve: Double
    /// 0 a line … 1 an aperture. Opening drops the lower edge and leaves the
    /// upper one on the curve, so a smile that opens stays a smile.
    var open: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(curve, open) }
        set { curve = newValue.first; open = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        // Y grows downward, so a positive curve pushes the middle below the
        // corners — which is a smile.
        let depth = rect.height * CGFloat(curve)
        let corner = rect.midY - depth * 0.25
        let weight = rect.height * 0.17

        var path = Path()
        let left = CGPoint(x: rect.minX, y: corner)
        let right = CGPoint(x: rect.maxX, y: corner)
        path.move(to: left)
        path.addQuadCurve(to: right, control: CGPoint(x: rect.midX, y: rect.midY + depth - weight))
        let aperture = rect.height * 1.5 * min(max(open, 0), 1)
        path.addQuadCurve(
            to: left, control: CGPoint(x: rect.midX, y: rect.midY + depth + weight + aperture))
        path.closeSubpath()
        return path
    }
}

/// A tongue: flat where it leaves the mouth, rounded at the tip.
struct TongueShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height * 2) / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: max(rect.minY, rect.maxY - radius)))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: max(rect.minY, rect.maxY - radius)),
            control: CGPoint(x: rect.midX, y: rect.maxY + radius * 0.5))
        path.closeSubpath()
        return path
    }
}
