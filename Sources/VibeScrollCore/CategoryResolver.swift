import Foundation

/// Turns a raw tool signal (`toolName` + `toolTarget`) into a `TopicCategory`.
///
/// Pure string logic: no I/O, no wall-clock reads, no actor isolation, so every
/// rule below is directly unit-testable. Two stages, in this order:
///
///  1. **Target first.** A shell command or file path is far more specific than
///     a tool name — `Bash` alone means "running something", but `Bash` +
///     `git commit` means version control. Whenever the target yields a topic,
///     it wins.
///  2. **Tool name fallback.** Keyword matching over the tool name, which works
///     across agents because they converge on the same vocabulary (Claude's
///     `Read`/`Edit`/`Bash`/`Grep`, Cursor's `read_file`/`edit_file`/
///     `run_terminal_cmd`/`codebase_search`, and so on).
public enum CategoryResolver {

    /// Resolves a topic, or `nil` when there is no usable signal at all. `nil`
    /// is deliberately distinct from `.generic`: the caller keeps the session's
    /// previous topic rather than resetting it, so the card doesn't flicker
    /// between tool calls that happen to carry no arguments.
    public static func category(toolName: String?, target: String?) -> TopicCategory? {
        if let target, let hit = fromTarget(target) { return hit }
        guard let toolName, !toolName.isEmpty else { return nil }
        return fromToolName(toolName)
    }

    /// Reduces a set of sessions to the single topic worth showing a card for:
    /// the most recently changed topic among sessions that are actually working.
    /// Waiting/done/idle sessions carry no live topic — the user's attention is
    /// elsewhere.
    public static func aggregate(_ sessions: [AgentSession]) -> TopicCategory? {
        sessions
            .filter { $0.state == .working && $0.topic != nil }
            .max { $0.topicSince < $1.topicSince }?
            .topic
    }

    // MARK: - Stage 1: the target

    /// Command prefixes and path shapes, checked before tool names.
    private static func fromTarget(_ raw: String) -> TopicCategory? {
        let t = raw.lowercased()

        // Shell commands. Checked as whole words where a bare substring would
        // over-match (e.g. "git" inside "digit", "test" inside "latest").
        if word(t, "git") || word(t, "gh") || word(t, "jj") || word(t, "hg") {
            return .versionControl
        }
        if t.contains("npm install") || t.contains("npm ci") || t.contains("yarn add")
            || t.contains("pnpm add") || t.contains("pnpm install") || t.contains("bun add")
            || t.contains("pip install") || t.contains("poetry add") || t.contains("uv add")
            || t.contains("cargo add") || t.contains("go get") || t.contains("bundle install")
            || t.contains("swift package") || t.contains("npm audit") || t.contains("npm outdated") {
            return .dependencies
        }
        if word(t, "pytest") || word(t, "jest") || word(t, "vitest") || word(t, "rspec")
            || t.contains("npm test") || t.contains("npm run test") || t.contains("yarn test")
            || t.contains("go test") || t.contains("cargo test") || t.contains("swift test")
            || t.contains("dotnet test") || t.contains("mvn test") || t.contains("gradle test") {
            return .testing
        }
        if word(t, "lldb") || word(t, "gdb") || word(t, "dlv") || word(t, "pdb")
            || t.contains("--verbose") || t.contains("stack trace") || t.contains("traceback")
            || t.contains("tail -f") || word(t, "dmesg") || t.contains("journalctl") {
            return .debugging
        }

        // File paths. Only meaningful when the target actually looks like one.
        if looksLikePath(t) {
            if t.contains("/test") || t.contains("/spec") || t.contains("__tests__")
                || hasSuffixAny(t, ["_test.go", "_test.py", "test.swift", "tests.swift",
                                    ".test.ts", ".test.js", ".test.tsx", ".spec.ts", ".spec.js"]) {
                return .testing
            }
            // Lockfiles are checked before config: `Cargo.lock` shares no
            // extension with the config list, so nesting this rule inside that
            // branch would leave it unreachable.
            if hasNameAny(t, ["package-lock.json", "yarn.lock", "pnpm-lock.yaml",
                              "bun.lockb", "cargo.lock", "poetry.lock", "uv.lock",
                              "package.resolved", "go.sum", "gemfile.lock",
                              "composer.lock", "podfile.lock"]) {
                return .dependencies
            }
            if hasSuffixAny(t, [".md", ".mdx", ".rst", ".txt", ".adoc"]) { return .docs }
            if hasSuffixAny(t, [".json", ".yaml", ".yml", ".toml", ".ini", ".plist",
                                ".env", ".conf", ".tf", ".gradle"])
                || hasNameAny(t, ["dockerfile", "makefile", "package.json", "cargo.toml",
                                  "package.swift", "go.mod", "requirements.txt"]) {
                return .config
            }
        }

        // A URL means the agent went outside the repo for information.
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return .research }

        return nil
    }

    // MARK: - Stage 2: the tool name

    /// Keyword match over the tool name. Order matters: more specific
    /// categories are checked first so `codebase_search` doesn't fall into
    /// `reading` via "code", and `run_terminal_cmd` doesn't hit `.searching`
    /// via "term".
    private static func fromToolName(_ raw: String) -> TopicCategory {
        let n = raw.lowercased()
        if n.contains("task") || n.contains("agent") || n.contains("dispatch") { return .delegating }
        if n.contains("webfetch") || n.contains("websearch") || n.contains("browser")
            || n.contains("http") { return .research }
        if n.contains("search") || n.contains("grep") || n.contains("glob")
            || n.contains("find") || n.contains("list") { return .searching }
        if n.contains("run") || n.contains("shell") || n.contains("terminal")
            || n.contains("bash") || n.contains("exec") || n.contains("command") { return .running }
        if n.contains("edit") || n.contains("write") || n.contains("create")
            || n.contains("patch") || n.contains("apply") || n.contains("delete") { return .writing }
        if n.contains("read") || n.contains("view") || n.contains("open") { return .reading }
        return .generic
    }

    // MARK: - Helpers

    /// Whole-word containment, so "git" matches `git status` and `&& git` but
    /// not `digit` or `legit`. Word characters are letters, digits and `_`.
    static func word(_ haystack: String, _ needle: String) -> Bool {
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let beforeOK = range.lowerBound == haystack.startIndex
                || !isWordChar(haystack[haystack.index(before: range.lowerBound)])
            let afterOK = range.upperBound == haystack.endIndex
                || !isWordChar(haystack[range.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = range.upperBound
            if searchStart >= haystack.endIndex { break }
        }
        return false
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// A target is treated as a path when it has a separator or a file
    /// extension and no spaces — enough to keep `git commit -m "fix ui.ts"`
    /// from being read as a path.
    private static func looksLikePath(_ t: String) -> Bool {
        guard !t.contains(" ") else { return false }
        return t.contains("/") || t.contains(".")
    }

    private static func hasSuffixAny(_ t: String, _ suffixes: [String]) -> Bool {
        suffixes.contains { t.hasSuffix($0) }
    }

    private static func hasNameAny(_ t: String, _ names: [String]) -> Bool {
        let last = t.split(separator: "/").last.map(String.init) ?? t
        return names.contains(last)
    }
}
