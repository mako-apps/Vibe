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
    let downloadingTracks = payload["downloadingTracks"] as? [String: Double] ?? [:]
    let currentTrackId = currentTrack?.trackId
    return NativeMusicPlayerViewState(
      currentTrack: currentTrack,
      queue: queue,
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

  static func from(voiceSnapshot: VoiceBubblePlaybackSnapshot) -> NativeMusicPlayerViewState {
    guard let messageId = voiceSnapshot.messageId else { return .empty }
    let durationMs = max(0.0, voiceSnapshot.duration * 1000.0)
    let progressMs = durationMs * max(0.0, min(1.0, Double(voiceSnapshot.progress)))
    let track = NativeMusicPlayerTrack(
      trackId: messageId,
      videoId: nil,
      id: nil,
      source: "chat-voice",
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
      queue: [],
      isPlaying: voiceSnapshot.isPlaying,
      isExpanded: false,
      progressMs: progressMs,
      durationMs: durationMs,
      playbackRate: 1.0,
      currentDownloadProgress: voiceSnapshot.isDownloading ? Double(voiceSnapshot.downloadProgress ?? 0.0) : nil,
      artworkImage: voiceSnapshot.artwork,
      allowsExpansion: false
    )
  }
}

private final class NativeMusicPlayerQueueRowView: UIControl {
  private let artworkView = UIImageView()
  private let artworkFallbackView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let activeIndicator = UIView()
  private let textStack = UIStackView()
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

    textStack.axis = .vertical
    textStack.alignment = .fill
    textStack.spacing = 2.0
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(subtitleLabel)
    addSubview(textStack)

    activeIndicator.layer.cornerCurve = .continuous
    activeIndicator.layer.cornerRadius = 4.0
    addSubview(activeIndicator)

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func applyTheme(_ theme: NativeMusicPlayerTheme) {
    titleLabel.textColor = theme.text
    subtitleLabel.textColor = theme.secondaryText
    artworkFallbackView.tintColor = theme.secondaryText
    activeIndicator.backgroundColor = theme.primary
  }

  func configure(track: NativeMusicPlayerTrack, isActive: Bool) {
    trackId = track.trackId
    titleLabel.text = track.title
    subtitleLabel.text = track.artist
    activeIndicator.isHidden = !isActive
    backgroundColor = isActive
      ? UIColor.black.withAlphaComponent(0.12)
      : UIColor.black.withAlphaComponent(0.04)
    loadImage(urlString: track.cover)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset: CGFloat = 10.0
    let artworkSide = bounds.height - (inset * 2.0)
    artworkView.frame = CGRect(x: inset, y: inset, width: artworkSide, height: artworkSide)
    artworkFallbackView.frame = artworkView.frame.insetBy(dx: 9.0, dy: 9.0)
    activeIndicator.frame = CGRect(
      x: bounds.width - inset - 8.0,
      y: floor((bounds.height - 8.0) * 0.5),
      width: 8.0,
      height: 8.0
    )
    let textX = artworkView.frame.maxX + 12.0
    textStack.frame = CGRect(
      x: textX,
      y: floor((bounds.height - 34.0) * 0.5),
      width: max(0.0, activeIndicator.frame.minX - 12.0 - textX),
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

final class NativeMusicPlayerBannerView: UIView {
  static let miniHeight: CGFloat = 52.0

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
  private let miniPlayButton = VoicePlayProgressView()
  private let miniCloseButton = UIButton(type: .system)
  private let miniTextTapTarget = UIControl()

  private var theme = NativeMusicPlayerTheme()
  private var state = NativeMusicPlayerViewState.empty
  private var topInset: CGFloat = 0.0
  private var coverImageTask: URLSessionDataTask?
  private var queueRowViews: [NativeMusicPlayerQueueRowView] = []
  private var pendingSeekValue: Float?

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

    miniTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    miniTitleLabel.numberOfLines = 1
    addSubview(miniTitleLabel)

    miniSubtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    miniSubtitleLabel.numberOfLines = 1
    addSubview(miniSubtitleLabel)

    miniPlayButton.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTogglePlayback)))
    addSubview(miniPlayButton)

    miniCloseButton.setImage(
      UIImage(systemName: "xmark")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)),
      for: .normal
    )
    miniCloseButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    addSubview(miniCloseButton)

    miniTextTapTarget.addTarget(self, action: #selector(handleExpand), for: .touchUpInside)
    addSubview(miniTextTapTarget)

    isHidden = true
    applyTheme(theme)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func applyTheme(_ theme: NativeMusicPlayerTheme) {
    self.theme = theme
    let blurStyle: UIBlurEffect.Style = theme.isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight
    let miniBlurStyle: UIBlurEffect.Style = theme.isDark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight
    expandedBlurView.effect = UIBlurEffect(style: blurStyle)
    miniBlurView.effect = UIBlurEffect(style: miniBlurStyle)
    expandedBlurView.contentView.backgroundColor = theme.surface.withAlphaComponent(theme.isDark ? 0.16 : 0.08)
    miniBlurView.contentView.backgroundColor = theme.surface.withAlphaComponent(theme.isDark ? 0.18 : 0.10)

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

    miniBlurView.layer.borderWidth = 0.75
    miniBlurView.layer.borderColor = theme.text.withAlphaComponent(theme.isDark ? 0.14 : 0.08).cgColor
    miniArtworkView.backgroundColor = coverView.backgroundColor
    miniArtworkFallbackView.tintColor = theme.secondaryText
    miniTitleLabel.textColor = theme.text
    miniSubtitleLabel.textColor = theme.text.withAlphaComponent(secondaryAlpha)
    miniCloseButton.tintColor = theme.secondaryText

    progressSlider.minimumTrackTintColor = theme.primary
    progressSlider.maximumTrackTintColor = theme.text.withAlphaComponent(theme.isDark ? 0.16 : 0.10)
    let thumbImage = Self.sliderThumbImage(color: theme.primary)
    progressSlider.setThumbImage(thumbImage, for: .normal)
    progressSlider.setThumbImage(thumbImage, for: .highlighted)

    miniPlayButton.applyStyle(
      fillColor: UIColor(white: 1.0, alpha: 0.96),
      iconTint: theme.primary,
      ringTint: theme.primary.withAlphaComponent(0.82)
    )
    playButton.applyStyle(
      fillColor: UIColor(white: 1.0, alpha: 0.96),
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

  func applyVoiceSnapshot(_ snapshot: VoiceBubblePlaybackSnapshot) {
    applyState(NativeMusicPlayerViewState.from(voiceSnapshot: snapshot))
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
    state = nextState
    let shouldShow = nextState.currentTrack != nil
    isHidden = !shouldShow
    guard shouldShow, let track = nextState.currentTrack else { return }

    miniTitleLabel.text = track.title
    expandedTitleLabel.text = track.title
    miniSubtitleLabel.text = miniSubtitle(for: nextState, track: track)
    expandedArtistLabel.text = track.artist
    currentTimeLabel.text = Self.format(milliseconds: nextState.progressMs)
    durationLabel.text = Self.format(milliseconds: max(nextState.durationMs, (track.durationSeconds ?? 0.0) * 1000.0))
    rateButton.setTitle(Self.rateTitle(nextState.playbackRate), for: .normal)
    queueTitleLabel.text = nextState.queue.isEmpty ? nil : "Up Next"
    queueTitleLabel.isHidden = nextState.queue.isEmpty

    updateCoverImage(urlString: track.cover, directImage: nextState.artworkImage)
    applyPlaybackButtons(for: nextState)
    downloadLabel.isHidden = nextState.currentDownloadProgress == nil
    if let progress = nextState.currentDownloadProgress {
      downloadLabel.text = progress > 0.0 ? "Downloading \(Int(progress * 100.0))%" : "Downloading"
    } else {
      downloadLabel.text = nil
    }

    let durationMs = max(nextState.durationMs, 1.0)
    if !progressSlider.isTracking {
      progressSlider.value = Float(max(0.0, min(1.0, nextState.progressMs / durationMs)))
    }

    let isExpanded = nextState.allowsExpansion && nextState.isExpanded
    if isExpanded {
      dimView.alpha = 1.0
      expandedBlurView.alpha = 1.0
      miniBlurView.alpha = 0.0
      miniArtworkView.alpha = 0.0
      miniArtworkFallbackView.alpha = 0.0
      miniTitleLabel.alpha = 0.0
      miniSubtitleLabel.alpha = 0.0
      miniPlayButton.alpha = 0.0
      miniCloseButton.alpha = 0.0
      miniTextTapTarget.isUserInteractionEnabled = false
    } else {
      dimView.alpha = 0.0
      expandedBlurView.alpha = 0.0
      miniBlurView.alpha = 1.0
      miniArtworkView.alpha = 1.0
      miniArtworkFallbackView.alpha = 1.0
      miniTitleLabel.alpha = 1.0
      miniSubtitleLabel.alpha = 1.0
      miniPlayButton.alpha = 1.0
      miniCloseButton.alpha = 1.0
      miniTextTapTarget.isUserInteractionEnabled = nextState.allowsExpansion
    }

    rebuildQueueRows()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    dimView.frame = bounds
    expandedBlurView.frame = bounds
    expandedContentView.frame = bounds

    let collapsedY = max(8.0, topInset + 8.0)
    let collapsedInset: CGFloat = 20.0
    let collapsedWidth = max(0.0, bounds.width - (collapsedInset * 2.0))
    let miniFrame = CGRect(
      x: collapsedInset,
      y: collapsedY,
      width: collapsedWidth,
      height: Self.miniHeight
    )

    miniBlurView.frame = miniFrame
    let artworkSide: CGFloat = 30.0
    miniArtworkView.frame = CGRect(x: miniFrame.minX + 11.0, y: miniFrame.minY + 11.0, width: artworkSide, height: artworkSide)
    miniArtworkFallbackView.frame = miniArtworkView.frame.insetBy(dx: 8.0, dy: 8.0)
    miniCloseButton.frame = CGRect(x: miniFrame.maxX - 36.0, y: miniFrame.minY + 10.0, width: 24.0, height: 24.0)
    miniPlayButton.frame = CGRect(x: miniCloseButton.frame.minX - 40.0, y: miniFrame.minY + 10.0, width: 32.0, height: 32.0)
    let textX = miniArtworkView.frame.maxX + 10.0
    let textRight = miniPlayButton.frame.minX - 10.0
    miniTitleLabel.frame = CGRect(x: textX, y: miniFrame.minY + 9.0, width: max(0.0, textRight - textX), height: 17.0)
    miniSubtitleLabel.frame = CGRect(x: textX, y: miniTitleLabel.frame.maxY + 2.0, width: miniTitleLabel.frame.width, height: 15.0)
    miniTextTapTarget.frame = CGRect(
      x: miniFrame.minX,
      y: miniFrame.minY,
      width: max(0.0, miniPlayButton.frame.minX - miniFrame.minX - 6.0),
      height: miniFrame.height
    )

    let safeTop = topInset + 16.0
    headerButton.frame = CGRect(x: 16.0, y: safeTop, width: 36.0, height: 36.0)
    expandedDismissButton.frame = CGRect(x: bounds.width - 52.0, y: safeTop, width: 36.0, height: 36.0)

    let horizontalInset: CGFloat = 32.0
    let coverWidth = min(bounds.width - (horizontalInset * 2.0), 320.0)
    coverView.frame = CGRect(
      x: floor((bounds.width - coverWidth) * 0.5),
      y: safeTop + 52.0,
      width: coverWidth,
      height: coverWidth
    )
    coverFallbackView.frame = coverView.frame.insetBy(dx: 72.0, dy: 72.0)

    expandedTitleLabel.frame = CGRect(
      x: horizontalInset,
      y: coverView.frame.maxY + 24.0,
      width: bounds.width - (horizontalInset * 2.0),
      height: 64.0
    )
    expandedArtistLabel.frame = CGRect(
      x: horizontalInset,
      y: expandedTitleLabel.frame.maxY + 2.0,
      width: expandedTitleLabel.frame.width,
      height: 44.0
    )

    currentTimeLabel.frame = CGRect(x: horizontalInset, y: expandedArtistLabel.frame.maxY + 18.0, width: 56.0, height: 16.0)
    durationLabel.frame = CGRect(x: bounds.width - horizontalInset - 56.0, y: currentTimeLabel.frame.minY, width: 56.0, height: 16.0)
    progressSlider.frame = CGRect(
      x: horizontalInset,
      y: currentTimeLabel.frame.maxY + 6.0,
      width: bounds.width - (horizontalInset * 2.0),
      height: 28.0
    )
    downloadLabel.frame = CGRect(
      x: horizontalInset,
      y: progressSlider.frame.maxY + 6.0,
      width: bounds.width - (horizontalInset * 2.0),
      height: 18.0
    )

    let controlsY = downloadLabel.frame.maxY + 22.0
    prevButton.frame = CGRect(x: bounds.midX - 108.0, y: controlsY, width: 40.0, height: 40.0)
    playButton.frame = CGRect(x: bounds.midX - 26.0, y: controlsY - 6.0, width: 52.0, height: 52.0)
    nextButton.frame = CGRect(x: bounds.midX + 68.0, y: controlsY, width: 40.0, height: 40.0)
    rateButton.frame = CGRect(x: bounds.midX - 28.0, y: playButton.frame.maxY + 16.0, width: 56.0, height: 30.0)

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

  private func miniSubtitle(for state: NativeMusicPlayerViewState, track: NativeMusicPlayerTrack) -> String {
    if let progress = state.currentDownloadProgress {
      return progress > 0.0 ? "Downloading \(Int(progress * 100.0))%" : "Downloading"
    }
    let effectiveDuration = max(state.durationMs, (track.durationSeconds ?? 0.0) * 1000.0)
    if effectiveDuration > 0.0 {
      return "\(Self.format(milliseconds: state.progressMs)) / \(Self.format(milliseconds: effectiveDuration))"
    }
    return track.artist
  }

  private func applyPlaybackButtons(for state: NativeMusicPlayerViewState) {
    if let progress = state.currentDownloadProgress {
      miniPlayButton.setUploadState(isUploading: false, progress: nil)
      playButton.setUploadState(isUploading: false, progress: nil)
      miniPlayButton.setDownloadState(needsDownload: true, isDownloading: true, progress: progress)
      playButton.setDownloadState(needsDownload: true, isDownloading: true, progress: progress)
      return
    }

    miniPlayButton.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
    playButton.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)

    let effectiveDuration = max(state.durationMs, 1.0)
    let progress = CGFloat(max(0.0, min(1.0, state.progressMs / effectiveDuration)))
    miniPlayButton.setPlaybackState(isPlaying: state.isPlaying, progress: progress, level: state.isPlaying ? 0.20 : 0.0)
    playButton.setPlaybackState(isPlaying: state.isPlaying, progress: progress, level: state.isPlaying ? 0.20 : 0.0)
  }

  private func rebuildQueueRows() {
    queueRowViews.forEach { $0.removeFromSuperview() }
    queueRowViews.removeAll()

    guard !state.queue.isEmpty, let currentTrackId = state.currentTrack?.trackId else { return }
    for track in state.queue {
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
    coverFallbackView.isHidden = false
    miniArtworkFallbackView.isHidden = false
    if let directImage {
      coverView.image = directImage
      miniArtworkView.image = directImage
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

  @objc private func handleTogglePlayback() {
    onTogglePlayback?()
  }

  @objc private func handleClose() {
    onClose?()
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
}
