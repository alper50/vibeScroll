import XCTest
@testable import VibeScrollCore

final class TongueMotionTests: XCTestCase {

    // MARK: - Timing

    func testALivelyFaceFidgetsMoreOften() {
        XCTAssertLessThan(TongueMotion.interval(energy: 1, jitter: 0.5),
                          TongueMotion.interval(energy: 0, jitter: 0.5))
    }

    func testEveryGapIsLongEnoughToReadAsStillness() {
        // The point of gestures over drift: the tongue holds still between
        // them, so the orb is not re-blurred continuously.
        for energy in stride(from: 0.0, through: 1.0, by: 0.25) {
            for jitter in [0.0, 1.0] {
                let gap = TongueMotion.interval(energy: energy, jitter: jitter)
                XCTAssertGreaterThan(gap, 1.8, "a fidget every second is a tic")
                XCTAssertLessThan(gap, 9, "longer than this and it is a sticker again")
            }
        }
    }

    func testEveryGestureIsOverInUnderASecond() {
        for gesture in TongueMotion.Gesture.allCases {
            for energy in [0.0, 1.0] {
                let total = TongueMotion.keyframes(for: gesture, from: .rest, energy: energy,
                                                   a: 0.5, b: 0.5)
                    .reduce(0) { $0 + $1.duration }
                XCTAssertLessThan(total, 1.0, "\(gesture) at energy \(energy)")
                XCTAssertGreaterThan(total, 0.2, "\(gesture) too quick to see")
            }
        }
    }

    func testATiredFaceMovesSlower() {
        let brisk = TongueMotion.keyframes(for: .wiggle, from: .rest, energy: 1, a: 0, b: 0)
        let weary = TongueMotion.keyframes(for: .wiggle, from: .rest, energy: 0, a: 0, b: 0)
        XCTAssertLessThan(brisk.reduce(0) { $0 + $1.duration },
                          weary.reduce(0) { $0 + $1.duration })
    }

    // MARK: - Choice

    func testEveryGestureIsReachable() {
        let chosen = Set(stride(from: 0.0, through: 1.0, by: 0.05)
            .map { "\(TongueMotion.gesture(sample: $0))" })
        XCTAssertEqual(chosen.count, TongueMotion.Gesture.allCases.count)
    }

    // MARK: - Shift

    func testAShiftFromTheMiddleParksInACorner() {
        let frames = TongueMotion.keyframes(for: .shift, from: .rest, energy: 1, a: 0.1, b: 0.5)
        let end = frames.last!.pose
        XCTAssertGreaterThanOrEqual(abs(end.side), TongueMotion.cornerReach.lowerBound)
        XCTAssertLessThanOrEqual(abs(end.side), TongueMotion.cornerReach.upperBound)
        XCTAssertEqual(end.reach, 1)
    }

    func testAParkedTongueLeansIntoItsCorner() {
        for a in [0.1, 0.9] {
            let end = TongueMotion.keyframes(for: .shift, from: .rest, energy: 1, a: a, b: 0.5)
                .last!.pose
            XCTAssertEqual(end.tilt.sign, end.side.sign)
        }
    }

    func testAShiftAlwaysVisiblyMoves() {
        // Parked on one side, it goes to the middle or the other side — never
        // to the same corner again, which would be a gesture that shows nothing.
        let parked = TonguePose(side: 0.7, reach: 1, tilt: 0.5)
        for a in stride(from: 0.0, through: 1.0, by: 0.1) {
            let end = TongueMotion.keyframes(for: .shift, from: parked, energy: 1, a: a, b: 0.5)
                .last!.pose
            XCTAssertLessThanOrEqual(end.side, 0, "a = \(a)")
        }
    }

    // MARK: - Wiggle and withdraw

    func testAWiggleComesHome() {
        let start = TonguePose(side: -0.6, reach: 1, tilt: -0.4)
        let frames = TongueMotion.keyframes(for: .wiggle, from: start, energy: 1, a: 0.3, b: 1)
        XCTAssertEqual(frames.last!.pose, start)
        XCTAssertGreaterThanOrEqual(frames.count, 3, "one swing is a twitch, not a wiggle")
    }

    func testAWiggleNeverLeavesTheMouth() {
        let atEdge = TonguePose(side: 0.95, reach: 1, tilt: 0.7)
        for a in [0.0, 1.0] {
            for frame in TongueMotion.keyframes(for: .wiggle, from: atEdge, energy: 1, a: a, b: 1) {
                XCTAssertLessThanOrEqual(abs(frame.pose.side), 1)
            }
        }
    }

    func testAWithdrawGoesInQuicklyAndComesOutSlower() {
        let start = TonguePose(side: 0.5, reach: 1, tilt: 0.3)
        let frames = TongueMotion.keyframes(for: .withdraw, from: start, energy: 1, a: 0, b: 0)
        XCTAssertEqual(frames.count, 2)
        XCTAssertLessThan(frames[0].pose.reach, 0.5, "drawn most of the way in")
        XCTAssertLessThan(frames[0].duration, frames[1].duration,
                          "equal halves read as a mechanism")
        XCTAssertEqual(frames[1].pose, start)
    }
}
