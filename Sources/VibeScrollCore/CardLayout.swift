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
    public static let faceRestingSize: Double = 104
    /// …and this wide while the pointer is over it.
    public static let faceHoverSize: Double = 148

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
    public static var faceWindowHeight: Double { faceHoverSize + 4 + faceLabelHeight }

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

    /// Where the card panel sits so it reads as belonging to the face.
    ///
    /// Below the face when there is room and above it when there is not, always
    /// centred on it, always inside the screen. Pure arithmetic because the
    /// failure is silent: a card placed off-screen looks exactly like a card
    /// that never appeared.
    public static func attachedOrigin(
        faceFrame: CGRect, cardSize: CGSize, visibleFrame: CGRect, gap: Double = 10
    ) -> CGPoint {
        let below = faceFrame.minY - gap - cardSize.height
        let above = faceFrame.maxY + gap
        // Below unless that would run off the bottom; above unless that would
        // run off the top. If neither fits, the clamp below settles it.
        var y = below >= visibleFrame.minY ? below : above
        if y + cardSize.height > visibleFrame.maxY, below >= visibleFrame.minY { y = below }

        let x = faceFrame.midX - cardSize.width / 2
        return CGPoint(
            x: min(max(x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - cardSize.width)),
            y: min(max(y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - cardSize.height)))
    }
}
