import XCTest
@testable import VibeScrollCore

/// The arithmetic the task queue and the face both read. It lives in one place
/// so a gate that refuses to spend and a face that looks worried can never
/// disagree about the same week.
final class QuotaPaceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let hour: TimeInterval = 3600

    private func window(_ kind: String, _ percent: Int, resetsIn: TimeInterval) -> QuotaWindow {
        QuotaWindow(kind: kind, percentUsed: percent, severity: .normal,
                    resetsAt: now.addingTimeInterval(resetsIn), isActive: false)
    }

    func testElapsedFractionIsClampedAndKindAware() {
        let weekly = window("weekly_all", 0, resetsIn: 84 * hour)
        XCTAssertEqual(QuotaPace.elapsedFraction(weekly, now: now)!, 0.5, accuracy: 0.001)

        // Past its reset, and further out than its own length: both clamped
        // rather than producing a fraction outside 0...1.
        XCTAssertEqual(QuotaPace.elapsedFraction(window("weekly_all", 0, resetsIn: -1), now: now), 1)
        XCTAssertEqual(QuotaPace.elapsedFraction(window("session", 0, resetsIn: 99 * hour), now: now), 0)

        // An unknown kind is skipped, never guessed: a wrong duration would
        // silently distort every judgement made from it.
        XCTAssertNil(QuotaPace.elapsedFraction(window("monthly_mystery", 0, resetsIn: hour), now: now))
    }

    func testOverspendIsTheNumberBothCallersActuallyWant() {
        // The real reading taken while designing this: 85% of the week spent
        // with 67% of it elapsed. A percentage alone says nothing — 85% is
        // alarming on Tuesday and fine on Sunday night.
        let tuesday = window("weekly_all", 85, resetsIn: 54.9 * hour)
        XCTAssertEqual(QuotaPace.overspend(tuesday, now: now)!, 0.18, accuracy: 0.01)

        // Same 85%, three hours from the reset: essentially on schedule.
        let sunday = window("weekly_all", 85, resetsIn: 3 * hour)
        XCTAssertEqual(QuotaPace.overspend(sunday, now: now)!, -0.13, accuracy: 0.01)
    }

    func testOverspendIsNilWhenTheWindowCannotBePlaced() {
        XCTAssertNil(QuotaPace.overspend(window("monthly_mystery", 50, resetsIn: hour), now: now))
        XCTAssertNil(QuotaPace.overspend(
            QuotaWindow(kind: "weekly_all", percentUsed: 50, severity: .normal,
                        resetsAt: nil, isActive: true), now: now))
    }

    // MARK: - Telling a new window from the same one reported again

    /// The exact `resets_at` values four polls six seconds apart returned for a
    /// session window that was three and a half hours from renewing. The reset
    /// second never changed; only the fraction did, and it moved both ways.
    private static let jitteredResets = [0.416619, 0.789570, 0.152791, 0.528715]

    func testServerJitterIsNotARollover() {
        // The bug this exists to prevent: a strict `>` on these dates reports a
        // renewal on roughly half of all polls, so a window with three hours
        // left announced itself as renewed three times in an hour.
        let noon = Date(timeIntervalSince1970: 1_773_491_000)
        let observed = Self.jitteredResets.map { noon.addingTimeInterval($0) }
        for (previous, next) in zip(observed, observed.dropFirst()) {
            XCTAssertFalse(
                QuotaPace.isNewWindow(resetsAt: next, after: previous, kind: "session"),
                "sub-second jitter is not a new window")
        }
    }

    func testARealRolloverIsReported() {
        let previous = Date(timeIntervalSince1970: 1_773_491_000)
        XCTAssertTrue(QuotaPace.isNewWindow(
            resetsAt: previous.addingTimeInterval(5 * 3600), after: previous, kind: "session"))
        XCTAssertTrue(QuotaPace.isNewWindow(
            resetsAt: previous.addingTimeInterval(7 * 24 * 3600), after: previous,
            kind: "weekly_all"))
    }

    func testTheBarScalesWithTheWindow() {
        // Four hours is most of a session window and nothing at all of a week,
        // so the same gap has to answer differently for the two kinds.
        let previous = Date(timeIntervalSince1970: 1_773_491_000)
        let fourHoursOn = previous.addingTimeInterval(4 * 3600)
        XCTAssertTrue(QuotaPace.isNewWindow(resetsAt: fourHoursOn, after: previous, kind: "session"))
        XCTAssertFalse(QuotaPace.isNewWindow(resetsAt: fourHoursOn, after: previous, kind: "weekly_all"))
    }

    func testAWindowThatMovedBackwardIsNeverNew() {
        let previous = Date(timeIntervalSince1970: 1_773_491_000)
        XCTAssertFalse(QuotaPace.isNewWindow(
            resetsAt: previous.addingTimeInterval(-5 * 3600), after: previous, kind: "session"))
    }

    func testAnUnknownKindIsNeverCalledNew() {
        // No length to measure the jump against, and announcing a renewal that
        // did not happen is the failure being fixed here.
        let previous = Date(timeIntervalSince1970: 1_773_491_000)
        XCTAssertFalse(QuotaPace.isNewWindow(
            resetsAt: previous.addingTimeInterval(90 * 24 * 3600), after: previous,
            kind: "monthly_something"))
    }

    func testTightestPicksTheOneThatWillStopYou() {
        let windows = [
            window("weekly_all", 20, resetsIn: 84 * hour),
            window("weekly_opus", 95, resetsIn: 84 * hour),
            window("session", 99, resetsIn: hour),
        ]
        XCTAssertEqual(QuotaPace.tightest(windows, in: QuotaPace.weeklyKinds)?.percentUsed, 95)
        XCTAssertEqual(QuotaPace.tightest(windows, in: QuotaPace.sessionKinds)?.percentUsed, 99)
        XCTAssertNil(QuotaPace.tightest([], in: QuotaPace.weeklyKinds))
    }
}
