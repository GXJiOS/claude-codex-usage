import XCTest
@testable import QuotaBar
final class CyclistSpriteTests: XCTestCase {
    /// In the right-facing space the skeleton is built in, the cranks must turn clockwise
    /// (the draw-time mirror flips this to match the left-facing rider). Frame 0 puts the
    /// pedal at the front of its circle; the next frame carries it down and back, not up.
    func testCranksTurnForward() {
        let first = CyclistSprite.pedal(crank: CyclistSprite.crankAngle(frameIndex: 0))
        let second = CyclistSprite.pedal(crank: CyclistSprite.crankAngle(frameIndex: 1))
        XCTAssertGreaterThan(first.x, second.x, "the pedal sweeps back from the front")
        XCTAssertGreaterThan(first.y, second.y, "the pedal drops rather than rising")
    }

    /// A full revolution returns to the start, so the loop does not jump.
    func testRevolutionCloses() {
        let start = CyclistSprite.pedal(crank: CyclistSprite.crankAngle(frameIndex: 0))
        let wrapped = CyclistSprite.pedal(crank: CyclistSprite.crankAngle(frameIndex: CyclistSprite.frameCount))
        XCTAssertEqual(start.x, wrapped.x, accuracy: 0.0001)
        XCTAssertEqual(start.y, wrapped.y, accuracy: 0.0001)
    }
}
