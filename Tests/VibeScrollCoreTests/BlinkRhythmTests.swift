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

    // MARK: - The shape of one blink

    func testALidDropsFasterThanItLifts() {
        // Equal halves is what anyone writes first, and it is the single thing
        // that makes a blink read as a shutter rather than an eyelid.
        for energy in [0.0, 0.5, 1.0] {
            XCTAssertLessThan(BlinkRhythm.closeDuration(energy: energy),
                              BlinkRhythm.openDuration(energy: energy))
        }
    }

    func testTheTwoHalvesStillMakeTheWhole() {
        // `duration` is what the double-blink gap is measured from, so the
        // parts and the total cannot drift apart.
        for energy in stride(from: 0.0, through: 1.0, by: 0.25) {
            XCTAssertEqual(
                BlinkRhythm.closeDuration(energy: energy) + BlinkRhythm.openDuration(energy: energy),
                BlinkRhythm.duration(energy: energy), accuracy: 0.0001)
        }
    }

    func testBothHalvesSlowWhenSpent() {
        XCTAssertGreaterThan(BlinkRhythm.closeDuration(energy: 0),
                             BlinkRhythm.closeDuration(energy: 1))
        XCTAssertGreaterThan(BlinkRhythm.openDuration(energy: 0),
                             BlinkRhythm.openDuration(energy: 1))
    }

    func testNoHalfIsSoShortItCannotBeSeen() {
        for energy in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertGreaterThan(BlinkRhythm.closeDuration(energy: energy), 0.03,
                                 "a lid that closes in under 30ms is a dropped frame")
        }
    }

    // MARK: - Doubles

    func testSomeBlinksComeInPairs() {
        // Varying the blinks, not only the gaps between them — otherwise the
        // rhythm reads as a metronome however well the interval is jittered.
        XCTAssertTrue(BlinkRhythm.isDouble(sample: 0))
        XCTAssertFalse(BlinkRhythm.isDouble(sample: 0.99))
    }

    func testDoublesAreOccasionalRatherThanTheNorm() {
        let hits = stride(from: 0.0, through: 1.0, by: 0.01)
            .filter { BlinkRhythm.isDouble(sample: $0) }.count
        XCTAssertLessThan(hits, 30, "a face that double-blinks half the time is twitching")
        XCTAssertGreaterThan(hits, 5, "rare enough never to be seen is the same as absent")
    }

    func testTheGapBetweenAPairIsShorterThanAnyInterval() {
        // Otherwise the second blink is not a pair, it is just the next blink.
        XCTAssertLessThan(BlinkRhythm.doubleGap,
                          BlinkRhythm.interval(energy: 1, jitter: 0))
    }

    // MARK: - Staying out of the way

    func testTheSuppressionThresholdSitsBelowAReactionsPeak() {
        // A scheduled blink must defer to a reaction that is already playing,
        // which only works if the threshold is somewhere a rising impulse
        // actually passes through.
        XCTAssertGreaterThan(BlinkRhythm.suppressedAboveReaction, 0)
        XCTAssertLessThan(BlinkRhythm.suppressedAboveReaction, 1)
    }
}
