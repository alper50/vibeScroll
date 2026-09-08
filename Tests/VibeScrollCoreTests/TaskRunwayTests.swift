import XCTest
@testable import VibeScrollCore

final class TaskRunwayTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let hour: TimeInterval = 3600

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func window(_ kind: String, _ percent: Int, resetsIn: TimeInterval) -> QuotaWindow {
        QuotaWindow(kind: kind, percentUsed: percent, severity: .normal,
                    resetsAt: now.addingTimeInterval(resetsIn), isActive: false)
    }

    private func snapshot(_ windows: [QuotaWindow], age: TimeInterval = 0) -> QuotaSnapshot {
        QuotaSnapshot(provider: "claude", displayName: "Claude", windows: windows,
                      checkedAt: now.addingTimeInterval(-age))
    }

    /// Fixed id so a `.launch` can be compared by value; `add` would mint a new
    /// UUID on every call and never match.
    private var theTask: QueuedTask {
        QueuedTask(id: "task-1", order: 0, projectPath: "/work/app",
                   prompt: "write the tests", createdAt: now)
    }

    private func oneTaskQueue() -> TaskQueue { TaskQueue(tasks: [theTask]) }

    /// Plenty of weekly room, fresh session window, empty room.
    private func healthy() -> QuotaSnapshot {
        snapshot([
            window("session", 10, resetsIn: 4 * hour),
            // Half the week gone, a fifth of it spent.
            window("weekly_all", 20, resetsIn: 84 * hour),
        ])
    }

    private func decide(
        queue: TaskQueue? = nil,
        snapshot: QuotaSnapshot? = nil,
        sessions: [AgentSession] = [],
        idle: TimeInterval? = 30 * 60,
        lastFinishedAt: Date? = nil,
        policy: TaskRunway.Policy = .init()
    ) -> TaskRunway.Decision {
        TaskRunway.decide(
            queue: queue ?? oneTaskQueue(),
            snapshot: snapshot ?? healthy(),
            liveSessions: sessions,
            userIdleFor: idle,
            lastFinishedAt: lastFinishedAt,
            policy: policy,
            calendar: utc,
            now: now)
    }

    // MARK: - The happy path

    func testLaunchesWhenBehindPaceAndNobodyIsAround() {
        guard case .launch(let task) = decide() else {
            return XCTFail("expected a launch, got \(decide())")
        }
        XCTAssertEqual(task.prompt, "write the tests")
    }

    // MARK: - Weekly pace

    /// The real reading taken from the usage endpoint while designing this:
    /// 85% of the week spent with 67% of it elapsed. Spending more here would
    /// come straight out of the days the person still has to work.
    func testHoldsWhenSpendingIsAheadOfTheWeeksPace() {
        let s = snapshot([
            window("session", 43, resetsIn: 2.4 * hour),
            window("weekly_all", 85, resetsIn: 54.9 * hour),
        ])
        XCTAssertEqual(decide(snapshot: s), .hold(.aheadOfPace(usedPercent: 85, elapsedPercent: 67)))
    }

    func testUnderPaceIsAllowedEvenLateInTheWeek() {
        let s = snapshot([
            window("session", 10, resetsIn: 4 * hour),
            window("weekly_all", 60, resetsIn: 12 * hour),   // ~93% elapsed
        ])
        XCTAssertEqual(decide(snapshot: s), .launch(theTask))
    }

    func testSittingExactlyOnPaceStillHolds() {
        // 50% used at 50% elapsed. The margin exists so the queue does not
        // launch while balanced on the line.
        let s = snapshot([
            window("session", 10, resetsIn: 4 * hour),
            window("weekly_all", 50, resetsIn: 84 * hour),
        ])
        XCTAssertEqual(decide(snapshot: s), .hold(.aheadOfPace(usedPercent: 50, elapsedPercent: 50)))
    }

    // MARK: - The weekly reserve

    func testTheReserveHoldsBackTheLastTenPercentMidWeek() {
        let s = snapshot([
            window("session", 10, resetsIn: 4 * hour),
            window("weekly_all", 92, resetsIn: 48 * hour),
        ])
        XCTAssertEqual(decide(snapshot: s), .hold(.weeklyReserve(percent: 92, reserve: 90)))
    }

    func testTheReserveLiftsOnceTheWeekIsNearlyOver() {
        // Three hours left: whatever is still unspent is about to expire, which
        // is exactly the waste this feature exists to catch.
        let s = snapshot([
            window("session", 10, resetsIn: 4 * hour),
            window("weekly_all", 88, resetsIn: 3 * hour),
        ])
        XCTAssertEqual(decide(snapshot: s), .launch(theTask))
    }

    // MARK: - The session window

    func testANearlySpentSessionWindowHolds() {
        // Starting here buys a rate limit partway through the task.
        let s = snapshot([
            window("session", 95, resetsIn: 1 * hour),
            window("weekly_all", 20, resetsIn: 84 * hour),
        ])
        XCTAssertEqual(decide(snapshot: s), .hold(.sessionWindowSpent(percent: 95)))
    }

    func testSessionWindowIsNotPacedOnlyCapped() {
        // 80% spent with 90% of the window elapsed is far ahead of pace, and is
        // deliberately fine: this window expires either way.
        let s = snapshot([
            window("session", 80, resetsIn: 0.5 * hour),
            window("weekly_all", 20, resetsIn: 84 * hour),
        ])
        XCTAssertEqual(decide(snapshot: s), .launch(theTask))
    }

    func testTheTightestWeeklyPoolWins() {
        // A plan reporting a per-model pool must be gated on the one about to
        // run out, not on the combined figure that hides it.
        let s = snapshot([
            window("session", 10, resetsIn: 4 * hour),
            window("weekly_all", 20, resetsIn: 84 * hour),
            window("weekly_opus", 95, resetsIn: 84 * hour),
        ])
        XCTAssertEqual(decide(snapshot: s), .hold(.weeklyReserve(percent: 95, reserve: 90)))
    }

    // MARK: - Failing closed on missing quota

    func testNoSnapshotHolds() {
        // Called directly: the helper substitutes a healthy snapshot for nil.
        let decision = TaskRunway.decide(
            queue: oneTaskQueue(), snapshot: nil, liveSessions: [],
            userIdleFor: 30 * 60, lastFinishedAt: nil,
            policy: .init(), calendar: utc, now: now)
        XCTAssertEqual(decision, .hold(.quotaUnavailable))
    }

    func testAStaleSnapshotIsNotEvidenceAboutNow() {
        let s = snapshot([
            window("session", 10, resetsIn: 4 * hour),
            window("weekly_all", 20, resetsIn: 84 * hour),
        ], age: 3600)
        XCTAssertEqual(decide(snapshot: s), .hold(.quotaStale(age: 3600)))
    }

    func testAMissingWeeklyWindowHoldsRatherThanProceeding() {
        // Without the weekly reading the guard that keeps this from eating the
        // week is gone, so nothing runs.
        let s = snapshot([window("session", 10, resetsIn: 4 * hour)])
        XCTAssertEqual(decide(snapshot: s), .hold(.quotaUnavailable))
    }

    // MARK: - The room

    func testHoldsWhileTheUsersOwnAgentIsWorking() {
        let session = AgentSession(id: "live", agentKind: .claude, state: .working,
                                   source: .hook, updatedAt: now)
        XCTAssertEqual(decide(sessions: [session]), .hold(.agentBusy))
    }

    func testAFinishedSessionIsNotABlocker() {
        let session = AgentSession(id: "done", agentKind: .claude, state: .done,
                                   source: .hook, updatedAt: now)
        XCTAssertEqual(decide(sessions: [session]), .launch(theTask))
    }

    func testHoldsWhileSomebodyIsAtTheKeyboard() {
        XCTAssertEqual(decide(idle: 60), .hold(.userActive))
    }

    func testUnreadableIdleTimeCountsAsSomebodyBeingHere() {
        // The one mistake worth being cautious about is starting unattended work
        // on a machine whose state we cannot see.
        XCTAssertEqual(decide(idle: nil), .hold(.userActive))
    }

    func testCooldownAfterAFinishedTask() {
        guard case .hold(.cooldown) = decide(lastFinishedAt: now.addingTimeInterval(-10)) else {
            return XCTFail("expected a cooldown hold")
        }
        XCTAssertEqual(decide(lastFinishedAt: now.addingTimeInterval(-120)),
                       .launch(theTask))
    }

    // MARK: - Queue state

    func testAnEmptyQueueHolds() {
        XCTAssertEqual(decide(queue: TaskQueue()), .hold(.queueEmpty))
    }

    func testOnlyOneTaskRunsAtATime() {
        var q = oneTaskQueue()
        let task = q.nextPending!
        q.markRunning(id: task.id, sessionId: "s", worktreeName: nil, now: now)
        XCTAssertEqual(decide(queue: q), .hold(.taskAlreadyRunning))
    }

    func testTheDailyCapCountsRunsAndStopsTheQueue() {
        var q = TaskQueue()
        for i in 0..<4 { q.add(projectPath: "/work/app", prompt: "t\(i)", now: now) }
        let policy = TaskRunway.Policy(maxLaunchesPerDay: 3)
        for _ in 0..<3 {
            guard case .launch(let task) = decide(queue: q, policy: policy) else {
                return XCTFail("expected a launch while under the cap")
            }
            q.markRunning(id: task.id, sessionId: UUID().uuidString, worktreeName: nil, now: now)
            q.markFinished(id: task.id, exitCode: 0, failure: nil, maxRateLimitRetries: 2, now: now)
        }
        XCTAssertEqual(decide(queue: q, policy: policy),
                       .hold(.dailyLimitReached(started: 3, limit: 3)))
    }
}
