import XCTest
@testable import VibeScrollCore

final class ContentLanguageTests: XCTestCase {

    func testATurkishDeviceGetsTurkish() {
        XCTAssertEqual(ContentLanguage.resolve(preferredLanguages: ["tr-TR"]), .tr)
        XCTAssertEqual(ContentLanguage.resolve(preferredLanguages: ["tr"]), .tr)
        XCTAssertEqual(ContentLanguage.resolve(preferredLanguages: ["TR_tr"]), .tr)
    }

    func testRegionalEnglishIsEnglish() {
        XCTAssertEqual(ContentLanguage.resolve(preferredLanguages: ["en-GB", "tr-TR"]), .en)
    }

    func testTheFirstSupportedLanguageWinsNotTheFirstListed() {
        // German first, Turkish second: the device has said it reads Turkish,
        // which beats falling back to English.
        XCTAssertEqual(ContentLanguage.resolve(preferredLanguages: ["de-DE", "tr-TR"]), .tr)
    }

    func testNothingSupportedFallsBackToEnglish() {
        XCTAssertEqual(ContentLanguage.resolve(preferredLanguages: ["de-DE", "fr"]), .en)
        XCTAssertEqual(ContentLanguage.resolve(preferredLanguages: []), .en)
        XCTAssertEqual(ContentLanguage.resolve(preferredLanguages: [""]), .en)
    }

    func testTheHeaderNamesTheFallbackWithALowerWeight() {
        // A server without Turkish yet should answer in English, not guess.
        XCTAssertEqual(ContentLanguage.tr.acceptLanguageHeader, "tr, en;q=0.5")
        XCTAssertEqual(ContentLanguage.en.acceptLanguageHeader, "en")
    }

    func testEveryLanguageHasAnInterfaceLocalizationFolderName() {
        // The raw values double as `.lproj` names; a value that is not a valid
        // language code would silently never match either list.
        for language in ContentLanguage.allCases {
            XCTAssertEqual(Locale(identifier: language.rawValue).language.languageCode?.identifier,
                           language.rawValue)
        }
    }
}
