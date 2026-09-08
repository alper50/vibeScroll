import XCTest
@testable import VibeScrollCore

final class FaceReactionTests: XCTestCase {

    func testAReactionAtRestChangesNothing() {
        let mood = FaceMood.base(for: .working)
        XCTAssertEqual(mood.applying(FaceReaction.noticed.impulse, strength: 0), mood)
        XCTAssertEqual(mood.applying(FaceReaction.winced.impulse, strength: -1), mood)
    }

    func testNoticingOpensTheFaceUp() {
        let mood = FaceMood.base(for: .working)
        let startled = mood.applying(FaceReaction.noticed.impulse, strength: 1)
        XCTAssertGreaterThan(startled.eyeOpenness, mood.eyeOpenness)
        XCTAssertGreaterThan(startled.browAngle, mood.browAngle)
    }

    func testWincingClosesItDown() {
        let mood = FaceMood.base(for: .working)
        let winced = mood.applying(FaceReaction.winced.impulse, strength: 1)
        XCTAssertLessThan(winced.eyeOpenness, mood.eyeOpenness)
        XCTAssertLessThan(winced.browAngle, mood.browAngle)
        XCTAssertLessThan(winced.mouthCurve, mood.mouthCurve)
    }

    func testFinishingSmiles() {
        let mood = FaceMood.base(for: .working)
        XCTAssertGreaterThan(
            mood.applying(FaceReaction.pleased.impulse, strength: 1).mouthCurve, mood.mouthCurve)
    }

    func testAReactionCannotPushTheFaceOutOfRange() {
        // A startle on an already wide-eyed face must not open the eyes past 1
        // and then come back down from somewhere the face was never at.
        let alert = FaceMood.base(for: .waiting)
        for reaction in FaceReaction.allCases {
            for strength in [0.25, 0.5, 1.0] {
                let face = alert.applying(reaction.impulse, strength: strength)
                XCTAssertTrue((0...1).contains(face.eyeOpenness))
                XCTAssertTrue((-1...1).contains(face.browAngle))
                XCTAssertTrue((-1...1).contains(face.mouthCurve))
            }
        }
    }

    func testStrengthScalesTheOffsetLinearly() {
        let mood = FaceExpression(browAngle: 0, eyeOpenness: 0.5, mouthCurve: 0)
        let impulse = FaceImpulse(browAngle: 0.4, eyeOpenness: 0, mouthCurve: 0,
                                  rise: 0.1, hold: 0.1, fall: 0.1)
        XCTAssertEqual(mood.applying(impulse, strength: 0.5).browAngle, 0.2, accuracy: 0.0001)
        XCTAssertEqual(mood.applying(impulse, strength: 1).browAngle, 0.4, accuracy: 0.0001)
    }

    func testEveryReactionIsPunctuationRatherThanAPerformance() {
        // These ride on an ambient surface. Anything longer starts competing
        // for the attention the face exists to save.
        for reaction in FaceReaction.allCases {
            let impulse = reaction.impulse
            XCTAssertLessThan(impulse.total, 1.5, "\(reaction) outstays its welcome")
            XCTAssertGreaterThan(impulse.rise, 0)
            XCTAssertEqual(impulse.total, impulse.rise + impulse.hold + impulse.fall)
        }
    }
}
