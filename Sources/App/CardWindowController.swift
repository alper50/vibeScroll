import AppKit
import SwiftUI
import VibeScrollCore

/// Hosts the info card in a borderless floating panel.
///
/// It is a `.nonactivatingPanel` on purpose: the card must never steal focus
/// from the editor or terminal the user is typing in. A teaching aid that
/// interrupts is worse than no teaching aid.
@MainActor
final class CardWindowController: NSObject {
    static let shared = CardWindowController()

    private var panel: NSPanel?
    private static let size = NSSize(width: CardLayout.width, height: CardLayout.cardHeight)

    /// Matches the face's. The card hangs off it, so one arriving abruptly
    /// while the other eases in reads as a glitch rather than two windows.
    private static let fade: TimeInterval = 0.22
    private var wantsVisible = false

    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Shows the card panel, hung off the face.
    ///
    /// The panel has no position of its own any more: it belongs to the face
    /// and follows it. Letting it be dragged separately meant it would snap
    /// back the next time it opened, which reads as a bug rather than a rule.
    func show(height: Double) {
        wantsVisible = true
        let panel = panel ?? makePanel()
        self.panel = panel
        lastHeight = height

        let wasHidden = !panel.isVisible
        panel.setFrame(NSRect(origin: origin(forHeight: height),
                              size: NSSize(width: CardLayout.width, height: height)),
                       display: true)
        if wasHidden { panel.alphaValue = prefersReducedMotion ? 1 : 0 }
        panel.orderFrontRegardless()

        guard !prefersReducedMotion else { panel.alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        wantsVisible = false
        guard let panel, panel.isVisible else { return }
        guard !prefersReducedMotion else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fade
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                // Shown again while it was fading: leave it be.
                guard let self, !self.wantsVisible else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Called when the face moves, so an open card travels with it.
    func reposition() {
        guard let panel, panel.isVisible, let height = lastHeight else { return }
        panel.setFrameOrigin(origin(forHeight: height))
    }

    private var lastHeight: Double?

    private func origin(forHeight height: Double) -> CGPoint {
        let size = CGSize(width: CardLayout.width, height: height)
        let screen = (panel?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        guard let face = FaceWindowController.shared.frame else {
            // No face to attach to: the old bottom-right corner.
            return CGPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)
        }
        return CardLayout.attachedOrigin(
            faceFrame: face, cardSize: size, visibleFrame: screen)
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

        return panel
    }
}
