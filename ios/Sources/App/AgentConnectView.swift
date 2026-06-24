import AVFoundation
import SwiftUI
import UIKit

/// Drives the "connect your computer" flow shown inside a Claude/Codex chat while
/// no paired computer is online. The desktop daemon shows a QR; the phone scans it
/// and authorizes the pairing, then waits for the computer to come online.
@MainActor
final class AgentConnectModel: ObservableObject {
  /// `"claude"` / `"codex"`.
  let provider: String
  /// Display name shown in copy ("Claude" / "Codex").
  let displayName: String

  @Published var status: AgentBridgeStatus = .disconnected
  @Published var isScanning = false
  @Published var isAuthorizing = false
  @Published var didAuthorize = false
  @Published var errorMessage: String?

  /// Invoked once a computer comes online so the host can reveal the input bar.
  var onConnected: (() -> Void)?

  private var pollTask: Task<Void, Never>?

  init(provider: String, displayName: String) {
    self.provider = provider
    self.displayName = displayName
  }

  func onAppear() {
    startPolling()
  }

  func onDisappear() {
    stopPolling()
  }

  /// Polls bridge status every couple of seconds while the panel is on screen so
  /// it flips to "connected" the moment the daemon claims its token and joins.
  func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshStatusOnce()
        if Task.isCancelled { return }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
      }
    }
  }

  func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  func refreshStatusOnce() async {
    guard let config = AppSessionConfig.current else { return }
    do {
      let next = try await AgentPairingService.status(config: config)
      status = next
      if next.connected {
        stopPolling()
        onConnected?()
      }
    } catch {
      // Transient — keep the last known status and let the next tick retry.
    }
  }

  func beginScan() {
    errorMessage = nil
    isScanning = true
  }

  func cancelScan() {
    isScanning = false
  }

  /// A QR was scanned. Parse the pairing request and authorize it against this
  /// (authenticated) account, binding the computer to the user.
  func handleScanned(_ payload: String) {
    isScanning = false
    guard let requestId = AgentPairingService.requestId(fromScanned: payload) else {
      errorMessage =
        "That isn't a Vibe pairing code. On your computer run the bridge and scan the QR it shows."
      return
    }
    guard let config = AppSessionConfig.current else {
      errorMessage = AgentPairingError.noSession.localizedDescription
      return
    }
    isAuthorizing = true
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      defer { self.isAuthorizing = false }
      do {
        try await AgentPairingService.authorize(config: config, requestId: requestId)
        self.didAuthorize = true
        self.startPolling()
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }
}

/// Bottom panel rendered in place of the composer for an unconnected agent chat.
struct AgentConnectPanel: View {
  @ObservedObject var model: AgentConnectModel
  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    VStack(spacing: 14) {
      HStack(spacing: 12) {
        ZStack {
          Circle().fill(palette.accent.opacity(0.16))
          Image(systemName: "laptopcomputer.and.iphone")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(palette.accent)
        }
        .frame(width: 44, height: 44)

        VStack(alignment: .leading, spacing: 3) {
          Text("Connect your computer")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(palette.text)
          Text(
            "\(model.displayName) runs on your own computer with your own subscription. Pair it once to start chatting here."
          )
          .font(.system(size: 13))
          .foregroundStyle(palette.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 8) {
        Image(systemName: "lock.shield")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.secondaryText)
        Text("Pairing is end-to-end and revocable. Only you can connect a computer.")
          .font(.system(size: 11.5))
          .foregroundStyle(palette.secondaryText)
        Spacer(minLength: 0)
      }

      if model.didAuthorize {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Auth is done — waiting for your computer…")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.text)
          Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(AgentConnectGlassBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      } else {
        Button(action: { model.beginScan() }) {
          HStack(spacing: 8) {
            if model.isAuthorizing {
              ProgressView().tint(.white)
            } else {
              Image(systemName: "qrcode.viewfinder")
            }
            Text(model.isAuthorizing ? "Connecting…" : "Scan to connect")
              .font(.system(size: 16, weight: .semibold))
          }
          .frame(maxWidth: .infinity)
          .frame(height: 48)
          .foregroundStyle(.white)
          .background(palette.accent)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(model.isAuthorizing)

        Text(
          "On your computer run the bridge — it shows a QR. Scan it here to connect."
        )
        .font(.system(size: 11.5))
        .foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.system(size: 12))
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
    .background(AgentConnectGlassBackground())
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(palette.secondaryText.opacity(0.12), lineWidth: 1)
    )
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    .onAppear { model.onAppear() }
    .onDisappear { model.onDisappear() }
    .fullScreenCover(isPresented: $model.isScanning) {
      AgentQRScannerView(
        instruction: "Scan the QR shown on your computer",
        onResult: { model.handleScanned($0) },
        onCancel: { model.cancelScan() }
      )
      .ignoresSafeArea()
    }
  }
}

// MARK: - Camera QR scanner

/// SwiftUI wrapper over an AVFoundation QR scanner used to pair a computer.
struct AgentQRScannerView: UIViewControllerRepresentable {
  let instruction: String
  let onResult: (String) -> Void
  let onCancel: () -> Void

  func makeUIViewController(context: Context) -> AgentQRScannerController {
    let controller = AgentQRScannerController()
    controller.instruction = instruction
    controller.onResult = onResult
    controller.onCancel = onCancel
    return controller
  }

  func updateUIViewController(_ controller: AgentQRScannerController, context: Context) {}
}

final class AgentQRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var instruction: String = "Scan the QR"
  var onResult: ((String) -> Void)?
  var onCancel: (() -> Void)?

  private let session = AVCaptureSession()
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var metadataOutput: AVCaptureMetadataOutput?
  private let sessionQueue = DispatchQueue(label: "vibe.agent.qr.scanner")
  private var hasEmitted = false
  private let messageLabel = UILabel()
  
  private let overlayEffectView = UIVisualEffectView()
  private let overlayMaskLayer = CAShapeLayer()
  private let targetBoxLayer = CAShapeLayer()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      overlayEffectView.effect = glass
    } else {
      overlayEffectView.effect = UIBlurEffect(style: .systemThinMaterialDark)
    }
    view.addSubview(overlayEffectView)
    
    targetBoxLayer.strokeColor = UIColor.white.withAlphaComponent(0.6).cgColor
    targetBoxLayer.fillColor = UIColor.clear.cgColor
    targetBoxLayer.lineWidth = 2
    view.layer.addSublayer(targetBoxLayer)
    
    configureChrome()
    requestCameraAndConfigure()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    startRunning()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stopRunning()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
    overlayEffectView.frame = view.bounds
    
    let boxSize: CGFloat = 260
    let boxRect = CGRect(
      x: (view.bounds.width - boxSize) / 2,
      y: (view.bounds.height - boxSize) / 2,
      width: boxSize,
      height: boxSize
    )
    
    let path = UIBezierPath(rect: view.bounds)
    let innerPath = UIBezierPath(roundedRect: boxRect, cornerRadius: 24)
    path.append(innerPath)
    path.usesEvenOddFillRule = true
    
    overlayMaskLayer.path = path.cgPath
    overlayMaskLayer.fillRule = .evenOdd
    overlayEffectView.layer.mask = overlayMaskLayer
    
    targetBoxLayer.path = innerPath.cgPath
    
    if let preview = previewLayer, let output = metadataOutput {
      output.rectOfInterest = preview.metadataOutputRectConverted(fromLayerRect: boxRect)
    }
  }

  // MARK: Camera

  private func requestCameraAndConfigure() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      configureSession()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else { return }
          if granted {
            self.configureSession()
            self.startRunning()
          } else {
            self.showMessage("Camera access is needed to scan the pairing QR.")
          }
        }
      }
    default:
      showMessage("Camera access is off. Enable it in Settings to scan the pairing QR.")
    }
  }

  private func configureSession() {
    guard
      let device = AVCaptureDevice.default(for: .video),
      let input = try? AVCaptureDeviceInput(device: device),
      session.canAddInput(input)
    else {
      showMessage("This device can't scan a QR code.")
      return
    }
    session.addInput(input)

    let output = AVCaptureMetadataOutput()
    self.metadataOutput = output
    guard session.canAddOutput(output) else {
      showMessage("This device can't scan a QR code.")
      return
    }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]

    let preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    preview.frame = view.bounds
    view.layer.insertSublayer(preview, at: 0)
    previewLayer = preview
    hideMessage()
  }

  private func startRunning() {
    sessionQueue.async { [weak self] in
      guard let self, !self.session.inputs.isEmpty, !self.session.isRunning else { return }
      self.session.startRunning()
    }
  }

  private func stopRunning() {
    sessionQueue.async { [weak self] in
      guard let self, self.session.isRunning else { return }
      self.session.stopRunning()
    }
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard
      !hasEmitted,
      let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
      object.type == .qr,
      let value = object.stringValue
    else { return }
    hasEmitted = true
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    stopRunning()
    onResult?(value)
  }

  // MARK: Chrome

  private func configureChrome() {
    let close = UIButton(type: .system)
    close.setImage(
      UIImage(systemName: "xmark.circle.fill"), for: .normal)
    close.tintColor = .white
    close.translatesAutoresizingMaskIntoConstraints = false
    close.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    view.addSubview(close)

    let title = UILabel()
    title.text = instruction
    title.textColor = .white
    title.font = .systemFont(ofSize: 16, weight: .semibold)
    title.textAlignment = .center
    title.numberOfLines = 0
    title.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(title)

    messageLabel.textColor = .white
    messageLabel.font = .systemFont(ofSize: 15, weight: .medium)
    messageLabel.textAlignment = .center
    messageLabel.numberOfLines = 0
    messageLabel.isHidden = true
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(messageLabel)

    NSLayoutConstraint.activate([
      close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      close.widthAnchor.constraint(equalToConstant: 32),
      close.heightAnchor.constraint(equalToConstant: 32),

      title.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 56),
      title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -56),

      messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
      messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
    ])
  }

  private func showMessage(_ text: String) {
    messageLabel.text = text
    messageLabel.isHidden = false
  }

  private func hideMessage() {
    messageLabel.isHidden = true
  }

  @objc private func handleClose() {
    onCancel?()
  }
}

struct AgentConnectGlassBackground: UIViewRepresentable {
  func makeUIView(context: Context) -> UIVisualEffectView {
    if #available(iOS 26.0, *) {
      return UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    } else {
      return UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    }
  }
  func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}
