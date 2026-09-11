import SwiftUI
import UniformTypeIdentifiers
import VibeScrollCore

struct SettingsView: View {
    /// Tagged so the setup checklist can send somebody to the tab that finishes
    /// the step it is describing.
    enum Tab: Hashable { case general, integrations, content, tasks }

    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(tab: $tab)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            IntegrationsSettingsView()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
                .tag(Tab.integrations)
            ContentSettingsView()
                .tabItem { Label("Content", systemImage: "books.vertical") }
                .tag(Tab.content)
            TasksSettingsView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(Tab.tasks)
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Binding var tab: SettingsView.Tab
    @ObservedObject private var cards = CardController.shared
    @AppStorage("vibescroll.pacing") private var pacing = Pacing.normal.rawValue

    /// Named presets rather than four raw sliders: the numbers only make sense
    /// in combination, and a user tuning them individually will produce either
    /// silence or a strobe.
    enum Pacing: String, CaseIterable, Identifiable {
        case calm, normal, eager
        var id: String { rawValue }
        var label: String { rawValue.capitalized }

        var policy: CardScheduler.Policy {
            switch self {
            case .calm:
                return .init(minimumDwell: 15, globalCooldown: 300, topicCooldown: 3600)
            case .normal:
                return .init(minimumDwell: 8, globalCooldown: 90, topicCooldown: 900)
            case .eager:
                return .init(minimumDwell: 4, globalCooldown: 30, topicCooldown: 300)
            }
        }
    }

    var body: some View {
        Form {
            SetupChecklist(tab: $tab)
            StartupSection()

            Section {
                Toggle("Show info cards", isOn: $cards.enabled)

                // Bound through a computed setter rather than `.onChange`,
                // which changed signature in macOS 14 — this works on 13 and
                // applies the policy in the same turn the value changes.
                Picker("Frequency", selection: Binding(
                    get: { pacing },
                    set: { newValue in
                        pacing = newValue
                        CardController.shared.apply(
                            policy: (Pacing(rawValue: newValue) ?? .normal).policy)
                    }
                )) {
                    ForEach(Pacing.allCases) { p in Text(p.label).tag(p.rawValue) }
                }
                .pickerStyle(.segmented)
                .disabled(!cards.enabled)
            } footer: {
                Text("Cards appear while an agent works, based on what it is doing. They never take focus, and stay until you dismiss them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FaceSection()
            SoundsSection()
            QuotaSection()
        }
        .formStyle(.grouped)
        .onAppear {
            CardController.shared.apply(policy: (Pacing(rawValue: pacing) ?? .normal).policy)
        }
    }
}

/// First-run guidance.
///
/// Launching a menu bar app produces no visible result — an icon joins fifteen
/// others — and the three things that make vibeScroll do anything all live
/// behind tabs. The checklist names them, shows which are already done, and
/// takes you to the one that is not. It goes away for good once dismissed.
struct SetupChecklist: View {
    @Binding var tab: SettingsView.Tab
    @AppStorage("vibescroll.setupDismissed") private var dismissed = false
    @ObservedObject private var content = ContentStore.shared
    @ObservedObject private var loginItem = LoginItem.shared
    /// Reading every agent's config is disk work, so it happens when the window
    /// appears or comes forward rather than on each redraw.
    @State private var anyHookInstalled = false

    var body: some View {
        if !dismissed {
            Section {
                step(done: anyHookInstalled,
                     title: "Connect your agents",
                     detail: "vibeScroll sees nothing at all until one agent's hooks are installed.",
                     jump: .integrations)
                step(done: content.count > 0,
                     title: "Point at a card backend",
                     detail: content.count > 0
                        ? "\(content.count) cards ready."
                        : "No cards yet. The default backend runs on this machine.",
                     jump: .content)
                step(done: loginItem.state.isOn,
                     title: "Start at login",
                     detail: "A menu bar app you have to remember to open is off exactly when it is needed.",
                     jump: nil)
            } header: {
                HStack {
                    Text("Setup")
                    Spacer()
                    Button("Dismiss") { dismissed = true }.font(.caption)
                }
            }
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                refresh()
            }
        }
    }

    private func refresh() {
        anyHookInstalled = AgentCatalog.all.contains { HookSetup.isInstalled($0.kind) }
    }

    private func step(
        done: Bool, title: String, detail: String, jump: SettingsView.Tab?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let jump, !done {
                Button("Open") { tab = jump }.font(.caption)
            }
        }
    }
}

/// The face's settings.
struct FaceSection: View {
    @ObservedObject private var cards = CardController.shared

    var body: some View {
        Section {
            Toggle("Keep the face on screen when nothing is running",
                   isOn: $cards.showsFaceWhenIdle)
            Toggle("Follow the pointer with its eyes",
                   isOn: $cards.followsPointer)
        } header: {
            Text("Face")
        } footer: {
            Text("The face shows what your agents are doing, how the week's quota is going, and how long you have been at it. Asleep it still says something \u{2014} that vibeScroll is running and nothing else is. The eyes only follow while the pointer is over the face, and cost nothing the rest of the time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Launch at login. Its own section because it is about the app rather than
/// about cards: a menu-bar daemon nobody remembers to start is off exactly when
/// it is needed.
struct StartupSection: View {
    @ObservedObject private var loginItem = LoginItem.shared

    var body: some View {
        Section {
            Toggle("Start at login", isOn: Binding(
                get: { loginItem.state.isOn },
                set: { loginItem.set($0) }
            ))
            .disabled(isBlocked)
        } footer: {
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        // The user can switch this off in System Settings behind our back, so
        // the displayed state is re-read rather than remembered.
        .onAppear { loginItem.refresh() }
    }

    private var isBlocked: Bool {
        switch loginItem.state {
        case .blockedByUser, .unavailable: return true
        case .on, .off: return false
        }
    }

    private var caption: String {
        switch loginItem.state {
        case .on:
            return "vibeScroll starts with your Mac."
        case .off:
            return "Agent events are queued to disk while vibeScroll is closed, so none are lost — but none are shown either."
        case .blockedByUser:
            return "Turned off in System Settings \u{203A} General \u{203A} Login Items. Re-enable it there."
        case .unavailable(let message):
            return message
        }
    }
}

// MARK: - Quota

/// The quota probe's switch and current reading.
///
/// The copy is deliberately blunt about what enabling this does. It is the only
/// feature that reads a credential and calls a provider, and a user should be
/// able to decide that from this screen without reading the source.
struct QuotaSection: View {
    @ObservedObject private var probe = UsageProbe.shared

    var body: some View {
        Section {
            Toggle("Track Claude quota", isOn: $probe.enabled)

            if probe.enabled {
                if let snapshot = probe.snapshot {
                    ForEach(snapshot.windows, id: \.kind) { window in
                        LabeledContent(window.label) { reading(window) }
                    }
                } else if let error = probe.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    Text("Checking\u{2026}").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Quota")
        } footer: {
            Text("Reads the sign-in Claude Code stores in your Keychain and asks Anthropic how much of your plan is left. Read-only, and off unless you turn it on. The endpoint is not a published API, so it can stop working without notice.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reading(_ window: QuotaWindow) -> some View {
        HStack(spacing: 8) {
            Text("\(window.percentUsed)% used")
                .monospacedDigit()
                .foregroundStyle(color(for: window))
            if let resetsAt = window.resetsAt {
                Text("resets \(resetsAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Colour follows the provider's own severity, not a threshold of ours —
    /// except exhaustion, which is unambiguous at any severity.
    private func color(for window: QuotaWindow) -> Color {
        if window.isExhausted { return .red }
        switch window.severity {
        case .critical: return .red
        case .warning: return .orange
        case .normal, .unknown: return .primary
        }
    }
}

// MARK: - Sounds

/// Independent alert sounds, each pickable from the system set or from a
/// file of the user's own.
struct SoundsSection: View {
    @ObservedObject private var sounds = SoundSettings.shared
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(SoundSettings.Event.allCases, id: \.self) { event in
                LabeledContent(event.title) { controls(for: event) }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Sounds")
        } footer: {
            Text("Played by vibeScroll itself, so alerts are heard even with notifications turned off — and regardless of Focus.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controls(for event: SoundSettings.Event) -> some View {
        let current = sounds.selection(for: event)
        HStack(spacing: 6) {
            Picker("", selection: binding(for: event)) {
                Text("None").tag(SoundSelection.silent)
                Divider()
                ForEach(sounds.availableSystemNames, id: \.self) { name in
                    Text(name).tag(SoundSelection.system(name))
                }
                // Ours, in their own group: `NSSound` resolves them the same
                // way, but they are not part of the set macOS ships and the
                // picker should not imply that they are.
                if !sounds.availableBundledNames.isEmpty {
                    Divider()
                    ForEach(sounds.availableBundledNames, id: \.self) { name in
                        Text(name).tag(SoundSelection.bundled(name))
                    }
                }
                // The current custom file is listed so the picker can display
                // it; without a matching tag SwiftUI would show a blank row.
                if current.isCustom {
                    Divider()
                    Text(current.displayName).tag(current)
                }
            }
            .labelsHidden()
            .frame(width: 132)

            Button {
                sounds.preview(current)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(current == .silent)
            .help("Preview")

            Button("Choose\u{2026}") { chooseFile(for: event) }
                .help("Use your own sound file")
        }
    }

    private func binding(for event: SoundSettings.Event) -> Binding<SoundSelection> {
        Binding(
            get: { sounds.selection(for: event) },
            set: { sounds.set($0, for: event) }
        )
    }

    private func chooseFile(for event: SoundSettings.Event) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use Sound"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try sounds.importSound(from: url, for: event)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Integrations

struct IntegrationsSettingsView: View {
    @State private var installed: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            List(AgentCatalog.all) { agent in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.displayName)
                        if let note = agent.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(installed.contains(agent.id) ? "Remove" : "Install") {
                        toggle(agent.kind)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .onAppear(perform: refresh)
        // The settings window is reused rather than rebuilt, so `onAppear` runs
        // once and never again. Anything that changed an agent's config in the
        // meantime — a reinstall to a new path, an edit by hand, another
        // machine syncing the file — would leave this list describing the past.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        installed = Set(AgentCatalog.all.filter { HookSetup.isInstalled($0.kind) }.map(\.id))
    }

    private func toggle(_ kind: AgentKind) {
        error = nil
        do {
            if installed.contains(kind.rawValue) {
                try HookSetup.uninstall(kind)
            } else {
                try HookSetup.install(kind)
            }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}

// MARK: - Content

struct ContentSettingsView: View {
    @ObservedObject private var store = ContentStore.shared
    @State private var draftURL = ""

    var body: some View {
        Form {
            Section("Backend") {
                TextField("Origin", text: $draftURL, prompt: Text("http://127.0.0.1:8787"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save & refresh") { store.setBaseURL(draftURL) }
                    Button("Refresh now") { Task { await store.refresh(force: true) } }
                }
            }

            Section("Catalogue") {
                LabeledContent("Cards", value: "\(store.count)")
                LabeledContent("Version", value: store.version.isEmpty ? "—" : store.version)
                LabeledContent("Last refresh") {
                    Text(store.lastRefreshAt.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "never")
                }
                if let error = store.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Button("Preview a card") {
                    // Pull from whatever the catalogue has, so the preview shows
                    // real content rather than a placeholder that hides an empty
                    // or misconfigured backend.
                    guard let card = store.byCategory.values.flatMap({ $0 }).randomElement() else { return }
                    CardController.shared.preview(card)
                }
                .disabled(store.count == 0)
            }
        }
        .formStyle(.grouped)
        .onAppear { draftURL = store.baseURL.absoluteString }
    }
}
