import SwiftUI
import AVFoundation

/// Camera QR scanner; calls `onCode` once with the first Hermes pairing code seen.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (PairingPayload) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((PairingPayload) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.configure() : self.showDenied() }
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { showDenied(); return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer
            // startRunning bloque : hors du fil principal. AVCaptureSession est sûre entre fils.
            nonisolated(unsafe) let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        private func showDenied() {
            let label = UILabel()
            label.text = "Autorise l'accès à la caméra dans Réglages > Égide pour scanner le code."
            label.numberOfLines = 0
            label.textColor = .white
            label.textAlignment = .center
            label.frame = view.bounds.insetBy(dx: 30, dy: 0)
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(label)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            nonisolated(unsafe) let session = session
            if session.isRunning { DispatchQueue.global().async { session.stopRunning() } }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered else { return }
            for case let code as AVMetadataMachineReadableCodeObject in objects {
                if let value = code.stringValue, let payload = PairingPayload.parse(value) {
                    delivered = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCode?(payload)
                    return
                }
            }
        }
    }
}
