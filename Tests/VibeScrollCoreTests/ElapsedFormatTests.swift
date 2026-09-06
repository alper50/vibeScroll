import XCTest
@testable import VibeScrollCore

final class ElapsedFormatTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 50_000)

    private func label(_ seconds: TimeInterval) -> String {
        TickerFormatter.elapsed(since: t0, now: t0.addingTimeInterval(seconds))
    }

    func testSecondsBelowAMinute() {
        XCTAssertEqual(label(0), "0s")
        XCTAssertEqual(label(5), "5s")
        XCTAssertEqual(label(59), "59s")
    }

    func testMinutesRollOverAtSixty() {
        XCTAssertEqual(label(60), "1m")
        XCTAssertEqual(label(119), "1m")
        XCTAssertEqual(label(59 * 60), "59m")
    }

    func testHoursDropTheMinutesWhenExact() {
        XCTAssertEqual(label(3600), "1h")
        XCTAssertEqual(label(3600 + 4 * 60), "1h 4m")
        XCTAssertEqual(label(2 * 3600), "2h")
    }

    func testClockSkewDoesNotProduceANegativeLabel() {
        // Queued events replay with their original timestamps, so a session can
        // briefly look like it started in the future.
        XCTAssertEqual(label(-30), "0s")
    }
}
