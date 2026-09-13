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

    private func sessionQuota(percent: Int, resetsIn: TimeInterval) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: "claude", displayName: "Claude",
            windows: [QuotaWindow(kind: "session", percentUsed: percent, severity: .normal,
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
        // Nothing running is fully asleep, not merely resting: eyes shut, no
        // energy left to blink with, and no expression on it either way.
        let face = FaceMood.expression(for: FaceInputs(), now: now)
        XCTAssertEqual(face.eyeOpenness, 0)
        XCTAssertEqual(face.energy, 0)
        XCTAssertEqual(face.browAngle, 0)
        XCTAssertEqual(face.strain, 0)
        XCTAssertTrue(BlinkRhythm.sleeps(atEnergy: face.energy))
    }

    // MARK: - The shape of the work

    func testCrowdingCountsOnlyAgentsActuallyDoingSomething() {
        let policy = FaceMood.Policy(crowdedAt: 4)
        XCTAssertEqual(FaceMood.crowding([session(.working)], policy: policy), 0)
        XCTAssertEqual(
            FaceMood.crowding((0..<4).map { session(.working, id: "w\($0)") }, policy: policy), 1)
        // Finished and idle sessions are still listed but nobody is waiting on
        // them, so they do not make the room feel busy.
        XCTAssertEqual(
            FaceMood.crowding([session(.working), session(.done, id: "d"),
                               session(.idle, id: "i")], policy: policy), 0)
    }

    func testExertionRampsWithTheBurnRate() {
        let policy = FaceMood.Policy(briskTokensPerMinute: 3000)
        XCTAssertEqual(FaceMood.exertion(tokensPerMinute: 0, policy: policy), 0)
        XCTAssertEqual(FaceMood.exertion(tokensPerMinute: 3000, policy: policy), 1)
        XCTAssertEqual(FaceMood.exertion(tokensPerMinute: 9_999_999, policy: policy), 1)
    }

    // MARK: - Waking up

    func testAnUntouchedFaceWithNothingRunningIsAsleep() {
        XCTAssertEqual(FaceMood.drowsiness([], now: now), 1)
        XCTAssertEqual(FaceMood.alertness(lastInteraction: nil, now: now), 0)
    }

    func testBeingTouchedCountsAsSomethingHappening() {
        // Same arithmetic an agent event gets: the clock restarts.
        XCTAssertEqual(FaceMood.drowsiness([], lastInteraction: now, now: now), 0)
        let policy = FaceMood.Policy(drowsyAfter: 300, asleepAfter: 1200)
        XCTAssertEqual(
            FaceMood.drowsiness([], lastInteraction: now.addingTimeInterval(-1200),
                                policy: policy, now: now),
            1)
    }

    func testAClickOpensTheEyesOfAFaceWithNothingRunning() {
        // The bug this exists for: suppressing drowsiness alone left the face
        // at `base(for: nil)`, which is eyes at 0.05 — still asleep.
        let asleep = FaceMood.expression(for: FaceInputs(), now: now)
        var touched = FaceInputs()
        touched.lastInteraction = now
        let woken = FaceMood.expression(for: touched, now: now)

        XCTAssertLessThan(asleep.eyeOpenness, 0.1)
        XCTAssertGreaterThan(woken.eyeOpenness, 0.6)
        XCTAssertGreaterThan(woken.energy, asleep.energy)
    }

    func testWakingIsAFloorRatherThanAPush() {
        // A click on an already wide-eyed face must not pin it at 1 for the
        // next five minutes.
        var busy = FaceInputs(sessions: [session(.working)])
        let plain = FaceMood.expression(for: busy, now: now)
        busy.lastInteraction = now
        XCTAssertEqual(FaceMood.expression(for: busy, now: now).eyeOpenness,
                       plain.eyeOpenness, accuracy: 0.0001)
    }

    func testAlertnessHandsOverToDrowsinessWithoutAGap() {
        // It reaches zero exactly where drowsiness starts to climb, so there
        // is no window in which the face is neither awake nor asleep.
        let policy = FaceMood.Policy(drowsyAfter: 300, asleepAfter: 1200)
        XCTAssertEqual(
            FaceMood.alertness(lastInteraction: now.addingTimeInterval(-300),
                               policy: policy, now: now),
            0, accuracy: 0.0001)
        XCTAssertEqual(
            FaceMood.drowsiness([], lastInteraction: now.addingTimeInterval(-300),
                                policy: policy, now: now),
            0, accuracy: 0.0001)
    }

    func testSessionsThatAgreeRaiseNoBrow() {
        XCTAssertEqual(FaceMood.discord([session(.working, id: "a"),
                                         session(.working, id: "b")]), 0)
        XCTAssertEqual(FaceMood.discord([]), 0)
    }

    func testOneSessionOutOfStepRaisesABrow() {
        let pair = FaceMood.discord([session(.working, id: "a"), session(.waiting, id: "b")])
        XCTAssertEqual(abs(pair), 0.5, accuracy: 0.0001)

        // `working` outranks `waiting` in `attentionPriority`, so the busy one
        // is what the face is about and the two waiting ones are the odd ones.
        let policy = FaceMood.Policy(discordAt: 2)
        let two = FaceMood.discord([session(.working, id: "a"),
                                    session(.waiting, id: "b"),
                                    session(.waiting, id: "c")],
                                   policy: policy)
        XCTAssertEqual(abs(two), 1, accuracy: 0.0001)
    }

    func testFinishedSessionsAreNotADiscrepancy() {
        // Yesterday's session sitting in the list is not something to be
        // sceptical about, whatever state it ended in.
        XCTAssertEqual(FaceMood.discord([session(.working, id: "a"),
                                         session(.done, id: "b"),
                                         session(.idle, id: "c")]), 0)
    }

    func testWhichBrowGoesUpIsStableForTheSameSessions() {
        // Not `hashValue`: Swift seeds it per process, which would swap the
        // brow on every restart for an unchanged set of sessions.
        let sessions = [session(.working, id: "a"), session(.waiting, id: "b")]
        XCTAssertEqual(FaceMood.discord(sessions), FaceMood.discord(sessions))
        let other = [session(.working, id: "a"), session(.waiting, id: "c")]
        XCTAssertEqual(FaceMood.discord(other) * FaceMood.discord(sessions) < 0, true,
                       "b and c land on opposite sides, so the sign is doing something")
    }

    func testTheFiveHourWindowSquints() {
        // 80% spent with three of five hours left is 40% elapsed: 40 points
        // ahead, past the 35 that counts as full.
        let hot = FaceMood.sessionPressure(sessionQuota(percent: 80, resetsIn: 3 * 3600), now: now)
        XCTAssertEqual(hot, 1, accuracy: 0.0001)

        let fine = FaceMood.sessionPressure(sessionQuota(percent: 40, resetsIn: 3 * 3600), now: now)
        XCTAssertEqual(fine, 0)
        XCTAssertEqual(FaceMood.sessionPressure(nil, now: now), 0)
    }

    func testTheFiveHourWindowIsNamedAheadOfTheWeeklyOne() {
        // Both lit; the one that runs out this afternoon is the one to say.
        var inputs = FaceInputs(sessions: [session(.working)])
        inputs.quota = QuotaSnapshot(
            provider: "claude", displayName: "Claude",
            windows: [QuotaWindow(kind: "session", percentUsed: 90, severity: .normal,
                                  resetsAt: now.addingTimeInterval(4 * 3600), isActive: true),
                      QuotaWindow(kind: "weekly_all", percentUsed: 100, severity: .normal,
                                  resetsAt: now.addingTimeInterval(160 * 3600), isActive: true)],
            checkedAt: now)
        XCTAssertEqual(FaceMood.dominantReason(for: inputs, now: now),
                       .burningWindow(usedPercent: 90, minutesLeft: 240))
    }

    func testEachNewSignalMovesExactlyOneFeature() {
        // The whole point of one signal per feature: a raised brow has to mean
        // the same thing every time, whatever else is happening.
        let base = FaceInputs(sessions: [session(.working)])
        let plain = FaceMood.expression(for: base, now: now)

        var split = base
        split.sessions = [session(.working, id: "a"), session(.waiting, id: "b")]
        let disagreeing = FaceMood.expression(for: split, now: now)
        XCTAssertNotEqual(disagreeing.browSkew, plain.browSkew)
        XCTAssertEqual(disagreeing.tongue, plain.tongue)

        var busy = base
        busy.tokensPerMinute = 5000
        let working = FaceMood.expression(for: busy, now: now)
        XCTAssertGreaterThan(working.tongue, plain.tongue)
        XCTAssertEqual(working.browSkew, plain.browSkew)
    }

    func testATongueCannotShowFurtherThanTheMouthIsOpen() {
        // Otherwise it reads as painted on rather than sticking out.
        let face = FaceExpression(mouthOpen: 0.2, tongue: 1).clamped()
        XCTAssertEqual(face.tongue, 0.2)
    }

    // MARK: - Sleep

    func testAQuietMachineDropsOffGradually() {
        let policy = FaceMood.Policy(drowsyAfter: 5 * 60, asleepAfter: 20 * 60)
        func quiet(_ minutes: Double) -> [AgentSession] {
            var s = session(.idle)
            s.updatedAt = now.addingTimeInterval(-minutes * 60)
            return [s]
        }
        XCTAssertEqual(FaceMood.drowsiness(quiet(2), policy: policy, now: now), 0)
        XCTAssertEqual(FaceMood.drowsiness(quiet(12.5), policy: policy, now: now), 0.5, accuracy: 0.02)
        XCTAssertEqual(FaceMood.drowsiness(quiet(30), policy: policy, now: now), 1)
    }

    func testAWorkingAgentKeepsTheFaceAwakeHoweverQuietItIs() {
        // Events stop entirely during a long tool call — the same silence
        // `SessionStore.prune` had to learn to read. A face that dozes off
        // while a build runs has misread it the same way.
        var building = session(.working)
        building.updatedAt = now.addingTimeInterval(-40 * 60)
        XCTAssertEqual(FaceMood.drowsiness([building], now: now), 0)
    }

    func testNothingAtAllIsAlreadyAsleep() {
        XCTAssertEqual(FaceMood.drowsiness([], now: now), 1)
    }

    func testSleepClosesTheEyesWhateverElseIsGoingOn() {
        // A sleeping face is not a worried one, so the lids win over the
        // pressures rather than averaging with them.
        var stale = session(.idle)
        stale.updatedAt = now.addingTimeInterval(-40 * 60)
        let face = FaceMood.expression(
            for: FaceInputs(sessions: [stale], quota: quota(percent: 99, resetsIn: 160 * hour)),
            now: now)
        XCTAssertLessThan(face.eyeOpenness, 0.1)
        XCTAssertTrue(BlinkRhythm.sleeps(atEnergy: face.energy),
                      "a face this far gone should stop blinking")
        // Asleep with the mouth open and the tongue out is not asleep.
        XCTAssertEqual(face.mouthOpen, 0)
        XCTAssertEqual(face.tongue, 0)
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
