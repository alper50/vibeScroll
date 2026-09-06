import XCTest
@testable import VibeScrollCore

final class SoundSelectionTests: XCTestCase {

    // MARK: - Round trip

    func testEveryCaseSurvivesTheRoundTrip() {
        // This is the path that silently loses a user's choice between launches,
        // so each case is pinned rather than spot-checked.
        let cases: [SoundSelection] = [
            .silent,
            .system("Glass"),
            .custom(URL(fileURLWithPath: "/Users/a/.vibescroll/sounds/done.aiff")),
        ]
        for selection in cases {
            XCTAssertEqual(SoundSelection.decode(selection.encoded), selection)
        }
    }

    func testCustomPathsWithSpacesSurvive() {
        let url = URL(fileURLWithPath: "/Users/a/My Sounds/ding dong.wav")
        XCTAssertEqual(SoundSelection.decode(SoundSelection.custom(url).encoded), .custom(url))
    }

    // MARK: - Nothing stored

    func testUnsetReturnsNilSoTheCallerCanApplyItsDefault() {
        // nil is distinct from .silent: a fresh install should get the default
        // chime, not silence.
        XCTAssertNil(SoundSelection.decode(nil))
        XCTAssertNil(SoundSelection.decode(""))
    }

    // MARK: - Corrupt input

    func testUnknownSystemNameIsRejected() {
        // Storing a name macOS does not have would show it in the picker while
        // playing nothing — a setting that lies about itself.
        XCTAssertNil(SoundSelection.decode("system:NoSuchSound"))
        XCTAssertNil(SoundSelection.decode("system:"))
    }

    func testRelativeCustomPathIsRejected() {
        XCTAssertNil(SoundSelection.decode("custom:sounds/done.aiff"))
        XCTAssertNil(SoundSelection.decode("custom:"))
    }

    func testUnknownPrefixIsRejected() {
        XCTAssertNil(SoundSelection.decode("Glass"))
        XCTAssertNil(SoundSelection.decode("bundle:Glass"))
    }

    func testSilentDecodesExactly() {
        XCTAssertEqual(SoundSelection.decode("silent"), .silent)
    }

    // MARK: - Display

    func testDisplayNames() {
        XCTAssertEqual(SoundSelection.silent.displayName, "None")
        XCTAssertEqual(SoundSelection.system("Hero").displayName, "Hero")
        // The extension is dropped: the picker shows a label, not a filename.
        XCTAssertEqual(
            SoundSelection.custom(URL(fileURLWithPath: "/tmp/my chime.wav")).displayName,
            "my chime")
    }

    func testIsCustomDiscriminates() {
        XCTAssertTrue(SoundSelection.custom(URL(fileURLWithPath: "/tmp/a.aiff")).isCustom)
        XCTAssertFalse(SoundSelection.system("Glass").isCustom)
        XCTAssertFalse(SoundSelection.silent.isCustom)
    }

    func testSystemNamesAreTheDocumentedMacOSSet() {
        XCTAssertEqual(SoundSelection.systemNames.count, 14)
        XCTAssertTrue(SoundSelection.systemNames.contains("Glass"))
        XCTAssertTrue(SoundSelection.systemNames.contains("Ping"))
    }
}
