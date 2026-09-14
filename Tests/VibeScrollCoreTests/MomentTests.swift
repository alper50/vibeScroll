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
            .taskStarted(project: "/Users/me/work/app"),
            .allQuiet(count: 2),
            .stillHere(quietForMinutes: 30),
        ]
        for moment in all {
            XCTAssertFalse(moment.title.isEmpty, "\(moment) has no title")
            XCTAssertFalse(moment.detail.isEmpty, "\(moment) has no detail")
        }
    }

    func testTheAgentsStoppingReadsDifferentlyAloneAndInACrowd() {
        XCTAssertEqual(Moment.allQuiet(count: 1).title, "Your agent stopped")
        XCTAssertEqual(Moment.allQuiet(count: 4).title, "All 4 stopped")
    }

    func testACheckInSaysHowLongItHasBeenQuiet() {
        // Whole units: the number is the point, the precision is not.
        XCTAssertEqual(Moment.stillHere(quietForMinutes: 30).detail, "Quiet for 30 minutes.")
        XCTAssertEqual(Moment.stillHere(quietForMinutes: 60).detail, "An hour without an agent.")
        XCTAssertEqual(Moment.stillHere(quietForMinutes: 240).detail, "4 hours without an agent.")
    }

    func testOnlySmallTalkIsAmbient() {
        // Everything else is news, and news is allowed to bring the panel back.
        XCTAssertTrue(Moment.stillHere(quietForMinutes: 30).isAmbient)
        let news: [Moment] = [
            .welcome, .allQuiet(count: 2), .rateLimited(count: 1), .windowRenewed,
            .crowd(count: 3), .longHaul(hours: 4), .taskStarted(project: "/a"),
            .sessionStarted(agent: .claude, project: nil),
            .turnFinished(agent: .claude, project: nil),
            .waitingOnYou(agent: .claude, project: nil),
        ]
        for moment in news {
            XCTAssertFalse(moment.isAmbient, "\(moment) is news, not small talk")
        }
    }

    func testTheQuietMilestonesClimb() {
        // The caller takes the last one at or below the elapsed minutes, which
        // picks the wrong milestone if they are not in order.
        XCTAssertFalse(Moment.quietMilestones.isEmpty)
        XCTAssertEqual(Moment.quietMilestones, Moment.quietMilestones.sorted())
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

    func testHalfAnHourOfQuietDoesNotSilenceTwoHoursOfIt() {
        // Same reason as the longHaul milestones: one key per threshold.
        var gate = MomentGate(policy: .init(perKind: 3600, betweenAny: 45))
        XCTAssertTrue(gate.admit(.stillHere(quietForMinutes: 30), now: now))
        XCTAssertTrue(gate.admit(.stillHere(quietForMinutes: 60),
                                 now: now.addingTimeInterval(1800)))
        XCTAssertFalse(gate.admit(.stillHere(quietForMinutes: 60),
                                  now: now.addingTimeInterval(1900)))
    }

    func testTwoAgentsStoppingTogetherIsOneRemark() {
        // The count rides on the moment but not on its key: the point is that
        // the room went quiet, not how many of them left.
        var gate = MomentGate()
        XCTAssertTrue(gate.admit(.allQuiet(count: 2), now: now))
        XCTAssertFalse(gate.admit(.allQuiet(count: 3), now: now.addingTimeInterval(60)))
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
