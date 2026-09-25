import XCTest
@testable import VibeScrollCore

/// Tasks that build on each other, what a run leaves behind, and the prompt
/// the agent is actually handed.
final class TaskChainTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_773_500_000)

    // MARK: - Chaining

    func testATaskWithNoBaseStartsFromHead() {
        var q = TaskQueue()
        let task = q.add(projectPath: "/w/app", prompt: "do it", now: t0)
        XCTAssertEqual(q.readiness(of: task), .ready(baseBranch: nil))
    }

    func testAChainedTaskWaitsForItsBase() {
        var q = TaskQueue()
        let first = q.add(projectPath: "/w/app", prompt: "step one", now: t0)
        let second = q.add(projectPath: "/w/app", prompt: "step two", basedOn: first.id, now: t0)
        XCTAssertEqual(q.readiness(of: q.task(id: second.id)!), .waiting(on: first.id))
        XCTAssertEqual(q.nextPending?.id, first.id, "the step it waits on goes first")
    }

    func testAChainedTaskStartsFromItsBasesBranchOnceThatSucceeded() {
        var q = TaskQueue()
        let first = q.add(projectPath: "/w/app", prompt: "step one", now: t0)
        let second = q.add(projectPath: "/w/app", prompt: "step two", basedOn: first.id, now: t0)
        q.markRunning(id: first.id, sessionId: "s", worktreeName: "step-one-abc", now: t0)
        XCTAssertNil(q.nextPending, "the only other task waits on the running one")
        q.markFinished(id: first.id, exitCode: 0, failure: nil, maxRateLimitRetries: 2, now: t0)

        XCTAssertEqual(q.readiness(of: q.task(id: second.id)!),
                       .ready(baseBranch: "vibescroll/step-one-abc"))
        XCTAssertEqual(q.nextPending?.id, second.id)
    }

    func testAFailedBaseBlocksRatherThanFallingBackToHead() {
        // Starting from HEAD would silently drop the step it was meant to build on.
        var q = TaskQueue()
        let first = q.add(projectPath: "/w/app", prompt: "step one", now: t0)
        let second = q.add(projectPath: "/w/app", prompt: "step two", basedOn: first.id, now: t0)
        q.markRunning(id: first.id, sessionId: "s", worktreeName: "one", now: t0)
        q.markFinished(id: first.id, exitCode: 1, failure: .agentError, maxRateLimitRetries: 2, now: t0)

        XCTAssertEqual(q.readiness(of: q.task(id: second.id)!), .blocked(by: first.id))
        XCTAssertNil(q.nextPending)
        XCTAssertTrue(q.hasPendingWaitingOnAnother)
    }

    func testRetryingTheBaseUnblocksTheChain() {
        var q = TaskQueue()
        let first = q.add(projectPath: "/w/app", prompt: "step one", now: t0)
        let second = q.add(projectPath: "/w/app", prompt: "step two", basedOn: first.id, now: t0)
        q.markRunning(id: first.id, sessionId: "s", worktreeName: "one", now: t0)
        q.markFinished(id: first.id, exitCode: 1, failure: .agentError, maxRateLimitRetries: 2, now: t0)
        q.requeue(id: first.id)
        XCTAssertEqual(q.readiness(of: q.task(id: second.id)!), .waiting(on: first.id))
    }

    func testOnlyTheSameProjectCanBeBuiltOn() {
        var q = TaskQueue()
        let other = q.add(projectPath: "/w/other", prompt: "elsewhere", now: t0)
        let task = q.add(projectPath: "/w/app", prompt: "here", basedOn: other.id, now: t0)
        XCTAssertNil(task.basedOn, "a branch from another repository is nowhere to start")
        // Offered bases are this project's, however the path is spelled.
        XCTAssertEqual(q.buildableBases(for: "/w/app/").map(\.id), [task.id])
    }

    func testGivenUpTasksAreNotOfferedAsBases() {
        var q = TaskQueue()
        let cancelled = q.add(projectPath: "/w/app", prompt: "no", now: t0)
        q.cancel(id: cancelled.id)
        let kept = q.add(projectPath: "/w/app", prompt: "yes", now: t0)
        XCTAssertEqual(q.buildableBases(for: "/w/app").map(\.id), [kept.id])
    }

    func testRemovingABaseReleasesItsDependents() {
        var q = TaskQueue()
        let first = q.add(projectPath: "/w/app", prompt: "step one", now: t0)
        let second = q.add(projectPath: "/w/app", prompt: "step two", basedOn: first.id, now: t0)
        q.remove(id: first.id)
        XCTAssertNil(q.task(id: second.id)?.basedOn)
        XCTAssertEqual(q.nextPending?.id, second.id)
    }

    func testTheGateSaysWhyAChainIsNotStarting() {
        var q = TaskQueue()
        let first = q.add(projectPath: "/w/app", prompt: "one", now: t0)
        _ = q.add(projectPath: "/w/app", prompt: "two", basedOn: first.id, now: t0)
        q.markRunning(id: first.id, sessionId: "s", worktreeName: "one", now: t0)
        q.markFinished(id: first.id, exitCode: 1, failure: .agentError, maxRateLimitRetries: 2, now: t0)
        let decision = TaskRunway.decide(queue: q, snapshot: nil, liveSessions: [],
                                         userIdleFor: 3600, lastFinishedAt: nil,
                                         policy: .init(), now: t0)
        XCTAssertEqual(decision, .hold(.waitingOnEarlierTask))
    }

    // MARK: - Reports

    func testAReportIsKeptOnTheTaskAndClearedByARetry() {
        var q = TaskQueue()
        let task = q.add(projectPath: "/w/app", prompt: "p", now: t0)
        let report = TaskReport(summary: "Added the toggle.", committed: true)
        q.markRunning(id: task.id, sessionId: "s", worktreeName: "p", now: t0)
        q.markFinished(id: task.id, exitCode: 0, failure: nil, maxRateLimitRetries: 2,
                       report: report, now: t0)
        XCTAssertEqual(q.task(id: task.id)?.report, report)
        q.requeue(id: task.id)
        XCTAssertNil(q.task(id: task.id)?.report, "a retry is a new run with a new report")
    }

    func testNumstatIsParsed() {
        let text = "12\t3\tSources/App/Settings.swift\n-\t-\tResources/icon.png\n\n0\t7\tREADME.md\n"
        let files = TaskReport.parseNumstat(text)
        XCTAssertEqual(files, [
            .init(path: "Sources/App/Settings.swift", added: 12, removed: 3),
            .init(path: "Resources/icon.png", added: nil, removed: nil),
            .init(path: "README.md", added: 0, removed: 7),
        ])
        let report = TaskReport(changedFiles: files)
        XCTAssertEqual(report.totalAdded, 12)
        XCTAssertEqual(report.totalRemoved, 10)
    }

    func testNumstatSkipsLinesItCannotRead() {
        XCTAssertEqual(TaskReport.parseNumstat("warning: something\n1\t2\n"), [])
    }

    // MARK: - Old queue files

    func testAQueueWrittenBeforeTheseFieldsStillLoads() throws {
        let json = """
        {"tasks":[{"id":"a","projectPath":"/w/app","prompt":"Fix the login bug\\nDetails…",
                   "status":"succeeded","order":0,"createdAt":0}],"launches":[]}
        """
        let q = try JSONDecoder().decode(TaskQueue.self, from: Data(json.utf8))
        let task = try XCTUnwrap(q.task(id: "a"))
        XCTAssertNil(task.title)
        XCTAssertNil(task.report)
        XCTAssertEqual(task.displayTitle, "Fix the login bug")
    }

    func testAnUnreadableReportCostsTheReportNotTheQueue() throws {
        let json = """
        {"tasks":[{"id":"a","projectPath":"/w","prompt":"p","report":{"committed":"yes"}}]}
        """
        let q = try JSONDecoder().decode(TaskQueue.self, from: Data(json.utf8))
        XCTAssertNotNil(q.task(id: "a"))
        XCTAssertNil(q.task(id: "a")?.report)
    }

    // MARK: - Titles and prompts

    func testTheTitleIsPreferredForDisplay() {
        var q = TaskQueue()
        let task = q.add(projectPath: "/w", prompt: "a long set of instructions",
                         title: "  Dark mode  ", now: t0)
        XCTAssertEqual(task.displayTitle, "Dark mode")
        let blank = q.add(projectPath: "/w", prompt: "\n  First real line\nmore", title: "  ", now: t0)
        XCTAssertNil(blank.title)
        XCTAssertEqual(blank.displayTitle, "First real line")
    }

    func testThePromptCarriesTheFinishLineAsItsOwnSection() {
        let prompt = AgentLaunch.composedPrompt(
            instructions: "Add a toggle.", doneWhen: "swift test passes", continuesFrom: nil)
        XCTAssertEqual(prompt, "Add a toggle.\n\n## Done when\nswift test passes")
    }

    func testAChainedPromptSaysWhereItPicksUp() {
        let prompt = AgentLaunch.composedPrompt(
            instructions: "Now wire it up.", doneWhen: nil, continuesFrom: "Add a toggle")
        XCTAssertTrue(prompt.hasPrefix("Now wire it up."))
        XCTAssertTrue(prompt.contains("## Context"))
        XCTAssertTrue(prompt.contains("“Add a toggle”"))
        XCTAssertFalse(prompt.contains("## Done when"))
    }

    func testAnEmptyFinishLineAddsNothing() {
        XCTAssertEqual(AgentLaunch.composedPrompt(instructions: "  Do it.\n", doneWhen: "  \n",
                                                  continuesFrom: nil),
                       "Do it.")
    }
}
