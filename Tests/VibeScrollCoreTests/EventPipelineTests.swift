import XCTest
@testable import VibeScrollCore

/// Covers the path a real hook takes: raw stdin JSON → AgentEvent → wire
/// round-trip → SessionStore.
final class EventPipelineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 30_000)

    func testClaudePayloadCarriesTheCategorySignal() throws {
        let json = """
        {"session_id":"abc","cwd":"/work/app","hook_event_name":"PreToolUse",
         "tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}
        """
        let payload = try XCTUnwrap(ClaudeHookPayload.decode(from: Data(json.utf8)))
        let event = try XCTUnwrap(payload.makeEvent(now: now))

        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolTarget, "git commit -m wip")
        XCTAssertEqual(event.project, "/work/app")

        let store = SessionStore()
        XCTAssertEqual(store.apply(event, now: now)?.topic, .versionControl)
    }

    func testClaudeShapeIsReusedForCodexAndDroid() throws {
        let json = #"{"session_id":"x","hook_event_name":"Stop"}"#
        let payload = try XCTUnwrap(ClaudeHookPayload.decode(from: Data(json.utf8)))
        XCTAssertEqual(payload.makeEvent(now: now, kind: .codex)?.agentKind, .codex)
        XCTAssertEqual(payload.makeEvent(now: now, kind: .droid)?.agentKind, .droid)
    }

    func testCursorPayloadUsesItsOwnFieldNames() throws {
        let json = """
        {"conversation_id":"c1","hook_event_name":"preToolUse",
         "workspace_roots":["/work/app"],"tool_name":"edit_file",
         "tool_input":{"file_path":"src/main.ts"}}
        """
        let event = try XCTUnwrap(HookPayload.event(forAgent: .cursor, stdin: Data(json.utf8), now: now))
        XCTAssertEqual(event.sessionId, "c1")
        XCTAssertEqual(event.agentKind, .cursor)
        XCTAssertEqual(event.toolTarget, "src/main.ts")
    }

    func testAntigravityInfersStateFromDiscriminatorFields() throws {
        // Antigravity sends no event name at all.
        let stop = try XCTUnwrap(HookPayload.event(
            forAgent: .antigravity,
            stdin: Data(#"{"conversationId":"a","fullyIdle":true}"#.utf8), now: now))
        XCTAssertEqual(StateMapper.state(for: .antigravity, eventName: stop.eventName), .done)

        let working = try XCTUnwrap(HookPayload.event(
            forAgent: .antigravity,
            stdin: Data(#"{"conversationId":"a","toolCall":{"name":"Read"}}"#.utf8), now: now))
        XCTAssertEqual(StateMapper.state(for: .antigravity, eventName: working.eventName), .working)
    }

    func testUndecodablePayloadYieldsNilRatherThanThrowing() {
        // The hook CLI turns this into exit 0 — never a blocked agent.
        XCTAssertNil(HookPayload.event(forAgent: .claude, stdin: Data("not json".utf8), now: now))
        XCTAssertNil(HookPayload.event(forAgent: .cursor, stdin: Data("{}".utf8), now: now))
    }

    func testModelFieldToleratesEveryShape() throws {
        for (json, expected) in [
            (#"{"session_id":"x","hook_event_name":"Stop","model":{"display_name":"Opus 5"}}"#, "Opus 5"),
            (#"{"session_id":"x","hook_event_name":"Stop","model":{"id":"claude-opus-5"}}"#, "claude-opus-5"),
            (#"{"session_id":"x","hook_event_name":"Stop","model":"Sonnet"}"#, "Sonnet"),
        ] {
            let payload = try XCTUnwrap(ClaudeHookPayload.decode(from: Data(json.utf8)))
            XCTAssertEqual(payload.makeEvent(now: now)?.model, expected)
        }
        // Absent entirely, and an unexpected shape, must both decode cleanly.
        let bare = try XCTUnwrap(ClaudeHookPayload.decode(
            from: Data(#"{"session_id":"x","hook_event_name":"Stop","model":[1,2]}"#.utf8)))
        XCTAssertNil(bare.makeEvent(now: now)?.model)
    }

    func testEventSurvivesTheWireRoundTrip() throws {
        let event = AgentEvent(
            sessionId: "s", agentKind: .claude, eventName: "PreToolUse", project: "/p",
            message: "Running git status", toolName: "Bash", toolTarget: "git status", timestamp: now)
        let line = try EventSender.encodeLine(event)
        XCTAssertEqual(line.last, 0x0A)

        var decoded: [AgentEvent] = []
        EventSocketServer.decodeLines(line) { decoded.append($0) }
        XCTAssertEqual(decoded, [event])
    }

    func testDecodeLinesSkipsGarbageAndKeepsGoing() throws {
        let good = try EventSender.encodeLine(
            AgentEvent(sessionId: "s", agentKind: .cli, eventName: "working", timestamp: now))
        var buffer = Data("{bad json}\n".utf8)
        buffer.append(good)
        var decoded: [AgentEvent] = []
        EventSocketServer.decodeLines(buffer) { decoded.append($0) }
        XCTAssertEqual(decoded.count, 1)
    }

    func testToolCallStartIsRecognisedPerAgentDialect() {
        XCTAssertTrue(StateMapper.isToolCallStart(for: .claude, eventName: "PreToolUse"))
        XCTAssertTrue(StateMapper.isToolCallStart(for: .cursor, eventName: "beforeShellExecution"))
        XCTAssertTrue(StateMapper.isToolCallStart(for: .gemini, eventName: "BeforeTool"))
        XCTAssertTrue(StateMapper.isToolCallStart(for: .grok, eventName: "pre_tool_use"))
        XCTAssertTrue(StateMapper.isToolCallStart(for: .pi, eventName: "tool_execution_start"))

        // Case belongs to the agent, not to us: Claude never sends camelCase.
        XCTAssertFalse(StateMapper.isToolCallStart(for: .claude, eventName: "preToolUse"))
        // The end of a call, and a turn boundary, both mean the agent is
        // reporting again — neither may extend the grace period.
        XCTAssertFalse(StateMapper.isToolCallStart(for: .claude, eventName: "PostToolUse"))
        XCTAssertFalse(StateMapper.isToolCallStart(for: .claude, eventName: "Stop"))
        // The run wrapper heartbeats on its own, so it needs no grace at all.
        XCTAssertFalse(StateMapper.isToolCallStart(for: .cli, eventName: "working"))
    }

    func testAcceptErrorDefaultsToBackoffNotATightLoop() {
        XCTAssertEqual(EventSocketServer.acceptErrorAction(errno: EINTR), .retryImmediately)
        XCTAssertEqual(EventSocketServer.acceptErrorAction(errno: EBADF), .stop)
        XCTAssertEqual(EventSocketServer.acceptErrorAction(errno: EMFILE), .backoff)
        // An unrecognised errno must never fall through to retryImmediately.
        XCTAssertEqual(EventSocketServer.acceptErrorAction(errno: 9999), .backoff)
    }
}
