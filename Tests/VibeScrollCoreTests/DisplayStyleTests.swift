import XCTest
@testable import VibeScrollCore

final class DisplayStyleTests: XCTestCase {

    // MARK: - Which style is on screen

    func testTheNotchNeedsANotch() {
        XCTAssertEqual(DisplayStyle.effective(preferred: .notch, notchAvailable: true), .notch)
        // Lid closed on an external display: fall back rather than vanish.
        XCTAssertEqual(DisplayStyle.effective(preferred: .notch, notchAvailable: false), .floating)
    }

    func testFloatingIsTheDefault() {
        XCTAssertEqual(DisplayStyle.effective(preferred: nil, notchAvailable: true), .floating,
                       "nothing chosen yet means what the app has always been")
        XCTAssertEqual(DisplayStyle.effective(preferred: .floating, notchAvailable: true), .floating)
    }

    func testTheQuestionIsOnlyAskedWhereThereIsAChoice() {
        XCTAssertTrue(DisplayStyle.shouldAsk(preferred: nil, notchAvailable: true))
        XCTAssertFalse(DisplayStyle.shouldAsk(preferred: nil, notchAvailable: false),
                       "one style, nothing to choose")
        XCTAssertFalse(DisplayStyle.shouldAsk(preferred: .floating, notchAvailable: true),
                       "answered once, never again")
        XCTAssertFalse(DisplayStyle.shouldAsk(preferred: .notch, notchAvailable: true))
    }

    // MARK: - Geometry

    func testTheIslandIsTheNotchPlusTwoWings() {
        let notch = 185.0
        XCTAssertEqual(NotchLayout.islandWidth(notchWidth: notch),
                       notch + 2 * (NotchLayout.wing + NotchLayout.edgeInset))
    }

    func testOpeningPopsOutALittleOnEachSide() {
        for notch in [150.0, 185.0, 230.0] {
            let closed = NotchLayout.islandWidth(notchWidth: notch)
            let open = NotchLayout.openWidth(notchWidth: notch)
            XCTAssertEqual(open - closed, NotchLayout.openOutset * 2)
            XCTAssertLessThan(open - closed, 40, "a pop, not a second panel")
            XCTAssertEqual(NotchLayout.contentWidth(notchWidth: notch) + NotchLayout.sidePadding * 2, open,
                           "pages fill the open island")
        }
    }

    func testAnEmptyWingFoldsIntoTheNotch() {
        let pop = NotchLayout.openOutset
        XCTAssertEqual(NotchLayout.wingInset(state: .collapsed, hasContent: false),
                       pop + NotchLayout.wing + NotchLayout.edgeInset,
                       "nothing to show: no black beside the camera at all")
        XCTAssertEqual(NotchLayout.wingInset(state: .collapsed, hasContent: true), pop,
                       "closed, a side sits in by the pop it opens with")
        XCTAssertEqual(NotchLayout.wingInset(state: .expanded, hasContent: false), 0,
                       "open, the pages need the whole width")
    }

    // MARK: - Who is working

    private func session(_ id: String, _ kind: AgentKind, _ state: AgentState, at seconds: Double) -> AgentSession {
        AgentSession(id: id, agentKind: kind, state: state, source: .hook,
                     updatedAt: Date(timeIntervalSince1970: seconds))
    }

    func testTheAgentWithMostLiveSessionsLeads() {
        let summary = NotchLayout.agentSummary(for: [
            session("1", .cursor, .working, at: 1),
            session("2", .cursor, .waiting, at: 2),
            session("3", .claude, .working, at: 9),
        ])
        XCTAssertEqual(summary?.leader, .cursor, "two Cursor sessions beat one fresher Claude one")
        XCTAssertEqual(summary?.active, 3)
        XCTAssertEqual(summary?.waiting, 1)
        XCTAssertEqual(summary?.breakdown.map(\.kind), [.cursor, .claude])
    }

    func testFinishedSessionsDoNotCount() {
        let summary = NotchLayout.agentSummary(for: [
            session("1", .cursor, .done, at: 1),
            session("2", .cursor, .idle, at: 2),
            session("3", .claude, .working, at: 3),
        ])
        XCTAssertEqual(summary?.leader, .claude)
        XCTAssertEqual(summary?.active, 1)
        XCTAssertNil(NotchLayout.agentSummary(for: [session("1", .cursor, .done, at: 1)]),
                     "nobody working: the wing folds away")
    }

    func testATieGoesToWhoeverWasHeardFromLast() {
        let summary = NotchLayout.agentSummary(for: [
            session("1", .claude, .working, at: 5),
            session("2", .cursor, .working, at: 8),
        ])
        XCTAssertEqual(summary?.leader, .cursor)
    }

    func testTheClosedIslandShowsTheSessionWindow() {
        let snapshot = QuotaSnapshot(provider: "claude", displayName: "Claude", windows: [
            QuotaWindow(kind: "weekly_all", percentUsed: 80, severity: .warning, resetsAt: nil, isActive: true),
            QuotaWindow(kind: "session", percentUsed: 35, severity: .normal, resetsAt: nil, isActive: true),
        ], checkedAt: Date())
        XCTAssertEqual(NotchLayout.quotaWindow(in: snapshot)?.kind, "session",
                       "the session window, even when the weekly one is fuller")
        XCTAssertNil(NotchLayout.quotaWindow(in: nil), "no reading, nothing to show")
    }

    func testTheQuotaGoesWithTheAgentsWhenIdleIsNotKept() {
        XCTAssertTrue(NotchLayout.showsQuota(hasReading: true, agentsLive: true, keepWhenIdle: false))
        XCTAssertFalse(NotchLayout.showsQuota(hasReading: true, agentsLive: false, keepWhenIdle: false),
                       "idle: the ring leaves with the agents, like the floating face")
        XCTAssertTrue(NotchLayout.showsQuota(hasReading: true, agentsLive: false, keepWhenIdle: true),
                      "asked to stay out when idle: it stays")
        XCTAssertFalse(NotchLayout.showsQuota(hasReading: false, agentsLive: true, keepWhenIdle: true),
                       "no reading, nothing to draw")
    }

    func testWithoutASessionWindowTheTightestIsShown() {
        let snapshot = QuotaSnapshot(provider: "codex", displayName: "Codex", windows: [
            QuotaWindow(kind: "weekly_all", percentUsed: 40, severity: .normal, resetsAt: nil, isActive: true),
            QuotaWindow(kind: "weekly_opus", percentUsed: 90, severity: .critical, resetsAt: nil, isActive: true),
        ], checkedAt: Date())
        XCTAssertEqual(NotchLayout.quotaWindow(in: snapshot)?.percentUsed, 90)
    }

    func testSwipingStopsAtEitherEnd() {
        XCTAssertEqual(NotchLayout.Page.sessions.neighbour(forward: true), .card)
        XCTAssertEqual(NotchLayout.Page.card.neighbour(forward: false), .sessions)
        XCTAssertNil(NotchLayout.Page.sessions.neighbour(forward: false))
        XCTAssertNil(NotchLayout.Page.tasks.neighbour(forward: true))
    }

    func testPagesAreClampedAndBadMeasurementsFailOpen() {
        let chrome = NotchLayout.tabBarHeight + NotchLayout.bottomPadding
        XCTAssertEqual(NotchLayout.dropHeight(pageHeight: 10), chrome + NotchLayout.minPageHeight)
        XCTAssertEqual(NotchLayout.dropHeight(pageHeight: 5000), chrome + NotchLayout.maxPageHeight)
        XCTAssertEqual(NotchLayout.dropHeight(pageHeight: 150.2), chrome + 151,
                       "rounded up so the last line is never shaved")
        XCTAssertEqual(NotchLayout.dropHeight(pageHeight: .nan), chrome + NotchLayout.maxPageHeight,
                       "too tall is a gap, too short is text cut off")
    }

    func testTheWindowHoldsTheLargestIslandWithoutResizing() {
        let notch = 185.0, top = 32.0
        let size = NotchLayout.windowSize(notchWidth: notch, notchHeight: top)
        XCTAssertGreaterThanOrEqual(Double(size.width), NotchLayout.openWidth(notchWidth: notch))
        XCTAssertGreaterThanOrEqual(Double(size.height),
                                    top + NotchLayout.dropHeight(pageHeight: .infinity))
    }

    func testOpeningLandsOnAWaitingCard() {
        XCTAssertEqual(NotchLayout.openingPage(hasUnreadCard: true, last: .tasks), .card)
        XCTAssertEqual(NotchLayout.openingPage(hasUnreadCard: false, last: .tasks), .tasks)
    }

    // MARK: - The unread badge

    func testACardArrivingUnseenIsUnread() {
        var inbox = NotchInbox()
        inbox.arrived(cardID: "a", alreadyVisible: false)
        XCTAssertTrue(inbox.hasUnread)
        inbox.viewed()
        XCTAssertFalse(inbox.hasUnread)
    }

    func testACardArrivingInFrontOfTheReaderIsNotUnread() {
        // Next, or a picked show: somebody is already looking at it.
        var inbox = NotchInbox(unreadCardID: "a")
        inbox.arrived(cardID: "b", alreadyVisible: true)
        XCTAssertFalse(inbox.hasUnread)
    }

    func testANewerCardReplacesTheBadgeRatherThanStacking() {
        var inbox = NotchInbox()
        inbox.arrived(cardID: "a", alreadyVisible: false)
        inbox.arrived(cardID: "b", alreadyVisible: false)
        XCTAssertEqual(inbox.unreadCardID, "b", "only the latest card is still there to read")
    }

    func testTheBadgeGoesWithTheCard() {
        var inbox = NotchInbox(unreadCardID: "a")
        inbox.cardChanged(to: "a")
        XCTAssertTrue(inbox.hasUnread, "the same card still being there changes nothing")
        inbox.cardChanged(to: nil)
        XCTAssertFalse(inbox.hasUnread, "dismissed unread: nothing left to point at")
    }
}
