import AppKit
import SwiftUI
import VibeScrollCore

/// Hosts the face in its own small borderless panel.
///
/// Separate from the card panel because the two have opposite lifetimes: the
/// face is continuous and the card is occasional. Sharing a window meant the
/// card's size dictated the face's, and dismissing one had to argue about the
/// other.
///
/// Non-activating, like the card panel — an ambient face that steals focus from
/// the editor is worse than no face.
@MainActor
final class FaceWindowController: NSObject {
    static let shared = FaceWindowController()

    /// Drives the entrance and exit inside the SwiftUI content. The window's
    /// own alpha carries the fade; this carries the scale, because animating a
    /// borderless panel's frame makes SwiftUI re-lay-out on every step.
    let presentation = FacePresentation()

    private var panel: NSPanel?
    /// What the caller last asked for. The exit animation checks it before
    /// actually ordering the window out: a session arriving mid-fade would
    /// otherwise leave a window that is on screen, opaque, and hidden.
    private var wantsVisible = false

    private static let fade: TimeInterval = 0.22
    private static let originKey = "vibescroll.faceOrigin"
    private static var size: NSSize {
        NSSize(width: CardLayout.faceWindowWidth, height: CardLayout.faceWindowHeight)
    }

    /// Frame of the face on screen, for the card to hang off. `nil` when the
    /// face is not up, in which case the card has nothing to attach to and
    /// falls back to its own corner.
    var frame: CGRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    func setVisible(_ visible: Bool) {
        wantsVisible = visible
        visible ? present() : dismiss()
    }

    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel

        let wasHidden = !panel.isVisible
        if wasHidden {
            panel.setFrame(NSRect(origin: savedOrigin(on: panel), size: Self.size), display: true)
            panel.alphaValue = prefersReducedMotion ? 1 : 0
            presentation.shown = prefersReducedMotion
        }
        panel.orderFrontRegardless()

        guard !prefersReducedMotion else {
            presentation.shown = true
            panel.alphaValue = 1
            return
        }
        // One turn of the run loop before the scale starts, so SwiftUI has
        // rendered the small state to animate away from. Setting it in the same
        // pass as `orderFront` batches the two together and the spring is lost.
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

    private func dismiss() {
        guard let panel, panel.isVisible else { return }
        presentation.shown = false

        guard !prefersReducedMotion else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fade
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                // Asked back on screen while it was fading: leave it alone.
                guard let self, !self.wantsVisible else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Dragging is handled in SwiftUI instead, so a click on the face can be
        // told from a drag of it. Leaving this on meant AppKit consumed the
        // mouse down before the view ever saw it.
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // No shadow: the window is mostly transparent, and AppKit would draw
        // the shadow around the square frame rather than the visible circle.
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: FaceWindowView())
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        return panel
    }

    /// Nudges the window, in SwiftUI's coordinates: its y grows downward and a
    /// window origin's grows up.
    ///
    /// The card is moved by the same delta rather than recomputing where it
    /// belongs, and nothing is written to disk until the drag ends. Doing both
    /// on every step — a settings write and a re-derived origin, per frame,
    /// with two vibrancy windows to move — is what made dragging with the card
    /// open feel like it was catching.
    /// Where the pointer sat inside the window when the drag began, in screen
    /// space. `nil` between drags.
    ///
    /// Dragging by the gesture's own `translation` does not work here, and this
    /// is why: `translation` is measured against the view, and the view is
    /// inside the window we are moving. Move the window a step and the view
    /// travels with it, so the pointer has barely moved *relative to the view*
    /// and the next translation comes back near zero. The window stalls, the
    /// pointer runs ahead, the following event over-corrects, and the whole
    /// thing judders and crawls away from the hand holding it.
    ///
    /// Screen coordinates have no such loop. Remember the grab offset once,
    /// then put the window wherever the pointer is minus that offset. It is
    /// absolute, so a dropped frame costs nothing — the next event lands the
    /// window exactly where it belongs rather than one delta further along.
    private var dragGrab: CGSize?

    /// Mouse down on the face.
    func beginDrag() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        dragGrab = CGSize(width: mouse.x - panel.frame.origin.x,
                          height: mouse.y - panel.frame.origin.y)
    }

    /// How far the pointer has travelled since the grab. The view cannot work
    /// this out for itself: while the window is following, the gesture's own
    /// translation stays near zero however far the hand has gone.
    var dragDistance: CGFloat {
        guard let panel, let grab = dragGrab else { return 0 }
        let mouse = NSEvent.mouseLocation
        return hypot(mouse.x - grab.width - panel.frame.origin.x,
                     mouse.y - grab.height - panel.frame.origin.y)
    }

    /// Puts the face back under the pointer, and takes the card with it.
    func dragToPointer() {
        guard let panel, let grab = dragGrab else { return }
        let mouse = NSEvent.mouseLocation
        let origin = CGPoint(x: mouse.x - grab.width, y: mouse.y - grab.height)
        let delta = CGSize(width: origin.x - panel.frame.origin.x,
                           height: origin.y - panel.frame.origin.y)
        guard delta != .zero else { return }
        panel.setFrameOrigin(origin)
        // A plain translation, not a recomputed attachment point: the card is
        // riding along, and re-deriving its corner every frame was the other
        // half of what made this drag feel heavy.
        CardWindowController.shared.move(byX: delta.width, y: delta.height)
    }

    /// Called when a drag finishes.
    func persistOrigin() {
        dragGrab = nil
        guard let panel else { return }
        let origin = panel.frame.origin
        UserDefaults.standard.set([origin.x, origin.y], forKey: Self.originKey)
    }

    /// Where the user last left it, or the bottom-right corner on first run.
    private func savedOrigin(on panel: NSPanel) -> CGPoint {
        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [CGFloat],
           saved.count == 2 {
            return CGPoint(x: saved[0], y: saved[1])
        }
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return .zero }
        return CGPoint(x: visible.maxX - Self.size.width - 16, y: visible.minY + 16)
    }
}

/// Whether the face is meant to be on screen, for the content to animate
/// against. Separate from the window's own visibility: the window is still up
/// while the exit plays.
@MainActor
final class FacePresentation: ObservableObject {
    @Published var shown = false
}
