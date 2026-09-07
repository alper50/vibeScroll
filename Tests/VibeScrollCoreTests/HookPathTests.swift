import XCTest
@testable import VibeScrollCore

/// The hook command embeds an absolute path, so moving the app disconnects
/// every agent — silently, because the hook fails open. These cover the part
/// that notices.
final class HookPathTests: XCTestCase {

    private let ours = "\"/Applications/vibeScroll.app/Contents/MacOS/vibescroll\" hook --agent claude"
    private let elsewhere = "\"/Users/me/Downloads/vibeScroll.app/Contents/MacOS/vibescroll\" hook --agent claude"
    private let current = "/Applications/vibeScroll.app/Contents/MacOS/vibescroll"

    private func temporaryFile(_ contents: String) throws -> String {
        let path = NSTemporaryDirectory() + "hp-\(UUID().uuidString.prefix(8)).json"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - The style-agnostic scan

    func testOurCommandsFindsThemWhateverTheLayout() {
        // Claude nests them under groups, Cursor keeps them flat, Antigravity
        // puts the whole event map under a named key. One walk, all three.
        let nested: [String: Any] = ["hooks": ["Stop": [["hooks": [["command": ours]]]]]]
        let flat: [String: Any] = ["hooks": ["stop": [["command": ours, "type": "command"]]]]
        let named: [String: Any] = ["vibescroll": ["Stop": [["type": "command", "command": ours]]]]

        for settings in [nested, flat, named] {
            XCTAssertEqual(HookInstaller.ourCommands(in: settings), [ours])
        }
    }

    func testForeignHooksAreNeverClaimed() {
        let settings: [String: Any] = ["hooks": [
            "Stop": [["hooks": [["command": "/usr/local/bin/some-other-tool report"]]]],
        ]]
        XCTAssertTrue(HookInstaller.ourCommands(in: settings).isEmpty)
    }

    func testAnEmptyOrUnrelatedTreeYieldsNothing() {
        XCTAssertTrue(HookInstaller.ourCommands(in: [String: Any]()).isEmpty)
        XCTAssertTrue(HookInstaller.ourCommands(in: ["model": "opus", "effortLevel": "high"]).isEmpty)
    }

    // MARK: - Status

    func testHookPointingHereIsCurrent() throws {
        let path = try temporaryFile(#"{"hooks":{"Stop":[{"hooks":[{"command":\#(quoted(ours))}]}]}}"#)
        XCTAssertEqual(
            HookInstaller.pathStatus(path: path, style: .claudeNested, currentBinary: current),
            .current)
    }

    func testHookLeftBehindByAMoveIsReported() throws {
        let path = try temporaryFile(#"{"hooks":{"Stop":[{"hooks":[{"command":\#(quoted(elsewhere))}]}]}}"#)
        XCTAssertEqual(
            HookInstaller.pathStatus(path: path, style: .claudeNested, currentBinary: current),
            .elsewhere("/Users/me/Downloads/vibeScroll.app/Contents/MacOS/vibescroll"))
    }

    func testAConfigWithNoHookOfOursIsNotInstalled() throws {
        let path = try temporaryFile(#"{"model":"opus"}"#)
        XCTAssertEqual(
            HookInstaller.pathStatus(path: path, style: .claudeNested, currentBinary: current),
            .notInstalled)
        XCTAssertEqual(
            HookInstaller.pathStatus(path: "/no/such/file.json", style: .claudeNested,
                                     currentBinary: current),
            .notInstalled)
    }

    func testOneEntryPointingHereIsEnough() throws {
        // A part-rewritten config is repaired by reinstalling, which is what the
        // caller does for `.elsewhere` anyway — so it must not read as stale.
        let path = try temporaryFile("""
        {"hooks":{"Stop":[{"hooks":[{"command":\(quoted(elsewhere))}]}],
                  "SessionStart":[{"hooks":[{"command":\(quoted(ours))}]}]}}
        """)
        XCTAssertEqual(
            HookInstaller.pathStatus(path: path, style: .claudeNested, currentBinary: current),
            .current)
    }

    // MARK: - Generated plugin files

    func testThePathIsRecoveredFromAGeneratedPlugin() {
        // These are JavaScript rather than JSON, but we wrote every line, so the
        // binary is the only quoted absolute path in the file.
        let source = HookInstaller.opencodePlugin(binary: current)
        XCTAssertEqual(HookInstaller.pluginBinary(in: source), current)
    }

    func testAMovedPluginIsReported() throws {
        let stale = "/Users/me/Downloads/vibeScroll.app/Contents/MacOS/vibescroll"
        let path = NSTemporaryDirectory() + "hp-\(UUID().uuidString.prefix(8)).js"
        try HookInstaller.opencodePlugin(binary: stale)
            .write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            HookInstaller.pathStatus(path: path, style: .opencodePlugin, currentBinary: current),
            .elsewhere(stale))
    }

    private func quoted(_ command: String) -> String {
        String(decoding: try! JSONSerialization.data(
            withJSONObject: command, options: .fragmentsAllowed), as: UTF8.self)
    }
}
