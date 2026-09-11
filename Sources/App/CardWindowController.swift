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

    /// Drives the emergence inside the SwiftUI content, the same split the face
    /// uses: the window's alpha carries the fade, this carries the growth.
    let presentation = FacePresentation()

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
        if wasHidden {
            panel.alphaValue = prefersReducedMotion ? 1 : 0
            presentation.shown = prefersReducedMotion
        }
        panel.orderFrontRegardless()

        guard !prefersReducedMotion else {
            panel.alphaValue = 1
            presentation.shown = true
            return
        }
        // One turn of the run loop before the growth starts, so SwiftUI has
        // drawn the small state to animate away from.
        if wasHidden {
            Task { @MainActor [weak self] in self?.presentation.shown = true }
        } else {
            presentation.shown = true
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        wantsVisible = false
        presentation.shown = false
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

    /// Travels with the face during a drag. A plain translation: the card's
    /// place relative to the face has not changed, so there is nothing to
    /// work out again.
    func move(byX dx: CGFloat, y dy: CGFloat) {
        guard let panel, panel.isVisible else { return }
        panel.setFrameOrigin(CGPoint(x: panel.frame.origin.x + dx,
                                     y: panel.frame.origin.y + dy))
    }

    /// Recomputes where the card belongs. Used when it opens, not while the
    /// face is being dragged.
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
