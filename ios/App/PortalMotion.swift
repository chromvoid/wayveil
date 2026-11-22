import Foundation

/// Turns gyroscope rates into a screen-space tilt that follows the hand and drifts back to neutral while the phone rests.
///
/// x > 0 when the right edge of the screen turns away from the viewer, y > 0 when the top edge does.
/// Rates are rad/s about the device axes (x right, y up, z towards the viewer). Mirrors TiltTracker.kt on Android.
struct TiltTracker {
    var fullScale: Float = 0.5
    var recentreSeconds: Float = 2.5
    var forgetSeconds: Float = 10
    // Per device axis, roll about y and then pitch about x: how far the phone has turned in radians,
    // and how much of that turn recentring has already taken back since the phone left its old pose.
    private var turned = SIMD2<Float>(repeating: 0)
    private var recentred = SIMD2<Float>(repeating: 0)
    private(set) var tilt = SIMD2<Float>(repeating: 0)

    /// `quarterTurns` counts counter-clockwise quarter turns of the device from portrait.
    mutating func update(rateX: Float, rateY: Float, dt: Float, quarterTurns: Int) {
        guard dt > 0, dt <= 0.25 else { return }
        let recentre = 1 - exp(-dt / recentreSeconds)
        let forget = exp(-dt / forgetSeconds)
        turn(0, by: rateY * dt, recentre: recentre, forget: forget)
        turn(1, by: -rateX * dt, recentre: recentre, forget: forget)
        // The tilt eases into its full range instead of stopping at it, the same way in every direction.
        let reach = turned / fullScale
        let length = (reach * reach).sum().squareRoot()
        let device = length > 1e-6 ? reach * (tanh(length) / length) : reach
        switch quarterTurns & 3 {
        case 1: tilt = SIMD2(-device.y, device.x)
        case 2: tilt = -device
        case 3: tilt = SIMD2(device.y, -device.x)
        default: tilt = device
        }
    }

    private mutating func turn(_ axis: Int, by delta: Float, recentre: Float, forget: Float) {
        var tilt = turned[axis]
        var taken = recentred[axis]
        let away = tilt + taken
        if delta * away < 0 {
            // Turning back towards the old pose gives the recentring back in proportion, so a turn there and back
            // brings the light home instead of swinging it past neutral to the other side.
            let back = abs(delta) > abs(away) ? -away : delta
            let share = min(1, max(0, taken / away))
            tilt += back * (1 - share) + (delta - back)
            taken += back * share
        } else {
            tilt += delta
        }
        let settled = tilt * recentre
        turned[axis] = tilt - settled
        // A pose held long enough becomes the new one, and turning away from it counts in full again.
        recentred[axis] = (taken + settled) * forget
    }
}

/// Eases the tilt that a frame draws towards the sensor's on a critically damped spring, stepped on the frame clock.
/// It keeps hand tremor and the beat between the sensor's rate and the display's out of the light, at about 80 ms of lag.
/// Mirrors TiltSpring in TiltTracker.kt on Android.
struct TiltSpring {
    var rate: Float = 24
    private(set) var tilt = SIMD2<Float>(repeating: 0)
    private var velocity = SIMD2<Float>(repeating: 0)

    mutating func step(toward target: SIMD2<Float>, dt: Float) {
        guard dt > 0 else { return }
        let decay = exp(-rate * dt)
        let drift = velocity + (tilt - target) * rate
        tilt = target + decay * (tilt - target + drift * dt)
        velocity = decay * (velocity - drift * rate * dt)
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

/// Turns the tunnel's live traffic into what the membrane shows while connected: how busy the passage is, how far its
/// packets have run, the ripples that traffic drops in at the rim, and the slow breath of an open portal.
/// Mirrors PortalFlow in PortalEffect.kt on Android.
struct PortalFlow {
    static let rippleSeconds: Float = 1.6
    /// The traffic, eased: 0 when there is none, 1 from about 2 MB/s.
    private(set) var traffic: Float = 0
    /// How far traffic has carried the packets in the passage. The shader's lanes repeat every 1.25, so it wraps at 5.
    private(set) var drift: Float = 0
    /// Rises and falls about twelve times a minute while connected, 0...1; 0.5 otherwise.
    private(set) var breath: Float = 0.5
    /// Per ripple: the unit vector to where it fell on the rim, its age in seconds, and its strength, 0 once it has died away.
    private(set) var ripples = [SIMD4<Float>](repeating: .zero, count: 3)
    private var open: Float = 0
    private var untilRipple: Float = 0
    private var nextRipple = 0
    private var seed: UInt32 = 0x2545_F491

    /// Traffic on a logarithmic scale: 0 up to 2 KB/s, 1 from 2 MB/s.
    static func level(bytesPerSecond: Double) -> Float {
        bytesPerSecond > 2_000 ? Float(min(1, log10(bytesPerSecond / 2_000) / 3)) : 0
    }

    /// The breath `seconds` after the portal opened: none while it opens, then it rises for 2 s, falls for 2.6 s and rests
    /// for 0.4 s. It starts halfway up a breath, so it never jumps.
    static func breath(secondsOpen seconds: Float) -> Float {
        guard seconds > 2 else { return 0.5 }
        let phase = ((seconds - 1) / 5).truncatingRemainder(dividingBy: 1)
        if phase < 0.4 { return smoothstep(0, 0.4, phase) }
        if phase < 0.92 { return 1 - smoothstep(0.4, 0.92, phase) }
        return 0
    }

    /// Advances by `dt` seconds. `bytesPerSecond` is the tunnel's live traffic, nil when it is unknown.
    mutating func step(dt: Float, connected: Bool, bytesPerSecond: Double?) {
        guard dt > 0 else { return }
        open = connected ? open + dt : 0
        breath = connected ? Self.breath(secondsOpen: open) : 0.5
        let target = connected ? bytesPerSecond.map(Self.level) ?? 0 : 0
        traffic += (target - traffic) * (1 - exp(-dt * 3))
        if target == 0 && traffic < 0.001 { traffic = 0 }
        // Packets run as fast as the tunnel is busy and stand still without traffic.
        drift = (drift + dt * 0.6 * traffic).truncatingRemainder(dividingBy: 5)
        for i in ripples.indices where ripples[i].w > 0 {
            ripples[i].z += dt
            if ripples[i].z >= Self.rippleSeconds { ripples[i] = .zero }
        }
        guard traffic > 0.05 else { return }
        untilRipple -= dt
        guard untilRipple <= 0 else { return }
        let angle = random() * 2 * Float.pi
        ripples[nextRipple] = SIMD4(cos(angle), sin(angle), 0, 0.5 + 0.6 * traffic)
        nextRipple = (nextRipple + 1) % ripples.count
        untilRipple = 0.75 / (0.25 + traffic) * (0.7 + 0.6 * random())
    }

    /// Drops all motion, for reduced motion: no traffic, no ripples, no breath.
    mutating func settle() {
        self = PortalFlow()
    }

    /// A number in 0..<1 from xorshift, so both platforms drop their ripples alike.
    private mutating func random() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Float(seed >> 8) / 16_777_216
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
        let reach = min(1, (tilt * tilt).sum().squareRoot())
        let lean = smoothstep(0.1, 0.8, reach)
        // The light is placed by its angle from the viewer, in the direction it lies in. Tilt turns it towards the edge
        // that came to face the viewer, so the highlights slide round the ring and cross over the top instead of jumping.
        let angle = time * 0.65
        let toward = SIMD2(cos(angle), sin(angle)) * 0.687 * (1 - 0.5 * smoothstep(0.3, 0.9, reach)) - tilt * 0.9
        let away = (toward * toward).sum().squareRoot()
        // Eases towards 72 degrees from the viewer, so it never sinks to the ring's plane.
        let polar = 1.25 * tanh(away / 1.25)
        let spread = away > 1e-6 ? sin(polar) / away : 0
        return SIMD4(toward.x * spread, toward.y * spread, cos(polar), lean)
    }
}

/// Bakes the portal's fractal noise once, so the shader reads in one sample what four octaves of value noise used to cost.
/// The texture tiles with a period of `period` noise cells in both axes, `size / period` texels to a cell. Each octave
/// raises the frequency by √5 and turns by 26.6° through the integer matrix (2 1; -1 2), so every octave tiles as well.
/// Mirrors PortalNoise in PortalEffect.kt on Android, byte for byte.
enum PortalNoise {
    static let size = 512
    static let period = 16

    /// One byte per texel, row by row from the top: 255 × fbm at the texel's centre, so 0...239.
    static func bake() -> [UInt8] {
        // A value per lattice corner from an integer hash, so both platforms bake the same bytes.
        let corners = (0..<period * period).map { index -> Float in
            var n = UInt32(index) &* 0x9E37_79B1
            n ^= n >> 15
            n = n &* 0x85EB_CA77
            n ^= n >> 13
            return Float(n & 0xFF) / 255
        }
        func corner(_ x: Int, _ y: Int) -> Float {
            corners[(y % period + period) % period * period + (x % period + period) % period]
        }
        func noise(_ x: Float, _ y: Float) -> Float {
            let cellX = x.rounded(.down), cellY = y.rounded(.down)
            var fx = x - cellX, fy = y - cellY
            fx = fx * fx * (3 - 2 * fx)
            fy = fy * fy * (3 - 2 * fy)
            let i = Int(cellX), j = Int(cellY)
            let top = corner(i, j) + (corner(i + 1, j) - corner(i, j)) * fx
            let bottom = corner(i, j + 1) + (corner(i + 1, j + 1) - corner(i, j + 1)) * fx
            return top + (bottom - top) * fy
        }
        let texelsPerCell = Float(size / period)
        var bytes = [UInt8](repeating: 0, count: size * size)
        for row in 0..<size {
            for column in 0..<size {
                var x = (Float(column) + 0.5) / texelsPerCell
                var y = (Float(row) + 0.5) / texelsPerCell
                var sum: Float = 0
                var amplitude: Float = 0.5
                for _ in 0..<4 {
                    sum += amplitude * noise(x, y)
                    (x, y) = (2 * x + y + 3.1, 2 * y - x + 3.1)
                    amplitude *= 0.5
                }
                bytes[row * size + column] = UInt8((sum * 255).rounded())
            }
        }
        return bytes
    }
}
