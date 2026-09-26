import AppKit
import SwiftUI
import VibeScrollCore

/// Settings → Permissions: what each agent may do without asking, and where
/// that was written down.
///
/// Answers the question a permission prompt leaves behind — "did I just allow
/// that for good?" — by listing every saved grant, in words, next to the file
/// that holds it, with a way to take personal ones back.
struct PermissionsSettingsView: View {
    @ObservedObject private var store = PermissionStore.shared
    @State private var pendingRemoval: PermissionEntry?

    var body: some View {
        Form {
            overview
            ForEach(PermissionAgent.allCases, id: \.self) { agent in
                agentSection(agent)
            }
            Section {
                ForEach(store.extraFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(verbatim: ProjectPath.displayName(folder))
                        Text(verbatim: folder).font(.caption).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { store.removeFolder(folder) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Stop scanning this folder")
                    }
                }
                HStack {
                    Button("Scan another project folder\u{2026}", action: chooseFolder)
                    if store.scanning { ProgressView().controlSize(.small) }
                }
                if let result = store.folderResult {
                    Label(result.files == 0
                          ? String(localized: "No saved permissions in “\(ProjectPath.displayName(result.folder))”. Anything allowed there was for a session only.")
                          : String(localized: "Found \(result.files) permission files in “\(ProjectPath.displayName(result.folder))” — listed above."),
                          systemImage: result.files == 0 ? "checkmark.circle" : "arrow.up.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Projects Claude Code has worked in, live sessions, queued tasks, and projects with an agent folder under Desktop, Documents and the usual code folders are scanned automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
        .confirmationDialog(
            "Remove this permission?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { entry in
            Button("Remove", role: .destructive) { store.remove(entry) }
        } message: { entry in
            let warning = entry.source.isSharedWithTeam
                ? "\n\n" + String(localized: "This file is tracked by git. Removing the rule changes the file in your working copy; once you commit it, it changes for everyone who has the repository.")
                : ""
            Text(verbatim: "\(entry.summary)\n\n\(entry.raw)\n\n\(entry.source.path)\(warning)")
        }
    }

    // MARK: - Overview

    private var overview: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                let entries = store.allEntries
                let grants = entries.filter { $0.effect == .allow || $0.effect == .directory }.count
                let risky = entries.filter { $0.risk == .high }.count
                VStack(alignment: .leading, spacing: 2) {
                    Text(grants == 0 ? String(localized: "No saved permissions")
                                     : String(localized: "\(grants) saved permissions"))
                        .font(.system(size: 13, weight: .semibold))
                    if risky > 0 {
                        Text("\(risky) worth a second look")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if store.scanning { ProgressView().controlSize(.small) }
                Button("Refresh") { store.refresh() }.disabled(store.scanning)
            }

            if let undo = store.undo {
                HStack {
                    Text("Removed: \(undo.summary)").font(.caption).lineLimit(1)
                    Spacer()
                    Button("Undo") { store.undoLastRemoval() }.font(.caption)
                }
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    Text("Only permissions saved to disk are listed. Approvals given “for this session” live inside that agent and end when the session does — they cannot be seen from outside, and need no removing.")
                    Text("Folder access at the macOS level — Desktop, Documents, Downloads — is granted to the editor or terminal, not to the agent, and is managed by macOS.")
                }
                .foregroundStyle(.secondary)
                Button("Open Files and Folders in System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
            .font(.caption)
        }
    }

    // MARK: - Per agent

    @ViewBuilder
    private func agentSection(_ agent: PermissionAgent) -> some View {
        let groups = store.groups.filter { $0.source.agent == agent }
        Section {
            if groups.isEmpty {
                Text("Nothing saved.").foregroundStyle(.secondary).font(.system(size: 12))
            }
            ForEach(groups) { group in
                fileHeader(group.source)
                ForEach(group.entries.sorted(by: order)) { entry in
                    row(entry)
                }
            }
        } header: {
            Text(verbatim: agent.label)
        } footer: {
            if let note = note(for: agent) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Riskiest first, then grants before limits.
    private func order(_ a: PermissionEntry, _ b: PermissionEntry) -> Bool {
        if a.risk != b.risk { return a.risk > b.risk }
        return rank(a.effect) < rank(b.effect)
    }

    private func rank(_ effect: PermissionEntry.Effect) -> Int {
        switch effect {
        case .setting: return 0
        case .allow: return 1
        case .directory: return 2
        case .ask: return 3
        case .deny: return 4
        }
    }

    private func note(for agent: PermissionAgent) -> String? {
        switch agent {
        case .claude:
            return String(localized: "Inside Claude Code, /permissions shows the same rules and can edit them too.")
        case .cursor:
            return String(localized: "Commands added to the allowlist from Cursor's own settings screen are kept inside Cursor, not in these files, and only show there.")
        case .codex:
            let hasConfig = store.groups.contains { $0.source.format == .codexConfig }
            return hasConfig
                ? String(localized: "config.toml is shown but not edited from here; change it in the file itself.")
                : nil
        }
    }

    private func fileHeader(_ source: PermissionSource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon(for: source.scope)).foregroundStyle(.secondary).font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(scopeLabel(source.scope)).font(.system(size: 11, weight: .semibold))
                Text(verbatim: abbreviated(source.path))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Show") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)])
            }
            .controlSize(.small)
        }
        .padding(.top, 4)
    }

    private func scopeLabel(_ scope: PermissionSource.Scope) -> String {
        switch scope {
        case .managed:
            return String(localized: "Managed by your organization — read only")
        case .user:
            return String(localized: "Your settings — every project")
        case .project(let root, let shared):
            let name = ProjectPath.displayName(root)
            return shared
                ? String(localized: "\(name) — tracked by git, shared with anyone who has the repository")
                : String(localized: "\(name) — your personal settings for this project")
        }
    }

    private func icon(for scope: PermissionSource.Scope) -> String {
        switch scope {
        case .managed: return "building.2"
        case .user: return "person"
        case .project(_, let shared): return shared ? "person.2" : "folder"
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Rows

    private func row(_ entry: PermissionEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(for: entry.effect))
                .foregroundStyle(color(for: entry.effect))
                .font(.system(size: 11))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: entry.summary).font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.risk == .high {
                        Text("Check")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }
                }
                Text(verbatim: entry.raw)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 6)
            if entry.isRemovable {
                Button("Remove") { pendingRemoval = entry }
                    .controlSize(.small)
            }
        }
        .padding(.leading, 12)
    }

    private func symbol(for effect: PermissionEntry.Effect) -> String {
        switch effect {
        case .allow: return "checkmark.circle.fill"
        case .ask: return "questionmark.circle.fill"
        case .deny: return "xmark.octagon.fill"
        case .directory: return "folder.fill"
        case .setting: return "gearshape.fill"
        }
    }

    private func color(for effect: PermissionEntry.Effect) -> Color {
        switch effect {
        case .allow: return .green
        case .ask: return .yellow
        case .deny: return .red
        case .directory: return .blue
        case .setting: return .gray
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { store.addFolder(url.path) }
    }
}
