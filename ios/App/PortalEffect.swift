import MetalKit
import CoreMotion
import SwiftUI

struct PortalEffect: UIViewRepresentable {
    let phase: TunnelPhase
    let buttonDiameter: CGFloat
    let logoBounds: CGRect
    let active: Bool
    let pressed: Bool
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Renderer? { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator?.device)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.preferredFramesPerSecond = 60
        view.contentScaleFactor = displayScale
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator else { return }
        renderer.active = active
        renderer.setMotionEnabled(active && !reduceMotion, view: view)
        renderer.buttonDiameter = buttonDiameter
        renderer.logoBounds = logoBounds
        renderer.reduceMotion = reduceMotion
        renderer.pressed = pressed
        renderer.observe(phase: phase)
        view.contentScaleFactor = displayScale
        // The view's own display link drives the animation, so SwiftUI is not re-evaluated every frame.
        // Reduced motion draws one still frame on demand instead.
        view.enableSetNeedsDisplay = reduceMotion
        view.isPaused = !active || reduceMotion
        if active && reduceMotion { view.setNeedsDisplay() }
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Renderer?) {
        coordinator?.setMotionEnabled(false, view: view)
        view.delegate = nil
        view.releaseDrawables()
    }

    /// Matches PortalUniforms in PortalShader.metal: 192 bytes, tilt at 32, logoRect at 48, press at 68, packets at 80, light at 176.
    struct Uniforms {
        var resolution = SIMD2<Float>(repeating: 0)
        var scale: Float = 1
        var time: Float = 0
        var power: Float = 0
        var busy: Float = 0
        var close: Float = 1
        var impact: Float = 10
        var tilt = SIMD2<Float>(repeating: 0)
        var split: Float = 0
        var spin: Float = 0
        var logoRect = SIMD4<Float>(repeating: 0)
        var spinBlur: Float = 0
        var press: Float = 0
        var packets = PortalTraffic.packets(at: 0)
        var light = PortalLight.light(at: 0, tilt: .zero)
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let logoMask: MTLTexture
        private let lattice: MTLTexture
        private let motion = CMMotionManager()
        private var tracker = TiltTracker()
        private var lastMotion: TimeInterval?
        private var portal = PortalMotion()
        private var phase: TunnelPhase = .disconnected
        private var power: Float?
        private var busy: Float = 0
        private var time: Float = 0
        private var press: Float = 0
        private var lastFrame: CFTimeInterval?
        var uniforms = Uniforms()
        var reduceMotion = false
        var buttonDiameter: CGFloat = 164
        var logoBounds = CGRect.zero
        var active = false
        var pressed = false

        init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
            guard let device, let queue = device.makeCommandQueue() else { return nil }
            guard let logo = UIImage(named: "Portal") else {
                assertionFailure("The portal logo asset is missing.")
                return nil
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let image = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { _ in
                logo.draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
            }
            guard let cgImage = image.cgImage else {
                assertionFailure("Could not rasterize the portal logo.")
                return nil
            }
            do {
                logoMask = try MTKTextureLoader(device: device).newTexture(cgImage: cgImage,
                    options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
            }
            catch {
                assertionFailure("Could not create the portal logo texture: \(error)")
                return nil
            }
            // The value-noise lattice for PortalShader.metal: one hash per texel with a period of 256 in both axes.
            // The integer hash keeps shared cell corners identical on every GPU and matches portal.agsl on Android.
            let latticeDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 256, height: 256, mipmapped: false)
            latticeDescriptor.usage = .shaderRead
            guard let lattice = device.makeTexture(descriptor: latticeDescriptor) else { return nil }
            let hashes = (0..<256 * 256).map { index -> UInt8 in
                let x = index % 256
                let n = (x * 34 + 1) * x % 256 + index / 256
                return UInt8((n * 34 + 1) * n % 256)
            }
            hashes.withUnsafeBytes {
                lattice.replace(region: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256)
            }
            self.lattice = lattice
            guard let library = device.makeDefaultLibrary(), let vertex = library.makeFunction(name: "portalVertex"),
                  let fragment = library.makeFunction(name: "portalFragment") else {
                assertionFailure("The portal Metal library is missing.")
                return nil
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            do { pipeline = try device.makeRenderPipelineState(descriptor: descriptor) }
            catch {
                assertionFailure("Could not create the portal Metal pipeline: \(error)")
                return nil
            }
            self.device = device
            self.queue = queue
            super.init()
        }

        func observe(phase: TunnelPhase) {
            self.phase = phase
            if power == nil {
                // The first phase is shown settled rather than eased in.
                power = phase == .connected ? 1 : 0
                busy = phase == .connecting || phase == .reconnecting ? 1 : 0
                uniforms.power = power ?? 0
                uniforms.busy = busy
            }
            let lit = phase == .connected || phase == .connecting || phase == .reconnecting
            if portal.observe(lit: lit, connected: phase == .connected, power: uniforms.power, busy: uniforms.busy, now: CACurrentMediaTime()) {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
        }

        func setMotionEnabled(_ enabled: Bool, view: MTKView) {
            if !enabled {
                motion.stopDeviceMotionUpdates()
                tracker = TiltTracker()
                lastMotion = nil
                uniforms.tilt = .zero
                return
            }
            guard !motion.isDeviceMotionActive, motion.isDeviceMotionAvailable else { return }
            motion.deviceMotionUpdateInterval = 1 / 60
            motion.startDeviceMotionUpdates(to: .main) { [weak self, weak view] data, _ in
                guard let self, let view, self.active, self.motion.isDeviceMotionActive, let data else { return }
                let dt = self.lastMotion.map { Float(data.timestamp - $0) } ?? 0
                self.lastMotion = data.timestamp
                let quarterTurns: Int
                switch view.window?.windowScene?.interfaceOrientation ?? .portrait {
                case .landscapeRight: quarterTurns = 1
                case .portraitUpsideDown: quarterTurns = 2
                case .landscapeLeft: quarterTurns = 3
                default: quarterTurns = 0
                }
                // The next frame picks the tilt up, so it never asks for a redraw of its own.
                self.tracker.update(rateX: Float(data.rotationRate.x), rateY: Float(data.rotationRate.y), dt: dt, quarterTurns: quarterTurns)
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

        func draw(in view: MTKView) {
            guard active, UIApplication.shared.applicationState == .active,
                  view.bounds.width > 0, view.bounds.height > 0 else { return }
            // Scrolled out of view: tick slowly without drawing until the button is back.
            guard let window = view.window, window.bounds.intersects(view.convert(view.bounds, to: window)) else {
                if view.preferredFramesPerSecond != 4 { view.preferredFramesPerSecond = 4 }
                lastFrame = nil
                return
            }
            let now = CACurrentMediaTime()
            let dt = Float(min(0.05, max(0, now - (lastFrame ?? now))))
            lastFrame = now
            let connecting = phase == .connecting || phase == .reconnecting
            let targetPower: Float = phase == .connected ? 1 : 0
            let targetBusy: Float = connecting ? 1 : 0
            var power = self.power ?? targetPower
            let tilt = tracker.tilt
            if reduceMotion {
                portal.settle()
                power = targetPower
                busy = targetBusy
                time = 0
                press = pressed ? 1 : 0
                uniforms.close = 1
                uniforms.impact = 10
                (uniforms.power, uniforms.busy) = (power, busy)
            } else {
                let blend = 1 - exp(-dt * 7)
                power += (targetPower - power) * blend
                busy += (targetBusy - busy) * blend
                if abs(targetPower - power) < 0.001 { power = targetPower }
                if abs(targetBusy - busy) < 0.001 { busy = targetBusy }
                time += dt * (0.28 + busy * 0.72) * (phase == .reconnecting ? 0.75 : 1)
                // The ring gives quickly under the finger and springs back a little slower.
                press += ((pressed ? 1 : 0) - press) * (1 - exp(-dt * (pressed ? 30 : 12)))
                if abs((pressed ? 1 : 0) - press) < 0.001 { press = pressed ? 1 : 0 }
                uniforms.close = portal.close(at: now)
                uniforms.impact = portal.impact(at: now)
                (uniforms.power, uniforms.busy) = portal.held(power: power, busy: busy, close: uniforms.close)
                portal.step(dt: dt, connecting: connecting, close: uniforms.close,
                            speed: phase == .reconnecting ? 0.75 : 1)
            }
            self.power = power
            if view.preferredFramesPerSecond != 60 { view.preferredFramesPerSecond = 60 }
            uniforms.tilt = reduceMotion ? .zero : tilt
            uniforms.time = time
            uniforms.split = portal.split
            uniforms.spin = portal.spin
            uniforms.spinBlur = min(0.06, max(-0.06, portal.spinVelocity * 0.035))
            uniforms.press = press
            uniforms.packets = PortalTraffic.packets(at: time)
            uniforms.light = PortalLight.light(at: time, tilt: uniforms.tilt)
            uniforms.resolution = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
            uniforms.scale = Float(min(view.bounds.width, view.bounds.height) * 0.43 / buttonDiameter)
            let scaleX = Float(view.drawableSize.width / view.bounds.width)
            let scaleY = Float(view.drawableSize.height / view.bounds.height)
            uniforms.logoRect = SIMD4(Float(logoBounds.minX) * scaleX, Float(logoBounds.minY) * scaleY,
                                     Float(logoBounds.width) * scaleX, Float(logoBounds.height) * scaleY)
            guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(logoMask, index: 0)
            encoder.setFragmentTexture(lattice, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }
    }
}
