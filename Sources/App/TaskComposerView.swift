import AppKit
import SwiftUI
import VibeScrollCore

/// Writing a task for an agent that will run with nobody to ask.
///
/// The one prompt box this replaces asked for everything at once and got
/// back a sentence. Split into the parts an unattended run actually needs —
/// where, what, and how to tell it is finished — each with a hint of what a
/// good answer looks like, the prompt that reaches the agent is the one it
/// needed rather than the one that was quickest to type.
struct TaskComposerView: View {
    @ObservedObject private var store = TaskQueueStore.shared

    @State private var projectPath = ""
    @State private var title = ""
    @State private var instructions = ""
    @State private var doneWhen = ""
    /// A task id, or empty for the project's current HEAD.
    @State private var basedOn = ""

    /// The last folder a task was added for, so the next task in the same
    /// project — the common case — does not start with a folder picker.
    @AppStorage("vibescroll.task.lastProject") private var lastProject = ""

    var body: some View {
        Section {
            projectRow

            TextField("Title", text: $title,
                      prompt: Text("Add a dark mode toggle to Settings"))
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions").font(.system(size: 11, weight: .medium))
                PlaceholderEditor(
                    text: $instructions,
                    placeholder: String(localized: "What to change and where. Name the files or screens involved, and anything to leave alone."),
                    minHeight: 84)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Done when").font(.system(size: 11, weight: .medium))
                PlaceholderEditor(
                    text: $doneWhen,
                    placeholder: String(localized: "e.g. swift test passes, and the toggle appears under General."),
                    minHeight: 40)
            }

            if !bases.isEmpty {
                Picker("Build on", selection: $basedOn) {
                    Text("The project as it is now").tag("")
                    ForEach(bases) { task in
                        Text(verbatim: "\u{21B3} \(task.displayTitle)").tag(task.id)
                    }
                }
            }
        } header: {
            Text("Add a task")
        } footer: {
            footer
        }
        .onAppear { if projectPath.isEmpty { projectPath = lastProject } }
    }

    // MARK: - Project

    private var projectRow: some View {
        HStack {
            if projectPath.isEmpty {
                Text("No project chosen").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: ProjectPath.displayName(projectPath))
                    Text(verbatim: projectPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Menu("Project") {
                ForEach(recentProjects, id: \.self) { path in
                    Button(ProjectPath.displayName(path)) { select(project: path) }
                }
                if !recentProjects.isEmpty { Divider() }
                Button("Choose\u{2026}") { chooseProject() }
            }
            .fixedSize()
        }
    }

    /// Folders tasks have been queued for, most recent first — the projects
    /// somebody actually uses this with, without a separate list to keep.
    private var recentProjects: [String] {
        var seen = Set<String>()
        return store.queue.tasks
            .sorted { $0.createdAt > $1.createdAt }
            .map(\.projectPath)
            .filter { seen.insert(ProjectPath.normalize($0)).inserted }
            .prefix(6)
            .map { $0 }
    }

    private func select(project path: String) {
        projectPath = path
        // A base from another project is not somewhere this one can start.
        basedOn = ""
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { select(project: url.path) }
    }

    private var bases: [QueuedTask] {
        projectPath.isEmpty ? [] : store.queue.buildableBases(for: projectPath)
    }

    // MARK: - Adding

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !trimmed(instructions).isEmpty && trimmed(doneWhen).isEmpty {
                // Advice, not a rule: some tasks are open-ended on purpose.
                Label("Without a finish line the agent stops wherever it decides it is done.",
                      systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Runs in its own branch; nothing is pushed or merged.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Add to queue", action: add)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canAdd)
            }
        }
    }

    private var canAdd: Bool {
        !trimmed(projectPath).isEmpty && !trimmed(instructions).isEmpty
    }

    private func add() {
        guard canAdd else { return }
        store.add(projectPath: projectPath, prompt: instructions, title: title,
                  doneWhen: doneWhen, basedOn: basedOn.isEmpty ? nil : basedOn)
        lastProject = projectPath
        // The project is kept — the next task is usually in the same place —
        // but not the chain, which is a decision to make each time.
        title = ""
        instructions = ""
        doneWhen = ""
        basedOn = ""
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A `TextEditor` with a hint while it is empty, which the plain one lacks —
/// and without it a blank box gives no idea what belongs in it.
private struct PlaceholderEditor: View {
    @Binding var text: String
    let placeholder: String
    let minHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(4)
            if text.isEmpty {
                Text(verbatim: placeholder)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
    }
}
