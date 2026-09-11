import XCTest
@testable import VibeScrollCore

final class MomentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - What they say

    func testAMomentNamesTheAgentAndTheProject() {
        let moment = Moment.sessionStarted(agent: .claude, project: "/Users/me/work/vibeScroll")
        XCTAssertEqual(moment.title, "Session started")
        XCTAssertEqual(moment.detail, "Claude \u{00B7} vibeScroll")
    }

    func testAMomentWithoutAProjectSaysJustTheAgent() {
        // `project` is optional on a session and several agents never send one.
        // A trailing separator with nothing after it is worse than no project.
        XCTAssertEqual(Moment.waitingOnYou(agent: .codex, project: nil).detail, "Codex")
        XCTAssertEqual(Moment.waitingOnYou(agent: .codex, project: "").detail, "Codex")
    }

    func testTheFirstRateLimitReadsDifferentlyFromTheFourth() {
        XCTAssertEqual(Moment.rateLimited(count: 1).detail, "First one this hour.")
        XCTAssertEqual(Moment.rateLimited(count: 4).detail, "4 this hour.")
    }

    func testEveryMomentSaysSomething() {
        let all: [Moment] = [
            .welcome,
            .sessionStarted(agent: .claude, project: nil),
            .turnFinished(agent: .claude, project: nil),
            .waitingOnYou(agent: .claude, project: nil),
            .rateLimited(count: 2),
            .windowRenewed,
            .longHaul(hours: 4),
            .crowd(count: 3),
        ]
        for moment in all {
            XCTAssertFalse(moment.title.isEmpty, "\(moment) has no title")
            XCTAssertFalse(moment.detail.isEmpty, "\(moment) has no detail")
        }
    }

    // MARK: - The gate

    func testTheFirstMomentAlwaysGetsThrough() {
        var gate = MomentGate()
        XCTAssertTrue(gate.admit(.windowRenewed, now: now))
    }

    func testTwoProjectsStartingTogetherIsOneCard() {
        // The point is that work began, not which work.
        var gate = MomentGate()
        XCTAssertTrue(gate.admit(.sessionStarted(agent: .claude, project: "a"), now: now))
        XCTAssertFalse(gate.admit(.sessionStarted(agent: .codex, project: "b"),
                                  now: now.addingTimeInterval(1)))
    }

    func testDifferentKindsStillCannotStack() {
        // Without the floor between any two, a rate limit lands on top of a
        // session start and the panel flickers between them.
        var gate = MomentGate(policy: .init(perKind: 300, betweenAny: 45))
        XCTAssertTrue(gate.admit(.sessionStarted(agent: .claude, project: nil), now: now))
        XCTAssertFalse(gate.admit(.rateLimited(count: 1), now: now.addingTimeInterval(10)))
        XCTAssertTrue(gate.admit(.rateLimited(count: 1), now: now.addingTimeInterval(46)))
    }

    func testAKindRepeatsOnceItsOwnWindowHasPassed() {
        var gate = MomentGate(policy: .init(perKind: 300, betweenAny: 45))
        XCTAssertTrue(gate.admit(.turnFinished(agent: .claude, project: nil), now: now))
        XCTAssertFalse(gate.admit(.turnFinished(agent: .claude, project: nil),
                                  now: now.addingTimeInterval(200)))
        XCTAssertTrue(gate.admit(.turnFinished(agent: .claude, project: nil),
                                 now: now.addingTimeInterval(301)))
    }

    func testCrossingFourHoursDoesNotSilenceCrossingFive() {
        // Each milestone is its own key, or the second one would be swallowed
        // by the first one's per-kind window.
        var gate = MomentGate(policy: .init(perKind: 3600, betweenAny: 45))
        XCTAssertTrue(gate.admit(.longHaul(hours: 4), now: now))
        XCTAssertTrue(gate.admit(.longHaul(hours: 5), now: now.addingTimeInterval(3600)))
        XCTAssertFalse(gate.admit(.longHaul(hours: 5), now: now.addingTimeInterval(3700)))
    }

    func testResetForgetsEverything() {
        var gate = MomentGate()
        XCTAssertTrue(gate.admit(.welcome, now: now))
        gate.reset()
        XCTAssertTrue(gate.admit(.welcome, now: now))
    }

    // MARK: - Layout

    func testAMomentIsShorterThanATeachingCard() {
        // Two lines in a 200pt panel is mostly empty panel.
        XCTAssertLessThan(CardLayout.panelHeight(for: .moment),
                          CardLayout.panelHeight(for: .card))
        XCTAssertGreaterThan(CardLayout.panelHeight(for: .moment), 0)
    }
}
