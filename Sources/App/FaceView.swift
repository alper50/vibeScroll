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
    /// Where the eyes are pointed, -1…1 on each axis. Out of the expression for
    /// the same reason as the blink: looking at the pointer is not a mood.
    var gaze: CGSize = .zero

    /// Design canvas. Everything is expressed against this and scaled once, so
    /// the same face works in a 110pt strip and in the preview at 3×.
    static let designSize = CGSize(width: 96, height: 72)

    /// How far the engraving's two ghosts sit from the features, in design
    /// points. Light below and dark above, which is what a groove cut into a
    /// surface lit from above looks like — the far wall of the groove catches
    /// the light, the near lip casts into it.
    ///
    /// Deliberately under a point each. The face is drawn at roughly half this
    /// canvas on screen, so these land at a fraction of a pixel and read as
    /// weight rather than as outlines. Anything heavier and the features get a
    /// white halo, which on a translucent material looks like dirt rather than
    /// depth.
    private static let engraveDrop: CGFloat = 0.85
    private static let engraveRise: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / Self.designSize.width,
                            geometry.size.height / Self.designSize.height)
            ZStack {
                features
                    .foregroundStyle(Color.white.opacity(0.20))
                    .offset(y: Self.engraveDrop)
                features
                    .foregroundStyle(Color.black.opacity(0.11))
                    .offset(y: -Self.engraveRise)
                features
                    .foregroundStyle(tint)
            }
            .frame(width: Self.designSize.width, height: Self.designSize.height)
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    /// The features themselves, drawn three times: twice as the engraving's
    /// ghosts and once in the accent colour. Grouped rather than engraved
    /// shape by shape so the offsets cannot drift apart between features.
    private var features: some View {
        ZStack {
            brow(side: -1)
            brow(side: 1)
            eye(side: -1)
            eye(side: 1)
            mouth
        }
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
    /// How far a full look moves the eyes, in design points. Small on purpose:
    /// with no iris to slide, the whole shape travels, and a shape that moves
    /// far stops reading as an eye looking and starts reading as an eye coming
    /// loose from the face.
    private static let gazeRangeX: CGFloat = 2.6
    private static let gazeRangeY: CGFloat = 1.8

    /// The frame is fixed and the shape draws inside it, rather than the frame
    /// shrinking as the eye closes. Nothing is re-laid-out on a blink, and the
    /// corners stay put — an eye whose corners move is a shape changing size,
    /// not a lid coming down.
    private func eye(side: CGFloat) -> some View {
        // `side` is +1 on the right of the face, and that eye's inner corner —
        // the one by the nose — is on the left of its own rect.
        let openness = expression.eyeOpenness * (1 - min(max(blink, 0), 1))
        let shape = EyeShape(openness: openness, innerLeading: side > 0)

        return ZStack {
            shape
            // Punched out rather than painted on: the hole shows the orb
            // behind, so the highlight is whatever the material is doing at
            // that moment and the face stays a single colour. `destinationOut`
            // rather than an even-odd hole because it cannot misfire — a
            // highlight that strays past the lid removes nothing instead of
            // drawing a stray crescent outside the eye.
            EyeCatchlightShape(openness: openness, innerLeading: side > 0)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: Self.eyeWidth, height: Self.eyeHeight)
        .offset(x: side * Self.eyeOffsetX + gaze.width * Self.gazeRangeX,
                y: Self.eyeCentreY + gaze.height * Self.gazeRangeY)
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
///
/// Nothing here is symmetrical either, which is the rest of what made the first
/// version read as a graphic rather than an eye. Three asymmetries, all small:
/// the corner nearest the nose sits lower than the one by the temple, the upper
/// lid's high point is pulled toward the nose, and the lower lid's dip is
/// pushed away from it. Individually invisible; together they are the
/// difference between an eye and a lens.
struct EyeShape: Shape {
    var openness: Double
    /// True when the corner nearest the nose is on the left of this shape's own
    /// rect — so the right eye of the face. `BrowShape` is handed its side the
    /// same way, and for the same reason: mirroring with a transform would
    /// flip everything applied outside along with it.
    var innerLeading: Bool

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    /// The geometry both the outline and the catchlight are built from, so the
    /// highlight cannot drift off the shape it is supposed to be sitting on.
    struct Lids {
        var left: CGPoint
        var right: CGPoint
        var upperControl: CGPoint
        var lowerControl: CGPoint
        var middle: CGFloat
    }

    static func lids(in rect: CGRect, openness: Double, innerLeading: Bool) -> Lids {
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

        // The tear duct sits lower than the outer corner. Scaled by how open
        // the eye is so that a blink closes to a level line rather than to a
        // slope, which would read as a wink.
        let tilt = rect.height * 0.030 * open
        let leftY = middle + (innerLeading ? tilt : -tilt)
        let rightY = middle + (innerLeading ? -tilt : tilt)

        // Peak toward the nose, dip away from it. Both are expressed against
        // the rect's own left edge rather than against the inner corner, so
        // there is one coordinate system here and no mirrored reasoning.
        func x(fromNose t: CGFloat) -> CGFloat {
            rect.minX + rect.width * (innerLeading ? t : 1 - t)
        }

        return Lids(
            left: CGPoint(x: rect.minX, y: leftY),
            right: CGPoint(x: rect.maxX, y: rightY),
            upperControl: CGPoint(x: x(fromNose: 0.46), y: middle - upper - closed),
            lowerControl: CGPoint(x: x(fromNose: 0.54), y: middle + lower + closed),
            middle: middle)
    }

    /// Where the catchlight goes, in the eye's own coordinates. `nil` when the
    /// eye is too nearly shut to hold one.
    ///
    /// Upper left on *both* eyes rather than mirrored, because the orb behind
    /// the face is lit from the upper left too. Two eyes with symmetrical
    /// highlights are two eyes lit by two lamps, which is the look of a
    /// diagram; one lamp is what makes a face read as being in a room.
    static func catchlight(in rect: CGRect, openness: Double, innerLeading: Bool) -> CGRect? {
        let lids = lids(in: rect, openness: openness, innerLeading: innerLeading)
        // Anchored to a place on screen, not to a position along the curve.
        // Taking it at a fixed curve parameter put it in a different spot on
        // each eye, because the two curves are mirrored — which is two lamps
        // again, by accident.
        let target = rect.minX + rect.width * 0.30
        let lid = nearestOnUpperLid(toX: target, lids: lids)
        let gap = lids.middle - lid.y
        guard gap > 0 else { return nil }

        // Sized and placed against that gap rather than against the rect, so
        // it shrinks with the lid on the way into a blink instead of having to
        // be switched off at some threshold.
        let radius = min(gap * 0.20, rect.width * 0.12)
        guard radius > 0.35 else { return nil }
        let centre = CGPoint(x: lid.x, y: lid.y + gap * 0.55)
        return CGRect(x: centre.x - radius, y: centre.y - radius,
                      width: radius * 2, height: radius * 2)
    }

    /// The point on the upper lid closest to a given x.
    ///
    /// Sampled rather than solved. The curve's x is a quadratic in t and
    /// inverting it is a page of algebra plus the branch where the eye is shut
    /// and the quadratic degenerates; twenty-four samples of an arc a few
    /// points long are accurate past what any of this is drawn at.
    private static func nearestOnUpperLid(toX target: CGFloat, lids: Lids) -> CGPoint {
        let steps = 24
        var best = lids.left
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for step in 0...steps {
            let point = quadPoint(CGFloat(step) / CGFloat(steps),
                                  lids.left, lids.upperControl, lids.right)
            let distance = abs(point.x - target)
            if distance < bestDistance {
                bestDistance = distance
                best = point
            }
        }
        return best
    }

    private static func quadPoint(_ t: CGFloat, _ p0: CGPoint, _ c: CGPoint,
                                  _ p1: CGPoint) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                       y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
    }

    func path(in rect: CGRect) -> Path {
        let lids = Self.lids(in: rect, openness: openness, innerLeading: innerLeading)
        var path = Path()
        path.move(to: lids.left)
        path.addQuadCurve(to: lids.right, control: lids.upperControl)
        path.addQuadCurve(to: lids.left, control: lids.lowerControl)
        path.closeSubpath()
        return path
    }
}

/// The catchlight, as a shape rather than a circle positioned by the view.
///
/// It has to be a `Shape` so that it carries `openness` as `animatableData`
/// like the lid does. Computed in a view body instead, it would be sized once
/// per re-render while the lid interpolated past it — the highlight sitting
/// still at full size through a blink, then disappearing.
struct EyeCatchlightShape: Shape {
    var openness: Double
    var innerLeading: Bool

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard let spot = EyeShape.catchlight(in: rect, openness: openness,
                                             innerLeading: innerLeading)
        else { return Path() }
        return Path(ellipseIn: spot)
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
