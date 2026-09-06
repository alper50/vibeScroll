import XCTest
@testable import VibeScrollCore

final class CardLayoutTests: XCTestCase {

    func testASingleSessionStillFillsTheMinimumHeight() {
        // Switching from card to list must never shrink the panel — a window
        // that jumps smaller under the pointer reads as a glitch.
        XCTAssertEqual(CardLayout.sessionsHeight(forCount: 1), CardLayout.minSessionsHeight)
        XCTAssertEqual(CardLayout.sessionsHeight(forCount: 0), CardLayout.minSessionsHeight)
    }

    func testHeightGrowsWithTheSessionCount() {
        let four = CardLayout.sessionsHeight(forCount: 4)
        let eight = CardLayout.sessionsHeight(forCount: 8)
        XCTAssertGreaterThan(eight, four)
        XCTAssertEqual(eight - four, 4 * CardLayout.rowHeight, accuracy: 0.001)
    }

    func testHeightIsCappedSoTheAmbientPanelNeverTakesOverTheScreen() {
        XCTAssertEqual(CardLayout.sessionsHeight(forCount: 50), CardLayout.maxSessionsHeight)
        XCTAssertEqual(CardLayout.sessionsHeight(forCount: 12), CardLayout.maxSessionsHeight)
    }

    func testNegativeCountIsTreatedAsOne() {
        XCTAssertEqual(CardLayout.sessionsHeight(forCount: -3), CardLayout.minSessionsHeight)
    }
}
