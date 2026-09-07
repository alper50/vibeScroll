import XCTest
@testable import VibeScrollCore

/// Exercises the real socket. The behaviour that matters here — one client
/// being unable to delay another — lives entirely in the threading, so a test
/// of the decode path alone cannot see it.
final class EventSocketServerTests: XCTestCase {

    private struct ConnectFailed: Error {}

    /// `sun_path` is 104 bytes on Darwin, so the name is kept deliberately
    /// short rather than built from a temporary directory plus a full UUID.
    private func temporaryPath() -> String {
        NSTemporaryDirectory() + "vs-\(UUID().uuidString.prefix(8)).sock"
    }

    /// A bare connection with no client logic behind it, so a test can hold one
    /// open without writing anything.
    private func connectRaw(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectFailed() }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { close(fd); throw ConnectFailed() }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { close(fd); throw ConnectFailed() }
        return fd
    }

    private func event(_ id: String) -> AgentEvent {
        AgentEvent(sessionId: id, agentKind: .cli, eventName: "working",
                   timestamp: Date(timeIntervalSince1970: 1))
    }

    func testAnEventSentOverTheSocketIsDelivered() throws {
        let path = temporaryPath()
        let server = EventSocketServer(path: path)
        defer { server.stop() }

        let arrived = expectation(description: "the event")
        try server.start { received in
            if received.sessionId == "s1" { arrived.fulfill() }
        }

        XCTAssertTrue(EventSender.send(event("s1"), socketPath: path, queueDir: temporaryPath()))
        wait(for: [arrived], timeout: 2)
    }

    func testAStalledClientDoesNotDelayOtherEvents() throws {
        let path = temporaryPath()
        let server = EventSocketServer(path: path)
        defer { server.stop() }

        let arrived = expectation(description: "the second client's event")
        try server.start { received in
            if received.sessionId == "second" { arrived.fulfill() }
        }

        // Connects, then says nothing. While connections were read on the accept
        // loop this wedged the daemon outright: every later hook fell back to
        // the disk queue and the session list stopped updating.
        let stalled = try connectRaw(to: path)
        defer { close(stalled) }

        XCTAssertTrue(EventSender.send(event("second"), socketPath: path, queueDir: temporaryPath()))

        // Comfortably inside the server's receive timeout, so passing means the
        // event overtook the stalled client rather than waiting it out.
        wait(for: [arrived], timeout: 2)
    }

    func testStopIsIdempotentAndRemovesTheSocketFile() throws {
        let path = temporaryPath()
        let server = EventSocketServer(path: path)
        try server.start { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // Twice: `deinit` also calls this, so a second close of the same
        // descriptor would be a live bug rather than a hypothetical one.
        server.stop()
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
