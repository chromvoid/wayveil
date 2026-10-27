import MetalKit
import CoreMotion
import SwiftUI

struct PortalEffect: UIViewRepresentable {
    let time: Float
    let power: Float
    let busy: Float
    let age: Float
    let phase: TunnelPhase
    let buttonDiameter: CGFloat
    let logoBounds: CGRect
    let active: Bool
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
        view.enableSetNeedsDisplay = true
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
        renderer.uniforms.time = time
        renderer.uniforms.power = power
        renderer.uniforms.busy = busy
        renderer.uniforms.age = age
        renderer.uniforms.phase = phase == .connected ? 2 : phase == .stopping ? 3 : phase == .connecting || phase == .reconnecting ? 1 : 0
        view.contentScaleFactor = displayScale
        if active { view.setNeedsDisplay() }
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Renderer?) {
        coordinator?.setMotionEnabled(false, view: view)
        view.delegate = nil
        view.releaseDrawables()
    }

    struct Uniforms {
        var resolution = SIMD2<Float>(repeating: 0)
        var scale: Float = 1
        var time: Float = 0
        var power: Float = 0
        var busy: Float = 0
        var age: Float = 10
        var phase: Float = 0
        var tilt = SIMD2<Float>(repeating: 0)
        var logoRect = SIMD4<Float>(repeating: 0)
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let logoMask: MTLTexture
        private let motion = CMMotionManager()
        private var reference: CMAttitude?
        private var orientation: UIInterfaceOrientation = .unknown
        var uniforms = Uniforms()
        var buttonDiameter: CGFloat = 164
        var logoBounds = CGRect.zero
        var active = false

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

        func setMotionEnabled(_ enabled: Bool, view: MTKView) {
            if !enabled {
                motion.stopDeviceMotionUpdates()
                reference = nil
                uniforms.tilt = .zero
                return
            }
            guard !motion.isDeviceMotionActive, motion.isDeviceMotionAvailable else { return }
            motion.deviceMotionUpdateInterval = 1 / 60
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self, weak view] data, _ in
                guard let self, let view, self.active, self.motion.isDeviceMotionActive, let data,
                      let attitude = data.attitude.copy() as? CMAttitude else { return }
                let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
                if self.reference == nil || self.orientation != orientation {
                    self.reference = data.attitude.copy() as? CMAttitude
                    self.orientation = orientation
                }
                guard let reference = self.reference else { return }
                attitude.multiply(byInverseOf: reference)
                let matrix = attitude.rotationMatrix
                let base: SIMD2<Double>
                switch orientation {
                case .landscapeLeft: base = SIMD2(-0.55, -0.35)
                case .landscapeRight: base = SIMD2(0.55, 0.35)
                case .portraitUpsideDown: base = SIMD2(0.35, -0.55)
                default: base = SIMD2(-0.35, 0.55)
                }
                let x = Float(matrix.m11 * base.x + matrix.m12 * base.y + matrix.m13 * 0.9)
                let y = Float(matrix.m21 * base.x + matrix.m22 * base.y + matrix.m23 * 0.9)
                let screen: SIMD2<Float>
                switch orientation {
                case .landscapeLeft: screen = SIMD2(y, -x)
                case .landscapeRight: screen = SIMD2(-y, x)
                case .portraitUpsideDown: screen = SIMD2(-x, -y)
                default: screen = SIMD2(x, y)
                }
                let target = (screen - SIMD2(-0.35, 0.55)) * 1.6
                let bounded = SIMD2(min(1, max(-1, target.x)), min(1, max(-1, target.y)))
                let next = self.uniforms.tilt + (bounded - self.uniforms.tilt) * 0.0835
                if abs(next.x - self.uniforms.tilt.x) > 0.001 || abs(next.y - self.uniforms.tilt.y) > 0.001 {
                    self.uniforms.tilt = next
                }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

        func draw(in view: MTKView) {
            guard active, UIApplication.shared.applicationState == .active,
                  view.bounds.width > 0, view.bounds.height > 0,
                  let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            uniforms.resolution = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
            uniforms.scale = Float(min(view.bounds.width, view.bounds.height) * 0.43 / buttonDiameter)
            let scaleX = Float(view.drawableSize.width / view.bounds.width)
            let scaleY = Float(view.drawableSize.height / view.bounds.height)
            uniforms.logoRect = SIMD4(Float(logoBounds.minX) * scaleX, Float(logoBounds.minY) * scaleY,
                                     Float(logoBounds.width) * scaleX, Float(logoBounds.height) * scaleY)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(logoMask, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }
    }
}
