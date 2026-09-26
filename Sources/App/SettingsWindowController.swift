import AppKit
import SwiftUI

/// Owns the settings window directly instead of going through SwiftUI's
/// `Settings` scene.
///
/// The scene is opened by sending `showSettingsWindow:` up the responder chain,
/// and in an `LSUIElement` app launched from a status-bar menu that chain is
/// effectively empty — the action resolves to nothing and the click appears to
/// do nothing at all. Hosting the same `SettingsView` in an `NSWindow` we own
/// removes the responder chain from the equation entirely.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        // An accessory app can own key windows, but only once it is active —
        // without this the window appears behind whatever the user was in.
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "vibeScroll Settings")
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        // Closing settings must not deallocate the window: the next click would
        // then message a freed object.
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        window.makeKeyAndOrderFront(nil)
    }
}
