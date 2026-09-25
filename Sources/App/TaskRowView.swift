import AppKit
import SwiftUI
import VibeScrollCore

/// One task in the queue: a line when folded, and what it did when opened.
///
/// "What did it do?" used to have no answer on this screen — the agent's
/// summary went into a notification and was gone once dismissed, and what
/// changed meant opening a terminal in the worktree. Everything a run leaves
/// behind is now kept on the task (`TaskReport`) and read here.
struct TaskRowView<Actions: View>: View {
    let task: QueuedTask
    let queue: TaskQueue
    @ViewBuilder var actions: () -> Actions

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded { details }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Folded

    private var header: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide details" : "Show details")

            Circle().fill(statusColor).frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: task.displayTitle).font(.system(size: 12)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(verbatim: ProjectPath.displayName(task.projectPath))
                    Text(verbatim: "\u{00B7}")
                    Text(statusLabel)
                    if let report = task.report, !report.changedFiles.isEmpty {
                        Text(verbatim: "\u{00B7}")
                        if report.changedFiles.count == 1 {
                            Text("1 file")
                        } else {
                            Text("\(report.changedFiles.count) files")
                        }
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                if let chain = chainLine {
                    Text(chain)
                        .font(.system(size: 10))
                        .foregroundStyle(chainIsBlocked ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
            actions()
        }
    }

    // MARK: - Opened

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            block(String(localized: "Instructions"), task.prompt)
            if let doneWhen = task.doneWhen { block(String(localized: "Done when"), doneWhen) }

            if let report = task.report {
                if let blocker = report.blocker {
                    // First, and in its own colour: when there is one it is
                    // the most important thing on the row.
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Stopped and wrote BLOCKED.md", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(verbatim: blocker)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
                }
                if let summary = report.summary, !summary.isEmpty {
                    block(String(localized: "What the agent says it did"), summary)
                }
                files(report)
                stats(report)
            } else if task.status == .running {
                Text("Running \u{2014} the report appears here when it finishes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            buttons
        }
        .padding(.leading, 18)
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(verbatim: text).font(.system(size: 11)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The files, largest change first, capped: a row is not a diff viewer,
    /// and the worktree is one click away for the rest.
    @ViewBuilder
    private func files(_ report: TaskReport) -> some View {
        if report.changedFiles.isEmpty {
            Text(report.committed ? "Committed, but nothing changed." : "Nothing changed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            let shown = report.changedFiles
                .sorted { ($0.added ?? 0) + ($0.removed ?? 0) > ($1.added ?? 0) + ($1.removed ?? 0) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(report.committed ? "Committed" : "Left uncommitted")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text(verbatim: "+\(report.totalAdded)").foregroundStyle(.green)
                    Text(verbatim: "\u{2212}\(report.totalRemoved)").foregroundStyle(.red)
                }
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                ForEach(shown.prefix(8), id: \.path) { file in
                    HStack(spacing: 6) {
                        Text(verbatim: file.path).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let added = file.added, let removed = file.removed {
                            Text(verbatim: "+\(added)").foregroundStyle(.green)
                            Text(verbatim: "\u{2212}\(removed)").foregroundStyle(.red)
                        } else {
                            Text("new").foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
                if shown.count > 8 {
                    Text("and \(shown.count - 8) more").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func stats(_ report: TaskReport) -> some View {
        HStack(spacing: 10) {
            if let seconds = report.durationSeconds {
                Label(Self.duration(seconds), systemImage: "clock")
            }
            let tokens = report.inputTokens + report.outputTokens
            if tokens > 0 {
                Label(TickerFormatter.tokens(tokens), systemImage: "text.word.spacing")
            }
            if let branch = task.worktreeName {
                Label(WorktreePlan.branch(slug: branch), systemImage: "arrow.triangle.branch")
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: seconds) ?? ""
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if let path = task.worktreePath, FileManager.default.fileExists(atPath: path) {
                if let editor = TaskLinks.editorURL(for: path) {
                    Button("Open in editor") { NSWorkspace.shared.open(editor) }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            let log = TaskRunner.logPath(for: task.id)
            if FileManager.default.fileExists(atPath: log) {
                Button("Open log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
            }
        }
        .controlSize(.small)
    }

    // MARK: - Status

    private var statusLabel: String {
        switch task.status {
        case .pending:   return String(localized: "Queued")
        case .running:   return String(localized: "Running")
        case .succeeded: return String(localized: "Finished")
        case .cancelled: return String(localized: "Cancelled")
        case .parked:    return String(localized: "Parked after rate limits")
        case .failed:    return task.failure.map(TaskRunner.label(for:)) ?? String(localized: "failed")
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .pending:   return .secondary
        case .running:   return .accentColor
        case .succeeded: return task.report?.blocker == nil ? .green : .orange
        case .failed:    return .orange
        case .parked:    return .yellow
        case .cancelled: return .gray.opacity(0.5)
        }
    }

    /// "↳ after …" for a task that builds on another, saying whether it is
    /// waiting, ready, or stuck behind one that failed.
    private var chainLine: String? {
        guard let parentID = task.basedOn, let parent = queue.task(id: parentID) else { return nil }
        let name = parent.displayTitle
        switch queue.readiness(of: task) {
        case .ready:
            return String(localized: "\u{21B3} builds on “\(name)”")
        case .waiting:
            return String(localized: "\u{21B3} waits for “\(name)”")
        case .blocked:
            return String(localized: "\u{21B3} blocked: “\(name)” did not succeed \u{2014} retry it to continue")
        }
    }

    private var chainIsBlocked: Bool {
        if case .blocked = queue.readiness(of: task) { return true }
        return false
    }
}

/// Where a task's checkout can be opened.
enum TaskLinks {
    /// The first installed editor that can open a folder by URL — VS Code,
    /// then its forks. Same safe link the session list uses, so a click can
    /// never reload a window somebody is working in.
    @MainActor
    static func editorURL(for path: String) -> URL? {
        let preferred = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                         "com.exafunction.windsurf", "com.microsoft.VSCodeInsiders"]
        for bundleID in preferred
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            if let url = EditorLink.url(bundleID: bundleID, projectPath: path) { return url }
        }
        return nil
    }
}
