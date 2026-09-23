import XCTest
@testable import VibeScrollCore

/// What the agent is doing and what a card is about are two vocabularies, and
/// these pin that they stay apart: activity sets the rhythm, the catalogue
/// supplies the subject.
final class CardCategoryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_773_500_000)

    private func card(_ id: String, _ category: CardCategory) -> InfoCard {
        InfoCard(id: id, category: category, title: "t", body: "b")
    }

    func testNoActivityNameIsAContentCategory() {
        // The backend validates against `CATEGORIES`; a work topic arriving as
        // content would mean the two lists had been merged again.
        let activity = Set(TopicCategory.allCases.map(\.rawValue))
        let content = Set(CardCategory.allCases.map(\.rawValue))
        XCTAssertTrue(activity.isDisjoint(with: content))
    }

    func testAnyActivityCanDrawFromAnyShow() {
        // The automatic path hands the whole catalogue to `next`, whatever the
        // topic: debugging does not have to be answered with a debugging card.
        let scheduler = CardScheduler(policy: .unthrottled)
        let shown = scheduler.next(
            topic: .debugging, topicSince: t0,
            candidates: [card("office", .theOffice)], now: t0)
        XCTAssertEqual(shown?.id, "office")
    }

    func testShowsTakeTurnsAcrossAutomaticCards() {
        // Least recently shown first, over the whole pool: two cards in a row
        // come from two different shows while both have unseen material.
        let scheduler = CardScheduler(policy: .unthrottled)
        let pool = [card("bb1", .breakingBad), card("got1", .gameOfThrones),
                    card("bb2", .breakingBad)]
        let first = scheduler.next(topic: .reading, topicSince: t0, candidates: pool, now: t0)
        let second = scheduler.next(topic: .writing, topicSince: t0, candidates: pool,
                                    now: t0.addingTimeInterval(1))
        XCTAssertEqual(first?.id, "bb1")
        XCTAssertEqual(second?.id, "bb2", "ties break on id, never on show")
        XCTAssertNotEqual(first?.id, second?.id)
    }

    func testTheTopicCooldownBelongsToTheActivityNotTheShow() {
        let scheduler = CardScheduler(policy: .init(minimumDwell: 0, globalCooldown: 0,
                                                    topicCooldown: 900, cardRepeatWindow: 0))
        _ = scheduler.next(topic: .testing, topicSince: t0,
                           candidates: [card("a", .theOffice)], now: t0)
        let later = t0.addingTimeInterval(60)
        XCTAssertFalse(scheduler.mayShow(topic: .testing, topicSince: t0, now: later),
                       "the same activity waits out its cooldown")
        XCTAssertTrue(scheduler.mayShow(topic: .debugging, topicSince: t0, now: later),
                      "a different activity is free, whichever show was on screen")
    }

    func testBrowsingStartsNoTopicCooldown() {
        // Reading a card is not the agent doing anything.
        let scheduler = CardScheduler(policy: .init(minimumDwell: 0, globalCooldown: 0,
                                                    topicCooldown: 900, cardRepeatWindow: 0))
        scheduler.recordShown(card("a", .theOffice), now: t0)
        XCTAssertTrue(scheduler.mayShow(topic: .testing, topicSince: t0,
                                        now: t0.addingTimeInterval(1)))
    }

    func testNextStaysInsideTheChosenShow() {
        let scheduler = CardScheduler(policy: .unthrottled)
        let all = [card("got1", .gameOfThrones), card("got2", .gameOfThrones),
                   card("bb1", .breakingBad)]
        let next = scheduler.advance(from: all, category: .gameOfThrones,
                                     excluding: "got1", now: t0)
        XCTAssertEqual(next?.id, "got2")
    }

    func testShowNamesAreNotTranslated() {
        // Proper nouns, shipped under the same title in every supported
        // language — so they are not looked up anywhere.
        XCTAssertEqual(CardCategory.theOffice.label, "The Office")
        XCTAssertEqual(CardCategory.gameOfThrones.label, "Game of Thrones")
    }
}
