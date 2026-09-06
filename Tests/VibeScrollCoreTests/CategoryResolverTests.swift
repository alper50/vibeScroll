import XCTest
@testable import VibeScrollCore

final class CategoryResolverTests: XCTestCase {

    // MARK: - Target beats tool name

    func testShellCommandOverridesGenericToolName() {
        // `Bash` alone is just "running something"; the command is what makes it
        // version control. This precedence is the whole point of stage 1.
        XCTAssertEqual(CategoryResolver.category(toolName: "Bash", target: "git status"), .versionControl)
        XCTAssertEqual(CategoryResolver.category(toolName: "Bash", target: "npm install lodash"), .dependencies)
        XCTAssertEqual(CategoryResolver.category(toolName: "Bash", target: "pytest -q"), .testing)
        XCTAssertEqual(CategoryResolver.category(toolName: "Bash", target: "ls -la"), .running)
    }

    func testFilePathOverridesEditTool() {
        XCTAssertEqual(CategoryResolver.category(toolName: "Edit", target: "docs/setup.md"), .docs)
        XCTAssertEqual(CategoryResolver.category(toolName: "Edit", target: "app/config.yaml"), .config)
        XCTAssertEqual(CategoryResolver.category(toolName: "Edit", target: "src/Tests/StoreTests.swift"), .testing)
        XCTAssertEqual(CategoryResolver.category(toolName: "Edit", target: "src/Store.swift"), .writing)
    }

    func testLockfileIsADependencyChangeNotAConfigEdit() {
        // package.json is config, but its lockfile is a dependency event —
        // the more specific rule has to be checked first.
        XCTAssertEqual(CategoryResolver.category(toolName: "Edit", target: "package.json"), .config)
        XCTAssertEqual(CategoryResolver.category(toolName: "Edit", target: "package-lock.json"), .dependencies)
        XCTAssertEqual(CategoryResolver.category(toolName: "Edit", target: "Cargo.lock"), .dependencies)
    }

    // MARK: - Word-boundary matching

    func testGitMatchesAsAWordNotASubstring() {
        XCTAssertEqual(CategoryResolver.category(toolName: "Bash", target: "git commit -m x"), .versionControl)
        XCTAssertEqual(CategoryResolver.category(toolName: "Bash", target: "make && git push"), .versionControl)
        // "digit" and "legit" must not read as git.
        XCTAssertNotEqual(CategoryResolver.category(toolName: "Bash", target: "check_digit --run"), .versionControl)
        XCTAssertNotEqual(CategoryResolver.category(toolName: "Bash", target: "echo legit"), .versionControl)
    }

    func testWordHelperHandlesBoundaries() {
        XCTAssertTrue(CategoryResolver.word("git status", "git"))
        XCTAssertTrue(CategoryResolver.word("cd x && git", "git"))
        XCTAssertTrue(CategoryResolver.word("(git)", "git"))
        XCTAssertFalse(CategoryResolver.word("digital", "git"))
        XCTAssertFalse(CategoryResolver.word("gitignore", "git"))
        XCTAssertFalse(CategoryResolver.word("", "git"))
    }

    func testQuotedFilenameInACommandIsNotTreatedAsAPath() {
        // Spaces disqualify a target from path handling, so the .ts suffix here
        // must not turn a commit into a code edit.
        XCTAssertEqual(
            CategoryResolver.category(toolName: "Bash", target: "git commit -m \"fix ui.ts\""),
            .versionControl
        )
    }

    // MARK: - Tool-name fallback

    func testToolNameFallbackAcrossAgentVocabularies() {
        XCTAssertEqual(CategoryResolver.category(toolName: "Read", target: nil), .reading)
        XCTAssertEqual(CategoryResolver.category(toolName: "read_file", target: nil), .reading)
        XCTAssertEqual(CategoryResolver.category(toolName: "edit_file", target: nil), .writing)
        XCTAssertEqual(CategoryResolver.category(toolName: "run_terminal_cmd", target: nil), .running)
        XCTAssertEqual(CategoryResolver.category(toolName: "codebase_search", target: nil), .searching)
        XCTAssertEqual(CategoryResolver.category(toolName: "Grep", target: nil), .searching)
        XCTAssertEqual(CategoryResolver.category(toolName: "Task", target: nil), .delegating)
        XCTAssertEqual(CategoryResolver.category(toolName: "WebFetch", target: nil), .research)
    }

    func testSpecificCategoriesWinOverGenericKeywordCollisions() {
        // "codebase_search" contains neither "read" nor "code"-as-reading, but
        // it does contain "search" — and "run_terminal_cmd" contains "term".
        XCTAssertEqual(CategoryResolver.category(toolName: "codebase_search", target: nil), .searching)
        XCTAssertEqual(CategoryResolver.category(toolName: "run_terminal_cmd", target: nil), .running)
    }

    func testUnknownToolWithNoTargetIsGeneric() {
        XCTAssertEqual(CategoryResolver.category(toolName: "Frobnicate", target: nil), .generic)
    }

    func testNoSignalAtAllReturnsNil() {
        // nil is distinct from .generic: the caller keeps the previous topic.
        XCTAssertNil(CategoryResolver.category(toolName: nil, target: nil))
        XCTAssertNil(CategoryResolver.category(toolName: "", target: nil))
    }

    func testURLTargetIsResearch() {
        XCTAssertEqual(
            CategoryResolver.category(toolName: "Fetch", target: "https://example.com/docs"),
            .research
        )
    }

    // MARK: - Aggregation

    func testAggregatePicksMostRecentWorkingTopic() {
        let base = Date(timeIntervalSince1970: 1_000)
        let sessions = [
            session(id: "a", state: .working, topic: .testing, topicSince: base),
            session(id: "b", state: .working, topic: .debugging, topicSince: base.addingTimeInterval(30)),
        ]
        XCTAssertEqual(CategoryResolver.aggregate(sessions), .debugging)
    }

    func testAggregateIgnoresNonWorkingSessions() {
        let base = Date(timeIntervalSince1970: 1_000)
        let sessions = [
            session(id: "a", state: .working, topic: .testing, topicSince: base),
            // Newer, but the user's attention is elsewhere — a waiting session
            // has no live topic to teach about.
            session(id: "b", state: .waiting, topic: .debugging, topicSince: base.addingTimeInterval(60)),
            session(id: "c", state: .done, topic: .docs, topicSince: base.addingTimeInterval(90)),
        ]
        XCTAssertEqual(CategoryResolver.aggregate(sessions), .testing)
    }

    func testAggregateReturnsNilWhenNothingIsWorking() {
        let sessions = [session(id: "a", state: .idle, topic: .testing, topicSince: Date())]
        XCTAssertNil(CategoryResolver.aggregate(sessions))
    }

    // MARK: - Helpers

    private func session(
        id: String, state: AgentState, topic: TopicCategory?, topicSince: Date
    ) -> AgentSession {
        AgentSession(id: id, agentKind: .claude, state: state, topic: topic,
                     source: .hook, updatedAt: topicSince, topicSince: topicSince)
    }
}
