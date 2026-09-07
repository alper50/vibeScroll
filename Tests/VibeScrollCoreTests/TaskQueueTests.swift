import XCTest
@testable import VibeScrollCore

final class TaskQueueTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func queueWithTwo() -> TaskQueue {
        var q = TaskQueue()
        q.add(projectPath: "/work/a", prompt: "first", now: t0)
        q.add(projectPath: "/work/b", prompt: "second", now: t0.addingTimeInterval(1))
        return q
    }

    // MARK: - Ordering

    func testAddAssignsIncreasingOrderAndNextRunsTheFirst() {
        let q = queueWithTwo()
        XCTAssertEqual(q.tasks.map(\.order), [0, 1])
        XCTAssertEqual(q.nextPending?.prompt, "first")
    }

    func testNextPendingIsStableWhenOrderAndTimeTie() {
        // Two tasks added in the same instant with the same order must not be
        // able to swap between ticks — the runner asks repeatedly.
        let a = QueuedTask(id: "b-id", order: 0, projectPath: "/p", prompt: "b", createdAt: t0)
        let b = QueuedTask(id: "a-id", order: 0, projectPath: "/p", prompt: "a", createdAt: t0)
        let q = TaskQueue(tasks: [a, b])
        XCTAssertEqual(q.nextPending?.id, "a-id")
        XCTAssertEqual(q.nextPending?.id, "a-id")
    }

    func testMoveRenumbersDensely() {
        var q = queueWithTwo()
        q.add(projectPath: "/work/c", prompt: "third", now: t0.addingTimeInterval(2))
        let last = q.tasks.first { $0.prompt == "third" }!
        q.move(id: last.id, to: 0)
        XCTAssertEqual(q.nextPending?.prompt, "third")
        XCTAssertEqual(q.tasks.map(\.order).sorted(), [0, 1, 2])
    }

    func testOnlyPendingTasksAreEligible() {
        var q = queueWithTwo()
        let first = q.nextPending!
        q.markRunning(id: first.id, sessionId: "s", worktreeName: nil, now: t0)
        XCTAssertEqual(q.running?.id, first.id)
        XCTAssertEqual(q.nextPending?.prompt, "second")
    }

    // MARK: - Outcomes

    func testCleanExitSucceeds() {
        var q = queueWithTwo()
        let task = q.nextPending!
        q.markRunning(id: task.id, sessionId: "s", worktreeName: nil, now: t0)
        q.markFinished(id: task.id, exitCode: 0, failure: nil, maxRateLimitRetries: 2, now: t0)
        XCTAssertEqual(q.task(id: task.id)?.status, .succeeded)
        XCTAssertEqual(q.task(id: task.id)?.attempts, 0)
    }

    func testANonRetryableFailureIsNeverRetried() {
        var q = queueWithTwo()
        let task = q.nextPending!
        q.markRunning(id: task.id, sessionId: "s", worktreeName: nil, now: t0)
        // Re-running would spend a whole window to reach the same answer.
        q.markFinished(id: task.id, exitCode: 1, failure: .nonZeroExit,
                       maxRateLimitRetries: 2, now: t0)
        XCTAssertEqual(q.task(id: task.id)?.status, .failed)
        XCTAssertEqual(q.task(id: task.id)?.attempts, 0)
    }

    func testARateLimitGoesBackInLineThenParks() {
        var q = queueWithTwo()
        let task = q.nextPending!

        q.markRunning(id: task.id, sessionId: "s1", worktreeName: nil, now: t0)
        q.markFinished(id: task.id, exitCode: nil, failure: .rateLimit,
                       maxRateLimitRetries: 2, now: t0)
        XCTAssertEqual(q.task(id: task.id)?.status, .pending, "a rate limit is about the moment, not the task")
        XCTAssertEqual(q.task(id: task.id)?.attempts, 1)

        q.markRunning(id: task.id, sessionId: "s2", worktreeName: nil, now: t0.addingTimeInterval(60))
        q.markFinished(id: task.id, exitCode: nil, failure: .rateLimit,
                       maxRateLimitRetries: 2, now: t0.addingTimeInterval(60))
        // Parked, not failed: it is waiting for a person, and the queue should
        // say so rather than quietly declaring the task over.
        XCTAssertEqual(q.task(id: task.id)?.status, .parked)
        XCTAssertEqual(q.task(id: task.id)?.attempts, 2)
    }

    func testRequeueClearsTheOutcome() {
        var q = queueWithTwo()
        let task = q.nextPending!
        q.markRunning(id: task.id, sessionId: "s", worktreeName: nil, now: t0)
        q.markFinished(id: task.id, exitCode: 1, failure: .nonZeroExit,
                       maxRateLimitRetries: 2, now: t0)
        q.requeue(id: task.id)
        let after = q.task(id: task.id)
        XCTAssertEqual(after?.status, .pending)
        XCTAssertNil(after?.failure)
        XCTAssertNil(after?.exitCode)
        XCTAssertEqual(after?.attempts, 0)
    }

    // MARK: - Session ownership

    func testOwnsSessionMatchesTheIdHandedToTheAgent() {
        var q = queueWithTwo()
        let task = q.nextPending!
        q.markRunning(id: task.id, sessionId: "sess-abc", worktreeName: nil, now: t0)
        XCTAssertTrue(q.ownsSession("sess-abc"))
        XCTAssertFalse(q.ownsSession("a-session-the-user-started"))
    }

    func testOwnershipOutlivesTheRun() {
        // The agent's Stop hook fires before its process exits, so the daemon
        // can see the session finish before the runner records the outcome.
        // Ownership scoped to `running` would lose that race.
        var q = queueWithTwo()
        let task = q.nextPending!
        q.markRunning(id: task.id, sessionId: "sess-abc", worktreeName: nil, now: t0)
        q.markFinished(id: task.id, exitCode: 0, failure: nil, maxRateLimitRetries: 2, now: t0)
        XCTAssertEqual(q.task(id: task.id)?.status, .succeeded)
        XCTAssertTrue(q.ownsSession("sess-abc"))
    }

    func testAnUnstartedTaskOwnsNothing() {
        XCTAssertFalse(queueWithTwo().ownsSession("anything"))
    }

    // MARK: - What counts as finished

    func testFinishedIsEveryStateThatWillNotRunAgain() {
        var q = TaskQueue()
        for name in ["ok", "bad", "stuck", "gone", "waiting"] {
            q.add(projectPath: "/p", prompt: name, now: t0)
        }
        func id(_ prompt: String) -> String { q.tasks.first { $0.prompt == prompt }!.id }

        q.markRunning(id: id("ok"), sessionId: "s", worktreeName: nil, now: t0)
        q.markFinished(id: id("ok"), exitCode: 0, failure: nil, maxRateLimitRetries: 2, now: t0)
        q.markRunning(id: id("bad"), sessionId: "s", worktreeName: nil, now: t0)
        q.markFinished(id: id("bad"), exitCode: 1, failure: .nonZeroExit,
                       maxRateLimitRetries: 2, now: t0)
        q.markRunning(id: id("stuck"), sessionId: "s", worktreeName: nil, now: t0)
        q.markFinished(id: id("stuck"), exitCode: nil, failure: .rateLimit,
                       maxRateLimitRetries: 1, now: t0)   // parked
        q.cancel(id: id("gone"))
        // "waiting" is left pending.

        XCTAssertEqual(Set(q.finished.map(\.prompt)), ["ok", "bad", "stuck", "gone"])
    }

    func testARunningTaskIsNeverSweptUp() {
        var q = queueWithTwo()
        let task = q.nextPending!
        q.markRunning(id: task.id, sessionId: "s", worktreeName: nil, now: t0)
        XCTAssertTrue(q.finished.isEmpty)
    }

    func testBulkRemoveTakesOnlyWhatItWasGiven() {
        var q = queueWithTwo()
        let first = q.nextPending!
        q.remove(ids: [first.id, "not-a-real-id"])
        XCTAssertEqual(q.tasks.map(\.prompt), ["second"])
    }

    // MARK: - Launch ledger

    func testTheLedgerCountsRunsNotTasks() {
        var q = queueWithTwo()
        let task = q.nextPending!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        // One task, retried: it has spent two windows and the daily cap has to
        // see two, or a failing task would run all night for free.
        q.markRunning(id: task.id, sessionId: "s1", worktreeName: nil, now: t0)
        q.markFinished(id: task.id, exitCode: nil, failure: .rateLimit,
                       maxRateLimitRetries: 3, now: t0)
        q.markRunning(id: task.id, sessionId: "s2", worktreeName: nil, now: t0.addingTimeInterval(600))
        XCTAssertEqual(q.launchCount(on: t0, calendar: cal), 2)
    }

    func testLedgerCountIsPerCalendarDay() {
        var q = queueWithTwo()
        let task = q.nextPending!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        q.markRunning(id: task.id, sessionId: "s", worktreeName: nil, now: t0)
        let tomorrow = t0.addingTimeInterval(36 * 3600)
        XCTAssertEqual(q.launchCount(on: t0, calendar: cal), 1)
        XCTAssertEqual(q.launchCount(on: tomorrow, calendar: cal), 0)
    }

    func testLedgerIsPrunedSoTheFileCannotGrowForever() {
        var q = queueWithTwo()
        let task = q.nextPending!
        q.markRunning(id: task.id, sessionId: "s", worktreeName: nil, now: t0)
        q.markRunning(id: task.id, sessionId: "s",
                      worktreeName: nil, now: t0.addingTimeInterval(30 * 24 * 3600))
        XCTAssertEqual(q.launches.count, 1)
    }

    // MARK: - Persistence

    func testQueueSurvivesARoundTrip() throws {
        var q = queueWithTwo()
        let task = q.nextPending!
        q.markRunning(id: task.id, sessionId: "sess-1", worktreeName: "wt", now: t0)

        let data = try JSONEncoder().encode(q)
        let back = try JSONDecoder().decode(TaskQueue.self, from: data)
        XCTAssertEqual(back, q)
        XCTAssertEqual(back.running?.sessionId, "sess-1")
    }

    func testAFileFromAnOlderBuildStillDecodes() throws {
        // Only the fields a task cannot exist without. Everything added later
        // must fall back rather than strand the whole queue.
        let json = """
        {"tasks":[{"id":"t1","projectPath":"/work/a","prompt":"do the thing"}]}
        """
        let q = try JSONDecoder().decode(TaskQueue.self, from: Data(json.utf8))
        XCTAssertEqual(q.tasks.count, 1)
        XCTAssertEqual(q.nextPending?.id, "t1")
        XCTAssertEqual(q.tasks[0].status, .pending)
        XCTAssertEqual(q.tasks[0].attempts, 0)
        XCTAssertTrue(q.launches.isEmpty)
    }
}
