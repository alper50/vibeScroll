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
    static let hasLaunchedKey = "vibescroll.hasLaunched"

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
        FaceModel.shared.start()
        // Before the controller's first sync: it asks this which style to
        // draw, and the notch has to be measured by then.
        DisplayStyleStore.shared.start()
        CardController.shared.start()
        // A task still marked `running` is left over from a crash or a force
        // quit; its process is long gone, and leaving the row would block the
        // queue forever.
        TaskQueueStore.shared.reconcileAfterRestart()
        // Must come after the reconcile above: a leftover `running` row would
        // otherwise hold the gate shut on the first tick.
        TaskRunner.shared.start()

        // Hooks embed this binary's absolute path, so moving the app silently
        // disconnects every one of them. Repaired before anything else runs, so
        // the first event after a move is already reaching us.
        let repaired = HookSetup.repairMovedInstalls()
        if !repaired.isEmpty {
            let names = repaired.map(TickerFormatter.agentLabel(for:)).joined(separator: ", ")
            NotificationManager.shared.notify(
                title: String(localized: "vibeScroll hooks updated"),
                body: String(localized: "The app moved, so hooks for \(names) now point at its new location."))
        }

        // Nothing visible happens when a menu bar app launches — an icon joins
        // fifteen others. On the very first run the settings window is opened
        // so there is something to read and somewhere to start.
        //
        // On a Mac with a notch the style question comes first, once, and the
        // settings follow it on a first run — two windows at once is two
        // things to read and no order to read them in. Someone who has used
        // the app before gets only the question.
        let firstRun = !UserDefaults.standard.bool(forKey: Self.hasLaunchedKey)
        UserDefaults.standard.set(true, forKey: Self.hasLaunchedKey)
        if DisplayStyleStore.shared.shouldAsk {
            DisplayStyleChooserController.shared.show {
                if firstRun { SettingsWindowController.shared.show() }
            }
        } else if firstRun {
            SettingsWindowController.shared.show()
        }
    }

    /// Opening the app again — Spotlight, Finder, the Dock — while it is
    /// already running. In the notch style there is no menu bar icon, so this
    /// is how a panel hidden by hand comes back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        CardController.shared.reveal()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Remove the socket file so the next launch binds cleanly and hooks
        // fall back to the disk queue in the meantime.
        AppDaemon.shared.stopServer()
    }
}
