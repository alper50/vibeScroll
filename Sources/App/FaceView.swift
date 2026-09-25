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
///
/// **Drawn for the size it is seen at.** The face lands at about 50pt on
/// screen, where an eye is a few points across. An earlier version chased
/// realism at that size — almond eyes with pointed corners, brows and a mouth
/// that tapered to a tip, an engraved double outline — and every one of those
/// details fell below a pixel and came out as jaggies and halo. So the rules
/// here are the ones small icons follow:
///
/// - **No points.** Every end is a round cap, every corner a round join.
/// - **A minimum weight.** Lines are about 1.7pt on screen, never thinner, so
///   they stay solid on a non-Retina display too.
/// - **One layer.** No ghost copies for depth: the orb is lit, the features
///   are ink on it.
struct FaceView: View {
    var expression: FaceExpression
    /// 0 open … 1 fully shut. Kept out of the expression because a blink is not
    /// a change of mood; it multiplies into the lids at drawing time.
    var blink: Double = 0
    /// Where the eyes are pointed, -1…1 on each axis. Out of the expression for
    /// the same reason as the blink: looking at the pointer is not a mood.
    var gaze: CGSize = .zero
    /// Where the tongue's tip is, when it is out. The fidget, kept out of the
    /// expression for the same reason as the blink and the gaze — see
    /// `TongueModel`.
    var tongue: TonguePose = .rest

    /// Design canvas. Everything is expressed against this and scaled once, so
    /// the same face works in the 74pt orb and in the preview at 3×. At the
    /// orb's size one design point is about half a screen point, which is what
    /// the weights below are chosen against.
    static let designSize = CGSize(width: 96, height: 72)

    /// Stroke weight for brows and mouth, in design points (~1.7pt on screen).
    private static let lineWeight: CGFloat = 3.3

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
    }

    // MARK: - Colour

    /// The accent colour, nudged by strain — a quarter of the way at most, see
    /// `FaceExpression.tint`.
    ///
    /// Mixed in OKLCH and around the hue wheel rather than straight across in
    /// RGB. Blue and orange are near-complements, so a straight mix passes
    /// through grey and the face goes a sickly blue-grey; turning the hue keeps
    /// it saturated, which at this distance lands on a violet.
    private var tint: Color {
        Color(nsColor: FaceInk.mix(NSColor.controlAccentColor, NSColor.systemOrange,
                                   amount: expression.tint))
    }

    /// Inside an open mouth: the ink, much darker, so the opening reads as a
    /// hole rather than as a filled shape.
    private var mouthInterior: Color {
        Color(nsColor: FaceInk.darkened(NSColor.controlAccentColor, by: 0.55))
    }

    /// Its own colour, or it disappears into the mouth it is sitting in.
    private static let tongueColor = Color(red: 0.98, green: 0.47, blue: 0.56)
    /// The groove down the middle: the same pink, deeper. It is what turns a
    /// flat pink shape into something with a surface.
    private static let tongueGroove = Color(red: 0.82, green: 0.29, blue: 0.40)

    // MARK: - Eyes

    private static let eyeOffsetX: CGFloat = 17
    private static let eyeCentreY: CGFloat = -4
    private static let eyeWidth: CGFloat = 11
    private static let eyeHeight: CGFloat = 15
    /// How far a full look moves the eyes, in design points. Small on purpose:
    /// with no iris to slide, the whole shape travels, and a shape that moves
    /// far stops reading as an eye looking and starts reading as an eye coming
    /// loose from the face.
    private static let gazeRangeX: CGFloat = 2.2
    private static let gazeRangeY: CGFloat = 1.6

    private func eye(side: CGFloat) -> some View {
        let openness = expression.eyeOpenness * (1 - min(max(blink, 0), 1))
        return ZStack {
            EyeShape(openness: openness).fill(tint)
            EyeCatchlightShape(openness: openness).fill(Color.white.opacity(0.92))
        }
        .frame(width: Self.eyeWidth, height: Self.eyeHeight)
        .offset(x: side * Self.eyeOffsetX + gaze.width * Self.gazeRangeX,
                y: Self.eyeCentreY + gaze.height * Self.gazeRangeY)
    }

    // MARK: - Brows

    private static let browWidth: CGFloat = 14
    private static let browHeight: CGFloat = 4
    private static let browRestY: CGFloat = -19

    /// One axis carries both height and tilt, because they move together on a
    /// real face: raised brows are high and *level*, a furrowed pair is low
    /// with the inner ends pulled down.
    private func brow(side: CGFloat) -> some View {
        let angle = expression.browAngle
        // Negative y is up, so a positive angle lifts. Skew lifts one and drops
        // the other: `side` is +1 on the right, which is the one a positive
        // skew raises.
        let lift = -angle * 5 - expression.browSkew * side * 4.5
        // Tilt only ever furrows. Rotating in the positive direction too would
        // raise the inner ends, which is the sad brow, not the alert one — the
        // two are opposite expressions and only one of them belongs on a face
        // that is paying attention.
        let tilt = Angle.degrees(min(angle, 0) * 16 * side)
        return BrowShape()
            .stroke(tint, style: StrokeStyle(lineWidth: Self.lineWeight, lineCap: .round))
            .frame(width: Self.browWidth, height: Self.browHeight)
            .rotationEffect(tilt)
            .offset(x: side * Self.eyeOffsetX, y: Self.browRestY + lift)
    }

    // MARK: - Mouth

    private static let mouthWidth: CGFloat = 26
    private static let mouthHeight: CGFloat = 20
    private static let mouthY: CGFloat = 19

    private var mouth: some View {
        let shape = MouthShape(curve: expression.mouthCurve, open: expression.mouthOpen)
        // Faded in with the opening rather than switched on at a threshold, so
        // a mouth that opens while animating grows a hole instead of popping one.
        let interior = min(max(expression.mouthOpen * 5, 0), 1)
        let tongueShape = TongueShape(curve: expression.mouthCurve, open: expression.mouthOpen,
                                      amount: expression.tongue, pose: tongue)
        let lipStyle = StrokeStyle(lineWidth: Self.lineWeight, lineCap: .round, lineJoin: .round)
        return ZStack {
            shape.fill(mouthInterior).opacity(interior)
            // A closed path stroked with round joins: the smile line when the
            // mouth is shut, a rounded rim when it is open, and no moment where
            // one swaps for the other.
            shape.stroke(tint, style: lipStyle)
            // Over the lower lip rather than clipped inside the mouth. A tongue
            // that can only show within the opening is a pink patch sitting in
            // a hole; one that comes out over the lip is a tongue. It is cut
            // off above the upper lip, which is all that stops it floating
            // over the face when the mouth frowns.
            ZStack {
                tongueShape.fill(Self.tongueColor)
                TongueGrooveShape(tongue: tongueShape)
                    .stroke(Self.tongueGroove.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            .clipShape(BelowUpperLipShape(curve: expression.mouthCurve,
                                          open: expression.mouthOpen))
            // The upper lip once more, over the tongue's root, so it comes out
            // from under the lip instead of being pasted on top of the mouth.
            UpperLipShape(curve: expression.mouthCurve, open: expression.mouthOpen)
                .stroke(tint, style: lipStyle)
        }
        .frame(width: Self.mouthWidth, height: Self.mouthHeight)
        .offset(y: Self.mouthY)
    }
}

// MARK: - Shapes

/// An eye: a solid capsule whose lid comes down from the top.
///
/// Closing shrinks the height from above and settles the eye a little lower,
/// which is what a lid does — the lower lid barely moves. Fully shut, the
/// capsule has become a short horizontal pill: a closed eye, drawn at the same
/// weight as everything else, with nothing swapped in.
struct EyeShape: Shape {
    var openness: Double

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    /// The eye's outline in `rect`, shared with the catchlight so the two
    /// cannot drift apart.
    static func body(in rect: CGRect, openness: Double) -> CGRect {
        let open = CGFloat(min(max(openness, 0), 1))
        // The shut eye keeps a line's weight, or the face loses half its
        // features on every blink.
        let shut: CGFloat = 3.2
        let height = max(shut, rect.height * open)
        // The lower edge rises only a little as the lid falls.
        let bottom = rect.maxY - (rect.height - height) * 0.3
        // A drowsy eye is also slightly wider than it is tall-and-narrow open,
        // which keeps a half-shut eye from reading as a squint.
        let width = rect.width * (1 + (1 - open) * 0.12)
        return CGRect(x: rect.midX - width / 2, y: bottom - height,
                      width: width, height: height)
    }

    func path(in rect: CGRect) -> Path {
        let eye = Self.body(in: rect, openness: openness)
        return Path(roundedRect: eye, cornerRadius: min(eye.width, eye.height) / 2)
    }
}

/// The catchlight: one soft dot, upper left on *both* eyes.
///
/// Not mirrored, because the orb behind is lit from the upper left too — two
/// eyes with symmetrical highlights are two eyes lit by two lamps. Big enough
/// to be a highlight at the size the face is seen (about 1.5pt), where the
/// previous one was a speck. It shrinks with the lid and is gone before the
/// eye is a line, so it never floats outside a closing eye.
struct EyeCatchlightShape: Shape {
    var openness: Double

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let eye = EyeShape.body(in: rect, openness: openness)
        let radius = min(eye.width * 0.17, (eye.height - 6) * 0.25)
        guard radius > 0.8 else { return Path() }
        let centre = CGPoint(x: eye.minX + eye.width * 0.36,
                             y: eye.minY + max(radius + 1.2, eye.height * 0.30))
        return Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                      width: radius * 2, height: radius * 2))
    }
}

/// A brow: a shallow arch, stroked with round caps by the view.
///
/// Barely curved. A pronounced arch over a round eye is the cartoon shorthand
/// for surprise, and with it every expression — neutral included — read as
/// startled. The brow's job here is height and tilt; the curve only keeps it
/// from being a dash.
struct BrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.35))
        return path
    }
}

/// A mouth as one closed outline: the upper lip's curve out, the lower lip's
/// curve back.
///
/// Shut, the two curves coincide and the view's round-joined stroke draws a
/// plain line with rounded ends. Opening drops only the lower curve, so a smile
/// that opens stays a smile.
struct MouthShape: Shape {
    var curve: Double
    /// 0 a line … 1 an aperture.
    var open: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(curve, open) }
        set { curve = newValue.first; open = newValue.second }
    }

    /// The corners and the two control points, shared with the tongue.
    struct Lips {
        var left: CGPoint
        var right: CGPoint
        var upper: CGPoint
        var lower: CGPoint
    }

    static func lips(in rect: CGRect, curve: Double, open: Double) -> Lips {
        // The shut mouth sits in the upper part of the rect; the rest is room
        // for the lower lip to drop into.
        let rest = rect.minY + rect.height * 0.30
        // Y grows downward, so a positive curve pushes the middle below the
        // corners — which is a smile. Corners move the other way by a little,
        // so a frown does not just look like a smile flipped on its axis.
        let depth = rect.height * 0.42 * CGFloat(min(max(curve, -1), 1))
        let corner = rest - depth * 0.25
        let aperture = rect.height * 0.62 * CGFloat(min(max(open, 0), 1))
        return Lips(
            left: CGPoint(x: rect.minX, y: corner),
            right: CGPoint(x: rect.maxX, y: corner),
            upper: CGPoint(x: rect.midX, y: rest + depth),
            // Quadratic control points sit twice as far from the chord as the
            // curve they produce, hence the doubled aperture.
            lower: CGPoint(x: rect.midX, y: rest + depth + aperture * 2))
    }

    func path(in rect: CGRect) -> Path {
        let lips = Self.lips(in: rect, curve: curve, open: open)
        var path = Path()
        path.move(to: lips.left)
        path.addQuadCurve(to: lips.right, control: lips.upper)
        path.addQuadCurve(to: lips.left, control: lips.lower)
        path.closeSubpath()
        return path
    }
}

/// A tongue sticking out: root under the upper lip, a rounded tip past the
/// lower one.
///
/// `amount` is how far out the mood puts it; `pose` is the fidget on top —
/// which way the tip has wandered, how far it leans, whether it has been
/// drawn back in for a moment. Both animate, so a gesture is a smooth motion
/// of the shape rather than a series of poses.
struct TongueShape: Shape {
    var curve: Double
    var open: Double
    var amount: Double
    var pose: TonguePose

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>,
                                       AnimatablePair<Double, AnimatablePair<Double, AnimatablePair<Double, Double>>>> {
        get {
            AnimatablePair(AnimatablePair(curve, open),
                           AnimatablePair(amount, AnimatablePair(pose.side,
                                                                 AnimatablePair(pose.reach, pose.tilt))))
        }
        set {
            curve = newValue.first.first
            open = newValue.first.second
            amount = newValue.second.first
            pose = TonguePose(side: newValue.second.second.first,
                              reach: newValue.second.second.second.first,
                              tilt: newValue.second.second.second.second)
        }
    }

    /// Where everything is, shared with the groove so the two cannot part.
    struct Geometry {
        var root: CGPoint
        var tip: CGPoint
        var halfWidth: CGFloat
        /// How far past the lower lip the tip reaches.
        var protrusion: CGFloat
        /// Leans the whole tongue about its root.
        var transform: CGAffineTransform
    }

    func geometry(in rect: CGRect) -> Geometry? {
        let out = CGFloat(min(max(amount, 0), 1)) * CGFloat(min(max(pose.reach, 0), 1.25))
        guard out > 0.01 else { return nil }
        let lips = MouthShape.lips(in: rect, curve: curve, open: open)
        let chordY = (lips.left.y + lips.right.y) / 2
        // The middle of each lip: halfway from the chord to its control point.
        let upper = chordY + (lips.upper.y - chordY) / 2
        let lower = chordY + (lips.lower.y - chordY) / 2

        let side = CGFloat(min(max(pose.side, -1), 1))
        // Narrower while drawn in: a tongue pulled back bunches up.
        let halfWidth = rect.width * 0.21 * (0.8 + 0.2 * min(out, 1))
        let protrusion = rect.height * 0.46 * out
        let root = CGPoint(x: rect.midX + side * rect.width * 0.08, y: min(upper, lower) - 1)
        let tip = CGPoint(x: rect.midX + side * rect.width * 0.24, y: lower + protrusion)

        let angle = CGFloat(min(max(pose.tilt, -1), 1)) * .pi / 13
        let transform = CGAffineTransform(translationX: root.x, y: root.y)
            .rotated(by: -angle)
            .translatedBy(x: -root.x, y: -root.y)
        return Geometry(root: root, tip: tip, halfWidth: halfWidth,
                        protrusion: protrusion, transform: transform)
    }

    func path(in rect: CGRect) -> Path {
        guard let g = geometry(in: rect) else { return Path() }
        let w = g.halfWidth
        // Sides run from the root to where the tip starts rounding; the tip is
        // two quarter-curves, so it comes to a soft point rather than a
        // semicircle — a tongue is fuller than it is wide at the end.
        let shoulder = max(g.root.y, g.tip.y - w * 1.1)
        var path = Path()
        path.move(to: CGPoint(x: g.root.x - w, y: g.root.y))
        path.addLine(to: CGPoint(x: g.tip.x - w, y: shoulder))
        path.addQuadCurve(to: CGPoint(x: g.tip.x, y: g.tip.y),
                          control: CGPoint(x: g.tip.x - w, y: g.tip.y))
        path.addQuadCurve(to: CGPoint(x: g.tip.x + w, y: shoulder),
                          control: CGPoint(x: g.tip.x + w, y: g.tip.y))
        path.addLine(to: CGPoint(x: g.root.x + w, y: g.root.y))
        path.closeSubpath()
        return path.applying(g.transform)
    }
}

/// The groove down the middle of the tongue, from near the tip towards the
/// root. Fades in only once enough of the tongue is out to hold it — a line on
/// a sliver of pink is a scratch, not a groove.
struct TongueGrooveShape: Shape {
    var tongue: TongueShape

    var animatableData: TongueShape.AnimatableData {
        get { tongue.animatableData }
        set { tongue.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard let g = tongue.geometry(in: rect), g.protrusion > rect.height * 0.14
        else { return Path() }
        let start = CGPoint(x: g.tip.x + (g.root.x - g.tip.x) * 0.2,
                            y: g.tip.y - g.halfWidth * 0.9)
        let end = CGPoint(x: g.tip.x + (g.root.x - g.tip.x) * 0.7,
                          y: g.tip.y + (g.root.y - g.tip.y) * 0.7)
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path.applying(g.transform)
    }
}

/// Everything below the upper lip. What the tongue is clipped to, so its root
/// can never show above the mouth whatever shape the mouth is in.
struct BelowUpperLipShape: Shape {
    var curve: Double
    var open: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(curve, open) }
        set { curve = newValue.first; open = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let lips = MouthShape.lips(in: rect, curve: curve, open: open)
        let far = rect.height * 3
        var path = Path()
        path.move(to: CGPoint(x: lips.left.x - far, y: lips.left.y))
        path.addLine(to: lips.left)
        path.addQuadCurve(to: lips.right, control: lips.upper)
        path.addLine(to: CGPoint(x: lips.right.x + far, y: lips.right.y))
        path.addLine(to: CGPoint(x: lips.right.x + far, y: rect.maxY + far))
        path.addLine(to: CGPoint(x: lips.left.x - far, y: rect.maxY + far))
        path.closeSubpath()
        return path
    }
}

/// The upper lip on its own, stroked over the tongue's root.
struct UpperLipShape: Shape {
    var curve: Double
    var open: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(curve, open) }
        set { curve = newValue.first; open = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let lips = MouthShape.lips(in: rect, curve: curve, open: open)
        var path = Path()
        path.move(to: lips.left)
        path.addQuadCurve(to: lips.right, control: lips.upper)
        return path
    }
}

// MARK: - Colour

/// Colour arithmetic for the face, in OKLCH.
///
/// OKLab rather than HSB because it is perceptually even: equal steps look
/// like equal steps, and lightness stays put while the hue turns, so the
/// features never dim or flare partway through a transition.
enum FaceInk {
    /// Blends `a` towards `b` along the hue wheel, the short way round.
    static func mix(_ a: NSColor, _ b: NSColor, amount: Double) -> NSColor {
        let t = min(max(amount, 0), 1)
        guard t > 0 else { return a }
        let x = lch(a), y = lch(b)
        var dh = y.h - x.h
        if dh > .pi { dh -= 2 * .pi }
        if dh < -.pi { dh += 2 * .pi }
        return color(l: x.l + (y.l - x.l) * t,
                     c: x.c + (y.c - x.c) * t,
                     h: x.h + dh * t,
                     alpha: a.alphaComponent)
    }

    /// The same hue, `amount` of the way to black in perceptual lightness.
    static func darkened(_ a: NSColor, by amount: Double) -> NSColor {
        let x = lch(a)
        return color(l: x.l * (1 - amount), c: x.c * (1 - amount * 0.5), h: x.h,
                     alpha: a.alphaComponent)
    }

    private static func lch(_ color: NSColor) -> (l: Double, c: Double, h: Double) {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(c.redComponent), g = linear(c.greenComponent), b = linear(c.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return (L, (A * A + B * B).squareRoot(), atan2(B, A))
    }

    private static func color(l L: Double, c C: Double, h: Double, alpha: CGFloat) -> NSColor {
        let A = C * cos(h), B = C * sin(h)
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
        func gamma(_ v: Double) -> CGFloat {
            let v = min(max(v, 0), 1)
            return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        return NSColor(srgbRed: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                       green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                       blue: gamma(-0.0041960863 * l - 0.5115618607 * m + 1.5906614880 * s),
                       alpha: alpha)
    }
}
