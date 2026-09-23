import XCTest
@testable import VibeScrollCore

final class CardSchedulerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 10_000)

    private func card(_ id: String, _ category: CardCategory = .theOffice) -> InfoCard {
        InfoCard(id: id, category: category, title: id, body: "body")
    }

    // MARK: - Gates

    func testDwellGateBlocksATopicThatJustChanged() {
        let s = CardScheduler(policy: .init(minimumDwell: 8, globalCooldown: 0,
                                           topicCooldown: 0, cardRepeatWindow: 0))
        // Topic entered 3s ago — not stable enough to be "what the user is doing".
        XCTAssertFalse(s.mayShow(topic: .testing, topicSince: t0.addingTimeInterval(-3), now: t0))
        XCTAssertTrue(s.mayShow(topic: .testing, topicSince: t0.addingTimeInterval(-9), now: t0))
    }

    func testGlobalCooldownBlocksADifferentTopicToo() {
        let s = CardScheduler(policy: .init(minimumDwell: 0, globalCooldown: 90,
                                            topicCooldown: 0, cardRepeatWindow: 0))
        s.recordShown(card("a"), topic: .testing, now: t0)
        XCTAssertFalse(s.mayShow(topic: .debugging, topicSince: t0, now: t0.addingTimeInterval(30)))
        XCTAssertTrue(s.mayShow(topic: .debugging, topicSince: t0, now: t0.addingTimeInterval(91)))
    }

    func testTopicCooldownIsPerTopic() {
        let s = CardScheduler(policy: .init(minimumDwell: 0, globalCooldown: 0,
                                            topicCooldown: 900, cardRepeatWindow: 0))
        s.recordShown(card("a"), topic: .testing, now: t0)
        let later = t0.addingTimeInterval(60)
        XCTAssertFalse(s.mayShow(topic: .testing, topicSince: t0, now: later))
        // A different topic is unaffected.
        XCTAssertTrue(s.mayShow(topic: .debugging, topicSince: t0, now: later))
    }

    // MARK: - Selection

    func testPickPrefersNeverShownCards() {
        let s = CardScheduler(policy: .init(cardRepeatWindow: 3600))
        s.recordShown(card("a"), now: t0)
        let picked = s.pick(from: [card("a"), card("b")], now: t0.addingTimeInterval(1))
        XCTAssertEqual(picked?.id, "b")
    }

    func testPickCyclesOldestShownFirst() {
        let s = CardScheduler(policy: .init(cardRepeatWindow: 0))
        s.recordShown(card("a"), now: t0)
        s.recordShown(card("b"), now: t0.addingTimeInterval(10))
        // Both eligible (window 0); "a" was shown longer ago.
        XCTAssertEqual(s.pick(from: [card("a"), card("b")], now: t0.addingTimeInterval(20))?.id, "a")
    }

    func testPickIsDeterministicOnTies() {
        let s = CardScheduler()
        // Two never-shown cards tie on timestamp; id breaks it, so repeated
        // calls can't produce a different card and flicker the UI.
        XCTAssertEqual(s.pick(from: [card("b"), card("a")], now: t0)?.id, "a")
        XCTAssertEqual(s.pick(from: [card("a"), card("b")], now: t0)?.id, "a")
    }

    func testPickReturnsNilWhenEverythingIsInsideItsRepeatWindow() {
        let s = CardScheduler(policy: .init(cardRepeatWindow: 3600))
        s.recordShown(card("a"), now: t0)
        XCTAssertNil(s.pick(from: [card("a")], now: t0.addingTimeInterval(60)))
        XCTAssertNotNil(s.pick(from: [card("a")], now: t0.addingTimeInterval(3601)))
    }

    func testPickOnEmptyCandidatesIsNil() {
        XCTAssertNil(CardScheduler().pick(from: [], now: t0))
    }

    // MARK: - next()

    func testNextRecordsOnlyWhenItActuallyReturnsACard() {
        let s = CardScheduler(policy: .init(minimumDwell: 10, globalCooldown: 60,
                                            topicCooldown: 60, cardRepeatWindow: 3600))
        // Blocked by dwell — must not burn the card's repeat window.
        XCTAssertNil(s.next(topic: .testing, topicSince: t0, candidates: [card("a")], now: t0))
        // Once dwell passes, the same card is still available.
        let shown = s.next(topic: .testing, topicSince: t0,
                           candidates: [card("a")], now: t0.addingTimeInterval(11))
        XCTAssertEqual(shown?.id, "a")
    }

    func testResetClearsPacingState() {
        let s = CardScheduler(policy: .init(minimumDwell: 0, globalCooldown: 600,
                                            topicCooldown: 600, cardRepeatWindow: 600))
        s.recordShown(card("a"), topic: .testing, now: t0)
        XCTAssertFalse(s.mayShow(topic: .testing, topicSince: t0, now: t0.addingTimeInterval(1)))
        s.reset()
        XCTAssertTrue(s.mayShow(topic: .testing, topicSince: t0, now: t0.addingTimeInterval(1)))
    }

    // MARK: - Manual navigation (Next)

    /// The catalogue the Next tests browse: two Breaking Bad, two The Office.
    private var catalogue: [InfoCard] {
        [card("bb1", .breakingBad), card("bb2", .breakingBad),
         card("of1", .theOffice), card("of2", .theOffice)]
    }

    func testAdvanceStaysInsideTheActiveTopicWhileItHasMaterial() {
        let s = CardScheduler(policy: .init(cardRepeatWindow: 3600))
        let first = s.advance(from: catalogue, category: .breakingBad, excluding: nil, now: t0)
        XCTAssertEqual(first?.id, "bb1")
        s.recordShown(first!, now: t0)

        let second = s.advance(from: catalogue, category: .breakingBad, excluding: "bb1", now: t0)
        XCTAssertEqual(second?.id, "bb2")
    }

    func testAdvanceSpillsToOtherCategoriesOnceTheTopicIsExhausted() {
        let s = CardScheduler(policy: .init(cardRepeatWindow: 3600))
        s.recordShown(card("bb1", .breakingBad), now: t0)
        s.recordShown(card("bb2", .breakingBad), now: t0)
        // Both Breaking Bad cards are inside their repeat window, so the only
        // unseen material is in another show.
        let next = s.advance(from: catalogue, category: .breakingBad, excluding: nil, now: t0)
        XCTAssertEqual(next?.category, .theOffice)
    }

    func testAdvanceNeverDeadEndsOnceEverythingHasBeenSeen() {
        let s = CardScheduler(policy: .init(cardRepeatWindow: 3600))
        // Seen in this order; bb1 is the oldest, so it comes back round first.
        s.recordShown(card("bb1", .breakingBad), now: t0)
        s.recordShown(card("bb2", .breakingBad), now: t0.addingTimeInterval(10))
        s.recordShown(card("of1", .theOffice), now: t0.addingTimeInterval(20))
        s.recordShown(card("of2", .theOffice), now: t0.addingTimeInterval(30))

        let next = s.advance(from: catalogue, category: .breakingBad,
                             excluding: nil, now: t0.addingTimeInterval(40))
        XCTAssertEqual(next?.id, "bb1", "Next must cycle rather than go inert")
    }

    func testAdvanceNeverReturnsTheCardAlreadyOnScreen() {
        let s = CardScheduler(policy: .init(cardRepeatWindow: 0))
        // Repeat window 0 makes every card eligible, so only the explicit
        // exclusion stops Next from re-showing what is already visible.
        for _ in 0..<5 {
            XCTAssertNotEqual(
                s.advance(from: catalogue, category: .theOffice, excluding: "of1", now: t0)?.id, "of1")
        }
    }

    func testAdvanceWithNoTopicBrowsesTheWholeCatalogue() {
        let s = CardScheduler(policy: .init(cardRepeatWindow: 3600))
        XCTAssertNotNil(s.advance(from: catalogue, category: nil, excluding: nil, now: t0))
    }

    func testAdvanceOnAnEmptyCatalogueIsNil() {
        XCTAssertNil(CardScheduler().advance(from: [], category: .theOffice, excluding: nil, now: t0))
        // A single card that is also the one on screen leaves nothing to show.
        XCTAssertNil(CardScheduler().advance(
            from: [card("only")], category: .theOffice, excluding: "only", now: t0))
    }

    func testAdvanceIgnoresPacingGates() {
        let s = CardScheduler(policy: .init(minimumDwell: 999, globalCooldown: 999,
                                            topicCooldown: 999, cardRepeatWindow: 0))
        s.recordShown(card("bb1", .breakingBad), topic: .versionControl, now: t0)
        // mayShow would refuse; the user pressed Next, so they get a card.
        XCTAssertFalse(s.mayShow(topic: .versionControl, topicSince: t0, now: t0))
        XCTAssertNotNil(s.advance(from: catalogue, category: .breakingBad,
                                  excluding: nil, now: t0))
    }

    func testLeastRecentlyShownPrefersNeverShown() {
        let s = CardScheduler()
        s.recordShown(card("a"), now: t0)
        XCTAssertEqual(s.leastRecentlyShown(in: [card("a"), card("b")], now: t0)?.id, "b")
        XCTAssertNil(s.leastRecentlyShown(in: [], now: t0))
    }

    func testUnthrottledPolicyLetsEverythingThrough() {
        let s = CardScheduler(policy: .unthrottled)
        s.recordShown(card("a"), now: t0)
        XCTAssertTrue(s.mayShow(topic: .testing, topicSince: t0, now: t0))
        XCTAssertEqual(s.pick(from: [card("a")], now: t0)?.id, "a")
    }
}
