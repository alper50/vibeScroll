import XCTest
@testable import VibeScrollCore

final class SessionStoreTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 20_000)

    private func event(
        _ eventName: String, session: String = "s1", kind: AgentKind = .claude,
        tool: String? = nil, target: String? = nil, at offset: TimeInterval = 0
    ) -> AgentEvent {
        AgentEvent(sessionId: session, agentKind: kind, eventName: eventName,
                   project: "/work/app", toolName: tool, toolTarget: target,
                   timestamp: t0.addingTimeInterval(offset))
    }

    // MARK: - Topic tracking

    func testTopicIsResolvedFromToolSignal() {
        let store = SessionStore()
        let s = store.apply(event("PreToolUse", tool: "Bash", target: "git push"), now: t0)
        XCTAssertEqual(s?.topic, .versionControl)
        XCTAssertEqual(s?.topicSince, t0)
    }

    func testTopicSinceOnlyMovesWhenTheTopicActuallyChanges() {
        let store = SessionStore()
        store.apply(event("PreToolUse", tool: "Bash", target: "pytest"), now: t0)
        // Same topic 30s later — the dwell clock must not restart, or a long
        // stretch of testing would never satisfy the scheduler's dwell gate.
        let again = store.apply(
            event("PostToolUse", tool: "Bash", target: "pytest -q"), now: t0.addingTimeInterval(30))
        XCTAssertEqual(again?.topic, .testing)
        XCTAssertEqual(again?.topicSince, t0)

        let changed = store.apply(
            event("PreToolUse", tool: "Edit", target: "src/a.swift"), now: t0.addingTimeInterval(60))
        XCTAssertEqual(changed?.topic, .writing)
        XCTAssertEqual(changed?.topicSince, t0.addingTimeInterval(60))
    }

    func testEventWithoutSignalKeepsThePreviousTopic() {
        let store = SessionStore()
        store.apply(event("PreToolUse", tool: "Bash", target: "git status"), now: t0)
        // A bare Stop carries no tool — the topic must survive rather than
        // dropping to .generic and flickering the card's context.
        let after = store.apply(event("Stop", at: 5), now: t0.addingTimeInterval(5))
        XCTAssertEqual(after?.topic, .versionControl)
    }

    // MARK: - State machine

    func testStateTransitionResetsStateSince() {
        let store = SessionStore()
        store.apply(event("UserPromptSubmit"), now: t0)
        let done = store.apply(event("Stop"), now: t0.addingTimeInterval(10))
        XCTAssertEqual(done?.state, .done)
        XCTAssertEqual(done?.stateSince, t0.addingTimeInterval(10))
    }

    func testRepeatedSameStateKeepsStateSince() {
        let store = SessionStore()
        store.apply(event("PreToolUse"), now: t0)
        let again = store.apply(event("PostToolUse"), now: t0.addingTimeInterval(20))
        XCTAssertEqual(again?.state, .working)
        XCTAssertEqual(again?.stateSince, t0)
    }

    func testSessionEndRemovesImmediately() {
        let store = SessionStore()
        store.apply(event("Stop"), now: t0)
        XCTAssertEqual(store.sessions.count, 1)
        store.apply(event("SessionEnd"), now: t0.addingTimeInterval(1))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testUnmappedEventLeavesStoreUntouched() {
        let store = SessionStore()
        XCTAssertNil(store.apply(event("SubagentStop"), now: t0))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    // MARK: - refineState

    func testRefineStateAppliesToTheSameTransition() {
        let store = SessionStore()
        let done = store.apply(event("Stop"), now: t0)!
        store.refineState(id: "s1", from: .done, to: .waiting, since: done.stateSince)
        XCTAssertEqual(store.session(id: "s1")?.state, .waiting)
    }

    func testRefineStateIsANoOpOnceANewerEventMovedTheSessionOn() {
        let store = SessionStore()
        let done = store.apply(event("Stop"), now: t0)!
        // The user replied before the async transcript read finished.
        store.apply(event("UserPromptSubmit"), now: t0.addingTimeInterval(2))
        store.refineState(id: "s1", from: .done, to: .waiting, since: done.stateSince)
        // The stale correction must never clobber the fresher state.
        XCTAssertEqual(store.session(id: "s1")?.state, .working)
    }

    // MARK: - Pruning

    func testPruneDemotesDoneToIdleThenRemoves() {
        let store = SessionStore(doneToIdleAfter: 30, removeIdleAfter: 600)
        store.apply(event("Stop"), now: t0)
        store.prune(now: t0.addingTimeInterval(31))
        XCTAssertEqual(store.session(id: "s1")?.state, .idle)
        store.prune(now: t0.addingTimeInterval(31 + 601))
        XCTAssertNil(store.session(id: "s1"))
    }

    func testPruneDropsSilentActiveSessions() {
        let store = SessionStore(staleActiveAfter: 300)
        // Deliberately not a PreToolUse: silence there is a running tool call
        // and earns the longer window. This is the other case — the agent was
        // between calls and simply stopped reporting.
        store.apply(event("UserPromptSubmit"), now: t0)
        store.prune(now: t0.addingTimeInterval(301))
        XCTAssertNil(store.session(id: "s1"))
    }

    func testASessionInsideAToolCallSurvivesTheShortStaleWindow() {
        let store = SessionStore(staleActiveAfter: 300, staleToolCallAfter: 1800)
        // A ten-minute build: PreToolUse fires, then the agent reports nothing
        // at all until the command returns.
        store.apply(event("PreToolUse", tool: "Bash", target: "swift test"), now: t0)
        store.prune(now: t0.addingTimeInterval(601))
        XCTAssertNotNil(store.session(id: "s1"), "a running tool call must not read as a dead agent")
    }

    func testASessionInsideAToolCallIsStillDroppedEventually() {
        let store = SessionStore(staleActiveAfter: 300, staleToolCallAfter: 1800)
        store.apply(event("PreToolUse", tool: "Bash", target: "swift test"), now: t0)
        store.prune(now: t0.addingTimeInterval(1801))
        XCTAssertNil(store.session(id: "s1"))
    }

    func testTheToolCallGraceEndsWithTheNextEvent() {
        let store = SessionStore(staleActiveAfter: 300, staleToolCallAfter: 1800)
        store.apply(event("PreToolUse", tool: "Bash", target: "swift test"), now: t0)
        // The tool returned, so silence means the agent died again — the long
        // window must not stay latched once it is reporting.
        store.apply(event("PostToolUse", tool: "Bash", target: "swift test"), now: t0.addingTimeInterval(60))
        store.prune(now: t0.addingTimeInterval(60 + 301))
        XCTAssertNil(store.session(id: "s1"))
    }

    func testRegisteredSessionsAreDroppedSooner() {
        let store = SessionStore(staleActiveAfter: 300, staleRegisteredAfter: 90)
        store.apply(event("SessionStart"), now: t0)
        store.prune(now: t0.addingTimeInterval(91))
        XCTAssertNil(store.session(id: "s1"))
    }

    // MARK: - Ordering

    func testSortedPutsWorkingFirstThenWaiting() {
        let store = SessionStore()
        store.apply(event("Stop", session: "done"), now: t0)
        store.apply(event("Notification", session: "waiting"), now: t0)
        store.apply(event("PreToolUse", session: "working"), now: t0)
        XCTAssertEqual(store.sorted.map(\.id), ["working", "waiting", "done"])
    }
}
