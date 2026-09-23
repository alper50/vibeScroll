import XCTest
@testable import VibeScrollCore

final class CardLayoutTests: XCTestCase {

    func testASmallListGetsASmallPanel() {
        // The panel used to be floored at card height, so one agent sat in
        // 200pt that was three quarters empty. It is now exactly as tall as
        // what is in it.
        XCTAssertEqual(CardLayout.listHeight(forCount: 1),
                       CardLayout.chrome + CardLayout.rowHeight, accuracy: 0.001)
        XCTAssertLessThan(CardLayout.listHeight(forCount: 1), CardLayout.cardHeight)
    }

    func testAnEmptyListIsSizedLikeAListOfOne() {
        // "No active agents" needs a row's worth of space to sit in, and a
        // panel that collapses to its header reads as broken rather than empty.
        XCTAssertEqual(CardLayout.listHeight(forCount: 0),
                       CardLayout.listHeight(forCount: 1))
    }

    func testChromeIsDerivedFromThePartsTheViewDraws() {
        // One tuned number nobody can re-derive drifts the moment the header
        // changes, and the symptom is a list that scrolls when it should fit.
        XCTAssertEqual(CardLayout.chrome,
                       CardLayout.listPadding * 2 + CardLayout.listHeaderHeight
                           + CardLayout.listSpacing,
                       accuracy: 0.001)
    }

    func testEveryRowCountBelowTheCapIsItsOwnHeight() {
        // The point of the change: the panel tracks the session count instead
        // of snapping to one of two sizes.
        var heights: Set<Double> = []
        for count in 1...13 {
            heights.insert(CardLayout.listHeight(forCount: count))
        }
        XCTAssertEqual(heights.count, 13, "some counts share a height")
    }

    func testHeightGrowsWithTheSessionCount() {
        let four = CardLayout.listHeight(forCount: 4)
        let eight = CardLayout.listHeight(forCount: 8)
        XCTAssertGreaterThan(eight, four)
        XCTAssertEqual(eight - four, 4 * CardLayout.rowHeight, accuracy: 0.001)
    }

    func testHeightIsCappedSoTheAmbientPanelNeverTakesOverTheScreen() {
        XCTAssertEqual(CardLayout.listHeight(forCount: 50), CardLayout.maxListHeight)
        XCTAssertEqual(CardLayout.listHeight(forCount: 100), CardLayout.maxListHeight)
        // Every count on the way up stays under it, so the cap is a ceiling
        // rather than the height the panel usually has.
        for count in 1...12 {
            XCTAssertLessThan(CardLayout.listHeight(forCount: count), CardLayout.maxListHeight)
        }
    }

    func testTheQuotaFooterCannotPushAFullListPastTheCap() {
        for count in [11, 13, 40] {
            XCTAssertLessThanOrEqual(
                CardLayout.panelHeight(for: .sessions(count: count, hasQuota: true)),
                CardLayout.maxListHeight)
        }
    }

    func testNegativeCountIsTreatedAsOne() {
        XCTAssertEqual(CardLayout.listHeight(forCount: -3),
                       CardLayout.listHeight(forCount: 1))
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

    func testTheFullPickerFitsWithoutScrolling() {
        // One row per show. Well under the cap, so the whole catalogue is on
        // screen at once — the cap exists for a long session list, not for this.
        let rows = Double(CardCategory.allCases.count)
        let full = CardLayout.panelHeight(for: .categories(count: CardCategory.allCases.count))
        XCTAssertLessThan(full, CardLayout.maxListHeight)
        XCTAssertLessThanOrEqual(
            CardLayout.chrome + rows * CardLayout.rowHeight, CardLayout.maxListHeight,
            "the picker would scroll — a show was added that the cap does not leave room for")
    }

    func testThePickerIsSizedToItsRowsLikeAnyOtherList() {
        // It used to be floored at card height so opening it never shrank the
        // panel. Sizing to content won that trade: a five-topic picker in a
        // 200pt panel was mostly empty panel.
        XCTAssertEqual(CardLayout.panelHeight(for: .categories(count: 5)),
                       CardLayout.chrome + 5 * CardLayout.rowHeight, accuracy: 0.001)
        XCTAssertLessThan(CardLayout.panelHeight(for: .categories(count: 5)),
                          CardLayout.cardHeight)
    }

    // MARK: - Which windows are up

    private func visibility(
        _ content: CardLayout.PanelContent, sessions: Bool = false, card: Bool = false,
        faceWhenIdle: Bool = true, suppressed: Bool = false
    ) -> CardLayout.PanelVisibility {
        CardLayout.visibility(content: content, hasSessions: sessions, hasCard: card,
                              showsFaceWhenIdle: faceWhenIdle, suppressed: suppressed)
    }

    func testTheCardIsNeverUpWithoutTheFace() {
        // The bug this exists to prevent. The card is placed against the face's
        // frame, so one without the other falls back to the screen corner and
        // sits there orphaned — having visibly jumped to get there.
        let contents: [CardLayout.PanelContent] = [
            .none, .card, .moment,
            .sessions(count: 0, hasQuota: false), .sessions(count: 4, hasQuota: true),
            .categories(count: 17),
        ]
        for content in contents {
            for sessions in [true, false] {
                for card in [true, false] {
                    for idle in [true, false] {
                        for suppressed in [true, false] {
                            let v = visibility(content, sessions: sessions, card: card,
                                               faceWhenIdle: idle, suppressed: suppressed)
                            if v.card {
                                XCTAssertTrue(v.face, "card without a face: \(content)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testGoingIdleWithTheSessionListOpenTakesBothAway() {
        // Exactly the reported case: the face leaves because nothing is
        // running and the setting says not to linger, and the list used to
        // stay behind on its own.
        let v = visibility(.sessions(count: 0, hasQuota: false), faceWhenIdle: false)
        XCTAssertFalse(v.face)
        XCTAssertFalse(v.card)
    }

    func testAnIdleFaceThatStaysKeepsWhateverIsUnderIt() {
        // With the setting on, the face is still information — and a card that
        // is still saying something goes on hanging off it.
        let v = visibility(.card, card: true, faceWhenIdle: true)
        XCTAssertTrue(v.face)
        XCTAssertTrue(v.card)
    }

    func testACardAloneIsEnoughToKeepTheFaceOut() {
        // No agents and no idle face, but something on screen worth reading:
        // the face has to be there for the card to hang off.
        let v = visibility(.card, sessions: false, card: true, faceWhenIdle: false)
        XCTAssertTrue(v.face)
        XCTAssertTrue(v.card)
    }

    func testNothingToShowMeansNoCardEvenWithAFace() {
        let v = visibility(.none, sessions: true, faceWhenIdle: true)
        XCTAssertTrue(v.face)
        XCTAssertFalse(v.card)
    }

    func testDismissingByHandTakesBoth() {
        let v = visibility(.sessions(count: 4, hasQuota: false), sessions: true,
                           card: true, faceWhenIdle: true, suppressed: true)
        XCTAssertFalse(v.face)
        XCTAssertFalse(v.card)
    }
}
