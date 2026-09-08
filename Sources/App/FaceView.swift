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

    private static let eyeOffsetX: CGFloat = 21
    private static let eyeCentreY: CGFloat = -6
    private static let eyeWidth: CGFloat = 15
    private static let eyeMaxHeight: CGFloat = 21
    /// Never fully zero: a closed eye is a line, and a line still has to be
    /// drawn or the face loses half its features when it blinks.
    private static let eyeMinHeight: CGFloat = 2.5

    private func eye(side: CGFloat) -> some View {
        let openness = expression.eyeOpenness * (1 - min(max(blink, 0), 1))
        let height = Self.eyeMinHeight
            + (Self.eyeMaxHeight - Self.eyeMinHeight) * openness
        return Capsule(style: .continuous)
            .frame(width: Self.eyeWidth, height: height)
            .offset(x: side * Self.eyeOffsetX, y: Self.eyeCentreY)
    }

    // MARK: - Brows

    private static let browWidth: CGFloat = 19
    private static let browThickness: CGFloat = 3.5
    private static let browRestY: CGFloat = -24

    /// One axis carries both height and tilt, because they move together on a
    /// real face: raised brows are high and *level*, a furrowed pair is low
    /// with the inner ends pulled down.
    private func brow(side: CGFloat) -> some View {
        let angle = expression.browAngle
        // Negative y is up, so a positive angle lifts.
        let lift = -angle * 7
        // Tilt only ever furrows. Rotating in the positive direction too would
        // raise the inner ends, which is the sad brow, not the alert one — the
        // two are opposite expressions and only one of them belongs on a face
        // that is paying attention.
        //
        // A capsule's inner end is its right end on the left side of the face
        // and its left end on the right, so the sign is mirrored per side.
        let tilt = Angle.degrees(min(angle, 0) * 15 * side)
        return Capsule()
            .frame(width: Self.browWidth, height: Self.browThickness)
            .rotationEffect(tilt)
            .offset(x: side * Self.eyeOffsetX, y: Self.browRestY + lift)
    }

    // MARK: - Mouth

    private static let mouthWidth: CGFloat = 40
    private static let mouthHeight: CGFloat = 18
    private static let mouthY: CGFloat = 22

    private var mouth: some View {
        MouthShape(curve: expression.mouthCurve)
            .stroke(style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            .frame(width: Self.mouthWidth, height: Self.mouthHeight)
            .offset(y: Self.mouthY)
    }
}

/// A single quadratic curve: corners fixed, control point swept.
///
/// `animatableData` is what lets a mouth travel from a frown to a smile instead
/// of cutting between them — the whole reason the expression is numbers.
struct MouthShape: Shape {
    var curve: Double

    var animatableData: Double {
        get { curve }
        set { curve = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Y grows downward, so a positive curve pushes the control point below
        // the corners — which is a smile.
        let depth = rect.height * CGFloat(curve)
        let corner = rect.midY - depth * 0.25
        path.move(to: CGPoint(x: rect.minX, y: corner))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: corner),
            control: CGPoint(x: rect.midX, y: rect.midY + depth))
        return path
    }
}
