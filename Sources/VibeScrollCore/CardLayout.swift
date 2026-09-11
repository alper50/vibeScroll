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

    /// Sessions mode never shrinks below card height (no jarring shrink when
    /// switching modes) and never grows past `maxSessionsHeight` (a pet-sized
    /// ambient panel must not become a full-screen list).
    public static let minSessionsHeight: Double = 200
    public static let maxSessionsHeight: Double = 420

    /// One session row, and the fixed chrome around the list (header, footer,
    /// padding). Kept here so the view and the window can never disagree about
    /// how much space a row takes.
    public static let rowHeight: Double = 28
    static let chrome: Double = 96

    /// Panel height for `count` sessions, clamped. Beyond roughly eleven rows
    /// the list scrolls inside the capped panel.
    public static func sessionsHeight(forCount count: Int) -> Double {
        let content = Double(max(count, 1)) * rowHeight
        return min(max(chrome + content, minSessionsHeight), maxSessionsHeight)
    }

    /// What sits underneath the face.
    ///
    /// `none` is a real state rather than "panel hidden": the face is the
    /// always-on layer, and a card that has been dismissed leaves it behind
    /// rather than closing the window.
    public enum PanelContent: Equatable, Sendable {
        case none
        case card
        case sessions(count: Int)
    }

    /// Height of the card panel. `none` is zero because there is nothing left
    /// to show once the card is gone — the face is a separate window now and
    /// carries the always-on job by itself.
    public static func panelHeight(for content: PanelContent) -> Double {
        switch content {
        case .none:               return 0
        case .card:               return cardHeight
        case .sessions(let rows): return sessionsHeight(forCount: rows)
        }
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
