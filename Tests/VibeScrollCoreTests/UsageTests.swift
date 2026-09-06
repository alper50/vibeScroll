import XCTest
@testable import VibeScrollCore

final class UsageTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 60_000)

    private func event(_ name: String, session: String = "s1") -> AgentEvent {
        AgentEvent(sessionId: session, agentKind: .claude, eventName: name,
                   project: "/work/app", timestamp: t0)
    }

    // MARK: - Accumulation

    func testUsageStartsUnknownNotZero() {
        // The distinction matters: nine of the eleven agents write no readable
        // transcript, and showing them "0 tokens" would be a false statement
        // rather than a missing one.
        let store = SessionStore()
        let session = store.apply(event("PreToolUse"), now: t0)
        XCTAssertNil(session?.tokens)
        XCTAssertNil(session?.costUSD)
    }

    func testDeltasAccumulate() {
        // TranscriptReader reads incrementally, so each scan returns only what
        // is new — adding is the correct operation, not assignment.
        let store = SessionStore()
        store.apply(event("PreToolUse"), now: t0)
        store.addUsage(id: "s1", tokens: 1_200, costUSD: 0.02)
        store.addUsage(id: "s1", tokens: 800, costUSD: 0.01)
        XCTAssertEqual(store.session(id: "s1")?.tokens, 2_000)
        XCTAssertEqual(store.session(id: "s1")?.costUSD ?? 0, 0.03, accuracy: 0.0001)
    }

    func testUsageForAPrunedSessionIsDropped() {
        // A detached transcript read can land after prune deleted the session;
        // it must not resurrect a half-built one.
        let store = SessionStore()
        store.addUsage(id: "ghost", tokens: 5_000, costUSD: 1)
        XCTAssertNil(store.session(id: "ghost"))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testNegativeDeltaCannotReduceTheTotal() {
        let store = SessionStore()
        store.apply(event("PreToolUse"), now: t0)
        store.addUsage(id: "s1", tokens: 1_000, costUSD: 0.5)
        store.addUsage(id: "s1", tokens: -900, costUSD: -0.4)
        XCTAssertEqual(store.session(id: "s1")?.tokens, 1_000)
    }

    func testUsageSurvivesLaterEvents() {
        // Usage is banked on the session, so an ordinary state change must not
        // reset it.
        let store = SessionStore()
        store.apply(event("PreToolUse"), now: t0)
        store.addUsage(id: "s1", tokens: 4_000, costUSD: 0.1)
        store.apply(event("Stop"), now: t0.addingTimeInterval(5))
        XCTAssertEqual(store.session(id: "s1")?.tokens, 4_000)
    }

    // MARK: - Formatting

    func testTokenFormatBands() {
        XCTAssertEqual(TickerFormatter.tokens(0), "0")
        XCTAssertEqual(TickerFormatter.tokens(512), "512")
        XCTAssertEqual(TickerFormatter.tokens(999), "999")
        XCTAssertEqual(TickerFormatter.tokens(1_000), "1.0k")
        XCTAssertEqual(TickerFormatter.tokens(3_450), "3.5k")
        XCTAssertEqual(TickerFormatter.tokens(9_999), "10.0k")
        XCTAssertEqual(TickerFormatter.tokens(10_000), "10k")
        XCTAssertEqual(TickerFormatter.tokens(847_300), "847k")
        XCTAssertEqual(TickerFormatter.tokens(1_000_000), "1.0M")
        XCTAssertEqual(TickerFormatter.tokens(1_234_567), "1.2M")
    }

    func testTokenFormatNeverShowsANegative() {
        XCTAssertEqual(TickerFormatter.tokens(-5), "0")
    }
}
