import Foundation
import VibeScrollCore

/// Finds every file where Claude Code, Codex and Cursor keep permissions that
/// outlive a session, reads them, and takes single entries out on request.
///
/// Only saved permissions exist on disk. What an agent was allowed "for this
/// session" lives inside that agent's process and ends with it — nothing here
/// can see it, and the screen says so rather than implying a complete list.
@MainActor
final class PermissionStore: ObservableObject {
    static let shared = PermissionStore()

    struct FileGroup: Identifiable {
        let source: PermissionSource
        let entries: [PermissionEntry]
        var id: String { source.path }
    }

    @Published private(set) var groups: [FileGroup] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastError: String?
    /// The file as it was before the last removal, so it can be put back.
    @Published private(set) var undo: (path: String, data: Data, summary: String)?
    /// What the last hand-picked folder turned up, so choosing one always
    /// says something — including that there was nothing to find.
    @Published private(set) var folderResult: (folder: String, files: Int)?
    /// A scan asked for while one was running. Run once the current one ends
    /// rather than dropped, which is what made a folder choice look ignored.
    private var rescanRequested = false
    private var awaitingFolder: String?

    /// Folders added by hand, for projects vibeScroll has not otherwise seen.
    private static let extraFoldersKey = "vibescroll.permissions.extraFolders"
    var extraFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.extraFoldersKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.extraFoldersKey) }
    }

    var allEntries: [PermissionEntry] { groups.flatMap(\.entries) }

    // MARK: - Scanning

    func refresh() {
        guard !scanning else {
            rescanRequested = true
            return
        }
        scanning = true
        let known = liveProjectRoots()
        let picked = extraFolders
        Task.detached(priority: .userInitiated) {
            let roots = Self.projectRoots(adding: known, searching: picked)
            let groups = Self.scan(projectRoots: roots)
            await MainActor.run {
                self.groups = groups
                self.scanning = false
                if let folder = self.awaitingFolder {
                    self.awaitingFolder = nil
                    let files = groups.filter {
                        $0.source.projectRoot.map { ProjectPath.contains(root: folder, path: $0) } ?? false
                    }.count
                    self.folderResult = (folder, files)
                }
                if self.rescanRequested {
                    self.rescanRequested = false
                    self.refresh()
                }
            }
        }
    }

    /// Projects known from this app's own state: live sessions' workspaces,
    /// the task queue's projects, and folders added by hand.
    private func liveProjectRoots() -> [String] {
        AppDaemon.shared.sessions.compactMap { $0.workspace ?? $0.project }
            + TaskQueueStore.shared.queue.tasks.map(\.projectPath)
            + extraFolders
    }

    /// Every project worth looking in. No single source has them all: Claude
    /// Code's own list misses projects opened from the editor, its transcript
    /// folders miss projects it never ran in, and a project can carry a
    /// `.claude`, `.cursor` or `.codex` folder from a template without any
    /// agent having been started there — so all of them are used.
    /// `searching` are folders picked by hand: looked inside as well as at,
    /// since the folder somebody picks is as often the one holding their
    /// projects as a project itself.
    private nonisolated static func projectRoots(adding known: [String],
                                                 searching picked: [String]) -> [String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let usual = ["Desktop", "Documents", "Developer", "Projects", "projects", "Code", "code",
                     "src", "dev", "repos", "workspace", "GitHub"].map { home + "/" + $0 }
        var roots = known + claudeKnownProjects() + decodedTranscriptFolders()
            + discoverProjects(under: usual + picked)
        var seen = Set<String>()
        roots = roots.map(ProjectPath.normalize).filter { seen.insert($0).inserted }
        return roots.filter {
            var directory: ObjCBool = false
            return fm.fileExists(atPath: $0, isDirectory: &directory) && directory.boolValue
                && $0 != NSHomeDirectory()
        }
        .sorted()
    }

    /// The project paths Claude Code keeps in `~/.claude.json`. Only the keys
    /// of `projects` are read — the file also holds account details that have
    /// no business being touched here.
    private nonisolated static func claudeKnownProjects() -> [String] {
        let path = NSHomeDirectory() + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: Any] else { return [] }
        return Array(projects.keys)
    }

    /// Every folder Claude Code has kept a transcript for, traced back to the
    /// directory it was named after.
    private nonisolated static func decodedTranscriptFolders() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: NSHomeDirectory() + "/.claude/projects")) ?? []
        return names.filter { !$0.hasPrefix("-private-") }.compactMap { name in
            ProjectPath.decodeTranscriptFolder(name) { directory in
                (try? fm.contentsOfDirectory(atPath: directory)) ?? []
            }
        }
    }

    /// Folders under `bases` that hold an agent's config folder. Bounded in
    /// depth and in how many folders it opens, so a large home folder costs a
    /// moment rather than a minute.
    private nonisolated static func discoverProjects(under bases: [String]) -> [String] {
        let fm = FileManager.default
        let skipped: Set<String> = ["node_modules", "Library", "Pods", "DerivedData", "build",
                                    "dist", "vendor", "target", "venv"]
        let markers: Set<String> = [".claude", ".cursor", ".codex"]
        var found: [String] = []
        var budget = 20_000

        func walk(_ directory: String, depth: Int) {
            guard budget > 0, let children = try? fm.contentsOfDirectory(atPath: directory) else { return }
            budget -= 1
            if !markers.isDisjoint(with: children) { found.append(directory) }
            guard depth < 4 else { return }
            for child in children where !child.hasPrefix(".") && !skipped.contains(child) {
                let path = directory + "/" + child
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    walk(path, depth: depth + 1)
                }
            }
        }
        for base in bases where fm.fileExists(atPath: base) { walk(base, depth: 0) }
        return found
    }

    private nonisolated static func scan(projectRoots: [String]) -> [FileGroup] {
        let home = NSHomeDirectory()
        var sources: [PermissionSource] = [
            .init(path: "/Library/Application Support/ClaudeCode/managed-settings.json",
                  agent: .claude, scope: .managed, format: .claudeSettings),
            .init(path: home + "/.claude/settings.json", agent: .claude, scope: .user,
                  format: .claudeSettings),
            .init(path: home + "/.codex/config.toml", agent: .codex, scope: .user,
                  format: .codexConfig),
            .init(path: home + "/.cursor/permissions.json", agent: .cursor, scope: .user,
                  format: .cursorPermissions),
            .init(path: home + "/.cursor/cli-config.json", agent: .cursor, scope: .user,
                  format: .cursorCLI),
        ]
        sources += rulesFiles(in: home + "/.codex/rules").map {
            .init(path: $0, agent: .codex, scope: .user, format: .codexRules)
        }

        for root in projectRoots {
            let candidates: [(String, PermissionAgent, PermissionSource.Format)] = [
                (".claude/settings.json", .claude, .claudeSettings),
                (".claude/settings.local.json", .claude, .claudeSettings),
                (".cursor/permissions.json", .cursor, .cursorPermissions),
                (".cursor/cli.json", .cursor, .cursorCLI),
                (".codex/config.toml", .codex, .codexConfig),
            ]
            for (relative, agent, format) in candidates {
                let path = (root as NSString).appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: path) else { continue }
                sources.append(.init(path: path, agent: agent,
                                     scope: .project(root: root, shared: isShared(relative, in: root)),
                                     format: format))
            }
            for path in rulesFiles(in: (root as NSString).appendingPathComponent(".codex/rules")) {
                let relative = String(path.dropFirst(root.count + 1))
                sources.append(.init(path: path, agent: .codex,
                                     scope: .project(root: root, shared: isShared(relative, in: root)),
                                     format: .codexRules))
            }
        }

        return sources.compactMap { source in
            guard let data = FileManager.default.contents(atPath: source.path) else { return nil }
            let entries = parse(data, source: source)
            // A file with nothing in it worth listing is left out, so the
            // screen shows grants rather than a directory of empty files.
            return entries.isEmpty ? nil : FileGroup(source: source, entries: entries)
        }
    }

    private nonisolated static func parse(_ data: Data, source: PermissionSource) -> [PermissionEntry] {
        switch source.format {
        case .claudeSettings, .cursorPermissions, .cursorCLI:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return []
            }
            switch source.format {
            case .claudeSettings:    return PermissionParser.claude(settings: json, source: source)
            case .cursorPermissions: return PermissionParser.cursorPermissions(json: json, source: source)
            default:                 return PermissionParser.cursorCLI(json: json, source: source)
            }
        case .codexConfig:
            return PermissionParser.codexConfig(toml: String(decoding: data, as: UTF8.self), source: source)
        case .codexRules:
            return PermissionParser.codexRules(text: String(decoding: data, as: UTF8.self), source: source)
        }
    }

    private nonisolated static func rulesFiles(in directory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory))?
            .filter { $0.hasSuffix(".rules") }
            .sorted()
            .map { (directory as NSString).appendingPathComponent($0) } ?? []
    }

    /// A project file git tracks is the team's, not yours: editing it here
    /// would quietly change a file everyone shares.
    private nonisolated static func isShared(_ relativePath: String, in root: String) -> Bool {
        Git.run(["ls-files", "--error-unmatch", relativePath], in: root).succeeded
    }

    // MARK: - Removing

    /// Takes one entry out of its file. Refuses rather than guesses: a file
    /// that no longer parses, or no longer holds the entry, is left alone.
    func remove(_ entry: PermissionEntry) {
        lastError = nil
        guard entry.isRemovable else { return }
        let path = entry.source.path
        guard let original = FileManager.default.contents(atPath: path) else {
            lastError = String(localized: "\(path) could not be read.")
            return
        }

        let updated: Data?
        switch entry.location {
        case .jsonArray:
            guard let json = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                lastError = String(localized: "\(path) is not valid JSON; nothing was changed.")
                return
            }
            updated = PermissionEditor.removing(entry, from: json).flatMap {
                try? JSONSerialization.data(withJSONObject: $0,
                                            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            }
        case .text:
            updated = PermissionEditor.removing(entry, fromText: String(decoding: original, as: UTF8.self))
                .map { Data($0.utf8) }
        case .fixed:
            updated = nil
        }

        guard let updated else {
            lastError = String(localized: "The file changed since it was read; nothing was removed. Refresh and try again.")
            refresh()
            return
        }
        do {
            try updated.write(to: URL(fileURLWithPath: path), options: .atomic)
            undo = (path, original, entry.summary)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Puts the file back exactly as it was before the last removal.
    func undoLastRemoval() {
        guard let undo else { return }
        do {
            try undo.data.write(to: URL(fileURLWithPath: undo.path), options: .atomic)
            self.undo = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Adds a folder to every scan from now on, and scans it now. Picking one
    /// already on the list still rescans and reports — the answer is what
    /// was asked for, not whether the list changed.
    func addFolder(_ path: String) {
        let normalized = ProjectPath.normalize(path)
        if !extraFolders.contains(normalized) { extraFolders.append(normalized) }
        folderResult = nil
        awaitingFolder = normalized
        objectWillChange.send()
        refresh()
    }

    func removeFolder(_ path: String) {
        extraFolders.removeAll { $0 == path }
        if folderResult?.folder == path { folderResult = nil }
        objectWillChange.send()
        refresh()
    }
}
