import XCTest
@testable import VibeScrollCore

final class WorktreePlanTests: XCTestCase {

    func testSlugIsReadableForTurkishPrompts() {
        // Diacritic folding alone leaves "yap-land-r"; the transliteration table
        // exists so a directory listing is still readable.
        XCTAssertEqual(
            WorktreePlan.slug(from: "Kimlik doğrulamayı yeniden yapılandır"),
            "kimlik-dogrulamayi-yeniden-yapil")   // cut at the 32-character limit
        XCTAssertEqual(WorktreePlan.slug(from: "Ölçüm şeması"), "olcum-semasi")
    }

    func testSlugCollapsesJunkAndTrimsEdges() {
        XCTAssertEqual(WorktreePlan.slug(from: "  Fix   the //auth// bug!! "), "fix-the-auth-bug")
        XCTAssertEqual(WorktreePlan.slug(from: "feature/PR #42"), "feature-pr-42")
    }

    func testSlugNeverComesBackEmpty() {
        // An empty component would build the branch "vibescroll/", which git
        // rejects outright.
        XCTAssertEqual(WorktreePlan.slug(from: ""), "task")
        XCTAssertEqual(WorktreePlan.slug(from: "🎉🎉🎉"), "task")
        XCTAssertEqual(WorktreePlan.slug(from: "///"), "task")
    }

    func testSlugRespectsTheLimit() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(WorktreePlan.slug(from: long, limit: 12).count, 12)
    }

    func testPlanIsUniquePerTaskEvenForAnIdenticalPrompt() {
        let a = WorktreePlan.plan(projectPath: "/work/app", prompt: "same thing",
                                  uniqueSuffix: "aaaaaa11", worktreeRoot: "/root")
        let b = WorktreePlan.plan(projectPath: "/work/app", prompt: "same thing",
                                  uniqueSuffix: "bbbbbb22", worktreeRoot: "/root")
        XCTAssertNotEqual(a.branch, b.branch)
        XCTAssertNotEqual(a.path, b.path)
    }

    func testPlanShape() {
        let plan = WorktreePlan.plan(projectPath: "/Users/me/work/vibeScroll",
                                     prompt: "Add the tests", uniqueSuffix: "abc123",
                                     worktreeRoot: "/root/worktrees")
        XCTAssertEqual(plan.branch, "vibescroll/add-the-tests-abc123")
        // Project first, so the worktree root sorts by project.
        XCTAssertEqual(plan.path, "/root/worktrees/vibescroll-add-the-tests-abc123")
    }
}

final class AgentLaunchTests: XCTestCase {

    private func claudePlan(suffix: String? = nil) -> AgentLaunch.Plan? {
        AgentLaunch.plan(for: .claude, executable: "/bin/claude", prompt: "do the thing",
                         sessionId: "11111111-2222-3333-4444-555555555555",
                         workingDirectory: "/wt", systemPromptSuffix: suffix)
    }

    func testClaudePlanIsTheVerifiedInvocation() throws {
        let plan = try XCTUnwrap(claudePlan())
        XCTAssertEqual(plan.workingDirectory, "/wt")
        XCTAssertEqual(plan.arguments, [
            "-p", "do the thing",
            "--session-id", "11111111-2222-3333-4444-555555555555",
            "--output-format", "json",
            "--permission-mode", "bypassPermissions",
        ])
    }

    func testTheWorktreeIsNotClaudesJob() throws {
        // Isolation is plain git so it works the same for every agent; `-w`
        // would tie it to this one.
        let plan = try XCTUnwrap(claudePlan())
        XCTAssertFalse(plan.arguments.contains("-w"))
        XCTAssertFalse(plan.arguments.contains("--worktree"))
    }

    func testNoFlagThatWouldSilenceHooksOrTheTranscript() throws {
        let plan = try XCTUnwrap(claudePlan(suffix: "be careful"))
        for flag in AgentLaunch.forbiddenFlags {
            XCTAssertFalse(plan.arguments.contains(flag), "\(flag) would break observability")
        }
    }

    func testSystemPromptSuffixIsAppendedOnlyWhenItSaysSomething() throws {
        let withSuffix = try XCTUnwrap(claudePlan(suffix: "no questions"))
        XCTAssertEqual(withSuffix.arguments.suffix(2), ["--append-system-prompt", "no questions"])

        XCTAssertFalse(try XCTUnwrap(claudePlan(suffix: "   ")).arguments
            .contains("--append-system-prompt"))
        XCTAssertFalse(try XCTUnwrap(claudePlan(suffix: nil)).arguments
            .contains("--append-system-prompt"))
    }

    func testAgentsWithNoVerifiedHeadlessModeDoNotLaunch() {
        // Queued rather than guessed at: a wrong invocation spends a window.
        for kind in [AgentKind.codex, .cursor, .gemini, .grok, .cli] {
            XCTAssertNil(AgentLaunch.plan(for: kind, executable: "/bin/x", prompt: "p",
                                          sessionId: "s", workingDirectory: "/wt",
                                          systemPromptSuffix: nil),
                         "\(kind) has no verified headless invocation")
        }
    }
}

final class TaskOutcomeTests: XCTestCase {

    /// Trimmed from a real run against Claude Code 2.1.226.
    private let successJSON = Data("""
    {"is_error":false,"num_turns":2,"stop_reason":"end_turn",
     "session_id":"9d31b972-3a1d-4190-9a75-771248d02c1a","total_cost_usd":0.0804957,
     "usage":{"input_tokens":4,"output_tokens":196,"cache_read_input_tokens":55479},
     "permission_denials":[],"terminal_reason":"completed","subtype":"success",
     "api_error_status":null,"result":"Created done.txt with \\"DONE\\".","type":"result"}
    """.utf8)

    func testARealSuccessfulRunIsReadCorrectly() throws {
        let (failure, result) = TaskOutcome.classify(exitCode: 0, stdout: successJSON, timedOut: false)
        XCTAssertNil(failure)
        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.sessionId, "9d31b972-3a1d-4190-9a75-771248d02c1a")
        XCTAssertEqual(r.outputTokens, 196)
        XCTAssertEqual(r.costUSD ?? 0, 0.0804957, accuracy: 0.000001)
        XCTAssertEqual(r.text, "Created done.txt with \"DONE\".")
    }

    func testARateLimitIsTheOneRetryableOutcome() throws {
        let json = Data("""
        {"type":"result","is_error":true,"subtype":"error_during_execution",
         "api_error_status":429}
        """.utf8)
        let (failure, _) = TaskOutcome.classify(exitCode: 1, stdout: json, timedOut: false)
        XCTAssertEqual(failure, .rateLimit)
        XCTAssertTrue(try XCTUnwrap(failure).isRetryable)
    }

    func testAnOverloadIsNotARateLimit() throws {
        // 529 means the provider is busy, not that the quota is gone; retrying
        // it would spend a window on a different problem.
        let json = Data(#"{"type":"result","is_error":true,"api_error_status":529}"#.utf8)
        let (failure, _) = TaskOutcome.classify(exitCode: 1, stdout: json, timedOut: false)
        XCTAssertEqual(failure, .agentError)
        XCTAssertFalse(try XCTUnwrap(failure).isRetryable)
    }

    func testAgentReportedFailureIsNotRetried() {
        let json = Data(#"{"type":"result","is_error":true,"subtype":"error_max_turns"}"#.utf8)
        let (failure, _) = TaskOutcome.classify(exitCode: 0, stdout: json, timedOut: false)
        XCTAssertEqual(failure, .agentError)
    }

    func testCleanExitWithNothingReadableIsItsOwnProblem() {
        // Calling this a non-zero exit would send somebody looking at the wrong
        // thing entirely.
        let (failure, result) = TaskOutcome.classify(
            exitCode: 0, stdout: Data("not json".utf8), timedOut: false)
        XCTAssertEqual(failure, .unreadableResult)
        XCTAssertNil(result)
    }

    func testCrashWithNoOutputIsANonZeroExit() {
        let (failure, _) = TaskOutcome.classify(exitCode: 127, stdout: Data(), timedOut: false)
        XCTAssertEqual(failure, .nonZeroExit)
    }

    func testATimeoutOutranksWhateverTheRunManagedToSay() throws {
        // A killed process can still have flushed a result; what it said does
        // not change why it ended.
        let (failure, result) = TaskOutcome.classify(
            exitCode: nil, stdout: successJSON, timedOut: true)
        XCTAssertEqual(failure, .timedOut)
        XCTAssertNotNil(result, "the partial result is still worth keeping")
    }

    func testStreamingChunksAreNotMistakenForAResult() {
        // stream-json emits many objects; only the final `result` is an outcome.
        let chunk = Data(#"{"type":"assistant","message":{"content":"working"}}"#.utf8)
        XCTAssertNil(TaskOutcome.parse(chunk))
    }
}
