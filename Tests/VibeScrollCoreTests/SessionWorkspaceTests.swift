import XCTest
@testable import VibeScrollCore

/// Which folder a session belongs to — what a click on its row opens. Getting
/// it wrong used to be destructive: an editor handed a folder no window had
/// open reloaded a different window, and the session running in it.
final class SessionWorkspaceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_773_500_000)

    // MARK: - Transcript folder names

    func testTheEncodingMatchesClaudeCode() {
        // Every non-alphanumeric becomes "-", dots and underscores included.
        XCTAssertEqual(ProjectPath.transcriptFolderName(for: "/Users/a/projects/vibescrol"),
                       "-Users-a-projects-vibescrol")
        XCTAssertEqual(ProjectPath.transcriptFolderName(for: "/tmp/x/.claude/my_app"),
                       "-tmp-x--claude-my-app")
        XCTAssertEqual(ProjectPath.transcriptFolderName(for: "/Users/a/Masaüstü"),
                       "-Users-a-Masa-st-")
    }

    // MARK: - Recovering the root

    private let transcript =
        "/Users/a/.claude/projects/-Users-a-projects-vibescrol/0f2c.jsonl"

    func testASessionThatWanderedIntoASubfolderIsTracedBackToItsRoot() {
        XCTAssertEqual(
            ProjectPath.sessionRoot(cwd: "/Users/a/projects/vibescrol/vibeScroll-app",
                                    transcriptPath: transcript),
            "/Users/a/projects/vibescrol")
        XCTAssertEqual(
            ProjectPath.sessionRoot(cwd: "/Users/a/projects/vibescrol/app/Sources/Core",
                                    transcriptPath: transcript),
            "/Users/a/projects/vibescrol")
    }

    func testASessionStillAtItsRootIsItsOwnRoot() {
        XCTAssertEqual(ProjectPath.sessionRoot(cwd: "/Users/a/projects/vibescrol",
                                               transcriptPath: transcript),
                       "/Users/a/projects/vibescrol")
    }

    func testNoMatchIsNoAnswerRatherThanAGuess() {
        XCTAssertNil(ProjectPath.sessionRoot(cwd: "/Users/a/elsewhere",
                                             transcriptPath: transcript))
        XCTAssertNil(ProjectPath.sessionRoot(cwd: "/Users/a/projects/vibescrol", transcriptPath: ""))
    }

    func testASiblingWithASimilarNameDoesNotMatch() {
        // "vibescrol-old" encodes differently from "vibescrol"; only a real
        // ancestor can be the root.
        XCTAssertNil(ProjectPath.sessionRoot(cwd: "/Users/a/projects/vibescrol-old",
                                             transcriptPath: transcript))
    }

    // MARK: - The store

    private func event(_ name: String, cwd: String, transcript: String? = nil) -> AgentEvent {
        AgentEvent(sessionId: "s", agentKind: .claude, eventName: name, project: cwd,
                   transcriptPath: transcript, timestamp: now)
    }

    func testTheWorkspaceDoesNotDriftWhenTheAgentChangesDirectory() {
        let store = SessionStore()
        store.apply(event("SessionStart", cwd: "/w/repo"), now: now)
        store.apply(event("PreToolUse", cwd: "/w/repo/app"), now: now)

        let session = store.session(id: "s")
        XCTAssertEqual(session?.project, "/w/repo/app", "project follows the agent")
        XCTAssertEqual(session?.workspace, "/w/repo", "workspace stays where it started")
    }

    func testTheTranscriptCorrectsAWorkspaceFirstSeenFromASubfolder() {
        // The app launched mid-session: the first event it sees is already in
        // a subfolder. The transcript's location still names the real root.
        let store = SessionStore()
        store.apply(event("PreToolUse", cwd: "/Users/a/projects/vibescrol/vibeScroll-app"), now: now)
        XCTAssertEqual(store.session(id: "s")?.workspace,
                       "/Users/a/projects/vibescrol/vibeScroll-app")

        store.apply(event("PreToolUse", cwd: "/Users/a/projects/vibescrol/vibeScroll-app",
                          transcript: transcript), now: now)
        XCTAssertEqual(store.session(id: "s")?.workspace, "/Users/a/projects/vibescrol")
    }
}
