import XCTest
@testable import VibeScrollCore

final class InfoCardTests: XCTestCase {

    private func decode(_ json: String) throws -> InfoCard {
        try JSONDecoder().decode(InfoCard.self, from: Data(json.utf8))
    }

    private func decodeBundle(_ json: String) throws -> CardBundle {
        try JSONDecoder().decode(CardBundle.self, from: Data(json.utf8))
    }

    func testMinimalPayloadDecodes() throws {
        let card = try decode("""
        {"id":"a","category":"theOffice","title":"T","body":"B"}
        """)
        XCTAssertEqual(card.id, "a")
        XCTAssertEqual(card.category, .theOffice)
        XCTAssertTrue(card.tags.isEmpty)
        XCTAssertNil(card.link)
    }

    func testAnUnknownCategoryIsRejectedOnItsOwn() {
        // There is no neutral topic to file it under any more.
        XCTAssertThrowsError(try decode(#"{"id":"a","category":"quantum","title":"T","body":"B"}"#))
    }

    func testUnknownFieldsAreIgnored() throws {
        // `level` included: older backends sent it, and this build no longer
        // reads it.
        let card = try decode("""
        {"id":"a","category":"theOffice","title":"T","body":"B","level":"beginner","futureField":{"x":1}}
        """)
        XCTAssertEqual(card.id, "a")
    }

    func testMalformedLinkBecomesNilRatherThanThrowing() throws {
        let card = try decode("""
        {"id":"a","category":"theOffice","title":"T","body":"B","link":""}
        """)
        XCTAssertNil(card.link)
    }

    func testMissingRequiredFieldStillThrows() {
        // Leniency has a floor: a card with no body is not renderable.
        XCTAssertThrowsError(try decode(#"{"id":"a","category":"theOffice","title":"T"}"#))
    }

    func testBundleDecodes() throws {
        let bundle = try decodeBundle("""
        {"version":"abc","language":"tr","cards":[{"id":"a","category":"theOffice","title":"T","body":"B"}]}
        """)
        XCTAssertEqual(bundle.version, "abc")
        XCTAssertEqual(bundle.language, .tr)
        XCTAssertEqual(bundle.cards.count, 1)
    }

    func testABundleSkipsCardsItCannotReadInsteadOfFailing() throws {
        // A category added server-first must cost that card on an older app,
        // not the whole catalogue.
        let bundle = try decodeBundle("""
        {"version":"abc","cards":[
          {"id":"new","category":"theWire","title":"T","body":"B"},
          {"id":"broken","category":"theOffice","title":"T"},
          {"id":"ok","category":"breakingBad","title":"T","body":"B"}
        ]}
        """)
        XCTAssertEqual(bundle.cards.map(\.id), ["ok"])
    }

    func testABundleFromBeforeLocalizationHasNoLanguage() throws {
        let bundle = try decodeBundle(#"{"version":"abc","cards":[]}"#)
        XCTAssertNil(bundle.language)
    }

    func testAnUnknownLanguageIsNilRatherThanAnError() throws {
        let bundle = try decodeBundle(#"{"version":"abc","language":"de","cards":[]}"#)
        XCTAssertNil(bundle.language)
    }
}
