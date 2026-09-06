import AppKit
import SwiftUI
import VibeScrollCore

/// Hosts the info card in a borderless floating panel.
///
/// It is a `.nonactivatingPanel` on purpose: the card must never steal focus
/// from the editor or terminal the user is typing in. A teaching aid that
/// interrupts is worse than no teaching aid.
@MainActor
final class CardWindowController: NSObject, NSWindowDelegate {
    static let shared = CardWindowController()

    private var panel: NSPanel?
    private static let originKey = "vibescroll.cardOrigin"
    private static let size = NSSize(width: CardLayout.width, height: CardLayout.cardHeight)

    /// Shows the panel at `height`. A window's origin is its bottom-left, so
    /// holding the origin while the height changes makes the panel grow upward
    /// — which is what a surface anchored to the bottom-right of the screen
    /// should do. An already-visible panel keeps where the user dragged it; a
    /// hidden one comes back at its saved position.
    func show(height: Double = CardLayout.cardHeight) {
        let panel = panel ?? makePanel()
        self.panel = panel

        let size = NSSize(width: CardLayout.width, height: height)
        let origin = panel.isVisible ? panel.frame.origin : savedOrigin(for: size, on: panel)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        // Re-clamp after resizing: growing upward can push the top edge off the
        // screen even from a position that was legal at the smaller height.
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(Self.clamp(panel.frame.origin, size: size, into: visible))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Visible on every Space and over full-screen apps, since the agent the
        // card describes is usually running in one.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: InfoCardView())
        host.autoresizingMask = [.width, .height]   // follow the panel as it grows
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host

        // Persist wherever the user drags it. Done through the delegate rather
        // than a NotificationCenter observer: the delegate is already
        // main-actor isolated, so no non-Sendable notification has to cross an
        // isolation boundary, and there is no observer to unregister.
        panel.delegate = self
        return panel
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        let origin = panel.frame.origin
        UserDefaults.standard.set([origin.x, origin.y], forKey: Self.originKey)
    }

    /// The position the user last dragged the panel to, or the default
    /// bottom-right slot on first run.
    private func savedOrigin(for size: NSSize, on panel: NSPanel) -> CGPoint {
        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [CGFloat],
           saved.count == 2 {
            return CGPoint(x: saved[0], y: saved[1])
        }
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return .zero }
        return CGPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
    }

    /// Clamps a bottom-left origin so a window of `size` sits fully inside
    /// `visible`. If the window is larger than the visible area on an axis, it
    /// pins to that axis's minimum edge. Pure, so it is unit-testable.
    static func clamp(_ origin: CGPoint, size: NSSize, into visible: NSRect) -> CGPoint {
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return CGPoint(
            x: min(max(origin.x, visible.minX), maxX),
            y: min(max(origin.y, visible.minY), maxY)
        )
    }
}
