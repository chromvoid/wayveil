import XCTest

final class PortalMotionTests: XCTestCase {
    private func turn(_ tracker: inout TiltTracker, rateX: Float, rateY: Float, seconds: Float, quarterTurns: Int = 0) {
        for _ in 0..<Int(seconds * 100) { tracker.update(rateX: rateX, rateY: rateY, dt: 0.01, quarterTurns: quarterTurns) }
    }

    func testTurningTheRightEdgeAwayTiltsRight() {
        var tracker = TiltTracker()
        turn(&tracker, rateX: 0, rateY: 0.3, seconds: 0.5)
        XCTAssertGreaterThan(tracker.tilt.x, 0.35)
        XCTAssertEqual(tracker.tilt.y, 0, accuracy: 1e-6)
    }

    func testTurningTheTopEdgeAwayTiltsUp() {
        var tracker = TiltTracker()
        turn(&tracker, rateX: -0.3, rateY: 0, seconds: 0.5)
        XCTAssertGreaterThan(tracker.tilt.y, 0.35)
        XCTAssertEqual(tracker.tilt.x, 0, accuracy: 1e-6)
    }

    func testRecentresWhileThePhoneRests() {
        var tracker = TiltTracker()
        turn(&tracker, rateX: 0, rateY: 1.5, seconds: 0.2)
        XCTAssertGreaterThan(tracker.tilt.x, 0.7)
        turn(&tracker, rateX: 0, rateY: 0, seconds: 8)
        XCTAssertLessThan(tracker.tilt.x, 0.05)
    }

    func testMapsDeviceAxesToTheRotatedScreen() {
        var tracker = TiltTracker()
        turn(&tracker, rateX: 0, rateY: 0.3, seconds: 0.5, quarterTurns: 1)
        XCTAssertGreaterThan(tracker.tilt.y, 0.35)
        XCTAssertEqual(tracker.tilt.x, 0, accuracy: 1e-6)
    }

    func testConnectingPartsTheCrescentsAndConnectingLocksThem() {
        var motion = PortalMotion()
        XCTAssertFalse(motion.observe(lit: false, connected: false, power: 0, busy: 0, now: 0))
        XCTAssertFalse(motion.observe(lit: true, connected: false, power: 0, busy: 0, now: 0))
        for _ in 0..<120 { motion.step(dt: 1 / 60, connecting: true, close: 1, speed: 1) }
        XCTAssertGreaterThan(motion.split, 0.8)
        XCTAssertGreaterThan(motion.spinVelocity, 1)
        XCTAssertTrue(motion.observe(lit: true, connected: true, power: 0, busy: 1, now: 2))
        for _ in 0..<90 { motion.step(dt: 1 / 60, connecting: false, close: 1, speed: 1) }
        XCTAssertEqual(motion.split, 0, accuracy: 0.01)
        XCTAssertEqual(motion.spin.truncatingRemainder(dividingBy: .pi), 0, accuracy: 0.01)
    }

    func testSpringsComeToRestSoFramesCanSlowDown() {
        var motion = PortalMotion()
        _ = motion.observe(lit: true, connected: false, power: 0, busy: 1, now: 0)
        for _ in 0..<120 { motion.step(dt: 1 / 60, connecting: true, close: 1, speed: 1) }
        XCTAssertFalse(motion.settled)
        _ = motion.observe(lit: true, connected: true, power: 0, busy: 1, now: 2)
        for _ in 0..<300 { motion.step(dt: 1 / 60, connecting: false, close: 1, speed: 1) }
        XCTAssertTrue(motion.settled)
        XCTAssertEqual(motion.split, 0)
    }

    func testDisconnectClosesEvenWithoutAStoppingPhase() {
        var motion = PortalMotion()
        _ = motion.observe(lit: true, connected: true, power: 1, busy: 0, now: 0)
        _ = motion.observe(lit: false, connected: false, power: 1, busy: 0, now: 10)
        XCTAssertEqual(motion.close(at: 10.375), 0.5, accuracy: 0.001)
        XCTAssertEqual(motion.held(power: 0, busy: 0, close: 0.2).power, 1)
        XCTAssertEqual(motion.close(at: 11), 1)
    }
}
