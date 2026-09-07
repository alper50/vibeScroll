import Foundation

/// Names and paths for the isolated checkout a queued task runs in.
///
/// Pure string work, kept out of the app layer for the same reason `EditorLink`
/// is: the rules break silently. A branch name with a space in it fails at
/// `git worktree add` — at 03:00, into a log nobody is reading.
///
/// A worktree *is* a branch, so nothing about git visibility is given up by
/// running out of one: `git log`, `git diff main..vibescroll/<slug>` and
/// `cherry-pick` all work from the main repository. The worktree only decides
/// where the files live while the agent works, which is what keeps a task from
/// ever touching the branch somebody left checked out.
public enum WorktreePlan {

    /// Everything a run needs to know about its checkout.
    public struct Plan: Equatable, Sendable {
        public let slug: String
        public let branch: String
        public let path: String

        public init(slug: String, branch: String, path: String) {
            self.slug = slug
            self.branch = branch
            self.path = path
        }
    }

    /// Characters that survive into a slug. Deliberately narrow: this ends up
    /// in a git ref and a directory name, and every character outside this set
    /// is a rule to remember somewhere else.
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")

    /// Letters that `folding(.diacriticInsensitive)` does not reduce to ASCII.
    /// Turkish is spelled out because it is the language prompts get written in
    /// here, and "yap-land-r" is not a directory name anyone wants to read.
    private static let transliterations: [Character: String] = [
        "ı": "i", "İ": "i", "ğ": "g", "Ğ": "g", "ş": "s", "Ş": "s",
        "ç": "c", "Ç": "c", "ö": "o", "Ö": "o", "ü": "u", "Ü": "u",
        "ø": "o", "Ø": "o", "å": "a", "Å": "a", "æ": "ae", "Æ": "ae", "ß": "ss",
    ]

    /// A short, readable, filesystem- and git-safe form of a prompt.
    ///
    /// Empty input, or input with nothing left after filtering (an emoji-only
    /// prompt, say), yields `"task"` rather than an empty string — an empty
    /// component would produce a branch named `vibescroll/` , which git rejects.
    public static func slug(from text: String, limit: Int = 32) -> String {
        var mapped = ""
        for character in text {
            mapped += transliterations[character] ?? String(character)
        }
        let folded = mapped.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .lowercased()

        var out = ""
        var pendingDash = false
        for character in folded {
            if allowed.contains(character) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(character)
                if out.count >= limit { break }
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "task" : out
    }

    /// Branch for a task. The `vibescroll/` prefix keeps queued work in its own
    /// namespace, so `git branch --list 'vibescroll/*'` is the whole inventory
    /// and nothing collides with a branch a person made.
    public static func branch(slug: String) -> String { "vibescroll/\(slug)" }

    /// Directory name: project first, so a listing of the worktree root sorts by
    /// project rather than by whatever the task happened to be about.
    public static func directoryName(projectPath: String, slug: String) -> String {
        let project = Self.slug(from: ProjectPath.displayName(projectPath), limit: 24)
        return "\(project)-\(slug)"
    }

    /// The full plan for one task.
    ///
    /// `uniqueSuffix` (the task id) is appended to the slug so two tasks with
    /// the same prompt — a retry, or a duplicated line — cannot collide on a
    /// branch name that already exists.
    public static func plan(
        projectPath: String, prompt: String, uniqueSuffix: String, worktreeRoot: String
    ) -> Plan {
        let base = slug(from: prompt)
        let suffix = slug(from: uniqueSuffix, limit: 6)
        let full = "\(base)-\(suffix)"
        return Plan(
            slug: full,
            branch: branch(slug: full),
            path: (worktreeRoot as NSString)
                .appendingPathComponent(directoryName(projectPath: projectPath, slug: full))
        )
    }
}
