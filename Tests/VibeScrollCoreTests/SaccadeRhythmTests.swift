import XCTest
@testable import VibeScrollCore

final class SaccadeRhythmTests: XCTestCase {

    func testALivelyFaceResettlesMoreOften() {
        XCTAssertLessThan(SaccadeRhythm.interval(energy: 1, jitter: 0.5),
                          SaccadeRhythm.interval(energy: 0, jitter: 0.5))
    }

    func testJitterNeverLetsASpentFaceOutpaceALivelyOne() {
        XCTAssertLessThan(SaccadeRhythm.interval(energy: 1, jitter: 1),
                          SaccadeRhythm.interval(energy: 0, jitter: 0))
    }

    func testEveryGapIsLongEnoughToReadAsAFixation() {
        // Eyes that move again before they have settled are not looking at
        // anything, they are vibrating.
        for energy in stride(from: 0.0, through: 1.0, by: 0.1) {
            for jitter in [0.0, 0.5, 1.0] {
                let interval = SaccadeRhythm.interval(energy: energy, jitter: jitter)
                XCTAssertGreaterThan(interval, 1.5)
                XCTAssertLessThan(interval, 10)
            }
        }
    }

    func testAFlickNeverReachesAsFarAsThePointerCanPull() {
        // Following the pointer is the face looking at something. This is only
        // the eyes not being welded in place, and at full range it would read
        // as the face scanning the room.
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            for y in stride(from: 0.0, through: 1.0, by: 0.05) {
                let target = SaccadeRhythm.target(x: x, y: y, recentre: 1)
                XCTAssertLessThanOrEqual(abs(target.width), SaccadeRhythm.maxOffset + 0.0001)
                XCTAssertLessThanOrEqual(abs(target.height), SaccadeRhythm.maxOffset + 0.0001)
                XCTAssertLessThan(SaccadeRhythm.maxOffset, 1, "a flick is not a full look")
            }
        }
    }

    func testEyesRangeFurtherSideToSideThanUpAndDown() {
        // A face looking straight up is a face doing something, not idling.
        let corner = SaccadeRhythm.target(x: 1, y: 1, recentre: 1)
        XCTAssertGreaterThan(abs(corner.width), abs(corner.height))
    }

    func testSomeFlicksGoHome() {
        // Without this the gaze random-walks away and settles in a corner.
        XCTAssertEqual(SaccadeRhythm.target(x: 1, y: 1, recentre: 0), .zero)
        XCTAssertNotEqual(SaccadeRhythm.target(x: 1, y: 1, recentre: 1), .zero)
    }

    func testRecentringIsCommonButNotTheRule() {
        let home = stride(from: 0.0, through: 1.0, by: 0.01)
            .filter { SaccadeRhythm.target(x: 1, y: 1, recentre: $0) == .zero }.count
        XCTAssertGreaterThan(home, 20, "the gaze would wander off and stay there")
        XCTAssertLessThan(home, 80, "eyes that mostly stare straight ahead are the old behaviour")
    }

    func testTheMidpointSampleLooksStraightAhead() {
        XCTAssertEqual(SaccadeRhythm.target(x: 0.5, y: 0.5, recentre: 1), .zero)
    }

    func testASleepingFaceDoesNotFlick() {
        // Shut eyes darting about are not resting. Tied to the blink's own
        // threshold so the two stop together rather than one at a time.
        XCTAssertTrue(SaccadeRhythm.sleeps(atEnergy: 0))
        XCTAssertFalse(SaccadeRhythm.sleeps(atEnergy: 1))
        for energy in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(SaccadeRhythm.sleeps(atEnergy: energy),
                           BlinkRhythm.sleeps(atEnergy: energy))
        }
    }

    func testAMoveIsFasterThanABlink() {
        // Saccades are the quickest movement a body makes.
        XCTAssertLessThan(SaccadeRhythm.moveDuration, BlinkRhythm.duration(energy: 1))
    }

    func testOutOfRangeInputsAreClamped() {
        XCTAssertEqual(SaccadeRhythm.interval(energy: 9, jitter: 0.5),
                       SaccadeRhythm.interval(energy: 1, jitter: 0.5))
        XCTAssertEqual(SaccadeRhythm.target(x: 5, y: 5, recentre: 1),
                       SaccadeRhythm.target(x: 1, y: 1, recentre: 1))
    }
}
