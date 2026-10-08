import AppKit
import SwiftUI
import VibeScrollCore

/// `vibescroll notch <dir>` — draws the notch island in each of its states and
/// writes them out as PNGs.
///
/// `vibescroll notch --hold [closed|sessions|card|tasks]` instead puts it in one
/// state with sample data and leaves it there, writing nothing, so its cost
/// can be read off `top` without the snapshots in the way.
///
/// Like `vibescroll face`, a development affordance: whether the island sits
/// flush with the camera and reads at a glance cannot be judged from a test.
/// It uses the real window on the real notch, fed sample sessions and a sample
/// card, so what lands in the files is what the app draws.
@MainActor
enum NotchPreviewCLI {
    static func run(arguments: [String]) -> Never {
        let hold = arguments.first == "--hold" ? (arguments.dropFirst().first ?? "closed") : nil
        let dir = URL(fileURLWithPath: arguments.first ?? FileManager.default.currentDirectoryPath)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = NotchPreviewDelegate(directory: dir, hold: hold)
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

@MainActor
private final class NotchPreviewDelegate: NSObject, NSApplicationDelegate {
    let directory: URL
    let hold: String?
    init(directory: URL, hold: String?) { self.directory = directory; self.hold = hold }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await walk() }
    }

    private func walk() async {
        let store = DisplayStyleStore.shared
        store.start()
        guard store.notchAvailable else {
            FileHandle.standardError.write(Data("No notched display connected.\n".utf8))
            exit(1)
        }
        store.preferred = .notch
        let notch = NotchWindowController.shared
        let now = Date()

        if let hold {
            await self.hold(hold, notch: notch, now: now)
            return
        }

        // Nothing running: the right wing is folded away.
        CardController.shared.displayStyleChanged()
        await pause(1.2)
        save("0-idle")

        let sessions = [
            AgentSession(id: "a", agentKind: .claude, project: "/Users/me/Desktop/vibescrol",
                         state: .working, source: .hook, updatedAt: now,
                         stateSince: now.addingTimeInterval(-340), tokens: 182_000),
            AgentSession(id: "b", agentKind: .codex, project: "/Users/me/code/RuView",
                         state: .waiting, source: .hook, updatedAt: now,
                         stateSince: now.addingTimeInterval(-45)),
        ]
        FaceModel.shared.update(sessions: sessions)
        CardController.shared.consider(sessions: sessions, now: now)
        await pause(1.0)
        save("1-collapsed")
        // No quota reading yet: a waiting card's dot rides on the agent icon.
        notch.model.inbox.arrived(cardID: "early-card", alreadyVisible: false)
        await pause(0.6)
        save("1b-agent-dot")
        notch.model.inbox.viewed()

        UsageProbe.shared.showSample(QuotaSnapshot(
            provider: "claude", displayName: "Claude",
            windows: [QuotaWindow(kind: "session", percentUsed: 62, severity: .normal,
                                  resetsAt: now.addingTimeInterval(7200), isActive: true)],
            checkedAt: now))
        await pause(0.8)
        save("2-with-quota")

        // Quota but nobody working: the case where the ring once slid behind
        // the camera. Opened, since that is where it showed.
        let idle = sessions.map {
            AgentSession(id: $0.id, agentKind: $0.agentKind, project: $0.project,
                         state: .idle, source: .hook, updatedAt: now)
        }
        CardController.shared.consider(sessions: idle, now: now)
        notch.expand(page: .sessions)
        await pause(1.0)
        save("2b-quota-no-agents-open")
        notch.collapse()
        await pause(0.8)

        // Idle with the face told not to stay out: the ring goes too, and a
        // card still waiting does not bring it back. Bare notch both times.
        let keep = CardController.shared.showsFaceWhenIdle
        CardController.shared.showsFaceWhenIdle = false
        notch.model.inbox.arrived(cardID: "idle-card", alreadyVisible: false)
        await pause(0.8)
        save("2c-idle-unread")
        notch.model.inbox.viewed()
        await pause(0.8)
        save("2d-idle")
        CardController.shared.showsFaceWhenIdle = keep

        CardController.shared.consider(sessions: sessions, now: now)
        await pause(0.8)

        let card = InfoCard(
            id: "preview-card", category: .breakingBad,
            title: "Heisenberg's hat was a costume department accident",
            body: "The pork-pie hat was picked to hide Bryan Cranston's shaved head between takes. It became the most recognisable prop of the show.")
        CardController.shared.preview(card)
        notch.collapse()
        await pause(0.8)
        notch.model.inbox.arrived(cardID: card.id, alreadyVisible: false)
        await pause(0.6)
        save("3-collapsed-badge")

        // The opening, frame by frame.
        notch.expand()
        for step in 1...5 {
            await pause(0.09)
            save("4-opening-\(step)")
        }
        await pause(4.0)   // lets the typewriter finish
        save("5-open-card")

        notch.select(.sessions)
        await pause(0.12)
        save("6-sliding")
        await pause(0.8)
        save("7-open-sessions")

        notch.select(.tasks)
        await pause(0.8)
        save("8-open-tasks")

        exit(0)
    }


    /// One state, sample data, no snapshots, until killed.
    private func hold(_ state: String, notch: NotchWindowController, now: Date) async {
        CardController.shared.consider(sessions: [
            AgentSession(id: "a", agentKind: .claude, project: "/Users/me/Desktop/vibescrol",
                         state: .working, source: .hook, updatedAt: now,
                         stateSince: now.addingTimeInterval(-340), tokens: 182_000),
        ], now: now)
        UsageProbe.shared.showSample(QuotaSnapshot(
            provider: "claude", displayName: "Claude",
            windows: [QuotaWindow(kind: "session", percentUsed: 62, severity: .normal,
                                  resetsAt: nil, isActive: true)],
            checkedAt: now))
        switch state {
        case "sessions": notch.expand(page: .sessions)
        case "tasks": notch.expand(page: .tasks)
        case "card":
            CardController.shared.preview(InfoCard(
                id: "hold", category: .breakingBad, title: "A sample card",
                body: "Held open so its cost can be measured."))
        default: break
        }
        print("holding \(state) — pid \(ProcessInfo.processInfo.processIdentifier)")
    }

    private func save(_ name: String) {
        guard let rep = NotchWindowController.shared.snapshot(),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
