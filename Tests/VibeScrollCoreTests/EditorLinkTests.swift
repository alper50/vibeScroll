import XCTest
@testable import VibeScrollCore

final class EditorLinkTests: XCTestCase {

    func testBuildsAVSCodeLinkForAProject() {
        let url = EditorLink.url(scheme: "vscode", projectPath: "/Users/a/dev/app")
        XCTAssertEqual(url?.absoluteString, "vscode://file/Users/a/dev/app")
    }

    func testSpacesInProjectPathsArePercentEncoded() {
        // The single most common way this breaks: a folder with a space builds
        // a URL that silently fails to parse and the click does nothing.
        let url = EditorLink.url(scheme: "vscode", projectPath: "/Users/a/My Projects/app")
        XCTAssertEqual(url?.absoluteString, "vscode://file/Users/a/My%20Projects/app")
        XCTAssertNotNil(url)
    }

    func testTrailingSlashIsNormalisedAway() {
        // Two spellings of one folder must produce one URL, or the editor can
        // fail to match it against the window that already has it open.
        XCTAssertEqual(
            EditorLink.url(scheme: "vscode", projectPath: "/Users/a/app/"),
            EditorLink.url(scheme: "vscode", projectPath: "/Users/a/app")
        )
    }

    func testRelativePathIsRejected() {
        // A relative path would resolve against whatever directory the editor
        // is in — the wrong window, or none. Better to fall back to activation.
        XCTAssertNil(EditorLink.url(scheme: "vscode", projectPath: "dev/app"))
        XCTAssertNil(EditorLink.url(scheme: "vscode", projectPath: ""))
    }

    func testEmptySchemeIsRejected() {
        XCTAssertNil(EditorLink.url(scheme: "", projectPath: "/Users/a/app"))
    }

    func testKnownEditorsResolveToTheirScheme() {
        XCTAssertEqual(EditorLink.scheme(forBundleID: "com.microsoft.VSCode"), "vscode")
        XCTAssertEqual(EditorLink.scheme(forBundleID: "com.todesktop.230313mzl4w4u92"), "cursor")
    }

    func testUnknownHostYieldsNoLink() {
        // Terminal.app is a known host but not an editor: it must fall through
        // to activation rather than producing a bogus terminal://file URL.
        XCTAssertNil(EditorLink.scheme(forBundleID: "com.apple.Terminal"))
        XCTAssertNil(EditorLink.url(bundleID: "com.apple.Terminal", projectPath: "/Users/a/app"))
        XCTAssertNil(EditorLink.url(bundleID: nil, projectPath: "/Users/a/app"))
        XCTAssertNil(EditorLink.url(bundleID: "com.microsoft.VSCode", projectPath: nil))
    }
}
