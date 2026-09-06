import XCTest
@testable import VibeScrollCore

final class QuotaTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 100_000)

    private func parse(_ json: String) -> QuotaSnapshot? {
        let data = Data(json.utf8)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return obj.flatMap { ClaudeUsageParser.parse($0, now: now) }
    }

    /// The real response shape, captured from the live endpoint. Trimmed to the
    /// fields we read, plus two of the null-valued internal codenames it also
    /// returns — those must be ignored, not tripped over.
    private let liveShape = """
    {
      "five_hour": {"utilization": 66.0, "resets_at": "2026-09-06T18:39:59.831054+00:00"},
      "seven_day": {"utilization": 76.0, "resets_at": "2026-09-09T17:59:59.831083+00:00"},
      "nimbus_quill": {"utilization": 0.0, "resets_at": null},
      "tangelo": null,
      "limits": [
        {"kind": "session", "group": "session", "percent": 66,
         "severity": "normal", "resets_at": "2026-09-06T18:39:59.831054+00:00", "is_active": false},
        {"kind": "weekly_all", "group": "weekly", "percent": 76,
         "severity": "warning", "resets_at": "2026-09-09T17:59:59.831083+00:00", "is_active": true}
      ]
    }
    """

    func testParsesTheLiveResponseShape() throws {
        let snapshot = try XCTUnwrap(parse(liveShape))
        XCTAssertEqual(snapshot.provider, "claude")
        XCTAssertEqual(snapshot.windows.count, 2)

        let session = snapshot.windows[0]
        XCTAssertEqual(session.kind, "session")
        XCTAssertEqual(session.percentUsed, 66)
        XCTAssertEqual(session.severity, .normal)
        XCTAssertFalse(session.isActive)
        XCTAssertNotNil(session.resetsAt)

        let weekly = snapshot.windows[1]
        XCTAssertEqual(weekly.severity, .warning)
        XCTAssertTrue(weekly.isActive)
    }

    func testLimitsArrayIsPreferredOverTheLegacyWindows() {
        // Both shapes are present in the live response; the structured one wins
        // because only it carries severity.
        let snapshot = parse(liveShape)
        XCTAssertEqual(snapshot?.windows.map(\.kind), ["session", "weekly_all"])
    }

    func testFallsBackToLegacyWindowsWhenLimitsIsAbsent() throws {
        let snapshot = try XCTUnwrap(parse("""
        {"five_hour": {"utilization": 12.0}, "seven_day": {"utilization": 30.0}}
        """))
        XCTAssertEqual(snapshot.windows.map(\.kind), ["five_hour", "seven_day"])
        XCTAssertEqual(snapshot.windows[0].severity, .unknown)
        XCTAssertEqual(snapshot.tightest?.percentUsed, 30)
    }

    func testTightestWindowIsTheOneClosestToItsLimit() {
        XCTAssertEqual(parse(liveShape)?.tightest?.kind, "weekly_all")
    }

    func testExhaustionIsDrivenByPercentNotBySeverityText() throws {
        // Severity strings are the provider's vocabulary and can change;
        // "100% used" cannot.
        let snapshot = try XCTUnwrap(parse("""
        {"limits": [{"kind": "session", "percent": 100, "severity": "normal", "is_active": true}]}
        """))
        XCTAssertTrue(snapshot.isExhausted)
    }

    func testWarningIsReportedSeparatelyFromExhaustion() {
        let snapshot = parse(liveShape)
        XCTAssertTrue(snapshot?.isWarning ?? false, "76% weekly is flagged 'warning' upstream")
        XCTAssertFalse(snapshot?.isExhausted ?? true, "but nothing is spent yet")
    }

    func testUnknownSeverityIsNeverTreatedAsCritical() throws {
        // A field they add later must not fire a false alarm.
        let snapshot = try XCTUnwrap(parse("""
        {"limits": [{"kind": "session", "percent": 10, "severity": "chartreuse", "is_active": true}]}
        """))
        XCTAssertEqual(snapshot.windows[0].severity, .unknown)
        XCTAssertFalse(snapshot.isWarning)
        XCTAssertFalse(snapshot.isExhausted)
    }

    func testUnreadableEntriesAreDroppedNotFatal() throws {
        let snapshot = try XCTUnwrap(parse("""
        {"limits": [{"kind": "session", "percent": 40, "severity": "normal"},
                    {"group": "weekly"},
                    {"kind": "weekly_all"}]}
        """))
        XCTAssertEqual(snapshot.windows.count, 1)
    }

    func testEmptyOrUnusableResponseYieldsNoSnapshot() {
        XCTAssertNil(parse("{}"))
        XCTAssertNil(parse(#"{"limits": []}"#))
        XCTAssertNil(parse(#"{"tangelo": null}"#))
    }

    func testFractionalPercentRoundsRatherThanTruncates() throws {
        // 99.6% must not read as 99%.
        let snapshot = try XCTUnwrap(parse(#"{"five_hour": {"utilization": 99.6}}"#))
        XCTAssertEqual(snapshot.windows[0].percentUsed, 100)
    }

    func testResetDateParsesWithFractionalSeconds() {
        // The live endpoint sends microseconds; a formatter without
        // .withFractionalSeconds returns nil for these.
        XCTAssertNotNil(ClaudeUsageParser.date(from: "2026-09-06T18:39:59.831054+00:00"))
        XCTAssertNotNil(ClaudeUsageParser.date(from: "2026-09-06T18:39:59Z"))
        XCTAssertNil(ClaudeUsageParser.date(from: ""))
        XCTAssertNil(ClaudeUsageParser.date(from: nil))
    }

    func testWindowLabels() {
        let make = { (kind: String) in
            QuotaWindow(kind: kind, percentUsed: 0, severity: .normal, resetsAt: nil, isActive: true)
        }
        XCTAssertEqual(make("session").label, "Session")
        XCTAssertEqual(make("weekly_all").label, "Weekly")
        XCTAssertEqual(make("five_hour").label, "Session")
        // An unseen kind still shows something truthful.
        XCTAssertEqual(make("monthly_all").label, "Monthly All")
    }
}
