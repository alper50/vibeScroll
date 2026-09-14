import XCTest
@testable import VibeScrollCore

final class QuotaSummaryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_773_500_000)

    private func session(_ kind: AgentKind, id: String = UUID().uuidString) -> AgentSession {
        AgentSession(id: id, agentKind: kind, project: "/w/app", state: .working,
                     source: .hook, updatedAt: Date(timeIntervalSince1970: 1_773_500_000))
    }

    private func window(_ kind: String, _ percent: Int,
                        _ severity: QuotaWindow.Severity = .normal) -> QuotaWindow {
        QuotaWindow(kind: kind, percentUsed: percent, severity: severity,
                    resetsAt: nil, isActive: true)
    }

    private func snapshot(_ windows: [QuotaWindow], provider: String = "claude") -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, displayName: "Claude",
                      windows: windows, checkedAt: now)
    }

    // MARK: - When there is nothing honest to say

    func testNoSnapshotMeansNoFooter() {
        // The probe is off by default. The list carries on exactly as it is.
        XCTAssertNil(QuotaSummary.summarise(sessions: [session(.claude)], snapshot: nil))
    }

    func testAReadingWithNobodyOnScreenToAttachItToIsNotShown() {
        // A Claude quota says nothing about a list of Codex and Cursor sessions,
        // and the sessions panel is about the list in front of you.
        let summary = QuotaSummary.summarise(
            sessions: [session(.codex), session(.cursor)],
            snapshot: snapshot([window("session", 58)]))
        XCTAssertNil(summary)
    }

    func testAnEmptyWindowListIsNotAFooter() {
        XCTAssertNil(QuotaSummary.summarise(
            sessions: [session(.claude)], snapshot: snapshot([])))
    }

    func testAnUnknownProviderCoversNothing() {
        XCTAssertTrue(QuotaSummary.coveredKinds(provider: "openai").isEmpty)
        XCTAssertNil(QuotaSummary.summarise(
            sessions: [session(.claude)],
            snapshot: snapshot([window("session", 58)], provider: "openai")))
    }

    // MARK: - Attribution

    func testAnAllClaudeListNeedsNoOwnersName() {
        // Naming the owner when it owns everything on screen is noise.
        let summary = QuotaSummary.summarise(
            sessions: [session(.claude), session(.claude)],
            snapshot: snapshot([window("session", 58)]))
        XCTAssertEqual(summary?.attribution, nil)
        XCTAssertEqual(summary?.untrackedCount, 0)
    }

    func testAMixedListNamesWhoseQuotaItIs() {
        // The failure this prevents: one figure under a list of four agents,
        // looking like it covers all four.
        let summary = QuotaSummary.summarise(
            sessions: [session(.claude), session(.codex), session(.gemini)],
            snapshot: snapshot([window("session", 58)]))
        XCTAssertEqual(summary?.attribution, "Claude")
        XCTAssertEqual(summary?.untrackedCount, 2)
    }

    func testDroidIsNotCoveredByClaudeCodesSignIn() {
        // Droid runs Claude models against its own billing, and the probe reads
        // Claude Code's own sign-in. Counting it would be a plain lie.
        XCTAssertEqual(QuotaSummary.coveredKinds(provider: "claude"), [.claude])
        let summary = QuotaSummary.summarise(
            sessions: [session(.claude), session(.droid)],
            snapshot: snapshot([window("session", 58)]))
        XCTAssertEqual(summary?.untrackedCount, 1)
    }

    // MARK: - Which windows, in what order

    func testSessionComesBeforeWeekly() {
        // The five-hour window is the one that runs out while you are watching.
        let summary = QuotaSummary.summarise(
            sessions: [session(.claude)],
            snapshot: snapshot([window("weekly_all", 24), window("session", 58)]))
        XCTAssertEqual(summary?.windows.map(\.label), ["Session", "Weekly"])
    }

    func testSeveralWeeklyPoolsAreAllReported() {
        // A plan with per-model pools has more than one weekly number, and the
        // combined figure hides whichever is about to run out.
        let summary = QuotaSummary.summarise(
            sessions: [session(.claude)],
            snapshot: snapshot([
                window("session", 40), window("weekly_all", 24), window("weekly_opus", 91),
            ]))
        XCTAssertEqual(summary?.windows.map(\.label),
                       ["Session", "Weekly (Opus)", "Weekly"])
    }

    func testTheTightestSurvivesTheCap() {
        // Three fit in a 340pt footer; a fourth would truncate. The one that
        // will actually stop you must not be the one that gets dropped.
        let summary = QuotaSummary.summarise(
            sessions: [session(.claude)],
            snapshot: snapshot([
                window("session", 40), window("weekly_all", 10),
                window("weekly_opus", 95), window("weekly_sonnet", 60),
            ]),
            limit: 3)
        XCTAssertEqual(summary?.windows.map(\.label),
                       ["Session", "Weekly (Opus)", "Weekly (Sonnet)"])
    }

    func testAnUnrecognisedKindSortsLastButIsStillShown() {
        // A window kind added later still means something to the person paying
        // for it, and `QuotaWindow.label` already falls back to the raw name.
        let summary = QuotaSummary.summarise(
            sessions: [session(.claude)],
            snapshot: snapshot([window("monthly_extra", 12), window("session", 58)]))
        XCTAssertEqual(summary?.windows.map(\.label), ["Session", "Monthly Extra"])
    }

    // MARK: - What each window carries

    func testExhaustionIsDrivenByPercentNotBySeverityText() {
        let summary = QuotaSummary.summarise(
            sessions: [session(.claude)],
            snapshot: snapshot([window("session", 100, .normal)]))
        XCTAssertEqual(summary?.windows.first?.isExhausted, true)
    }

    func testSeverityTravelsFromTheProvider() {
        // No threshold is invented here; the provider classifies.
        let summary = QuotaSummary.summarise(
            sessions: [session(.claude)],
            snapshot: snapshot([window("session", 77, .warning)]))
        XCTAssertEqual(summary?.windows.first?.severity, .warning)
        XCTAssertEqual(summary?.windows.first?.isExhausted, false)
    }

    // MARK: - Layout follows

    func testTheFooterChangesThePanelHeight() {
        // The footer is carried in the panel's size rather than overlapping the
        // list; without this the last row sits behind it.
        XCTAssertEqual(
            CardLayout.panelHeight(for: .sessions(count: 8, hasQuota: true))
                - CardLayout.panelHeight(for: .sessions(count: 8, hasQuota: false)),
            CardLayout.quotaFooterHeight, accuracy: 0.001)
    }

    func testTheFooterCannotPushThePanelPastItsCeiling() {
        XCTAssertLessThanOrEqual(
            CardLayout.panelHeight(for: .sessions(count: 40, hasQuota: true)),
            CardLayout.maxListHeight)
    }
}
