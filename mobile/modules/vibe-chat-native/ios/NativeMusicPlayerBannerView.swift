import UIKit

struct NativeMusicPlayerTheme {
  var isDark = true
  var surface = UIColor(white: 0.08, alpha: 1.0)
  var text = UIColor.white
  var secondaryText = UIColor(white: 1.0, alpha: 0.68)
  var primary = UIColor.systemBlue
}

private struct NativeMusicPlayerViewState {
  let currentTrack: NativeMusicPlayerTrack?
  let queue: [NativeMusicPlayerTrack]
  let library: [NativeMusicPlayerTrack]
  let isPlaying: Bool
  let isExpanded: Bool
  let progressMs: Double
  let durationMs: Double
  let playbackRate: Double
  let currentDownloadProgress: Double?
  let artworkImage: UIImage?
  let allowsExpansion: Bool

  static let empty = NativeMusicPlayerViewState(
    currentTrack: nil,
    queue: [],
    library: [],
    isPlaying: false,
    isExpanded: false,
    progressMs: 0.0,
    durationMs: 0.0,
    playbackRate: 1.0,
    currentDownloadProgress: nil,
    artworkImage: nil,
    allowsExpansion: true
  )

  static func from(payload: [String: Any]) -> NativeMusicPlayerViewState {
    let currentTrack = (payload["currentTrack"] as? [String: Any]).flatMap(NativeMusicPlayerTrack.init)
    let queue = (payload["queue"] as? [[String: Any]] ?? []).compactMap(NativeMusicPlayerTrack.init)
    let library = (payload["library"] as? [[String: Any]] ?? []).compactMap(NativeMusicPlayerTrack.init)
    let downloadingTracks = payload["downloadingTracks"] as? [String: Double] ?? [:]
    let currentTrackId = currentTrack?.trackId
    return NativeMusicPlayerViewState(
      currentTrack: currentTrack,
      queue: queue,
      library: library,
      isPlaying: (payload["isPlaying"] as? Bool) ?? false,
      isExpanded: (payload["isExpanded"] as? Bool) ?? false,
      progressMs: (payload["progress"] as? NSNumber)?.doubleValue ?? (payload["progress"] as? Double) ?? 0.0,
      durationMs: (payload["duration"] as? NSNumber)?.doubleValue ?? (payload["duration"] as? Double) ?? 0.0,
      playbackRate: (payload["playbackRate"] as? NSNumber)?.doubleValue
        ?? (payload["playbackRate"] as? Double)
        ?? 1.0,
      currentDownloadProgress: currentTrackId.flatMap { downloadingTracks[$0] },
      artworkImage: nil,
      allowsExpansion: true
    )
  }

  static func from(
    voiceSnapshot: VoiceBubblePlaybackSnapshot,
    isExpanded: Bool = false
  ) -> NativeMusicPlayerViewState {
    guard let messageId = voiceSnapshot.messageId else { return .empty }
    let durationMs = max(0.0, voiceSnapshot.duration * 1000.0)
    let progressMs = durationMs * max(0.0, min(1.0, Double(voiceSnapshot.progress)))
    let queue = ChatAudioQueueRegistry.shared.tracks(for: voiceSnapshot.chatId)
    let track =
      queue.first(where: { $0.trackId == messageId })
      ?? NativeMusicPlayerTrack(
        trackId: messageId,
        videoId: nil,
        id: messageId,
        source: "chat-music",
        title: voiceSnapshot.title ?? "Audio",
        artist: voiceSnapshot.subtitle ?? "Vibegram",
        album: nil,
        duration: nil,
        durationSeconds: voiceSnapshot.duration > 0.0 ? voiceSnapshot.duration : nil,
        cover: nil,
        previewURL: nil,
        streamURL: nil,
        localURI: nil,
        cachedAt: nil,
        playCount: 0,
        lastPlayedAt: nil,
        links: [:]
      )
    return NativeMusicPlayerViewState(
      currentTrack: track,
      queue: queue,
      library: [],
      isPlaying: voiceSnapshot.isPlaying,
      isExpanded: isExpanded,
      progressMs: progressMs,
      durationMs: durationMs,
      playbackRate: 1.0,
      currentDownloadProgress: voiceSnapshot.isDownloading ? Double(voiceSnapshot.downloadProgress ?? 0.0) : nil,
      artworkImage: voiceSnapshot.artwork,
      allowsExpansion: voiceSnapshot.presentsGlobalPlayer
    )
  }
}

private final class NativeMusicPlayerQueueRowView: UIControl {
  private let artworkView = UIImageView()
  private let artworkFallbackView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let durationLabel = UILabel()
  private let activeIndicator = UIView()
  private let textStack = UIStackView()
  private var theme = NativeMusicPlayerTheme()
  private var trackId: String?
  private var imageTask: URLSessionDataTask?

  var onSelectTrack: ((String) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerCurve = .continuous
    layer.cornerRadius = 16.0

    artworkView.contentMode = .scaleAspectFill
    artworkView.clipsToBounds = true
    artworkView.layer.cornerCurve = .continuous
    artworkView.layer.cornerRadius = 10.0
    addSubview(artworkView)

    artworkFallbackView.contentMode = .scaleAspectFit
    artworkFallbackView.image = UIImage(systemName: "music.note")
    addSubview(artworkFallbackView)

    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    titleLabel.numberOfLines = 1
    subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    subtitleLabel.numberOfLines = 1

    durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    durationLabel.textAlignment = .right
    addSubview(durationLabel)

    textStack.axis = .vertical
    textStack.alignment = .fill
    textStack.spacing = 2.0
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(subtitleLabel)
    addSubview(textStack)

    activeIndicator.layer.cornerCurve = .continuous
    activeIndicator.layer.cornerRadius = 3.0
    activeIndicator.alpha = 0.0
    addSubview(activeIndicator)

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func applyTheme(_ theme: NativeMusicPlayerTheme) {
    self.theme = theme
    titleLabel.textColor = theme.text
    subtitleLabel.textColor = theme.secondaryText
    durationLabel.textColor = theme.secondaryText
    artworkFallbackView.tintColor = theme.secondaryText
    activeIndicator.backgroundColor = theme.primary
  }

  func configure(track: NativeMusicPlayerTrack, isActive: Bool) {
    trackId = track.trackId
    titleLabel.text = track.title
    subtitleLabel.text = track.artist
    durationLabel.text = track.duration
    activeIndicator.alpha = isActive ? 1.0 : 0.0
    backgroundColor = isActive
      ? theme.primary.withAlphaComponent(0.08)
      : theme.text.withAlphaComponent(0.03)
    loadImage(urlString: track.cover)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset: CGFloat = 10.0
    let artworkSide = bounds.height - (inset * 2.0)
    artworkView.frame = CGRect(x: inset, y: inset, width: artworkSide, height: artworkSide)
    artworkFallbackView.frame = artworkView.frame.insetBy(dx: 9.0, dy: 9.0)
    activeIndicator.frame = CGRect(
      x: bounds.width - inset - 6.0,
      y: floor((bounds.height - 6.0) * 0.5),
      width: 6.0,
      height: 6.0
    )
    let textX = artworkView.frame.maxX + 12.0
    durationLabel.frame = CGRect(
      x: bounds.width - inset - 54.0,
      y: floor((bounds.height - 14.0) * 0.5),
      width: 44.0,
      height: 14.0
    )
    textStack.frame = CGRect(
      x: textX,
      y: floor((bounds.height - 34.0) * 0.5),
      width: max(0.0, durationLabel.frame.minX - 12.0 - textX),
      height: 34.0
    )
  }

  private func loadImage(urlString: String?) {
    imageTask?.cancel()
    artworkView.image = nil
    artworkFallbackView.isHidden = false
    guard
      let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty,
      let url = URL(string: trimmed)
    else { return }

    imageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        self.artworkView.image = image
        self.artworkFallbackView.isHidden = true
      }
    }
    imageTask?.resume()
  }

  @objc private func handleTap() {
    guard let trackId else { return }
    onSelectTrack?(trackId)
  }
}

final class NativeMusicPlayerBannerView: UIView, UIGestureRecognizerDelegate {
  static let miniHeight: CGFloat = 44.0

  private let dimView = UIView()
  private let expandedBlurView = UIVisualEffectView(effect: nil)
  private let expandedContentView = UIView()
  private let headerButton = UIButton(type: .system)
  private let expandedDismissButton = UIButton(type: .system)
  private let coverView = UIImageView()
  private let coverFallbackView = UIImageView()
  private let expandedTitleLabel = UILabel()
  private let expandedArtistLabel = UILabel()
  private let currentTimeLabel = UILabel()
  private let durationLabel = UILabel()
  private let progressSlider = UISlider()
  private let downloadLabel = UILabel()
  private let prevButton = UIButton(type: .system)
  private let playButton = VoicePlayProgressView()
  private let nextButton = UIButton(type: .system)
  private let rateButton = UIButton(type: .system)
  private let queueTitleLabel = UILabel()
  private let queueScrollView = UIScrollView()
  private let queueStackView = UIStackView()

  private let miniBlurView = UIVisualEffectView(effect: nil)
  private let miniArtworkView = UIImageView()
  private let miniArtworkFallbackView = UIImageView()
  private let miniTitleLabel = UILabel()
  private let miniSubtitleLabel = UILabel()
  private let miniProgressTrackView = UIView()
  private let miniProgressFillView = UIView()
  private let miniProgressImageView = UIImageView()
  private let miniProgressBlurView = UIVisualEffectView(effect: nil)
  private let miniProgressTintView = UIView()
  private let miniPlayButton = UIButton(type: .system)
  private let miniCloseButton = UIButton(type: .system)
  private let miniTextTapTarget = UIControl()

  private var theme = NativeMusicPlayerTheme()
  private var state = NativeMusicPlayerViewState.empty
  private var topInset: CGFloat = 0.0
  private var coverImageTask: URLSessionDataTask?
  private var queueRowViews: [NativeMusicPlayerQueueRowView] = []
  private var pendingSeekValue: Float?
  private var miniDragOffset = CGPoint.zero
  private var miniDragStartOffset = CGPoint.zero
  private var renderedExpandedState = false
  private var hasAppliedPresentationState = false
  private lazy var miniPanGesture: UIPanGestureRecognizer = {
    let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleMiniPan(_:)))
    gesture.cancelsTouchesInView = false
    gesture.delegate = self
    return gesture
  }()

  var onTogglePlayback: (() -> Void)?
  var onClose: (() -> Void)?
  var onSetExpanded: ((Bool) -> Void)?
  var onPlayNext: (() -> Void)?
  var onPlayPrev: (() -> Void)?
  var onPlaybackRateToggle: (() -> Void)?
  var onSeek: ((Double) -> Void)?
  var onSelectTrack: ((String) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    dimView.backgroundColor = UIColor.black.withAlphaComponent(0.48)
    dimView.alpha = 0.0
    addSubview(dimView)
    dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleCollapse)))

    expandedBlurView.clipsToBounds = true
    expandedBlurView.alpha = 0.0
    addSubview(expandedBlurView)

    expandedBlurView.contentView.addSubview(expandedContentView)

    headerButton.setImage(
      UIImage(systemName: "chevron.down")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)),
      for: .normal
    )
    headerButton.addTarget(self, action: #selector(handleCollapse), for: .touchUpInside)
    expandedContentView.addSubview(headerButton)

    expandedDismissButton.setImage(
      UIImage(systemName: "xmark")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
      for: .normal
    )
    expandedDismissButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    expandedContentView.addSubview(expandedDismissButton)

    coverView.contentMode = .scaleAspectFill
    coverView.clipsToBounds = true
    coverView.layer.cornerCurve = .continuous
    coverView.layer.cornerRadius = 26.0
    expandedContentView.addSubview(coverView)

    coverFallbackView.contentMode = .scaleAspectFit
    coverFallbackView.image = UIImage(systemName: "music.note")
    expandedContentView.addSubview(coverFallbackView)

    expandedTitleLabel.font = .systemFont(ofSize: 26, weight: .bold)
    expandedTitleLabel.numberOfLines = 2
    expandedTitleLabel.textAlignment = .center
    expandedContentView.addSubview(expandedTitleLabel)

    expandedArtistLabel.font = .systemFont(ofSize: 18, weight: .medium)
    expandedArtistLabel.numberOfLines = 2
    expandedArtistLabel.textAlignment = .center
    expandedContentView.addSubview(expandedArtistLabel)

    currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    expandedContentView.addSubview(currentTimeLabel)
    expandedContentView.addSubview(durationLabel)

    progressSlider.addTarget(self, action: #selector(handleSliderChanged), for: .valueChanged)
    progressSlider.addTarget(self, action: #selector(handleSliderCommit), for: .touchUpInside)
    progressSlider.addTarget(self, action: #selector(handleSliderCommit), for: .touchUpOutside)
    progressSlider.addTarget(self, action: #selector(handleSliderCommit), for: .touchCancel)
    expandedContentView.addSubview(progressSlider)

    downloadLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    downloadLabel.textAlignment = .center
    expandedContentView.addSubview(downloadLabel)

    configureControlButton(prevButton, systemName: "backward.fill")
    configureControlButton(nextButton, systemName: "forward.fill")
    prevButton.addTarget(self, action: #selector(handlePrev), for: .touchUpInside)
    nextButton.addTarget(self, action: #selector(handleNext), for: .touchUpInside)
    expandedContentView.addSubview(prevButton)
    expandedContentView.addSubview(nextButton)

    playButton.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTogglePlayback)))
    expandedContentView.addSubview(playButton)

    rateButton.configuration = .plain()
    rateButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    rateButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
    rateButton.layer.cornerCurve = .continuous
    rateButton.layer.cornerRadius = 14.0
    rateButton.addTarget(self, action: #selector(handleRateToggle), for: .touchUpInside)
    expandedContentView.addSubview(rateButton)

    queueTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    expandedContentView.addSubview(queueTitleLabel)

    queueScrollView.showsVerticalScrollIndicator = false
    queueScrollView.delegate = self
    expandedContentView.addSubview(queueScrollView)

    queueStackView.axis = .vertical
    queueStackView.spacing = 10.0
    queueScrollView.addSubview(queueStackView)

    miniBlurView.layer.cornerCurve = .continuous
    miniBlurView.layer.cornerRadius = Self.miniHeight / 2.0
    miniBlurView.clipsToBounds = true
    addSubview(miniBlurView)

    miniArtworkView.contentMode = .scaleAspectFill
    miniArtworkView.clipsToBounds = true
    miniArtworkView.layer.cornerCurve = .continuous
    miniArtworkView.layer.cornerRadius = 14.0
    addSubview(miniArtworkView)

    miniArtworkFallbackView.contentMode = .scaleAspectFit
    miniArtworkFallbackView.image = UIImage(systemName: "music.note")
    addSubview(miniArtworkFallbackView)

    miniProgressTrackView.layer.cornerCurve = .continuous
    miniProgressTrackView.layer.cornerRadius = Self.miniHeight / 2.0
    miniProgressTrackView.clipsToBounds = true
    miniBlurView.contentView.addSubview(miniProgressTrackView)

    miniProgressImageView.contentMode = .scaleAspectFill
    miniProgressImageView.clipsToBounds = true
    miniProgressFillView.addSubview(miniProgressImageView)

    miniProgressBlurView.isUserInteractionEnabled = false
    miniProgressFillView.addSubview(miniProgressBlurView)

    miniProgressTintView.isUserInteractionEnabled = false
    miniProgressFillView.addSubview(miniProgressTintView)

    miniProgressFillView.layer.cornerCurve = .continuous
    miniProgressFillView.layer.cornerRadius = Self.miniHeight / 2.0
    miniProgressFillView.clipsToBounds = true
    miniProgressTrackView.addSubview(miniProgressFillView)

    miniTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    miniTitleLabel.numberOfLines = 1
    addSubview(miniTitleLabel)

    miniSubtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    miniSubtitleLabel.numberOfLines = 1
    addSubview(miniSubtitleLabel)

    miniPlayButton.tintColor = .white
    miniPlayButton.addTarget(self, action: #selector(handleTogglePlayback), for: .touchUpInside)
    addSubview(miniPlayButton)

    miniCloseButton.configuration = .plain()
    miniCloseButton.setImage(
      UIImage(systemName: "xmark")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)),
      for: .normal
    )
    miniCloseButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    addSubview(miniCloseButton)

    miniTextTapTarget.addTarget(self, action: #selector(handleExpand), for: .touchUpInside)
    miniTextTapTarget.addGestureRecognizer(miniPanGesture)
    addSubview(miniTextTapTarget)

    isHidden = true
    applyTheme(theme)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  private func applyGlassMaterial(to blurView: UIVisualEffectView, interactive: Bool) {
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = interactive
      blurView.effect = glass
    } else {
      blurView.effect = UIBlurEffect(style: .systemMaterial)
    }
  }

  private func applyMiniControlButtonStyle(button: UIButton, systemName: String) {
    button.configuration = nil
    button.backgroundColor = .clear
    button.setImage(
      UIImage(
        systemName: systemName,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)
      ),
      for: .normal
    )
    button.tintColor = theme.text
  }

  func applyTheme(_ theme: NativeMusicPlayerTheme) {
    self.theme = theme
    applyGlassMaterial(to: expandedBlurView, interactive: true)
    applyGlassMaterial(to: miniBlurView, interactive: true)
    expandedBlurView.contentView.backgroundColor = theme.surface.withAlphaComponent(theme.isDark ? 0.16 : 0.10)
    miniBlurView.contentView.backgroundColor = theme.surface.withAlphaComponent(theme.isDark ? 0.10 : 0.08)
    miniBlurView.alpha = theme.isDark ? 0.98 : 0.94

    let secondaryAlpha: CGFloat = theme.isDark ? 0.72 : 0.62
    headerButton.tintColor = theme.text
    expandedDismissButton.tintColor = theme.secondaryText
    coverView.backgroundColor = UIColor(white: theme.isDark ? 1.0 : 0.0, alpha: theme.isDark ? 0.08 : 0.06)
    coverFallbackView.tintColor = theme.secondaryText
    expandedTitleLabel.textColor = theme.text
    expandedArtistLabel.textColor = theme.secondaryText
    currentTimeLabel.textColor = theme.secondaryText
    durationLabel.textColor = theme.secondaryText
    downloadLabel.textColor = theme.primary
    prevButton.tintColor = theme.text
    nextButton.tintColor = theme.text
    rateButton.setTitleColor(theme.text, for: .normal)
    rateButton.backgroundColor = theme.text.withAlphaComponent(theme.isDark ? 0.10 : 0.08)
    queueTitleLabel.textColor = theme.text

    miniArtworkView.backgroundColor = coverView.backgroundColor
    miniArtworkFallbackView.tintColor = theme.secondaryText
    miniTitleLabel.textColor = theme.text
    miniSubtitleLabel.textColor = theme.text.withAlphaComponent(secondaryAlpha)
    miniProgressTrackView.backgroundColor = .clear
    miniProgressFillView.backgroundColor = .clear
    applyGlassMaterial(to: miniProgressBlurView, interactive: false)
    miniProgressTintView.backgroundColor = theme.primary.withAlphaComponent(theme.isDark ? 0.38 : 0.32)
    miniPlayButton.tintColor = theme.text
    miniCloseButton.tintColor = theme.secondaryText
    applyMiniControlButtonStyle(button: miniPlayButton, systemName: state.isPlaying ? "pause.fill" : "play.fill")
    applyMiniControlButtonStyle(button: miniCloseButton, systemName: "xmark")

    progressSlider.minimumTrackTintColor = theme.primary
    progressSlider.maximumTrackTintColor = theme.text.withAlphaComponent(theme.isDark ? 0.16 : 0.10)
    let thumbImage = Self.sliderThumbImage(color: theme.primary)
    progressSlider.setThumbImage(thumbImage, for: .normal)
    progressSlider.setThumbImage(thumbImage, for: .highlighted)

    playButton.applyStyle(
      fillColor: theme.primary.withAlphaComponent(0.12),
      iconTint: theme.primary,
      ringTint: theme.primary.withAlphaComponent(0.82)
    )

    queueRowViews.forEach { $0.applyTheme(theme) }
  }

  func setTopInset(_ value: CGFloat) {
    if abs(topInset - value) <= 0.5 { return }
    topInset = value
    setNeedsLayout()
  }

  func applyStatePayload(_ payload: [String: Any]) {
    applyState(NativeMusicPlayerViewState.from(payload: payload))
  }

  func applyVoiceSnapshot(_ snapshot: VoiceBubblePlaybackSnapshot, isExpanded: Bool = false) {
    applyState(NativeMusicPlayerViewState.from(voiceSnapshot: snapshot, isExpanded: isExpanded))
  }

  func containsInteractivePoint(_ point: CGPoint) -> Bool {
    if state.isExpanded && state.allowsExpansion { return bounds.contains(point) && !isHidden }
    guard !isHidden else { return false }
    return miniBlurView.frame.contains(point)
      || miniPlayButton.frame.contains(point)
      || miniCloseButton.frame.contains(point)
      || miniTextTapTarget.frame.contains(point)
  }

  private func applyState(_ nextState: NativeMusicPlayerViewState) {
    let previousExpandedState = renderedExpandedState
    state = nextState
    let shouldShow = nextState.currentTrack != nil
    isHidden = !shouldShow
    guard shouldShow, let track = nextState.currentTrack else { return }
    let availableTracks = mergedAvailableTracks(for: nextState)

    miniTitleLabel.text = track.title
    expandedTitleLabel.text = track.title
    let detailText = playbackDetailText(for: nextState, track: track)
    miniSubtitleLabel.text = detailText
    expandedArtistLabel.text = detailText
    currentTimeLabel.text = Self.format(milliseconds: nextState.progressMs)
    durationLabel.text = Self.format(milliseconds: max(nextState.durationMs, (track.durationSeconds ?? 0.0) * 1000.0))
    rateButton.setTitle(Self.rateTitle(nextState.playbackRate), for: .normal)
    queueTitleLabel.text = queueHeaderTitle(for: nextState, availableTracks: availableTracks)
    queueTitleLabel.isHidden = availableTracks.isEmpty

    updateCoverImage(urlString: track.cover, directImage: nextState.artworkImage)
    applyPlaybackButtons(for: nextState)
    downloadLabel.isHidden = true
    downloadLabel.text = nil

    let durationMs = max(nextState.durationMs, 1.0)
    if !progressSlider.isTracking {
      progressSlider.value = Float(max(0.0, min(1.0, nextState.progressMs / durationMs)))
    }

    let isExpanded = nextState.allowsExpansion && nextState.isExpanded
    applyExpandedPresentation(
      isExpanded: isExpanded,
      animated: hasAppliedPresentationState && previousExpandedState != isExpanded
    )

    rebuildQueueRows()
    setNeedsLayout()
  }

  private func miniPresentationViews() -> [UIView] {
    [
      miniBlurView,
      miniArtworkView,
      miniArtworkFallbackView,
      miniTitleLabel,
      miniSubtitleLabel,
      miniPlayButton,
      miniCloseButton,
      miniTextTapTarget,
    ]
  }

  private func applyExpandedPresentation(isExpanded: Bool, animated: Bool) {
    renderedExpandedState = isExpanded
    let expandedHiddenTransform = CGAffineTransform(translationX: 0.0, y: bounds.height)
    let miniHiddenTransform = CGAffineTransform(translationX: 0.0, y: -10.0)
    let miniVisibleAlpha = theme.isDark ? 0.98 : 0.94
    let miniViews = miniPresentationViews()

    let applyFinalState = {
      self.dimView.alpha = isExpanded ? 1.0 : 0.0
      self.dimView.isUserInteractionEnabled = isExpanded
      self.expandedBlurView.alpha = isExpanded ? 1.0 : 0.0
      self.expandedBlurView.transform = isExpanded ? .identity : expandedHiddenTransform
      self.expandedBlurView.isUserInteractionEnabled = isExpanded
      
      // Modal corner radius for 90% view
      self.expandedBlurView.layer.cornerRadius = isExpanded ? 32.0 : 0.0
      self.expandedBlurView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

      self.miniBlurView.alpha = isExpanded ? 0.0 : miniVisibleAlpha
      for view in miniViews where view !== self.miniBlurView {
        view.alpha = isExpanded ? 0.0 : 1.0
      }
      for view in miniViews {
        view.transform = isExpanded ? miniHiddenTransform : .identity
      }
      self.miniTextTapTarget.isUserInteractionEnabled = !isExpanded
    }

    guard animated else {
      applyFinalState()
      hasAppliedPresentationState = true
      return
    }

    if isExpanded {
      expandedBlurView.alpha = 0.0
      expandedBlurView.transform = expandedHiddenTransform
      expandedBlurView.isUserInteractionEnabled = true
      dimView.alpha = 0.0
      dimView.isUserInteractionEnabled = true
    } else {
      miniBlurView.alpha = 0.0
      for view in miniViews where view !== miniBlurView {
        view.alpha = 0.0
      }
      for view in miniViews {
        view.transform = miniHiddenTransform
      }
      miniTextTapTarget.isUserInteractionEnabled = true
    }

    UIView.animate(
      withDuration: 0.46,
      delay: 0.0,
      usingSpringWithDamping: 0.88,
      initialSpringVelocity: 0.16,
      options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
    ) {
      applyFinalState()
    }

    hasAppliedPresentationState = true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    dimView.frame = bounds
    
    // 90% Height Modal Layout
    let expandedH = bounds.height * 0.90
    expandedBlurView.frame = CGRect(x: 0, y: bounds.height - expandedH, width: bounds.width, height: expandedH)
    expandedContentView.frame = expandedBlurView.bounds

    let collapsedY = max(24.0, topInset + 60.0)
    let collapsedInset: CGFloat = 20.0
    let collapsedWidth = max(0.0, bounds.width - (collapsedInset * 2.0))
    let baseMiniFrame = CGRect(
      x: collapsedInset,
      y: collapsedY,
      width: collapsedWidth,
      height: Self.miniHeight
    )
    miniDragOffset = clampedMiniOffset(miniDragOffset, for: baseMiniFrame)
    let miniFrame = resolvedMiniFrame(from: baseMiniFrame)

    miniBlurView.frame = miniFrame
    miniProgressTrackView.frame = miniBlurView.bounds
    let miniProgressWidth = miniProgressTrackView.bounds.width * resolvedMiniProgress(for: state)
    let targetFillFrame = CGRect(
      x: 0.0,
      y: 0.0,
      width: max(0.0, min(miniProgressTrackView.bounds.width, miniProgressWidth)),
      height: miniProgressTrackView.bounds.height
    )
    if miniProgressFillView.frame != targetFillFrame {
      let fromFrame = miniProgressFillView.layer.presentation()?.frame ?? miniProgressFillView.frame
      miniProgressFillView.frame = targetFillFrame
      if abs(fromFrame.width - targetFillFrame.width) > 0.5 {
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = fromFrame.width
        animation.toValue = targetFillFrame.width
        animation.duration = 0.24
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        miniProgressFillView.layer.add(animation, forKey: "miniFluidWidth")
      }
    }
    miniProgressImageView.frame = miniProgressFillView.bounds
    miniProgressBlurView.frame = miniProgressFillView.bounds
    miniProgressTintView.frame = miniProgressFillView.bounds

    let artworkSide: CGFloat = 24.0
    miniArtworkView.frame = CGRect(
      x: miniFrame.minX + 12.0,
      y: miniFrame.minY + floor((miniFrame.height - artworkSide) * 0.5) - 1.0,
      width: artworkSide,
      height: artworkSide
    )
    miniArtworkFallbackView.frame = miniArtworkView.frame.insetBy(dx: 6.5, dy: 6.5)

    let controlSide: CGFloat = 24.0
    miniCloseButton.frame = CGRect(
      x: miniFrame.maxX - 10.0 - controlSide,
      y: miniFrame.midY - (controlSide * 0.5),
      width: controlSide,
      height: controlSide
    )
    miniPlayButton.frame = CGRect(
      x: miniCloseButton.frame.minX - 30.0,
      y: miniFrame.midY - (controlSide * 0.5),
      width: controlSide,
      height: controlSide
    )
    let textX = miniArtworkView.frame.maxX + 10.0
    let textRight = miniPlayButton.frame.minX - 10.0
    miniTitleLabel.frame = CGRect(
      x: textX,
      y: miniFrame.minY + 7.0,
      width: max(0.0, textRight - textX),
      height: 15.0
    )
    miniSubtitleLabel.frame = CGRect(
      x: textX,
      y: miniTitleLabel.frame.maxY + 1.0,
      width: miniTitleLabel.frame.width,
      height: 13.0
    )
    miniTextTapTarget.frame = CGRect(
      x: miniFrame.minX,
      y: miniFrame.minY,
      width: max(0.0, miniPlayButton.frame.minX - miniFrame.minX - 6.0),
      height: miniFrame.height
    )

    let safeTop = topInset + 16.0
    headerButton.frame = CGRect(x: 16.0, y: safeTop, width: 36.0, height: 36.0)
    expandedDismissButton.frame = CGRect(x: bounds.width - 52.0, y: safeTop, width: 36.0, height: 36.0)

    let scrollOffset = queueScrollView.contentOffset.y
    let scrollScale = max(0.4, 1.0 - (max(0, scrollOffset) / 300.0))
    let scrollAlpha = max(0.0, 1.0 - (max(0, scrollOffset) / 200.0))

    let horizontalInset: CGFloat = 32.0
    let baseCoverWidth = min(bounds.width - (horizontalInset * 2.0), 320.0)
    let coverWidth = baseCoverWidth * scrollScale
    coverView.frame = CGRect(
      x: floor((bounds.width - coverWidth) * 0.5),
      y: max(safeTop + 10.0, (safeTop + 52.0) - (scrollOffset * 0.5)),
      width: coverWidth,
      height: coverWidth
    )
    coverView.alpha = scrollAlpha
    coverFallbackView.frame = coverView.frame.insetBy(dx: 72.0 * scrollScale, dy: 72.0 * scrollScale)
    coverFallbackView.alpha = scrollAlpha

    expandedTitleLabel.frame = CGRect(
      x: horizontalInset,
      y: coverView.frame.maxY + 24.0,
      width: bounds.width - (horizontalInset * 2.0),
      height: 64.0
    )
    expandedTitleLabel.alpha = scrollAlpha
    expandedArtistLabel.frame = CGRect(
      x: horizontalInset,
      y: expandedTitleLabel.frame.maxY + 2.0,
      width: expandedTitleLabel.frame.width,
      height: 44.0
    )
    expandedArtistLabel.alpha = scrollAlpha

    currentTimeLabel.frame = CGRect(x: horizontalInset, y: expandedArtistLabel.frame.maxY + 18.0, width: 56.0, height: 16.0)
    durationLabel.frame = CGRect(x: bounds.width - horizontalInset - 56.0, y: currentTimeLabel.frame.minY, width: 56.0, height: 16.0)
    progressSlider.frame = CGRect(
      x: horizontalInset,
      y: currentTimeLabel.frame.maxY + 6.0,
      width: bounds.width - (horizontalInset * 2.0),
      height: 28.0
    )
    progressSlider.alpha = scrollAlpha
    
    downloadLabel.frame = .zero
    downloadLabel.isHidden = true

    let controlsY = progressSlider.frame.maxY + 12.0
    prevButton.frame = CGRect(x: bounds.midX - 108.0, y: controlsY, width: 40.0, height: 40.0)
    playButton.frame = CGRect(x: bounds.midX - 26.0, y: controlsY - 6.0, width: 52.0, height: 52.0)
    nextButton.frame = CGRect(x: bounds.midX + 68.0, y: controlsY, width: 40.0, height: 40.0)
    rateButton.frame = CGRect(x: bounds.midX - 28.0, y: playButton.frame.maxY + 16.0, width: 56.0, height: 30.0)
    
    prevButton.alpha = scrollAlpha
    playButton.alpha = scrollAlpha
    nextButton.alpha = scrollAlpha
    rateButton.alpha = scrollAlpha

    queueTitleLabel.frame = CGRect(
      x: horizontalInset,
      y: rateButton.frame.maxY + 24.0,
      width: bounds.width - (horizontalInset * 2.0),
      height: 18.0
    )
    let queueTop = queueTitleLabel.isHidden ? rateButton.frame.maxY + 12.0 : queueTitleLabel.frame.maxY + 12.0
    queueScrollView.frame = CGRect(
      x: horizontalInset,
      y: queueTop,
      width: bounds.width - (horizontalInset * 2.0),
      height: max(0.0, bounds.height - queueTop - 20.0)
    )
    queueStackView.frame = CGRect(x: 0.0, y: 0.0, width: queueScrollView.bounds.width, height: 0.0)
    var rowY: CGFloat = 0.0
    for row in queueRowViews {
      row.frame = CGRect(x: 0.0, y: rowY, width: queueScrollView.bounds.width, height: 62.0)
      rowY += 72.0
    }
    queueStackView.frame.size.height = rowY
    queueScrollView.contentSize = CGSize(width: queueScrollView.bounds.width, height: rowY)
  }

  private func playbackDetailText(for state: NativeMusicPlayerViewState, track: NativeMusicPlayerTrack) -> String {
    let effectiveDuration = max(state.durationMs, (track.durationSeconds ?? 0.0) * 1000.0)
    if effectiveDuration > 0.0 {
      if state.isPlaying || state.progressMs > 0.0 {
        return "\(Self.format(milliseconds: state.progressMs)) / \(Self.format(milliseconds: effectiveDuration))"
      }
      return Self.format(milliseconds: effectiveDuration)
    }
    return track.artist
  }

  private func mergedAvailableTracks(for state: NativeMusicPlayerViewState) -> [NativeMusicPlayerTrack] {
    var seen = Set<String>()
    var tracks: [NativeMusicPlayerTrack] = []
    for track in state.queue + state.library {
      if seen.insert(track.trackId).inserted {
        tracks.append(track)
      }
    }
    return tracks
  }

  private func queueHeaderTitle(
    for state: NativeMusicPlayerViewState,
    availableTracks: [NativeMusicPlayerTrack]
  ) -> String? {
    guard !availableTracks.isEmpty else { return nil }
    if !state.queue.isEmpty && !state.library.isEmpty {
      return "Queue & Local Music"
    }
    if !state.queue.isEmpty {
      return "Up Next"
    }
    return "Local Music & MP3"
  }

  private func applyPlaybackButtons(for state: NativeMusicPlayerViewState) {
    let miniSymbolName: String
    playButton.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)

    let effectiveDuration = max(state.durationMs, 1.0)
    let progress = CGFloat(max(0.0, min(1.0, state.progressMs / effectiveDuration)))
    playButton.setPlaybackState(
      isPlaying: state.isPlaying,
      progress: progress,
      level: state.isPlaying ? 0.20 : 0.0
    )
    miniSymbolName = state.isPlaying ? "pause.fill" : "play.fill"

    applyMiniControlButtonStyle(button: miniPlayButton, systemName: miniSymbolName)
  }

  private func resolvedMiniProgress(for state: NativeMusicPlayerViewState) -> CGFloat {
    let duration = max(state.durationMs, (state.currentTrack?.durationSeconds ?? 0.0) * 1000.0, 1.0)
    return CGFloat(max(0.0, min(1.0, state.progressMs / duration)))
  }

  private func rebuildQueueRows() {
    queueRowViews.forEach { $0.removeFromSuperview() }
    queueRowViews.removeAll()

    guard let currentTrackId = state.currentTrack?.trackId else { return }
    for track in mergedAvailableTracks(for: state) {
      let row = NativeMusicPlayerQueueRowView()
      row.applyTheme(theme)
      row.configure(track: track, isActive: track.trackId == currentTrackId)
      row.onSelectTrack = { [weak self] trackId in
        self?.onSelectTrack?(trackId)
      }
      queueScrollView.addSubview(row)
      queueRowViews.append(row)
    }
  }

  private func updateCoverImage(urlString: String?, directImage: UIImage? = nil) {
    coverImageTask?.cancel()
    coverView.image = nil
    miniArtworkView.image = nil
    miniProgressImageView.image = nil
    coverFallbackView.isHidden = false
    miniArtworkFallbackView.isHidden = false
    if let directImage {
      coverView.image = directImage
      miniArtworkView.image = directImage
      miniProgressImageView.image = directImage
      coverFallbackView.isHidden = true
      miniArtworkFallbackView.isHidden = true
      return
    }
    guard
      let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty,
      let url = URL(string: trimmed)
    else { return }

    coverImageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        self.coverView.image = image
        self.miniArtworkView.image = image
        self.miniProgressImageView.image = image
        self.coverFallbackView.isHidden = true
        self.miniArtworkFallbackView.isHidden = true
      }
    }
    coverImageTask?.resume()
  }

  private func configureControlButton(_ button: UIButton, systemName: String) {
    button.setImage(
      UIImage(systemName: systemName)?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)),
      for: .normal
    )
  }

  private static func rateTitle(_ rate: Double) -> String {
    let rounded = abs(rate.rounded(.toNearestOrAwayFromZero) - rate) < 0.05
    if rounded { return "\(Int(rate.rounded()))x" }
    return String(format: "%.1fx", rate)
  }

  private static func format(milliseconds: Double) -> String {
    guard milliseconds.isFinite, milliseconds > 0 else { return "0:00" }
    let totalSeconds = Int((milliseconds / 1000.0).rounded())
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
  }

  private static func sliderThumbImage(color: UIColor) -> UIImage? {
    let size = CGSize(width: 12.0, height: 12.0)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
      let rect = CGRect(origin: .zero, size: size)
      context.cgContext.setFillColor(color.cgColor)
      context.cgContext.fillEllipse(in: rect)
    }
  }

  private func resolvedMiniFrame(from baseFrame: CGRect) -> CGRect {
    let clampedOffset = clampedMiniOffset(miniDragOffset, for: baseFrame)
    return baseFrame.offsetBy(dx: clampedOffset.x, dy: clampedOffset.y)
  }

  private func clampedMiniOffset(_ proposedOffset: CGPoint, for baseFrame: CGRect) -> CGPoint {
    let minX = -baseFrame.minX + 12.0
    let maxX = bounds.width - baseFrame.maxX - 12.0
    let minY = -baseFrame.minY + max(12.0, topInset + 10.0)
    let maxY = bounds.height - baseFrame.maxY - 24.0
    return CGPoint(
      x: min(max(proposedOffset.x, minX), maxX),
      y: min(max(proposedOffset.y, minY), maxY)
    )
  }

  @objc private func handleTogglePlayback() {
    onTogglePlayback?()
  }

  @objc private func handleClose() {
    if state.isExpanded {
      onSetExpanded?(false)
    } else {
      onClose?()
    }
  }

  @objc private func handleExpand() {
    guard state.allowsExpansion else { return }
    onSetExpanded?(true)
  }

  @objc private func handleCollapse() {
    onSetExpanded?(false)
  }

  @objc private func handlePrev() {
    onPlayPrev?()
  }

  @objc private func handleNext() {
    onPlayNext?()
  }

  @objc private func handleRateToggle() {
    onPlaybackRateToggle?()
  }

  @objc private func handleSliderChanged() {
    pendingSeekValue = progressSlider.value
    let duration = max(state.durationMs, 1.0)
    let current = Double(progressSlider.value) * duration
    currentTimeLabel.text = Self.format(milliseconds: current)
  }

  @objc private func handleSliderCommit() {
    guard let value = pendingSeekValue else { return }
    pendingSeekValue = nil
    let duration = max(state.durationMs, 1.0)
    onSeek?(Double(value) * duration)
  }

  @objc private func handleMiniPan(_ gesture: UIPanGestureRecognizer) {
    guard !state.isExpanded, !isHidden else { return }
    let collapsedY = max(24.0, topInset + 60.0)
    let collapsedInset: CGFloat = 20.0
    let collapsedWidth = max(0.0, bounds.width - (collapsedInset * 2.0))
    let baseMiniFrame = CGRect(
      x: collapsedInset,
      y: collapsedY,
      width: collapsedWidth,
      height: Self.miniHeight
    )

    switch gesture.state {
    case .began:
      miniDragStartOffset = miniDragOffset
    case .changed, .ended:
      let translation = gesture.translation(in: self)
      miniDragOffset = clampedMiniOffset(
        CGPoint(
          x: miniDragStartOffset.x + translation.x,
          y: miniDragStartOffset.y + translation.y
        ),
        for: baseMiniFrame
      )
      setNeedsLayout()
    default:
      break
    }
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === miniPanGesture else { return true }
    return !state.isExpanded && !isHidden
  }
}

extension NativeMusicPlayerBannerView: UIScrollViewDelegate {
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    if state.isExpanded {
      setNeedsLayout()
    }
  }
}
