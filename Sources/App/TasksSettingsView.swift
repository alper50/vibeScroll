import AppKit
import SwiftUI
import VibeScrollCore

/// Settings → Tasks: writing tasks, the queue, and what each run left behind.
///
/// Composing lives in `TaskComposerView` and each row in `TaskRowView`; this
/// view holds the queue together — the gate's status, the list, clean-up, and
/// the settings that apply to every task.
struct TasksSettingsView: View {
    @ObservedObject private var store = TaskQueueStore.shared
    @ObservedObject private var runner = TaskRunner.shared

    /// Tasks whose checkout git refused to delete because it holds uncommitted
    /// work. Membership turns the row's trash button into a deliberate second
    /// action rather than a repeat of the first.
    @State private var needsConfirmation: Set<String> = []
    @State private var cleanupReport: TaskQueueStore.CleanupReport?
    @State private var removalError: String?
    /// Empty means "find it automatically". Stored under the key the runner
    /// reads, so the two can never drift apart.
    @AppStorage(TaskRunner.executableKey) private var executableOverride = ""

    var body: some View {
        Form {
            TaskComposerView()
            gateStatus
            taskList
            agentSection
            settings
        }
        .formStyle(.grouped)
    }

    // MARK: - Why nothing is running

    /// A queue that sits still without saying why reads as broken, so the gate's
    /// own reason is shown verbatim rather than summarised as "waiting".
    private var gateStatus: some View {
        Section {
            Toggle("Run queued tasks automatically", isOn: $runner.autopilot)
            LabeledContent("Queue") {
                Text(runner.currentDecision().summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if let error = runner.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Off, the queue only runs what you start by hand. On, it checks once a minute and starts the next task when there is spare quota, no agent of yours is working, and you have been away from the keyboard \u{2014} the reason it is holding is shown above. It never pushes or merges; each task is left on its own branch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The queue

    private var taskList: some View {
        Section {
            if store.queue.tasks.isEmpty {
                Text("No tasks yet.").foregroundStyle(.secondary)
            } else {
                ForEach(store.queue.tasks.sorted { $0.order < $1.order }) { task in
                    row(task)
                }
            }
        } header: {
            HStack {
                Text("Queue")
                Spacer()
                let finished = store.queue.finished.count
                if finished > 0 {
                    Button("Clean up finished (\(finished))") {
                        cleanupReport = store.cleanUpFinished()
                        needsConfirmation.removeAll()
                    }
                    .font(.caption)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if let report = cleanupReport, !report.isEmpty {
                    Text(Self.describe(report)).font(.caption).foregroundStyle(.secondary)
                }
                if let removalError {
                    Text(removalError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    static func describe(_ report: TaskQueueStore.CleanupReport) -> String {
        var parts = [String(localized: "Removed \(report.removed)")]
        // Named rather than counted silently: a bulk button is the worst place
        // to discard something that exists nowhere else, so the ones it left
        // behind have to be visible.
        if report.blocked > 0 {
            parts.append(String(localized: "\(report.blocked) kept \u{2014} uncommitted work, delete individually"))
        }
        if report.failed > 0 { parts.append(String(localized: "\(report.failed) failed")) }
        return parts.joined(separator: ". ") + "."
    }

    private func row(_ task: QueuedTask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TaskRowView(task: task, queue: store.queue) {
                if task.status == .pending {
                    Button("Run now") { runner.run(task) }
                        .disabled(runner.runningTaskID != nil || !store.queue.readiness(of: task).isReady)
                        .help(store.queue.readiness(of: task).isReady
                              ? "" : "Waits for the task it builds on")
                }
                if task.status == .failed || task.status == .parked {
                    Button("Retry") { store.requeue(id: task.id) }
                }
                deleteButton(task)
            }
            if needsConfirmation.contains(task.id) {
                Text("This checkout has uncommitted changes. Deleting discards them.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.leading, 18)
            }
        }
    }

    /// One button, two meanings. The first press asks git to remove the
    /// checkout; git refuses when that would discard work, and the button
    /// becomes an explicit "delete anyway" rather than a press that quietly
    /// did nothing.
    @ViewBuilder
    private func deleteButton(_ task: QueuedTask) -> some View {
        let confirming = needsConfirmation.contains(task.id)
        Button {
            removalError = nil
            switch store.remove(id: task.id, force: confirming) {
            case .removed:
                needsConfirmation.remove(task.id)
            case .blockedByUncommittedWork:
                needsConfirmation.insert(task.id)
            case .failed(let reason):
                removalError = reason
            }
        } label: {
            if confirming {
                Text("Delete anyway").font(.caption)
            } else {
                Image(systemName: "trash")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(confirming ? Color.orange : Color.secondary)
        .disabled(task.status == .running)
        .help(confirming ? "Discards the uncommitted changes in this checkout"
                         : "Remove the task, its checkout and its log")
    }

    // MARK: - Which binary

    /// The runner's "set its path in Settings" message pointed at a field that
    /// did not exist. This is it.
    private var agentSection: some View {
        Section {
            HStack {
                TextField("Automatic", text: $executableOverride)
                    .textFieldStyle(.roundedBorder)
                Button("Choose\u{2026}") { chooseExecutable() }
                if !executableOverride.isEmpty {
                    Button("Reset") { executableOverride = "" }
                }
            }
        } header: {
            Text("Claude Code binary")
        } footer: {
            Text(executableCaption)
                .font(.caption)
                .foregroundStyle(executableIsUsable ? Color.secondary : Color.orange)
        }
    }

    private var executableIsUsable: Bool { TaskRunner.discoverExecutable() != nil }

    private var executableCaption: String {
        if !executableOverride.isEmpty {
            return FileManager.default.isExecutableFile(atPath: executableOverride)
                ? String(localized: "Using this path.")
                : String(localized: "Not an executable file \u{2014} tasks cannot start.")
        }
        guard let found = TaskRunner.discoverExecutable() else {
            // The common install ships inside the VS Code extension and is not
            // on PATH, so "not found" is worth explaining rather than asserting.
            return String(localized: "Claude Code was not found automatically. Set its path here \u{2014} it usually lives inside the VS Code extension, not on your PATH.")
        }
        return String(localized: "Found automatically: \(found)")
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // The extension lives under ~/.vscode, which the panel hides by default.
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        let extensions = NSHomeDirectory() + "/.vscode/extensions"
        if FileManager.default.fileExists(atPath: extensions) {
            panel.directoryURL = URL(fileURLWithPath: extensions)
        }
        if panel.runModal() == .OK, let url = panel.url { executableOverride = url.path }
    }

    // MARK: - Knobs

    private var settings: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unattended instructions").font(.system(size: 11, weight: .medium))
                TextEditor(text: Binding(
                    get: { runner.systemPromptSuffix },
                    set: { TaskRunner.shared.systemPromptSuffix = $0 }
                ))
                .font(.system(size: 11))
                .frame(height: 70)
                .border(Color.primary.opacity(0.1))
            }
        } footer: {
            Text("Appended to every queued prompt. A queued agent has nobody to answer it, so a question ends the run having done nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
