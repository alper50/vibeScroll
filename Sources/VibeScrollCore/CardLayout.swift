import Foundation

/// Geometry for the floating card panel.
///
/// The sessions list grows the panel with the number of sessions, so the size
/// rule lives here as pure arithmetic rather than being scattered between the
/// window controller and the view — and so the clamp has a test.
public enum CardLayout {
    public static let width: Double = 340

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
}
