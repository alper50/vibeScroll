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

    func testOnlyBeingAddressedOpensTheMouth() {
        // The three reactions written before `mouthOpen` existed must be
        // untouched by it, which is what the defaulted parameter is for.
        let mood = FaceMood.base(for: .working)
        for quiet in [FaceReaction.noticed, .pleased, .winced] {
            XCTAssertEqual(mood.applying(quiet.impulse, strength: 1).mouthOpen, mood.mouthOpen,
                           "\(quiet) should not open the mouth")
        }
        XCTAssertGreaterThan(
            mood.applying(FaceReaction.greeted.impulse, strength: 1).mouthOpen, mood.mouthOpen)
    }

    func testAClickIsAnsweredFasterThanAMoodChanges() {
        // A reply to a poke that takes as long as a mood change does not read
        // as a reply to the poke. It is the *arrival* that carries that, not
        // the whole reaction — leaving just as fast read as a twitch, which is
        // why `greeted` is now the longest of the four overall.
        let greeted = FaceReaction.greeted.impulse
        for other in [FaceReaction.noticed, .pleased, .winced] {
            XCTAssertLessThan(greeted.rise, other.impulse.rise)
        }
    }

    func testASmileDoesNotSnapBack() {
        // Clicking the face used to peak and drop straight back to the mood in
        // half a second, which reads as a sprite being swapped rather than as
        // somebody reacting to you.
        for warm in [FaceReaction.greeted, .pleased] {
            let impulse = warm.impulse
            XCTAssertTrue(impulse.hasAfterglow, "\(warm) should relax rather than drop")
            XCTAssertGreaterThan(impulse.linger, impulse.hold,
                                 "\(warm) should sit at the afterglow longer than at its peak")
            XCTAssertEqual(impulse.total,
                           impulse.rise + impulse.hold + impulse.decay
                               + impulse.linger + impulse.fall,
                           accuracy: 0.0001)
        }
    }

    func testAFlinchHasNoTail() {
        // Nothing lingers about a wince, and `noticed` is an alert that has to
        // clear so the resting `waiting` face underneath can be read.
        for sharp in [FaceReaction.winced, .noticed] {
            let impulse = sharp.impulse
            XCTAssertFalse(impulse.hasAfterglow)
            XCTAssertEqual(impulse.total, impulse.rise + impulse.hold + impulse.fall,
                           accuracy: 0.0001)
        }
    }

    func testAnAfterglowIsWeakerThanThePeak() {
        // It is the same reaction fading, not a second one: a level at or above
        // the peak would mean the face never came down at all.
        for reaction in FaceReaction.allCases where reaction.impulse.hasAfterglow {
            XCTAssertGreaterThan(reaction.impulse.afterglow, 0)
            XCTAssertLessThan(reaction.impulse.afterglow, 1)
        }
    }

    func testAnAfterglowNeedsSomewhereToSpendItsTime() {
        // A level with no decay and no linger is a field nobody plays, and the
        // player would skip it while `total` counted it — clearing the impulse
        // out from under a face still wearing it.
        XCTAssertFalse(FaceImpulse(browAngle: 0, eyeOpenness: 0, mouthCurve: 0,
                                   rise: 0.1, hold: 0.1, afterglow: 0.5,
                                   fall: 0.1).hasAfterglow)
    }

    func testAnImpulseMayOvershootItsPeak() {
        // A muscle passes its target and comes back; an ease arrives and stops,
        // which is why the old rise read as interpolation. The spring that
        // drives `strength` goes past 1, and the offsets have to follow it
        // there or the overshoot is clipped away before it is ever drawn.
        let mood = FaceExpression(browAngle: 0, eyeOpenness: 0.5, mouthCurve: 0)
        let impulse = FaceImpulse(browAngle: 0.4, eyeOpenness: 0, mouthCurve: 0,
                                  rise: 0.1, hold: 0.1, fall: 0.1)
        XCTAssertGreaterThan(mood.applying(impulse, strength: 1.2).browAngle,
                             mood.applying(impulse, strength: 1).browAngle)
    }

    func testOvershootHasACeiling() {
        // Bounded so a mis-tuned spring cannot turn a flinch into a cartoon.
        let mood = FaceExpression(browAngle: 0, eyeOpenness: 0.5, mouthCurve: 0)
        let impulse = FaceImpulse(browAngle: 0.4, eyeOpenness: 0, mouthCurve: 0,
                                  rise: 0.1, hold: 0.1, fall: 0.1)
        XCTAssertEqual(mood.applying(impulse, strength: 99).browAngle,
                       mood.applying(impulse, strength: FaceImpulse.maxOvershoot).browAngle,
                       accuracy: 0.0001)
        XCTAssertLessThan(FaceImpulse.maxOvershoot, 1.5)
        XCTAssertGreaterThan(FaceImpulse.maxOvershoot, 1)
    }

    func testAReactionCannotPushTheFaceOutOfRange() {
        // A startle on an already wide-eyed face must not open the eyes past 1
        // and then come back down from somewhere the face was never at.
        let alert = FaceMood.base(for: .waiting)
        for reaction in FaceReaction.allCases {
            for strength in [0.25, 0.5, 1.0, FaceImpulse.maxOvershoot, 99.0] {
                let face = alert.applying(reaction.impulse, strength: strength)
                XCTAssertTrue((0...1).contains(face.eyeOpenness))
                XCTAssertTrue((-1...1).contains(face.browAngle))
                XCTAssertTrue((-1...1).contains(face.mouthCurve))
                XCTAssertTrue((0...1).contains(face.mouthOpen))
                XCTAssertLessThanOrEqual(face.tongue, face.mouthOpen)
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
        // These ride on an ambient surface. The *peak* is the part that competes
        // for the attention the face exists to save, so that is what stays
        // brief; the tail after it is the face settling, which is allowed to
        // take its time and is the whole reason the tail exists.
        for reaction in FaceReaction.allCases {
            let impulse = reaction.impulse
            XCTAssertLessThan(impulse.rise + impulse.hold, 0.7,
                              "\(reaction) holds its peak too long")
            XCTAssertLessThan(impulse.total, 2.5, "\(reaction) outstays its welcome")
            XCTAssertGreaterThan(impulse.rise, 0)
        }
    }
}
