import XCTest
@testable import VibeScrollCore

final class SoundGateTests: XCTestCase {
    private let done = 1, quota = 2, waiting = 3
    private let t0 = Date(timeIntervalSince1970: 1000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testASoundOnItsOwnPlaysAtOnce() {
        var gate = SoundGate(window: 1)
        XCTAssertEqual(gate.request(priority: done, now: at(0)), .playNow)
        XCTAssertEqual(gate.request(priority: done, now: at(5)), .playNow, "well apart: both heard")
    }

    func testSeveralFinishingTogetherAreOneSound() {
        var gate = SoundGate(window: 1)
        XCTAssertEqual(gate.request(priority: done, now: at(0)), .playNow)
        XCTAssertEqual(gate.request(priority: done, now: at(0.2)), .drop)
        XCTAssertEqual(gate.request(priority: done, now: at(0.4)), .drop)
    }

    func testSomeoneWaitingRightAfterAFinishIsStillHeard() {
        // The case the old two-second throttle silenced.
        var gate = SoundGate(window: 1)
        XCTAssertEqual(gate.request(priority: done, now: at(0)), .playNow)
        XCTAssertEqual(gate.request(priority: waiting, now: at(0.3)), .playAt(at(1)),
                       "held to the end of the window, not thrown away")
        XCTAssertEqual(gate.firePending(now: at(1)), waiting)
        XCTAssertNil(gate.firePending(now: at(1.1)), "played once")
    }

    func testOnlyTheMostImportantOfABurstIsHeld() {
        var gate = SoundGate(window: 1)
        _ = gate.request(priority: done, now: at(0))
        XCTAssertEqual(gate.request(priority: quota, now: at(0.2)), .playAt(at(1)))
        XCTAssertEqual(gate.request(priority: waiting, now: at(0.4)), .playAt(at(1)), "upgrades the held one")
        XCTAssertEqual(gate.request(priority: quota, now: at(0.6)), .drop, "already covered by what is held")
        XCTAssertEqual(gate.firePending(now: at(1)), waiting)
    }

    func testAFinishRightAfterSomeoneWaitingAddsNothing() {
        var gate = SoundGate(window: 1)
        _ = gate.request(priority: waiting, now: at(0))
        XCTAssertEqual(gate.request(priority: done, now: at(0.5)), .drop,
                       "you are already looking — a second chime says nothing new")
    }

    func testAHeldSoundOpensItsOwnWindow() {
        var gate = SoundGate(window: 1)
        _ = gate.request(priority: done, now: at(0))
        _ = gate.request(priority: waiting, now: at(0.5))
        _ = gate.firePending(now: at(1))
        XCTAssertEqual(gate.request(priority: done, now: at(1.4)), .drop)
        XCTAssertEqual(gate.request(priority: done, now: at(2.1)), .playNow)
    }
}
