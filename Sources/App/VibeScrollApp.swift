import AppKit
import SwiftUI
import VibeScrollCore

/// The menu bar app. Runs as an accessory (no Dock icon, no main window): the
/// card panel and the status item are the entire surface.
struct VibeScrollApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    // SwiftUI requires at least one scene, but this app has no scene-managed
    // windows: the card is an NSPanel and settings is an NSWindow, both owned
    // by their controllers (see SettingsWindowController for why).
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: menu bar only. Set before anything can present a window,
        // or macOS briefly shows a Dock icon.
        NSApp.setActivationPolicy(.accessory)

        NotificationManager.shared.requestAuthorization()
        ContentStore.shared.start()
        StatusBarController.shared.install()
        AppDaemon.shared.start()
        // No-op unless the user turned the quota probe on: it reaches a
        // provider and touches the Keychain, so it stays opt-in.
        UsageProbe.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Remove the socket file so the next launch binds cleanly and hooks
        // fall back to the disk queue in the meantime.
        AppDaemon.shared.stopServer()
    }
}
