import Foundation

/// Turns gyroscope rates into a screen-space tilt that follows the hand and drifts back to neutral while the phone rests.
///
/// x > 0 when the right edge of the screen turns away from the viewer, y > 0 when the top edge does.
/// Rates are rad/s about the device axes (x right, y up, z towards the viewer). Mirrors TiltTracker.kt on Android.
struct TiltTracker {
    var fullScale: Float = 0.3
    var recentreSeconds: Float = 2.5
    private var pitch: Float = 0
    private var roll: Float = 0
    private(set) var tilt = SIMD2<Float>(repeating: 0)

    /// `quarterTurns` counts counter-clockwise quarter turns of the device from portrait.
    mutating func update(rateX: Float, rateY: Float, dt: Float, quarterTurns: Int) {
        guard dt > 0, dt <= 0.25 else { return }
        let leak = exp(-dt / recentreSeconds)
        pitch = (pitch + rateX * dt) * leak
        roll = (roll + rateY * dt) * leak
        let device = SIMD2(tanh(roll / fullScale), tanh(-pitch / fullScale))
        switch quarterTurns & 3 {
        case 1: tilt = SIMD2(-device.y, device.x)
        case 2: tilt = -device
        case 3: tilt = SIMD2(device.y, -device.x)
        default: tilt = device
        }
    }
}

/// Remembers tunnel transitions and integrates the springs that part, turn and lock the two logo crescents.
/// Mirrors PortalMotion in PortalEffect.kt on Android.
struct PortalMotion {
    static let closeSeconds = 0.75
    // The C2 glyph is symmetric under a half turn, so any multiple of it is a resting pose.
    private static let halfTurn = Float.pi
    private var wasLit: Bool?
    private var wasConnected = false
    private var closeAt: TimeInterval?
    private var impactAt: TimeInterval?
    private var holdPower: Float = 0
    private var holdBusy: Float = 0
    private var splitVelocity: Float = 0
    private var spinTarget: Float?
    private(set) var split: Float = 0
    private(set) var spin: Float = 0
    private(set) var spinVelocity: Float = 0

    /// Records a phase change and returns true when the tunnel has just connected.
    /// Transitions are read from phase changes, so a stopping phase too short to render still closes the portal.
    mutating func observe(lit: Bool, connected: Bool, power: Float, busy: Float, now: TimeInterval) -> Bool {
        guard let previous = wasLit else {
            wasLit = lit
            wasConnected = connected
            return false
        }
        if previous && !lit {
            closeAt = now
            holdPower = power
            holdBusy = busy
            spinTarget = ((spin / Self.halfTurn).rounded() - 1) * Self.halfTurn
        }
        if lit { closeAt = nil }
        let impact = connected && !wasConnected
        if impact { impactAt = now }
        wasLit = lit
        wasConnected = connected
        return impact
    }

    /// Progress of the closing animation, 1 when none is running.
    func close(at now: TimeInterval) -> Float {
        closeAt.map { min(1, Float((now - $0) / Self.closeSeconds)) } ?? 1
    }

    /// Seconds since the tunnel connected, capped at 10.
    func impact(at now: TimeInterval) -> Float {
        impactAt.map { min(10, Float(now - $0)) } ?? 10
    }

    /// Keeps the ring lit while it drains during a close.
    func held(power: Float, busy: Float, close: Float) -> (power: Float, busy: Float) {
        guard close < 1 else { return (power, busy) }
        let fade = 1 - smoothstep(0.4, 1, close)
        return (max(power, holdPower * fade), max(busy, holdBusy * fade))
    }

    mutating func step(dt: Float, connecting: Bool, close: Float, speed: Float) {
        guard dt > 0 else { return }
        let splitTarget: Float = close < 0.45 ? 0.7 : connecting ? 1 : 0
        let h = dt / 4
        for _ in 0..<4 {
            // Parting is critically damped; locking overshoots so the crescents visibly clack together.
            let locking = splitTarget < split
            splitVelocity += ((locking ? 320 : 45) * (splitTarget - split) - (locking ? 14 : 13) * splitVelocity) * h
            split += splitVelocity * h
            if connecting {
                spinTarget = nil
                spinVelocity += (1.8 * speed - spinVelocity) * (1 - exp(-h * 1.5))
            } else {
                let target = spinTarget ?? (spinVelocity > 0.2 ? (spin / Self.halfTurn).rounded(.up)
                    : (spin / Self.halfTurn).rounded()) * Self.halfTurn
                spinTarget = target
                // Closing unwinds half a turn slowly; otherwise the spin snaps forward into the lock with the crescents.
                let closing = close < 1
                spinVelocity += ((closing ? 40 : 320) * (target - spin) - (closing ? 11.4 : 14) * spinVelocity) * h
            }
            spin += spinVelocity * h
        }
        // Settled springs snap to rest so the shader can skip the layers they drive.
        if abs(split - splitTarget) < 0.0005, abs(splitVelocity) < 0.005 {
            split = splitTarget
            splitVelocity = 0
        }
        if !connecting, close >= 1, let target = spinTarget, abs(spin - target) < 0.001, abs(spinVelocity) < 0.01 {
            let rested = target - (target / (2 * Self.halfTurn)).rounded(.down) * 2 * Self.halfTurn
            spinTarget = rested
            spin = rested
            spinVelocity = 0
        }
    }

    /// Drops all motion, for reduced motion.
    mutating func settle() {
        split = 0
        splitVelocity = 0
        spin = 0
        spinVelocity = 0
        spinTarget = nil
        closeAt = nil
        impactAt = nil
    }
}

private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

/// Places the packets of light that run round the ring while it is connected: three along the inner wire, three the other way along the outer one.
/// The shader gets their heads ready-made, so it does not work out the same six angles for every pixel.
enum PortalTraffic {
    typealias Packets = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    /// A fixed random number per packet that sets where it starts, how fast it runs and how long its tail is.
    static let seeds: [Float] = [0.5524, 0.8349, 0.8579, 0.6066, 0.4873, 0.2637]

    /// Per packet: x and y the unit vector from the ring's centre to its head, z how fast its tail fades.
    static func packets(at time: Float) -> Packets {
        func packet(_ i: Int) -> SIMD4<Float> {
            let seed = seeds[i]
            let direction: Float = i < 3 ? 1 : -1
            let head = Float(i) * 2.1 + seed * 6 + direction * time * (4 + 2.5 * seed)
            return SIMD4(cos(head), sin(head), 1.3 + 1.2 * seed, 0)
        }
        return (packet(0), packet(1), packet(2), packet(3), packet(4), packet(5))
    }
}

/// Places the one light that shades the whole portal: the ring's reflection, glint and highlight, and the logo's gloss and shadow.
/// It circles slowly at rest and leans towards the edge that the tilt turned to the viewer, so all of them follow the hand together.
/// Mirrors PortalLight in PortalEffect.kt on Android.
enum PortalLight {
    /// x, y and z the unit vector towards the light (x right, y up, z towards the viewer); w how far tilt has drawn it down, 0...1.
    static func light(at time: Float, tilt: SIMD2<Float>) -> SIMD4<Float> {
        let lean = smoothstep(0.04, 0.5, min(1, (tilt * tilt).sum().squareRoot()))
        let angle = time * 0.65
        let toward = SIMD2(cos(angle), sin(angle)) * 0.65 * (1 - 0.7 * lean) - tilt * 1.3
        let length = (toward.x * toward.x + toward.y * toward.y + 0.81).squareRoot()
        return SIMD4(toward.x / length, toward.y / length, 0.9 / length, lean)
    }
}
