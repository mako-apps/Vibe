import AVFoundation
import ExpoModulesCore
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

private enum NativeStoryCameraMode: String {
  case picture
  case video
}

private final class NativeStoryCameraPreviewView: UIView {
  override class var layerClass: AnyClass {
    AVCaptureVideoPreviewLayer.self
  }

  var previewLayer: AVCaptureVideoPreviewLayer {
    layer as! AVCaptureVideoPreviewLayer
  }
}

private extension UIInterfaceOrientation {
  var nativeStoryCameraVideoOrientation: AVCaptureVideoOrientation {
    switch self {
    case .portraitUpsideDown:
      return .portraitUpsideDown
    case .landscapeLeft:
      return .landscapeRight
    case .landscapeRight:
      return .landscapeLeft
    default:
      return .portrait
    }
  }
}

public final class NativeStoryCameraView: ExpoView, AVCapturePhotoCaptureDelegate,
  AVCaptureFileOutputRecordingDelegate, PHPickerViewControllerDelegate
{
  public var onNativeEvent = EventDispatcher()

  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(
    label: "vibe.native.story.camera.session",
    qos: .userInitiated
  )
  private let photoOutput = AVCapturePhotoOutput()
  private let movieOutput = AVCaptureMovieFileOutput()

  private let cardContainer = UIView()
  private let previewView = NativeStoryCameraPreviewView()
  private let topBar = UIView()
  private let draftsButton = UIButton(type: .system)
  private let flashButton = UIButton(type: .system)
  private let closeButton = UIButton(type: .system)
  private let loadingOverlay = UIView()
  private let loadingBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let loadingTintView = UIView()
  private let loadingSpinner = UIActivityIndicatorView(style: .large)
  private let focusRingView = UIView()

  private let footerContainer = UIView()
  private let shutterButton = UIButton(type: .custom)
  private let shutterRingView = UIView()
  private let shutterInnerView = UIView()
  private let bottomRow = UIView()
  private let galleryButton = UIButton(type: .custom)
  private let galleryImageView = UIImageView()
  private let galleryFallbackView = UIImageView()
  private let modeContainer = UIView()
  private let pictureModeButton = UIButton(type: .system)
  private let videoModeButton = UIButton(type: .system)
  private let flipButton = UIButton(type: .system)

  private let permissionContainer = UIView()
  private let permissionTitleLabel = UILabel()
  private let permissionButton = UIButton(type: .system)

  private var currentMode: NativeStoryCameraMode = .picture
  private var currentPosition: AVCaptureDevice.Position = .back
  private var currentVideoOrientation: AVCaptureVideoOrientation = .portrait
  private var isFlashEnabled = false
  private var isRecording = false
  private var deferMountMs: Double = 0.0
  private var deferredStartWorkItem: DispatchWorkItem?
  private var hasConfiguredSession = false
  private var didRequestInitialPermissions = false
  private var shouldIgnoreNextVideoCapture = false
  private var videoInput: AVCaptureDeviceInput?
  private var audioInput: AVCaptureDeviceInput?
  private var latestThumbnailRequestId: PHImageRequestID = PHInvalidImageRequestID

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = .black
    clipsToBounds = true

    previewView.previewLayer.session = session
    previewView.previewLayer.videoGravity = .resizeAspectFill

    configureView()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    DispatchQueue.main.async { [weak self] in
      self?.refreshPermissionState(requestIfNeeded: true)
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    cancelDeferredStart()
    if latestThumbnailRequestId != PHInvalidImageRequestID {
      PHImageManager.default().cancelImageRequest(latestThumbnailRequestId)
    }
    let session = self.session
    let movieOutput = self.movieOutput
    sessionQueue.async {
      if movieOutput.isRecording {
        movieOutput.stopRecording()
      }
      if session.isRunning {
        session.stopRunning()
      }
    }
  }

  override public func didMoveToWindow() {
    super.didMoveToWindow()

    guard window != nil else {
      cancelDeferredStart()
      stopSessionIfNeeded()
      return
    }

    refreshPermissionState(requestIfNeeded: !didRequestInitialPermissions)
    refreshLatestThumbnailIfPossible()

    DispatchQueue.main.async { [weak self] in
      self?.scheduleSessionStartIfNeeded()
    }
  }

  override public func layoutSubviews() {
    super.layoutSubviews()

    permissionContainer.frame = bounds

    let safeTop = max(safeAreaInsets.top, 12.0)
    let safeBottom = max(safeAreaInsets.bottom, 20.0)
    let horizontalMargin: CGFloat = 10.0
    let footerReservedHeight: CGFloat = 190.0
    let cardTop = safeTop + 4.0
    let cardWidth = max(0.0, bounds.width - (horizontalMargin * 2.0))
    let maxCardHeight = max(260.0, bounds.height - cardTop - footerReservedHeight)
    let preferredCardHeight = max(320.0, bounds.height * 0.85)
    let cardHeight = min(preferredCardHeight, maxCardHeight)

    cardContainer.frame = CGRect(
      x: horizontalMargin,
      y: cardTop,
      width: cardWidth,
      height: cardHeight
    )
    previewView.frame = cardContainer.bounds
    loadingOverlay.frame = cardContainer.bounds
    loadingBlurView.frame = loadingOverlay.bounds
    loadingTintView.frame = loadingOverlay.bounds
    loadingSpinner.center = CGPoint(
      x: loadingOverlay.bounds.midX,
      y: loadingOverlay.bounds.midY
    )

    topBar.frame = CGRect(x: 14.0, y: 14.0, width: max(0.0, cardWidth - 28.0), height: 44.0)
    draftsButton.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    closeButton.frame = CGRect(x: topBar.bounds.width - 44.0, y: 0.0, width: 44.0, height: 44.0)
    flashButton.frame = CGRect(x: closeButton.frame.minX - 54.0, y: 0.0, width: 44.0, height: 44.0)

    footerContainer.frame = CGRect(
      x: 0.0,
      y: cardContainer.frame.maxY,
      width: bounds.width,
      height: max(0.0, bounds.height - cardContainer.frame.maxY)
    )

    let bottomRowY = max(0.0, footerContainer.bounds.height - safeBottom - 58.0)
    bottomRow.frame = CGRect(x: 30.0, y: bottomRowY, width: max(0.0, bounds.width - 60.0), height: 44.0)

    galleryButton.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    galleryImageView.frame = galleryButton.bounds
    galleryFallbackView.frame = galleryButton.bounds.insetBy(dx: 11.0, dy: 11.0)

    flipButton.frame = CGRect(x: bottomRow.bounds.width - 44.0, y: 0.0, width: 44.0, height: 44.0)
    modeContainer.frame = CGRect(
      x: floor((bottomRow.bounds.width - 150.0) * 0.5),
      y: 0.0,
      width: 150.0,
      height: 44.0
    )
    pictureModeButton.frame = CGRect(x: 4.0, y: 4.0, width: 69.0, height: 36.0)
    videoModeButton.frame = CGRect(x: modeContainer.bounds.width - 73.0, y: 4.0, width: 69.0, height: 36.0)

    shutterButton.frame = CGRect(
      x: floor((bounds.width - 80.0) * 0.5),
      y: max(10.0, bottomRowY - 110.0),
      width: 80.0,
      height: 80.0
    )
    shutterRingView.frame = shutterButton.bounds
    let innerSize: CGFloat = isRecording ? 34.0 : 62.0
    shutterInnerView.frame = CGRect(
      x: floor((shutterButton.bounds.width - innerSize) * 0.5),
      y: floor((shutterButton.bounds.height - innerSize) * 0.5),
      width: innerSize,
      height: innerSize
    )
    shutterInnerView.layer.cornerRadius = isRecording ? 12.0 : (innerSize * 0.5)

    permissionTitleLabel.sizeToFit()
    permissionButton.sizeToFit()
    let permissionStackHeight = permissionTitleLabel.bounds.height + 18.0 + permissionButton.bounds.height
    let permissionOriginY = floor((permissionContainer.bounds.height - permissionStackHeight) * 0.5)
    permissionTitleLabel.frame = CGRect(
      x: 24.0,
      y: permissionOriginY,
      width: max(0.0, permissionContainer.bounds.width - 48.0),
      height: permissionTitleLabel.bounds.height
    )
    permissionButton.frame = CGRect(
      x: floor((permissionContainer.bounds.width - max(140.0, permissionButton.bounds.width + 28.0)) * 0.5),
      y: permissionTitleLabel.frame.maxY + 18.0,
      width: max(140.0, permissionButton.bounds.width + 28.0),
      height: max(44.0, permissionButton.bounds.height + 18.0)
    )

    focusRingView.bounds = CGRect(x: 0.0, y: 0.0, width: 60.0, height: 60.0)
    focusRingView.layer.cornerRadius = 30.0

    updatePreviewOrientation()
  }

  func setDeferMountMs(_ value: Double) {
    let next = max(0.0, value)
    guard abs(deferMountMs - next) > 0.5 else { return }
    deferMountMs = next
    scheduleSessionStartIfNeeded()
  }

  @objc private func handleWillResignActive() {
    stopSessionIfNeeded()
  }

  @objc private func handleDidBecomeActive() {
    refreshPermissionState(requestIfNeeded: false)
    refreshLatestThumbnailIfPossible()
    scheduleSessionStartIfNeeded()
  }

  @objc private func handlePermissionButtonPress() {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    if status == .notDetermined {
      requestVideoPermission()
      return
    }
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  @objc private func handleDraftsPress() {
    onNativeEvent(["type": "openDrafts"])
  }

  @objc private func handleClosePress() {
    if isRecording {
      shouldIgnoreNextVideoCapture = true
      stopRecording()
    }
    onNativeEvent(["type": "close"])
  }

  @objc private func handleFlashPress() {
    guard supportsCurrentFlashMode else { return }
    isFlashEnabled.toggle()
    updateFlashButtonAppearance()
    applyTorchIfNeeded()
  }

  @objc private func handleFlipPress() {
    guard !isRecording else { return }
    let nextPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.ensureSessionConfigured()
      self.session.beginConfiguration()
      self.replaceVideoInput(position: nextPosition)
      self.session.commitConfiguration()
      DispatchQueue.main.async {
        self.updatePreviewOrientation()
        self.updateFlashButtonAppearance()
      }
    }
  }

  @objc private func handlePictureModePress() {
    setMode(.picture)
  }

  @objc private func handleVideoModePress() {
    setMode(.video)
  }

  @objc private func handleShutterPress() {
    switch currentMode {
    case .picture:
      capturePhoto()
    case .video:
      if isRecording {
        stopRecording()
      } else {
        startRecording()
      }
    }
  }

  @objc private func handleGalleryPress() {
    guard !isRecording else { return }
    guard let presenter = topMostViewController() else {
      emitError("Unable to open the media picker.")
      return
    }

    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.selectionLimit = 1
    configuration.filter = currentMode == .picture ? .images : .videos

    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  @objc private func handlePreviewTap(_ gesture: UITapGestureRecognizer) {
    let point = gesture.location(in: previewView)
    showFocusRing(at: point)
    focusCamera(at: point)
  }

  private func configureView() {
    cardContainer.backgroundColor = UIColor(white: 0.06, alpha: 1.0)
    cardContainer.layer.cornerRadius = 32.0
    cardContainer.layer.cornerCurve = .continuous
    cardContainer.clipsToBounds = true
    addSubview(cardContainer)

    previewView.clipsToBounds = true
    previewView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handlePreviewTap(_:))))
    cardContainer.addSubview(previewView)

    topBar.backgroundColor = .clear
    cardContainer.addSubview(topBar)

    configureChromeButton(draftsButton, symbol: "folder.fill")
    draftsButton.addTarget(self, action: #selector(handleDraftsPress), for: .touchUpInside)
    topBar.addSubview(draftsButton)

    configureChromeButton(flashButton, symbol: "bolt.slash.fill")
    flashButton.addTarget(self, action: #selector(handleFlashPress), for: .touchUpInside)
    topBar.addSubview(flashButton)

    configureChromeButton(closeButton, symbol: "xmark")
    closeButton.addTarget(self, action: #selector(handleClosePress), for: .touchUpInside)
    topBar.addSubview(closeButton)

    loadingOverlay.isHidden = false
    loadingOverlay.isUserInteractionEnabled = false
    cardContainer.addSubview(loadingOverlay)

    loadingBlurView.clipsToBounds = true
    loadingOverlay.addSubview(loadingBlurView)

    loadingTintView.backgroundColor = UIColor.black.withAlphaComponent(0.22)
    loadingOverlay.addSubview(loadingTintView)

    loadingSpinner.color = .white
    loadingSpinner.startAnimating()
    loadingOverlay.addSubview(loadingSpinner)

    focusRingView.isHidden = true
    focusRingView.alpha = 0.0
    focusRingView.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
    focusRingView.layer.borderWidth = 1.5
    cardContainer.addSubview(focusRingView)

    footerContainer.backgroundColor = .clear
    addSubview(footerContainer)

    shutterButton.addTarget(self, action: #selector(handleShutterPress), for: .touchUpInside)
    shutterButton.accessibilityLabel = "Capture"
    footerContainer.addSubview(shutterButton)

    shutterRingView.isUserInteractionEnabled = false
    shutterRingView.layer.borderWidth = 4.0
    shutterRingView.layer.borderColor = UIColor.white.cgColor
    shutterRingView.layer.cornerRadius = 40.0
    shutterButton.addSubview(shutterRingView)

    shutterInnerView.isUserInteractionEnabled = false
    shutterInnerView.backgroundColor = .white
    shutterButton.addSubview(shutterInnerView)

    footerContainer.addSubview(bottomRow)

    configureBottomButton(galleryButton)
    galleryButton.addTarget(self, action: #selector(handleGalleryPress), for: .touchUpInside)
    bottomRow.addSubview(galleryButton)

    galleryImageView.clipsToBounds = true
    galleryImageView.contentMode = .scaleAspectFill
    galleryImageView.layer.cornerRadius = 14.0
    galleryButton.addSubview(galleryImageView)

    galleryFallbackView.image = UIImage(systemName: "photo.on.rectangle")
    galleryFallbackView.tintColor = .white
    galleryFallbackView.contentMode = .scaleAspectFit
    galleryButton.addSubview(galleryFallbackView)

    modeContainer.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    modeContainer.layer.cornerRadius = 22.0
    modeContainer.layer.cornerCurve = .continuous
    modeContainer.layer.borderWidth = 1.0
    modeContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    bottomRow.addSubview(modeContainer)

    configureModeButton(pictureModeButton, title: "PHOTO")
    pictureModeButton.addTarget(self, action: #selector(handlePictureModePress), for: .touchUpInside)
    modeContainer.addSubview(pictureModeButton)

    configureModeButton(videoModeButton, title: "VIDEO")
    videoModeButton.addTarget(self, action: #selector(handleVideoModePress), for: .touchUpInside)
    modeContainer.addSubview(videoModeButton)

    configureBottomButton(flipButton)
    flipButton.setImage(
      UIImage(
        systemName: "arrow.triangle.2.circlepath.camera.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)
      ),
      for: .normal
    )
    flipButton.tintColor = .white
    flipButton.addTarget(self, action: #selector(handleFlipPress), for: .touchUpInside)
    bottomRow.addSubview(flipButton)

    permissionContainer.isHidden = true
    permissionContainer.backgroundColor = .black
    addSubview(permissionContainer)

    permissionTitleLabel.textAlignment = .center
    permissionTitleLabel.textColor = .white
    permissionTitleLabel.font = .systemFont(ofSize: 18.0, weight: .semibold)
    permissionTitleLabel.numberOfLines = 0
    permissionContainer.addSubview(permissionTitleLabel)

    permissionButton.backgroundColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
    permissionButton.layer.cornerRadius = 22.0
    permissionButton.layer.cornerCurve = .continuous
    permissionButton.titleLabel?.font = .systemFont(ofSize: 15.0, weight: .semibold)
    var permissionButtonConfiguration = UIButton.Configuration.plain()
    permissionButtonConfiguration.baseForegroundColor = .white
    permissionButtonConfiguration.contentInsets = NSDirectionalEdgeInsets(
      top: 10.0,
      leading: 18.0,
      bottom: 10.0,
      trailing: 18.0
    )
    permissionButton.configuration = permissionButtonConfiguration
    permissionButton.addTarget(self, action: #selector(handlePermissionButtonPress), for: .touchUpInside)
    permissionContainer.addSubview(permissionButton)

    updateModeButtons()
    updateShutterAppearance()
    updateFlashButtonAppearance()
    setLoadingVisible(true)
  }

  private func configureChromeButton(_ button: UIButton, symbol: String) {
    button.backgroundColor = UIColor.black.withAlphaComponent(0.28)
    button.layer.cornerRadius = 22.0
    button.layer.cornerCurve = .continuous
    button.layer.borderWidth = 1.0
    button.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    button.tintColor = .white
    button.setImage(
      UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)
      ),
      for: .normal
    )
  }

  private func configureBottomButton(_ button: UIButton) {
    button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    button.layer.cornerRadius = 20.0
    button.layer.cornerCurve = .continuous
    button.layer.borderWidth = 1.0
    button.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    button.clipsToBounds = true
  }

  private func configureModeButton(_ button: UIButton, title: String) {
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 12.0, weight: .bold)
    button.layer.cornerRadius = 18.0
    button.layer.cornerCurve = .continuous
  }

  private func refreshPermissionState(requestIfNeeded: Bool) {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      permissionContainer.isHidden = true
      if requestIfNeeded {
        requestOptionalAudioPermissionIfNeeded()
      }
      scheduleSessionStartIfNeeded()
    case .notDetermined:
      permissionContainer.isHidden = false
      permissionTitleLabel.text = "Camera permission required"
      permissionButton.configuration?.title = "Grant Permission"
      if requestIfNeeded && !didRequestInitialPermissions {
        didRequestInitialPermissions = true
        requestVideoPermission()
      }
    default:
      permissionContainer.isHidden = false
      permissionTitleLabel.text = "Allow camera access in Settings"
      permissionButton.configuration?.title = "Open Settings"
      setLoadingVisible(false)
      stopSessionIfNeeded()
    }
  }

  private func requestVideoPermission() {
    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      DispatchQueue.main.async {
        self?.refreshPermissionState(requestIfNeeded: granted)
      }
    }
  }

  private func requestOptionalAudioPermissionIfNeeded() {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .authorized {
      sessionQueue.async { [weak self] in
        guard let self else { return }
        self.session.beginConfiguration()
        self.addAudioInputIfPossible()
        self.session.commitConfiguration()
      }
      return
    }
    guard status == .notDetermined else { return }
    AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
      guard granted else { return }
      self?.sessionQueue.async { [weak self] in
        guard let self else { return }
        self.session.beginConfiguration()
        self.addAudioInputIfPossible()
        self.session.commitConfiguration()
      }
    }
  }

  private func scheduleSessionStartIfNeeded() {
    cancelDeferredStart()
    guard window != nil else { return }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
    if session.isRunning {
      setLoadingVisible(false)
      return
    }

    setLoadingVisible(true)

    let workItem = DispatchWorkItem { [weak self] in
      self?.startSessionIfNeeded()
    }
    deferredStartWorkItem = workItem

    if deferMountMs > 0.0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + (deferMountMs / 1000.0), execute: workItem)
    } else {
      DispatchQueue.main.async(execute: workItem)
    }
  }

  private func cancelDeferredStart() {
    deferredStartWorkItem?.cancel()
    deferredStartWorkItem = nil
  }

  private func startSessionIfNeeded() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.ensureSessionConfigured()
      guard !self.session.isRunning else {
        DispatchQueue.main.async {
          self.setLoadingVisible(false)
        }
        return
      }
      self.session.startRunning()
      DispatchQueue.main.async {
        self.setLoadingVisible(false)
        self.updatePreviewOrientation()
        self.updateFlashButtonAppearance()
      }
    }
  }

  private func stopSessionIfNeeded() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      if self.movieOutput.isRecording {
        self.shouldIgnoreNextVideoCapture = true
        self.movieOutput.stopRecording()
      }
      if self.session.isRunning {
        self.session.stopRunning()
      }
    }
  }

  private func ensureSessionConfigured() {
    guard !hasConfiguredSession else { return }
    session.beginConfiguration()
    session.sessionPreset = .high

    if session.canAddOutput(photoOutput) {
      session.addOutput(photoOutput)
    }

    if session.canAddOutput(movieOutput) {
      session.addOutput(movieOutput)
      movieOutput.maxRecordedDuration = CMTime(seconds: 15.0, preferredTimescale: 600)
      movieOutput.movieFragmentInterval = .invalid
    }

    replaceVideoInput(position: currentPosition)
    addAudioInputIfPossible()

    session.commitConfiguration()
    hasConfiguredSession = true
  }

  private func replaceVideoInput(position: AVCaptureDevice.Position) {
    guard let device = Self.cameraDevice(for: position) else { return }
    guard let nextInput = try? AVCaptureDeviceInput(device: device) else { return }

    let previousInput = videoInput
    if let previousInput {
      session.removeInput(previousInput)
    }

    if session.canAddInput(nextInput) {
      session.addInput(nextInput)
      videoInput = nextInput
      currentPosition = position
      return
    }

    if let previousInput, session.canAddInput(previousInput) {
      session.addInput(previousInput)
      videoInput = previousInput
    }
  }

  private func addAudioInputIfPossible() {
    guard audioInput == nil else { return }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
    guard let audioDevice = AVCaptureDevice.default(for: .audio) else { return }
    guard let nextInput = try? AVCaptureDeviceInput(device: audioDevice) else { return }
    guard session.canAddInput(nextInput) else { return }
    session.addInput(nextInput)
    audioInput = nextInput
  }

  private func updatePreviewOrientation() {
    currentVideoOrientation =
      window?.windowScene?.interfaceOrientation.nativeStoryCameraVideoOrientation ?? .portrait

    if let connection = previewView.previewLayer.connection, connection.isVideoOrientationSupported {
      connection.videoOrientation = currentVideoOrientation
      if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = currentPosition == .front
      }
    }
  }

  private var supportsCurrentFlashMode: Bool {
    guard let device = videoInput?.device else { return false }
    if currentMode == .picture {
      return device.hasFlash
    }
    return device.hasTorch
  }

  private func updateFlashButtonAppearance() {
    let symbol = isFlashEnabled ? "bolt.fill" : "bolt.slash.fill"
    flashButton.setImage(
      UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)
      ),
      for: .normal
    )
    flashButton.tintColor = isFlashEnabled ? UIColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 1.0) : .white
    flashButton.isEnabled = supportsCurrentFlashMode && !isRecording
    flashButton.alpha = flashButton.isEnabled ? 1.0 : 0.5
  }

  private func updateModeButtons() {
    let selectedBackground = UIColor.white.withAlphaComponent(0.18)
    let unselectedBackground = UIColor.clear
    pictureModeButton.backgroundColor = currentMode == .picture ? selectedBackground : unselectedBackground
    videoModeButton.backgroundColor = currentMode == .video ? selectedBackground : unselectedBackground
    pictureModeButton.setTitleColor(currentMode == .picture ? .white : UIColor.white.withAlphaComponent(0.62), for: .normal)
    videoModeButton.setTitleColor(currentMode == .video ? .white : UIColor.white.withAlphaComponent(0.62), for: .normal)
  }

  private func updateShutterAppearance() {
    shutterRingView.layer.borderColor = (isRecording ? UIColor.systemRed : UIColor.white).cgColor
    shutterRingView.layer.borderWidth = isRecording ? 6.0 : 4.0
    shutterInnerView.backgroundColor = currentMode == .video ? UIColor.systemRed : .white
    setNeedsLayout()
  }

  private func setLoadingVisible(_ visible: Bool) {
    loadingOverlay.isHidden = !visible
    if visible {
      loadingSpinner.startAnimating()
    } else {
      loadingSpinner.stopAnimating()
    }
  }

  private func setMode(_ mode: NativeStoryCameraMode) {
    guard currentMode != mode else { return }
    if isRecording {
      shouldIgnoreNextVideoCapture = true
      stopRecording()
    }
    currentMode = mode
    if mode == .video {
      requestOptionalAudioPermissionIfNeeded()
    }
    updateModeButtons()
    updateShutterAppearance()
    updateFlashButtonAppearance()
    applyTorchIfNeeded()
  }

  private func showFocusRing(at point: CGPoint) {
    focusRingView.center = point
    focusRingView.isHidden = false
    focusRingView.alpha = 1.0
    focusRingView.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
    UIView.animate(withDuration: 0.16, delay: 0.0, options: [.curveEaseOut]) {
      self.focusRingView.transform = .identity
    }
    UIView.animate(withDuration: 0.3, delay: 0.65, options: [.curveEaseIn]) {
      self.focusRingView.alpha = 0.0
    } completion: { _ in
      self.focusRingView.isHidden = true
    }
  }

  private func focusCamera(at point: CGPoint) {
    let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
    sessionQueue.async { [weak self] in
      guard let self, let device = self.videoInput?.device else { return }
      do {
        try device.lockForConfiguration()
        if device.isFocusPointOfInterestSupported {
          device.focusPointOfInterest = devicePoint
          device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported {
          device.exposurePointOfInterest = devicePoint
          device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()
      } catch {}
    }
  }

  private func capturePhoto() {
    guard !isRecording else { return }
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.ensureSessionConfigured()

      let settings: AVCapturePhotoSettings
      if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
        settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
      } else {
        settings = AVCapturePhotoSettings()
      }

      if self.videoInput?.device.hasFlash == true {
        settings.flashMode = self.isFlashEnabled ? .on : .off
      }

      if let connection = self.photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
        connection.videoOrientation = self.currentVideoOrientation
        if connection.isVideoMirroringSupported {
          connection.isVideoMirrored = self.currentPosition == .front
        }
      }

      self.photoOutput.capturePhoto(with: settings, delegate: self)
    }
  }

  private func startRecording() {
    guard !isRecording else { return }
    setRecording(true)
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.ensureSessionConfigured()
      guard !self.movieOutput.isRecording else { return }

      if let connection = self.movieOutput.connection(with: .video), connection.isVideoOrientationSupported {
        connection.videoOrientation = self.currentVideoOrientation
        if connection.isVideoMirroringSupported {
          connection.isVideoMirrored = self.currentPosition == .front
        }
      }

      self.applyTorchIfNeededOnSessionQueue()
      let outputURL = self.temporaryOutputURL(fileExtension: "mov")
      self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
    }
  }

  private func stopRecording() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      if self.movieOutput.isRecording {
        self.movieOutput.stopRecording()
      }
    }
  }

  private func setRecording(_ recording: Bool) {
    isRecording = recording
    DispatchQueue.main.async {
      self.updateShutterAppearance()
      self.updateFlashButtonAppearance()
    }
  }

  private func applyTorchIfNeeded() {
    sessionQueue.async { [weak self] in
      self?.applyTorchIfNeededOnSessionQueue()
    }
  }

  private func applyTorchIfNeededOnSessionQueue() {
    guard let device = videoInput?.device, device.hasTorch else { return }
    do {
      try device.lockForConfiguration()
      if currentMode == .video && isRecording && isFlashEnabled {
        try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
      } else {
        device.torchMode = .off
      }
      device.unlockForConfiguration()
    } catch {}
  }

  private func emitCapture(url: URL, mediaType: String, mirrored: Bool) {
    onNativeEvent([
      "type": "capture",
      "uri": url.absoluteString,
      "mediaType": mediaType,
      "mirrored": mirrored,
    ])
  }

  private func emitError(_ message: String) {
    onNativeEvent([
      "type": "error",
      "message": message,
    ])
  }

  private func refreshLatestThumbnailIfPossible() {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else {
      galleryImageView.image = nil
      galleryFallbackView.isHidden = false
      return
    }

    let options = PHFetchOptions()
    options.fetchLimit = 1
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    let assets = PHAsset.fetchAssets(with: options)
    guard let asset = assets.firstObject else {
      galleryImageView.image = nil
      galleryFallbackView.isHidden = false
      return
    }

    let requestOptions = PHImageRequestOptions()
    requestOptions.deliveryMode = .opportunistic
    requestOptions.resizeMode = .fast
    requestOptions.isNetworkAccessAllowed = true

    if latestThumbnailRequestId != PHInvalidImageRequestID {
      PHImageManager.default().cancelImageRequest(latestThumbnailRequestId)
    }

    latestThumbnailRequestId = PHImageManager.default().requestImage(
      for: asset,
      targetSize: CGSize(width: 120.0, height: 120.0),
      contentMode: .aspectFill,
      options: requestOptions
    ) { [weak self] image, _ in
      self?.galleryImageView.image = image
      self?.galleryFallbackView.isHidden = image != nil
    }
  }

  private func temporaryOutputURL(fileExtension: String) -> URL {
    let trimmed = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let resolvedExtension = trimmed.isEmpty ? "tmp" : trimmed
    return FileManager.default.temporaryDirectory.appendingPathComponent(
      "story-\(UUID().uuidString).\(resolvedExtension)"
    )
  }

  private func topMostViewController() -> UIViewController? {
    let root =
      window?.rootViewController
      ?? UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)?.rootViewController
      ?? UIApplication.shared.delegate?.window??.rootViewController

    guard let root else { return nil }
    var top = root
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }

  private static func cameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
    if position == .front {
      return AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
        ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        ?? AVCaptureDevice.default(for: .video)
    }
    return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
      ?? AVCaptureDevice.default(for: .video)
  }

  public func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    if let error {
      DispatchQueue.main.async {
        self.emitError(error.localizedDescription)
      }
      return
    }

    guard let data = photo.fileDataRepresentation() else {
      DispatchQueue.main.async {
        self.emitError("Unable to save photo.")
      }
      return
    }

    let outputURL = temporaryOutputURL(fileExtension: "jpg")
    do {
      try data.write(to: outputURL, options: [.atomic])
      DispatchQueue.main.async {
        self.emitCapture(
          url: outputURL,
          mediaType: "image",
          mirrored: self.currentPosition == .front
        )
        self.refreshLatestThumbnailIfPossible()
      }
    } catch {
      DispatchQueue.main.async {
        self.emitError(error.localizedDescription)
      }
    }
  }

  public func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    setRecording(true)
  }

  public func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    applyTorchIfNeeded()
    setRecording(false)

    if shouldIgnoreNextVideoCapture {
      shouldIgnoreNextVideoCapture = false
      try? FileManager.default.removeItem(at: outputFileURL)
      return
    }

    if let nsError = error as NSError?,
      nsError.domain != AVFoundationErrorDomain
        || nsError.code != AVError.Code.maximumDurationReached.rawValue
    {
      DispatchQueue.main.async {
        self.emitError(nsError.localizedDescription)
      }
      return
    }

    DispatchQueue.main.async {
      self.emitCapture(
        url: outputFileURL,
        mediaType: "video",
        mirrored: self.currentPosition == .front
      )
      self.refreshLatestThumbnailIfPossible()
    }
  }

  public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = results.first else { return }

    if currentMode == .video {
      loadPickedVideo(from: result.itemProvider)
      return
    }

    loadPickedImage(from: result.itemProvider)
  }

  private func loadPickedImage(from itemProvider: NSItemProvider) {
    guard itemProvider.canLoadObject(ofClass: UIImage.self) else {
      emitError("Unable to import image.")
      return
    }

    itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
      guard let self else { return }
      if let error {
        DispatchQueue.main.async {
          self.emitError(error.localizedDescription)
        }
        return
      }
      guard let image = object as? UIImage, let data = image.jpegData(compressionQuality: 0.94) else {
        DispatchQueue.main.async {
          self.emitError("Unable to process image.")
        }
        return
      }

      let outputURL = self.temporaryOutputURL(fileExtension: "jpg")
      do {
        try data.write(to: outputURL, options: [.atomic])
        DispatchQueue.main.async {
          self.emitCapture(url: outputURL, mediaType: "image", mirrored: false)
          self.refreshLatestThumbnailIfPossible()
        }
      } catch {
        DispatchQueue.main.async {
          self.emitError(error.localizedDescription)
        }
      }
    }
  }

  private func loadPickedVideo(from itemProvider: NSItemProvider) {
    guard itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
      emitError("Unable to import video.")
      return
    }

    itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
      guard let self else { return }
      if let error {
        DispatchQueue.main.async {
          self.emitError(error.localizedDescription)
        }
        return
      }
      guard let url else {
        DispatchQueue.main.async {
          self.emitError("Unable to read selected video.")
        }
        return
      }

      let outputURL = self.temporaryOutputURL(fileExtension: url.pathExtension.isEmpty ? "mov" : url.pathExtension)
      do {
        if FileManager.default.fileExists(atPath: outputURL.path) {
          try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: url, to: outputURL)
        DispatchQueue.main.async {
          self.emitCapture(url: outputURL, mediaType: "video", mirrored: false)
          self.refreshLatestThumbnailIfPossible()
        }
      } catch {
        DispatchQueue.main.async {
          self.emitError(error.localizedDescription)
        }
      }
    }
  }
}

public final class NativeStoryCameraModule: Module {
  public func definition() -> ModuleDefinition {
    Name("NativeStoryCamera")

    View(NativeStoryCameraView.self) {
      Prop("deferMountMs") { (view: NativeStoryCameraView, value: Double?) in
        view.setDeferMountMs(value ?? 0.0)
      }

      Events("onNativeEvent")
    }
  }
}
