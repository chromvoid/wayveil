import AVFoundation
import SwiftUI
import UIKit

struct QRScanner: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var allowed = false
    @State private var error: String?
    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            if allowed { CameraView(onCode: onCode, onError: { error = L("camera_unavailable") }).ignoresSafeArea() }
            VStack {
                HStack { Spacer(); Button(L("close")) { dismiss() }.padding().background(.ultraThinMaterial, in: Capsule()) }
                Spacer()
                if allowed { RoundedRectangle(cornerRadius: 24).stroke(Brand.mint, lineWidth: 2).frame(width: 230, height: 230).accessibilityHidden(true) }
                if let error { Text(error).multilineTextAlignment(.center).padding(24) }
                Spacer()
                Text(L("scan_prompt")).font(.headline).padding(20).background(.ultraThinMaterial, in: Capsule())
            }.padding(24)
        }
        .preferredColorScheme(.dark).tint(Brand.mint)
        .task {
            #if targetEnvironment(simulator)
            error = L("camera_unavailable")
            #else
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video); if !allowed { error = L("camera_denied") }
            default: error = L("camera_denied")
            }
            #endif
        }
    }
}

private struct CameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: () -> Void
    func makeUIViewController(context: Context) -> CameraController { CameraController(onCode: onCode, onError: onError) }
    func updateUIViewController(_ controller: CameraController, context: Context) { }
    static func dismantleUIViewController(_ controller: CameraController, coordinator: ()) { controller.stop() }
}

private final class CameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.chromvoid.vpn.camera")
    private var preview: AVCaptureVideoPreviewLayer!
    private var handled = false
    private let onCode: (String) -> Void
    private let onError: () -> Void
    init(onCode: @escaping (String) -> Void, onError: @escaping () -> Void) { self.onCode = onCode; self.onError = onError; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Storyboard initialization is not supported.") }
    override func viewDidLoad() {
        super.viewDidLoad()
        preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        queue.async { [self] in
            do {
                guard let device = AVCaptureDevice.default(for: .video) else { throw NSError(domain: "Camera", code: 1) }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureMetadataOutput()
                guard session.canAddInput(input), session.canAddOutput(output) else { throw NSError(domain: "Camera", code: 1) }
                session.addInput(input); session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
                session.startRunning()
            } catch { DispatchQueue.main.async { self.onError() } }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview.frame = view.bounds
        if let orientation = view.window?.windowScene?.interfaceOrientation {
            switch orientation {
            case .landscapeLeft: preview.connection?.videoOrientation = .landscapeLeft
            case .landscapeRight: preview.connection?.videoOrientation = .landscapeRight
            case .portraitUpsideDown: preview.connection?.videoOrientation = .portraitUpsideDown
            default: preview.connection?.videoOrientation = .portrait
            }
        }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !handled, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        handled = true; stop(); onCode(value)
    }
    func stop() { let session = session; queue.async { if session.isRunning { session.stopRunning() } } }
}
