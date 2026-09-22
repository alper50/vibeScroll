import CoreGraphics
import Foundation

/// Geometry for the floating card panel.
///
/// The sessions list grows the panel with the number of sessions, so the size
/// rule lives here as pure arithmetic rather than being scattered between the
/// window controller and the view — and so the clamp has a test.
public enum CardLayout {
    public static let width: Double = 340

    /// The face lives in its own window. Its blob is this wide at rest…
    public static let faceRestingSize: Double = 74
    /// …and grows by this much under the pointer. A ratio rather than a second
    /// size, so resizing the face keeps the step it was tuned to: the growth is
    /// an acknowledgement that the pointer arrived, not an entrance.
    public static let faceHoverGrowth: Double = 1.19
    public static var faceHoverSize: Double { faceRestingSize * faceHoverGrowth }

    /// Clear space around the blob inside its window.
    ///
    /// The orb casts a shadow and grows on hover; without room for both, the
    /// shadow meets the window's edge and draws a straight line across it —
    /// the window's own corner, showing through a surface that is supposed to
    /// be a circle on the desktop.
    public static let faceMargin: Double = 14
    /// The square the blob is centred in, shadow and growth included.
    public static var faceSlot: Double { faceHoverSize + faceMargin * 2 }

    /// Room under the blob for the hover label.
    public static let faceLabelHeight: Double = 26

    /// The face window never changes size — only the blob inside it does.
    ///
    /// Resizing the window on hover is the obvious approach and it flickers:
    /// shrinking moves the frame out from under the pointer, which ends the
    /// hover, which grows it again. Holding the frame at its largest and
    /// scaling the content means the hover target only ever *gains* area, so
    /// there is no oscillation to damp.
    ///
    /// Wider than the blob because the label is a sentence. The margin is
    /// transparent and does not hit-test, so it costs nothing to carry.
    public static let faceWindowWidth: Double = 300
    public static var faceWindowHeight: Double { faceSlot + 4 + faceLabelHeight }

    /// Height in card mode. Fixed: a card's text is clamped to two title lines
    /// and five body lines, so it never needs more.
    public static let cardHeight: Double = 200

    /// A list never grows past this: a pet-sized ambient panel must not become
    /// a full-screen list. There is deliberately no matching floor — see
    /// `listHeight`.
    public static let maxListHeight: Double = 420

    /// One session row.
    public static let rowHeight: Double = 28

    /// The fixed furniture around a list: the padding box, the header row, and
    /// the gap between the header and the first row.
    ///
    /// Decomposed rather than carried as one tuned figure. The panel is sized
    /// from this while the view is laid out from the same three parts, and a
    /// single number nobody can derive is one that drifts the moment the header
    /// changes — which shows up as a list that scrolls when it should fit.
    public static let listPadding: Double = 14
    public static let listHeaderHeight: Double = 20
    public static let listSpacing: Double = 8
    static var chrome: Double { listPadding * 2 + listHeaderHeight + listSpacing }

    /// The quota footer under the session list, when there is one to show.
    ///
    /// Carried in the panel's size rather than allowed to overlap the list:
    /// without it the footer eats the last row, and a row half-hidden behind a
    /// summary looks like a rendering bug rather than a full list.
    public static let quotaFooterHeight: Double = 22

    /// Panel height for a list of `count` rows, capped. The panel is exactly as
    /// tall as what is in it until it reaches `maxListHeight`, after which the
    /// list scrolls inside it.
    ///
    /// There used to be a floor at card height, so that switching from a card
    /// to the list never shrank the panel. It bought a smooth transition and
    /// paid for it with the common case: one or two agents sat in a 200pt panel
    /// that was mostly empty, every time. An ambient surface that is three
    /// quarters nothing is worse than one that changes size when you ask it to
    /// show you something else.
    ///
    /// One function for both list modes rather than one each: the session list
    /// and the topic picker are the same panel drawing the same rows, and two
    /// copies of this arithmetic would eventually disagree about how tall a row
    /// is — which shows up as the panel resizing when you switch between them.
    public static func listHeight(forCount count: Int, footer: Double = 0) -> Double {
        let content = Double(max(count, 1)) * rowHeight
        return min(chrome + footer + content, maxListHeight)
    }

    /// What sits underneath the face.
    ///
    /// `none` is a real state rather than "panel hidden": the face is the
    /// always-on layer, and a card that has been dismissed leaves it behind
    /// rather than closing the window.
    public enum PanelContent: Equatable, Sendable {
        case none
        case card
        case moment
        /// `hasQuota` is part of the identity rather than looked up when the
        /// height is computed: the panel resizes on this value, so a pure
        /// function of the case is what makes the resize testable.
        case sessions(count: Int, hasQuota: Bool)
        /// The topic picker, opened from the card's category badge.
        case categories(count: Int)
    }

    /// A moment is two short lines and nothing else — no category strip, no
    /// footer, no "read more". Giving it the teaching card's height would leave
    /// most of the panel empty and make a one-line remark look like an
    /// announcement.
    public static let momentHeight: Double = 92

    /// Height of the card panel. `none` is zero because there is nothing left
    /// to show once the card is gone — the face is a separate window now and
    /// carries the always-on job by itself.
    public static func panelHeight(for content: PanelContent) -> Double {
        switch content {
        case .none:               return 0
        case .card:               return cardHeight
        case .moment:             return momentHeight
        case .sessions(let rows, let hasQuota):
            return listHeight(forCount: rows, footer: hasQuota ? quotaFooterHeight : 0)
        case .categories(let rows):
            return listHeight(forCount: rows)
        }
    }

    /// Which of the two windows belong on screen.
    public struct PanelVisibility: Equatable, Sendable {
        public let face: Bool
        public let card: Bool

        public init(face: Bool, card: Bool) {
            self.face = face
            self.card = card
        }
    }

    /// The rule for both windows, in one place.
    ///
    /// The invariant that matters, and the one that was missing: **the card is
    /// never up without the face.** The card has no position of its own — it is
    /// placed against the face's frame — so a visible card with no face falls
    /// back to the screen corner and sits there orphaned, having visibly jumped
    /// to get there. It used to be possible: the card's own gate asked only
    /// whether the panel had been dismissed by hand, while the face's asked
    /// about sessions and settings, so the two could disagree.
    ///
    /// Pure so that disagreement is a failing test rather than something you
    /// find by going idle with the session list open.
    public static func visibility(
        content: PanelContent, hasSessions: Bool, hasCard: Bool,
        showsFaceWhenIdle: Bool, suppressed: Bool
    ) -> PanelVisibility {
        guard !suppressed else { return PanelVisibility(face: false, card: false) }
        let face = showsFaceWhenIdle || hasSessions || hasCard
        return PanelVisibility(face: face, card: face && content != .none)
    }

    /// Where the card panel sits so it reads as coming out of the face.
    ///
    /// Above it by preference, which is also where the face usually has room:
    /// it opens in the bottom-right corner and most people leave it low. The
    /// card then grows upward out of its top edge rather than dropping out from
    /// underneath, which is the direction that reads as emerging.
    ///
    /// Pure arithmetic because the failure is silent: a card placed off-screen
    /// looks exactly like a card that never appeared.
    public static func attachedOrigin(
        faceFrame: CGRect, cardSize: CGSize, visibleFrame: CGRect, gap: Double = 10
    ) -> CGPoint {
        let above = faceFrame.maxY + gap
        let below = faceFrame.minY - gap - cardSize.height
        // Above unless that would run off the top; below otherwise. If neither
        // fits, the clamp settles it.
        let y = above + cardSize.height <= visibleFrame.maxY ? above : below

        let x = faceFrame.midX - cardSize.width / 2
        return CGPoint(
            x: min(max(x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - cardSize.width)),
            y: min(max(y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - cardSize.height)))
    }
}
