import XCTest
@testable import VibeScrollCore

final class CardLayoutTests: XCTestCase {

    func testASingleSessionStillFillsTheMinimumHeight() {
        // Switching from card to list must never shrink the panel — a window
        // that jumps smaller under the pointer reads as a glitch.
        XCTAssertEqual(CardLayout.listHeight(forCount: 1), CardLayout.minListHeight)
        XCTAssertEqual(CardLayout.listHeight(forCount: 0), CardLayout.minListHeight)
    }

    func testHeightGrowsWithTheSessionCount() {
        let four = CardLayout.listHeight(forCount: 4)
        let eight = CardLayout.listHeight(forCount: 8)
        XCTAssertGreaterThan(eight, four)
        XCTAssertEqual(eight - four, 4 * CardLayout.rowHeight, accuracy: 0.001)
    }

    func testHeightIsCappedSoTheAmbientPanelNeverTakesOverTheScreen() {
        XCTAssertEqual(CardLayout.listHeight(forCount: 50), CardLayout.maxListHeight)
        XCTAssertEqual(CardLayout.listHeight(forCount: 12), CardLayout.maxListHeight)
    }

    func testNegativeCountIsTreatedAsOne() {
        XCTAssertEqual(CardLayout.listHeight(forCount: -3), CardLayout.minListHeight)
    }

    // MARK: - Panel composition

    func testAnEmptyPanelHasNoHeight() {
        // The face is its own window now, so a dismissed card leaves nothing
        // for this one to show.
        XCTAssertEqual(CardLayout.panelHeight(for: .none), 0)
        XCTAssertEqual(CardLayout.panelHeight(for: .card), CardLayout.cardHeight)
        XCTAssertEqual(CardLayout.panelHeight(for: .sessions(count: 3, hasQuota: false)),
                       CardLayout.listHeight(forCount: 3))
    }

    func testTheFaceWindowHoldsItsLargestStateAndTheLabel() {
        // Fixed at the largest it ever draws, so the pointer target only ever
        // grows — resizing the window instead makes hover oscillate. The label
        // slot is always reserved so the blob cannot move when it appears.
        XCTAssertGreaterThan(CardLayout.faceHoverSize, CardLayout.faceRestingSize)
        XCTAssertEqual(CardLayout.faceWindowHeight,
                       CardLayout.faceSlot + 4 + CardLayout.faceLabelHeight)
        // Room for the shadow and the growth, or the window's own corner shows
        // through as a straight edge across a surface meant to be a circle.
        XCTAssertGreaterThan(CardLayout.faceSlot, CardLayout.faceHoverSize)
        XCTAssertGreaterThan(CardLayout.faceWindowWidth, CardLayout.faceHoverSize,
                             "the label is a sentence and needs more room than the blob")
    }

    // MARK: - Attaching the card to the face

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private var cardSize: CGSize { CGSize(width: CardLayout.width, height: CardLayout.cardHeight) }

    func testTheCardGrowsOutOfTheTopOfTheFace() {
        // Upward is the direction that reads as emerging, and it is also where
        // the face usually has room: it opens low and most people leave it low.
        let face = CGRect(x: 700, y: 120, width: 124, height: 150)
        let origin = CardLayout.attachedOrigin(
            faceFrame: face, cardSize: cardSize, visibleFrame: screen)
        XCTAssertEqual(origin.y, face.maxY + 10)
        XCTAssertEqual(origin.x, face.midX - CardLayout.width / 2)
    }

    func testTheCardDropsBelowWhenTheFaceIsAgainstTheTop() {
        let face = CGRect(x: 700, y: 700, width: 124, height: 150)
        let origin = CardLayout.attachedOrigin(
            faceFrame: face, cardSize: cardSize, visibleFrame: screen)
        XCTAssertEqual(origin.y, face.minY - 10 - CardLayout.cardHeight)
    }

    func testTheCardIsNeverPushedOffScreen() {
        // A card placed off-screen looks exactly like one that never appeared.
        for x in [-400.0, 1400.0] {
            let face = CGRect(x: x, y: 400, width: 148, height: 148)
            let origin = CardLayout.attachedOrigin(
                faceFrame: face, cardSize: cardSize, visibleFrame: screen)
            XCTAssertGreaterThanOrEqual(origin.x, screen.minX)
            XCTAssertLessThanOrEqual(origin.x + CardLayout.width, screen.maxX)
        }
        let tall = CGRect(x: 700, y: 880, width: 124, height: 150)
        let origin = CardLayout.attachedOrigin(
            faceFrame: tall, cardSize: cardSize, visibleFrame: screen)
        XCTAssertLessThanOrEqual(origin.y + CardLayout.cardHeight, screen.maxY)
    }

    // MARK: - The topic picker

    func testThePickerIsSizedLikeTheSessionList() {
        // One panel, one row height, one clamp. Two functions here would show
        // up as the panel changing size when you switch between the two lists.
        for count in [0, 1, 3, 8, 13, 50] {
            XCTAssertEqual(CardLayout.panelHeight(for: .categories(count: count)),
                           CardLayout.panelHeight(for: .sessions(count: count, hasQuota: false)),
                           "row count \(count)")
        }
    }

    func testEveryTopicFitsWithoutTheClampDoingTheWork() {
        // Thirteen is every category there is, so the picker at its fullest
        // must not be the case that hits the ceiling — a list that is always
        // capped cannot tell the user it has more to scroll.
        let full = CardLayout.panelHeight(for: .categories(count: TopicCategory.allCases.count))
        XCTAssertLessThanOrEqual(full, CardLayout.maxListHeight)
    }

    func testThePickerIsTallerThanACard() {
        // It replaces the card in the same panel; shrinking to open a list
        // reads as the panel breaking rather than as a mode change.
        XCTAssertGreaterThanOrEqual(CardLayout.panelHeight(for: .categories(count: 5)),
                                    CardLayout.panelHeight(for: .card))
    }
}
