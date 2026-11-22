import XCTest

final class PortalMotionTests: XCTestCase {
    private func turn(_ tracker: inout TiltTracker, rateX: Float, rateY: Float, seconds: Float, quarterTurns: Int = 0) {
        for _ in 0..<Int(seconds * 100) { tracker.update(rateX: rateX, rateY: rateY, dt: 0.01, quarterTurns: quarterTurns) }
    }

    func testTurningTheRightEdgeAwayTiltsRight() {
        var tracker = TiltTracker()
        turn(&tracker, rateX: 0, rateY: 0.3, seconds: 0.5)
        XCTAssertGreaterThan(tracker.tilt.x, 0.2)
        XCTAssertEqual(tracker.tilt.y, 0, accuracy: 1e-6)
    }

    func testTurningTheTopEdgeAwayTiltsUp() {
        var tracker = TiltTracker()
        turn(&tracker, rateX: -0.3, rateY: 0, seconds: 0.5)
        XCTAssertGreaterThan(tracker.tilt.y, 0.2)
        XCTAssertEqual(tracker.tilt.x, 0, accuracy: 1e-6)
    }

    func testAnswersASmallTurnGently() {
        // Two degrees.
        var tracker = TiltTracker()
        turn(&tracker, rateX: 0, rateY: 0.35, seconds: 0.1)
        XCTAssertGreaterThan(tracker.tilt.x, 0.05)
        XCTAssertLessThan(tracker.tilt.x, 0.1)
    }

    func testRecentresWhileThePhoneRests() {
        var tracker = TiltTracker()
        turn(&tracker, rateX: 0, rateY: 1.5, seconds: 0.35)
        XCTAssertGreaterThan(tracker.tilt.x, 0.7)
        XCTAssertLessThan(tracker.tilt.x, 1)
        turn(&tracker, rateX: 0, rateY: 0, seconds: 10)
        XCTAssertLessThan(tracker.tilt.x, 0.03)
    }

    func testComesHomeAfterATurnThereAndBack() {
        var tracker = TiltTracker()
        turn(&tracker, rateX: 0, rateY: 1.5, seconds: 0.2)
        turn(&tracker, rateX: 0, rateY: 0, seconds: 2)
        var lowest: Float = 1
        for _ in 0..<20 {
            tracker.update(rateX: 0, rateY: -1.5, dt: 0.01, quarterTurns: 0)
            lowest = min(lowest, tracker.tilt.x)
        }
        XCTAssertGreaterThan(lowest, -0.06)
    }

    func testTurningPastTheOldPoseTiltsTheOtherWay() {
        var tracker = TiltTracker()
        turn(&tracker, rateX: 0, rateY: 1.5, seconds: 0.2)
        turn(&tracker, rateX: 0, rateY: 0, seconds: 2)
        turn(&tracker, rateX: 0, rateY: -1.5, seconds: 0.4)
        XCTAssertLessThan(tracker.tilt.x, -0.4)
    }

    func testTakesAPoseHeldLongAsTheNewOne() {
        var tracker = TiltTracker()
        turn(&tracker, rateX: 0, rateY: 1.5, seconds: 0.2)
        turn(&tracker, rateX: 0, rateY: 0, seconds: 30)
        turn(&tracker, rateX: 0, rateY: -1.5, seconds: 0.2)
        XCTAssertLessThan(tracker.tilt.x, -0.4)
    }

    func testMapsDeviceAxesToTheRotatedScreen() {
        var tracker = TiltTracker()
        turn(&tracker, rateX: 0, rateY: 0.3, seconds: 0.5, quarterTurns: 1)
        XCTAssertGreaterThan(tracker.tilt.y, 0.2)
        XCTAssertEqual(tracker.tilt.x, 0, accuracy: 1e-6)
    }

    func testSpringEasesTowardsTheSensorWithoutOvershoot() {
        var spring = TiltSpring()
        spring.step(toward: SIMD2(1, 0), dt: 1 / 60)
        XCTAssertGreaterThan(spring.tilt.x, 0)
        XCTAssertLessThan(spring.tilt.x, 0.1)
        var highest: Float = 0
        for _ in 0..<60 {
            spring.step(toward: SIMD2(1, 0), dt: 1 / 60)
            highest = max(highest, spring.tilt.x)
        }
        XCTAssertLessThanOrEqual(highest, 1)
        XCTAssertEqual(spring.tilt.x, 1, accuracy: 1e-3)
        XCTAssertEqual(spring.tilt.y, 0)
    }

    func testSpringSmoothsTheBeatOfTheSensorRate() {
        // A 100 Hz sensor read at 60 fps hands a steady turn over in steps of two samples, two samples and one.
        var spring = TiltSpring()
        var target: Float = 0
        var steps: [Float] = []
        for frame in 0..<90 {
            target += frame % 3 == 2 ? 0.01 : 0.02
            let before = spring.tilt.x
            spring.step(toward: SIMD2(target, 0), dt: 1 / 60)
            if frame >= 60 { steps.append(spring.tilt.x - before) }
        }
        XCTAssertLessThan(steps.max()! - steps.min()!, 0.002)
    }

    func testLightCirclesAtRest() {
        let light = PortalLight.light(at: 2, tilt: .zero)
        XCTAssertEqual((light.x * light.x + light.y * light.y + light.z * light.z).squareRoot(), 1, accuracy: 1e-5)
        XCTAssertEqual(light.w, 0)
        XCTAssertEqual(light.y / light.x, tan(1.3), accuracy: 1e-4)
    }

    func testTiltDrawsTheLightToTheEdgeTurnedToTheViewer() {
        // The right edge turned away, so the left edge faces the viewer.
        let light = PortalLight.light(at: 2, tilt: SIMD2(0.9, 0))
        XCTAssertEqual(light.w, 1)
        XCTAssertLessThan(light.x, -0.5)
        XCTAssertLessThan(abs(light.y), 0.3)
    }

    func testSmallTiltMovesTheLightALittle() {
        // About two degrees of turn moves the light under six degrees round the ring and leaves the highlight off.
        let light = PortalLight.light(at: 0, tilt: SIMD2(0, 0.07))
        XCTAssertLessThan(abs(atan2(light.y, light.x)), 0.1)
        XCTAssertEqual(light.w, 0)
    }

    func testTiltAgainstTheOrbitCarriesTheLightOverTheTop() {
        // Leaning the other way from where the light circles, it passes close to straight ahead instead of jumping across.
        var previous = PortalLight.light(at: 0, tilt: .zero)
        for step in 1...90 {
            let light = PortalLight.light(at: 0, tilt: SIMD2(Float(step) / 100, 0))
            XCTAssertGreaterThan(light.x * previous.x + light.y * previous.y + light.z * previous.z, 0.999)
            previous = light
        }
        XCTAssertLessThan(previous.x, 0)
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

    func testNoiseBakesTheSameBytesAsAndroid() {
        // PortalNoiseTest on Android checks the same texels, so both shaders read the same noise.
        let bytes = PortalNoise.bake()
        let at = { (column: Int, row: Int) in bytes[row * PortalNoise.size + column] }
        XCTAssertEqual(at(0, 0), 26)
        XCTAssertEqual(at(255, 17), 137)
        XCTAssertEqual(at(100, 400), 138)
        XCTAssertEqual(at(511, 511), 24)
    }

    func testNoiseTilesWithoutASeam() {
        let bytes = PortalNoise.bake().map(Int.init)
        let last = PortalNoise.size - 1
        let at = { (column: Int, row: Int) in bytes[row * PortalNoise.size + column] }
        var seam = 0
        var step = 0
        for row in 0...last {
            seam = max(seam, abs(at(last, row) - at(0, row)), abs(at(row, last) - at(row, 0)))
            for column in 1...last { step = max(step, abs(at(column, row) - at(column - 1, row))) }
        }
        XCTAssertLessThanOrEqual(seam, step)
    }

    private func run(_ flow: inout PortalFlow, seconds: Float, connected: Bool = true, bytesPerSecond: Double?) {
        for _ in 0..<Int(seconds * 60) { flow.step(dt: 1.0 / 60, connected: connected, bytesPerSecond: bytesPerSecond) }
    }

    func testFlowReadsTrafficOnALogarithmicScale() {
        XCTAssertEqual(PortalFlow.level(bytesPerSecond: 1_500), 0)
        XCTAssertEqual(PortalFlow.level(bytesPerSecond: 63_245.55), 0.5, accuracy: 0.001)
        XCTAssertEqual(PortalFlow.level(bytesPerSecond: 2_000_000), 1)
        XCTAssertEqual(PortalFlow.level(bytesPerSecond: 50_000_000), 1)
    }

    func testFlowBreathesFromHalfwayEveryFiveSeconds() {
        XCTAssertEqual(PortalFlow.breath(secondsOpen: 1), 0.5)
        XCTAssertEqual(PortalFlow.breath(secondsOpen: 2.001), 0.5, accuracy: 0.01)
        for step in 0..<50 {
            let at = 3 + Float(step) * 0.1
            XCTAssertEqual(PortalFlow.breath(secondsOpen: at), PortalFlow.breath(secondsOpen: at + 5), accuracy: 0.001)
        }
        let cycle = (0..<500).map { PortalFlow.breath(secondsOpen: 3 + Float($0) * 0.01) }
        XCTAssertEqual(cycle.max()!, 1, accuracy: 0.01)
        XCTAssertEqual(cycle.min()!, 0, accuracy: 0.01)
    }

    func testFlowStandsStillWithoutTraffic() {
        var flow = PortalFlow()
        run(&flow, seconds: 10, bytesPerSecond: 500)
        XCTAssertEqual(flow.traffic, 0)
        XCTAssertEqual(flow.drift, 0)
        XCTAssertTrue(flow.ripples.allSatisfy { $0 == .zero })
    }

    func testFlowDropsRipplesThatDieAway() {
        var flow = PortalFlow()
        run(&flow, seconds: 3, bytesPerSecond: 1_000_000)
        XCTAssertGreaterThan(flow.drift, 0)
        XCTAssertTrue(flow.ripples.contains { $0.w > 0 })
        run(&flow, seconds: 3, connected: false, bytesPerSecond: nil)
        XCTAssertEqual(flow.traffic, 0)
        XCTAssertEqual(flow.breath, 0.5)
        XCTAssertTrue(flow.ripples.allSatisfy { $0 == .zero })
    }

    func testFlowDropsTheSameRipplesAsAndroid() {
        // PortalFlowTest on Android checks the same numbers, so both portals ripple alike.
        var flow = PortalFlow()
        run(&flow, seconds: 3, bytesPerSecond: 1_000_000)
        XCTAssertEqual(flow.traffic, 0.89955, accuracy: 1e-4)
        XCTAssertEqual(flow.drift, 1.44393, accuracy: 1e-3)
        let expected: [Float] = [0, 0, 0, 0, -0.78656, 0.61752, 0.66667, 1.0393, 0.94702, -0.32116, 0.2, 1.03967]
        let actual = flow.ripples.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        for (index, value) in expected.enumerated() { XCTAssertEqual(actual[index], value, accuracy: 1e-3, "ripples[\(index)]") }
    }
}
