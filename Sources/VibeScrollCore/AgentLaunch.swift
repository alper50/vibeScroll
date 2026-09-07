import Foundation

/// Builds the command line that runs one queued task.
///
/// Split out per agent from the start, even though Claude Code is the only one
/// implemented: the queue is worth having for any agent on a subscription
/// window, and the alternative — Claude's flags inlined into the runner — is
/// the version that has to be untangled later. An agent with no headless mode
/// returns `nil` and its tasks simply never launch, rather than launching
/// something that will not work.
public enum AgentLaunch {

    public struct Plan: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
        public let workingDirectory: String

        public init(executable: String, arguments: [String], workingDirectory: String) {
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
        }
    }

    /// Flags that would defeat the queue if they ever crept in, kept here as a
    /// named list because each one is quiet in a different way:
    /// `--bare` and `--safe-mode` disable hooks, which is the only reason a
    /// running task is visible at all, and `--no-session-persistence` skips the
    /// transcript the token count is read from.
    public static let forbiddenFlags: Set<String> = [
        "--bare", "--safe-mode", "--no-session-persistence",
    ]

    /// The command for one run.
    ///
    /// No `-w`: the worktree is created beforehand with plain git (see
    /// `WorktreePlan`) and passed as the working directory, so isolation works
    /// the same way for every agent instead of depending on a Claude-only flag.
    ///
    /// Argument order is the one verified against Claude Code 2.1.226: the
    /// prompt is positional and follows `-p` directly.
    public static func plan(
        for kind: AgentKind,
        executable: String,
        prompt: String,
        sessionId: String,
        workingDirectory: String,
        systemPromptSuffix: String?
    ) -> Plan? {
        switch kind {
        case .claude:
            var arguments = [
                "-p", prompt,
                "--session-id", sessionId,
                "--output-format", "json",
                "--permission-mode", "bypassPermissions",
            ]
            if let suffix = systemPromptSuffix?.trimmingCharacters(in: .whitespacesAndNewlines),
               !suffix.isEmpty {
                arguments.append(contentsOf: ["--append-system-prompt", suffix])
            }
            return Plan(executable: executable, arguments: arguments,
                        workingDirectory: workingDirectory)

        // Everything else: no verified headless invocation yet. Returning nil
        // keeps a task queued rather than spending a window on a guess.
        case .codex, .gemini, .cursor, .windsurf, .opencode, .antigravity,
             .copilot, .kiroCLI, .droid, .pi, .grok, .cli, .unknown:
            return nil
        }
    }

    /// The default instruction appended to every queued prompt.
    ///
    /// A queued task runs with nobody to answer it. Without this an agent that
    /// meets an ambiguity does the reasonable interactive thing — asks, and ends
    /// its turn — which spends the window and produces nothing. Writing the
    /// blocker to a file instead leaves something to read in the morning.
    public static let defaultSystemPromptSuffix = """
        You are running unattended from a queue: there is nobody to answer a \
        question, and asking one ends the run with nothing done. If a choice is \
        ambiguous, pick the most conventional option and note it. If you truly \
        cannot proceed, write what is blocking you to BLOCKED.md and stop. Do \
        not commit, push, merge, or change branches — the work is collected for \
        you afterwards.
        """
}
