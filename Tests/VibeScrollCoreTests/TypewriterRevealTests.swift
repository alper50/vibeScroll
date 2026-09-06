import XCTest
@testable import VibeScrollCore

final class TypewriterRevealTests: XCTestCase {

    /// 10 characters per second keeps the arithmetic obvious: elapsed × 10.
    private let reveal = TypewriterReveal(title: "ABCDE", body: "12345", charactersPerSecond: 10)

    func testNothingIsRevealedBeforeTheAnimationStarts() {
        let shown = reveal.text(after: 0)
        XCTAssertEqual(shown.title, "")
        XCTAssertEqual(shown.body, "")
        XCTAssertFalse(shown.isComplete)
    }

    func testTitleRevealsBeforeTheBodyStarts() {
        let shown = reveal.text(after: 0.3)   // 3 characters
        XCTAssertEqual(shown.title, "ABC")
        XCTAssertEqual(shown.body, "", "the body must not start until the title finishes")
    }

    func testHandoverFromTitleToBodyIsContinuous() {
        // Exactly at the boundary the title is whole and the body is empty…
        let atBoundary = reveal.text(after: 0.5)
        XCTAssertEqual(atBoundary.title, "ABCDE")
        XCTAssertEqual(atBoundary.body, "")
        // …and one character later the body has started, with no lost character.
        let justAfter = reveal.text(after: 0.6)
        XCTAssertEqual(justAfter.title, "ABCDE")
        XCTAssertEqual(justAfter.body, "1")
    }

    func testCompletionIsReportedOnlyWhenEverythingIsShown() {
        XCTAssertFalse(reveal.text(after: 0.9).isComplete)
        let done = reveal.text(after: 1.0)
        XCTAssertEqual(done.title, "ABCDE")
        XCTAssertEqual(done.body, "12345")
        XCTAssertTrue(done.isComplete)
    }

    func testRevealIsClampedPastTheEnd() {
        let shown = reveal.text(after: 60)
        XCTAssertEqual(shown.body, "12345")
        XCTAssertTrue(shown.isComplete)
    }

    func testHugeElapsedDoesNotOverflow() {
        // The skip-to-end path can hand in an enormous elapsed; converting it
        // to Int before clamping would trap.
        XCTAssertEqual(reveal.revealedCount(after: .greatestFiniteMagnitude), 10)
        XCTAssertTrue(reveal.text(after: .greatestFiniteMagnitude).isComplete)
    }

    func testNegativeElapsedRevealsNothing() {
        XCTAssertEqual(reveal.revealedCount(after: -5), 0)
    }

    func testZeroRateRevealsEverythingAtOnce() {
        // How reduced-motion is expressed: no animation, full text, zero duration.
        let instant = TypewriterReveal(title: "AB", body: "CD", charactersPerSecond: 0)
        XCTAssertEqual(instant.duration, 0)
        XCTAssertTrue(instant.text(after: 0).isComplete)
        XCTAssertEqual(instant.text(after: 0).body, "CD")
    }

    func testDurationMatchesTheCharacterCount() {
        XCTAssertEqual(reveal.totalCharacters, 10)
        XCTAssertEqual(reveal.duration, 1.0, accuracy: 0.0001)
    }

    func testEmptyCardIsImmediatelyComplete() {
        let empty = TypewriterReveal(title: "", body: "")
        XCTAssertEqual(empty.duration, 0)
        XCTAssertTrue(empty.text(after: 0).isComplete)
    }

    func testGraphemeClustersAreRevealedWhole() {
        // A ZWJ family is one Character but many scalars; revealing it by byte
        // or scalar offset would render broken glyphs mid-animation.
        let emoji = TypewriterReveal(title: "👨‍👩‍👧x", body: "", charactersPerSecond: 10)
        XCTAssertEqual(emoji.totalCharacters, 2)
        XCTAssertEqual(emoji.text(after: 0.1).title, "👨‍👩‍👧")
    }

    func testCombiningAccentsCountAsOneCharacter() {
        // "é" written as e + combining acute is one Character.
        let accented = TypewriterReveal(title: "e\u{0301}f", body: "", charactersPerSecond: 10)
        XCTAssertEqual(accented.totalCharacters, 2)
        XCTAssertEqual(accented.text(after: 0.1).title, "e\u{0301}")
    }

    func testRealisticCardLandsInAReadableTime() {
        // The tuning claim in TypewriterReveal.defaultRate, pinned so a future
        // rate change has to be deliberate.
        let card = TypewriterReveal(
            title: String(repeating: "a", count: 40),
            body: String(repeating: "b", count: 280))
        XCTAssertEqual(card.duration, 320.0 / 90.0, accuracy: 0.001)
        XCTAssertLessThan(card.duration, 4.0)
    }
}
