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

    // MARK: - Bundled sounds

    func testBundledSurvivesTheRoundTrip() {
        let choice = SoundSelection.bundled("Fart 1")
        XCTAssertEqual(choice.encoded, "bundled:Fart 1")
        XCTAssertEqual(SoundSelection.decode(choice.encoded), choice)
        XCTAssertEqual(choice.displayName, "Fart 1")
    }

    func testBundledIsNotConfusedWithASystemSound() {
        // One set is Apple's and one is ours. `NSSound` resolves both the same
        // way, which is exactly why the stored value has to keep them apart.
        XCTAssertNotEqual(SoundSelection.bundled("Fart 1"), SoundSelection.system("Fart 1"))
        XCTAssertEqual(SoundSelection.decode("system:Fart 1"), nil)
    }

    func testANameThisBuildDoesNotShipIsRejected() {
        // Rather than resolving to silence while the picker still shows a name.
        XCTAssertNil(SoundSelection.decode("bundled:Trombone"))
        XCTAssertNil(SoundSelection.decode("bundled:"))
        // The name this shipped under before the set grew to four. A stored
        // value naming a sound no longer bundled must fall back to the event's
        // default rather than resolving to silence.
        XCTAssertNil(SoundSelection.decode("bundled:Fart"))
    }

    func testBundledIsNotACustomFile() {
        // `isCustom` drives the picker's "show the chosen file" row; a bundled
        // sound already has its own entry and must not appear twice.
        XCTAssertFalse(SoundSelection.bundled("Fart 1").isCustom)
    }
}
