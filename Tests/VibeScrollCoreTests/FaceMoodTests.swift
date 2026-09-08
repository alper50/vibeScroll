import XCTest
@testable import VibeScrollCore

final class FaceMoodTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let hour: TimeInterval = 3600

    private func session(
        _ state: AgentState, topicSince: TimeInterval = 0, createdAt: TimeInterval = 0,
        id: String = "s1"
    ) -> AgentSession {
        AgentSession(id: id, agentKind: .claude, state: state, source: .hook,
                     updatedAt: now,
                     createdAt: now.addingTimeInterval(-createdAt),
                     topicSince: now.addingTimeInterval(-topicSince))
    }

    private func quota(percent: Int, resetsIn: TimeInterval) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: "claude", displayName: "Claude",
            windows: [QuotaWindow(kind: "weekly_all", percentUsed: percent, severity: .normal,
                                  resetsAt: now.addingTimeInterval(resetsIn), isActive: true)],
            checkedAt: now)
    }

    // MARK: - The resting face

    func testNoSessionsIsAsleepRatherThanIdle() {
        let asleep = FaceMood.base(for: nil)
        let idle = FaceMood.base(for: .idle)
        XCTAssertLessThan(asleep.eyeOpenness, idle.eyeOpenness)
        XCTAssertLessThan(asleep.energy, idle.energy)
    }

    func testWaitingIsTheMostAlertRestingFace() {
        // "Needs input" is the one state where being noticed is the point.
        let waiting = FaceMood.base(for: .waiting)
        for other in [AgentState.working, .done, .registered, .idle] {
            XCTAssertGreaterThanOrEqual(waiting.eyeOpenness, FaceMood.base(for: other).eyeOpenness)
            XCTAssertGreaterThanOrEqual(waiting.browAngle, FaceMood.base(for: other).browAngle)
        }
    }

    func testDoneIsTheHappiest() {
        let done = FaceMood.base(for: .done)
        for other in [AgentState.working, .waiting, .registered, .idle] {
            XCTAssertGreaterThan(done.mouthCurve, FaceMood.base(for: other).mouthCurve)
        }
    }

    func testTheFaceFollowsWhicheverSessionWantsAttentionMost() {
        let sessions = [session(.idle, id: "a"), session(.waiting, id: "b"), session(.done, id: "c")]
        XCTAssertEqual(FaceMood.dominantState(sessions), .waiting)
        XCTAssertNil(FaceMood.dominantState([]))
    }

    // MARK: - Quota

    func testAnUnmeasuredBudgetIsNotAWorriedFace() {
        // The queue refuses to run without a quota reading because the risk
        // there is spending unsupervised. Here the only risk is a wrong face,
        // and looking worried about a budget nobody measured would be a lie.
        XCTAssertEqual(FaceMood.quotaPressure(nil, now: now), 0)
        let noWeekly = QuotaSnapshot(provider: "claude", displayName: "Claude", windows: [],
                                     checkedAt: now)
        XCTAssertEqual(FaceMood.quotaPressure(noWeekly, now: now), 0)
    }

    func testSpendingAheadOfTheWeekShows() {
        // 85% spent, 67% elapsed — the real reading from designing this.
        let pressure = FaceMood.quotaPressure(quota(percent: 85, resetsIn: 54.9 * hour), now: now)
        XCTAssertEqual(pressure, 0.9, accuracy: 0.06)
    }

    func testTheSamePercentageLateInTheWeekIsFine() {
        // 85% with three hours left is behind pace, not ahead of it.
        XCTAssertEqual(FaceMood.quotaPressure(quota(percent: 85, resetsIn: 3 * hour), now: now), 0)
    }

    // MARK: - Thrash

    func testCirclingOneTopicBuildsUp() {
        XCTAssertEqual(FaceMood.thrashPressure([session(.working, topicSince: 5 * 60)], now: now), 0)
        XCTAssertEqual(
            FaceMood.thrashPressure([session(.working, topicSince: 45 * 60)], now: now), 1)
        XCTAssertEqual(
            FaceMood.thrashPressure([session(.working, topicSince: 32.5 * 60)], now: now),
            0.5, accuracy: 0.02)
    }

    func testWaitingOnAPersonIsNotThrashing() {
        // A session parked in `waiting` has held its topic for exactly as long
        // as the human took to answer, which says nothing about the agent.
        XCTAssertEqual(FaceMood.thrashPressure([session(.waiting, topicSince: 2 * hour)], now: now), 0)
    }

    // MARK: - Fatigue

    func testALongSessionShows() {
        XCTAssertEqual(FaceMood.fatigue([session(.working, createdAt: hour)], rateLimits: [], now: now), 0)
        XCTAssertEqual(
            FaceMood.fatigue([session(.working, createdAt: 6 * hour)], rateLimits: [], now: now), 1)
    }

    func testRateLimitsCountImmediatelyRatherThanWaitingForTheClock() {
        let fresh = [session(.working, createdAt: 10 * 60)]
        let limits = [now.addingTimeInterval(-60), now.addingTimeInterval(-600),
                      now.addingTimeInterval(-1800)]
        XCTAssertEqual(FaceMood.fatigue(fresh, rateLimits: limits, now: now), 1)
    }

    func testOldRateLimitsStopCounting() {
        let stale = [now.addingTimeInterval(-2 * hour), now.addingTimeInterval(-3 * hour)]
        XCTAssertEqual(
            FaceMood.fatigue([session(.working, createdAt: 60)], rateLimits: stale, now: now), 0)
    }

    // MARK: - Composition

    func testNoSignalCanSilenceAnother() {
        // Waiting is an alert face; overspending is a worried one. Both at once
        // must land between them rather than one winning outright.
        let inputs = FaceInputs(
            sessions: [session(.waiting, createdAt: 30 * 60)],
            quota: quota(percent: 85, resetsIn: 54.9 * hour))
        let face = FaceMood.expression(for: inputs, now: now)
        let resting = FaceMood.base(for: .waiting)

        XCTAssertLessThan(face.browAngle, resting.browAngle, "the worry has to show")
        XCTAssertGreaterThan(face.eyeOpenness, 0.5, "but it is still an alert face")
        XCTAssertGreaterThan(face.strain, 0.5)
    }

    func testEverythingAtOnceStaysInRange() {
        let inputs = FaceInputs(
            sessions: [session(.working, topicSince: 3 * hour, createdAt: 12 * hour)],
            quota: quota(percent: 100, resetsIn: 160 * hour),
            rateLimits: (0..<10).map { now.addingTimeInterval(-Double($0) * 60) })
        let face = FaceMood.expression(for: inputs, now: now)

        XCTAssertTrue((-1...1).contains(face.browAngle))
        XCTAssertTrue((0...1).contains(face.eyeOpenness))
        XCTAssertTrue((-1...1).contains(face.mouthCurve))
        XCTAssertTrue((0...1).contains(face.strain))
        XCTAssertTrue((0...1).contains(face.energy))
        // And it should look thoroughly done in.
        XCTAssertLessThan(face.energy, 0.2)
        XCTAssertEqual(face.strain, 1)
    }

    func testAQuietMachineSleepsRatherThanFrowns() {
        let face = FaceMood.expression(for: FaceInputs(), now: now)
        XCTAssertEqual(face, FaceMood.base(for: nil).clamped())
    }

    // MARK: - Why the face looks like that

    func testAQuietMachineJustReportsItsState() {
        // Below the floor nothing is worth naming, or a trace of pressure would
        // be reported as though it were news.
        XCTAssertEqual(FaceMood.dominantReason(for: FaceInputs(), now: now), .steady(nil))
        XCTAssertEqual(
            FaceMood.dominantReason(
                for: FaceInputs(sessions: [session(.working)]), now: now),
            .steady(.working))
    }

    func testTheBudgetReasonCarriesBothNumbers() {
        // A percentage alone is not a reason: 85% is alarming on Tuesday and
        // fine on Sunday night, so the label has to say where the week is.
        let reason = FaceMood.dominantReason(
            for: FaceInputs(sessions: [session(.working)],
                            quota: quota(percent: 85, resetsIn: 54.9 * hour)),
            now: now)
        XCTAssertEqual(reason, .overBudget(usedPercent: 85, elapsedPercent: 67))
        XCTAssertEqual(reason.summary, "Weekly 85% spent, 67% of the week gone")
    }

    func testCirclingNamesTheSessionTheFaceReactedTo() {
        var stuck = session(.working, topicSince: 41 * 60, id: "stuck")
        stuck.topic = .versionControl
        let reason = FaceMood.dominantReason(
            for: FaceInputs(sessions: [session(.working, id: "busy"), stuck]), now: now)
        XCTAssertEqual(reason, .circling(topic: .versionControl, minutes: 41))
        XCTAssertEqual(reason.summary, "Circling version control for 41 min")
    }

    func testFatigueSaysWhichOfItsTwoCausesItWas() {
        // "Tired" is not actionable; the clock and the rate limits call for
        // different responses.
        let limits = (0..<3).map { now.addingTimeInterval(-Double($0) * 600) }
        XCTAssertEqual(
            FaceMood.dominantReason(
                for: FaceInputs(sessions: [session(.working, createdAt: 20 * 60)],
                                rateLimits: limits), now: now),
            .rateLimited(count: 3))

        XCTAssertEqual(
            FaceMood.dominantReason(
                for: FaceInputs(sessions: [session(.working, createdAt: 5 * hour)]), now: now),
            .longSession(minutes: 300))
    }

    func testSummariesReadAsSentences() {
        XCTAssertEqual(FaceMood.Reason.longSession(minutes: 320).summary, "5h 20m in")
        XCTAssertEqual(FaceMood.Reason.longSession(minutes: 45).summary, "45m in")
        XCTAssertEqual(FaceMood.Reason.rateLimited(count: 1).summary, "1 rate limit this hour")
        XCTAssertEqual(FaceMood.Reason.rateLimited(count: 4).summary, "4 rate limits this hour")
        XCTAssertEqual(FaceMood.Reason.steady(.waiting).summary, "Waiting for you")
        XCTAssertEqual(FaceMood.Reason.steady(nil).summary, "Nothing running")
    }

    func testTheStrongestPressureWins() {
        // Everything at once: the budget is the one to act on first.
        let reason = FaceMood.dominantReason(
            for: FaceInputs(sessions: [session(.working, topicSince: 30 * 60, createdAt: 4 * hour)],
                            quota: quota(percent: 95, resetsIn: 100 * hour)),
            now: now)
        guard case .overBudget = reason else {
            return XCTFail("expected the budget to dominate, got \(reason)")
        }
    }

    // MARK: - Helpers

    func testRampHandlesADegenerateRange() {
        XCTAssertEqual(FaceMood.ramp(5, from: 10, to: 10), 0)
        XCTAssertEqual(FaceMood.ramp(10, from: 10, to: 10), 1)
    }

    func testBlendMovesBetweenTwoReadings() {
        let a = FaceExpression(browAngle: -1, eyeOpenness: 0, mouthCurve: -1, strain: 1, energy: 0)
        let b = FaceExpression(browAngle: 1, eyeOpenness: 1, mouthCurve: 1, strain: 0, energy: 1)
        XCTAssertEqual(a.blended(towards: b, amount: 0.5).browAngle, 0, accuracy: 0.001)
        XCTAssertEqual(a.blended(towards: b, amount: 2), b, "out-of-range amounts clamp")
    }
}
