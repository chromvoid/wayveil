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

    func testLightCirclesAtRest() {
        let light = PortalLight.light(at: 2, tilt: .zero)
        XCTAssertEqual((light.x * light.x + light.y * light.y + light.z * light.z).squareRoot(), 1, accuracy: 1e-5)
        XCTAssertEqual(light.w, 0)
        XCTAssertEqual(light.y / light.x, tan(1.3), accuracy: 1e-4)
    }

    func testTiltDrawsTheLightToTheEdgeTurnedToTheViewer() {
        // The right edge turned away, so the left edge faces the viewer.
        let light = PortalLight.light(at: 2, tilt: SIMD2(0.6, 0))
        XCTAssertEqual(light.w, 1)
        XCTAssertLessThan(light.x, -0.5)
        XCTAssertLessThan(abs(light.y), 0.25)
    }

    func testTrafficRunsBothWaysRoundTheRing() {
        let before = PortalTraffic.packets(at: 1), after = PortalTraffic.packets(at: 1.01)
        // Positive when a head moves counter-clockwise.
        func swing(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { a.x * b.y - a.y * b.x }
        XCTAssertEqual((before.0.x * before.0.x + before.0.y * before.0.y).squareRoot(), 1, accuracy: 1e-5)
        XCTAssertGreaterThan(swing(before.0, after.0), 0)
        XCTAssertGreaterThan(swing(before.2, after.2), 0)
        XCTAssertLessThan(swing(before.3, after.3), 0)
        XCTAssertLessThan(swing(before.5, after.5), 0)
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

    func testSpringsComeToRest() {
        var motion = PortalMotion()
        _ = motion.observe(lit: true, connected: false, power: 0, busy: 1, now: 0)
        for _ in 0..<120 { motion.step(dt: 1 / 60, connecting: true, close: 1, speed: 1) }
        XCTAssertNotEqual(motion.spinVelocity, 0)
        _ = motion.observe(lit: true, connected: true, power: 0, busy: 1, now: 2)
        for _ in 0..<300 { motion.step(dt: 1 / 60, connecting: false, close: 1, speed: 1) }
        XCTAssertEqual(motion.spinVelocity, 0)
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
