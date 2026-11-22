import MetalKit
import SwiftUI
#if os(iOS)
import CoreMotion
#else
import AppKit
#endif

struct PortalEffect {
    let phase: TunnelPhase
    let buttonDiameter: CGFloat
    let logoBounds: CGRect
    let active: Bool
    let pressed: Bool
    /// The tunnel's live traffic in bytes per second, nil when it is not connected or not known yet.
    let traffic: Double?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Renderer? { Renderer() }

    private func makeView(renderer: Renderer?) -> MTKView {
        #if os(iOS)
        let view = MTKView(frame: .zero, device: renderer?.device)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.contentScaleFactor = displayScale
        view.isUserInteractionEnabled = false
        #else
        let view = PortalMetalView(frame: .zero, device: renderer?.device)
        view.layer?.isOpaque = false
        #endif
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.preferredFramesPerSecond = 60
        view.delegate = renderer
        return view
    }

    private func update(_ view: MTKView, renderer: Renderer?) {
        guard let renderer else { return }
        renderer.active = active
        renderer.setMotionEnabled(active && !reduceMotion, view: view)
        renderer.buttonDiameter = buttonDiameter
        renderer.logoBounds = logoBounds
        renderer.reduceMotion = reduceMotion
        renderer.pressed = pressed
        renderer.traffic = traffic
        renderer.observe(phase: phase)
        #if os(iOS)
        view.contentScaleFactor = displayScale
        #endif
        // The view's own display link drives the animation, so SwiftUI is not re-evaluated every frame.
        // Reduced motion draws one still frame on demand instead.
        view.enableSetNeedsDisplay = reduceMotion
        view.isPaused = !active || reduceMotion
        #if os(iOS)
        if active && reduceMotion { view.setNeedsDisplay() }
        #else
        if active && reduceMotion { view.needsDisplay = true }
        #endif
    }

    private static func dismantle(_ view: MTKView, renderer: Renderer?) {
        renderer?.setMotionEnabled(false, view: view)
        view.delegate = nil
        view.releaseDrawables()
    }

    /// Matches PortalUniforms in PortalShader.metal: 256 bytes, tilt at 32, logoRect at 48, press at 68, packets at 80, light at 176,
    /// traffic at 192, ripples at 208.
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
        var traffic: Float = 0
        var drift: Float = 0
        var breath: Float = 0.5
        var ripples = (SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero)
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let logoMask: MTLTexture
        private let noise: MTLTexture
        #if os(iOS)
        private let motion = CMMotionManager()
        private var tracker = TiltTracker()
        private var tiltSpring = TiltSpring()
        private var lastMotion: TimeInterval?
        #else
        private var pointer = PointerTilt()
        private var pointerEnabled = false
        #endif
        private var portal = PortalMotion()
        private var flow = PortalFlow()
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
        var traffic: Double?

        init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
            guard let device, let queue = device.makeCommandQueue() else { return nil }
            guard let cgImage = Self.logoImage() else {
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
            // The fractal noise for PortalShader.metal, baked once; the same bytes as portal.agsl reads on Android.
            let size = PortalNoise.size
            let noiseDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
            noiseDescriptor.usage = .shaderRead
            guard let noise = device.makeTexture(descriptor: noiseDescriptor) else { return nil }
            PortalNoise.bake().withUnsafeBytes {
                noise.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size)
            }
            self.noise = noise
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

        /// The logo rasterized at 256 × 256, upright, as the mask texture expects it.
        private static func logoImage() -> CGImage? {
            let rect = CGRect(x: 0, y: 0, width: 256, height: 256)
            #if os(iOS)
            guard let logo = UIImage(named: "Portal") else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in logo.draw(in: rect) }.cgImage
            #else
            guard let logo = NSImage(named: "Portal"),
                  let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            logo.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage()
            #endif
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
            let connected = portal.observe(lit: lit, connected: phase == .connected, power: uniforms.power, busy: uniforms.busy,
                                           now: CACurrentMediaTime())
            #if os(iOS)
            if connected { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
            #else
            _ = connected
            #endif
        }

        #if os(iOS)
        func setMotionEnabled(_ enabled: Bool, view: MTKView) {
            if !enabled {
                motion.stopDeviceMotionUpdates()
                tracker = TiltTracker()
                tiltSpring = TiltSpring()
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
        #else
        /// A Mac has no gyroscope, so the pointer over the window leans the ring instead.
        func setMotionEnabled(_ enabled: Bool, view: MTKView) {
            pointerEnabled = enabled
            if !enabled {
                pointer = PointerTilt()
                uniforms.tilt = .zero
            }
        }
        #endif

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

        func draw(in view: MTKView) {
            #if os(iOS)
            guard active, UIApplication.shared.applicationState == .active,
                  view.bounds.width > 0, view.bounds.height > 0 else { return }
            // Scrolled out of view: tick slowly without drawing until the button is back.
            let visible = view.window.map { $0.bounds.intersects(view.convert(view.bounds, to: $0)) } ?? false
            #else
            guard active, view.bounds.width > 0, view.bounds.height > 0 else { return }
            // Scrolled out of view, or the window hidden behind others or minimized: tick slowly without drawing.
            let visible = view.window.map { $0.occlusionState.contains(.visible) && !view.visibleRect.isEmpty } ?? false
            #endif
            guard visible else {
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
            #if os(iOS)
            tiltSpring.step(toward: tracker.tilt, dt: dt)
            let tilt = tiltSpring.tilt
            #else
            let tilt = pointerEnabled ? pointer.update(view: view, dt: dt) : .zero
            #endif
            if reduceMotion {
                portal.settle()
                flow.settle()
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
                flow.step(dt: dt, connected: phase == .connected, bytesPerSecond: traffic)
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
            uniforms.traffic = flow.traffic
            uniforms.drift = flow.drift
            uniforms.breath = flow.breath
            uniforms.ripples = (flow.ripples[0], flow.ripples[1], flow.ripples[2])
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
            encoder.setFragmentTexture(noise, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }
    }
}

#if os(iOS)
extension PortalEffect: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView { makeView(renderer: context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) { update(view, renderer: context.coordinator) }
    static func dismantleUIView(_ view: MTKView, coordinator: Renderer?) { dismantle(view, renderer: coordinator) }
}
#else
extension PortalEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { makeView(renderer: context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) { update(view, renderer: context.coordinator) }
    static func dismantleNSView(_ view: MTKView, coordinator: Renderer?) { dismantle(view, renderer: coordinator) }
}

/// Lets clicks through to the button drawn over the portal.
private final class PortalMetalView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Turns the pointer's place over the window into the tilt that a phone gets from its gyroscope: the light leans
/// towards the pointer and drifts back to neutral when the pointer leaves the window or another app comes to the front.
private struct PointerTilt {
    var reach: Float = 0.55
    private var tilt = SIMD2<Float>(repeating: 0)

    mutating func update(view: NSView, dt: Float) -> SIMD2<Float> {
        var target = SIMD2<Float>(repeating: 0)
        if NSApp.isActive, let window = view.window, let content = window.contentView {
            let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if content.bounds.contains(point) {
                // Measured from the portal's centre in y-up points, against half the window's shorter side.
                let centre = content.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
                let half = Float(max(1, min(content.bounds.width, content.bounds.height) / 2))
                let offset = SIMD2(Float(point.x - centre.x), Float(content.isFlipped ? centre.y - point.y : point.y - centre.y)) / half
                // PortalLight leans away from the tilt, so the tilt points away from the pointer.
                target = -SIMD2(tanh(offset.x), tanh(offset.y)) * reach
            }
        }
        tilt += (target - tilt) * (1 - exp(-dt * 5))
        return tilt
    }
}
#endif
