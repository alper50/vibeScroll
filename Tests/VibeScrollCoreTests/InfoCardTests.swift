import XCTest
@testable import VibeScrollCore

final class InfoCardTests: XCTestCase {

    private func decode(_ json: String) throws -> InfoCard {
        try JSONDecoder().decode(InfoCard.self, from: Data(json.utf8))
    }

    func testMinimalPayloadDecodes() throws {
        let card = try decode("""
        {"id":"a","category":"testing","title":"T","body":"B"}
        """)
        XCTAssertEqual(card.id, "a")
        XCTAssertEqual(card.category, .testing)
        XCTAssertEqual(card.level, .beginner)
        XCTAssertTrue(card.tags.isEmpty)
        XCTAssertNil(card.link)
    }

    func testUnknownCategoryDegradesToGenericInsteadOfFailing() throws {
        // A newer backend must not break an older client.
        let card = try decode("""
        {"id":"a","category":"quantum","title":"T","body":"B"}
        """)
        XCTAssertEqual(card.category, .generic)
    }

    func testUnknownLevelFallsBackToBeginner() throws {
        let card = try decode("""
        {"id":"a","category":"docs","title":"T","body":"B","level":"expert"}
        """)
        XCTAssertEqual(card.level, .beginner)
    }

    func testUnknownFieldsAreIgnored() throws {
        let card = try decode("""
        {"id":"a","category":"docs","title":"T","body":"B","futureField":{"x":1}}
        """)
        XCTAssertEqual(card.id, "a")
    }

    func testMalformedLinkBecomesNilRatherThanThrowing() throws {
        let card = try decode("""
        {"id":"a","category":"docs","title":"T","body":"B","link":""}
        """)
        XCTAssertNil(card.link)
    }

    func testMissingRequiredFieldStillThrows() {
        // Leniency has a floor: a card with no body is not renderable.
        XCTAssertThrowsError(try decode(#"{"id":"a","category":"docs","title":"T"}"#))
    }

    func testBundleDecodes() throws {
        let bundle = try JSONDecoder().decode(CardBundle.self, from: Data("""
        {"version":"abc","cards":[{"id":"a","category":"docs","title":"T","body":"B"}]}
        """.utf8))
        XCTAssertEqual(bundle.version, "abc")
        XCTAssertEqual(bundle.cards.count, 1)
    }
}
