import AppKit
import SwiftUI
import VibeScrollCore

/// Settings → Tasks: the queue, and one button that runs a task now.
///
/// Nothing on this screen starts anything by itself yet. The automatic gate is
/// deliberately the last thing added: the mechanism is worth proving with a
/// person pressing the button before it is trusted to run at 03:00.
struct TasksSettingsView: View {
    @ObservedObject private var store = TaskQueueStore.shared
    @ObservedObject private var runner = TaskRunner.shared

    @State private var projectPath = ""
    @State private var prompt = ""
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
            composer
            gateStatus
            taskList
            agentSection
            settings
        }
        .formStyle(.grouped)
    }

    // MARK: - Adding

    private var composer: some View {
        Section("Add a task") {
            HStack {
                TextField("Project folder", text: $projectPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose\u{2026}") { chooseProject() }
            }
            TextField("What should the agent do?", text: $prompt, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Add to queue") {
                    store.add(projectPath: projectPath, prompt: prompt)
                    prompt = ""
                }
                .disabled(!canAdd)
            }
        }
    }

    private var canAdd: Bool {
        !projectPath.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { projectPath = url.path }
    }

    // MARK: - Why nothing is running

    /// A queue that sits still without saying why reads as broken, so the gate's
    /// own reason is shown verbatim rather than summarised as "waiting".
    private var gateStatus: some View {
        Section("Status") {
            LabeledContent("Queue") {
                Text(Self.describe(runner.currentDecision()))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if let error = runner.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    static func describe(_ decision: TaskRunway.Decision) -> String {
        switch decision {
        case .launch:
            return "Ready to run"
        case .hold(let reason):
            return describe(reason)
        }
    }

    static func describe(_ hold: TaskRunway.Hold) -> String {
        switch hold {
        case .queueEmpty:
            return "Nothing queued"
        case .taskAlreadyRunning:
            return "A task is running"
        case .dailyLimitReached(let started, let limit):
            return "Daily limit reached (\(started)/\(limit))"
        case .quotaUnavailable:
            return "No quota reading \u{2014} turn on the quota check in General"
        case .quotaStale(let age):
            return "Quota reading is \(Int(age / 60)) min old"
        case .sessionWindowSpent(let percent):
            return "Session window \(percent)% spent"
        case .weeklyReserve(let percent, let reserve):
            return "Weekly at \(percent)%, holding the last \(100 - reserve)%"
        case .aheadOfPace(let used, let elapsed):
            return "Weekly \(used)% spent, \(elapsed)% of the week gone"
        case .agentBusy:
            return "Your own agent is working"
        case .userActive:
            return "You are at the keyboard"
        case .cooldown(let remaining):
            return "Cooling down (\(Int(remaining))s)"
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
        var parts = ["Removed \(report.removed)"]
        // Named rather than counted silently: a bulk button is the worst place
        // to discard something that exists nowhere else, so the ones it left
        // behind have to be visible.
        if report.blocked > 0 {
            parts.append("\(report.blocked) kept \u{2014} uncommitted work, delete individually")
        }
        if report.failed > 0 { parts.append("\(report.failed) failed") }
        return parts.joined(separator: ". ") + "."
    }

    private func row(_ task: QueuedTask) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(for: task.status)).frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(TaskRunner.firstLine(task.prompt)).font(.system(size: 12))
                HStack(spacing: 4) {
                    Text(ProjectPath.displayName(task.projectPath))
                    if let failure = task.failure {
                        Text("\u{00B7}")
                        Text(TaskRunner.label(for: failure))
                    }
                    if let branch = task.worktreeName {
                        Text("\u{00B7}")
                        Text("vibescroll/\(branch)").monospaced()
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                if needsConfirmation.contains(task.id) {
                    Text("This checkout has uncommitted changes. Deleting discards them.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if task.status == .pending {
                Button("Run now") { runner.run(task) }
                    .disabled(runner.runningTaskID != nil)
            }
            if task.status == .failed || task.status == .parked {
                Button("Retry") { store.requeue(id: task.id) }
            }
            deleteButton(task)
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

    private func color(for status: QueuedTask.Status) -> Color {
        switch status {
        case .pending:   return .secondary
        case .running:   return .accentColor
        case .succeeded: return .green
        case .failed:    return .orange
        case .parked:    return .yellow
        case .cancelled: return .gray.opacity(0.5)
        }
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
                ? "Using this path."
                : "Not an executable file \u{2014} tasks cannot start."
        }
        guard let found = TaskRunner.discoverExecutable() else {
            // The common install ships inside the VS Code extension and is not
            // on PATH, so "not found" is worth explaining rather than asserting.
            return "Claude Code was not found automatically. Set its path here \u{2014} it usually lives inside the VS Code extension, not on your PATH."
        }
        return "Found automatically: \(found)"
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
