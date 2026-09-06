import SwiftUI
import UniformTypeIdentifiers
import VibeScrollCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            IntegrationsSettingsView()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            ContentSettingsView()
                .tabItem { Label("Content", systemImage: "books.vertical") }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
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

            SoundsSection()
            QuotaSection()
        }
        .formStyle(.grouped)
        .onAppear {
            CardController.shared.apply(policy: (Pacing(rawValue: pacing) ?? .normal).policy)
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
