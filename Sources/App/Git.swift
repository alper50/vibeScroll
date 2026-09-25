import Foundation
import VibeScrollCore

/// The git calls the task runner needs.
///
/// Shelling out rather than linking a library: these are four commands, the
/// binary is always present on a Mac with developer tools, and it honours the
/// user's own git configuration — including the identity a commit is made
/// under, which vibeScroll has no business inventing.
enum Git {
    private static let executable = "/usr/bin/git"

    struct Output {
        let status: Int32
        let text: String
        var succeeded: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: String) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch {
            return Output(status: -1, text: error.localizedDescription)
        }
        // Read before waiting: a command with a lot to say can fill the pipe and
        // deadlock a process that is waited on first.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            text: String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True when `path` is a repository that has something to branch from. A
    /// fresh `git init` with no commit has no HEAD, so there is nothing to make
    /// a worktree out of.
    static func hasCommits(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return run(["rev-parse", "--verify", "HEAD"], in: path).succeeded
    }

    /// Creates the task's isolated checkout on a new branch, starting from
    /// `base` — the project's current HEAD, or the branch of the task this one
    /// builds on.
    static func addWorktree(project: String, path: String, branch: String,
                            base: String = "HEAD") -> Bool {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        return run(["worktree", "add", "-b", branch, path, base], in: project).succeeded
    }

    /// The commit `HEAD` points at in `directory`, or `nil`.
    static func head(in directory: String) -> String? {
        let out = run(["rev-parse", "HEAD"], in: directory)
        return out.succeeded && !out.text.isEmpty ? out.text : nil
    }

    /// What changed in a worktree since `base`.
    ///
    /// Committed work is read from history; work left uncommitted — a failed
    /// run, deliberately not committed — from the working tree, with files git
    /// is not yet tracking listed without counts, since `--numstat` cannot see
    /// them and staging them just to count would change the checkout.
    static func changedFiles(in worktree: String, since base: String?,
                             committed: Bool) -> [TaskReport.ChangedFile] {
        if committed, let base {
            return TaskReport.parseNumstat(
                run(["diff", "--numstat", "\(base)..HEAD"], in: worktree).text)
        }
        let tracked = TaskReport.parseNumstat(run(["diff", "--numstat", "HEAD"], in: worktree).text)
        let untracked = run(["ls-files", "--others", "--exclude-standard"], in: worktree).text
            .split(whereSeparator: \.isNewline)
            .map { TaskReport.ChangedFile(path: String($0), added: nil, removed: nil) }
        return tracked + untracked
    }

    enum CommitResult {
        case committed
        /// The agent finished without changing anything. Not a failure: some
        /// tasks are investigations whose answer is "nothing to do".
        case nothingToCommit
        case failed(String)
    }

    static func commitAll(worktree: String, message: String) -> CommitResult {
        let status = run(["status", "--porcelain"], in: worktree)
        guard status.succeeded else { return .failed(status.text) }
        guard !status.text.isEmpty else { return .nothingToCommit }

        let staged = run(["add", "-A"], in: worktree)
        guard staged.succeeded else { return .failed(staged.text) }

        // No identity is passed: the commit is made under whatever the user's
        // own git configuration says, so it is not disguised as someone else.
        let commit = run(["commit", "-m", message], in: worktree)
        return commit.succeeded ? .committed : .failed(commit.text)
    }
}

// MARK: - Cleanup

extension Git {
    enum WorktreeRemoval: Equatable {
        case removed
        /// Git refused because the checkout holds changes that exist nowhere
        /// else. Surfaced rather than forced: this is a night of work.
        case dirty
        case failed(String)
    }

    /// Removes a task's checkout.
    ///
    /// Deliberately without `--force` unless asked. `git worktree remove`
    /// already refuses to delete a checkout with modified or untracked files,
    /// which is exactly the line worth drawing — and a better guard than
    /// anything reimplemented here, because git knows what is expendable.
    static func removeWorktree(project: String, path: String, force: Bool) -> WorktreeRemoval {
        guard FileManager.default.fileExists(atPath: path) else {
            // Directory already gone by hand; clear git's stale bookkeeping so
            // the branch is no longer considered checked out.
            run(["worktree", "prune"], in: project)
            return .removed
        }
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(path)

        let out = run(arguments, in: project)
        if out.succeeded { return .removed }
        // "contains modified or untracked files, use --force to delete it"
        if out.text.contains("--force") { return .dirty }
        return .failed(out.text)
    }

    /// Deletes a task's branch only when it carries no work of its own.
    ///
    /// `-d`, never `-D`: lowercase refuses a branch holding unmerged commits,
    /// so a finished task's work survives while the branch left by a task that
    /// changed nothing is cleared away. The distinction is free, and it is the
    /// right one.
    ///
    /// Must run after the worktree is gone — git will not delete a branch that
    /// is still checked out somewhere.
    @discardableResult
    static func deleteBranchIfEmpty(project: String, branch: String) -> Bool {
        run(["branch", "-d", branch], in: project).succeeded
    }
}
