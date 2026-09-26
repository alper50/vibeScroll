import XCTest
@testable import VibeScrollCore

final class PermissionTests: XCTestCase {

    private func source(_ agent: PermissionAgent, _ format: PermissionSource.Format,
                        scope: PermissionSource.Scope = .project(root: "/w/app", shared: false),
                        path: String = "/w/app/.claude/settings.local.json") -> PermissionSource {
        PermissionSource(path: path, agent: agent, scope: scope, format: format)
    }

    // MARK: - Claude Code

    func testClaudeRulesAreReadWithWhereTheyLive() {
        // The rules actually found on this machine, in RuView's settings.
        let settings: [String: Any] = ["permissions": [
            "allow": ["Bash(npx claude-flow*)", "Bash(node .claude/*)", "mcp__claude-flow__:*"],
            "deny": ["Bash(rm -rf *)"],
            "additionalDirectories": ["//Users/a/shared-docs"],
            "defaultMode": "acceptEdits",
        ]]
        let entries = PermissionParser.claude(settings: settings, source: source(.claude, .claudeSettings))
        XCTAssertEqual(entries.filter { $0.effect == .allow }.count, 3)
        XCTAssertEqual(entries.filter { $0.effect == .deny }.map(\.raw), ["Bash(rm -rf *)"])
        XCTAssertEqual(entries.first { $0.effect == .directory }?.raw, "//Users/a/shared-docs")
        XCTAssertEqual(entries.first { $0.effect == .setting }?.risk, .medium)
        XCTAssertTrue(entries.first { $0.raw == "Bash(npx claude-flow*)" }!
            .summary.contains("npx claude-flow"))
    }

    func testAnyShellCommandIsHighRisk() {
        for rule in ["Bash", "Bash(*)", "Bash(bash *)", "Bash(python3:*)"] {
            let entry = PermissionParser.claude(settings: ["permissions": ["allow": [rule]]],
                                                source: source(.claude, .claudeSettings)).first!
            XCTAssertEqual(entry.risk, .high, rule)
        }
        let narrow = PermissionParser.claude(settings: ["permissions": ["allow": ["Bash(npm test)"]]],
                                             source: source(.claude, .claudeSettings)).first!
        XCTAssertEqual(narrow.risk, .low)
    }

    func testBypassModeIsHighRisk() {
        let entry = PermissionParser.claude(settings: ["permissions": ["defaultMode": "bypassPermissions"]],
                                            source: source(.claude, .claudeSettings)).first!
        XCTAssertEqual(entry.risk, .high)
        XCTAssertFalse(entry.isRemovable, "a mode is a setting, not a grant to take back")
    }

    func testRulePathsAreShownTheWayClaudeResolvesThem() {
        XCTAssertEqual(PermissionExplainer.displayPath("//Users/a/x/**", root: "/w/app"), "/Users/a/x/**")
        XCTAssertEqual(PermissionExplainer.displayPath("/src/**", root: "/w/app"), "/w/app/src/**")
        XCTAssertEqual(PermissionExplainer.displayPath("~/notes", root: "/w/app"), "~/notes")
    }

    func testTheWholeHomeFolderIsHighRisk() {
        XCTAssertEqual(PermissionExplainer.directoryRisk(NSHomeDirectory()), .high)
        XCTAssertEqual(PermissionExplainer.directoryRisk("~/**"), .high)
        XCTAssertEqual(PermissionExplainer.directoryRisk("/Users/a/one-project"), .medium)
    }

    func testMCPRulesNameTheServer() {
        let entry = PermissionParser.claude(settings: ["permissions": ["allow": ["mcp__github__create_issue"]]],
                                            source: source(.claude, .claudeSettings)).first!
        XCTAssertTrue(entry.summary.contains("github"))
        XCTAssertTrue(entry.summary.contains("create_issue"))
    }

    func testAWholeMCPServerIsNotReadAsAToolNamedStar() {
        // The spelling found in RuView's settings.
        for rule in ["mcp__claude-flow__:*", "mcp__claude-flow__*", "mcp__claude-flow"] {
            let entry = PermissionParser.claude(settings: ["permissions": ["allow": [rule]]],
                                                source: source(.claude, .claudeSettings)).first!
            XCTAssertTrue(entry.summary.contains("every tool"), "\(rule): \(entry.summary)")
        }
    }

    // MARK: - Who may edit what

    func testOnlyPersonalFilesAreEditable() {
        let rule: [String: Any] = ["permissions": ["allow": ["Bash(ls)"]]]
        let personal = PermissionParser.claude(settings: rule, source: source(.claude, .claudeSettings)).first!
        let shared = PermissionParser.claude(settings: rule, source: source(
            .claude, .claudeSettings, scope: .project(root: "/w/app", shared: true))).first!
        let managed = PermissionParser.claude(settings: rule, source: source(
            .claude, .claudeSettings, scope: .managed)).first!
        let user = PermissionParser.claude(settings: rule, source: source(
            .claude, .claudeSettings, scope: .user)).first!
        XCTAssertTrue(personal.isRemovable)
        XCTAssertTrue(user.isRemovable)
        XCTAssertTrue(shared.isRemovable, "usually your own repository — removable, with a warning")
        XCTAssertTrue(shared.source.isSharedWithTeam)
        XCTAssertFalse(personal.source.isSharedWithTeam)
        XCTAssertFalse(managed.isRemovable, "an administrator's policy is not ours to edit")
    }

    // MARK: - Removing

    func testRemovingTakesOutExactlyThatRule() {
        let settings: [String: Any] = [
            "hooks": ["Stop": []],
            "permissions": ["allow": ["Bash(ls)", "Bash(npm test)"], "deny": ["Bash(ls)"]],
        ]
        let entry = PermissionParser.claude(settings: settings, source: source(.claude, .claudeSettings))
            .first { $0.raw == "Bash(ls)" && $0.effect == .allow }!
        let updated = PermissionEditor.removing(entry, from: settings)!
        let permissions = updated["permissions"] as! [String: Any]
        XCTAssertEqual(permissions["allow"] as? [String], ["Bash(npm test)"])
        XCTAssertEqual(permissions["deny"] as? [String], ["Bash(ls)"], "the same text elsewhere stays")
        XCTAssertNotNil(updated["hooks"], "nothing outside the rule is touched")
    }

    func testRemovingSomethingAlreadyGoneRefuses() {
        // The file changed since it was read; writing anyway would act on a stale view.
        let entry = PermissionParser.claude(settings: ["permissions": ["allow": ["Bash(ls)"]]],
                                            source: source(.claude, .claudeSettings)).first!
        XCTAssertNil(PermissionEditor.removing(entry, from: ["permissions": ["allow": ["Bash(pwd)"]]]))
    }

    // MARK: - Cursor

    func testCursorPermissionsJSON() {
        let json: [String: Any] = [
            "terminalAllowlist": ["git status", "npm:install*"],
            "mcpAllowlist": ["github:*"],
            "autoRun": ["block_instructions": ["never touch production"]],
        ]
        let entries = PermissionParser.cursorPermissions(
            json: json, source: source(.cursor, .cursorPermissions, path: "/w/app/.cursor/permissions.json"))
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries.first { $0.raw == "github:*" }?.risk, .medium)
        XCTAssertEqual(entries.first { $0.raw == "never touch production" }?.effect, .deny)
    }

    func testCursorCLIRules() {
        let json: [String: Any] = ["permissions": [
            "allow": ["Shell(ls)", "Read(src/**/*.ts)", "Write(package.json)"],
            "deny": ["Shell(rm)", "Read(.env*)"],
        ]]
        let entries = PermissionParser.cursorCLI(
            json: json, source: source(.cursor, .cursorCLI, path: "/w/app/.cursor/cli.json"))
        XCTAssertEqual(entries.filter { $0.effect == .allow }.count, 3)
        XCTAssertEqual(entries.filter { $0.effect == .deny }.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.isRemovable })
    }

    // MARK: - Codex

    func testCodexConfigSettings() {
        let toml = """
        model = "gpt-5"
        approval_policy = "never"   # no questions
        sandbox_mode = "workspace-write"

        [sandbox_workspace_write]
        network_access = true
        writable_roots = [
          "/Users/a/shared",
          "/tmp/build",
        ]

        [projects."/Users/a/Desktop/app"]
        trust_level = "trusted"
        """
        let entries = PermissionParser.codexConfig(
            toml: toml, source: source(.codex, .codexConfig, scope: .user, path: "~/.codex/config.toml"))
        XCTAssertEqual(entries.first { $0.raw.hasPrefix("approval_policy") }?.risk, .high)
        XCTAssertEqual(entries.filter { $0.effect == .directory }.map(\.raw), ["/Users/a/shared", "/tmp/build"])
        XCTAssertTrue(entries.contains { $0.raw == "network_access = true" })
        XCTAssertTrue(entries.contains { $0.summary.contains("/Users/a/Desktop/app") })
        XCTAssertTrue(entries.allSatisfy { !$0.isRemovable }, "TOML is shown, not rewritten")
    }

    func testTOMLCommentsAndQuotedKeys() {
        let values = MiniTOML.parse("""
        # a comment with = and [brackets]
        [projects."/a/b.c"]
        trust_level = 'trusted' # inline
        """)
        XCTAssertEqual(values[["projects", "/a/b.c", "trust_level"]], .string("trusted"))
    }

    func testCodexRulesAreFoundAndRemovedVerbatim() {
        let text = """
        # prefix_rule(pattern=["rm"], decision="allow")  commented out
        prefix_rule(pattern=["git", "add"], decision="allow")
        prefix_rule(
            pattern = ["npm", "publish"],
            decision = "forbidden",
        )
        prefix_rule(pattern=["curl"])
        """
        let entries = PermissionParser.codexRules(
            text: text, source: source(.codex, .codexRules, scope: .user, path: "~/.codex/rules/default.rules"))
        XCTAssertEqual(entries.count, 3, "the commented-out call is not a rule")
        XCTAssertEqual(entries[0].effect, .allow)
        XCTAssertTrue(entries[0].summary.contains("git add"))
        XCTAssertEqual(entries[1].effect, .deny)
        XCTAssertEqual(entries[2].effect, .ask, "no decision means prompt")

        let updated = PermissionEditor.removing(entries[0], fromText: text)!
        XCTAssertFalse(updated.contains(#"pattern=["git", "add"]"#))
        XCTAssertTrue(updated.contains(#"pattern = ["npm", "publish"]"#))
        XCTAssertTrue(updated.contains("commented out"), "only the rule itself is removed")
    }
}
