import AVFoundation
import SwiftUI
import UIKit
import AgentringCore

/// Pairing: scan the relay's QR code or paste its code.
struct PairView: View {
    let model: AppModel
    @State private var code = ""
    @State private var pairing = false
    @State private var error: String?
    @State private var scanning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Pair your phone").font(.largeTitle.bold())
                Text("Your phone talks to your agent through a small server called a relay.")
                    .foregroundStyle(.secondary)
                Card {
                    Text("agentring cloud").font(.headline)
                    StepRow(number: 1, title: "Sign in on agentring.io",
                            detail: "On your computer, open the website and sign in with your email. No password.")
                    StepRow(number: 2, title: "Show the pairing QR",
                            detail: "In your dashboard, under Pair a phone, press Show pairing QR.")
                }
                Card {
                    Text("My own server").font(.headline)
                    StepRow(number: 1, title: "Start your relay",
                            detail: "In the agentring folder (see the README on GitHub):",
                            code: "docker compose up -d")
                    StepRow(number: 2, title: "Create a pairing code",
                            detail: "It prints a QR code in the terminal:",
                            code: "agentring pair")
                }
                Button {
                    scanning = true
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(pairing)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Can't scan? Paste the code").font(.subheadline.weight(.semibold))
                    TextField("Pairing code", text: $code, axis: .vertical)
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                        .padding(10)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        pair(code)
                    } label: {
                        if pairing {
                            ProgressView()
                        } else {
                            Text("Pair")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pairing || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(StatusColors.bad)
                }
                Text("You can switch later by pairing again.").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .sheet(isPresented: $scanning) {
            ScannerSheet { scanned in
                scanning = false
                code = scanned
                pair(scanned)
            }
        }
    }

    private func pair(_ raw: String) {
        guard !pairing else { return }
        pairing = true
        error = nil
        Task {
            do {
                try await model.pair(code: raw)
            } catch {
                self.error = Strings.describe(error)
            }
            pairing = false
        }
    }
}

/// The camera, full screen, with a cancel button.
private struct ScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let failure {
                    ContentUnavailableView("Could not scan", systemImage: "camera", description: Text(failure))
                        .foregroundStyle(.white)
                } else {
                    QRScannerView(onCode: onCode, onFailure: { failure = $0 })
                        .ignoresSafeArea()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// QR scanner on AVFoundation (`AVCaptureMetadataOutput`).
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        vc.onFailure = onFailure
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private let sessionQueue = DispatchQueue(label: "dev.agentring.qr-session")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setUp()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                onMain { [weak self] in
                    if granted { self?.setUp() } else { self?.fail("Camera access was denied. Allow it in Settings, or paste the code.") }
                }
            }
        default:
            fail("Camera access was denied. Allow it in Settings, or paste the code.")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    private func setUp() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            fail("No camera available. Paste the code instead.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            fail("The camera can't read QR codes. Paste the code instead.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        let session = self.session
        sessionQueue.async { session.startRunning() }
    }

    private func fail(_ message: String) {
        onFailure?(message)
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let value = metadataObjects
            .compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            .first
        guard let value else { return }
        // Delegate queue is .main.
        MainActor.assumeIsolated {
            guard !self.delivered else { return }
            self.delivered = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            self.onCode?(value)
        }
    }
}
