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
  @Published var didSyncRuntimeKey = false
  @Published var errorMessage: String?
  @Published var selectedRepository: AgentBridgeRepository?

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
      selectedRepository = AgentBridgeSelectionStore.ensureValidSelection(from: next.repositories)
      if next.connected {
        stopPolling()
        onConnected?()
      }
    } catch {
      // A 401 here means the whole session token died, not just the bridge — kick
      // off a silent session refresh so the panel stops spinning on a dead token.
      if let pairingError = error as? AgentPairingError, case .http(401, _) = pairingError {
        Task { await AppSessionGuard.shared.recover(reason: "agent-connect-status") }
      }
      // Otherwise transient — keep the last known status and let the next tick retry.
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
    // A dedicated key-sync QR (`vibegram-rk:…`) only hands over the E2E runtime
    // key for an already-paired computer — store it, no authorize needed.
    let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("vibegram-rk:"),
      let key = AgentRuntimeCrypto.runtimeKey(fromScanned: payload)
    {
      if AgentRuntimeCrypto.storeKey(key) {
        errorMessage = nil
        didSyncRuntimeKey = true
      } else {
        errorMessage = "That key QR couldn't be read. Re-run the bridge with --show-key."
      }
      return
    }
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
    UIGlassWrapper(cornerRadius: 20) {
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
        UIGlassWrapper(cornerRadius: 12) {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Auth is done — waiting for your computer…")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(palette.text)
            Spacer(minLength: 0)
          }
          .padding(12)
          .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(
          "On your computer run the bridge — it shows a QR. Scan it here to connect."
        )
        .font(.system(size: 11.5))
        .foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)

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
      }

      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.system(size: 12))
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if model.didSyncRuntimeKey {
        Text("Encryption key synced — agent file-changes will now show on this phone.")
          .font(.system(size: 12))
          .foregroundStyle(.green)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      // Repo selection is intentionally NOT shown here. The connect panel is only
      // about pairing a computer; once connected it's replaced by the composer,
      // whose repo-picker control is the place to choose a repository.
      }
      .padding(16)
    }
    .fixedSize(horizontal: false, vertical: true)
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

struct AgentBridgeRepositoryPickerView: View {
  let provider: String
  let displayName: String
  /// Chat the picker was opened from — used to read this chat's session history so
  /// the user can choose to continue a past session instead of starting a new task.
  var chatId: String = ""

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var status: AgentBridgeStatus = .disconnected
  @State private var selected: AgentBridgeRepository? = AgentBridgeSelectionStore.selectedRepository()
  @State private var workMode: AgentBridgeWorkMode = AgentBridgeSelectionStore.selectedWorkMode()
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var sessions: [AgentBridgeHistorySession] = []
  @State private var historyRequestId: String?
  @State private var resumeSelectionId: String?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    NavigationView {
      Group {
        if status.repositories.isEmpty && isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if status.repositories.isEmpty {
          VStack(spacing: 14) {
            Image(systemName: status.connected ? "folder.badge.questionmark" : "laptopcomputer.slash")
              .font(.system(size: 36, weight: .semibold))
              .foregroundStyle(palette.secondaryText)
            Text(status.connected ? "No repositories shared" : "Computer offline")
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(palette.text)
            if let errorMessage {
              Text(errorMessage)
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List {
            Section {
              // Default: start a fresh task for the next message.
              resumeRow(
                title: "Start a new task",
                subtitle: "Each message runs on its own — no shared session",
                icon: "plus.circle",
                isSelected: resumeSelectionId == nil
              ) {
                resumeSelectionId = nil
                AgentBridgeSelectionStore.clearResumeSession(provider: provider)
              }
              ForEach(sessions) { session in
                resumeRow(
                  title: session.topic.isEmpty ? "Session" : session.topic,
                  subtitle: session.projectName.isEmpty
                    ? "\(session.messageCount) messages"
                    : "\(session.projectName) · \(session.messageCount) messages",
                  icon: "arrow.uturn.left.circle",
                  isSelected: resumeSelectionId == session.id
                ) {
                  resumeSelectionId = session.id
                  AgentBridgeSelectionStore.setResumeSession(
                    provider: provider,
                    id: session.id,
                    topic: session.topic
                  )
                }
              }
            } header: {
              Text("Continue a session")
            } footer: {
              Text(sessions.isEmpty
                ? "Past \(displayName) sessions on your computer will appear here."
                : "Pick a session to resume it; otherwise each message starts a new task.")
            }
            .listRowBackground(palette.card)

            Section {
              ForEach(AgentBridgeWorkMode.allCases) { mode in
                Button {
                  workMode = mode
                  AgentBridgeSelectionStore.setWorkMode(mode)
                } label: {
                  HStack(spacing: 12) {
                    Image(systemName: mode.icon)
                      .font(.system(size: 17, weight: .medium))
                      .foregroundStyle(palette.accent)
                      .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                      Text(mode.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text)
                      Text(mode.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if workMode == mode {
                      Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    }
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
              }
            } header: {
              Text("Permission")
            }
            .listRowBackground(palette.card)

            Section {
              ForEach(status.repositories) { repo in
                Button {
                  AgentBridgeSelectionStore.select(repo)
                  selected = repo
                  dismiss()
                } label: {
                  HStack(spacing: 12) {
                    Image(systemName: repo.isGitRepository ? "shippingbox" : "folder")
                      .font(.system(size: 18, weight: .medium))
                      .foregroundStyle(palette.accent)
                      .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                      Text(repo.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                      Text(repo.path)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if selected?.id == repo.id || selected?.cwd == repo.cwd {
                      Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    }
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
              }
            }
            .listRowBackground(palette.card)
          }
          .listStyle(.insetGrouped)
          .scrollContentBackground(.hidden)
          .background(palette.background)
        }
      }
      .background(palette.background.ignoresSafeArea())
      .navigationTitle("\(displayName) repo")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task { await refresh() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(isLoading)
        }
      }
      .task {
        resumeSelectionId = AgentBridgeSelectionStore.selectedResumeSession(provider: provider)?.id
        applyCachedHistory()
        loadHistory()
        await refresh()
      }
      .onReceive(NotificationCenter.default.publisher(for: ChatEngine.didChangeNotification)) { note in
        guard (note.userInfo?["reason"] as? String) == "agentBridgeHistory" else { return }
        if let pending = historyRequestId,
          let rid = note.userInfo?["requestId"] as? String,
          rid != pending {
          return
        }
        applyCachedHistory()
      }
    }
  }

  @ViewBuilder
  private func resumeRow(
    title: String,
    subtitle: String,
    icon: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(palette.accent)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.text)
            .lineLimit(1)
          Text(subtitle)
            .font(.system(size: 12))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(palette.accent)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Ask the connected computer for this chat's session list (the reply lands via the
  /// `agentBridgeHistory` change notification, then `applyCachedHistory` reads it).
  private func loadHistory() {
    guard !chatId.isEmpty else { return }
    let result = ChatEngine.shared.requestAgentBridgeHistory([
      "chatId": chatId,
      "provider": provider,
      "mode": "list",
    ])
    if (result["accepted"] as? Bool) == true {
      historyRequestId = result["requestId"] as? String
    }
  }

  private func applyCachedHistory() {
    guard
      !chatId.isEmpty,
      let payload = ChatEngine.shared.latestAgentBridgeHistory(chatId: chatId),
      (payload["mode"] as? String ?? "list") == "list"
    else { return }
    let raw = payload["sessions"] as? [[String: Any]] ?? []
    sessions = raw.compactMap { item in
      guard let id = item["id"] as? String, !id.isEmpty else { return nil }
      return AgentBridgeHistorySession(
        id: id,
        topic: (item["topic"] as? String) ?? "Untitled",
        projectName: (item["projectName"] as? String) ?? "",
        projectPath: (item["project"] as? String) ?? (item["projectPath"] as? String) ?? (item["cwd"] as? String) ?? "",
        updatedAt: (item["updatedAt"] as? String) ?? "",
        messageCount: (item["messageCount"] as? NSNumber)?.intValue
          ?? (item["messageCount"] as? Int) ?? 0,
        isRunning: false,
        taskId: nil,
        sessionId: id
      )
    }
  }

  @MainActor
  private func refresh() async {
    guard let config = AppSessionConfig.current else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      let next = try await AgentPairingService.status(config: config)
      status = next
      selected = AgentBridgeSelectionStore.ensureValidSelection(from: next.repositories)
    } catch {
      errorMessage = error.localizedDescription
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
      let glass = UIGlassEffect()
      glass.isInteractive = true
      overlayEffectView.effect = glass
    } else {
      overlayEffectView.effect = UIBlurEffect(style: .systemMaterialDark)
    }
    
    let maskView = UIView()
    overlayMaskLayer.fillColor = UIColor.black.cgColor
    maskView.layer.addSublayer(overlayMaskLayer)
    overlayEffectView.mask = maskView
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
    overlayEffectView.mask?.frame = view.bounds
    
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

struct UIGlassWrapper<Content: View>: UIViewRepresentable {
  var cornerRadius: CGFloat
  var strokeColor: Color = .clear
  let content: Content

  init(cornerRadius: CGFloat, strokeColor: Color = .clear, @ViewBuilder content: () -> Content) {
    self.cornerRadius = cornerRadius
    self.strokeColor = strokeColor
    self.content = content()
  }

  func makeUIView(context: Context) -> GlassContainerView<Content> {
    let blurView = UIVisualEffectView()
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = true
      blurView.effect = effect
    } else {
      blurView.effect = UIBlurEffect(style: .systemMaterial)
    }
    blurView.layer.cornerCurve = .continuous
    blurView.layer.cornerRadius = cornerRadius
    if strokeColor != .clear {
      blurView.layer.borderColor = UIColor(strokeColor).cgColor
      blurView.layer.borderWidth = 1.0
    }
    blurView.clipsToBounds = true

    let hostingController = UIHostingController(rootView: content)
    hostingController.view.backgroundColor = .clear
    
    blurView.contentView.addSubview(hostingController.view)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),
      hostingController.view.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor)
    ])
    
    return GlassContainerView(blurView: blurView, hostingController: hostingController)
  }

  func updateUIView(_ uiView: GlassContainerView<Content>, context: Context) {
    uiView.hostingController.rootView = content
    uiView.hostingController.view.setNeedsUpdateConstraints()
  }
}

final class GlassContainerView<Content: View>: UIView {
  let blurView: UIVisualEffectView
  let hostingController: UIHostingController<Content>

  init(blurView: UIVisualEffectView, hostingController: UIHostingController<Content>) {
    self.blurView = blurView
    self.hostingController = hostingController
    super.init(frame: .zero)
    backgroundColor = .clear
    addSubview(blurView)
    blurView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }
  
  required init?(coder: NSCoder) { fatalError() }
  
  override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
    return hostingController.view.systemLayoutSizeFitting(targetSize)
  }
  
  override var intrinsicContentSize: CGSize {
    let size = hostingController.view.intrinsicContentSize
    return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
  }
}
