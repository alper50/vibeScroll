import XCTest
@testable import VibeScrollCore

final class BlinkRhythmTests: XCTestCase {

    func testALivelyFaceBlinksMoreOften() {
        let lively = BlinkRhythm.interval(energy: 1, jitter: 0.5)
        let spent = BlinkRhythm.interval(energy: 0, jitter: 0.5)
        XCTAssertLessThan(lively, spent)
        XCTAssertEqual(lively, BlinkRhythm.briskInterval, accuracy: 0.001)
        XCTAssertEqual(spent, BlinkRhythm.wearyInterval, accuracy: 0.001)
    }

    func testJitterSpreadsAroundTheBaseWithoutInvertingIt() {
        // The spread must never let a weary face out-blink a lively one, or the
        // energy signal stops meaning anything.
        let liveliest = BlinkRhythm.interval(energy: 1, jitter: 1)
        let weariest = BlinkRhythm.interval(energy: 0, jitter: 0)
        XCTAssertLessThan(liveliest, weariest)

        let low = BlinkRhythm.interval(energy: 0.5, jitter: 0)
        let high = BlinkRhythm.interval(energy: 0.5, jitter: 1)
        XCTAssertLessThan(low, high)
        // Symmetric about the un-jittered value.
        let mid = BlinkRhythm.interval(energy: 0.5, jitter: 0.5)
        XCTAssertEqual((low + high) / 2, mid, accuracy: 0.001)
    }

    func testEveryIntervalIsAWaitSomebodyWouldNotNotice() {
        for energy in stride(from: 0.0, through: 1.0, by: 0.1) {
            for jitter in [0.0, 0.5, 1.0] {
                let interval = BlinkRhythm.interval(energy: energy, jitter: jitter)
                XCTAssertGreaterThan(interval, 2, "a blink every two seconds is a twitch")
                XCTAssertLessThan(interval, 11, "longer than this and it reads as frozen")
            }
        }
    }

    func testATiredLidIsSlowerToLift() {
        XCTAssertGreaterThan(BlinkRhythm.duration(energy: 0), BlinkRhythm.duration(energy: 1))
        XCTAssertLessThan(BlinkRhythm.duration(energy: 0), 0.4, "still a blink, not a nap")
    }

    func testOutOfRangeInputsAreClamped() {
        XCTAssertEqual(BlinkRhythm.interval(energy: 9, jitter: 0.5),
                       BlinkRhythm.interval(energy: 1, jitter: 0.5))
        XCTAssertEqual(BlinkRhythm.interval(energy: 0.5, jitter: -3),
                       BlinkRhythm.interval(energy: 0.5, jitter: 0))
        XCTAssertEqual(BlinkRhythm.duration(energy: -1), BlinkRhythm.duration(energy: 0))
    }
}
