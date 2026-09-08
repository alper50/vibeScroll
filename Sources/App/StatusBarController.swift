import AppKit
import VibeScrollCore

/// The menu bar item: a glyph plus a count, and a menu listing live sessions.
///
/// The title is the app's only always-visible surface, so it stays terse: a
/// count when agents are working, and an attention marker when one is blocked
/// on the user.
@MainActor
final class StatusBarController {
    static let shared = StatusBarController()

    private var item: NSStatusItem?
    private var latest: [AgentSession] = []

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "book.closed", accessibilityDescription: "vibeScroll")
        item.button?.imagePosition = .imageLeading
        self.item = item
        rebuildMenu()
    }

    func updateStatus(_ sessions: [AgentSession]) {
        latest = sessions
        let working = sessions.filter { $0.state == .working }.count
        let waiting = sessions.filter { $0.state == .waiting }.count

        guard let button = item?.button else { return }
        if waiting > 0 {
            button.title = " \(waiting)"
            // Orange reads as "you are blocking something" at a glance.
            button.contentTintColor = .systemOrange
        } else if working > 0 {
            button.title = " \(working)"
            button.contentTintColor = nil
        } else {
            button.title = ""
            button.contentTintColor = nil
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if latest.isEmpty {
            let empty = NSMenuItem(title: "No active agents", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for session in latest.prefix(10) {
                let title = TickerFormatter.line(for: session)
                let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                entry.isEnabled = false
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Clear sessions",
                                    action: #selector(clearSessions), keyEquivalent: ""))
            menu.items.last?.target = self
        }

        menu.addItem(.separator())
        let list = NSMenuItem(title: "Show all sessions\u{2026}",
                              action: #selector(openSessions), keyEquivalent: "")
        list.target = self
        list.isEnabled = !latest.isEmpty
        menu.addItem(list)

        let toggle = NSMenuItem(title: CardController.shared.enabled ? "Pause cards" : "Resume cards",
                                action: #selector(toggleCards), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        // The panel is ambient rather than dismissible-forever: hiding it is a
        // pause, and the next agent to start brings it back.
        let panel = NSMenuItem(title: "Hide panel", action: #selector(togglePanel), keyEquivalent: "")
        panel.target = self
        menu.addItem(panel)

        let settings = NSMenuItem(title: "Settings\u{2026}",
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit vibeScroll", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item?.menu = menu
    }

    @objc private func clearSessions() { AppDaemon.shared.clearSessions() }

    @objc private func openSessions() { CardController.shared.openSessions() }

    @objc private func togglePanel() { CardController.shared.togglePanel() }

    @objc private func toggleCards() {
        CardController.shared.enabled.toggle()
        rebuildMenu()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
