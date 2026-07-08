import SwiftUI
import AVFoundation
import AVKit
import OSLog
import QuickLook
import UIKit

private let chatListUITraceLogger = Logger(
  subsystem: "com.mohammadshayani.vibe.native",
  category: "UITrace"
)

private func chatListUITrace(_ message: String, fault: Bool = false) {
  if fault {
    chatListUITraceLogger.fault("\(message, privacy: .public)")
    NSLog("[VibeUITrace][fault] %@", message)
  } else {
    VibeDebugLog.notice(logger: chatListUITraceLogger, message)
    VibeDebugLog.log("[VibeUITrace] %@", message)
  }
}

private let chatListMediaVerboseDebugLogs = false
private let chatListInlineVideoVerboseDebugLogs = false
private let chatListEngineBindingQueue = DispatchQueue(
  label: "com.vibe.chatlist.engine-binding",
  qos: .utility
)

public final class NativeEventDispatcher {
  public var handler: (([String: Any]) -> Void)?

  public init(handler: (([String: Any]) -> Void)? = nil) {
    self.handler = handler
  }

  public func callAsFunction(_ payload: [String: Any]) {
    handler?(payload)
  }
}

private func chatListDebugLog(_ enabled: Bool, _ format: String, _ args: CVarArg...) {
  guard enabled else { return }
  withVaList(args) { pointer in
    NSLogv(format, pointer)
  }
}

func normalizedWallpaperSampleRect(_ rect: CGRect, containerSize: CGSize) -> CGRect {
  guard containerSize.width > 1.0, containerSize.height > 1.0 else {
    return CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
  }

  let clampedX = max(0.0, min(rect.minX, containerSize.width))
  let clampedY = max(0.0, min(rect.minY, containerSize.height))
  let remainingWidth = max(1.0, containerSize.width - clampedX)
  let remainingHeight = max(1.0, containerSize.height - clampedY)
  let clampedWidth = max(1.0, min(rect.width, remainingWidth))
  let clampedHeight = max(1.0, min(rect.height, remainingHeight))

  return CGRect(
    x: clampedX / containerSize.width,
    y: clampedY / containerSize.height,
    width: clampedWidth / containerSize.width,
    height: clampedHeight / containerSize.height
  )
}

private func blendedWallpaperEdgeTint(color: UIColor, isDark: Bool) -> UIColor {
  let target = isDark ? UIColor.black : UIColor.white
  var cr: CGFloat = 0.0
  var cg: CGFloat = 0.0
  var cb: CGFloat = 0.0
  var ca: CGFloat = 0.0
  var tr: CGFloat = 0.0
  var tg: CGFloat = 0.0
  var tb: CGFloat = 0.0
  var ta: CGFloat = 0.0
  guard color.getRed(&cr, green: &cg, blue: &cb, alpha: &ca),
    target.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
  else {
    return color
  }
  let mix: CGFloat = isDark ? 0.35 : 0.24
  let inv = 1.0 - mix
  return UIColor(
    red: (cr * inv) + (tr * mix),
    green: (cg * inv) + (tg * mix),
    blue: (cb * inv) + (tb * mix),
    alpha: 1.0
  )
}

private func chatListInterpolatedColor(
  from: UIColor,
  to: UIColor,
  progress: CGFloat
) -> UIColor {
  let amount = max(0.0, min(1.0, progress))
  var fr: CGFloat = 0.0
  var fg: CGFloat = 0.0
  var fb: CGFloat = 0.0
  var fa: CGFloat = 0.0
  var tr: CGFloat = 0.0
  var tg: CGFloat = 0.0
  var tb: CGFloat = 0.0
  var ta: CGFloat = 0.0
  guard from.getRed(&fr, green: &fg, blue: &fb, alpha: &fa),
    to.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
  else {
    return from
  }
  let inverse = 1.0 - amount
  return UIColor(
    red: (fr * inverse) + (tr * amount),
    green: (fg * inverse) + (tg * amount),
    blue: (fb * inverse) + (tb * amount),
    alpha: (fa * inverse) + (ta * amount)
  )
}

private func chatListEvenGradientLocations(count: Int) -> [NSNumber] {
  guard count > 1 else { return [0.0] }
  return (0..<count).map { index in
    NSNumber(value: Double(index) / Double(count - 1))
  }
}

enum ChatWallpaperEdge {
  case top
  case bottom
}

final class ChatWallpaperEdgeEffectView: UIView {
  private let edge: ChatWallpaperEdge
  private let sampleLayer = CALayer()
  private let tintLayer = CAGradientLayer()
  private let sampleMaskLayer = CAGradientLayer()
  private let blurView = UIVisualEffectView(effect: nil)
  private let blurMaskLayer = CAGradientLayer()
  private var appearance = ChatListAppearance.fallback
  private var sampleRect: CGRect = .zero
  private var containerSize: CGSize = .zero
  private var backdropSnapshot: CGImage?
  private var edgeAlpha: CGFloat = 0.0
  private var blurEnabled = false

  init(edge: ChatWallpaperEdge) {
    self.edge = edge
    super.init(frame: .zero)

    isUserInteractionEnabled = false
    backgroundColor = .clear
    clipsToBounds = true

    sampleLayer.contentsGravity = .resize
    sampleLayer.contentsScale = UIScreen.main.scale
    sampleLayer.mask = sampleMaskLayer
    layer.addSublayer(sampleLayer)

    blurView.isUserInteractionEnabled = false
    blurView.clipsToBounds = true
    blurView.layer.mask = blurMaskLayer
    addSubview(blurView)

    layer.addSublayer(tintLayer)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func applyAppearance(_ appearance: ChatListAppearance) {
    self.appearance = appearance

    let isDark = appearance.isDark
    let topBase = appearance.wallpaperGradient.first ?? (isDark ? UIColor.black : UIColor.white)
    let bottomBase = appearance.wallpaperGradient.last ?? topBase
    let tintBase = edge == .top ? topBase : bottomBase
    let tintColor = blendedWallpaperEdgeTint(color: tintBase, isDark: isDark)
    let tintAlpha: CGFloat
    switch edge {
    case .top:
      tintAlpha = isDark ? 0.18 : 0.10
    case .bottom:
      tintAlpha = isDark ? 0.12 : 0.06
    }

    tintLayer.colors =
      edge == .top
      ? [tintColor.withAlphaComponent(tintAlpha).cgColor, UIColor.clear.cgColor]
      : [UIColor.clear.cgColor, tintColor.withAlphaComponent(tintAlpha).cgColor]
    tintLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    tintLayer.endPoint = CGPoint(x: 0.5, y: 1.0)

    blurView.effect = UIBlurEffect(
      style: isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight)
    setNeedsLayout()
  }

  func updateBackdrop(
    snapshot: CGImage?,
    containerSize: CGSize,
    sampleRect: CGRect,
    alpha: CGFloat,
    blur: Bool
  ) {
    backdropSnapshot = snapshot
    self.containerSize = containerSize
    self.sampleRect = sampleRect
    edgeAlpha = alpha
    blurEnabled = blur
    applyBackdrop()
  }

  private func applyBackdrop() {
    let hasBackdrop =
      backdropSnapshot != nil
      && containerSize.width > 1.0
      && containerSize.height > 1.0
      && edgeAlpha > 0.001
      && !isHidden

    sampleLayer.isHidden = !hasBackdrop
    tintLayer.isHidden = !hasBackdrop
    blurView.isHidden = !hasBackdrop || !blurEnabled
    alpha = hasBackdrop ? 1.0 : 0.0

    guard hasBackdrop, let snapshot = backdropSnapshot else {
      sampleLayer.contents = nil
      return
    }

    sampleLayer.contents = snapshot
    sampleLayer.contentsRect = normalizedWallpaperSampleRect(sampleRect, containerSize: containerSize)
    let sampleOpacity: CGFloat
    let tintOpacity: CGFloat
    let blurAlpha: CGFloat
    switch edge {
    case .top:
      sampleOpacity = min(0.05, edgeAlpha * 0.14)
      tintOpacity = min(0.12, edgeAlpha * 0.42)
      blurAlpha = blurEnabled ? min(0.18, edgeAlpha * 0.52) : 0.0
    case .bottom:
      sampleOpacity = min(0.03, edgeAlpha * 0.10)
      tintOpacity = min(0.08, edgeAlpha * 0.28)
      blurAlpha = blurEnabled ? min(0.10, edgeAlpha * 0.20) : 0.0
    }
    sampleLayer.opacity = Float(sampleOpacity)
    tintLayer.opacity = Float(tintOpacity)
    blurView.alpha = blurAlpha
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    sampleLayer.frame = bounds
    tintLayer.frame = bounds
    blurView.frame = bounds

    let maskColors: [CGColor]
    switch edge {
    case .top:
      maskColors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
      sampleMaskLayer.locations = [0.0, 0.10, 0.46]
      blurMaskLayer.locations = [0.0, 0.14, 0.56]
    case .bottom:
      maskColors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
      sampleMaskLayer.locations = [0.58, 0.90, 1.0]
      blurMaskLayer.locations = [0.54, 0.88, 1.0]
    }

    sampleMaskLayer.frame = bounds
    sampleMaskLayer.colors = maskColors
    sampleMaskLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    sampleMaskLayer.endPoint = CGPoint(x: 0.5, y: 1.0)

    blurMaskLayer.frame = bounds
    blurMaskLayer.colors = maskColors
    blurMaskLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    blurMaskLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
  }
}

private final class ChatListDocumentPreviewDataSource: NSObject, QLPreviewControllerDataSource {
  private let previewURL: URL

  init(previewURL: URL) {
    self.previewURL = previewURL
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
    -> QLPreviewItem
  {
    previewURL as NSURL
  }
}

private final class ChatListTextPreviewController: UIViewController {
  private let previewTitle: String
  private let textContent: String
  private let textView = UITextView()

  init(title: String, text: String) {
    self.previewTitle = title
    self.textContent = text
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = previewTitle

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.alwaysBounceVertical = true
    textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    textView.text = textContent

    view.addSubview(textView)
    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.topAnchor.constraint(equalTo: view.topAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
}

private func formatNativeMusicPlayerTime(_ seconds: Double) -> String {
  guard seconds.isFinite, seconds > 0 else { return "0:00" }
  let total = max(0, Int(seconds.rounded()))
  return String(format: "%d:%02d", total / 60, total % 60)
}

private final class ChatNativeMusicPlayerBar: UIView {
  static let preferredHeight: CGFloat = 68.0

  private let blurView = UIVisualEffectView(effect: nil)
  private let artworkView = UIImageView()
  private let artworkPlaceholderView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let playbackButton = VoicePlayProgressView()
  private let closeButton = UIButton(type: .system)
  private let progressTrackView = UIView()
  private let progressFillView = UIView()
  private var snapshot = VoiceBubblePlaybackSnapshot.empty

  var onTogglePlayback: (() -> Void)?
  var onClose: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = false
    layer.cornerCurve = .continuous
    layer.cornerRadius = 20.0

    blurView.isUserInteractionEnabled = false
    blurView.clipsToBounds = true
    blurView.layer.cornerCurve = .continuous
    blurView.layer.cornerRadius = 20.0
    addSubview(blurView)

    artworkView.contentMode = .scaleAspectFill
    artworkView.clipsToBounds = true
    artworkView.layer.cornerCurve = .continuous
    artworkView.layer.cornerRadius = 12.0
    addSubview(artworkView)

    artworkPlaceholderView.contentMode = .scaleAspectFit
    artworkPlaceholderView.image = UIImage(systemName: "music.note")
    addSubview(artworkPlaceholderView)

    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    titleLabel.numberOfLines = 1
    addSubview(titleLabel)

    subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    subtitleLabel.numberOfLines = 1
    addSubview(subtitleLabel)

    playbackButton.isUserInteractionEnabled = true
    playbackButton.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTogglePlayback)))
    addSubview(playbackButton)

    closeButton.tintColor = .white
    closeButton.setImage(
      UIImage(systemName: "xmark")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)),
      for: .normal
    )
    closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    addSubview(closeButton)

    progressTrackView.isUserInteractionEnabled = false
    progressTrackView.layer.cornerCurve = .continuous
    progressTrackView.layer.cornerRadius = 1.5
    addSubview(progressTrackView)

    progressFillView.isUserInteractionEnabled = false
    progressFillView.layer.cornerCurve = .continuous
    progressFillView.layer.cornerRadius = 1.5
    addSubview(progressFillView)

    isHidden = true
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func applyAppearance(_ appearance: ChatListAppearance) {
    let isDark = appearance.isDark
    blurView.effect = UIBlurEffect(
      style: isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight)
    backgroundColor = UIColor.clear
    artworkView.backgroundColor = UIColor(white: isDark ? 1.0 : 0.0, alpha: isDark ? 0.08 : 0.06)
    artworkPlaceholderView.tintColor = UIColor(white: isDark ? 1.0 : 0.0, alpha: 0.48)
    titleLabel.textColor = isDark ? .white : UIColor(white: 0.08, alpha: 1.0)
    subtitleLabel.textColor = isDark ? UIColor(white: 1.0, alpha: 0.68) : UIColor(white: 0.16, alpha: 0.72)
    progressTrackView.backgroundColor = UIColor(white: isDark ? 1.0 : 0.0, alpha: isDark ? 0.12 : 0.10)
    progressFillView.backgroundColor = appearance.bubbleMeGradient.first ?? appearance.bubbleThemColor
    playbackButton.applyStyle(
      fillColor: UIColor(white: 1.0, alpha: 0.96),
      iconTint: appearance.bubbleMeGradient.first ?? UIColor.systemBlue,
      ringTint: (appearance.bubbleMeGradient.first ?? UIColor.systemBlue).withAlphaComponent(0.8)
    )
  }

  func applySnapshot(_ snapshot: VoiceBubblePlaybackSnapshot) {
    self.snapshot = snapshot
    let shouldShow = snapshot.presentsGlobalPlayer && snapshot.messageId != nil
    isHidden = !shouldShow
    guard shouldShow else { return }

    artworkView.image = snapshot.artwork
    artworkPlaceholderView.isHidden = snapshot.artwork != nil
    titleLabel.text = snapshot.title ?? "Audio"

    let newSubtitle: String
    if snapshot.isDownloading {
      let percent = Int(round(Double(snapshot.downloadProgress ?? 0.0) * 100.0))
      newSubtitle = percent > 0 ? "Downloading \(percent)%" : "Downloading"
    } else if snapshot.duration > 0.0 {
      let current = snapshot.duration * Double(snapshot.progress)
      newSubtitle = "\(formatNativeMusicPlayerTime(current)) / \(formatNativeMusicPlayerTime(snapshot.duration))"
    } else {
      newSubtitle = snapshot.subtitle ?? ""
    }
    if subtitleLabel.text != newSubtitle {
      subtitleLabel.text = newSubtitle
    }

    playbackButton.setArtworkImage(nil)
    playbackButton.setUploadState(isUploading: false, progress: nil)
    if snapshot.isDownloading {
      playbackButton.setDownloadState(
        needsDownload: true,
        isDownloading: true,
        progress: snapshot.downloadProgress
      )
    } else {
      playbackButton.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
      playbackButton.setPlaybackState(
        isPlaying: snapshot.isPlaying,
        progress: snapshot.progress,
        level: snapshot.isPlaying ? 0.22 : 0.0
      )
    }

    if bounds.width > 0 {
      let progressWidth = max(0.0, closeButton.frame.minX - 10.0 - titleLabel.frame.minX)
      progressFillView.frame.size.width = progressWidth * max(0.0, min(1.0, snapshot.progress))
      let hideProgress = snapshot.isDownloading || snapshot.duration <= 0.0
      if progressTrackView.isHidden != hideProgress {
        progressTrackView.isHidden = hideProgress
        progressFillView.isHidden = hideProgress
      }
    } else {
      setNeedsLayout()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    blurView.frame = bounds

    let inset: CGFloat = 10.0
    let artworkSide: CGFloat = bounds.height - (inset * 2.0)
    artworkView.frame = CGRect(x: inset, y: inset, width: artworkSide, height: artworkSide)
    artworkPlaceholderView.frame = artworkView.frame.insetBy(dx: 10.0, dy: 10.0)

    let closeSide: CGFloat = 28.0
    closeButton.frame = CGRect(
      x: bounds.width - inset - closeSide,
      y: floor((bounds.height - closeSide) * 0.5),
      width: closeSide,
      height: closeSide
    )

    let playbackSide: CGFloat = 34.0
    playbackButton.frame = CGRect(
      x: closeButton.frame.minX - 8.0 - playbackSide,
      y: floor((bounds.height - playbackSide) * 0.5),
      width: playbackSide,
      height: playbackSide
    )

    let textX = artworkView.frame.maxX + 10.0
    let textRight = playbackButton.frame.minX - 10.0
    let textWidth = max(0.0, textRight - textX)
    titleLabel.frame = CGRect(x: textX, y: inset + 8.0, width: textWidth, height: 18.0)
    subtitleLabel.frame = CGRect(x: textX, y: titleLabel.frame.maxY + 4.0, width: textWidth, height: 16.0)

    let progressX = textX
    let progressY = bounds.height - 10.0
    let progressWidth = max(0.0, closeButton.frame.minX - 10.0 - progressX)
    progressTrackView.frame = CGRect(x: progressX, y: progressY, width: progressWidth, height: 3.0)
    progressFillView.frame = CGRect(
      x: progressX,
      y: progressY,
      width: progressWidth * max(0.0, min(1.0, snapshot.progress)),
      height: 3.0
    )
    progressTrackView.isHidden = snapshot.isDownloading || snapshot.duration <= 0.0
    progressFillView.isHidden = progressTrackView.isHidden
  }

  @objc private func handleTogglePlayback() {
    onTogglePlayback?()
  }

  @objc private func handleClose() {
    onClose?()
  }
}

private let chatListSendVerticalTiming = CAMediaTimingFunction(
  controlPoints: Float(0.19919472913616398),
  Float(0.010644531250000006),
  Float(0.27920937042459737),
  Float(0.91025390625)
)
private let chatReactionDebugLogs = true
private let chatGapDebugOverlayEnabled = false

public final class ChatListView: UIView, UICollectionViewDataSource,
  UICollectionViewDelegateFlowLayout
{
  public var onViewportChanged = NativeEventDispatcher()
  public var onNativeEvent = NativeEventDispatcher()

  @objc public var surfaceId: String = "" {
    didSet {
      if !surfaceId.isEmpty {
        ChatListRegistry.shared.register(surfaceId: surfaceId, view: self)
      }
    }
  }

  private let flowLayout: ChatCollectionFlowLayout
  let collectionView: UICollectionView
  private let wallpaperLayer = CAGradientLayer()
  private let wallpaperPatternLayer = CAGradientLayer()
  private let wallpaperPatternMaskLayer = CALayer()
  private let wallpaperContainerView = UIView()
  private let scrollToneOverlay = UIView()
  private let scrollToneTopView = ChatWallpaperEdgeEffectView(edge: .top)
  private let scrollToneBottomView = ChatWallpaperEdgeEffectView(edge: .bottom)
  private let gapDebugOverlay = UIView()
  private let gapDebugLabel = UILabel()
  var rows: [ChatListRow] = []
  private var appearance = ChatListAppearance.fallback
  private var lastRawAppearance: [String: Any]?
  private var queuedAppearanceAfterSendTransition: ChatListAppearance?
  private var shouldAutoScroll = true
  private var previousOffsetY: CGFloat = 0.0
  private var skipNextTransitionScrollCorrection = false
  private var lastKnownViewportWidth: CGFloat = 0.0
  private var lastKnownViewportHeight: CGFloat = 0.0
  private var contentPaddingTop: CGFloat = sectionTopInset
  private var requestedContentPaddingBottom: CGFloat = sectionBottomInset
  private var contentPaddingBottom: CGFloat = sectionBottomInset
  private var isApplyingRowsUpdate = false
  private var pendingStreamingTextLayoutInvalidation = false
  // A streaming relayout arrived while the user was scrolling and was deferred to
  // avoid stuttering the gesture; flushed once the scroll settles.
  private var pendingDeferredAgentStreamingRelayout = false
  private var _setRowsGeneration: UInt = 0
  private var pendingRowsPayload: [[String: Any]]?
  private var sourceRowsPayload: [[String: Any]] = []
  private var searchQuery = ""
  private var nativeSendEnabled = false
  private var agentChatMode = false
  // When the user taps "!" on a failed agent message, its id is armed here so the
  // next composer send re-uses it (triggering a clean truncate-and-resend).
  private var editingAgentMessageId: String?
  private var agentStreaming = false
  /// Set when an agent message is sent so the next rows-apply scrolls the new
  /// user message to the top (with a bottom spacer) to leave room for the answer.
  private var pendingAgentPushToTop = false
  private var agentPushToTopSpacer: CGFloat = 0
  /// Latches true the moment the user manually drags during an agent turn. While
  /// latched we stop re-pinning the question to the top so the user can scroll
  /// freely (ChatGPT-style: pinned until you scroll, then free until next send).
  /// Reset on each send.
  private var agentPinUserDetached = false
  private var engineSurfaceId: String = ""
  private var engineChatId: String = ""
  private var engineMyUserId: String = ""
  private var enginePeerUserId: String = ""
  private var enginePeerAgentId: String = ""
  private var enginePeerDisplayName: String = ""
  private var avatarUri: String = ""
  private var engineOpenedChatId: String = ""
  private var engineChannelBindingEnabled = true
  private var statusAuthorityEnabled = false

  // Agent inbox mode. When enabled, agent event-notification rows (eventThread /
  // eventInboxSummary) are pulled out of the transcript and reported to the host
  // (ChatMainView) so they can be surfaced via the Inbox banner instead.
  private var eventInboxModeEnabled = false
  /// Notification rows filtered out of the transcript, newest last (transcript order).
  private(set) var eventInboxRows: [ChatListRow] = []
  /// Reports the current inbox state (count + newest preview text) to the host.
  var onEventInboxChanged: ((_ count: Int, _ latestPreview: String?) -> Void)?
  /// Asks the host (ChatMainView) to embed the DM-level agent runtime view in-place,
  /// sharing the chat header chrome, instead of pushing it as a separate VC. When unset,
  /// `presentBridgeAgentConversation` falls back to a pushed/modal presentation.
  var onHostBridgeAgentView: ((VibeAgentConversationViewController) -> Void)?
  /// Asks the host to remove any embedded agent runtime view (DM changed, or this is no
  /// longer a bridge surface).
  var onTearDownBridgeAgentView: (() -> Void)?
  /// Provider of the currently embedded agent runtime view, or nil if none is shown.
  var hostedBridgeAgentProvider: (() -> String?)?
  /// Surface mode of the currently embedded agent runtime view.
  var hostedBridgeAgentSurfaceMode: (() -> VibeAgentConversationSurfaceMode?)?
  /// Route-provided bridge provider for Claude/Codex DMs. Some server rows carry the
  /// provider through `peerAgentId` rather than the reserved peer user id, so the list
  /// cannot rely only on `enginePeerUserId`.
  private var explicitBridgeProvider: String?
  /// The agent runtime surface currently presented from this list (full-screen child or
  /// pushed). Used to refresh its feed immediately after a send originates there.
  private weak var presentedBridgeAgentVC: VibeAgentConversationViewController?

  // Per-row UI state for the inline agent-turn bubble (the real interleaved
  // step/narration/diff renderer embedded directly in the chat bubble). Keyed by row
  // message id, mirroring VibeAgentConversationViewController's
  // expandedStepIdsByMessage/expandedProgressMessageIds/expandedRuntimeMessageIds/
  // streamStartByMessageId — but owned here because ChatListCell (a UICollectionViewCell)
  // is reused across scroll and can't hold this state itself.
  private var agentTurnExpandedStepIdsByRow: [String: Set<String>] = [:]
  private var agentTurnProgressExpandedRowIds = Set<String>()
  private var agentTurnRuntimeExpandedRowIds = Set<String>()
  // Rows whose tall-collapsed bubble (user text, agent text or settled agent turn) the
  // user expanded via the "Show more" bar — see the shared tall-content rule in
  // measureMessageBubbleLayout (tallBubble* constants).
  private var tallBubbleExpandedRowIds = Set<String>()
  private var agentTurnStreamStartByRow: [String: Date] = [:]
  // Memoized measured heights (see estimateMessageHeight): the row struct is retained only
  // for the cheap content-equality validity check — COW means it shares storage with the
  // live `rows` array, not a payload copy.
  private struct RowHeightCacheEntry {
    let row: ChatListRow
    let rowWidth: CGFloat
    let state: AgentTurnBubbleState
    let height: CGFloat
  }
  private var agentTurnHeightCache: [String: RowHeightCacheEntry] = [:]
  // Same memoization for ordinary message rows. Their height is an
  // NSAttributedString.boundingRect measurement that was recomputed from scratch on every
  // layout pass — and one chat open drives several full passes (deferred-rows flush, the
  // forced subtree layout before setRows, the initial bottom-scroll double pass, the
  // wallpaper-snapshot relayout). For a 120-row transcript that meant measuring 120 bubbles
  // several times over on the main thread during the push — the bulk of the open-latency
  // hitch. Caching collapses it to one measurement per row. `tallExpanded` rides in `state`,
  // so a "Show more" toggle correctly misses the cache and re-measures.
  private var messageHeightCache: [String: RowHeightCacheEntry] = [:]
  private var nativeHistoryHydrationGeneration: UInt = 0
  private var nativeOutgoingRowsById: [String: [String: Any]] = [:]
  private var nativeOutgoingOrder: [String] = []
  private var nativeEngineRowsById: [String: [String: Any]] = [:]
  private var nativeEngineOrder: [String] = []
  private var nativeDeletedMessageIds = Set<String>()
  private var isInternalScrollAdjustment = false
  private var isUpdatingBottomInset = false
  // Coalescing for agent-stream-tick driven setRows (see scheduleStreamCoalescedSetRows).
  private var streamSyncCoalesceWorkItem: DispatchWorkItem?
  private var lastStreamSyncApplyAt: CFTimeInterval = 0
  private var activeVoicePlaybackMessageId: String?
  private var activeVoicePlaybackIsPlaying = false
  private var activeVoicePlaybackProgress: CGFloat = 0.0
  private var lastViewportEmitTime: CFTimeInterval = 0.0
  private var lastViewportPayload:
    (
      contentHeight: CGFloat,
      layoutHeight: CGFloat,
      offsetY: CGFloat,
      distanceFromBottom: CGFloat,
      atBottom: Bool
    )?
  private let viewportEmitMinInterval: CFTimeInterval = 1.0 / 30.0
  /// Newest incoming message id we've already sent a read-receipt for on this chat.
  /// Read is cumulative (reading the newest incoming implies all earlier ones read, and
  /// the sender collapses their own outgoing statuses off their latest message — see
  /// `resolvedDisplayStatus`), so we only ever receipt the newest incoming row. Reset in
  /// `setEngineChatId`.
  private var lastReadReceiptSentMessageId: String?
  private var documentPreviewDataSource: ChatListDocumentPreviewDataSource?
  private var documentPreviewCacheByRemoteURL: [String: URL] = [:]
  private var documentPreviewInFlightURLs = Set<String>()
  private var onDemandRemoteMediaDownloadKeys = Set<String>()
  private var mediaDownloadProgressByRemoteKey: [String: Double] = [:]
  private var mediaDownloadObservations: [String: NSKeyValueObservation] = [:]
  private var mediaDownloadTasks: [String: URLSessionDownloadTask] = [:]
  private var visibleAutoDownloadWorkItem: DispatchWorkItem?
  private var reactionDebugTargetMessageId: String?
  private var reactionDebugTargetEmoji: String?
  private var reactionDebugRemainingRowsChecks: Int = 0

  private var hiddenMessageId: String?
  private var selectionMode = false
  private var selectedMessageIds = Set<String>()
  private var pendingSendTransition: SendTransitionPayload?
  private var activeSendTransition: SendTransitionState?
  // The overlay outlives activeSendTransition by the ~55ms reveal crossfade.
  // Scroll/rows updates landing inside that window still move the real cell, so
  // the fading overlay must keep tracking it or the two paint ~1px apart
  // (visible as the tail gaining a pixel at the very end of the send morph).
  private var fadingSendTransition: SendTransitionState?
  private var projectedSendTransitionMessageId: String?
  private var deferredPendingSendBottomScrollMessageId: String?
  var swipeReplyPanGesture: UIPanGestureRecognizer?
  var contextMenuLongPressGesture: UILongPressGestureRecognizer?
  var dismissInputTapGesture: UITapGestureRecognizer?
  var swipeReplyIndexPath: IndexPath?
  var swipeReplyMessageId: String?
  var swipeReplyIsMe: Bool = false
  var swipeReplyDidTrigger = false
  var swipeReplyIconView: ChatSwipeReplyIconView?
  weak var contextMenuHostCell: UICollectionViewCell?
  var contextMenuHostCellOriginalTransform: CGAffineTransform = .identity
  var customContextMenuOverlay: ChatContextMenuOverlay?
  var customContextMenuWindow: UIWindow?

  // --- Native input bar ---
  private(set) var inputBar: ChatInputBar?
  private(set) var agentComposerView: VibeComposerView?
  private var inputBarEnabled = false
  private var inputBarPlaceholder = "Message"
  var keyboardHeight: CGFloat = 0

  /// The bottom input surface currently mounted over the list. Default chat uses
  /// `ChatInputBar`; agent chat can swap in `VibeComposerView`. Any edge/overlay
  /// positioning should key off this shared value so the bottom effect does not
  /// disappear when the input implementation changes.
  var activeNativeInputView: UIView? {
    agentComposerView ?? inputBar
  }
  /// Persistent overlay container that sits above the list but below the composer.
  private let transitionOverlayHost = UIView()
  private lazy var jumpToBottomButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.alpha = 0.0
    button.isHidden = true
    button.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
    button.accessibilityLabel = "Jump to latest"
    button.addTarget(self, action: #selector(jumpToBottomTapped), for: .touchUpInside)

    button.backgroundColor = .clear

    let blurEffect = UIBlurEffect(style: .systemThinMaterial)
    let blurView = UIVisualEffectView(effect: blurEffect)
    blurView.translatesAutoresizingMaskIntoConstraints = false
    blurView.isUserInteractionEnabled = false
    button.insertSubview(blurView, at: 0)

    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: button.topAnchor),
      blurView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
      blurView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
    ])

    button.layer.cornerRadius = 19.0
    button.layer.cornerCurve = .continuous
    button.clipsToBounds = true
    button.layer.borderWidth = 0.5
    button.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.15
    button.layer.shadowRadius = 8.0
    button.layer.shadowOffset = CGSize(width: 0, height: 3)

    button.setImage(
      UIImage(
        systemName: "chevron.down",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
      for: .normal)
    button.tintColor = .label
    return button
  }()
  private let nativeSendMorphTopRightRadius: CGFloat = 8.0

  // --- Debug animation tuning ---
  private var debugAnimDuration: CGFloat = 0.4
  private var debugAnimSlideOffset: CGFloat = 20.0
  private var debugPanelVisible = false {
    didSet { debugPanel?.isHidden = !debugPanelVisible }
  }
  private var debugPanel: UIView?
  private var debugDurationLabel: UILabel?
  private var debugOffsetLabel: UILabel?
  private var debugStatsLabel: UILabel?
  private static var wallpaperMaskImageCache: [String: CGImage] = [:]
  private static var wallpaperSnapshotCache: [String: CGImage] = [:]
  private static let cachedThemeIdDefaultsKey = "vibe.chat.native.themeId.v1"
  private static let cachedThemeIsDarkDefaultsKey = "vibe.chat.native.themeIsDark.v1"
  private static let documentPreviewSession: URLSession = {
    if #available(iOS 13.0, *) {
      return ChatPhoenixClient.makePinnedURLSession()
    }
    return URLSession.shared
  }()

  private var isPeerTyping: Bool = false
  private var isGroupOrChannel: Bool = false
  private var wallpaperSnapshot: CGImage?
  private var wallpaperSnapshotSize: CGSize = .zero
  private var wallpaperSnapshotCacheKey: String = ""
  private var wallpaperScrollPhaseBucket: Int = -1

  // Floating activity overlay (typing / agent progress) — lives OUTSIDE the collection view
  private let activityOverlay = UIView()
  private let activityDotContainer = UIView()
  private let activityDots: [UIView] = (0..<3).map { _ in UIView() }
  private let activityTextLabel = UILabel()

  func setIsGroupOrChannel(_ value: Bool) {
    isGroupOrChannel = value
  }

  // MARK: - Group sender identity (per-sender name label + floating avatar)

  /// One group participant, resolved from the room member list. Powers the name label
  /// + avatar shown on incoming group messages. Agents (Claude/Codex) carry a `provider`
  /// so their name renders in the brand colour (Claude ≈ orange, Codex ≈ white).
  struct GroupSenderInfo {
    let userId: String
    let name: String
    let avatarUrl: String?
    let provider: String?  // "claude" / "codex" / nil for a human
  }

  /// Per-run decoration decisions for a single cell (computed in the view, which knows
  /// the neighbours + directory, then handed to the cell).
  struct GroupCellContext {
    var reservesGutter: Bool = false
    var showsName: Bool = false
    var senderName: String? = nil
    var senderColor: UIColor? = nil
    var isLastOfRun: Bool = false
    var senderKey: String? = nil
    var avatarUrl: String? = nil
    var provider: String? = nil
    static let none = GroupCellContext()
  }

  /// Directory keyed by UPPERCASED user id.
  private var groupSenderDirectory: [String: GroupSenderInfo] = [:]

  /// Floating avatars live in this non-interactive overlay (above the cells, over the
  /// reserved gutter) so a single avatar per sender-run tracks scroll — instead of one
  /// baked into every cell. Keyed by run id (the run's last message id).
  private let senderAvatarOverlay = UIView()
  private var senderAvatarViews: [String: SenderRunAvatarView] = [:]

  /// Avatar column reserved on the leading edge of incoming group bubbles.
  static let groupAvatarSize: CGFloat = 29.0
  static let groupAvatarGap: CGFloat = 6.0
  static var groupIncomingExtraLeading: CGFloat { groupAvatarSize + groupAvatarGap }
  /// Vertical space reserved above a bubble for the sender's name (first msg of a run).
  static let groupSenderNameHeight: CGFloat = 17.0

  /// Known local-agent shadow-user ids (also matched by name/handle) so an agent's
  /// messages render in its brand colour even before the directory loads.
  private static let claudeAgentUserId = "11111111-1111-1111-1111-111111111111"
  private static let codexAgentUserId = "22222222-2222-2222-2222-222222222222"

  func setGroupSenderDirectory(_ rawMembers: [[String: Any]]) {
    var next: [String: GroupSenderInfo] = [:]
    for raw in rawMembers {
      let rawId =
        (raw["userId"] as? String) ?? (raw["id"] as? String) ?? (raw["memberId"] as? String)
      let id = rawId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !id.isEmpty else { continue }
      let name =
        ((raw["name"] as? String) ?? (raw["username"] as? String) ?? (raw["label"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let avatarRaw =
        ((raw["avatarUrl"] as? String) ?? (raw["avatar_url"] as? String)
          ?? (raw["profileImage"] as? String) ?? (raw["profile_image"] as? String))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let provider = Self.resolveGroupSenderProvider(
        userId: id, name: name, username: raw["username"] as? String)
      let resolvedName = name.isEmpty ? (provider?.capitalized ?? id) : name
      next[id.uppercased()] = GroupSenderInfo(
        userId: id,
        name: resolvedName,
        avatarUrl: (avatarRaw?.isEmpty ?? true) ? nil : avatarRaw,
        provider: provider
      )
    }
    let changed = next.count != groupSenderDirectory.count
      || next.contains { key, value in groupSenderDirectory[key]?.name != value.name }
    groupSenderDirectory = next
    guard changed, isGroupOrChannel else { return }
    // Directory can land after the rows do — re-decorate what's on screen.
    if !rows.isEmpty {
      flowLayout.invalidateLayout()
      let visible = collectionView.indexPathsForVisibleItems
      if !visible.isEmpty {
        UIView.performWithoutAnimation {
          collectionView.reconfigureItems(at: visible)
        }
      }
    }
    updateFloatingSenderAvatars()
  }

  private func groupNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  /// Stable identity for run-grouping: an agent by its shadow-user id, a human by `from_id`.
  private func resolvedSenderKey(_ row: ChatListRow) -> String? {
    let raw: String? =
      row.isAgentMessage
      ? (row.agentUserId ?? row.agentUsername ?? row.agentName)
      : row.senderUserId
    return groupNonEmpty(raw)?.uppercased()
  }

  /// The previous/next *incoming attributable* message row (a day divider or a "me"
  /// message breaks the run, so the name reappears after them — like Telegram).
  private func adjacentGroupMessageRow(from index: Int, delta: Int) -> ChatListRow? {
    let j = index + delta
    guard j >= 0, j < rows.count else { return nil }
    let r = rows[j]
    guard r.kind == .message, !r.isMe, r.messageType != "agent_actions" else { return nil }
    return r
  }

  func groupCellContext(at indexPath: IndexPath) -> GroupCellContext {
    guard isGroupOrChannel, indexPath.item < rows.count else { return .none }
    let row = rows[indexPath.item]
    guard row.kind == .message, !row.isMe,
      row.messageType != "agent_actions", row.messageType != "typing"
    else { return .none }
    guard let key = resolvedSenderKey(row) else { return .none }

    let prev = adjacentGroupMessageRow(from: indexPath.item, delta: -1)
    let next = adjacentGroupMessageRow(from: indexPath.item, delta: 1)
    let isFirst = prev == nil || resolvedSenderKey(prev!) != key
    let isLast = next == nil || resolvedSenderKey(next!) != key

    let info = groupSenderDirectory[key]
    let provider =
      (row.isAgentMessage
        ? Self.resolveGroupSenderProvider(
          userId: row.agentUserId, name: row.agentName, username: row.agentUsername)
        : nil) ?? info?.provider
    // "check if the member added a name → use that instead of the raw id."
    let name =
      (row.isAgentMessage ? (groupNonEmpty(row.agentName) ?? info?.name) : info?.name)
      ?? provider?.capitalized
      ?? shortenedIdentifier(key)
    let color = groupSenderColor(key: key, name: name, provider: provider)

    var ctx = GroupCellContext()
    ctx.reservesGutter = true
    ctx.showsName = isFirst
    ctx.senderName = isFirst ? name : nil
    ctx.senderColor = color
    ctx.isLastOfRun = isLast
    ctx.senderKey = key
    ctx.avatarUrl = info?.avatarUrl
    ctx.provider = provider
    return ctx
  }

  private func shortenedIdentifier(_ key: String) -> String {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= 8 { return trimmed }
    return "Member"
  }

  private func groupSenderColor(key: String, name: String, provider: String?) -> UIColor {
    switch provider {
    case "claude":
      // Claude terracotta / warm orange.
      return UIColor(red: 0.85, green: 0.44, blue: 0.29, alpha: 1.0)
    case "codex":
      // Codex reads as near-white (kept legible on the wallpaper via the label shadow).
      return UIColor(white: 0.96, alpha: 1.0)
    default:
      let base = ChatProfileAppearanceStore.avatarColors(
        title: name, peerUserId: key, chatId: engineChatId
      ).0
      // Nudge toward a legible, saturated author tint regardless of the source gradient.
      var hue: CGFloat = 0
      var sat: CGFloat = 0
      var bri: CGFloat = 0
      var alpha: CGFloat = 0
      if base.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) {
        return UIColor(
          hue: hue, saturation: max(0.5, sat), brightness: max(0.72, bri), alpha: 1.0)
      }
      return base
    }
  }

  static func resolveGroupSenderProvider(userId: String?, name: String?, username: String?)
    -> String?
  {
    let idLower = userId?.lowercased() ?? ""
    let hay = [name, username].compactMap { $0?.lowercased() }
    if idLower == claudeAgentUserId || idLower == "00000000-0000-0000-0000-0000000000c1"
      || hay.contains(where: { $0.contains("claude") })
    {
      return "claude"
    }
    if idLower == codexAgentUserId || idLower == "00000000-0000-0000-0000-0000000000c2"
      || hay.contains(where: { $0.contains("codex") })
    {
      return "codex"
    }
    return nil
  }

  override init(frame: CGRect) {
    let layout = ChatCollectionFlowLayout()
    layout.minimumLineSpacing = 2
    layout.sectionInset = UIEdgeInsets(
      top: sectionTopInset, left: messageHorizontalInset, bottom: sectionBottomInset,
      right: messageHorizontalInset)
    layout.sectionHeadersPinToVisibleBounds = false

    flowLayout = layout
    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    super.init(frame: frame)
    clipsToBounds = false

    if var cachedRawAppearance = Self.bootstrapCachedRawAppearance() {
      cachedRawAppearance["nativeThemeIsDark"] = traitCollection.userInterfaceStyle == .dark
      lastRawAppearance = cachedRawAppearance
      appearance = ChatListAppearance.from(raw: cachedRawAppearance)
    }

    wallpaperPatternLayer.mask = wallpaperPatternMaskLayer
    wallpaperPatternMaskLayer.contentsGravity = .resizeAspectFill
    wallpaperPatternMaskLayer.contentsScale = UIScreen.main.scale
    wallpaperContainerView.isUserInteractionEnabled = false
    wallpaperContainerView.layer.addSublayer(wallpaperLayer)
    wallpaperContainerView.layer.addSublayer(wallpaperPatternLayer)
    collectionView.addSubview(wallpaperContainerView)

    addSubview(collectionView)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
      collectionView.topAnchor.constraint(equalTo: topAnchor),
      collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    senderAvatarOverlay.isUserInteractionEnabled = false
    senderAvatarOverlay.clipsToBounds = true
    addSubview(senderAvatarOverlay)

    collectionView.backgroundColor = .clear
    collectionView.clipsToBounds = false
    collectionView.alwaysBounceVertical = true
    collectionView.showsVerticalScrollIndicator = false

    if #available(iOS 11.0, *) {
      collectionView.contentInsetAdjustmentBehavior = .never
    }

    if #available(iOS 26.0, *) {
      collectionView.topEdgeEffect.style = .soft
      collectionView.bottomEdgeEffect.style = .soft
    }
    collectionView.register(
      ChatListCell.self, forCellWithReuseIdentifier: ChatListCell.reuseIdentifier)
    collectionView.dataSource = self
    collectionView.delegate = self
    installInteractionGestures()

    scrollToneOverlay.isUserInteractionEnabled = false
    scrollToneOverlay.backgroundColor = .clear
    scrollToneOverlay.clipsToBounds = true
    scrollToneOverlay.addSubview(scrollToneTopView)
    scrollToneOverlay.addSubview(scrollToneBottomView)
    addSubview(scrollToneOverlay)

    applyWallpaperAppearance()
    applyScrollToneTheme()
    updateScrollToneOverlay(offsetY: 0.0)

    // Transition overlay host — above messages, below the native composer.
    transitionOverlayHost.isUserInteractionEnabled = false
    transitionOverlayHost.clipsToBounds = false
    addSubview(transitionOverlayHost)

    if chatGapDebugOverlayEnabled {
      gapDebugOverlay.isUserInteractionEnabled = false
      gapDebugOverlay.backgroundColor = UIColor.red.withAlphaComponent(0.24)
      gapDebugOverlay.layer.borderColor = UIColor.red.withAlphaComponent(0.95).cgColor
      gapDebugOverlay.layer.borderWidth = 1

      gapDebugLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
      gapDebugLabel.textColor = .white
      gapDebugLabel.backgroundColor = UIColor.red.withAlphaComponent(0.82)
      gapDebugLabel.textAlignment = .center
      gapDebugLabel.layer.cornerRadius = 4
      gapDebugLabel.clipsToBounds = true

      gapDebugOverlay.addSubview(gapDebugLabel)
      addSubview(gapDebugOverlay)
    }

    setupActivityOverlay()
    setupDebugPanel()

    // Keyboard observers
    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardWillHide(_:)),
      name: UIResponder.keyboardWillHideNotification, object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleChatEngineChanged(_:)),
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleVoiceBubblePlaybackChanged(_:)),
      name: .voiceBubblePlaybackDidChange,
      object: VoiceBubblePlaybackCoordinator.shared
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAgentCodeBlockExpanded(_:)),
      name: Notification.Name("AgentCodeBlockExpanded"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAgentStreamingTextLayoutInvalidated(_:)),
      name: .chatNativeStreamingTextLayoutInvalidated,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAgentBridgeSelectionChanged(_:)),
      name: AgentBridgeSelectionStore.didChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAgentIntegrationPackOpenPanel(_:)),
      name: Notification.Name("AgentIntegrationPackOpenPanelNotification"),
      object: nil
    )

  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else {
      return
    }
    reapplyNativeThemeForCurrentInterfaceStyle()
  }

  private func pixelAlignedValue(_ value: CGFloat) -> CGFloat {
    let scale = max(window?.screen.scale ?? UIScreen.main.scale, 1.0)
    return (value * scale).rounded() / scale
  }

  private func layoutGapDebugOverlay() {
    guard chatGapDebugOverlayEnabled else { return }

    let overlayHeight = max(0, contentPaddingBottom)
    gapDebugOverlay.isHidden = overlayHeight <= 0.5
    guard overlayHeight > 0.5 else { return }

    gapDebugOverlay.frame = CGRect(
      x: 0,
      y: max(0, bounds.height - overlayHeight),
      width: bounds.width,
      height: overlayHeight
    )
    let labelWidth = min(max(128, bounds.width * 0.46), max(128, bounds.width - 16))
    gapDebugLabel.frame = CGRect(x: 8, y: 6, width: labelWidth, height: 18)
    gapDebugLabel.text = String(
      format: "LIST inset %.0f req %.0f",
      contentPaddingBottom,
      requestedContentPaddingBottom
    )

    positionTransitionOverlayHost()
    bringSubviewToFront(gapDebugOverlay)
  }

  private func positionTransitionOverlayHost() {
    guard transitionOverlayHost.superview === self else { return }
    transitionOverlayHost.frame = bounds
    // Keep the send-transition overlay ABOVE the input bar so the morphing /
    // newly-sent bubble is never occluded behind the composer (it was rendering
    // at a lower z-index than the input). The host is non-interactive and empty
    // at rest, so this doesn't block the composer's controls.
    bringSubviewToFront(transitionOverlayHost)
  }

  private func reactionDebugLog(_ message: String) {
    guard chatReactionDebugLogs else { return }
    NSLog("[ChatReactionDebug] %@", message)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    updateChatEngineChannelBinding(forceDetach: true)
    if !engineSurfaceId.isEmpty {
      let surfaceId = engineSurfaceId
      chatListEngineBindingQueue.async {
        _ = ChatEngine.shared.unbindSurface(["surfaceId": surfaceId])
      }
    }
  }

  override public func didMoveToWindow() {
    super.didMoveToWindow()
    updateChatEngineBinding()
    updateChatEngineChannelBinding()
    if window != nil {
      revalidateListRenderOnAttach()
      hydrateRowsFromNativeHistoryIfReady(trigger: "didMoveToWindow")
      presentPreferredAgentViewIfNeeded()
      prefetchBridgeHistoryIfNeeded()
      replayOutstandingAgentBridgeAskIfNeeded()
    }
  }

  /// This view is REUSED across chat open/close (ChatHomeListView holds one ChatMainView).
  /// A rows update that lands while the view is detached takes the reloadData path, but a
  /// detached UICollectionView with unchanged bounds creates no cells — and re-attaching
  /// alone never re-queries the data source, so the chat re-opens visually EMPTY until a
  /// touch/scroll dirties the layout. Force the layout pass on attach and verify cells
  /// actually materialized; reload if they didn't.
  private func revalidateListRenderOnAttach() {
    guard !rows.isEmpty else { return }
    collectionView.collectionViewLayout.invalidateLayout()
    collectionView.layoutIfNeeded()
    let visibleCount = collectionView.indexPathsForVisibleItems.count
    let contentH = collectionView.contentSize.height
    let boundsH = collectionView.bounds.height
    if visibleCount == 0, contentH > 0, boundsH > 0 {
      NSLog(
        "[FirstMsg] attach REVALIDATE reloading — rows=%d visible=0 offset=%.0f contentH=%.0f boundsH=%.0f",
        rows.count, collectionView.contentOffset.y, contentH, boundsH)
      collectionView.reloadData()
      collectionView.layoutIfNeeded()
    } else if rows.count <= 4 {
      NSLog(
        "[FirstMsg] attach revalidate ok rows=%d visible=%d offset=%.0f contentH=%.0f",
        rows.count, visibleCount, collectionView.contentOffset.y, contentH)
    }
    // Stale send-morph ghost state must never survive a detach: if the morph never
    // completed (chat closed mid-send) the only message would re-render hidden.
    if activeSendTransition == nil, pendingSendTransition == nil, hiddenMessageId != nil {
      NSLog(
        "[FirstMsg] attach clearing stale hiddenMessageId=%@",
        String(hiddenMessageId?.prefix(12) ?? "nil"))
      hiddenMessageId = nil
      collectionView.reloadData()
    }
  }

  /// When this chat comes on screen, re-present any ask/command that arrived while it was
  /// off-screen (and was skipped by `isVisibleFrontmostChat`). A plain DM open doesn't reload
  /// history, so the bridge won't re-emit — we re-surface from the engine's stored ask instead.
  private func replayOutstandingAgentBridgeAskIfNeeded() {
    guard !engineChatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    // Defer so the push/transition settles and this view is actually frontmost before the
    // handler's visibility check runs; the provider often binds ~0.28s after the transition.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      guard let self, self.window != nil else { return }
      let chatId = self.engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !chatId.isEmpty,
        let info = ChatEngine.shared.outstandingAgentBridgeAskInfo(
          chatId: chatId, provider: self.currentBridgeProvider)
      else { return }
      self.presentAgentBridgeAskIfNeeded(info)
    }
  }

  override public func layoutSubviews() {
    let previousHeight = lastKnownViewportHeight
    let previousWidth = lastKnownViewportWidth
    super.layoutSubviews()
    wallpaperLayer.frame = bounds
    wallpaperPatternLayer.frame = bounds
    wallpaperPatternMaskLayer.frame = wallpaperPatternLayer.bounds
    var wallpaperFrame = bounds
    wallpaperFrame.origin.y = collectionView.contentOffset.y
    wallpaperContainerView.frame = wallpaperFrame
    collectionView.sendSubviewToBack(wallpaperContainerView)
    scrollToneOverlay.frame = bounds
    updateScrollToneOverlay(offsetY: collectionView.contentOffset.y)
    refreshWallpaperSnapshotIfNeeded()
    updateVisibleWallpaperBackdropLayouts()
    transitionOverlayHost.frame = bounds
    senderAvatarOverlay.frame = bounds
    updateFloatingSenderAvatars()
    layoutDebugPanel()

    // Layout native input bar if enabled
    if inputBarEnabled {
      layoutInputBarAndInset()
    } else {
      let desiredBottomPadding = requestedContentPaddingBottom
      if abs(contentPaddingBottom - desiredBottomPadding) > 0.5 {
        contentPaddingBottom = desiredBottomPadding
        updateBottomAnchorInset()
      }
      layoutJumpToBottomButton()
    }
    layoutActivityOverlay()
    layoutGapDebugOverlay()
    layoutBridgeCommandOverlay()
    layoutBridgeUsageBanner()

    let currentHeight = collectionView.bounds.height
    let currentWidth = collectionView.bounds.width
    lastKnownViewportHeight = currentHeight
    lastKnownViewportWidth = currentWidth

    if abs(previousWidth - currentWidth) > 0.5 {
      collectionView.collectionViewLayout.invalidateLayout()
    }

    if previousHeight <= 0.0 {
      updateBottomAnchorInset()
      if shouldAutoScroll || !rows.isEmpty {
        collectionView.layoutIfNeeded()
        // First layout of the chat: land on the latest message even in agent mode.
        scrollToBottom(animated: false, force: true)
      }
      // Rows are frequently applied while this list is still 0×0 (the host defers
      // setRows to viewWillAppear/attach, but the conversation VC's view isn't sized
      // by the nav controller until this first real layout pass). A reloadData issued
      // at 0×0 builds zero cells and computes contentSize=0; the width-change
      // invalidateLayout above recomputes item metrics, but the cells were never
      // created, so the transcript can stay blank until a later touch/scroll. Force a
      // reloadData HERE — the first pass with real bounds — so the already-applied rows
      // materialize immediately as the chat appears, closing the "empty for ~1s then
      // pops in" gap.
      if !rows.isEmpty, collectionView.indexPathsForVisibleItems.isEmpty {
        NSLog(
          "[ChatOpen] firstRealBounds RENDER surface=%@ rows=%d bounds=%.0fx%.0f contentH=%.0f — forcing reloadData (0 cells materialized)",
          surfaceId.isEmpty ? "<none>" : surfaceId, rows.count,
          collectionView.bounds.width, collectionView.bounds.height,
          collectionView.contentSize.height)
        UIView.performWithoutAnimation {
          collectionView.reloadData()
          collectionView.layoutIfNeeded()
          scrollToBottom(animated: false, force: true)
        }
      } else if !rows.isEmpty {
        NSLog(
          "[ChatOpen] firstRealBounds ok surface=%@ rows=%d bounds=%.0fx%.0f visible=%d contentH=%.0f",
          surfaceId.isEmpty ? "<none>" : surfaceId, rows.count,
          collectionView.bounds.width, collectionView.bounds.height,
          collectionView.indexPathsForVisibleItems.count, collectionView.contentSize.height)
      }
      emitViewport(force: true)
      maybeStartPendingSendTransition()
      return
    }

    guard abs(previousHeight - currentHeight) > 0.5 else {
      updateBottomAnchorInset()
      emitViewport(force: true)
      maybeStartPendingSendTransition()
      return
    }

    let distanceBeforeResize = max(
      0.0, collectionView.contentSize.height - (collectionView.contentOffset.y + previousHeight))
    updateBottomAnchorInset()
    let shouldForceBottomDuringTransition =
      (pendingSendTransition != nil || activeSendTransition != nil || hiddenMessageId != nil)
      && deferredPendingSendBottomScrollMessageId == nil
    if distanceBeforeResize <= listBottomThreshold || shouldAutoScroll
      || shouldForceBottomDuringTransition
    {
      scrollToBottom(animated: false)
    } else {
      restoreStationaryDistance(distanceBeforeResize)
    }
    previousOffsetY = collectionView.contentOffset.y
    emitViewport(force: true)
    maybeStartPendingSendTransition()
  }

  // MARK: - Bridge-agent fresh surface
  //
  // A Claude/Codex DM opens scratch ONLY the first time it's ever engaged in this
  // app process (older turns beyond that live in the profile's "Chat History").
  // Once you've sent a message here, the thread is "engaged" and must stay visible
  // for the rest of the app's lifetime: going back to the chat list and reopening
  // the same DM should show the same running/finished turn, not wipe it back to a
  // blank scratch surface. `ChatListView` itself is a UIView that gets torn down
  // and recreated on every such reopen (not a cached/reused instance), so this
  // state can't live on `self` — it's keyed by chatId in a process-lifetime static
  // store instead. That means it survives instance recreation (nav back/reopen,
  // backgrounding) and only resets on an actual app relaunch, when the static
  // storage itself is freshly initialized.
  private static var bridgeFreshHiddenIdsByChat: [String: Set<String>] = [:]
  // Messages the user sent from THIS thread — always visible, even if a send lands
  // before the history snapshot is taken (so a new thread never vanishes). A
  // non-empty entry for a chatId is also the "this thread is engaged" signal.
  private static var bridgeFreshOwnSentIdsByChat: [String: Set<String>] = [:]
  // A history session the user explicitly opened FROM the History surface. Its rows
  // are ingested under this DM's chatId keyed `bridge-<sessionId>-…`; while set, those
  // rows are allowed through the fresh-surface filter so the picked conversation shows
  // in the default chat view (everything else still opens clean). Nil = fresh thread.
  private var bridgeLoadedSessionId: String?
  // The bridge session the CURRENTLY-VISIBLE conversation belongs to, adopted from the
  // most recent finished agent turn in a fresh thread (one started here, not opened from
  // History). Lets a follow-up — "apply fix", "continue" — resume that same CLI session
  // instead of spawning a new one that lands in a different history. Cleared on New Chat
  // and DM-switch; harmless to also clear on a same-chat instance rebind since it's
  // re-derived from rows (via `bridgeFreshHiddenIdsByChat`-filtered rows, now correctly
  // unhidden) on the very next `setRows`.
  private var activeBridgeSessionId: String?
  private var lastOlderBridgeHistoryLoadAt: TimeInterval = 0

  /// Register an outgoing message id so the fresh-surface filter never hides it.
  func noteBridgeFreshOwnSentId(_ messageId: String) {
    let id = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { return }
    let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatKey.isEmpty else { return }
    Self.bridgeFreshOwnSentIdsByChat[chatKey, default: []].insert(id)
  }

  /// Load (or clear, when nil) an explicitly-picked history session into this chat
  /// surface. Re-applies the fresh-surface filter so the session's rows appear without
  /// leaking the rest of the stored transcript.
  func setBridgeLoadedSessionId(_ sessionId: String?) {
    let next = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = (next?.isEmpty == false) ? next : nil
    guard bridgeLoadedSessionId != resolved else { return }
    bridgeLoadedSessionId = resolved
    if !sourceRowsPayload.isEmpty { setRows(sourceRowsPayload) }
  }

  private func bridgeRowIsLive(_ row: ChatListRow) -> Bool {
    if row.isStreamingText { return true }
    let status = (row.status ?? "").lowercased()
    return status == "running" || status == "streaming"
  }

  /// A Claude/Codex DM opens showing its persisted transcript (seeded instantly from the
  /// engine's on-disk row cache), like any other chat. Hidden rows exist only after an
  /// explicit "New Chat": startNewBridgeSession snapshots the then-visible row ids into
  /// `bridgeFreshHiddenIdsByChat`, so the deliberate fresh thread starts clean while a
  /// plain open keeps its history. Session-transcript rows (`bridge-<sessionId>-…`) are
  /// still scoped: shown only for the explicitly-loaded/live session, never leaked from
  /// other sessions.
  private func bridgeFreshFiltered(_ parsed: [ChatListRow]) -> [ChatListRow] {
    guard currentBridgeProvider != nil else { return parsed }
    let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatKey.isEmpty else { return parsed }
    // Prefer this view's explicitly-picked session id, but fall back to the session the
    // ENGINE is still live-tailing for this chat (retained across view-detach/background).
    // A foreground rebind can wipe the per-instance `bridgeLoadedSessionId`, which would
    // otherwise hide every `bridge-<sessionId>` row and collapse the loaded transcript to
    // empty a few seconds after it rendered. Only pay the (cheap) engine read on the
    // recovery path — when this view has no session id of its own.
    // Also fall back to the session ADOPTED from this thread's own finished turns
    // (`activeBridgeSessionId`): when a run finishes, the engine drops its live-session
    // registration, and without this fallback the just-settled `bridge-<sid>` cards were
    // filtered right back out — the "whole list clears when the response lands" flicker.
    let effectiveLoadedSessionId =
      bridgeLoadedSessionId ?? ChatEngine.shared.liveBridgeSessionId(chatId: chatKey)
      ?? activeBridgeSessionId
    let loadedPrefix = effectiveLoadedSessionId.map { "bridge-\($0)" }
    let ownSentIds = Self.bridgeFreshOwnSentIdsByChat[chatKey] ?? []
    // The DM opens showing its persisted transcript, like any other chat — the
    // "open as a blank scratch surface" auto-hide that used to accumulate every
    // non-live row here is gone (it fought the on-disk row cache: the engine seeded
    // the last-known transcript instantly and this filter dropped all of it,
    // re-creating the empty-on-open the cache exists to kill). `hiddenIds` is now
    // written ONLY by the explicit "New Chat" action (startNewBridgeSession
    // snapshots the rows visible at that moment), so a deliberate fresh thread
    // still starts clean while a plain open keeps its history.
    let hiddenIds = Self.bridgeFreshHiddenIdsByChat[chatKey] ?? []
    // An EXPLICITLY-picked History session (`bridgeLoadedSessionId` is only ever set by
    // loadBridgeSessionIntoChat, cleared by New Chat — the resume-adoption path uses the
    // separate `activeBridgeSessionId`, so this stays nil in the default continuous view).
    // Because every session ingests into ONE shared DM chatId, the live `stream-…` rows,
    // the user's own just-sent rows, and other sessions' `bridge-…` rows all coexist in
    // the same store. Without isolation, opening an old session renders that session's
    // transcript COMBINED with all of that current-thread activity (and the same turn can
    // appear twice — once as its live stream row, once as its `bridge-` card). When a
    // historical session is picked, show ONLY that session's rows.
    let historicalSessionPicked = bridgeLoadedSessionId != nil
    return parsed.filter { row in
      let id = row.messageId ?? ""
      // Session transcripts opened from History are ingested under this DM chatId keyed
      // `bridge-<sessionId>-…`. Show them only for the explicitly-loaded session; never
      // surface other sessions in the fresh default chat.
      if id.hasPrefix("bridge-") {
        if let loadedPrefix, id.hasPrefix(loadedPrefix) { return true }
        // A picked historical session is isolated: another session's rows never bleed in,
        // even a currently-live one — the whole point is to view that one past thread.
        if historicalSessionPicked { return false }
        // A RUNNING/streaming session row is never "phantom history" — it's the run
        // in flight right now. Opening the DM mid-run must show it immediately (the
        // engine registers its session as live on ingest, which flips loadedPrefix
        // above on the next pass; this covers the first render before that lands).
        if bridgeRowIsLive(row) { return true }
        return false
      }
      // Non-`bridge-` rows are the CURRENT thread's live stream rows / native rows / the
      // user's own sends — all keyed in the shared chatId. In a picked historical session
      // they are not part of that past transcript, so suppress them to keep the view
      // isolated (otherwise the historical view shows live activity combined in).
      if historicalSessionPicked { return false }
      // Drop prior-history rows AND non-message rows (stale date separators); a new
      // thread renders only the messages exchanged since it was engaged.
      guard !id.isEmpty else { return false }
      if ownSentIds.contains(id) { return true }
      if hiddenIds.contains(id) { return false }
      if bridgeRowIsLive(row) { return true }
      return true
    }
  }

  // Message ids of bridge command results we've already reported to the host, so a
  // re-render of the same row set doesn't re-fire the overlay on every setRows pass.
  private var reportedBridgeCommandIds: Set<String> = []

  /// Max agent-DM rows rendered at once. Caps per-row E2E decryption + bubble self-sizing
  /// so a long transcript can't freeze the main thread.
  private static let agentTranscriptWindow = 40

  /// Pull bridge info-command results (executable == "vibe-bridge") out of the
  /// transcript. The newest unreported one is forwarded to the host via
  /// `onNativeEvent(type: "bridgeCommandResult")` so it renders in the glass overlay /
  /// pinned usage banner instead of as a chat bubble. Returns the rows minus those.
  // Slash commands the bridge answers in-place (banner/overlay) — these never belong in
  // the transcript, neither the bridge's reply NOR the user's outgoing echo. Anything
  // else ("/code-review", "/debug", …) is a real agent turn and stays in the list.
  private static let bridgeInfoCommandNames: Set<String> = [
    "usage", "status", "commands", "help", "model", "compact", "doctor", "context",
  ]

  private static func isBridgeInfoCommandText(_ text: String?) -> Bool {
    let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return false }
    let firstToken = trimmed.dropFirst().split(whereSeparator: { $0 == " " || $0 == "\n" }).first
    guard let name = firstToken.map({ String($0).lowercased() }) else { return false }
    return bridgeInfoCommandNames.contains(name)
  }

  private func extractBridgeCommandRows(_ parsed: [ChatListRow]) -> [ChatListRow] {
    // Only Claude/Codex bridge DMs answer slash commands in-place; never touch a normal
    // chat's transcript.
    guard currentBridgeProvider != nil else { return parsed }
    var kept: [ChatListRow] = []
    var commandRows: [ChatListRow] = []
    for row in parsed {
      if row.agentRuntime?.command?.executable?.lowercased() == "vibe-bridge" {
        commandRows.append(row)
      } else if row.isMe, !row.isAgentMessage,
        Self.isBridgeInfoCommandText(row.plainContent ?? row.text)
      {
        // The user's own "/usage" send — drop the echo bubble; the bridge's reply opens
        // the banner instead. (Functional task commands fall through and stay.)
        continue
      } else {
        kept.append(row)
      }
    }
    guard !commandRows.isEmpty else { return kept }

    // Report only the most recent command result that we haven't surfaced yet.
    if let latest = commandRows.last,
      let id = latest.messageId, !id.isEmpty,
      !reportedBridgeCommandIds.contains(id)
    {
      reportedBridgeCommandIds.insert(id)
      let display = latest.agentRuntime?.command?.display ?? ""
      let name =
        display
        .components(separatedBy: " ")
        .first(where: { $0.hasPrefix("/") })
        .map { String($0.dropFirst()) } ?? ""
      let body = (latest.plainContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !body.isEmpty {
        DispatchQueue.main.async { [weak self] in
          self?.showBridgeCommandOverlay(name: name, body: body)
          // Also notify the host (e.g. for a near-limit usage banner refinement).
          self?.onNativeEvent([
            "type": "bridgeCommandResult",
            "name": name,
            "display": display,
            "body": body,
          ])
        }
      }
    }
    return kept
  }

  // Glass command overlay (e.g. /usage, /status, /commands output) shown above the
  // input bar — bridge info commands are answered here, never added to the transcript.
  private var bridgeCommandOverlay: VibeAgentCommandOverlayView?

  // Near-limit usage banner (agent DMs): slim pill above the composer, mirroring the
  // desktop CLI's "You've used 99% of your session limit · resets in 3h" warning. Fed by
  // the bridge's structured usage report (requestAgentBridgeUsage), refreshed on DM open
  // and after each finished run; shown only when the worst subscription bucket crosses
  // the threshold. Tapping remembers the bucket+level so the same warning doesn't
  // re-pop until usage climbs further.
  var onBridgeUsageBannerVisibilityChanged: (() -> Void)?
  var isBridgeUsageBannerVisible: Bool {
    guard let banner = bridgeUsageBanner else { return false }
    return !banner.isHidden && banner.alpha > 0.01
  }
  private var bridgeUsageBanner: ChatPinnedBannerView?
  private var lastBridgeUsageRequestId: String?
  private var lastBridgeUsageRequestAt: TimeInterval = 0
  private var dismissedBridgeUsageKey: String?
  private var hadLiveBridgeRun = false

  private func showBridgeCommandOverlay(name: String, body: String) {
    let overlay: VibeAgentCommandOverlayView
    if let existing = bridgeCommandOverlay {
      overlay = existing
    } else {
      let created = VibeAgentCommandOverlayView()
      created.onClose = { [weak self] in self?.hideBridgeCommandOverlay() }
      addSubview(created)
      bridgeCommandOverlay = created
      overlay = created
    }
    overlay.applyAppearance(appearance.isDark ? .fallback : .lightFallback)
    let title = name.isEmpty ? "Command" : name.prefix(1).uppercased() + String(name.dropFirst())
    overlay.configure(title: title, body: body)
    overlay.isHidden = false
    bringSubviewToFront(overlay)
    setNeedsLayout()
    layoutIfNeeded()
    overlay.alpha = 0.0
    overlay.transform = CGAffineTransform(translationX: 0, y: 10)
    UIView.animate(
      withDuration: 0.22, delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      overlay.alpha = 1.0
      overlay.transform = .identity
    }
  }

  private func hideBridgeCommandOverlay() {
    guard let overlay = bridgeCommandOverlay else { return }
    UIView.animate(
      withDuration: 0.16, delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      overlay.alpha = 0.0
      overlay.transform = CGAffineTransform(translationX: 0, y: 8)
    } completion: { _ in
      if overlay.alpha <= 0.01 { overlay.isHidden = true }
    }
  }

  /// Position the command overlay just above the active input bar (agent composer or
  /// the standard input bar), matching the bar's horizontal insets.
  private func layoutBridgeCommandOverlay() {
    guard let overlay = bridgeCommandOverlay, !overlay.isHidden else { return }
    let barMinY = agentComposerView?.frame.minY ?? inputBar?.frame.minY ?? bounds.height
    let width = max(0.0, bounds.width - 36.0)
    let targetSize = overlay.systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    let height = max(60.0, targetSize.height)
    overlay.frame = CGRect(x: 18.0, y: barMinY - height - 10.0, width: width, height: height)
  }

  // MARK: - Near-limit usage banner

  /// Ask the bridge for a fresh structured usage snapshot. Throttled; a rejected push
  /// (socket/join not ready) clears the throttle so the channel-join retry fires freely.
  private func requestBridgeUsageSnapshot(reason: String) {
    guard let provider = currentBridgeProvider else { return }
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastBridgeUsageRequestAt > 30.0 else { return }
    lastBridgeUsageRequestAt = now
    let requestId = UUID().uuidString
    let result = ChatEngine.shared.requestAgentBridgeUsage([
      "chatId": chatId, "provider": provider, "requestId": requestId,
    ])
    let accepted = (result["accepted"] as? Bool) == true
    if accepted {
      lastBridgeUsageRequestId = (result["requestId"] as? String) ?? requestId
    } else {
      // Socket/join not ready — allow a retry after a short backoff (the fallback poll
      // and engine-change activity below re-call this) without spamming every frame.
      lastBridgeUsageRequestAt = now - 25.0
    }
    NSLog(
      "[ChatUsage] request chat=%@ reason=%@ accepted=%@ result=%@",
      String(chatId.prefix(12)), reason, accepted ? "Y" : "N",
      (result["reason"] as? String) ?? "-")
  }

  /// Parse the usage reply this surface requested; show the banner when the worst
  /// subscription bucket is at/over the threshold, hide it when usage dropped back.
  private func applyBridgeUsageReply(requestId: String) {
    guard requestId == lastBridgeUsageRequestId,
      let payload = ChatEngine.shared.latestAgentBridgeUsage(requestId: requestId),
      (payload["ok"] as? Bool) ?? true,
      let report = payload["report"] as? [String: Any],
      let buckets = report["buckets"] as? [[String: Any]]
    else { return }
    var worstLabel: String?
    var worstUtil = 0
    var worstResetsAt: String?
    for bucket in buckets {
      guard let label = bucket["label"] as? String, !label.isEmpty else { continue }
      let util = (bucket["utilization"] as? NSNumber)?.intValue ?? 0
      if util > worstUtil {
        worstUtil = util
        worstLabel = label
        worstResetsAt = bucket["resetsAt"] as? String
      }
    }
    NSLog("[ChatUsage] reply buckets=%d worst=%@ %d%%", buckets.count, worstLabel ?? "-", worstUtil)
    guard let label = worstLabel, worstUtil >= 75 else {
      hideBridgeUsageBanner()
      return
    }
    // Bucket + 5%-step level: dismissing 92% suppresses 90–94, but 95 re-warns.
    let key = "\(label)#\(worstUtil / 5)"
    guard key != dismissedBridgeUsageKey else { return }
    var text = "You've used \(worstUtil)% of your \(label) limit"
    if let reset = Self.bridgeUsageResetText(worstResetsAt) {
      text += " · resets in \(reset)"
    }
    showBridgeUsageBanner(text: text, key: key)
  }

  /// "2h 15m" / "45m" / "3d" until the bucket resets, from the report's ISO timestamp.
  private static func bridgeUsageResetText(_ iso: String?) -> String? {
    guard let iso, !iso.isEmpty else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    guard let date else { return nil }
    let seconds = date.timeIntervalSinceNow
    guard seconds > 0 else { return nil }
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    if hours > 48 { return "\(hours / 24)d" }
    if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
    return "\(max(1, minutes))m"
  }

  private func showBridgeUsageBanner(text: String, key: String) {
    let banner: ChatPinnedBannerView
    if let existing = bridgeUsageBanner {
      banner = existing
    } else {
      let created = ChatPinnedBannerView()
      created.addTarget(self, action: #selector(handleBridgeUsageBannerTapped), for: .touchUpInside)
      addSubview(created)
      bridgeUsageBanner = created
      banner = created
    }
    let accent = UIColor { trait in
      trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.98, green: 0.76, blue: 0.28, alpha: 1.0)
        : UIColor(red: 0.70, green: 0.48, blue: 0.04, alpha: 1.0)
    }
    banner.applyIconAccent(accent)
    banner.applyTheme(
      textColor: appearance.textColorThem,
      surfaceColor: appearance.bubbleThemColor,
      isDark: appearance.isDark
    )
    banner.configure(
      title: "Usage",
      body: text,
      systemImage: "gauge.with.dots.needle.bottom.50percent",
      animateIcon: banner.accessibilityValue != nil
    )
    banner.accessibilityValue = key
    let wasHidden = banner.isHidden
    banner.isHidden = false
    bringSubviewToFront(banner)
    setNeedsLayout()
    layoutIfNeeded()
    if wasHidden {
      onBridgeUsageBannerVisibilityChanged?()
    }
    banner.alpha = 0.0
    banner.transform = CGAffineTransform(translationX: 0, y: -8)
    UIView.animate(
      withDuration: 0.22, delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      banner.alpha = 1.0
      banner.transform = .identity
    }
  }

  @objc private func handleBridgeUsageBannerTapped() {
    dismissedBridgeUsageKey = bridgeUsageBanner?.accessibilityValue
    hideBridgeUsageBanner()
  }

  private func hideBridgeUsageBanner() {
    guard let banner = bridgeUsageBanner, !banner.isHidden else { return }
    UIView.animate(
      withDuration: 0.16, delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      banner.alpha = 0.0
      banner.transform = CGAffineTransform(translationX: 0, y: -8)
    } completion: { [weak self] _ in
      if banner.alpha <= 0.01 {
        banner.isHidden = true
        self?.onBridgeUsageBannerVisibilityChanged?()
      }
    }
  }

  /// Position the usage banner in the reserved top/header band, matching the pinned
  /// message banner instead of floating over the composer.
  private func layoutBridgeUsageBanner() {
    guard let banner = bridgeUsageBanner, !banner.isHidden else { return }
    let width = max(0.0, bounds.width - 32.0)
    let height = ChatPinnedBannerView.preferredHeight
    let topY = max(8.0, contentPaddingTop - height - 12.0)
    banner.frame = CGRect(x: 16.0, y: topY, width: width, height: height)
  }

  func setRows(_ nextRows: [[String: Any]]) {
    let startedAt = ProcessInfo.processInfo.systemUptime
    sourceRowsPayload = nextRows
    // [GroupCellOverlap] Fire settle-time overlap probes after this update lands (covers the
    // static finalize case where no scroll happens). Silent unless an overlap is detected.
    if isGroupOrChannel {
      for delay in [0.12, 0.45, 0.9] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
          self?.probeGroupCellOverlap(reason: "setRows+\(delay)s", force: true)
        }
      }
    }
    let traceChatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    VibeDebugLog.log(
      "[ChatListView] setRows called — count: %d, isApplying: %@", nextRows.count,
      isApplyingRowsUpdate ? "true" : "false")
    chatListUITrace(
      "ChatListView setRows start chatId=\(traceChatId.isEmpty ? "<empty>" : String(traceChatId.prefix(12))) incoming=\(nextRows.count) current=\(rows.count) applying=\(isApplyingRowsUpdate ? "Y" : "N") searchActive=\(searchQuery.isEmpty ? "N" : "Y")"
    )
    if isApplyingRowsUpdate {
      pendingRowsPayload = nextRows
      chatListUITrace(
        "ChatListView setRows queued chatId=\(traceChatId.isEmpty ? "<empty>" : String(traceChatId.prefix(12))) incoming=\(nextRows.count)"
      )
      return
    }
    isApplyingRowsUpdate = true
    _setRowsGeneration &+= 1
    let mySetRowsGeneration = _setRowsGeneration

    let mergedRows = mergedRowsPayload(from: nextRows)
    let visibleRows = filterRowsForSearch(mergedRows)
    let parsedAll = visibleRows.compactMap(ChatListRow.init).filter { row in
      guard row.messageType != "agent_progress" else { return false }
      // A live agent turn with nothing renderable yet (no tool/step, no narration, no
      // answer text) is held out of the transcript entirely — the header already shows
      // "Thinking…" for this state. The row appears the moment the first real chunk
      // streams in, landing directly at its normal full-width layout instead of a
      // centered placeholder pill that then grows.
      if bubbleUsesAgentTurnContent(row), agentTurnBubbleIsCompactThinking(row) {
        return false
      }
      return true
    }
    // Inbox mode: split raw agent event notifications out of the transcript and
    // report them to the host so they surface via the Inbox banner/view. Batched
    // summary rows stay in the main chat as the clean default agent view.
    var parsed: [ChatListRow]
    let hasInboxOnlyRows = parsedAll.contains { $0.kind == .message && $0.hiddenFromTranscript }
    if eventInboxModeEnabled || hasInboxOnlyRows {
      var transcript: [ChatListRow] = []
      var inbox: [ChatListRow] = []
      for row in parsedAll {
        let shouldRouteToInbox =
          row.hiddenFromTranscript
          || (eventInboxModeEnabled && row.isEventNotification && !row.isEventInboxSummary)
        if row.kind == .message, shouldRouteToInbox
        {
          inbox.append(row)
        } else {
          transcript.append(row)
        }
      }
      eventInboxRows = inbox
      parsed = transcript
      let latestPreview = inbox.last.map { eventInboxPreviewText(for: $0) }
      let count = inbox.count
      DispatchQueue.main.async { [weak self] in
        self?.onEventInboxChanged?(count, latestPreview)
      }
    } else {
      if !eventInboxRows.isEmpty {
        eventInboxRows = []
        DispatchQueue.main.async { [weak self] in
          self?.onEventInboxChanged?(0, nil)
        }
      }
      parsed = parsedAll
    }
    // Bridge-agent DMs open fresh: hide prior history; newly sent/live rows and an
    // explicitly-loaded history session still show.
    parsed = bridgeFreshFiltered(parsed)
    // Bridge info-command results (/usage, /status, /commands, …) are answered right
    // here by the bridge (runtime.command.executable == "vibe-bridge"). They must NOT
    // land in the transcript — route them to the host (banner/overlay) and drop them.
    parsed = extractBridgeCommandRows(parsed)
    if parsed.isEmpty, !nextRows.isEmpty {
      // Incoming rows all dropped before render — dump the first raw row's shape so
      // the drop point (ChatListRow.init vs a filter) is identifiable from device logs.
      let firstRow = nextRows[0]
      NSLog(
        "[ChatOpen] setRows ALL-DROPPED incoming=%d merged=%d parsedAll=%d keys=[%@] kind=%@ type=%@",
        nextRows.count, mergedRows.count, parsedAll.count,
        firstRow.keys.sorted().joined(separator: ","),
        (firstRow["kind"] as? String) ?? "nil",
        ((firstRow["message"] as? [String: Any])?["type"] as? String) ?? "nil")
    }
    // Agent DMs decrypt per-row (E2E actions/attachments) and self-size every bubble —
    // rendering a long transcript (hundreds of rows) blocks the main thread for seconds
    // and overheats the device. Only keep the latest window needed to continue; older
    // turns load on demand via History. (Normal chats keep their full list.)
    let effectiveBridgeLoadedSessionId =
      bridgeLoadedSessionId
      ?? ChatEngine.shared.liveBridgeSessionId(
        chatId: engineChatId.trimmingCharacters(in: .whitespacesAndNewlines))
    if currentBridgeProvider != nil, effectiveBridgeLoadedSessionId == nil,
      parsed.count > Self.agentTranscriptWindow
    {
      parsed = Array(parsed.suffix(Self.agentTranscriptWindow))
    }
    if isGroupOrChannel {
      parsed = parsed.map { row in
        var next = row
        next.isGroupOrChannel = true
        return next
      }
    }
    dismissBridgeSpinnerIfSessionLoaded(parsed)
    adoptActiveBridgeSessionId(from: parsed)
    pruneAgentTurnState(for: parsed)
    if let targetMessageId = reactionDebugTargetMessageId, reactionDebugRemainingRowsChecks > 0 {
      reactionDebugRemainingRowsChecks -= 1
      if let row = parsed.first(where: { $0.messageId == targetMessageId }) {
        reactionDebugLog(
          "setRows target id=\(targetMessageId) reaction=\(row.reactionEmoji ?? "nil") checksLeft=\(reactionDebugRemainingRowsChecks)"
        )
      } else {
        reactionDebugLog(
          "setRows target missing id=\(targetMessageId) parsedCount=\(parsed.count) checksLeft=\(reactionDebugRemainingRowsChecks)"
        )
      }
    }
    let previousRows = rows
    let previousContentOffsetY = collectionView.contentOffset.y
    let previousDistanceFromBottom = currentDistanceFromBottom()
    let wasNearBottom = previousDistanceFromBottom <= listBottomThreshold

    // NOTE: Do NOT set `rows = parsed` here. The data source (`rows`) must
    // reflect the OLD count until inside performBatchUpdates, otherwise UIKit
    // sees a mismatch between "before" count and the insert/delete operations.

    // Capture a stationary anchor: the topmost visible item's key and its screen-Y.
    let stationaryAnchor: (key: String, screenY: CGFloat)? = {
      guard !wasNearBottom else { return nil }
      let visibleIndexPaths = collectionView.indexPathsForVisibleItems
        .sorted { lhs, rhs in
          if lhs.section == rhs.section {
            return lhs.item < rhs.item
          }
          return lhs.section < rhs.section
        }
      guard let topIndexPath = visibleIndexPaths.first,
        topIndexPath.item < previousRows.count,
        let cell = collectionView.cellForItem(at: topIndexPath)
      else {
        return nil
      }
      let row = previousRows[topIndexPath.item]
      let screenY = cell.frame.minY - collectionView.contentOffset.y
      return (row.key, screenY)
    }()

    let applyDataSource = { [weak self] in
      guard let self else { return }
      self.rows = parsed
      if let agentVC = self.presentedBridgeAgentVC {
        agentVC.setMessages(VibeAgentKitMap.messages(from: parsed))
      }
      // Keep the DM agent composer's trailing control (SEND vs STOP) in sync with the
      // live state of the rows — a streaming/running turn forces STOP so the user can
      // interrupt it. The full-page runtime view drives its own composer separately.
      self.agentComposerView?.setTaskActive(self.agentComposerHasLiveTask())
      self.pruneMessageSelection(for: parsed)
      let engineChatId = self.engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      let resolvedChatId: String
      if !engineChatId.isEmpty {
        resolvedChatId = engineChatId
      } else {
        resolvedChatId =
          parsed.first(where: { row in
            if let chatId = row.chatId?.trimmingCharacters(in: .whitespacesAndNewlines) {
              return !chatId.isEmpty
            }
            return false
          })?.chatId?.trimmingCharacters(in: .whitespacesAndNewlines)
          ?? ""
      }
      if !resolvedChatId.isEmpty {
        ChatAudioQueueRegistry.shared.setRows(parsed, for: resolvedChatId)
        VoiceBubblePlaybackCoordinator.shared.refreshCurrentSnapshotIfNeeded(forChatId: resolvedChatId)
      }
    }

    // Set to true (before calling finalize) by the reconfigure path when this update is
    // ONLY a streaming agent turn growing in place — no inserts, no deletes, no other
    // reloads. For that case the offset-management rules change: the content grows
    // BELOW the viewport, so the right default is to not move the offset at all (the
    // user owns the scroll), with a gentle animated follow only when they were already
    // reading at the bottom. Snapping (scrollToBottom) or re-anchoring to a captured
    // distance-from-bottom (restoreStationaryDistance) both read as the per-chunk
    // "jumping" during long agent runs.
    var inPlaceAgentTurnGrowth = false

    let finalize = { [weak self] (animated: Bool) in
      guard let self else {
        return
      }
      let pendingPayload = self.pendingSendTransition
      let shouldDeferPendingBottomScroll =
        pendingPayload.map { self.shouldDeferBottomScrollForPendingSend($0, parsedRows: parsed) }
        ?? false
      let shouldForceBottomForPendingSend =
        (self.pendingSendTransition != nil || self.activeSendTransition != nil
          || self.hiddenMessageId != nil)
        && self.deferredPendingSendBottomScrollMessageId == nil
      self.collectionView.layoutIfNeeded()
      self.updateBottomAnchorInset()
      // Force a second layout pass so contentSize reflects the inset change
      // before scrollToBottom reads it. Without this, maxOffsetY can be 0
      // causing the newest message to appear at the top instead of the bottom.
      self.collectionView.layoutIfNeeded()
      let postInsetContentH = self.collectionView.contentSize.height
      let postInsetOffset = self.collectionView.contentOffset.y
      let setRowsDurationMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
      chatListUITrace(
        "ChatListView setRows finalize chatId=\(traceChatId.isEmpty ? "<empty>" : String(traceChatId.prefix(12))) parsed=\(parsed.count) animated=\(animated ? "Y" : "N") wasNearBottom=\(wasNearBottom ? "Y" : "N") queued=\(self.pendingRowsPayload != nil ? "Y" : "N") durationMs=\(setRowsDurationMs) contentH=\(Int(postInsetContentH)) offsetY=\(Int(postInsetOffset))"
      )
      // Main-thread watchdog: one setRows pass owning the thread past a frame-ish budget
      // is exactly what the user feels as "can't start scrolling while it streams". Keep
      // this visible in plain device logs (chatListUITrace is silent by default).
      if setRowsDurationMs > 48 {
        NSLog(
          "[MainThreadStall] setRows took %dms rows=%d streaming=%@ tracking=%@",
          setRowsDurationMs, parsed.count,
          parsed.contains(where: { $0.isStreamingText }) ? "Y" : "N",
          self.collectionView.isTracking ? "Y" : "N")
      }
      // Only the dedicated "Vibe AI" surface (agentChatMode) uses the ChatGPT-style
      // pin-question-to-top / reserve-room-below scroll strategy. An inline Claude/Codex
      // bridge DM (currentBridgeProvider != nil) now renders in the NORMAL chat list and
      // must behave like any other chat — stick-to-bottom / stationary-anchor — so it
      // falls through to the normal branches below instead of pinning to the top.
      let agentSurface = self.agentChatMode
      if agentSurface, self.pendingAgentPushToTop {
        self.pendingAgentPushToTop = false
        self.performAgentPushToTop(animated: animated)
      } else if agentSurface {
        // Agent surface: while a pin is active, only SHRINK the reserved room below
        // the question (forceOffset:false) so the dead space collapses as the answer
        // grows — never move the offset. Once the turn ends and the reserve is gone
        // (or the user has taken over scrolling) do nothing at all: the user owns the
        // scroll. Crucially we must NOT fall through to the normal-chat near-bottom /
        // stationary-anchor / restore branches below, which yank the offset around.
        if self.agentStreaming || self.agentPushToTopSpacer > 0 {
          self.applyAgentPin(forceOffset: false)
        }
      } else if shouldDeferPendingBottomScroll, let pendingPayload {
        self.deferredPendingSendBottomScrollMessageId = pendingPayload.messageId
        self.projectedSendTransitionMessageId = pendingPayload.messageId
        let maxOffset = max(
          0.0, self.collectionView.contentSize.height - self.collectionView.bounds.height)
        let clampedOffset = pixelAlignedValue(max(0.0, min(maxOffset, previousContentOffsetY)))
        self.performInternalScrollAdjustment {
          self.collectionView.setContentOffset(CGPoint(x: 0.0, y: clampedOffset), animated: false)
        }
        self.shouldAutoScroll = true
      } else if wasNearBottom || shouldForceBottomForPendingSend {
        if inPlaceAgentTurnGrowth && !shouldForceBottomForPendingSend {
          self.followBottomForAgentTurnGrowth()
        } else {
          self.scrollToBottom(animated: shouldForceBottomForPendingSend ? false : animated)
        }
      } else if let anchor = stationaryAnchor,
        let newIndex = parsed.firstIndex(where: { $0.key == anchor.key })
      {
        let ip = IndexPath(item: newIndex, section: 0)
        if let attrs = self.collectionView.layoutAttributesForItem(at: ip) {
          let desiredOffset = attrs.frame.minY - anchor.screenY
          let maxOffset = max(
            0.0, self.collectionView.contentSize.height - self.collectionView.bounds.height)
          let clampedOffset = pixelAlignedValue(max(0.0, min(maxOffset, desiredOffset)))
          self.performInternalScrollAdjustment {
            self.collectionView.setContentOffset(CGPoint(x: 0.0, y: clampedOffset), animated: false)
          }
        }
      } else if inPlaceAgentTurnGrowth {
        // Pure in-place growth with the user scrolled up and no findable anchor: the
        // growth is below them, so the offset is already stationary — re-anchoring to
        // the captured distance-from-bottom would drag them DOWN by the growth delta.
      } else {
        self.restoreStationaryDistance(previousDistanceFromBottom)
      }
      self.previousOffsetY = self.collectionView.contentOffset.y
      self.emitViewport(force: true)
      self.finishRowsUpdate()
      // Rows updates that land mid-send-morph (server echo, grouping patch on
      // the previous bubble, height settle) can move the target cell without
      // any scroll event firing — re-sync the overlay's model frame so it keeps
      // flying at the real cell instead of a stale rect.
      if let transition = self.activeSendTransition {
        self.updateTransitionFrame(transition)
      } else if let fading = self.fadingSendTransition {
        // Same for a rows update landing inside the ~55ms reveal crossfade
        // (e.g. the pending→sent status flip): the overlay ghost must follow
        // the cell it is fading out over.
        self.updateTransitionFrame(fading)
      }
      self.maybeStartPendingSendTransition()
    }

    let oldKeys = previousRows.map(\.key)
    let newKeys = parsed.map(\.key)
    let oldSet = Set(oldKeys)
    let newSet = Set(newKeys)
    let oldSharedOrder = oldKeys.filter { newSet.contains($0) }
    let newSharedOrder = newKeys.filter { oldSet.contains($0) }

    // Initial load or full replacement: use reloadData (no batch update needed).
    guard !previousRows.isEmpty else {
      if parsed.count <= 4 {
        NSLog(
          "[FirstMsg] setRows INITIAL surface=%@ chatId=%@ statusAuth=%@ parsed=%d keys=[%@] hidden=%@ pending=%@ src=%d window=%@ bounds=%.0fx%.0f",
          surfaceId.isEmpty ? "<none>" : surfaceId,
          traceChatId.isEmpty ? "<empty>" : String(traceChatId.prefix(12)),
          statusAuthorityEnabled ? "Y" : "N",
          parsed.count,
          parsed.map { String($0.key.prefix(16)) }.joined(separator: ","),
          hiddenMessageId.map { String($0.prefix(12)) } ?? "nil",
          pendingSendTransition != nil ? "Y" : "N",
          nextRows.count,
          window != nil ? "Y" : "N",
          collectionView.bounds.width, collectionView.bounds.height)
      }
      applyDataSource()
      UIView.performWithoutAnimation {
        collectionView.reloadData()
      }
      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        finalize(false)
        CATransaction.commit()
      }
      // A single-message initial load never scrolls (maxOffsetY == 0, so scrollToBottom
      // is a no-op), which means the HOST's own layoutSubviews — the pass that re-asserts
      // wallpaper z-order, refreshes the snapshot, and rebinds the freshly-created cell's
      // wallpaper backdrop — never runs after the cell exists. The bubble then stays
      // unpainted until the user's touch dirties the host layout (the "empty until I
      // tap/scroll" bug). Force that host layout pass now so the cell paints immediately.
      // (finalize already ran finishRowsUpdate, so isApplyingRowsUpdate is clear here.)
      if window != nil, !parsed.isEmpty, bounds.width > 1.0, bounds.height > 1.0 {
        UIView.performWithoutAnimation {
          setNeedsLayout()
          layoutIfNeeded()
          updateVisibleWallpaperBackdropLayouts()
        }
      }
      if parsed.count <= 4 {
        let cellDump = collectionView.visibleCells.compactMap { cell -> String? in
          guard let ip = collectionView.indexPath(for: cell) else { return nil }
          let ghost = (cell as? ChatListCell)?.isConfiguredGhostHidden == true
          return String(
            format: "i%d(y=%.0f h=%.0f a=%.2f%@)", ip.item, cell.frame.minY,
            cell.frame.height, cell.alpha, ghost ? " GHOST" : "")
        }.joined(separator: " ")
        NSLog(
          "[FirstMsg] setRows INITIAL done offset=%.0f contentH=%.0f inset(t=%.0f,b=%.0f) visible=%d window=%@ cells=[%@]",
          collectionView.contentOffset.y,
          collectionView.contentSize.height,
          flowLayout.sectionInset.top, flowLayout.sectionInset.bottom,
          collectionView.indexPathsForVisibleItems.count,
          window != nil ? "Y" : "N",
          cellDump)
      } else {
        // The large-transcript initial render (the one that matters for chat-open
        // latency) previously logged nothing — make its outcome and cost visible.
        NSLog(
          "[ChatOpen] setRows INITIAL done surface=%@ parsed=%d visible=%d contentH=%.0f offset=%.0f bounds=%.0fx%.0f durationMs=%d up=%.2f",
          surfaceId.isEmpty ? "<none>" : surfaceId,
          parsed.count,
          collectionView.indexPathsForVisibleItems.count,
          collectionView.contentSize.height,
          collectionView.contentOffset.y,
          collectionView.bounds.width, collectionView.bounds.height,
          Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000),
          ProcessInfo.processInfo.systemUptime)
      }
      return
    }

    // Reorder/move-heavy updates are uncommon here; fallback to full reload.
    guard oldSharedOrder == newSharedOrder else {
      // Find first mismatch to help debug which key triggered the reorder
      var mismatchIdx = -1
      for i in 0..<min(oldSharedOrder.count, newSharedOrder.count) {
        if oldSharedOrder[i] != newSharedOrder[i] {
          mismatchIdx = i
          break
        }
      }
      if mismatchIdx < 0 && oldSharedOrder.count != newSharedOrder.count {
        mismatchIdx = min(oldSharedOrder.count, newSharedOrder.count)
      }
      let insertedKeys = newKeys.filter { !oldSet.contains($0) }
      let deletedKeys = oldKeys.filter { !newSet.contains($0) }
      NSLog(
        "[ChatListView] ⚠️ reorder fallback — oldShared:%d newShared:%d mismatchAt:%d inserted:%d deleted:%d insertedKeys:%@ deletedKeys:%@",
        oldSharedOrder.count, newSharedOrder.count, mismatchIdx,
        insertedKeys.count, deletedKeys.count,
        insertedKeys.prefix(3).map { String($0.prefix(16)) }.joined(separator: ","),
        deletedKeys.prefix(3).map { String($0.prefix(16)) }.joined(separator: ","))
      if mismatchIdx >= 0, mismatchIdx < min(oldSharedOrder.count, newSharedOrder.count) {
        NSLog(
          "[ChatListView]   mismatch old:'%@' new:'%@'",
          String(oldSharedOrder[mismatchIdx].prefix(20)),
          String(newSharedOrder[mismatchIdx].prefix(20)))
      }

      // Animate small reorders near the bottom (e.g. after completeTransition
      // swaps the last 2 items). Capture pre-update screen positions BEFORE
      // reloadData so we can apply mode2 additive animations afterward.
      let reorderAnimMode = appearance.insertionAnimationMode
      let shouldAnimateReorder =
        wasNearBottom
        && reorderAnimMode == 2
        && insertedKeys.count + deletedKeys.count <= 3

      var preReorderScreenY: [String: CGFloat] = [:]
      var preReorderOffset: CGFloat = 0
      if shouldAnimateReorder {
        preReorderOffset = collectionView.contentOffset.y
        for cell in collectionView.visibleCells {
          guard let ip = collectionView.indexPath(for: cell), ip.item < rows.count else { continue }
          preReorderScreenY[rows[ip.item].key] = cell.center.y - preReorderOffset
        }
      }

      applyDataSource()
      UIView.performWithoutAnimation {
        collectionView.reloadData()
      }
      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        finalize(false)
        CATransaction.commit()
      }

      // Apply mode2 additive animations after reloadData so the reorder
      // appears smooth instead of an instant jump.
      // Skip if a queued setRows ran during finalize (cells were
      // recreated/repositioned — our pre-reorder positions are stale).
      let reorderQueuedProcessed = _setRowsGeneration != mySetRowsGeneration
      if shouldAnimateReorder, !preReorderScreenY.isEmpty, !reorderQueuedProcessed {
        collectionView.layoutIfNeeded()

        // Strip UIKit implicit animations (same as the batch-update path).
        for cell in collectionView.visibleCells {
          cell.alpha = 1.0
          cell.contentView.alpha = 1.0
          cell.layer.removeAnimation(forKey: "opacity")
          cell.layer.removeAnimation(forKey: "position")
          cell.layer.removeAnimation(forKey: "bounds.size")
          cell.layer.removeAnimation(forKey: "bounds.origin")
          cell.layer.removeAnimation(forKey: "bounds")
          cell.layer.removeAnimation(forKey: "transform")
          cell.contentView.layer.removeAnimation(forKey: "opacity")
          cell.contentView.layer.removeAnimation(forKey: "position")
          cell.layer.opacity = 1.0
          cell.contentView.layer.opacity = 1.0
        }

        let postReorderOffset = collectionView.contentOffset.y
        let animDuration: CFTimeInterval = 0.3
        let animTiming = chatListSendVerticalTiming
        var reorderShifted = 0

        for cell in collectionView.visibleCells {
          guard let ip = collectionView.indexPath(for: cell), ip.item < rows.count else { continue }
          let key = rows[ip.item].key
          if let oldScreenY = preReorderScreenY[key] {
            let currentScreenY = cell.center.y - postReorderOffset
            let delta = pixelAlignedValue(oldScreenY - currentScreenY)
            if abs(delta) > 0.5 {
              let anim = CABasicAnimation(keyPath: "position.y")
              anim.fromValue = delta as NSNumber
              anim.toValue = 0.0 as NSNumber
              anim.isAdditive = true
              anim.duration = animDuration
              anim.timingFunction = animTiming
              anim.isRemovedOnCompletion = true
              cell.layer.add(anim, forKey: "reorderShift")
              reorderShifted += 1
            }
          } else {
            // New cell that wasn't visible before — fade in.
            let fadeAnim = CABasicAnimation(keyPath: "opacity")
            fadeAnim.fromValue = 0.0 as NSNumber
            fadeAnim.toValue = 1.0 as NSNumber
            fadeAnim.duration = animDuration
            fadeAnim.timingFunction = animTiming
            fadeAnim.isRemovedOnCompletion = true
            cell.layer.add(fadeAnim, forKey: "reorderFadeIn")
          }
        }
      }

      return
    }

    let deletions = previousRows.enumerated()
      .filter { !newSet.contains($0.element.key) }
      .map { IndexPath(item: $0.offset, section: 0) }
      .sorted { $0.item > $1.item }
    let insertions = parsed.enumerated()
      .filter { !oldSet.contains($0.element.key) }
      .map { IndexPath(item: $0.offset, section: 0) }
      .sorted { $0.item < $1.item }

    let previousByKey = Dictionary(uniqueKeysWithValues: previousRows.map { ($0.key, $0) })
    let previousIndexByKey = Dictionary(
      uniqueKeysWithValues: previousRows.enumerated().map { ($0.element.key, $0.offset) })
    let reloads = parsed.compactMap { row -> IndexPath? in
      guard let previous = previousByKey[row.key], let oldIndex = previousIndexByKey[row.key]
      else {
        return nil
      }
      return chatListRowContentEqual(previous, row)
        ? nil
        : IndexPath(item: oldIndex, section: 0)
    }
    let safeReloads = reloads.filter { $0.item >= 0 && $0.item < previousRows.count }

    guard !deletions.isEmpty || !insertions.isEmpty || !safeReloads.isEmpty else {
      applyDataSource()
      finalize(false)
      return
    }

    if deletions.isEmpty && insertions.isEmpty && !safeReloads.isEmpty {
      let rowWidth = max(0.0, bounds.width - (messageHorizontalInset * 2.0))
      let requiresLayoutReload = safeReloads.contains { indexPath in
        guard indexPath.item < previousRows.count, indexPath.item < parsed.count else {
          return true
        }
        let previousRow = previousRows[indexPath.item]
        let nextRow = parsed[indexPath.item]
        guard previousRow.kind == nextRow.kind else {
          return true
        }
        guard previousRow.kind == .message else {
          return false
        }
        return abs(
          estimateMessageHeight(previousRow, rowWidth: rowWidth)
            - estimateMessageHeight(nextRow, rowWidth: rowWidth)
        ) > 0.5
      }

      applyDataSource()

      // Reactions add badge height to the bubble, so a content-only reconfigure
      // is not enough. Force a targeted relayout for height-changing reloads.
      if requiresLayoutReload {
        // A streaming agent turn changes height every chunk. `reloadItems` would
        // recreate the cell each time — throwing away VibeAgentKitAssistantMessageBodyView's
        // reusable live feed (`liveFeedViewsByKey`) so the whole narration re-fades in on
        // every token (the exact "batched / flickery" bug that reuse was built to avoid).
        // Route those rows through `reconfigureItems` instead so the SAME cell + body view
        // persists and just grows smoothly; `invalidateLayout` still re-queries the new
        // height. Non-agent height changes (e.g. reactions) keep the reloadItems path.
        let agentTurnReloads = safeReloads.filter { indexPath in
          guard indexPath.item < rows.count else { return false }
          return bubbleUsesAgentTurnContent(rows[indexPath.item])
        }
        let otherReloads = safeReloads.filter { !agentTurnReloads.contains($0) }
        inPlaceAgentTurnGrowth = otherReloads.isEmpty && !agentTurnReloads.isEmpty
        UIView.performWithoutAnimation {
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          flowLayout.invalidateLayout()
          collectionView.performBatchUpdates(
            {
              if !otherReloads.isEmpty {
                collectionView.reloadItems(at: otherReloads)
              }
              if !agentTurnReloads.isEmpty {
                if #available(iOS 15.0, *), self.rows.count > 1 {
                  collectionView.reconfigureItems(at: agentTurnReloads)
                } else {
                  collectionView.reloadItems(at: agentTurnReloads)
                }
              }
            },
            completion: nil)
          CATransaction.commit()
        }
        UIView.performWithoutAnimation {
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          finalize(false)
          CATransaction.commit()
        }
        return
      }

      // Telegram approach: content updates are INSTANT — no opacity, no
      // crossfade, no animation of any kind. Just swap the content.
      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for indexPath in safeReloads {
          guard indexPath.item < rows.count else { continue }
          if let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell {
            let row = rows[indexPath.item]
            cell.applyAppearance(appearance)
            cell.configure(
              row: row,
              hiddenMessageId: hiddenMessageId,
              selectionMode: selectionMode,
              selected: row.messageId.map { selectedMessageIds.contains($0) } ?? false,
              agentTurnState: agentTurnBubbleState(for: row)
            )
            bindWallpaperBackdrop(to: cell)
            cell.alpha = 1.0
            cell.contentView.alpha = 1.0
            cell.layer.opacity = 1.0
            cell.contentView.layer.opacity = 1.0
            cell.layer.removeAllAnimations()
            cell.contentView.layer.removeAllAnimations()
          }
        }
        CATransaction.commit()
      }
      // Lightweight finalize: skip updateBottomAnchorInset + scrollToBottom.
      // Reloads don't change cell count or total height, so insets and scroll
      // position are unchanged. Running the full finalize here triggers
      // updateBottomAnchorInset which can shift cells by 2-3px while additive
      // animations from a prior insertion are still in flight, causing flicker.
      previousOffsetY = collectionView.contentOffset.y
      emitViewport(force: true)
      finishRowsUpdate()
      maybeStartPendingSendTransition()
      chatListUITrace(
        "ChatListView setRows content-reconfigure chatId=\(traceChatId.isEmpty ? "<empty>" : String(traceChatId.prefix(12))) reloads=\(safeReloads.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
      )
      return
    }

    NSLog(
      "[ChatListView] setRows batchUpdate — del:%d ins:%d reload:%d (dataSource before: %d, after: %d)",
      deletions.count, insertions.count, safeReloads.count, previousRows.count, parsed.count)

    let expectedAfterCount = previousRows.count + insertions.count - deletions.count
    guard expectedAfterCount == parsed.count else {
      let insertedKeys = parsed.enumerated().filter { !oldSet.contains($0.element.key) }.map {
        String($0.element.key.prefix(16))
      }
      NSLog(
        "[ChatListView] ⚠️ batch count mismatch (expected %d, got %d) — falling back to reloadData insertedKeys:%@",
        expectedAfterCount, parsed.count, insertedKeys.prefix(5).joined(separator: ","))
      applyDataSource()
      UIView.performWithoutAnimation {
        collectionView.reloadData()
      }
      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        finalize(false)
        CATransaction.commit()
      }
      return
    }

    // Determine animation mode from appearance (0=none, 1=slideUpNew, 2=telegramOffset, 3=springBatch)
    let animMode = appearance.insertionAnimationMode

    // A finishing agent turn swaps its live `stream-…` row for the settled
    // `bridge-<sessionId>-…` card (and a late-arriving history snapshot swaps the other
    // way): same message to the user, but a NEW key to the differ. Rendered as a normal
    // delete+insert this replays the arrival animation — translate-Y slide + scroll —
    // on a bubble the user is already reading (the "cell re-animates a second later"
    // jump). Detect the swap and apply it as an instant, animation-free frame.
    let isAgentRowSwapRow = { (row: ChatListRow) -> Bool in
      guard row.isAgentMessage else { return false }
      let id = row.messageId ?? row.key
      return id.hasPrefix("stream-") || id.hasPrefix("bridge-")
        || row.key.hasPrefix("stream-") || row.key.hasPrefix("bridge-")
    }
    let isAgentSettleSwap =
      !deletions.isEmpty && !insertions.isEmpty
      && deletions.allSatisfy { ip in
        ip.item < previousRows.count && isAgentRowSwapRow(previousRows[ip.item])
      }
      && insertions.allSatisfy { ip in
        ip.item < parsed.count && isAgentRowSwapRow(parsed[ip.item])
      }
    if isAgentSettleSwap {
      NSLog(
        "[SettleSwap] agent stream↔session swap — applying without animation del=%d ins=%d delKeys=[%@] insKeys=[%@]",
        deletions.count, insertions.count,
        deletions.prefix(2).compactMap { ip -> String? in
          ip.item < previousRows.count ? String(previousRows[ip.item].key.prefix(20)) : nil
        }.joined(separator: ","),
        insertions.prefix(2).compactMap { ip -> String? in
          ip.item < parsed.count ? String(parsed[ip.item].key.prefix(20)) : nil
        }.joined(separator: ","))
    }

    // Animate insertions and deletions for small incremental appends near the bottom.
    // During a send transition, we still animate EXISTING cells shifting
    // (so the list moves smoothly) but skip fade-in on the new cell
    // (the overlay handles that).
    let isSmallUpdate =
      (insertions.count + deletions.count) > 0 && (insertions.count + deletions.count) <= 5
    let shouldAnimateUpdate =
      isSmallUpdate
      && wasNearBottom
      && animMode > 0  // mode 0 = no animation
      && !isAgentSettleSwap

    let insertedKeysSummary = insertions.prefix(3).compactMap { ip -> String? in
      guard ip.item < parsed.count else { return nil }
      let row = parsed[ip.item]
      return
        "\(String(row.key.prefix(12)))(\(row.isMe ? "me" : "them"),\(row.isAgentMessage ? "agent" : "user"))"
    }.joined(separator: " ")
    NSLog(
      "[ChatListView] animDecision — shouldAnim:%@ isSmall:%@ wasNear:%@ mode:%d del:%d ins:%d reload:%d keys:[%@]",
      shouldAnimateUpdate ? "Y" : "N", isSmallUpdate ? "Y" : "N",
      wasNearBottom ? "Y" : "N", animMode,
      deletions.count, insertions.count, safeReloads.count, insertedKeysSummary)

    // Animate scroll-to-bottom for small appends, BUT NOT during a send
    // transition. During send, we scroll instantly so the cell is at its
    // final position before the overlay animation starts (otherwise the
    // overlay "chases" the scrolling cell and appears at the wrong spot).
    let hasPendingSend = pendingSendTransition != nil || activeSendTransition != nil
    let shouldAnimateScroll =
      isSmallUpdate
      && wasNearBottom
      && !hasPendingSend
      && !isAgentSettleSwap

    // --- Telegram-style frame recording (mode 2 only) ---
    // Record SCREEN-SPACE Y (center.y - contentOffset.y) so additive
    // animations account for any scroll change finalize introduces.
    var preUpdateScreenY: [String: CGFloat] = [:]
    var preUpdateOffset: CGFloat = 0
    if shouldAnimateUpdate && animMode == 2 {
      preUpdateOffset = collectionView.contentOffset.y
      for cell in collectionView.visibleCells {
        guard let ip = collectionView.indexPath(for: cell), ip.item < previousRows.count else {
          continue
        }
        let key = previousRows[ip.item].key
        preUpdateScreenY[key] = cell.center.y - preUpdateOffset
      }
    }
    let insertedKeySet = Set(
      insertions.compactMap { ip -> String? in
        guard ip.item < parsed.count else { return nil }
        return parsed[ip.item].key
      })

    // ===================================================================
    // MODE 3: Spring Batch — UIView.animate wraps entire performBatchUpdates
    // ===================================================================
    if shouldAnimateUpdate && animMode == 3 {
      UIView.animate(
        withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.0,
        options: [.allowUserInteraction, .beginFromCurrentState],
        animations: { [weak self] in
          guard let self else { return }
          self.collectionView.performBatchUpdates(
            {
              applyDataSource()
              if !deletions.isEmpty {
                self.collectionView.deleteItems(at: deletions)
              }
              if !insertions.isEmpty {
                self.collectionView.insertItems(at: insertions)
              }
              if !safeReloads.isEmpty {
                if #available(iOS 15.0, *), self.rows.count > 1 {
                  self.collectionView.reconfigureItems(at: safeReloads)
                } else {
                  self.collectionView.reloadItems(at: safeReloads)
                }
              }
            }, completion: nil)
        },
        completion: { _ in
          finalize(shouldAnimateScroll)
        })
      return
    }

    // ===================================================================
    // MODES 0, 1, 2: Batch update without UIKit animation, then add
    //                 additive CAAnimations synchronously (same frame).
    // ===================================================================
    // IMPORTANT: Animations are applied synchronously after the batch
    // update (not in the completion handler) to guarantee they're in the
    // same render frame. The completion handler fires asynchronously,
    // which causes a 1-frame jump before the animation starts.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    UIView.performWithoutAnimation {
      collectionView.performBatchUpdates(
        {
          applyDataSource()
          if !deletions.isEmpty {
            collectionView.deleteItems(at: deletions)
          }
          if !insertions.isEmpty {
            collectionView.insertItems(at: insertions)
          }
          if !safeReloads.isEmpty {
            if #available(iOS 15.0, *), rows.count > 1 {
              collectionView.reconfigureItems(at: safeReloads)
            } else {
              collectionView.reloadItems(at: safeReloads)
            }
          }
        },
        completion: nil)
    }
    CATransaction.commit()

    // Force layout so cells are at their final post-update positions.
    collectionView.layoutIfNeeded()

    // For mode2 inserts (received messages): use ANIMATED scroll instead
    // of instant scroll + additive animations. This gives a natural
    // "push up" effect identical to one-on-one chats — the scroll
    // animation itself moves existing cells up and reveals the new cell
    // from below. The additive approach can't achieve this because the
    // new cell starts off-screen (below the clip boundary) and "pops in".
    // During send transitions we still use the additive path because
    // the cell is hidden and the overlay handles the visual.
    let useAnimatedScrollInsert =
      shouldAnimateUpdate
      && animMode == 2
      && shouldAnimateScroll  // wasNearBottom + !hasPendingSend
      && !insertions.isEmpty
      && deletions.isEmpty

    if useAnimatedScrollInsert {
      // Finalize settles layout + inset but scrolls instantly.
      finalize(false)

      // Strip UIKit implicit animations (prevent opacity flicker).
      for cell in collectionView.visibleCells {
        cell.alpha = 1.0
        cell.contentView.alpha = 1.0
        cell.layer.removeAnimation(forKey: "opacity")
        cell.layer.removeAnimation(forKey: "position")
        cell.layer.removeAnimation(forKey: "bounds.size")
        cell.layer.removeAnimation(forKey: "bounds.origin")
        cell.layer.removeAnimation(forKey: "bounds")
        cell.layer.removeAnimation(forKey: "transform")
        cell.contentView.layer.removeAnimation(forKey: "opacity")
        cell.contentView.layer.removeAnimation(forKey: "position")
        cell.layer.opacity = 1.0
        cell.contentView.layer.opacity = 1.0
      }

      // Undo the instant scroll, then animate it. The UIView spring
      // scroll naturally pushes existing cells up and reveals the new
      // cell from the bottom — no additive animations needed.
      // Scroll back to pre-update position BEFORE starting the animated scroll.
      // Use performInternalScrollAdjustment to avoid the scrollViewDidScroll
      // logic marking the list as not-near-bottom.
      performInternalScrollAdjustment {
        collectionView.setContentOffset(
          CGPoint(x: 0, y: preUpdateOffset), animated: false)
      }
      // Now animate to bottom. scrollToBottom sets isInternalScrollAdjustment
      // and resets it in the completion handler.
      scrollToBottom(animated: true)

      updateDebugStats(shifted: 0, newSlide: 0, maxDelta: 0, scrollDelta: 0)
      return
    }

    // Finalize: settle layout + scroll to bottom instantly.
    // Cells land at their true final screen positions so we can
    // compute screen-space deltas for additive animations.
    finalize(false)

    // Detect if finishRowsUpdate processed a queued setRows (recursive).
    // When that happens, cells may have been recreated/repositioned by
    // the recursive update's own animation (reorder, reload, etc).
    // Applying additive animations from the OUTER batch update would use
    // stale preUpdateScreenY positions and conflict with the recursive
    // update's animation, causing a visible gap/shift.
    let queuedUpdateProcessed = _setRowsGeneration != mySetRowsGeneration

    // CRITICAL (Telegram approach): Strip ALL UIKit-implicit animations
    // from every visible cell. UICollectionView sneaks in opacity/position/
    // bounds animations during performBatchUpdates even inside
    // performWithoutAnimation. We must remove them BEFORE applying our
    // own additive position animations. Without this, cells show brief
    // opacity flicker/transparency during insertions.
    for cell in collectionView.visibleCells {
      cell.alpha = 1.0
      cell.contentView.alpha = 1.0
      cell.layer.removeAnimation(forKey: "opacity")
      cell.layer.removeAnimation(forKey: "position")
      cell.layer.removeAnimation(forKey: "bounds.size")
      cell.layer.removeAnimation(forKey: "bounds.origin")
      cell.layer.removeAnimation(forKey: "bounds")
      cell.layer.removeAnimation(forKey: "transform")
      cell.contentView.layer.removeAnimation(forKey: "opacity")
      cell.contentView.layer.removeAnimation(forKey: "position")
      // Ensure absolute full opacity — no transparency at any point.
      cell.layer.opacity = 1.0
      cell.contentView.layer.opacity = 1.0
    }

    if queuedUpdateProcessed {
      NSLog("[ChatListAnim] skipping additive — queued setRows processed during finalize")
      maybeStartPendingSendTransition()
      return
    }

    if shouldAnimateUpdate {
      // Telegram timing: 0.3s spring (matches kCAMediaTimingFunctionSpring).
      // NOT a custom cubic bezier — a real spring with 0.3s settling time.
      let animDuration: CFTimeInterval = 0.3
      let animTiming = chatListSendVerticalTiming
      var dbgShifted = 0
      var dbgNewSlide = 0
      var dbgMaxDelta: CGFloat = 0
      var dbgScrollDelta: CGFloat = 0

      switch animMode {
      case 1:
        // MODE 1: SlideUpNewOnly — only new cells get animation
        for ip in insertions {
          guard let cell = collectionView.cellForItem(at: ip) else { continue }
          if let hid = hiddenMessageId, ip.item < rows.count,
            rows[ip.item].messageId == hid
          {
            continue
          }
          // Skip slide animation for media/GIF/sticker — just appear in place.
          if ip.item < rows.count {
            let vk = rows[ip.item].visualKind
            if vk == .media || vk == .sticker || vk == .video || vk == .videoNote {
              continue
            }
          }
          let slideUp = CABasicAnimation(keyPath: "position.y")
          slideUp.fromValue = pixelAlignedValue(debugAnimSlideOffset) as NSNumber
          slideUp.toValue = 0.0 as NSNumber
          slideUp.isAdditive = true
          slideUp.duration = animDuration
          slideUp.timingFunction = animTiming
          slideUp.isRemovedOnCompletion = true
          cell.layer.add(slideUp, forKey: "insertSlideUp")
          dbgNewSlide += 1
        }

      case 2:
        // MODE 2: TelegramOffset — additive position animation for ALL cells
        // Use screen-space deltas so the animation accounts for any
        // scroll change that finalize introduced.
        let postOffset = collectionView.contentOffset.y
        dbgScrollDelta = postOffset - preUpdateOffset

        // --- Pass 1: compute shift deltas for existing cells ---
        // We need the max delta BEFORE applying new-cell animations so
        // the new cell's slide distance matches the existing shift.
        // Without this, the new cell uses a tiny fixed offset (e.g. 20)
        // while existing cells shift by ~74, causing the new cell to
        // visually overlap/appear above existing bubbles at T=0.
        struct CellAnimInfo {
          let cell: UICollectionViewCell
          let key: String
          let indexPath: IndexPath
          let delta: CGFloat  // shift delta for existing cells
          let isNew: Bool
          let isHiddenForSend: Bool
        }
        var cellInfos: [CellAnimInfo] = []
        for cell in collectionView.visibleCells {
          guard let ip = collectionView.indexPath(for: cell),
            ip.item < rows.count
          else { continue }
          let key = rows[ip.item].key

          if let oldScreenY = preUpdateScreenY[key] {
            let currentScreenY = cell.center.y - postOffset
            let delta = pixelAlignedValue(oldScreenY - currentScreenY)
            cellInfos.append(
              CellAnimInfo(
                cell: cell, key: key, indexPath: ip, delta: delta,
                isNew: false, isHiddenForSend: false))
            if abs(delta) > 0.5 {
              dbgMaxDelta = max(dbgMaxDelta, abs(delta))
            }
          } else if insertedKeySet.contains(key) {
            let isHidden: Bool = {
              guard let hid = self.hiddenMessageId, ip.item < self.rows.count else { return false }
              return self.rows[ip.item].messageId == hid
            }()
            cellInfos.append(
              CellAnimInfo(
                cell: cell, key: key, indexPath: ip, delta: 0,
                isNew: true, isHiddenForSend: isHidden))
          }
        }

        // New cells must start BELOW all existing cells' old positions.
        // Use the max existing shift (which equals how far existing cells
        // "push up") so the new cell slides in from below, not from the
        // middle of existing bubbles.
        let newCellSlideOffset = pixelAlignedValue(
          max(dbgMaxDelta, debugAnimSlideOffset))

        // --- Pass 2: apply animations ---
        for info in cellInfos {
          if !info.isNew {
            if abs(info.delta) > 0.5 {
              let anim = CABasicAnimation(keyPath: "position.y")
              anim.fromValue = info.delta as NSNumber
              anim.toValue = 0.0 as NSNumber
              anim.isAdditive = true
              anim.duration = animDuration
              anim.timingFunction = animTiming
              anim.isRemovedOnCompletion = true
              info.cell.layer.add(anim, forKey: "insertionShift")
              dbgShifted += 1
            }
          } else if !info.isHiddenForSend {
            // Skip slide animation for media/GIF/sticker — just appear in place.
            let skipSlide: Bool = {
              guard info.indexPath.item < rows.count else { return false }
              let vk = rows[info.indexPath.item].visualKind
              return vk == .media || vk == .sticker || vk == .video || vk == .videoNote
            }()
            if !skipSlide {
              // Additive path fallback (only reached during send transitions
              // where shouldAnimateScroll is false). For normal receives, the
              // animated-scroll path above handles the visual transition.
              let slideAnim = CABasicAnimation(keyPath: "position.y")
              slideAnim.fromValue = newCellSlideOffset as NSNumber
              slideAnim.toValue = 0.0 as NSNumber
              slideAnim.isAdditive = true
              slideAnim.duration = animDuration
              slideAnim.timingFunction = animTiming
              slideAnim.isRemovedOnCompletion = true
              info.cell.layer.add(slideAnim, forKey: "insertSlideUp")
              dbgNewSlide += 1
            }
          }
        }

      default:
        break
      }

      updateDebugStats(
        shifted: dbgShifted, newSlide: dbgNewSlide,
        maxDelta: dbgMaxDelta, scrollDelta: dbgScrollDelta)
    }

    // Safety net: ensure the send overlay starts even if the attempt
    // inside finalize failed (e.g. cell wasn't laid out yet).
    maybeStartPendingSendTransition()
  }

  /// Keep the inline agent-turn bubble's per-row UI state in sync with the live row set:
  /// drop expand/runtime state for rows no longer present, and stamp a stream-start
  /// instant for each row that just began streaming so its "Working · M:SS" clock counts
  /// up from a fixed instant instead of resetting on every re-render. Mirrors
  /// VibeAgentConversationViewController's trackStreamStarts/expandedProgressMessageIds
  /// pruning pattern, keyed the same way (row.messageId ?? row.key, matching
  /// VibeAgentKitMap.chatMessage(from:)'s `id`).
  private func pruneAgentTurnState(for currentRows: [ChatListRow]) {
    let liveIds = Set(currentRows.map { $0.messageId ?? $0.key })
    let liveKeys = Set(currentRows.map(\.key))
    agentTurnHeightCache = agentTurnHeightCache.filter { liveKeys.contains($0.key) }
    messageHeightCache = messageHeightCache.filter { liveKeys.contains($0.key) }
    agentTurnExpandedStepIdsByRow = agentTurnExpandedStepIdsByRow.filter { liveIds.contains($0.key) }
    agentTurnProgressExpandedRowIds = agentTurnProgressExpandedRowIds.filter { liveIds.contains($0) }
    agentTurnRuntimeExpandedRowIds = agentTurnRuntimeExpandedRowIds.filter { liveIds.contains($0) }
    tallBubbleExpandedRowIds = tallBubbleExpandedRowIds.filter { liveIds.contains($0) }
    let streamingIds = Set(currentRows.filter { $0.isStreamingText }.map { $0.messageId ?? $0.key })
    for id in streamingIds where agentTurnStreamStartByRow[id] == nil {
      agentTurnStreamStartByRow[id] = Date()
    }
    agentTurnStreamStartByRow = agentTurnStreamStartByRow.filter { streamingIds.contains($0.key) }
  }

  /// Current expand/streaming state for one row's inline agent-turn bubble, read from the
  /// Stage-2 dictionaries above. Used both for measurement (`measureMessageBubbleLayout`)
  /// and for the cell's live `configure(row:...)` call so the two never disagree.
  private func agentTurnBubbleState(for row: ChatListRow) -> AgentTurnBubbleState {
    let id = row.messageId ?? row.key
    return AgentTurnBubbleState(
      isProgressExpanded: agentTurnProgressExpandedRowIds.contains(id),
      isRuntimeExpanded: agentTurnRuntimeExpandedRowIds.contains(id),
      expandedStepIds: agentTurnExpandedStepIdsByRow[id] ?? [],
      streamingStartDate: agentTurnStreamStartByRow[id],
      tallExpanded: tallBubbleExpandedRowIds.contains(id)
    )
  }

  func setEngineSurfaceId(_ value: String) {
    let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if engineSurfaceId == next { return }
    if !engineSurfaceId.isEmpty {
      let surfaceId = engineSurfaceId
      chatListEngineBindingQueue.async {
        _ = ChatEngine.shared.unbindSurface(["surfaceId": surfaceId])
      }
    }
    engineSurfaceId = next
    updateChatEngineBinding()
  }

  func setEngineChatId(_ value: String) {
    let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if engineChatId == next { return }
    engineChatId = next
    // Heal a full-page agent view that was hosted BEFORE this chat bound: it would have
    // been created with a nil chatId (its ask/plan handler then DROPs on the chatId guard,
    // leaving the bubble surface to cover). Now that the chatId is known, wire it so the
    // agent view owns its own asks (and plan re-runs route through its send path) again.
    if !next.isEmpty, let agentVC = presentedBridgeAgentVC,
      (agentVC.agentBridgeChatId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      agentVC.agentBridgeChatId = next
      NSLog("[ChatListView][ask] HEAL — wired full-page agent view chatId=%@", next)
    }
    nativeEngineRowsById.removeAll()
    nativeEngineOrder.removeAll()
    nativeDeletedMessageIds.removeAll()
    lastReadReceiptSentMessageId = nil
    // NOTE: bridge-agent fresh-surface tracking (bridgeFreshHiddenIdsByChat /
    // bridgeFreshOwnSentIdsByChat) is intentionally NOT cleared here — it's keyed by
    // chatId in a process-lifetime static store precisely so that switching away from
    // this DM and back (or a fresh ChatListView instance reopening it) does not re-hide
    // an already-engaged thread. It's naturally isolated per chatId, so rebinding to a
    // DIFFERENT chat can't leak into it either. Re-evaluate whether the in-place agent
    // view belongs to this DM.
    reportedBridgeCommandIds.removeAll()
    bridgeLoadedSessionId = nil
    activeBridgeSessionId = nil
    bridgeAgentManuallyShown = false
    agentTurnExpandedStepIdsByRow.removeAll()
    agentTurnProgressExpandedRowIds.removeAll()
    agentTurnRuntimeExpandedRowIds.removeAll()
    agentTurnStreamStartByRow.removeAll()
    scheduleBridgeAgentPresenceRefresh()
    updateChatEngineBinding()
    updateChatEngineChannelBinding()
    if statusAuthorityEnabled {
      refreshVisibleStatuses(reason: "chatId")
      hydrateRowsFromNativeHistoryIfReady(trigger: "chatId")
    }
  }

  func setEngineMyUserId(_ value: String) {
    let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if engineMyUserId == next { return }
    engineMyUserId = next
  }

  func setEnginePeerUserId(_ value: String) {
    let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if enginePeerUserId == next { return }
    enginePeerUserId = next
    didAutoPresentAgentView = false
    didPrefetchBridgeHistory = false
    // The peer id may arrive after the input bar is built; re-assert the agent
    // control so a Claude/Codex DM surfaces the repo picker (not a plain input).
    inputBar?.setAgentControlMode(agentChatMode || currentBridgeProvider != nil)
    updateAgentBridgeControlTitle()
    updateChatEngineBinding()
    if statusAuthorityEnabled {
      refreshVisibleStatuses(reason: "peerUserId")
    }
    presentPreferredAgentViewIfNeeded()
    prefetchBridgeHistoryIfNeeded()
  }

  func setEnginePeerAgentId(_ value: String) {
    let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if enginePeerAgentId == next { return }
    enginePeerAgentId = next
    updateChatEngineBinding()
  }

  func setEventInboxModeEnabled(_ enabled: Bool) {
    if eventInboxModeEnabled == enabled { return }
    eventInboxModeEnabled = enabled
    // Re-run the row pipeline so notifications are filtered (or restored) and the
    // host banner is refreshed for the new mode.
    setRows(sourceRowsPayload)
  }

  /// One-line preview for the Inbox banner: drops a leading markdown heading
  /// marker and collapses whitespace so the banner shows the latest event text.
  func eventInboxPreviewText(for row: ChatListRow) -> String {
    let raw = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine = raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? raw
    var line = firstLine.trimmingCharacters(in: .whitespaces)
    while line.hasPrefix("#") { line.removeFirst() }
    return line.trimmingCharacters(in: .whitespaces)
  }

  func setEngineChannelBindingEnabled(_ enabled: Bool) {
    if engineChannelBindingEnabled == enabled { return }
    engineChannelBindingEnabled = enabled
    updateChatEngineChannelBinding(forceDetach: !enabled)
  }

  func setEnginePeerDisplayName(_ value: String) {
    let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if enginePeerDisplayName == next { return }
    enginePeerDisplayName = next
  }

  func setStatusAuthorityEnabled(_ enabled: Bool) {
    if statusAuthorityEnabled == enabled { return }
    statusAuthorityEnabled = enabled
    if enabled {
      hydrateRowsFromNativeHistoryIfReady(trigger: "statusAuthorityEnabled")
    } else {
      refreshVisibleStatuses(reason: "statusAuthorityDisabled")
    }
  }

  func beginMessageSelection(messageId: String) {
    let resolvedMessageId = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolvedMessageId.isEmpty else { return }
    let wasActive = selectionMode
    let inserted = selectedMessageIds.insert(resolvedMessageId).inserted
    selectionMode = true
    guard !wasActive || inserted else { return }
    refreshMessageSelectionLayout()
    emitMessageSelectionChanged()
  }

  func toggleMessageSelection(row: ChatListRow) {
    guard let messageId = row.messageId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !messageId.isEmpty
    else { return }
    if selectedMessageIds.contains(messageId) {
      selectedMessageIds.remove(messageId)
    } else {
      selectedMessageIds.insert(messageId)
    }
    selectionMode = !selectedMessageIds.isEmpty
    refreshMessageSelectionLayout()
    emitMessageSelectionChanged()
  }

  private func pruneMessageSelection(for parsedRows: [ChatListRow]) {
    guard selectionMode || !selectedMessageIds.isEmpty else { return }
    let validIds = Set(
      parsedRows.compactMap {
        $0.messageId?.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
    )
    let before = selectedMessageIds
    selectedMessageIds = Set(selectedMessageIds.filter { validIds.contains($0) })
    let wasActive = selectionMode
    selectionMode = !selectedMessageIds.isEmpty
    if before != selectedMessageIds || wasActive != selectionMode {
      emitMessageSelectionChanged()
    }
  }

  private func refreshMessageSelectionLayout() {
    collectionView.collectionViewLayout.invalidateLayout()
    UIView.performWithoutAnimation {
      collectionView.reloadData()
      collectionView.layoutIfNeeded()
    }
  }

  private func emitMessageSelectionChanged() {
    inputBar?.setSelectionMode(selectionMode, animated: true)
    onNativeEvent([
      "type": "messageSelectionChanged",
      "active": selectionMode,
      "selectedCount": selectedMessageIds.count,
      "selectedMessageIds": Array(selectedMessageIds),
    ])
  }

  func clearMessageSelection() {
    selectedMessageIds.removeAll()
    selectionMode = false
    refreshMessageSelectionLayout()
    emitMessageSelectionChanged()
  }

  func setAppearance(_ rawAppearance: [String: Any]) {
    lastRawAppearance = rawAppearance
    Self.cacheNativeThemeSeed(from: rawAppearance)
    let next = ChatListAppearance.from(raw: rawAppearance)
    let visualChanged = appearance.visualKey != next.visualKey
    let hasPendingOrActiveSendTransition =
      pendingSendTransition != nil || activeSendTransition != nil
    if visualChanged && hasPendingOrActiveSendTransition {
      queuedAppearanceAfterSendTransition = next
      return
    }
    queuedAppearanceAfterSendTransition = nil
    applyResolvedAppearance(next)
  }

  func resolvedAppearance() -> ChatListAppearance {
    appearance
  }

  private func reapplyNativeThemeForCurrentInterfaceStyle() {
    var rawAppearance: [String: Any]
    if let lastRawAppearance,
      lastRawAppearance["nativeThemeId"] != nil
    {
      rawAppearance = lastRawAppearance
    } else if let cachedRawAppearance = Self.bootstrapCachedRawAppearance() {
      rawAppearance = cachedRawAppearance
    } else {
      return
    }

    rawAppearance["nativeThemeIsDark"] = traitCollection.userInterfaceStyle == .dark
    setAppearance(rawAppearance)
  }

  private func applyResolvedAppearance(_ next: ChatListAppearance) {
    let visualChanged = appearance.visualKey != next.visualKey
    appearance = next
    inputBar?.applyAppearance(next)
    if visualChanged {
      applyWallpaperAppearance()
      refreshWallpaperSnapshotIfNeeded(force: true)
      applyScrollToneTheme()
      updateScrollToneOverlay(offsetY: collectionView.contentOffset.y)
      applyActivityOverlayTheme()
      collectionView.reloadData()
    }
  }

  private func flushQueuedAppearanceAfterTransitionIfNeeded() {
    guard activeSendTransition == nil, pendingSendTransition == nil,
      let queued = queuedAppearanceAfterSendTransition
    else {
      return
    }
    queuedAppearanceAfterSendTransition = nil
    applyResolvedAppearance(queued)
  }

  private static func cacheNativeThemeSeed(from rawAppearance: [String: Any]) {
    guard let themeIdRaw = rawAppearance["nativeThemeId"] else { return }
    let themeId: String
    if let value = themeIdRaw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      themeId = trimmed
    } else {
      return
    }

    let isDark: Bool = {
      if let value = rawAppearance["nativeThemeIsDark"] as? Bool { return value }
      if let value = rawAppearance["nativeThemeIsDark"] as? NSNumber { return value.boolValue }
      if let value = rawAppearance["nativeThemeIsDark"] as? String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["1", "true", "yes"].contains(normalized)
      }
      return true
    }()

    let defaults = UserDefaults.standard
    defaults.set(themeId, forKey: cachedThemeIdDefaultsKey)
    defaults.set(isDark, forKey: cachedThemeIsDarkDefaultsKey)
  }

  private static func bootstrapCachedRawAppearance() -> [String: Any]? {
    let defaults = UserDefaults.standard
    guard let themeId = defaults.string(forKey: cachedThemeIdDefaultsKey), !themeId.isEmpty else {
      return nil
    }
    let isDark = defaults.bool(forKey: cachedThemeIsDarkDefaultsKey)
    return [
      "backgroundMode": "gradient",
      "nativeThemeId": themeId,
      "nativeThemeIsDark": isDark,
    ]
  }

  func setContentPaddingBottom(_ value: Double) {
    let next = max(sectionBottomInset, CGFloat(value))
    requestedContentPaddingBottom = next

    // Native input mode owns bottom inset (bar height + keyboard height).
    // Ignore external padding updates while still remembering the requested
    // value so it can be restored if native input mode is disabled.
    guard !inputBarEnabled else {
      return
    }
    if abs(next - contentPaddingBottom) <= 0.5 {
      return
    }
    contentPaddingBottom = next
    updateBottomAnchorInset()
    emitViewport(force: true)
  }

  func setContentPaddingTop(_ value: Double) {
    let next = max(sectionTopInset, CGFloat(value))
    if abs(next - contentPaddingTop) <= 0.5 {
      return
    }
    contentPaddingTop = next
    setNeedsLayout()
    updateBottomAnchorInset()
    emitViewport(force: true)
  }

  func setVoicePlayback(_ payload: [String: Any]) {
    let nextMessageId = payload["messageId"] as? String
    let nextIsPlaying = (payload["isPlaying"] as? Bool) ?? false
    let nextProgressRaw = payload["progress"] as? Double ?? 0.0
    let nextProgress = max(0.0, min(1.0, CGFloat(nextProgressRaw)))

    if activeVoicePlaybackMessageId == nextMessageId
      && activeVoicePlaybackIsPlaying == nextIsPlaying
      && abs(activeVoicePlaybackProgress - nextProgress) <= 0.001
    {
      return
    }

    activeVoicePlaybackMessageId = nextMessageId
    activeVoicePlaybackIsPlaying = nextIsPlaying
    activeVoicePlaybackProgress = nextProgress
    applyVoicePlaybackToVisibleCells()
  }

  private func applyVoicePlaybackToVisibleCells() {
    for case let cell as ChatListCell in collectionView.visibleCells {
      cell.setExternalVoicePlayback(
        messageId: activeVoicePlaybackMessageId,
        isPlaying: activeVoicePlaybackIsPlaying,
        progress: activeVoicePlaybackProgress
      )
    }
  }

  @objc private func handleVoiceBubblePlaybackChanged(_ notification: Notification) {
    let snapshot = VoiceBubblePlaybackCoordinator.shared.currentSnapshot
    let nextMessageId = snapshot.messageId
    let nextIsPlaying = snapshot.isPlaying
    let nextProgress = max(0.0, min(1.0, snapshot.progress))

    if activeVoicePlaybackMessageId == nextMessageId
      && activeVoicePlaybackIsPlaying == nextIsPlaying
      && abs(activeVoicePlaybackProgress - nextProgress) <= 0.001
    {
      return
    }

    activeVoicePlaybackMessageId = nextMessageId
    activeVoicePlaybackIsPlaying = nextIsPlaying
    activeVoicePlaybackProgress = nextProgress
    applyVoicePlaybackToVisibleCells()
  }

  func applyTransactions(_ transactions: [[String: Any]]) {
    onNativeEvent(["type": "transactionsApplied", "count": transactions.count])
  }

  func scrollToBottom(animated: Bool, force: Bool = false) {
    // On the agent surface the scroll offset is owned by exactly two things: the
    // deliberate send pin (performAgentPushToTop) and the user's finger. Every
    // other "stick to bottom" caller — setRows finalize, streaming-text layout
    // invalidation, resize/keyboard — must NOT run here, or it fights the user and
    // makes the list impossible to scroll (this kept snapping the offset back to the
    // bottom on every link-preview / markdown relayout once a turn had ended). The
    // only exception is `force` (first open of the chat), where we genuinely want to
    // land at the latest message.
    if agentChatMode, !force {
      return
    }
    let maxOffsetY = pixelAlignedValue(
      max(0.0, collectionView.contentSize.height - collectionView.bounds.height))
    if animated {
      // For animated scroll, use UIView spring animation to match the insertion feel.
      shouldAutoScroll = true
      isInternalScrollAdjustment = true
      UIView.animate(
        withDuration: 0.4,
        delay: 0.0,
        usingSpringWithDamping: 0.88,
        initialSpringVelocity: 0.0,
        options: [.curveEaseOut, .allowUserInteraction]
      ) { [weak self] in
        self?.collectionView.contentOffset = CGPoint(x: 0.0, y: maxOffsetY)
      } completion: { [weak self] _ in
        guard let self else { return }
        self.isInternalScrollAdjustment = false
        self.previousOffsetY = self.collectionView.contentOffset.y
        self.emitViewport(force: true)
      }
    } else {
      performInternalScrollAdjustment {
        collectionView.setContentOffset(CGPoint(x: 0.0, y: maxOffsetY), animated: false)
      }
      previousOffsetY = collectionView.contentOffset.y
      shouldAutoScroll = true
      emitViewport(force: true)
    }
  }

  private func updateJumpToBottomButtonVisibility() {
    let dist = currentDistanceFromBottom()
    let isFar = dist > listBottomThreshold
    setJumpButtonVisible(isFar)
  }

  private func setJumpButtonVisible(_ visible: Bool) {
    let shouldShow = visible && !rows.isEmpty
    guard shouldShow != (jumpToBottomButton.alpha > 0.0) else { return }

    if jumpToBottomButton.superview == nil {
      addSubview(jumpToBottomButton)
      setNeedsLayout()
      layoutIfNeeded()
    }

    if shouldShow {
      jumpToBottomButton.isHidden = false
      UIView.animate(withDuration: 0.22, delay: 0.0, options: [.beginFromCurrentState]) {
        self.jumpToBottomButton.alpha = 1.0
        self.jumpToBottomButton.transform = .identity
      }
    } else {
      UIView.animate(withDuration: 0.22, delay: 0.0, options: [.beginFromCurrentState]) {
        self.jumpToBottomButton.alpha = 0.0
        self.jumpToBottomButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
      } completion: { finished in
        if finished && self.jumpToBottomButton.alpha == 0.0 {
          self.jumpToBottomButton.isHidden = true
        }
      }
    }
  }

  @objc private func jumpToBottomTapped() {
    scrollToBottom(animated: true, force: true)
  }

  func scrollToMessage(messageId: String, animated: Bool, viewPosition: Double) {
    guard let rowIndex = indexForMessage(messageId) else {
      return
    }
    let indexPath = IndexPath(item: rowIndex, section: 0)
    collectionView.layoutIfNeeded()
    guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else {
      return
    }
    let clamped = max(0.0, min(1.0, viewPosition))
    let targetY =
      attrs.frame.minY - ((collectionView.bounds.height - attrs.frame.height) * CGFloat(clamped))
    let maxOffset = max(0.0, collectionView.contentSize.height - collectionView.bounds.height)
    let clampedOffset = pixelAlignedValue(max(0.0, min(maxOffset, targetY)))
    collectionView.setContentOffset(CGPoint(x: 0.0, y: clampedOffset), animated: animated)
    previousOffsetY = clampedOffset
    shouldAutoScroll = false
    emitViewport(force: true)
  }

  func openPinnedDocument(urlString: String) {
    openDocumentInApp(urlString: urlString)
  }

  func startSendTransition(_ payload: [String: Any]) {
    guard let parsed = SendTransitionPayload(payload: payload, hostView: self) else {
      NSLog("[ChatListView] startSendTransition — failed to parse payload")
      return
    }
    let typeHint =
      ((payload["type"] as? String) ?? (payload["messageType"] as? String))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let hasMediaHint =
      payload["mediaUrl"] != nil
      || payload["media_url"] != nil
      || payload["uri"] != nil
      || payload["fileName"] != nil
      || payload["file_name"] != nil
    let trimmedText = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if typeHint != nil && typeHint != "text" || hasMediaHint || trimmedText.isEmpty {
      NSLog(
        "[ChatListView] startSendTransition — ignored non-text payload (messageId=%@, type=%@, hasMedia=%@, textLen=%lu)",
        parsed.messageId,
        typeHint ?? "nil",
        hasMediaHint ? "true" : "false",
        trimmedText.count
      )
      return
    }
    NSLog(
      "[ChatListView] startSendTransition — messageId: %@, hiding cell immediately",
      parsed.messageId)
    // Hide the message immediately so it never renders visibly before the
    // transition overlay starts. cellForItemAt checks hiddenMessageId.
    hiddenMessageId = parsed.messageId
    pendingSendTransition = parsed
    maybeStartPendingSendTransition()
  }

  func playReactionFx(_ payload: [String: Any]) {
    guard let emojiRaw = payload["emoji"] as? String else { return }
    let emoji = emojiRaw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !emoji.isEmpty else { return }
    guard
      let pointX = payloadCGFloat(payload["x"] ?? payload["sourceX"]),
      let pointY = payloadCGFloat(payload["y"] ?? payload["sourceY"])
    else {
      return
    }

    var localPoint = CGPoint(x: pointX, y: pointY)
    if let window {
      localPoint = convert(localPoint, from: window)
    }
    localPoint.x = min(max(localPoint.x, -32.0), bounds.width + 32.0)
    localPoint.y = min(max(localPoint.y, -32.0), bounds.height + 32.0)

    let color = resolvedReactionFxColor(payload["color"])
    renderNativeReactionFxBurst(emoji: emoji, at: localPoint, tintColor: color)
  }

  public func collectionView(
    _ collectionView: UICollectionView, numberOfItemsInSection section: Int
  ) -> Int {
    rows.count
  }

  public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
    -> UICollectionViewCell
  {
    guard indexPath.item < rows.count else {
      // Reconfigure paths may request an index that has just shifted during a
      // batched delete+reload. Return the existing cell when present to avoid
      // UIKit's "different cell during reconfigure" assertion.
      if let existingCell = collectionView.cellForItem(at: indexPath) {
        return existingCell
      }
      return UICollectionViewCell()
    }
    guard
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: ChatListCell.reuseIdentifier, for: indexPath) as? ChatListCell
    else {
      return UICollectionViewCell()
    }
    let row = rows[indexPath.item]
    let preferredMediaURL = resolvedPreferredMediaURL(for: row)
    let preferredLocalMediaURLOverride: String? = {
      guard let preferredMediaURL else { return nil }
      if let parsed = URL(string: preferredMediaURL), parsed.isFileURL {
        return preferredMediaURL
      }
      if preferredMediaURL.hasPrefix("/") {
        return preferredMediaURL
      }
      return nil
    }()
    cell.applyAppearance(appearance)
    cell.resolveDisplayStatus = { [weak self] row in
      self?.resolvedDisplayStatus(for: row)
    }
    let mediaDownloadState = remoteMediaDownloadState(for: row)
    if let hid = hiddenMessageId, row.kind == .message, row.messageId == hid {
      NSLog(
        "[FirstMsg] cellForItemAt GHOST configure item=%d msgId=%@ rows=%d pending=%@ active=%@",
        indexPath.item, String(hid.prefix(12)), rows.count,
        pendingSendTransition != nil ? "Y" : "N",
        activeSendTransition != nil ? "Y" : "N")
    }
    let groupContext = groupCellContext(at: indexPath)
    cell.configure(
      row: row,
      hiddenMessageId: hiddenMessageId,
      skipRemoteMediaLoad: mediaDownloadState.needsDownload,
      preferredLocalMediaURLOverride: preferredLocalMediaURLOverride,
      selectionMode: selectionMode,
      selected: row.messageId.map { selectedMessageIds.contains($0) } ?? false,
      agentTurnState: agentTurnBubbleState(for: row),
      groupExtraLeading: groupContext.reservesGutter ? Self.groupIncomingExtraLeading : 0.0,
      groupSenderName: groupContext.senderName,
      groupSenderColor: groupContext.senderColor,
      groupSenderNameHeight: Self.groupSenderNameHeight
    )
    bindWallpaperBackdrop(to: cell)
    cell.applyMediaDownloadState(
      needsDownload: mediaDownloadState.needsDownload,
      isDownloading: mediaDownloadState.isDownloading,
      progress: mediaDownloadState.progress
    )
    let currentlyVisible = collectionView.indexPathsForVisibleItems.contains(indexPath)
    if rowRepresentsVideoMedia(row) {
      chatListDebugLog(
        chatListInlineVideoVerboseDebugLogs,
        "[ChatInlineVideoList] configure msgId=%@ visibleNow=%@ needsDownload=%@ downloading=%@ preferredLocal=%@ remote=%@",
        row.messageId ?? "-",
        currentlyVisible ? "Y" : "N",
        mediaDownloadState.needsDownload ? "Y" : "N",
        mediaDownloadState.isDownloading ? "Y" : "N",
        preferredLocalMediaURLOverride ?? "nil",
        row.mediaUrl ?? "nil"
      )
    }
    cell.setInlineVideoPlaybackActive(currentlyVisible)
    cell.onInlineAttachmentTap = { [weak self] row in
      guard let self else { return }
      if !row.relatedMessageIds.isEmpty {
        self.onNativeEvent([
          "type": "relatedMessagesPressed",
          "messageId": row.messageId ?? "",
          "relatedMessageIds": row.relatedMessageIds,
          "title": row.relatedMessagesTitle ?? "",
          "subtitle": row.relatedMessagesSubtitle ?? "",
        ])
      } else {
        self.openDocumentInApp(row: row)
      }
    }
    cell.onMediaNaturalSizeResolved = { [weak self] messageId, mediaURL, size in
      self?.handleResolvedMediaSize(messageId: messageId, mediaURL: mediaURL, size: size)
    }
    cell.onRetryMessageTap = { [weak self] row in
      self?.retryOutgoingMessage(row: row, source: "inline_retry")
    }
    cell.onNotSentTap = { [weak self] row in
      self?.handleNotSentTap(row: row)
    }
    cell.onAgentAction = { [weak self] payload in
      guard let self else { return }
      let actionType = payload["type"] as? String
      // "view agent" opens the native full-page agent surface (ported VibeAgentKit
      // renderer) for that single task — it does NOT go through the JS bridge.
      if actionType == "viewAgent" {
        let messageId = (payload["messageId"] as? String) ?? ""
        self.presentAgentConversation(forMessageId: messageId)
        return
      }
      // Inline agent-turn bubble interactions (step expand, subagent drill-down, diff
      // review, "Worked · N steps" collapse) — all purely local UI state or an existing
      // presentation entry point, none go through the JS bridge either.
      if let messageId = payload["messageId"] as? String, !messageId.isEmpty,
        let row = self.rows.first(where: { ($0.messageId ?? $0.key) == messageId })
      {
        switch actionType {
        case "toggleAgentStep":
          guard let nodeId = payload["nodeId"] as? String else { return }
          let message = VibeAgentKitMap.chatMessage(from: row)
          var foundItem: VibeAgentKitProgressItem? = nil
          if let item = message.progressItems.first(where: { ($0.nodeId ?? $0.label) == nodeId }) {
            foundItem = item
          } else {
            for (_, children) in message.subagentChildren {
              if let item = children.first(where: { ($0.nodeId ?? $0.label) == nodeId }) {
                foundItem = item
                break
              }
            }
          }

          if let item = foundItem {
            let kind = (item.itemType ?? item.tool ?? "").lowercased()
            if kind == "bash" || kind == "edit" || kind == "write" || kind == "read" || kind == "todo" || kind == "planning" {
              guard let presenter = self.topPresentingViewController() else { return }
              let detail = VibeAgentKitStepDetailViewController(
                item: item,
                appearance: VibeAgentKitMap.appearance(for: self.traitCollection)
              )
              let nav = UINavigationController(rootViewController: detail)
              nav.modalPresentationStyle = .pageSheet
              let vibeAppearance = VibeAgentKitMap.appearance(for: self.traitCollection)
              nav.view.backgroundColor = vibeAppearance.isDark
                ? UIColor.black.withAlphaComponent(0.3)
                : .clear
              if let sheet = nav.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
              }
              presenter.present(nav, animated: true)
              return
            }
          }
          return
        case "toggleAgentProgress":
          if self.agentTurnProgressExpandedRowIds.contains(messageId) {
            self.agentTurnProgressExpandedRowIds.remove(messageId)
          } else {
            self.agentTurnProgressExpandedRowIds.insert(messageId)
          }
          self.reloadAgentTurnStateRow(messageId: messageId, reason: "toggleAgentProgress")
          return
        case "toggleAgentRuntime":
          if self.agentTurnRuntimeExpandedRowIds.contains(messageId) {
            self.agentTurnRuntimeExpandedRowIds.remove(messageId)
          } else {
            self.agentTurnRuntimeExpandedRowIds.insert(messageId)
          }
          self.reloadAgentTurnStateRow(messageId: messageId, reason: "toggleAgentRuntime")
          return
        case "toggleTallBubble":
          // Shared tall-content collapse (user text, agent text, settled agent turns):
          // flip this row's expand state and reload just that row (a full setRows pass
          // diffs row CONTENT, which is unchanged here, and would no-op).
          if self.tallBubbleExpandedRowIds.contains(messageId) {
            self.tallBubbleExpandedRowIds.remove(messageId)
          } else {
            self.tallBubbleExpandedRowIds.insert(messageId)
          }
          self.reloadAgentTurnStateRow(messageId: messageId, reason: "toggleTallBubble")
          return
        case "openAgentSubagent":
          guard let nodeId = payload["nodeId"] as? String else { return }
          self.presentAgentTurnSubagentView(row: row, parentNodeId: nodeId)
          return
        case "openAgentTurnDetail":
          self.presentAgentTurnDetailView(row: row)
          return
        case "agentReviewTapped":
          guard let runtime = row.agentRuntime else { return }
          self.presentAgentRuntimeTask(row: row, runtime: runtime)
          return
        default:
          break
        }
      } else if let actionType, actionType.hasPrefix("toggle") {
        // A toggle that can't find its row is a silent dead tap — make it visible.
        NSLog(
          "[TallToggle] %@ DROPPED — row lookup failed id=%@ rows=%d",
          actionType, ((payload["messageId"] as? String) ?? "<nil>"), self.rows.count)
      }
      self.onNativeEvent(payload)
    }
    cell.onSelectionToggle = { [weak self] row in
      self?.toggleMessageSelection(row: row)
    }
    cell.onVoiceUploadCancelTap = { [weak self] row in
      guard let self, let messageId = row.messageId, !messageId.isEmpty else { return }
      let downloadState = self.remoteMediaDownloadState(for: row)
      if downloadState.isDownloading {
        if let remoteURL = URL(string: row.mediaUrl ?? "") {
          let remoteKey = self.remoteMediaCacheKey(
            remoteURL: remoteURL,
            mediaKey: self.resolvedMediaKey(for: row)
          )
          self.mediaDownloadTasks[remoteKey]?.cancel()
        }
        return
      }
      self.cancelOutgoingMessage(row: row, source: "voice_upload_cancel")
    }
    // Removed onVoiceBubbleTap so iOS uses Native Audio playback for Voice bubbles (like Android)
    cell.setExternalVoicePlayback(
      messageId: activeVoicePlaybackMessageId,
      isPlaying: activeVoicePlaybackIsPlaying,
      progress: activeVoicePlaybackProgress
    )
    // Telegram rule: cells are NEVER transparent. Force full opacity
    // and strip any UIKit-implicit opacity animation.
    cell.alpha = 1.0
    cell.contentView.alpha = 1.0
    cell.layer.opacity = 1.0
    cell.contentView.layer.opacity = 1.0
    cell.layer.removeAnimation(forKey: "opacity")
    cell.contentView.layer.removeAnimation(forKey: "opacity")
    return cell
  }

  public func collectionView(
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    guard indexPath.item < rows.count else { return }
    let row = rows[indexPath.item]
    if rowRepresentsVideoMedia(row) {
      chatListDebugLog(
        chatListInlineVideoVerboseDebugLogs,
        "[ChatInlineVideoList] willDisplay msgId=%@ needsDownload=%@ remote=%@",
        row.messageId ?? "-",
        remoteMediaDownloadState(for: row).needsDownload ? "Y" : "N",
        row.mediaUrl ?? "nil"
      )
    }
    (cell as? ChatListCell)?.setInlineVideoPlaybackActive(true)
    scheduleAutoRemoteMediaDownloadIfNeeded(for: row)
  }

  public func collectionView(
    _ collectionView: UICollectionView,
    didEndDisplaying cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    if indexPath.item < rows.count {
      let row = rows[indexPath.item]
      if rowRepresentsVideoMedia(row) {
        chatListDebugLog(
          chatListInlineVideoVerboseDebugLogs,
          "[ChatInlineVideoList] didEndDisplaying msgId=%@",
          row.messageId ?? "-"
        )
      }
    }
    (cell as? ChatListCell)?.setInlineVideoPlaybackActive(false)
  }

  public func collectionView(
    _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
  ) {
    guard indexPath.item < rows.count else { return }
    let row = rows[indexPath.item]
    if selectionMode {
      toggleMessageSelection(row: row)
      return
    }

    if row.isAgentMessage,
      row.visualKind == .text,
      let agentUserId = row.agentUserId,
      !agentUserId.isEmpty
    {
      var payload: [String: Any] = [
        "type": "agentChatPressed",
        "agentUserId": agentUserId,
        "agentName": row.agentName ?? "Agent",
      ]
      if let agentId = row.agentId, !agentId.isEmpty {
        payload["agentId"] = agentId
      }
      if let username = row.agentUsername, !username.isEmpty {
        payload["agentUsername"] = username
        payload["agentHandle"] = "@\(username)"
      }
      onNativeEvent(payload)
      return
    }
    guard let mediaURLRaw = row.mediaUrl else { return }
    let mediaURL = mediaURLRaw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !mediaURL.isEmpty else { return }
    let hasFileNameHint =
      !(row.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    let isFileLikeType = row.messageType == "file"
    let isVoiceVisual = row.visualKind == .voice
    let isUploadCancelableVisual =
      row.visualKind == .voice
      || row.visualKind == .media
      || row.visualKind == .video
      || row.visualKind == .videoNote
      || row.visualKind == .sticker
    let lowerMediaURL = mediaURL.lowercased()
    let isAgentDocURL =
      lowerMediaURL.contains("/uploads/agent-docs/")
      || lowerMediaURL.contains("/api/agent/document/")
    if isUploadCancelableVisual, row.shouldShowUploadOverlay {
      if let messageId = row.messageId, !messageId.isEmpty {
        cancelOutgoingMessage(row: row, source: "media_upload_cancel")
      }
      return
    }
    if isVoiceVisual {
      if let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell {
        VoiceBubblePlaybackCoordinator.shared.toggle(
          cell: cell,
          messageId: row.messageId,
          mediaURL: mediaURL,
          mediaKey: resolvedMediaKey(for: row),
          fileName: row.fileName
        )
      }
      return
    }
    let isImageVisual = row.visualKind == .media && row.messageType != "file"
    if isImageVisual {
      let mediaDownloadState = remoteMediaDownloadState(for: row)
      if mediaDownloadState.needsDownload {
        startRemoteMediaDownload(for: row, presentOnComplete: true)
        return
      }
      let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
      let seedImage = cell?.currentMediaImage()
      let sourceView = cell?.currentMediaImageView()
      presentImageEditView(
        for: row,
        mediaURL: resolvedPreferredMediaURL(for: row) ?? mediaURL,
        seedImage: seedImage,
        sourceView: sourceView)
      return
    }
    let isMediaOrVideo =
      row.visualKind == .media || row.visualKind == .video || row.visualKind == .videoNote
    if isMediaOrVideo {
      let mediaDownloadState = remoteMediaDownloadState(for: row)
      if mediaDownloadState.needsDownload {
        // Skip the full-file download for unencrypted remote audio — openDocumentInApp will stream it.
        let isStreamableAudio: Bool = {
          let key = resolvedMediaKey(for: row)
          let noKey = key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
          guard noKey, let rawURL = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
          return isAudioAttachmentURI(rawURL, fileNameHint: row.fileName)
            && (URL(string: rawURL)?.scheme.map { ["http","https"].contains($0.lowercased()) } ?? false)
        }()
        if !isStreamableAudio {
          startRemoteMediaDownload(for: row, presentOnComplete: true)
          return
        }
      }
    }
    guard isFileLikeType || hasFileNameHint || isAgentDocURL || isMediaOrVideo else { return }
    openDocumentInApp(row: row)
  }

  private func presentAgentRuntimeTask(row: ChatListRow, runtime: ChatListRow.AgentRuntimeSummary) {
    guard let presenter = topPresentingViewController() else { return }
    let rowChatId = row.chatId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resolvedChatId =
      rowChatId.isEmpty ? engineChatId.trimmingCharacters(in: .whitespacesAndNewlines) : rowChatId
    let controller = AgentRuntimeTaskViewController(
      row: row,
      runtime: runtime,
      appearance: appearance,
      chatId: resolvedChatId,
      fallbackProvider: currentBridgeProvider
    )
    let nav = UINavigationController(rootViewController: controller)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.large()]
      sheet.prefersGrabberVisible = true
    }
    presenter.present(nav, animated: true)
  }

  /// Open the read-only subagent view (no composer) for a Task node inside an inline
  /// agent-turn bubble — mirrors VibeAgentConversationViewController.presentSubagentView
  /// exactly (same detail VC, same sheet config), just reached from the bubble instead of
  /// the full-page surface.
  private func presentAgentTurnSubagentView(row: ChatListRow, parentNodeId: String) {
    guard let presenter = topPresentingViewController() else { return }
    let message = VibeAgentKitMap.chatMessage(from: row)
    let children = message.subagentChildren[parentNodeId] ?? []
    // Nothing to show for this subagent (yet) — presenting would just be empty glass
    // chrome, the "messy empty sheet" symptom a stale/mid-recovery row could trigger.
    guard !children.isEmpty else { return }
    let type = message.progressItems.first {
      (($0.nodeId ?? $0.label) == parentNodeId) && ($0.subagentType?.isEmpty == false)
    }?.subagentType ?? ""
    let running = children.contains {
      vibeAgentKitRunningStepStatuses.contains(($0.status ?? "").lowercased())
    }
    let detail = VibeAgentSubagentDetailViewController(
      subagentType: type,
      progressItems: children,
      running: running,
      appearance: VibeAgentKitMap.appearance(for: traitCollection)
    )
    let nav = UINavigationController(rootViewController: detail)
    nav.modalPresentationStyle = .pageSheet
    // Clear the nav wrapper's opaque backing so the sheet's own UIGlassEffect refracts the
    // chat behind it (real Liquid Glass) instead of frosting a solid nav background — the
    // ask sheet looks glass precisely because it's presented WITHOUT this opaque layer.
    nav.view.backgroundColor = .clear
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    presenter.present(nav, animated: true)
  }

  /// Open the WHOLE agent turn's progress in the same glass sheet — the "Worked for… /
  /// Working" header tap. Reuses the subagent detail VC (glass + shared renderer) with the
  /// full turn's step feed and answer body, so nothing renders through a second layout path.
  private func presentAgentTurnDetailView(row: ChatListRow) {
    guard let presenter = topPresentingViewController() else { return }
    let message = VibeAgentKitMap.chatMessage(from: row)
    let bodyText = resoloAssistantDisplayText(for: message)
    // A turn with no steps, no answer body, and not actively running has nothing to
    // show — presenting the glass sheet here would just be empty chrome (the "messy
    // blank sheet" symptom a stale/mid-recovery row could trigger). Bail instead.
    guard message.isStreaming || !message.progressItems.isEmpty
      || !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    let toolStepCount = message.progressItems.filter { $0.itemType != "text" }.count
    let title = message.isStreaming
      ? "Working…"
      : VibeAgentKitAssistantMessageBodyView.workedSummary(
        stepCount: toolStepCount, durationMs: message.runtime?.durationMs)
    let detail = VibeAgentSubagentDetailViewController(
      subagentType: "",
      titleOverride: title,
      bodyText: bodyText,
      progressItems: message.progressItems,
      running: message.isStreaming,
      appearance: VibeAgentKitMap.appearance(for: traitCollection)
    )
    let nav = UINavigationController(rootViewController: detail)
    nav.modalPresentationStyle = .pageSheet
    // Clear the nav wrapper's opaque backing so the sheet's own UIGlassEffect refracts the
    // chat behind it (real Liquid Glass) instead of frosting a solid nav background — the
    // ask sheet looks glass precisely because it's presented WITHOUT this opaque layer.
    nav.view.backgroundColor = .clear
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    presenter.present(nav, animated: true)
  }

  /// Re-runs the current row payload through `setRows` so a Stage-2 agent-turn state
  /// change (step expand/collapse, runtime card toggle) is reflected without a full
  /// engine round-trip — the same "re-apply sourceRowsPayload" idiom already used by
  /// `presentBridgeAgentConversation`'s onNewChat handler.
  private func refreshAgentTurnRows() {
    // Bridge-agent DMs render entirely from the native engine overlay — their
    // sourceRowsPayload is often EMPTY, and setRows([]) still merges the overlay
    // (mergedRowsPayload). Bailing on an empty payload made every expand toggle
    // ("Show more", step expand) a silent no-op on those chats.
    guard
      !sourceRowsPayload.isEmpty || !nativeEngineRowsById.isEmpty || !nativeOutgoingRowsById.isEmpty
    else { return }
    setRows(sourceRowsPayload)
  }

  /// Targeted re-render for a purely LOCAL expand/collapse flip (Show more, progress
  /// expand, runtime expand). These flips change NO row content, so routing them through
  /// setRows is a guaranteed no-op: the diff compares row payloads (`chatListRowContentEqual`),
  /// finds zero reloads, and short-circuits before any reconfigure or layout invalidation —
  /// the flipped state is never re-read. Reload the one row directly instead: drop its
  /// cached height (keyed on the expand state), invalidate layout, reconfigure the cell.
  private func reloadAgentTurnStateRow(messageId: String, reason: String) {
    guard let index = rows.firstIndex(where: { ($0.messageId ?? $0.key) == messageId }) else {
      NSLog(
        "[TallToggle] %@ row NOT FOUND id=%@ rows=%d", reason, String(messageId.prefix(24)),
        rows.count)
      return
    }
    let row = rows[index]
    let rowWidth = max(1.0, collectionView.bounds.width - (messageHorizontalInset * 2.0))
    let oldHeight =
      agentTurnHeightCache[row.key]?.height ?? messageHeightCache[row.key]?.height ?? -1.0
    agentTurnHeightCache.removeValue(forKey: row.key)
    messageHeightCache.removeValue(forKey: row.key)
    let indexPath = IndexPath(item: index, section: 0)
    UIView.performWithoutAnimation {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      flowLayout.invalidateLayout()
      collectionView.performBatchUpdates(
        {
          if #available(iOS 15.0, *), rows.count > 1 {
            collectionView.reconfigureItems(at: [indexPath])
          } else {
            collectionView.reloadItems(at: [indexPath])
          }
        },
        completion: nil)
      collectionView.layoutIfNeeded()
      // A collapse near the bottom shrinks content above the viewport floor — clamp the
      // offset back into range so the list doesn't hang past its own end.
      let maxOffset = max(
        0.0, collectionView.contentSize.height - collectionView.bounds.height)
      if collectionView.contentOffset.y > maxOffset {
        performInternalScrollAdjustment {
          collectionView.setContentOffset(CGPoint(x: 0.0, y: maxOffset), animated: false)
        }
      }
      CATransaction.commit()
    }
    let newHeight = estimateMessageHeight(row, rowWidth: rowWidth)
    NSLog(
      "[TallToggle] %@ id=%@ index=%d height %.0f→%.0f expanded=%@",
      reason, String(messageId.prefix(24)), index, oldHeight, newHeight,
      tallBubbleExpandedRowIds.contains(messageId) ? "Y" : "N")
  }

  @objc private func handleChatEngineChanged(_ note: Notification) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleChatEngineChanged(note)
      }
      return
    }
    // Mid-run ask / plan-approval sheets must surface on the bubble (chat) surface too.
    // The full-page agent view also presents these, but it's only mounted when this DM's
    // Default view = Agent; with Default view = Chat nothing else observes the ask, so the
    // run silently blocks for the full ASK timeout. Handle it here (deduped, scoped to this
    // DM + provider). Runs ahead of the statusAuthority gate so a held-back list still prompts.
    if (note.userInfo?["reason"] as? String) == "agentBridgeAsk" {
      presentAgentBridgeAskIfNeeded(note.userInfo ?? [:])
      return
    }
    // The chat channel just (re)joined its topic. For a bridge DM opened mid-run this is
    // the exact gate the current-session request was failing on at cold launch (socket /
    // join not ready) — fire it NOW instead of waiting for the next fallback-poll tick.
    // Runs BEFORE the statusAuthority gate below because bridge DMs keep statusAuthority
    // OFF, so this reason would otherwise never be observed here. Idempotent + throttled.
    if (note.userInfo?["reason"] as? String) == "chatChannelStateChanged",
      currentBridgeProvider != nil
    {
      let changed = (note.userInfo?["chatId"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !chatKey.isEmpty, changed == nil || changed?.isEmpty == true || changed == chatKey {
        requestCurrentBridgeSession(reason: "channelJoined")
        requestBridgeUsageSnapshot(reason: "channelJoined")
      }
    }
    // Usage banner plumbing — also ahead of the statusAuthority gate (bridge DMs keep
    // statusAuthority OFF, so these reasons would never be observed below).
    if currentBridgeProvider != nil {
      let reason = (note.userInfo?["reason"] as? String) ?? ""
      if reason == "agentBridgeUsage" {
        if let requestId = note.userInfo?["requestId"] as? String, !requestId.isEmpty {
          applyBridgeUsageReply(requestId: requestId)
        }
      } else if ["chatMessageChanged", "chatMessageInserted"].contains(reason) {
        let changed = (note.userInfo?["chatId"] as? String)?.trimmingCharacters(
          in: .whitespacesAndNewlines)
        let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chatKey.isEmpty, changed == chatKey {
          // Detect a run finishing (live session registration dropped) → the bridge now
          // has fresh utilization + this run's tokens, the moment the warning matters.
          let liveNow = ChatEngine.shared.liveBridgeSessionId(chatId: chatKey) != nil
          if hadLiveBridgeRun, !liveNow {
            lastBridgeUsageRequestAt = 0
            requestBridgeUsageSnapshot(reason: "runFinished")
          } else {
            // Any DM activity (a result landing, a limit-hit message) refreshes usage;
            // the 30s throttle keeps this quiet during streaming.
            requestBridgeUsageSnapshot(reason: "activity")
          }
          hadLiveBridgeRun = liveNow
        }
      }
    }
    guard statusAuthorityEnabled else { return }
    let changedChatId = (note.userInfo?["chatId"] as? String)?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    if let changedChatId, !changedChatId.isEmpty, changedChatId != engineChatId {
      return
    }
    let reason = (note.userInfo?["reason"] as? String) ?? "engine"
    if ["chatRowsReloaded", "chatMessageInserted", "chatMessageEdited", "chatMessageDeleted",
      "chatMessageChanged", "messageStatusChanged", "presenceChanged", "peerTyping",
      "chatChannelStateChanged"].contains(reason)
    {
      let traceChatIdRaw = changedChatId?.isEmpty == false ? changedChatId! : engineChatId
      let traceChatId = traceChatIdRaw.trimmingCharacters(in: .whitespacesAndNewlines)
      chatListUITrace(
        "ChatListView engineChanged reason=\(reason) chatId=\(traceChatId.isEmpty ? "<empty>" : String(traceChatId.prefix(12))) rows=\(rows.count) sourceRows=\(sourceRowsPayload.count) overlay=\(nativeEngineRowsById.count)"
      )
    }
    if reason == "peerTyping" {
      // Typing indicator is handled in header; do not show list-level typing UI.
      setPeerTyping(false)
      return
    }
    if reason == "chatMessageInserted"
      || reason == "chatMessageEdited"
      || reason == "chatMessageDeleted"
      || reason == "chatMessageChanged"
    {
      let messageId = normalizedMessageId(note.userInfo?["messageId"])
      let action = (note.userInfo?["action"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      syncNativeEngineMessageMutation(reason: reason, messageId: messageId, action: action)
      return
    }
    if reason == "messageStatusChanged" {
      let messageId = normalizedMessageId(note.userInfo?["messageId"])
      if messageId != nil {
        syncNativeEngineMessageMutation(
          reason: "chatMessageChanged",
          messageId: messageId,
          action: "updated"
        )
        return
      }
    }
    if reason == "chatRowsReloaded" {
      hydrateRowsFromNativeHistoryIfReady(trigger: "chatRowsReloaded")
      return
    }
    refreshVisibleStatuses(reason: reason)
  }

  /// Present a mid-run agent ask / plan-approval sheet from the bubble (chat) surface.
  /// The session ids identifying the CONVERSATION this DM page currently shows: the
  /// explicitly-picked History session and/or the session adopted from its visible turns.
  /// Deliberately excludes the engine's chatId-scoped live session — that is always the
  /// asker's own session, so consulting it would neuter ask scoping. Empty ⇒ the page has
  /// no session identity yet (fresh thread pre-first-turn) ⇒ callers fail open.
  func bridgePageSessionIds() -> Set<String> {
    Set(
      [bridgeLoadedSessionId, activeBridgeSessionId].compactMap {
        $0?.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
    )
  }

  /// Decide whether an ask naming `askSessionIds` (the CLI session that raised it, plus any
  /// id it resumed FROM) belongs to the conversation this shared-DM page is currently
  /// showing. Every session lives under one chatId, so the session — not the chatId — is
  /// the real scope.
  /// - `owns`: this page represents one of those sessions. That is the explicitly-loaded
  ///   History session, the adopted active session, the engine's live session for this
  ///   chat, OR a `bridge-<sid>-` transcript row actually on screen. The row check is what
  ///   `bridgePageSessionIds()` alone missed: plain-text history rows carry no runtime
  ///   metadata (nothing to adopt), so a cold-opened thread had an EMPTY session set and
  ///   the old disjoint test failed open — popping another conversation's approval here.
  /// - `hasIdentity`: this page represents SOME bridge session (a picked/adopted id, or any
  ///   `bridge-` row on screen). When true but `owns` is false the ask is a definite
  ///   cross-conversation leak → drop. When false the surface has no session identity yet
  ///   (fresh thread, nothing rendered) → the caller fails open (the send / live-session
  ///   engagement guard upstream still covers a truly un-engaged surface). The engine's
  ///   live session is a positive `owns` signal but deliberately NOT an identity signal:
  ///   it's chatId-scoped and ambiguous across concurrent runs, so it must never force a
  ///   drop by itself.
  func bridgeAskSessionScope(_ askSessionIds: Set<String>) -> (owns: Bool, hasIdentity: Bool) {
    let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let loaded = bridgeLoadedSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let active = activeBridgeSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let live = ChatEngine.shared.liveBridgeSessionId(chatId: chatKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    func rowsShow(session sid: String) -> Bool {
      let prefix = "bridge-\(sid)-"
      return rows.contains { ($0.messageId ?? "").hasPrefix(prefix) }
    }
    let owns = askSessionIds.contains { sid in
      if let loaded, !loaded.isEmpty, loaded == sid { return true }
      if let active, !active.isEmpty, active == sid { return true }
      if let live, !live.isEmpty, live == sid { return true }
      return rowsShow(session: sid)
    }
    let hasIdentity =
      (loaded?.isEmpty == false)
      || (active?.isEmpty == false)
      || rows.contains { ($0.messageId ?? "").hasPrefix("bridge-") }
    return (owns, hasIdentity)
  }

  /// Mirrors VibeAgentConversationView.handleAgentBridgeAsk, but runs when only the chat
  /// surface is shown so an `ask_user` / plan still prompts. No-ops if the full-page agent
  /// view is hosting this DM (it owns the sheet then), or on a chat/provider/dedup mismatch.
  private func presentAgentBridgeAskIfNeeded(_ info: [AnyHashable: Any]) {
    let infoChatId = (info["chatId"] as? String) ?? ""
    // All agent sessions share ONE DM chatId, so provider is what distinguishes runs.
    let infoProvider =
      (info["provider"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    // Defer to the full-page agent view ONLY when it can actually handle THIS ask — i.e.
    // it's alive AND wired to this DM's chatId AND not a different provider (then it owns
    // the sheet + the plan re-run path). A stray/unconfigured agent controller (nil/empty/
    // mismatched chatId — e.g. one still observing after a New Chat reset, or created before
    // the chat bound) or one for the WRONG provider must NOT swallow the ask: its own
    // handler DROPs on the chatId/provider guard, so a presence-only check here left BOTH
    // surfaces declining and nothing presented. The shared atomic claim still prevents a
    // double-present when both surfaces are genuinely valid.
    // Only defer to the full-page agent view when it's actually ON SCREEN. A hosted-but-hidden
    // agent VC (backed out to the bubble, or belonging to another page) must NOT swallow the
    // ask — otherwise both surfaces decline and nothing presents until the next re-emit.
    if let agentVC = presentedBridgeAgentVC,
      agentVC.viewIfLoaded?.window != nil,
      let vcChat = agentVC.agentBridgeChatId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !vcChat.isEmpty, vcChat == infoChatId
    {
      let vcProv =
        (agentVC.agentBridgeProvider ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let providerConflict = !infoProvider.isEmpty && !vcProv.isEmpty && infoProvider != vcProv
      if !providerConflict {
        NSLog("[ChatListView][ask] DEFER — full-page agent view owns chat=%@ provider=%@", vcChat, vcProv)
        return
      }
    }

    let requestId = (info["requestId"] as? String) ?? ""
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty, infoChatId == chatId else {
      NSLog("[ChatListView][ask] DROP — chatId mismatch vc=%@ info=%@", chatId, infoChatId)
      return
    }
    guard !requestId.isEmpty else { return }
    // Scope by provider too — a Codex ask must not surface on a Claude chat (and
    // vice-versa). Only drop on a definite mismatch.
    let vcProvider =
      (currentBridgeProvider ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !infoProvider.isEmpty, !vcProvider.isEmpty, infoProvider != vcProvider {
      NSLog(
        "[ChatListView][ask] DROP — provider mismatch chat=%@ vc=%@ info=%@",
        chatId, vcProvider, infoProvider)
      return
    }

    // Only present when THIS chat is the one actually on screen. A background/recycled chat
    // view can still hold this chatId (window != nil, behind a pushed/presented page) and would
    // otherwise pop the sheet over an unrelated screen. Dropping here is safe: the bridge
    // re-emits a still-blocked ask when the chat is reopened, so it surfaces then.
    guard isVisibleFrontmostChat() else {
      NSLog("[ChatListView][ask] DROP — not the visible chat requestId=%@ chat=%@", requestId, chatId)
      return
    }

    // Every agent run shares this ONE DM chatId, so a chatId match is NOT enough to say
    // the ask belongs to the conversation on screen. A fresh New-Chat surface (nothing
    // sent from it, no live session adopted) receiving an ask means the ask belongs to a
    // PREVIOUS conversation's still-running task — popping it over the clean page is the
    // "approval lands in an unrelated chat" bug. Drop it here; the bridge re-emits a
    // still-blocked ask on the next open of the owning conversation (and the engine's
    // pending-ask cache re-surfaces it once this surface engages the running session).
    let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let surfaceEngaged =
      !(Self.bridgeFreshOwnSentIdsByChat[chatKey] ?? []).isEmpty
      || bridgeLoadedSessionId != nil
      || ChatEngine.shared.liveBridgeSessionId(chatId: chatKey) != nil
    guard surfaceEngaged else {
      NSLog(
        "[ChatListView][ask] DROP — fresh un-engaged surface, ask belongs to a prior conversation requestId=%@ chat=%@",
        requestId, chatId)
      return
    }

    // CONVERSATION scoping (beyond chatId+provider, which every session shares): the ask
    // carries the CLI session that raised it (+ the id it resumed from — a resume mints a
    // new session id but the page still knows the conversation by the old one). This
    // page's identity is the explicitly-picked History session and/or the session adopted
    // from its visible turns. The ENGINE's live session is deliberately NOT consulted —
    // it's chatId-scoped, so it always equals the asker's session and would neuter the
    // guard. When both sides name sessions and none intersect, the ask belongs to a
    // DIFFERENT conversation → drop; it surfaces on the owning page (bridge re-emits on
    // open) and meanwhile shows as the header/History "waiting for approval" state.
    let askSessionIds = Set(
      [
        (info["sessionId"] as? String) ?? "",
        (info["resumedFromSessionId"] as? String) ?? "",
      ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    )
    if !askSessionIds.isEmpty {
      let scope = bridgeAskSessionScope(askSessionIds)
      if !scope.owns, scope.hasIdentity {
        NSLog(
          "[ChatListView][ask] DROP — session mismatch ask=%@ (this page shows a different conversation) requestId=%@",
          askSessionIds.joined(separator: ","), requestId)
        return
      }
    }

    guard let payload = ChatEngine.shared.latestAgentBridgeAsk(requestId: requestId) else {
      NSLog("[ChatListView][ask] DROP — no stored payload requestId=%@", requestId)
      return
    }
    // Body is E2E-sealed (`askEnc`); fall back to plaintext `request` for a keyless pairing.
    var body: [String: Any]
    if let dec = AgentRuntimeCrypto.decrypt(payload["askEnc"]) {
      body = dec
    } else if let raw = payload["request"] as? [String: Any] {
      body = ["request": raw]
    } else {
      NSLog("[ChatListView][ask] DROP — decrypt failed & no plaintext requestId=%@", requestId)
      return
    }
    let kind = (body["kind"] as? String) ?? (info["kind"] as? String) ?? "ask"
    let request = (body["request"] as? [String: Any]) ?? body
    let provider = info["provider"] as? String

    guard let presenter = topPresentingViewController() else {
      NSLog("[ChatListView][ask] DROP — no presenter requestId=%@", requestId)
      return
    }
    // Cross-surface dedup: claim once so a full-page agent view doesn't also present it.
    guard ChatEngine.shared.claimAgentBridgeAskPresentation(requestId: requestId) else {
      NSLog("[ChatListView][ask] DROP — already claimed by another surface requestId=%@", requestId)
      return
    }
    // If the presenter is mid-presentation (another sheet/picker/panel up), UIKit drops
    // present() silently. Release the claim so a re-emit (the bridge re-pushes a still-blocked
    // ask when the chat is reopened) can retry once the presenter is free — otherwise the claim
    // leaks and every later re-emit is dropped as "already claimed", so the sheet never reappears.
    if let busy = presenter.presentedViewController {
      NSLog("[ChatListView][ask] RETRY-LATER — presenter busy (%@) requestId=%@",
        String(describing: type(of: busy)), requestId)
      ChatEngine.shared.releaseAgentBridgeAskPresentation(requestId: requestId)
      return
    }
    let kitAppearance: VibeAgentKitChatAppearance =
      traitCollection.userInterfaceStyle == .light ? .lightFallback : .fallback
    let sheet = VibeAgentAskSheetViewController(
      kind: kind, request: request, appearance: kitAppearance, requestId: requestId)
    sheet.onResolve = { [weak self] decision, answer in
      self?.resolveAgentBridgeAsk(
        requestId: requestId, kind: kind, provider: provider,
        request: request, decision: decision, answer: answer)
    }
    sheet.onDismissWithoutResolve = {
      ChatEngine.shared.releaseAgentBridgeAskPresentation(requestId: requestId)
    }
    let nav = UINavigationController(rootViewController: sheet)
    nav.modalPresentationStyle = .pageSheet
    nav.view.backgroundColor = .clear
    if let presentation = nav.sheetPresentationController {
      presentation.detents = [.medium(), .large()]
      presentation.prefersGrabberVisible = true
      presentation.preferredCornerRadius = 22
    }
    NSLog("[ChatListView][ask] PRESENT sheet kind=%@ requestId=%@ chat=%@", kind, requestId, chatId)
    presenter.present(nav, animated: true)
  }

  /// Send the ask answer back to the bridge; for an approved/rejected plan, continue the
  /// run on the normal chat send path (mirrors VibeAgentConversationView.resolveAgentBridgeAsk).
  private func resolveAgentBridgeAsk(
    requestId: String, kind: String, provider: String?,
    request: [String: Any], decision: String, answer: [String: Any]?
  ) {
    var payload: [String: Any] = [
      "chatId": engineChatId,
      "requestId": requestId,
      "decision": decision,
    ]
    if let provider, !provider.isEmpty { payload["provider"] = provider }
    if let answer, !answer.isEmpty { payload["answer"] = answer }
    _ = ChatEngine.shared.sendAgentBridgeAskResponse(payload)

    guard kind == "plan" else { return }
    let resolvedProvider = currentBridgeProvider ?? provider ?? "codex"
    let feedback = (answer?["feedback"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    if decision == "approve" {
      // Approving means edits are OK → leave plan mode so the implementation turn can write.
      AgentBridgeSelectionStore.setWorkMode(.allowEdits)
      var prompt = "The plan above is approved. Implement it now, end to end."
      if let feedback, !feedback.isEmpty { prompt += "\n\nAdditional guidance:\n\(feedback)" }
      if let plan = (request["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !plan.isEmpty
      {
        prompt += "\n\nApproved plan:\n\(plan)"
      }
      handleNativeSend(text: prompt, mentionedAgentUsername: resolvedProvider)
    } else if decision == "reject", let feedback, !feedback.isEmpty {
      handleNativeSend(
        text: "Please revise the plan based on this feedback, then present the updated plan:\n\(feedback)",
        mentionedAgentUsername: resolvedProvider)
    }
  }

  private func hydrateRowsFromNativeHistoryIfReady(trigger: String) {
    guard statusAuthorityEnabled else {
      NSLog("[ChatOpen] hydrate SKIP trigger=%@ reason=statusAuthorityDisabled", trigger)
      return
    }
    let resolvedChatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolvedChatId.isEmpty else {
      NSLog("[ChatOpen] hydrate SKIP trigger=%@ reason=noChatId", trigger)
      return
    }

    // FAST PATH (synchronous, main thread): when the list is still empty but native
    // history is already available on-device (cached in memory or restorable from the
    // disk cache), paint it on THIS runloop — the same runloop as the trigger (chatId
    // bound / view attached). Previously the first render only happened after the async
    // probe below bounced to a background queue and back, so a chat with cached history
    // still flashed EMPTY through the whole push animation while the JS setRows
    // round-trip caught up. `mergedRowsPayload` already performs exactly this engine
    // read synchronously on the main thread, so this adds no new main-thread contract —
    // it just does it a beat earlier, before the chat is on screen.
    if rows.isEmpty {
      let historyReadyNow = ChatEngine.shared.isChatHistoryLoaded(chatId: resolvedChatId)
      if historyReadyNow || !nativeEngineRowsById.isEmpty {
        NSLog(
          "[ChatOpen] hydrate FAST-PATH trigger=%@ chatId=%@ historyReady=%@ overlay=%d sourceRows=%d — rendering synchronously",
          trigger, resolvedChatId, historyReadyNow ? "Y" : "N",
          nativeEngineRowsById.count, sourceRowsPayload.count)
        setRows(sourceRowsPayload)
      } else {
        NSLog(
          "[ChatOpen] hydrate fast-path unavailable trigger=%@ chatId=%@ (no cached history, no overlay) — awaiting JS setRows",
          trigger, resolvedChatId)
      }
    }

    nativeHistoryHydrationGeneration &+= 1
    let generation = nativeHistoryHydrationGeneration
    let shouldRestoreLiveRows = nativeEngineRowsById.isEmpty

    DispatchQueue.global(qos: .utility).async { [weak self] in
      let liveRows =
        shouldRestoreLiveRows
        ? ChatEngine.shared.getLiveMessageRows(["chatId": resolvedChatId])
        : [:]
      let historyLoaded = ChatEngine.shared.isChatHistoryLoaded(chatId: resolvedChatId)

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard self.statusAuthorityEnabled else { return }
        guard self.nativeHistoryHydrationGeneration == generation else { return }
        guard self.engineChatId.trimmingCharacters(in: .whitespacesAndNewlines) == resolvedChatId
        else { return }

        // Restore overlay rows from ChatEngine's live index so messages sent while
        // the view was detached can render immediately before JS catches up.
        if self.nativeEngineRowsById.isEmpty, !liveRows.isEmpty {
          for (rawMessageId, row) in liveRows {
            guard let messageId = self.normalizedMessageId(rawMessageId) else { continue }
            self.nativeEngineRowsById[messageId] = row
            if !self.nativeEngineOrder.contains(messageId) {
              self.nativeEngineOrder.append(messageId)
            }
          }
          NSLog(
            "[ChatListView] hydrateRowsFromNativeHistoryIfReady restored overlay from live rows trigger=%@ chatId=%@ count=%d",
            trigger, resolvedChatId, liveRows.count
          )
        }

        if !historyLoaded && self.nativeEngineRowsById.isEmpty {
          NSLog(
            "[ChatOpen] hydrate async BAIL trigger=%@ chatId=%@ historyLoaded=N overlay=0 rows=%d — chat stays as-is until JS setRows arrives",
            trigger, resolvedChatId, self.rows.count)
          return
        }
        NSLog(
          "[ChatOpen] hydrate async APPLY trigger=%@ chatId=%@ sourceRows=%d overlay=%d historyLoaded=%@ rows=%d",
          trigger, resolvedChatId, self.sourceRowsPayload.count, self.nativeEngineRowsById.count,
          historyLoaded ? "Y" : "N", self.rows.count
        )
        self.setRows(self.sourceRowsPayload)
      }
    }
  }

  private func updateChatEngineBinding() {
    guard !engineSurfaceId.isEmpty else { return }
    let payload: [String: Any] = [
      "surfaceId": engineSurfaceId,
      "chatId": engineChatId,
      "myUserId": engineMyUserId,
      "peerUserId": enginePeerUserId,
      "peerAgentId": enginePeerAgentId,
    ]
    chatListEngineBindingQueue.async {
      _ = ChatEngine.shared.bindSurface(payload)
    }
  }

  private func updateChatEngineChannelBinding(forceDetach: Bool = false) {
    let desiredChatId: String?
    if forceDetach || window == nil || !engineChannelBindingEnabled {
      desiredChatId = nil
    } else {
      desiredChatId = engineChatId.isEmpty ? nil : engineChatId
    }

    if !engineOpenedChatId.isEmpty, engineOpenedChatId != desiredChatId {
      let closeChatId = engineOpenedChatId
      chatListEngineBindingQueue.async {
        _ = ChatEngine.shared.closeChatChannel(["chatId": closeChatId])
      }
      engineOpenedChatId = ""
    }

    if let desiredChatId, engineOpenedChatId != desiredChatId {
      chatListEngineBindingQueue.async {
        _ = ChatEngine.shared.openChatChannel(["chatId": desiredChatId])
      }
      engineOpenedChatId = desiredChatId
    }
  }

  private func resolvedDisplayStatus(for row: ChatListRow) -> String? {
    let resolved = rawResolvedDisplayStatus(for: row)
    guard row.isMe, resolved == "sent" || resolved == "delivered" else {
      return resolved
    }
    guard let rowIndex = rows.firstIndex(where: { candidate in
      if let messageId = row.messageId, let candidateId = candidate.messageId {
        return messageId == candidateId
      }
      return candidate.key == row.key
    }) else {
      return resolved
    }
    for later in rows.dropFirst(rowIndex + 1) where later.isMe && later.kind == .message {
      if rawResolvedDisplayStatus(for: later) == "read" {
        return "read"
      }
    }
    return resolved
  }

  private func rawResolvedDisplayStatus(for row: ChatListRow) -> String? {
    guard statusAuthorityEnabled else {
      return row.status?.lowercased()
    }
    return ChatEngine.shared.resolveDisplayStatus(
      chatId: engineChatId.isEmpty ? nil : engineChatId,
      messageId: row.messageId,
      rawStatus: row.status,
      isMe: row.isMe,
      peerUserId: enginePeerUserId.isEmpty ? nil : enginePeerUserId
    )
  }

  private func refreshVisibleStatuses(reason: String) {
    guard statusAuthorityEnabled else { return }
    guard window != nil else { return }
    guard !rows.isEmpty else { return }
    for case let cell as ChatListCell in collectionView.visibleCells {
      guard let indexPath = collectionView.indexPath(for: cell), indexPath.item < rows.count else {
        continue
      }
      cell.resolveDisplayStatus = { [weak self] row in
        self?.resolvedDisplayStatus(for: row)
      }
      let row = rows[indexPath.item]
      cell.configure(
        row: row,
        hiddenMessageId: hiddenMessageId,
        selectionMode: selectionMode,
        selected: row.messageId.map { selectedMessageIds.contains($0) } ?? false,
        agentTurnState: agentTurnBubbleState(for: row)
      )
      bindWallpaperBackdrop(to: cell)
    }
  }

  public func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    guard indexPath.item < rows.count else {
      return CGSize(width: max(0.0, bounds.width - (messageHorizontalInset * 2.0)), height: 56.0)
    }
    let row = rows[indexPath.item]
    let width = max(0.0, bounds.width - (messageHorizontalInset * 2.0))
    if row.kind == .day {
      return CGSize(width: width, height: 30.0)
    }
    // Group rows reserve a leading avatar gutter (narrows the bubble) and, on the first
    // message of a sender-run, extra top space for the name label. Both must match what
    // the cell lays out, so the same context drives measurement and layout.
    let ctx = groupCellContext(at: indexPath)
    let extraLeading = ctx.reservesGutter ? Self.groupIncomingExtraLeading : 0.0
    let extraTop = ctx.showsName ? Self.groupSenderNameHeight : 0.0
    let measurementWidth = max(1.0, width - extraLeading)
    let bubbleHeight = estimateMessageHeight(row, rowWidth: measurementWidth)
    return CGSize(width: width, height: bubbleHeight + extraTop)
  }

  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let offsetY = scrollView.contentOffset.y

    var wallpaperFrame = bounds
    wallpaperFrame.origin.y = offsetY
    wallpaperContainerView.frame = wallpaperFrame
    collectionView.sendSubviewToBack(wallpaperContainerView)

    if customContextMenuOverlay != nil {
      dismissCustomContextMenu(animated: false)
    }
    _ = offsetY - previousOffsetY  // delta unused
    previousOffsetY = offsetY
    probeGroupCellOverlap(reason: "scroll")
    updateScrollToneOverlay(offsetY: offsetY)
    refreshWallpaperSnapshotIfNeeded()
    updateVisibleWallpaperBackdropLayouts()

    if let activeSendTransition {
      if skipNextTransitionScrollCorrection {
        skipNextTransitionScrollCorrection = false
      } else {
        // With additive animations, we just update the model position to
        // follow the real cell. The additive offset decays independently.
        updateTransitionFrame(activeSendTransition)
      }
    } else if let fadingSendTransition {
      // Reveal crossfade in progress: the overlay is a static ghost on top of
      // the real cell — keep it glued if this scroll moved the cell.
      updateTransitionFrame(fadingSendTransition)
    }

    if !isInternalScrollAdjustment {
      let distanceFromBottom = currentDistanceFromBottom()
      shouldAutoScroll = distanceFromBottom <= listBottomThreshold

      // Agent turn: once the user physically drags the list, stop re-pinning the
      // question to the top so they can scroll freely for the rest of the turn.
      if (agentChatMode || currentBridgeProvider != nil), agentStreaming || agentPushToTopSpacer > 0,
        collectionView.isTracking || collectionView.isDragging
      {
        agentPinUserDetached = true
      }
    }
    scheduleVisibleAutoDownloads()
    maybeStartPendingSendTransition()
    maybeLoadOlderBridgeHistoryIfNeeded(offsetY: offsetY)
    updateFloatingSenderAvatars()
    emitViewport()
    updateJumpToBottomButtonVisibility()
  }

  /// Position one floating avatar per visible incoming sender-run in the reserved gutter.
  /// The avatar bottom-aligns to the run's last message but stays clamped inside the run's
  /// vertical span, so it "follows" the run up/down as you scroll instead of duplicating
  /// per message. Cheap: only touches currently-visible runs.
  private func updateFloatingSenderAvatars() {
    guard isGroupOrChannel, !rows.isEmpty else {
      if !senderAvatarViews.isEmpty {
        senderAvatarViews.values.forEach { $0.removeFromSuperview() }
        senderAvatarViews.removeAll()
      }
      return
    }

    let visible = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
    guard let firstVisible = visible.first?.item, let lastVisible = visible.last?.item else {
      senderAvatarViews.values.forEach { $0.isHidden = true }
      return
    }

    let offsetY = collectionView.contentOffset.y
    let size = Self.groupAvatarSize
    let avatarX = messageHorizontalInset + bubbleSideMargin
    let viewportBottom = offsetY + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
    var liveRunIds = Set<String>()

    // Walk each visible row; when it's the LAST message of an incoming run, resolve the
    // run's [top, bottom] span and place the run's single avatar.
    var item = firstVisible
    while item <= lastVisible {
      defer { item += 1 }
      let ctx = groupCellContext(at: IndexPath(item: item, section: 0))
      guard ctx.reservesGutter, ctx.isLastOfRun, let key = ctx.senderKey else { continue }

      // Find the run's first index (walk back while same sender).
      var firstIndex = item
      while firstIndex > 0 {
        let prev = adjacentGroupMessageRow(from: firstIndex, delta: -1)
        if let prev, resolvedSenderKey(prev) == key {
          firstIndex -= 1
        } else {
          break
        }
      }
      guard
        let lastAttrs = collectionView.layoutAttributesForItem(at: IndexPath(item: item, section: 0)),
        let firstAttrs = collectionView.layoutAttributesForItem(
          at: IndexPath(item: firstIndex, section: 0))
      else { continue }

      let runTop = firstAttrs.frame.minY
      let runBottom = lastAttrs.frame.maxY
      // Bottom-align to the last bubble, but never let the avatar leave the run's span and
      // keep it inside the viewport when the whole run is taller than the screen.
      let desiredBottom = min(runBottom, max(runTop + size, viewportBottom))
      let avatarContentY = max(runTop, min(runBottom, desiredBottom) - size)
      let runId = rows[item].messageId ?? "\(key)-\(item)"
      liveRunIds.insert(runId)

      let avatarView: SenderRunAvatarView
      if let existing = senderAvatarViews[runId] {
        avatarView = existing
      } else {
        avatarView = SenderRunAvatarView()
        senderAvatarOverlay.addSubview(avatarView)
        senderAvatarViews[runId] = avatarView
      }
      avatarView.isHidden = false
      avatarView.frame = CGRect(x: avatarX, y: avatarContentY - offsetY, width: size, height: size)
      let info = ctx.senderKey.flatMap { groupSenderDirectory[$0] }
      avatarView.configure(
        name: info?.name ?? ctx.senderName ?? "",
        avatarUrl: ctx.avatarUrl,
        tint: ctx.senderColor ?? .systemGray,
        provider: ctx.provider)
    }

    // Retire avatars whose run scrolled away.
    for (runId, view) in senderAvatarViews where !liveRunIds.contains(runId) {
      view.removeFromSuperview()
      senderAvatarViews.removeValue(forKey: runId)
    }
  }

  // [GroupCellOverlap] Debug probe for the "messy overlapping Codex cell" report. Logs
  // (via NSLog so it shows in Console) only when two ADJACENT group rows are laid out with
  // overlapping frames — silent otherwise. Captures each row's identity (agent kind / error
  // / notice), assigned frame Y+height, and a text prefix so we can tell whether it's a
  // notice+result pair or a single row that grew without reflow. Remove once fixed.
  private var lastOverlapProbeAt: TimeInterval = 0
  private func probeGroupCellOverlap(reason: String, force: Bool = false) {
    guard isGroupOrChannel else { return }
    let now = Date().timeIntervalSinceReferenceDate
    if !force {
      guard now - lastOverlapProbeAt > 0.15 else { return }
    }
    lastOverlapProbeAt = now
    let visible = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
    guard visible.count >= 2 else { return }
    for i in 0..<(visible.count - 1) {
      let a = visible[i], b = visible[i + 1]
      guard b.item == a.item + 1 else { continue }
      guard
        let fa = collectionView.layoutAttributesForItem(at: a)?.frame,
        let fb = collectionView.layoutAttributesForItem(at: b)?.frame
      else { continue }
      let overlap = fa.maxY - fb.minY
      guard overlap > 0.5 else { continue }
      let ra = a.item < rows.count ? rows[a.item] : nil
      let rb = b.item < rows.count ? rows[b.item] : nil
      let line = String(
        format:
          "[GroupCellOverlap] %@ overlap=%.1fpt a[%d]{key=%@ agent=%@ kind=%@ err=%@ y=%.0f h=%.0f \"%@\"} b[%d]{key=%@ agent=%@ kind=%@ err=%@ y=%.0f h=%.0f \"%@\"}",
        reason, overlap,
        a.item, String((ra?.key ?? "?").prefix(10)), (ra?.isAgentMessage ?? false) ? "y" : "n",
        ra?.agentMsgKind ?? "-", (ra?.isAgentError ?? false) ? "y" : "n", fa.minY, fa.height,
        String((ra?.text ?? "").prefix(22)),
        b.item, String((rb?.key ?? "?").prefix(10)), (rb?.isAgentMessage ?? false) ? "y" : "n",
        rb?.agentMsgKind ?? "-", (rb?.isAgentError ?? false) ? "y" : "n", fb.minY, fb.height,
        String((rb?.text ?? "").prefix(22)))
      NSLog("%@", line)
      Self.appendOverlapProbeLine(line)
    }
  }

  // Mirror overlap-probe lines to a file in the app's tmp dir so they can be pulled off the
  // device without root: `devicectl device copy from --domain-type temporary
  // --domain-identifier com.vibegram.app --source group_overlap_probe.log ...`.
  private static func appendOverlapProbeLine(_ line: String) {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("group_overlap_probe.log")
    let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
    guard let data = stamped.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: path) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: URL(fileURLWithPath: path))
    }
  }

  private func maybeLoadOlderBridgeHistoryIfNeeded(offsetY: CGFloat) {
    guard currentBridgeProvider != nil else { return }
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return }
    let loadedSessionId = bridgeLoadedSessionId ?? ChatEngine.shared.liveBridgeSessionId(chatId: chatId)
    guard loadedSessionId != nil else { return }
    guard offsetY < 220.0 else { return }
    guard collectionView.isDragging || collectionView.isTracking || collectionView.isDecelerating else { return }
    let now = Date().timeIntervalSinceReferenceDate
    guard now - lastOlderBridgeHistoryLoadAt > 0.75 else { return }
    let result = ChatEngine.shared.loadOlderAgentBridgeSessionChunk(chatId: chatId)
    if (result["accepted"] as? Bool) == true {
      lastOlderBridgeHistoryLoadAt = now
    }
  }

  public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate {
      runVisibleAutoDownloads()
      flushDeferredAgentStreamingRelayoutIfNeeded()
    }
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    runVisibleAutoDownloads()
    flushDeferredAgentStreamingRelayoutIfNeeded()
  }

  private func updateBottomAnchorInset() {
    // Re-entry guard: this method invalidates layout and calls layoutIfNeeded,
    // which can trigger layoutSubviews → updateBottomAnchorInset again, causing
    // a visible bounce as insets oscillate.
    guard !isUpdatingBottomInset else { return }
    isUpdatingBottomInset = true
    defer { isUpdatingBottomInset = false }

    let baseInsets = UIEdgeInsets(
      top: contentPaddingTop, left: messageHorizontalInset,
      bottom: contentPaddingBottom,
      right: messageHorizontalInset)
    let currentInsets = flowLayout.sectionInset
    let contentHeight = collectionView.collectionViewLayout.collectionViewContentSize.height
    let contentWithoutInsets = max(0.0, contentHeight - currentInsets.top - currentInsets.bottom)
    let desiredTop =
      agentChatMode
      ? baseInsets.top
      : max(baseInsets.top, collectionView.bounds.height - contentWithoutInsets - baseInsets.bottom)

    let topUnchanged = abs(desiredTop - currentInsets.top) <= 0.5
    let bottomUnchanged = abs(baseInsets.bottom - currentInsets.bottom) <= 0.5
    if topUnchanged && bottomUnchanged {
      return
    }
    flowLayout.sectionInset = UIEdgeInsets(
      top: desiredTop, left: baseInsets.left, bottom: baseInsets.bottom, right: baseInsets.right)
    flowLayout.invalidateLayout()
    collectionView.layoutIfNeeded()
    updateScrollToneOverlay(offsetY: collectionView.contentOffset.y)
  }

  private func estimateMessageHeight(_ row: ChatListRow, rowWidth: CGFloat) -> CGFloat {
    // Agent control/context events (interrupt, /compact) render as a centered divider
    // pill, not a bubble — give them a fixed compact height like the day separator.
    if agentSystemDividerText(for: row) != nil {
      return 36.0
    }
    // Agent turns are the one row type whose measurement is genuinely expensive
    // (`VibeAgentTurnContentView.measuredHeight` parses the FULL progress payload and
    // runs an offscreen Auto Layout pass). A streaming chunk invalidates the whole
    // layout, so without memoization every FINALIZED agent turn in the transcript gets
    // fully re-measured on every chunk of the live one. Cache by row key and reuse
    // while the row's content, width, and expand state are unchanged — the live
    // streaming row misses the cache exactly once per chunk, which is the minimum.
    if bubbleUsesAgentTurnContent(row) {
      let state = agentTurnBubbleState(for: row)
      if let cached = agentTurnHeightCache[row.key],
        cached.rowWidth == rowWidth,
        cached.state == state,
        chatListRowContentEqual(cached.row, row)
      {
        return cached.height
      }
      let height = measureMessageBubbleLayout(
        row: row, rowWidth: rowWidth, agentTurnState: state
      ).bubbleHeight
      agentTurnHeightCache[row.key] = RowHeightCacheEntry(
        row: row, rowWidth: rowWidth, state: state, height: height)
      return height
    }
    // Ordinary message rows: reuse the last measured height while the row's content, width,
    // and tall-expand state are unchanged. This is the hot path on chat open — a long
    // transcript re-measured across several layout passes — see messageHeightCache.
    let state = agentTurnBubbleState(for: row)
    if let cached = messageHeightCache[row.key],
      cached.rowWidth == rowWidth,
      cached.state == state,
      chatListRowContentEqual(cached.row, row)
    {
      return cached.height
    }
    let height = measureMessageBubbleLayout(
      row: row, rowWidth: rowWidth, agentTurnState: state
    ).bubbleHeight
    messageHeightCache[row.key] = RowHeightCacheEntry(
      row: row, rowWidth: rowWidth, state: state, height: height)
    return height
  }

  private func shouldDeferBottomScrollForPendingSend(
    _ payload: SendTransitionPayload,
    parsedRows: [ChatListRow]
  ) -> Bool {
    guard
      let row = parsedRows.first(where: { $0.messageId == payload.messageId }),
      row.kind == .message,
      row.visualKind == .text
    else {
      return false
    }
    let rowWidth = max(1.0, collectionView.bounds.width - (messageHorizontalInset * 2.0))
    let metrics = measureMessageBubbleLayout(
      row: row, rowWidth: rowWidth, agentTurnState: agentTurnBubbleState(for: row)
    )
    let sourceHeight = max(1.0, payload.resolvedSourceBackgroundRect.height)
    let heightDelta = metrics.bubbleHeight - sourceHeight
    return metrics.bubbleHeight >= 112.0 && heightDelta >= 44.0
  }

  private func currentDistanceFromBottom() -> CGFloat {
    let contentHeight = collectionView.contentSize.height
    let layoutHeight = collectionView.bounds.height
    let offsetY = collectionView.contentOffset.y
    return max(0.0, contentHeight - (offsetY + layoutHeight))
  }

  private func restoreStationaryDistance(_ distanceFromBottom: CGFloat) {
    // The agent surface never re-anchors the offset to a captured distance-from-
    // bottom. That value grows as the answer streams in (and is recomputed on every
    // link-preview / markdown relayout), so re-applying it drags the user back down
    // and prevents scrolling. The user owns the scroll; only the send pin moves it.
    if agentChatMode {
      return
    }
    let targetOffset = max(
      0.0, collectionView.contentSize.height - collectionView.bounds.height - distanceFromBottom)
    _ = targetOffset - collectionView.contentOffset.y  // delta unused
    if let activeSendTransition {
      skipNextTransitionScrollCorrection = true
      updateTransitionFrame(activeSendTransition)
    }
    performInternalScrollAdjustment {
      collectionView.setContentOffset(CGPoint(x: 0.0, y: targetOffset), animated: false)
    }
    previousOffsetY = collectionView.contentOffset.y
    shouldAutoScroll = false
  }

  /// Gentle stick-to-bottom for a streaming agent turn growing in place. Unlike
  /// `scrollToBottom` this (a) also runs in a bridge DM (where scrollToBottom no-ops to
  /// protect the user's scroll), because it is only reachable when the user was ALREADY
  /// near the bottom before this growth tick; (b) never fires while the user's finger
  /// owns the scroll; and (c) animates with `.beginFromCurrentState` so back-to-back
  /// chunks chase the bottom as one continuous glide instead of a per-chunk snap.
  private func followBottomForAgentTurnGrowth() {
    guard !agentChatMode else { return }  // agent surface: pin logic owns the offset
    guard
      !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating
    else { return }
    let maxOffsetY = pixelAlignedValue(
      max(0.0, collectionView.contentSize.height - collectionView.bounds.height))
    guard maxOffsetY - collectionView.contentOffset.y > 0.5 else { return }
    shouldAutoScroll = true
    isInternalScrollAdjustment = true
    UIView.animate(
      withDuration: 0.25,
      delay: 0.0,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) { [weak self] in
      self?.collectionView.contentOffset = CGPoint(x: 0.0, y: maxOffsetY)
    } completion: { [weak self] _ in
      guard let self else { return }
      self.isInternalScrollAdjustment = false
      self.previousOffsetY = self.collectionView.contentOffset.y
      self.emitViewport(force: true)
    }
  }

  private func finishRowsUpdate() {
    isApplyingRowsUpdate = false
    guard let queued = pendingRowsPayload else {
      return
    }
    pendingRowsPayload = nil
    setRows(queued)
  }

  private func performInternalScrollAdjustment(_ block: () -> Void) {
    isInternalScrollAdjustment = true
    block()
    DispatchQueue.main.async { [weak self] in
      self?.isInternalScrollAdjustment = false
    }
  }

  private func payloadCGFloat(_ value: Any?) -> CGFloat? {
    if let number = value as? NSNumber {
      return CGFloat(number.doubleValue)
    }
    if let number = value as? Double {
      return CGFloat(number)
    }
    if let number = value as? Int {
      return CGFloat(number)
    }
    if let text = value as? String, let parsed = Double(text) {
      return CGFloat(parsed)
    }
    return nil
  }

  private func resolvedReactionFxColor(_ value: Any?) -> UIColor {
    if let raw = value as? String, let color = parseReactionFxColor(raw) {
      return color
    }
    return (appearance.bubbleMeGradient.last ?? UIColor.white).withAlphaComponent(0.95)
  }

  private func parseReactionFxColor(_ raw: String) -> UIColor? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("#") else { return nil }
    var hex = String(trimmed.dropFirst())
    if hex.count == 3 {
      hex = hex.map { "\($0)\($0)" }.joined()
    }
    guard hex.count == 6 else { return nil }
    var value: UInt64 = 0
    guard Scanner(string: hex).scanHexInt64(&value) else { return nil }
    let r = CGFloat((value & 0xFF0000) >> 16) / 255.0
    let g = CGFloat((value & 0x00FF00) >> 8) / 255.0
    let b = CGFloat(value & 0x0000FF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: 1.0)
  }

  private func renderNativeReactionFxBurst(emoji: String, at point: CGPoint, tintColor: UIColor) {
    ChatReactionFxModule.shared.playLandingEffect(
      emoji: emoji,
      at: point,
      in: transitionOverlayHost,
      tintOverride: tintColor
    )
  }

  private func messageId(fromRawRow row: [String: Any]) -> String? {
    guard
      (row["kind"] as? String) == "message",
      let message = row["message"] as? [String: Any],
      let messageId = normalizedMessageId(message["id"])
    else {
      return nil
    }
    return messageId
  }

  private func replyToMessageId(fromRawMessage message: [String: Any]) -> String? {
    let metadata = message["metadata"] as? [String: Any]
    let extra = message["extra"] as? [String: Any]
    return normalizedMessageId(message["replyToId"])
      ?? normalizedMessageId(message["reply_to_id"])
      ?? normalizedMessageId(message["replyToMessageId"])
      ?? normalizedMessageId(message["reply_to_message_id"])
      ?? normalizedMessageId(metadata?["replyToId"])
      ?? normalizedMessageId(metadata?["reply_to_id"])
      ?? normalizedMessageId(extra?["replyToId"])
      ?? normalizedMessageId(extra?["reply_to_id"])
  }

  private func replyPreviewDescriptor(forRawRow row: [String: Any]) -> (title: String, text: String)? {
    guard
      (row["kind"] as? String) == "message",
      let message = row["message"] as? [String: Any],
      messageId(fromRawRow: row) != nil
    else {
      return nil
    }

    let metadata = message["metadata"] as? [String: Any]
    let type = (nonEmptyString(from: message["type"]) ?? "text").lowercased()
    let peerName = enginePeerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let title =
      isMeMessage(rawRow: row)
      ? "You"
      : (nonEmptyString(from: message["senderName"])
        ?? nonEmptyString(from: message["sender_name"])
        ?? nonEmptyString(from: metadata?["senderName"])
        ?? nonEmptyString(from: metadata?["sender_name"])
        ?? (peerName.isEmpty ? "Reply" : peerName))

    if let text =
      nonEmptyString(from: message["text"])
      ?? nonEmptyString(from: message["caption"])
      ?? nonEmptyString(from: metadata?["caption"])
    {
      return (title, text)
    }

    if let fileName =
      nonEmptyString(from: message["fileName"])
      ?? nonEmptyString(from: message["file_name"])
      ?? nonEmptyString(from: metadata?["fileName"])
      ?? nonEmptyString(from: metadata?["file_name"])
    {
      return (title, fileName)
    }

    switch type {
    case "image", "gif":
      return (title, "Photo")
    case "video":
      return (title, "Video")
    case "voice", "audio", "music", "mp3":
      return (title, "Voice message")
    case "sticker":
      return (title, "Sticker")
    case "file":
      return (title, "File")
    default:
      return (title, "Message")
    }
  }

  private func rowsByAttachingReplyPreviews(_ rows: [[String: Any]]) -> [[String: Any]] {
    var previewsById: [String: (title: String, text: String)] = [:]
    previewsById.reserveCapacity(rows.count)
    for row in rows {
      guard let messageId = messageId(fromRawRow: row),
        let descriptor = replyPreviewDescriptor(forRawRow: row)
      else {
        continue
      }
      previewsById[messageId] = descriptor
    }

    return rows.map { row in
      guard
        (row["kind"] as? String) == "message",
        var message = row["message"] as? [String: Any],
        let replyToId = replyToMessageId(fromRawMessage: message)
      else {
        return row
      }

      message["replyToId"] = replyToId
      if let preview = previewsById[replyToId] {
        if (nonEmptyString(from: message["replyPreviewTitle"])
          ?? nonEmptyString(from: message["reply_preview_title"])) == nil
        {
          message["replyPreviewTitle"] = preview.title
        }
        if (nonEmptyString(from: message["replyPreviewText"])
          ?? nonEmptyString(from: message["reply_preview_text"])) == nil
        {
          message["replyPreviewText"] = preview.text
        }
      }

      var patchedRow = row
      patchedRow["message"] = message
      return patchedRow
    }
  }

  private func normalizedMessageId(_ raw: Any?) -> String? {
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = raw as? NSNumber {
      return value.stringValue
    }
    if let value = raw as? Int {
      return String(value)
    }
    if let value = raw as? Double, value.isFinite {
      return String(value)
    }
    return nil
  }

  private func rawRow(messageId targetMessageId: String, in payload: [[String: Any]])
    -> [String: Any]?
  {
    payload.first(where: { messageId(fromRawRow: $0) == targetMessageId })
  }

  private func isMeMessage(rawRow row: [String: Any]) -> Bool {
    guard let message = row["message"] as? [String: Any] else { return false }
    return
      (message["isMe"] as? Bool)
      ?? (message["isMe"] as? NSNumber)?.boolValue
      ?? false
  }

  private func patchBubbleShape(
    in row: [String: Any],
    showTail: Bool? = nil,
    topRightRadius: CGFloat? = nil,
    bottomRightRadius: CGFloat? = nil
  ) -> [String: Any] {
    guard var message = row["message"] as? [String: Any] else { return row }
    var shape =
      (message["bubbleShape"] as? [String: Any])
      ?? [
        "showTail": true,
        "borderTopLeftRadius": 18,
        "borderTopRightRadius": 18,
        "borderBottomRightRadius": 18,
        "borderBottomLeftRadius": 18,
      ]
    if let showTail {
      shape["showTail"] = showTail
    }
    if let topRightRadius {
      shape["borderTopRightRadius"] = topRightRadius
    }
    if let bottomRightRadius {
      shape["borderBottomRightRadius"] = bottomRightRadius
    }
    message["bubbleShape"] = shape
    var patchedRow = row
    patchedRow["message"] = message
    return patchedRow
  }

  private func rowsByApplyingNativeOutgoingSequenceShape(
    _ rows: [[String: Any]],
    nativeOutgoingIds: Set<String>
  ) -> [[String: Any]] {
    guard !nativeOutgoingIds.isEmpty else { return rows }
    var patchedRows = rows
    let messageIndices = rows.indices.filter { messageId(fromRawRow: rows[$0]) != nil }

    for (offset, rowIndex) in messageIndices.enumerated() {
      guard let currentMessageId = messageId(fromRawRow: rows[rowIndex]) else { continue }
      let isNativeOutgoing = nativeOutgoingIds.contains(currentMessageId)
      let isMe = isMeMessage(rawRow: rows[rowIndex])
      guard isMe else { continue }

      let previousIndex = offset > 0 ? messageIndices[offset - 1] : nil
      let nextIndex = offset + 1 < messageIndices.count ? messageIndices[offset + 1] : nil
      let previousSameSender =
        previousIndex.map { isMeMessage(rawRow: rows[$0]) == isMe } ?? false
      let nextSameSender =
        nextIndex.map { isMeMessage(rawRow: rows[$0]) == isMe } ?? false
      let nextIsNativeOutgoing =
        nextIndex.flatMap { messageId(fromRawRow: rows[$0]) }.map {
          nativeOutgoingIds.contains($0)
        } ?? false

      if isNativeOutgoing {
        patchedRows[rowIndex] = patchBubbleShape(
          in: patchedRows[rowIndex],
          showTail: !nextSameSender,
          topRightRadius: previousSameSender ? nativeSendMorphTopRightRadius : 18.0,
          bottomRightRadius: nextSameSender ? 5.0 : 18.0
        )
      } else if nextSameSender && nextIsNativeOutgoing {
        patchedRows[rowIndex] = patchBubbleShape(
          in: patchedRows[rowIndex],
          showTail: false,
          bottomRightRadius: 5.0
        )
      }
    }

    return patchedRows
  }

  private func nonEmptyString(from raw: Any?) -> String? {
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = raw as? NSNumber {
      return value.stringValue
    }
    if let value = raw as? Int {
      return String(value)
    }
    if let value = raw as? Double, value.isFinite {
      return String(value)
    }
    return nil
  }

  private func mediaKey(fromRawRow row: [String: Any]) -> String? {
    let message = row["message"] as? [String: Any]
    let metadata = message?["metadata"] as? [String: Any]
    return nonEmptyString(from: message?["mediaKey"])
      ?? nonEmptyString(from: message?["media_key"])
      ?? nonEmptyString(from: metadata?["mediaKey"])
      ?? nonEmptyString(from: metadata?["media_key"])
      ?? nonEmptyString(from: row["mediaKey"])
      ?? nonEmptyString(from: row["media_key"])
  }

  private func resolvedMediaKey(for row: ChatListRow) -> String? {
    if let mediaKey = nonEmptyString(from: row.mediaKey) {
      return mediaKey
    }
    guard let messageId = normalizedMessageId(row.messageId) else {
      return nil
    }
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let liveEngineRow: [String: Any]? = {
      guard !chatId.isEmpty else { return nil }
      return ChatEngine.shared.getLiveMessageRow([
        "chatId": chatId,
        "messageId": messageId,
      ])
    }()
    let candidates: [[String: Any]?] = [
      rawRow(messageId: messageId, in: sourceRowsPayload),
      nativeOutgoingRowsById[messageId],
      nativeEngineRowsById[messageId],
      liveEngineRow,
    ]
    for candidate in candidates {
      guard let candidate, let mediaKey = mediaKey(fromRawRow: candidate) else { continue }
      return mediaKey
    }
    return nil
  }

  private func rowByApplyingReactionEmoji(
    _ emoji: String,
    toMessageId targetMessageId: String,
    row: [String: Any]
  ) -> (row: [String: Any], changed: Bool) {
    guard messageId(fromRawRow: row) == targetMessageId else { return (row, false) }
    guard var message = row["message"] as? [String: Any] else { return (row, false) }
    let existing = (message["reactionEmoji"] as? String)?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    if existing == emoji {
      return (row, false)
    }
    message["reactionEmoji"] = emoji
    var patched = row
    patched["message"] = message
    return (patched, true)
  }

  func applyLocalReactionEmoji(_ emoji: String, toMessageId messageId: String) {
    let targetMessageId = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !targetMessageId.isEmpty, !trimmedEmoji.isEmpty else { return }
    reactionDebugTargetMessageId = targetMessageId
    reactionDebugTargetEmoji = trimmedEmoji
    reactionDebugRemainingRowsChecks = 12
    reactionDebugLog(
      "applyLocal start id=\(targetMessageId) emoji=\(trimmedEmoji) sourceCount=\(sourceRowsPayload.count) nativeOut=\(nativeOutgoingRowsById[targetMessageId] != nil ? "Y" : "N") nativeEngine=\(nativeEngineRowsById[targetMessageId] != nil ? "Y" : "N")"
    )

    var didPatch = false
    var sourcePatched = false
    var outgoingPatched = false
    var enginePatched = false
    var patchedSourceRow: [String: Any]?

    if !sourceRowsPayload.isEmpty {
      let patched = sourceRowsPayload.map { row -> [String: Any] in
        let result = rowByApplyingReactionEmoji(
          trimmedEmoji, toMessageId: targetMessageId, row: row)
        if result.changed {
          didPatch = true
          sourcePatched = true
          patchedSourceRow = result.row
        }
        return result.row
      }
      sourceRowsPayload = patched
    }

    if let row = nativeOutgoingRowsById[targetMessageId] {
      let result = rowByApplyingReactionEmoji(trimmedEmoji, toMessageId: targetMessageId, row: row)
      nativeOutgoingRowsById[targetMessageId] = result.row
      didPatch = didPatch || result.changed
      outgoingPatched = result.changed
    }

    if let row = nativeEngineRowsById[targetMessageId] {
      let result = rowByApplyingReactionEmoji(trimmedEmoji, toMessageId: targetMessageId, row: row)
      nativeEngineRowsById[targetMessageId] = result.row
      didPatch = didPatch || result.changed
      enginePatched = result.changed
    } else if let patchedRow = patchedSourceRow {
      // Store reaction overlay so it survives mergedRowsPayload when engine
      // rows replace sourceRowsPayload as the effective base.
      nativeEngineRowsById[targetMessageId] = patchedRow
      enginePatched = true
    }

    reactionDebugLog(
      "applyLocal patchResult id=\(targetMessageId) didPatch=\(didPatch ? "Y" : "N") source=\(sourcePatched ? "Y" : "N") outgoing=\(outgoingPatched ? "Y" : "N") engine=\(enginePatched ? "Y" : "N")"
    )
    guard didPatch else {
      reactionDebugLog("applyLocal skipped id=\(targetMessageId) no row changed")
      return
    }
    setRows(sourceRowsPayload)
  }

  private func resolveTransitionRow(for payload: SendTransitionPayload) -> ChatListRow? {
    if let rowIndex = indexForMessage(payload.messageId), rowIndex < rows.count {
      return rows[rowIndex]
    }
    if let row = rawRow(messageId: payload.messageId, in: sourceRowsPayload),
      let parsed = ChatListRow(raw: row)
    {
      return parsed
    }
    if let row = nativeOutgoingRowsById[payload.messageId], let parsed = ChatListRow(raw: row) {
      return parsed
    }
    return nil
  }

  private func projectedTransitionTargetRect(for row: ChatListRow) -> CGRect? {
    guard row.kind == .message else {
      return nil
    }
    let rowWidth = max(1.0, collectionView.bounds.width - (messageHorizontalInset * 2.0))
    let metrics = measureMessageBubbleLayout(
      row: row, rowWidth: rowWidth, agentTurnState: agentTurnBubbleState(for: row)
    )
    let bubbleXInRow =
      row.isMe ? rowWidth - metrics.bubbleWidth - bubbleSideMargin : bubbleSideMargin

    let bubbleYInHost: CGFloat = {
      let listMinY = collectionView.frame.minY
      if inputBarEnabled, let bar = activeNativeInputView {
        let barMinYInHost = bar.frame.minY
        return max(listMinY + contentPaddingTop, barMinYInHost - metrics.bubbleHeight - 2.0)
      }
      let listVisibleBottom = listMinY + collectionView.bounds.height
      return max(
        listMinY + contentPaddingTop,
        listVisibleBottom - contentPaddingBottom - metrics.bubbleHeight)
    }()

    // TRUE (un-rounded) rect: the flight's landing target must not be
    // integer-rounded away from the real cell's fractional bubble rect, or the
    // completion snap onto the real rect shows up as a ≤1px jump at reveal.
    return CGRect(
      x: collectionView.frame.minX + messageHorizontalInset + bubbleXInRow,
      y: bubbleYInHost,
      width: metrics.bubbleWidth,
      height: metrics.bubbleHeight
    )
  }

  private func mergedRowsPayload(from baseRows: [[String: Any]]) -> [[String: Any]] {
    let effectiveBaseRows: [[String: Any]] = {
      guard statusAuthorityEnabled, !engineChatId.isEmpty else { return baseRows }
      // Only use native engine rows as the primary source when native history
      // has actually been fetched from the server AND the native row count is
      // at least as large as what JS provides. If decryption failed for most
      // messages the native set will be tiny — never replace a larger JS set
      // with a smaller native set or messages will visually disappear.
      let historyReady = ChatEngine.shared.isChatHistoryLoaded(chatId: engineChatId)
      if historyReady {
        let nativeRows = ChatEngine.shared.getChatRows(["chatId": engineChatId])
        if !nativeRows.isEmpty, nativeRows.count >= baseRows.count || baseRows.isEmpty {
          if nativeRows.count <= 4 || baseRows.count <= 4 {
            NSLog(
              "[FirstMsg] mergedRows base=NATIVE native=%d js=%d outgoing=%d overlay=%d",
              nativeRows.count, baseRows.count, nativeOutgoingOrder.count,
              nativeEngineRowsById.count)
          }
          return nativeRows
        }
        if nativeRows.isEmpty, baseRows.count <= 4 {
          NSLog(
            "[FirstMsg] mergedRows historyReady but native EMPTY js=%d outgoing=%d overlay=%d",
            baseRows.count, nativeOutgoingOrder.count, nativeEngineRowsById.count)
        }
      }
      return baseRows
    }()

    var engineMergedRows = effectiveBaseRows
    if !nativeEngineRowsById.isEmpty || !nativeDeletedMessageIds.isEmpty {
      var filteredBase: [[String: Any]] = []
      filteredBase.reserveCapacity(effectiveBaseRows.count)
      var baseMessageIds = Set<String>()

      for row in effectiveBaseRows {
        if let messageId = messageId(fromRawRow: row) {
          if nativeDeletedMessageIds.contains(messageId) {
            continue
          }
          baseMessageIds.insert(messageId)
        }
        filteredBase.append(row)
      }

      nativeDeletedMessageIds = nativeDeletedMessageIds.filter { deletedId in
        baseMessageIds.contains(deletedId) || nativeEngineRowsById[deletedId] != nil
      }.reduce(into: Set<String>()) { $0.insert($1) }

      var mergedRows: [[String: Any]] = []
      mergedRows.reserveCapacity(filteredBase.count + nativeEngineRowsById.count)
      for row in filteredBase {
        if let messageId = messageId(fromRawRow: row),
          let overlay = nativeEngineRowsById[messageId]
        {
          mergedRows.append(mergeMessageRowPreservingShape(baseRow: row, overlayRow: overlay))
        } else {
          mergedRows.append(row)
        }
      }

      var nextEngineOrder: [String] = []
      nextEngineOrder.reserveCapacity(nativeEngineOrder.count)
      for messageId in nativeEngineOrder {
        guard let overlay = nativeEngineRowsById[messageId] else { continue }
        if baseMessageIds.contains(messageId) {
          nextEngineOrder.append(messageId)
          continue
        }
        mergedRows.append(overlay)
        nextEngineOrder.append(messageId)
      }
      nativeEngineOrder = nextEngineOrder
      engineMergedRows = mergedRows
    }

    guard nativeSendEnabled, !nativeOutgoingOrder.isEmpty else {
      return rowsByAttachingReplyPreviews(engineMergedRows)
    }

    var baseMessageIds = Set<String>()
    for row in engineMergedRows {
      if let messageId = messageId(fromRawRow: row) {
        baseMessageIds.insert(messageId)
      }
    }

    var effectiveBaseIds = Set<String>()
    for row in effectiveBaseRows {
      if let messageId = messageId(fromRawRow: row) {
        effectiveBaseIds.insert(messageId)
      }
    }

    // Pre-clean: remove native outgoing copies whose server-confirmed version
    // is already present in the base rows. Do this BEFORE building the merged
    // array so the diff algorithm never sees the same key jump positions
    // (which would trigger a full reloadData and cause cells to flash).
    var nextOrder: [String] = []
    for messageId in nativeOutgoingOrder {
      if nativeOutgoingRowsById[messageId] == nil {
        continue
      }
      if effectiveBaseIds.contains(messageId) {
        NSLog(
          "[FirstMsg] mergedRows PRE-CLEAN drop outgoing msgId=%@ (present in base %d rows)",
          String(messageId.prefix(12)), effectiveBaseIds.count)
        nativeOutgoingRowsById.removeValue(forKey: messageId)
        continue
      }
      nextOrder.append(messageId)
    }
    nativeOutgoingOrder = nextOrder

    guard !nativeOutgoingOrder.isEmpty else {
      return rowsByAttachingReplyPreviews(engineMergedRows)
    }

    var merged = engineMergedRows
    for messageId in nativeOutgoingOrder {
      if baseMessageIds.contains(messageId) {
        continue
      }
      guard let row = nativeOutgoingRowsById[messageId] else {
        continue
      }
      merged.append(row)
    }
    let shapedRows = rowsByApplyingNativeOutgoingSequenceShape(
      merged,
      nativeOutgoingIds: Set(nativeOutgoingOrder)
    )
    return rowsByAttachingReplyPreviews(shapedRows)
  }

  private func mergeMessageRowPreservingShape(baseRow: [String: Any], overlayRow: [String: Any])
    -> [String: Any]
  {
    guard
      let baseMessage = baseRow["message"] as? [String: Any],
      let overlayMessage = overlayRow["message"] as? [String: Any]
    else {
      return overlayRow
    }

    var mergedMessage = baseMessage
    for (key, value) in overlayMessage {
      mergedMessage[key] = value
    }
    if let baseBubbleShape = baseMessage["bubbleShape"] {
      mergedMessage["bubbleShape"] = baseBubbleShape
    }
    if let targetMessageId = reactionDebugTargetMessageId,
      let baseId = normalizedMessageId(baseMessage["id"]),
      baseId == targetMessageId
    {
      let baseReaction = (baseMessage["reactionEmoji"] as? String) ?? "nil"
      let overlayReaction = (overlayMessage["reactionEmoji"] as? String) ?? "nil"
      let mergedReaction = (mergedMessage["reactionEmoji"] as? String) ?? "nil"
      reactionDebugLog(
        "mergeRow id=\(targetMessageId) baseReaction=\(baseReaction) overlayReaction=\(overlayReaction) mergedReaction=\(mergedReaction)"
      )
    }

    var mergedRow = baseRow
    for (key, value) in overlayRow {
      mergedRow[key] = value
    }
    mergedRow["message"] = mergedMessage
    return mergedRow
  }

  private func syncNativeEngineMessageMutation(reason: String, messageId: String?, action: String?)
  {
    let resolvedMessageId = messageId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resolvedChatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolvedChatId.isEmpty, !resolvedMessageId.isEmpty else { return }

    let normalizedAction = action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let isDeleteReason = reason == "chatMessageDeleted" || normalizedAction == "deleted"

    if isDeleteReason {
      nativeEngineRowsById.removeValue(forKey: resolvedMessageId)
      nativeDeletedMessageIds.insert(resolvedMessageId)
    } else if reason == "chatMessageInserted" || reason == "chatMessageEdited"
      || reason == "chatMessageChanged"
    {
      if let row = ChatEngine.shared.getLiveMessageRow([
        "chatId": resolvedChatId,
        "messageId": resolvedMessageId,
      ]) {
        nativeEngineRowsById[resolvedMessageId] = row
        nativeDeletedMessageIds.remove(resolvedMessageId)
        if !nativeEngineOrder.contains(resolvedMessageId) {
          nativeEngineOrder.append(resolvedMessageId)
        }
      } else if ChatEngine.shared.isLiveMessageDeleted([
        "chatId": resolvedChatId,
        "messageId": resolvedMessageId,
      ]) {
        nativeEngineRowsById.removeValue(forKey: resolvedMessageId)
        nativeDeletedMessageIds.insert(resolvedMessageId)
      }
    }

    let isAgent: Bool = {
      if let row = nativeEngineRowsById[resolvedMessageId],
        let msg = row["message"] as? [String: Any]
      {
        return (msg["isAgentMessage"] as? Bool) == true
      }
      return false
    }()
    NSLog(
      "[ChatListEngine] syncMutation reason:%@ msgId:%@ action:%@ isAgent:%@ engineRows:%d engineOrder:%d",
      reason, String(resolvedMessageId.prefix(12)), normalizedAction ?? "nil",
      isAgent ? "Y" : "N", nativeEngineRowsById.count, nativeEngineOrder.count)
    if reason == "chatMessageChanged" && isAgent {
      // Agent stream ticks land many times per second, and every one of them was doing a
      // FULL setRows (merge + per-row decrypt/parse + measure) synchronously on the main
      // thread — starving touch delivery, which the user feels as the list refusing to
      // scroll while a turn streams. Coalesce these to a bounded cadence; inserts/deletes
      // and non-agent edits still apply immediately.
      scheduleStreamCoalescedSetRows()
    } else {
      streamSyncCoalesceWorkItem?.cancel()
      streamSyncCoalesceWorkItem = nil
      lastStreamSyncApplyAt = CACurrentMediaTime()
      setRows(sourceRowsPayload)
    }
  }

  private static let streamSyncMinInterval: CFTimeInterval = 0.12
  private func scheduleStreamCoalescedSetRows() {
    guard streamSyncCoalesceWorkItem == nil else { return }
    let now = CACurrentMediaTime()
    let elapsed = now - lastStreamSyncApplyAt
    if elapsed >= Self.streamSyncMinInterval {
      lastStreamSyncApplyAt = now
      setRows(sourceRowsPayload)
      return
    }
    // Trailing edge: always ends with a refresh carrying the final state.
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.streamSyncCoalesceWorkItem = nil
      self.lastStreamSyncApplyAt = CACurrentMediaTime()
      self.setRows(self.sourceRowsPayload)
    }
    streamSyncCoalesceWorkItem = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + (Self.streamSyncMinInterval - elapsed), execute: work)
  }

  private func queueNativeOutgoingMessage(
    messageId: String,
    text: String,
    timestamp: String,
    timestampMs: Double,
    replyToId: String? = nil,
    autoMarkSent: Bool = true,
    metadata: [String: Any] = [:]
  ) {
    let isPreviousMe: Bool = {
      if let lastMessageRow = rows.last(where: { $0.kind == .message }) {
        return lastMessageRow.isMe
      }
      return false
    }()
    let borderTopRightRadius: CGFloat = isPreviousMe ? nativeSendMorphTopRightRadius : 18.0

    var message: [String: Any] = [
      "id": messageId,
      "text": text,
      "timestamp": timestamp,
      "timestampMs": timestampMs,
      "isMe": true,
      "status": "pending",
      "type": "text",
      "bubbleShape": [
        "showTail": true,
        "borderTopLeftRadius": 18,
        "borderTopRightRadius": borderTopRightRadius,
        "borderBottomRightRadius": 18,
        "borderBottomLeftRadius": 18,
      ],
    ]
    if let replyToId {
      message["replyToId"] = replyToId
    }
    if !metadata.isEmpty {
      message["metadata"] = metadata
    }
    nativeOutgoingRowsById[messageId] = [
      "kind": "message",
      "key": "m-\(messageId)",
      "message": message,
    ]
    if !nativeOutgoingOrder.contains(messageId) {
      nativeOutgoingOrder.append(messageId)
    }
    setRows(sourceRowsPayload)

    guard autoMarkSent else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self,
        var row = self.nativeOutgoingRowsById[messageId],
        var message = row["message"] as? [String: Any]
      else {
        return
      }
      message["status"] = "sent"
      row["message"] = message
      self.nativeOutgoingRowsById[messageId] = row
      self.setRows(self.sourceRowsPayload)
    }
  }

  private func queueNativeOutgoingMediaMessage(
    messageId: String,
    type: String,
    localUri: String,
    caption: String?,
    timestamp: String,
    timestampMs: Double,
    fileName: String? = nil,
    fileSize: Int64? = nil,
    duration: Double? = nil,
    mediaSize: CGSize? = nil,
    thumbnailBase64: String? = nil,
    replyToId: String? = nil
  ) {
    let isPreviousMe: Bool = {
      if let lastMessageRow = rows.last(where: { $0.kind == .message }) {
        return lastMessageRow.isMe
      }
      return false
    }()
    let borderTopRightRadius: CGFloat = isPreviousMe ? nativeSendMorphTopRightRadius : 18.0
    var metadata: [String: Any] = [
      "mediaUrl": localUri,
      "localMediaUrl": localUri,
      "uploadProgress": 0.027,
    ]
    if let fileName { metadata["fileName"] = fileName }
    if let fileSize, fileSize > 0 { metadata["fileSize"] = fileSize }
    if let duration { metadata["duration"] = duration }
    if let mediaSize, mediaSize.width > 1.0, mediaSize.height > 1.0 {
      metadata["width"] = Int(mediaSize.width)
      metadata["height"] = Int(mediaSize.height)
    }
    if let thumbnailBase64, !thumbnailBase64.isEmpty {
      metadata["thumbnailBase64"] = thumbnailBase64
    }

    var message: [String: Any] = [
      "id": messageId,
      "text": caption ?? "",
      "timestamp": timestamp,
      "timestampMs": timestampMs,
      "isMe": true,
      "status": "pending",
      "type": type,
      "mediaUrl": localUri,
      "localMediaUrl": localUri,
      "uploadProgress": 0.027,
      "metadata": metadata,
      "bubbleShape": [
        "showTail": true,
        "borderTopLeftRadius": 18,
        "borderTopRightRadius": borderTopRightRadius,
        "borderBottomRightRadius": 18,
        "borderBottomLeftRadius": 18,
      ],
    ]
    if let fileName { message["fileName"] = fileName }
    if let fileSize, fileSize > 0 { message["fileSize"] = fileSize }
    if let duration { message["duration"] = duration }
    if let mediaSize, mediaSize.width > 1.0, mediaSize.height > 1.0 {
      message["width"] = Int(mediaSize.width)
      message["height"] = Int(mediaSize.height)
    }
    if let thumbnailBase64, !thumbnailBase64.isEmpty {
      message["thumbnailBase64"] = thumbnailBase64
    }
    if let replyToId { message["replyToId"] = replyToId }

    nativeOutgoingRowsById[messageId] = [
      "kind": "message",
      "key": "m-\(messageId)",
      "message": message,
    ]
    if !nativeOutgoingOrder.contains(messageId) {
      nativeOutgoingOrder.append(messageId)
    }
    setRows(sourceRowsPayload)
  }

  private func setNativeOutgoingMessageStatus(_ messageId: String, status: String) {
    guard var row = nativeOutgoingRowsById[messageId],
      var message = row["message"] as? [String: Any]
    else {
      return
    }
    message["status"] = status
    row["message"] = message
    nativeOutgoingRowsById[messageId] = row
    setRows(sourceRowsPayload)
  }

  private func removeNativeOutgoingMessage(_ messageId: String) {
    nativeOutgoingRowsById.removeValue(forKey: messageId)
    nativeOutgoingOrder.removeAll { $0 == messageId }
    nativeEngineRowsById.removeValue(forKey: messageId)
    nativeDeletedMessageIds.insert(messageId)
    if hiddenMessageId == messageId { hiddenMessageId = nil }
    if pendingSendTransition?.messageId == messageId { pendingSendTransition = nil }
    if activeSendTransition?.payload.messageId == messageId {
      activeSendTransition?.invalidate()
      activeSendTransition = nil
    }
    setRows(sourceRowsPayload)
  }

  private func showBridgeSendFailure(messageId: String, reason: String, provider: String?) {
    let bridgeFreshChatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    if !bridgeFreshChatKey.isEmpty {
      Self.bridgeFreshOwnSentIdsByChat[bridgeFreshChatKey]?.remove(messageId)
    }
    removeNativeOutgoingMessage(messageId)
    let trimmedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayProvider =
      trimmedProvider?.isEmpty == false ? trimmedProvider!.capitalized : "Bridge"
    NSLog(
      "[ChatListView] bridge send failed messageId=%@ provider=%@ reason=%@",
      messageId,
      displayProvider,
      reason
    )
    onNativeEvent([
      "type": "agentToast",
      "message": "\(displayProvider) message did not reach the bridge. Try again.",
    ])
  }

  func cancelOutgoingMessage(row: ChatListRow, source: String) {
    guard let messageId = normalizedMessageId(row.messageId) else { return }
    let rowChatId = row.chatId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let chatId = rowChatId.isEmpty ? engineChatId.trimmingCharacters(in: .whitespacesAndNewlines) : rowChatId
    guard !chatId.isEmpty else { return }
    // Optimistically remove the bubble from every local store so it disappears
    // immediately; the engine removal (chatMessageDeleted) confirms it.
    nativeOutgoingRowsById.removeValue(forKey: messageId)
    nativeEngineRowsById.removeValue(forKey: messageId)
    nativeDeletedMessageIds.insert(messageId)
    setRows(sourceRowsPayload)
    DispatchQueue.global(qos: .utility).async {
      let result = ChatEngine.shared.cancelOutgoingMessage([
        "chatId": chatId,
        "messageId": messageId,
      ])
      NSLog(
        "[ChatListView] cancelOutgoingMessage source=%@ chatId=%@ messageId=%@ result=%@",
        source, chatId, messageId, String(describing: result))
    }
  }

  /// Tapping the "!" on a failed message re-opens it for editing: the text drops
  /// back into the composer and the original id is armed so the next send reuses
  /// it (the agent transport then truncates the stale turn). In non-agent chat we
  /// fall back to a straight resend.
  func handleNotSentTap(row: ChatListRow) {
    guard let messageId = normalizedMessageId(row.messageId) else { return }
    guard agentChatMode else {
      retryOutgoingMessage(row: row, source: "not_sent_tap")
      return
    }
    let editText = row.plainContent ?? row.text
    editingAgentMessageId = messageId
    inputBar?.setComposerText(editText)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  func retryOutgoingMessage(row: ChatListRow, source: String) {
    guard let messageId = normalizedMessageId(row.messageId) else { return }
    // Agent chat: the headless agent transport owns these bubbles (not the
    // ChatEngine), so re-send through it reusing the original message id. The
    // transport truncates the stale turn + tail before re-appending, which keeps
    // the list clean instead of stacking a duplicate exchange.
    if agentChatMode {
      let resendText = row.plainContent ?? row.text
      guard !resendText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      onNativeEvent([
        "type": "sendMessage",
        "messageId": messageId,
        "text": resendText,
      ])
      return
    }
    let rowChatId = row.chatId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let chatId = rowChatId.isEmpty ? engineChatId.trimmingCharacters(in: .whitespacesAndNewlines) : rowChatId
    guard !chatId.isEmpty else { return }
    setNativeOutgoingMessageStatus(messageId, status: "pending")
    DispatchQueue.global(qos: .utility).async {
      let result = ChatEngine.shared.retryOutgoingMessage([
        "chatId": chatId,
        "messageId": messageId,
      ])
      NSLog(
        "[ChatListView] retryOutgoingMessage source=%@ chatId=%@ messageId=%@ result=%@ status=%@ journalTail=%@",
        source,
        chatId,
        messageId,
        String(describing: result),
        String(describing: ChatEngine.shared.getStatus()),
        String(describing: Array(ChatEngine.shared.getJournal().suffix(6)))
      )
    }
  }

  private func indexForMessage(_ messageId: String) -> Int? {
    rows.firstIndex(where: { row in
      row.kind == .message && row.messageId == messageId
    })
  }

  private func resolveTransitionTargetRect(
    messageId: String,
    fallbackPayload: SendTransitionPayload? = nil
  ) -> CGRect? {
    if projectedSendTransitionMessageId == messageId,
      let fallbackPayload,
      let row = resolveTransitionRow(for: fallbackPayload),
      let projected = projectedTransitionTargetRect(for: row)
    {
      return projected
    }
    if let rowIndex = indexForMessage(messageId), rowIndex < rows.count {
      let indexPath = IndexPath(item: rowIndex, section: 0)
      if let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell,
        let rect = cell.bubbleRect(in: self)
      {
        return rect
      }
    }
    if let fallbackPayload, let row = resolveTransitionRow(for: fallbackPayload) {
      return projectedTransitionTargetRect(for: row)
    }
    return nil
  }

  private func makeTransitionSnapshotCell(for row: ChatListRow, targetBubbleRect: CGRect)
    -> ChatListCell
  {
    let rowWidth = max(1.0, bounds.width - (messageHorizontalInset * 2.0))
    let rowHeight: CGFloat
    if row.kind == .day {
      rowHeight = 30.0
    } else {
      rowHeight = estimateMessageHeight(row, rowWidth: rowWidth)
    }

    let renderCell = ChatListCell(
      frame: CGRect(x: messageHorizontalInset, y: 0.0, width: rowWidth, height: max(1.0, rowHeight))
    )
    renderCell.applyAppearance(appearance)
    renderCell.configure(row: row, hiddenMessageId: nil)
    bindWallpaperBackdrop(to: renderCell)
    transitionOverlayHost.addSubview(renderCell)
    renderCell.setNeedsLayout()
    renderCell.layoutIfNeeded()
    if let renderedBubbleRect = renderCell.bubbleRect(in: self) {
      renderCell.frame = renderCell.frame.offsetBy(
        dx: targetBubbleRect.minX - renderedBubbleRect.minX,
        dy: targetBubbleRect.minY - renderedBubbleRect.minY
      )
      renderCell.setNeedsLayout()
      renderCell.layoutIfNeeded()
      bindWallpaperBackdrop(to: renderCell)
      renderCell.updateWallpaperBackdropLayoutIfNeeded()
    }
    return renderCell
  }

  private func maybeStartPendingSendTransition() {
    guard activeSendTransition == nil, let payload = pendingSendTransition else {
      return
    }
    guard let targetRow = resolveTransitionRow(for: payload) else {
      NSLog(
        "[ChatListView] maybeStartPendingSendTransition — waiting, row unavailable for '%@'",
        payload.messageId)
      return
    }
    guard
      let targetRect = resolveTransitionTargetRect(
        messageId: payload.messageId,
        fallbackPayload: payload)
    else {
      NSLog(
        "[ChatListView] maybeStartPendingSendTransition — target rect unresolved for '%@'",
        payload.messageId)
      return
    }

    pendingSendTransition = nil
    collectionView.layoutIfNeeded()
    let settledTargetRect =
      resolveTransitionTargetRect(messageId: payload.messageId, fallbackPayload: payload)
      ?? targetRect
    let snapshotCell = makeTransitionSnapshotCell(
      for: targetRow,
      targetBubbleRect: settledTargetRect
    )
    defer {
      snapshotCell.removeFromSuperview()
    }

    // Build native send overlay: source/input ghost + bubble crossfade/morph.
    let overlayParts = SendTransitionOverlayFactory.make(
      appearance: appearance,
      snapshotCell: snapshotCell,
      targetBubbleRect: settledTargetRect,
      payload: payload,
      hostView: self
    )
    transitionOverlayHost.addSubview(overlayParts.container)
    positionTransitionOverlayHost()

    let state = SendTransitionState(
      host: self,
      payload: payload,
      overlayContainer: overlayParts.container,
      clippingView: overlayParts.clippingView,
      sourceBackgroundSnapshot: overlayParts.sourceBackgroundSnapshot,
      bubbleBackgroundSnapshot: overlayParts.bubbleBackgroundSnapshot,
      destinationContentSnapshot: overlayParts.destinationContentSnapshot,
      sourceTextSnapshot: overlayParts.sourceTextSnapshot,
      metaSnapshot: overlayParts.metaSnapshot,
      tailSnapshot: overlayParts.tailSnapshot,
      tailCornerTravel: overlayParts.tailCornerTravel,
      clipSettleRadius: overlayParts.clipSettleRadius,
      sourceBackgroundStartFrame: overlayParts.sourceBackgroundStartFrame,
      sourceBackgroundEndFrame: overlayParts.sourceBackgroundEndFrame,
      sourceContentStartFrame: overlayParts.sourceContentStartFrame,
      destinationContentFrame: overlayParts.destinationContentFrame,
      sourceScrollOffset: overlayParts.sourceScrollOffset
    )
    activeSendTransition = state
    onNativeEvent(["type": "sendTransitionStarted", "messageId": payload.messageId])

    // Start the additive animation from source rect → target rect.
    NSLog(
      "[ChatListView] sendTransition rects — source: (%.0f,%.0f %.0fx%.0f) target: (%.0f,%.0f %.0fx%.0f) bounds: %.0fx%.0f",
      overlayParts.sourceRect.minX, overlayParts.sourceRect.minY, overlayParts.sourceRect.width,
      overlayParts.sourceRect.height,
      settledTargetRect.minX, settledTargetRect.minY, settledTargetRect.width,
      settledTargetRect.height,
      bounds.width, bounds.height)
    state.start(sourceRect: overlayParts.sourceRect, targetRect: settledTargetRect)
    DispatchQueue.main.asyncAfter(
      deadline: .now() + SendMorphProfile.duration + 0.22
    ) { [weak self, weak state] in
      guard let self, let state else { return }
      guard self.activeSendTransition === state else { return }
      NSLog(
        "[ChatListView] sendTransition watchdog — forcing completion for messageId=%@",
        state.payload.messageId
      )
      self.completeTransition(state)
    }
  }

  /// Called by scrollViewDidScroll to keep the overlay tracking the real cell.
  func updateTransitionFrame(_ transition: SendTransitionState) {
    guard
      let targetRect = resolveTransitionTargetRect(
        messageId: transition.payload.messageId,
        fallbackPayload: transition.payload)
    else {
      return
    }
    transition.compensateScroll(targetRect: targetRect)
  }

  /// One-line landing report: where the overlay snapped vs where the real
  /// cell's bubble/tail actually are at the reveal instant. Sub-pixel deltas
  /// here are exactly the "tail grows a pixel at the end" class of artifact.
  private func logSendMorphLanding(_ transition: SendTransitionState, finalTargetRect: CGRect) {
    func fmt(_ r: CGRect) -> String {
      String(format: "(%.3f,%.3f %.3fx%.3f)", r.minX, r.minY, r.width, r.height)
    }
    var realRectText = "nil"
    var lobeText = "nil"
    var statusText = "?"
    var cellFrameText = "nil"
    if let rowIndex = indexForMessage(transition.payload.messageId), rowIndex < rows.count,
      let cell = collectionView.cellForItem(at: IndexPath(item: rowIndex, section: 0))
        as? ChatListCell
    {
      if let rect = cell.bubbleRect(in: self) {
        realRectText = fmt(rect)
      }
      if let lobe = cell.bubbleView.integratedTailLobePath() {
        lobeText = fmt(cell.bubbleView.convert(lobe.bounds, to: self))
      }
      statusText = rows[rowIndex].status ?? "nil"
      cellFrameText = fmt(cell.frame)
    }
    let overlayTailText =
      transition.tailSnapshot.map {
        fmt(transition.overlayContainer.convert($0.frame, to: self))
      } ?? "nil"
    NSLog(
      "[SendMorphDiag] target=%@ real=%@ plateEnd=%@ overlayTail=%@ realLobe=%@ status=%@ cell=%@ offsetY=%.3f",
      fmt(finalTargetRect), realRectText, fmt(transition.sourceBackgroundEndFrame),
      overlayTailText, lobeText, statusText, cellFrameText,
      collectionView.contentOffset.y)
  }

  func completeTransition(_ transition: SendTransitionState) {
    guard activeSendTransition === transition else {
      NSLog("[ChatListView] completeTransition — ignoring stale transition")
      return
    }
    NSLog(
      "[ChatListView] completeTransition — revealing message '%@'", transition.payload.messageId)
    transition.invalidate()
    // Final alignment: the flight may have been tracking a projected/estimated
    // rect, and rows updates can land without a scroll event. Clear the
    // projection first so the REAL cell's rect wins, then snap the overlay onto
    // it — the short crossfade below then starts pixel-aligned with the cell it
    // reveals instead of the bubble shifting at the hand-off into the list.
    if projectedSendTransitionMessageId == transition.payload.messageId {
      projectedSendTransitionMessageId = nil
    }
    if let finalTargetRect = resolveTransitionTargetRect(
      messageId: transition.payload.messageId, fallbackPayload: transition.payload)
    {
      transition.compensateScroll(targetRect: finalTargetRect)
      logSendMorphLanding(transition, finalTargetRect: finalTargetRect)
    }
    let shouldSettleDeferredBottomScroll =
      deferredPendingSendBottomScrollMessageId == transition.payload.messageId

    // Hard swap — NO crossfade. The landing is pixel-exact ([SendMorphDiag]
    // shows overlay == revealed cell to the third decimal), so any frame where
    // both are visible BLENDS two identical anti-aliased silhouettes: every
    // curved edge composites denser, and the small tail curve visibly gains
    // ~1px of weight for the fade duration, then settles ("tail grows at the
    // end"). Instead the reveal below and the overlay removal commit in the
    // SAME frame; only the rare async reveal paths keep the overlay one tick
    // so the swap never shows a one-frame hole.
    let overlay = transition.overlayContainer
    fadingSendTransition = transition
    var revealCellWasPresent = false
    let dropOverlay = { [weak self] in
      overlay.removeFromSuperview()
      if let self, self.fadingSendTransition === transition {
        self.fadingSendTransition = nil
      }
    }

    activeSendTransition = nil
    if shouldSettleDeferredBottomScroll {
      deferredPendingSendBottomScrollMessageId = nil
    }

    let revealedMessageId = hiddenMessageId
    hiddenMessageId = nil
    if let revealedMessageId {
      let rowIndex = indexForMessage(revealedMessageId)
      let cellPresent =
        rowIndex.map {
          collectionView.cellForItem(at: IndexPath(item: $0, section: 0)) != nil
        } ?? false
      NSLog(
        "[FirstMsg] reveal msgId=%@ rowIndex=%@ cellPresent=%@ rows=%d visible=%d offset=%.0f contentH=%.0f boundsH=%.0f",
        String(revealedMessageId.prefix(12)),
        rowIndex.map(String.init) ?? "nil",
        cellPresent ? "Y" : "N",
        rows.count,
        collectionView.indexPathsForVisibleItems.count,
        collectionView.contentOffset.y,
        collectionView.contentSize.height,
        collectionView.bounds.height)
    }
    if let revealedMessageId, let rowIndex = indexForMessage(revealedMessageId),
      rowIndex < rows.count
    {
      let indexPath = IndexPath(item: rowIndex, section: 0)
      let revealVisibleCell = { [weak self] in
        guard let self,
          let cell = self.collectionView.cellForItem(at: indexPath) as? ChatListCell,
          indexPath.item < self.rows.count
        else { return false }
        let row = self.rows[indexPath.item]
        cell.applyAppearance(self.appearance)
        cell.configure(
          row: row,
          hiddenMessageId: nil,
          selectionMode: self.selectionMode,
          selected: row.messageId.map { self.selectedMessageIds.contains($0) } ?? false,
          agentTurnState: self.agentTurnBubbleState(for: row)
        )
        self.bindWallpaperBackdrop(to: cell)
        cell.alpha = 1.0
        cell.contentView.alpha = 1.0
        cell.layer.opacity = 1.0
        cell.contentView.layer.opacity = 1.0
        cell.layer.removeAllAnimations()
        cell.contentView.layer.removeAllAnimations()
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        cell.updateWallpaperBackdropLayoutIfNeeded()
        return true
      }
      if let cell = self.collectionView.cellForItem(at: indexPath) as? ChatListCell {
        let row = self.rows[rowIndex]
        cell.applyAppearance(self.appearance)
        cell.configure(
          row: row,
          hiddenMessageId: nil,
          selectionMode: self.selectionMode,
          selected: row.messageId.map { self.selectedMessageIds.contains($0) } ?? false,
          agentTurnState: self.agentTurnBubbleState(for: row)
        )
        bindWallpaperBackdrop(to: cell)
        cell.alpha = 1.0
        cell.contentView.alpha = 1.0
        cell.layer.opacity = 1.0
        cell.contentView.layer.opacity = 1.0
        cell.layer.removeAllAnimations()
        cell.contentView.layer.removeAllAnimations()
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        cell.updateWallpaperBackdropLayoutIfNeeded()
        revealCellWasPresent = true
      } else {
        UIView.performWithoutAnimation {
          self.flowLayout.invalidateLayout()
          self.collectionView.layoutIfNeeded()
          self.collectionView.reloadItems(at: [indexPath])
          self.collectionView.layoutIfNeeded()
          revealCellWasPresent = revealVisibleCell()
        }
      }
      if let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell {
        let lobeText = cell.bubbleView.integratedTailLobePath().map { lobe -> String in
          let r = cell.bubbleView.convert(lobe.bounds, to: self)
          return String(format: "(%.3f,%.3f %.3fx%.3f)", r.minX, r.minY, r.width, r.height)
        }
        NSLog(
          "[SendMorphDiag] postReveal lobe=%@ ghost=%@ showTail=%@",
          lobeText ?? "nil",
          cell.isConfiguredGhostHidden ? "Y" : "N",
          (cell.row?.shape.showTail ?? false) ? "Y" : "N")
      }
      if rows.filter({ $0.kind == .message }).count == 1 {
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          UIView.performWithoutAnimation {
            self.flowLayout.invalidateLayout()
            self.collectionView.layoutIfNeeded()
            if !revealVisibleCell() {
              if indexPath.item < self.rows.count {
                self.collectionView.reloadItems(at: [indexPath])
                self.collectionView.layoutIfNeeded()
                _ = revealVisibleCell()
              }
            }
            self.updateVisibleWallpaperBackdropLayouts()
          }
        }
      }
    } else if revealedMessageId != nil {
      NSLog(
        "[FirstMsg] reveal FALLBACK setRows(sourceRowsPayload) — row not found for msgId=%@ src=%d",
        String((revealedMessageId ?? "").prefix(12)), sourceRowsPayload.count)
      setRows(sourceRowsPayload)
    }
    // Belt & braces: the indexPath-based reveal above can miss the on-screen cell
    // when a rows update landed mid-transition (the cell UIKit has on screen no
    // longer matches indexForMessage's index). Sweep the visible cells and
    // un-ghost any that are still hidden for the revealed message.
    if let revealedMessageId {
      for case let cell as ChatListCell in collectionView.visibleCells
      where cell.isConfiguredGhostHidden && cell.row?.messageId == revealedMessageId {
        NSLog(
          "[FirstMsg] reveal SWEEP un-ghosting stale visible cell msgId=%@",
          String(revealedMessageId.prefix(12)))
        guard let row = cell.row else { continue }
        cell.applyAppearance(appearance)
        cell.configure(
          row: row,
          hiddenMessageId: nil,
          selectionMode: selectionMode,
          selected: row.messageId.map { selectedMessageIds.contains($0) } ?? false,
          agentTurnState: agentTurnBubbleState(for: row)
        )
        bindWallpaperBackdrop(to: cell)
        cell.alpha = 1.0
        cell.contentView.alpha = 1.0
        cell.layer.opacity = 1.0
        cell.contentView.layer.opacity = 1.0
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        cell.updateWallpaperBackdropLayoutIfNeeded()
      }
    }
    flushQueuedAppearanceAfterTransitionIfNeeded()
    if revealCellWasPresent {
      // Common path: the cell above is configured, visible, and pixel-identical
      // under the overlay — drop the overlay in the same frame (zero overlap).
      dropOverlay()
    } else {
      // Async reveal path (cell not realized yet): keep the overlay one tick so
      // the swap never shows a one-frame hole where the bubble disappears.
      DispatchQueue.main.async(execute: dropOverlay)
    }
    if shouldSettleDeferredBottomScroll {
      DispatchQueue.main.async { [weak self] in
        self?.scrollToBottom(animated: true)
      }
    }
    onNativeEvent(["type": "sendTransitionCompleted", "messageId": revealedMessageId ?? ""])
  }

  func setSearchQuery(_ value: String) {
    let nextQuery = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard nextQuery != searchQuery else { return }
    searchQuery = nextQuery
    NSLog(
      "[ChatListView] setSearchQuery active=%@ length=%d chatId=%@",
      searchQuery.isEmpty ? "false" : "true",
      searchQuery.count,
      engineChatId
    )
    setRows(sourceRowsPayload)
  }

  private func filterRowsForSearch(_ input: [[String: Any]]) -> [[String: Any]] {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return input }

    return input.filter { row in
      guard (row["kind"] as? String)?.lowercased() == "message",
        let message = row["message"] as? [String: Any]
      else {
        return false
      }

      let values: [Any?] = [
        message["text"],
        message["plainContent"],
        message["plain_content"],
        message["caption"],
        message["fileName"],
        message["file_name"],
        message["id"],
        row["id"],
        row["messageId"],
      ]
      return values.contains { value in
        guard let value else { return false }
        return String(describing: value).lowercased().contains(query)
      }
    }
  }

  private func emitViewport(force: Bool = false) {
    let contentHeight = collectionView.contentSize.height
    let layoutHeight = collectionView.bounds.height
    let offsetY = collectionView.contentOffset.y
    let distanceFromBottom = max(0.0, contentHeight - (offsetY + layoutHeight))
    let atBottom = distanceFromBottom <= listBottomThreshold

    let now = CACurrentMediaTime()
    if !force, let last = lastViewportPayload {
      let atBottomChanged = atBottom != last.atBottom
      let payloadUnchanged =
        abs(contentHeight - last.contentHeight) <= 0.5
        && abs(layoutHeight - last.layoutHeight) <= 0.5
        && abs(offsetY - last.offsetY) <= 0.5
        && abs(distanceFromBottom - last.distanceFromBottom) <= 0.5
        && !atBottomChanged
      if payloadUnchanged {
        return
      }
      if (now - lastViewportEmitTime) < viewportEmitMinInterval && !atBottomChanged {
        return
      }
    }

    lastViewportEmitTime = now
    lastViewportPayload = (
      contentHeight: contentHeight,
      layoutHeight: layoutHeight,
      offsetY: offsetY,
      distanceFromBottom: distanceFromBottom,
      atBottom: atBottom
    )

    onViewportChanged([
      "contentHeight": contentHeight,
      "layoutHeight": layoutHeight,
      "offsetY": offsetY,
      "distanceFromBottom": distanceFromBottom,
      "atBottom": atBottom,
    ])

    if atBottom {
      sendReadReceiptForNewestIncomingIfNeeded()
    }
  }

  /// Emit a read-receipt for the newest incoming message when the user is actually looking
  /// at the bottom of an open chat. This is the ONLY place this native client tells the peer
  /// "read" — without it the peer's bubble never turns blue (it only ever auto-sends the
  /// *delivery* receipt on message insert). Best-effort + deduped by message id, so it's safe
  /// to call on every viewport tick.
  private func sendReadReceiptForNewestIncomingIfNeeded() {
    guard window != nil else { return }
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return }

    // Newest incoming human message = last non-me `.message` row with a real id.
    guard
      let newest = rows.reversed().first(where: { row in
        row.isMe == false
          && row.kind == .message
          && row.isAgentMessage == false
          && (row.messageId?.isEmpty == false)
      }),
      let messageId = newest.messageId
    else {
      return
    }
    guard messageId != lastReadReceiptSentMessageId else { return }
    lastReadReceiptSentMessageId = messageId

    chatListEngineBindingQueue.async { [weak self] in
      let result = ChatEngine.shared.sendReadReceipt([
        "chatId": chatId,
        "messageId": messageId,
      ])
      // Not actually pushed (chat topic not joined yet — common on first open before the
      // join lands). Drop the dedupe so the next viewport tick retries; otherwise the very
      // first incoming message can get stuck never-read on the peer's side.
      let accepted = (result["accepted"] as? Bool) ?? false
      if !accepted {
        DispatchQueue.main.async {
          guard let self else { return }
          if self.lastReadReceiptSentMessageId == messageId {
            self.lastReadReceiptSentMessageId = nil
          }
        }
      }
    }
  }

  private func applyWallpaperAppearance() {
    wallpaperSnapshotCacheKey = ""
    wallpaperLayer.colors = appearance.wallpaperGradient.map(\.cgColor)
    wallpaperLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    wallpaperLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    wallpaperLayer.opacity = Float(max(0.0, min(1.0, appearance.wallpaperOpacity)))
    wallpaperLayer.isHidden = appearance.backgroundMode == "transparent"

    let canShowPattern =
      appearance.backgroundMode != "transparent"
      && appearance.wallpaperPatternGradient.count >= 2
      && appearance.wallpaperPatternOpacity > 0.001
      && (appearance.wallpaperMaskKey?.isEmpty == false)

    guard
      canShowPattern,
      let maskKey = appearance.wallpaperMaskKey,
      let maskImage = resolvedWallpaperMaskImage(for: maskKey)
    else {
      wallpaperPatternLayer.isHidden = true
      wallpaperPatternLayer.colors = nil
      wallpaperPatternLayer.locations = nil
      wallpaperPatternLayer.opacity = 0.0
      wallpaperPatternMaskLayer.contents = nil
      return
    }

    wallpaperPatternLayer.colors = appearance.wallpaperPatternGradient.map(\.cgColor)
    wallpaperPatternLayer.locations = appearance.wallpaperPatternLocations
    wallpaperPatternLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    wallpaperPatternLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    wallpaperPatternLayer.opacity = Float(max(0.0, min(1.0, appearance.wallpaperPatternOpacity)))
    wallpaperPatternMaskLayer.contents = maskImage
    wallpaperPatternMaskLayer.frame = wallpaperPatternLayer.bounds
    wallpaperPatternLayer.isHidden = false
    applyWallpaperScrollPhase(offsetY: collectionView.contentOffset.y)
  }

  private func applyScrollToneTheme() {
    scrollToneTopView.applyAppearance(appearance)
    scrollToneBottomView.applyAppearance(appearance)
  }

  private func updateScrollToneOverlay(offsetY: CGFloat) {
    guard bounds.width > 0.0, bounds.height > 0.0 else { return }
    applyWallpaperScrollPhase(offsetY: offsetY)

    let topHeight = min(bounds.height, max(100.0, contentPaddingTop + 34.0))
    let bottomHeight = min(bounds.height, max(100.0, contentPaddingBottom + 20.0))

    let topFrame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: topHeight)
    let bottomFrame = CGRect(
      x: 0.0,
      y: max(0.0, bounds.height - bottomHeight),
      width: bounds.width,
      height: bottomHeight
    )
    scrollToneTopView.frame = topFrame
    scrollToneBottomView.frame = bottomFrame
    scrollToneTopView.updateBackdrop(
      snapshot: nil,
      containerSize: .zero,
      sampleRect: topFrame,
      alpha: 0.0,
      blur: false
    )
    scrollToneBottomView.updateBackdrop(
      snapshot: nil,
      containerSize: .zero,
      sampleRect: bottomFrame,
      alpha: 0.0,
      blur: false
    )
    scrollToneOverlay.alpha = 0.0
    scrollToneOverlay.isHidden = true
  }

  private func applyWallpaperScrollPhase(offsetY: CGFloat) {
    guard
      appearance.backgroundMode != "transparent",
      appearance.wallpaperPatternGradient.count >= 2,
      appearance.wallpaperPatternOpacity > 0.001,
      !wallpaperPatternLayer.isHidden
    else {
      return
    }

    let colors = appearance.wallpaperPatternGradient
    let triggerDistance = max(360.0, min(620.0, bounds.height * 0.72))
    let linearProgress = max(0.0, min(1.0, offsetY / triggerDistance))
    let easedProgress = linearProgress * linearProgress * (3.0 - (2.0 * linearProgress))
    let progress = easedProgress * 0.45
    let phasedColors: [UIColor] = colors.enumerated().map { index, color in
      let next = colors[(index + 1) % colors.count]
      return chatListInterpolatedColor(from: color, to: next, progress: progress)
    }
    let locations: [NSNumber] = {
      guard let configured = appearance.wallpaperPatternLocations,
        configured.count == phasedColors.count
      else {
        return chatListEvenGradientLocations(count: phasedColors.count)
      }
      return configured
    }()
    let phaseBucket = Int((progress * 18.0).rounded())
    if phaseBucket != wallpaperScrollPhaseBucket {
      wallpaperScrollPhaseBucket = phaseBucket
      wallpaperSnapshotCacheKey = ""
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    wallpaperPatternLayer.colors = phasedColors.map(\.cgColor)
    wallpaperPatternLayer.locations = locations
    wallpaperPatternLayer.startPoint = CGPoint(x: -0.14 + (0.08 * progress), y: -0.05)
    wallpaperPatternLayer.endPoint = CGPoint(x: 1.10 - (0.06 * progress), y: 1.06)
    CATransaction.commit()
  }

  private func refreshWallpaperSnapshotIfNeeded(force: Bool = false) {
    guard
      appearance.backgroundMode != "transparent",
      bounds.width > 1.0,
      bounds.height > 1.0,
      !wallpaperLayer.isHidden
    else {
      wallpaperSnapshot = nil
      wallpaperSnapshotSize = .zero
      wallpaperSnapshotCacheKey = ""
      return
    }

    let scale = max(window?.screen.scale ?? UIScreen.main.scale, 1.0)
    let cacheKey =
      "\(appearance.visualKey)|phase:\(wallpaperScrollPhaseBucket)|\(Int(bounds.width.rounded() * scale))x\(Int(bounds.height.rounded() * scale))"
    if !force, wallpaperSnapshotCacheKey == cacheKey, wallpaperSnapshot != nil {
      return
    }

    if let cached = Self.wallpaperSnapshotCache[cacheKey] {
      wallpaperSnapshot = cached
      wallpaperSnapshotSize = bounds.size
      wallpaperSnapshotCacheKey = cacheKey
      return
    }

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = scale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
    let image = renderer.image { context in
      wallpaperLayer.render(in: context.cgContext)
      if !wallpaperPatternLayer.isHidden {
        wallpaperPatternLayer.render(in: context.cgContext)
      }
    }
    guard let cgImage = image.cgImage else { return }
    Self.wallpaperSnapshotCache[cacheKey] = cgImage
    wallpaperSnapshot = cgImage
    wallpaperSnapshotSize = bounds.size
    wallpaperSnapshotCacheKey = cacheKey
  }

  private func bindWallpaperBackdrop(to cell: ChatListCell) {
    cell.applyWallpaperBackdrop(
      snapshot: wallpaperSnapshot,
      containerSize: wallpaperSnapshotSize,
      coordinateView: self
    )
  }

  private func updateVisibleWallpaperBackdropLayouts() {
    for case let cell as ChatListCell in collectionView.visibleCells {
      bindWallpaperBackdrop(to: cell)
      cell.updateWallpaperBackdropLayoutIfNeeded()
    }
  }

  private func resolvedWallpaperMaskImage(for key: String) -> CGImage? {
    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedKey.isEmpty else { return nil }
    if let cached = Self.wallpaperMaskImageCache[normalizedKey] {
      return cached
    }
    guard let baseName = Self.wallpaperMaskBaseName(for: normalizedKey) else {
      return nil
    }

    let bundles = [Bundle.main, Bundle(for: ChatListView.self)]
    for bundle in bundles {
      if let image = UIImage(named: baseName, in: bundle, compatibleWith: nil)?.cgImage {
        Self.wallpaperMaskImageCache[normalizedKey] = image
        return image
      }
      if let image = UIImage(named: "\(baseName).png", in: bundle, compatibleWith: nil)?.cgImage {
        Self.wallpaperMaskImageCache[normalizedKey] = image
        return image
      }
      if let path = bundle.path(forResource: baseName, ofType: "png"),
        let image = UIImage(contentsOfFile: path)?.cgImage
      {
        Self.wallpaperMaskImageCache[normalizedKey] = image
        return image
      }
    }
    return nil
  }

  private static func wallpaperMaskBaseName(for key: String) -> String? {
    switch key {
    case "doodles", "hearts":
      return "doodle_transparent"
    case "music":
      return "music_transparent"
    case "music2":
      return "music2_transparent"
    case "food":
      return "food_transparent"
    case "animals":
      return "animals_transparent"
    default:
      return nil
    }
  }

  // MARK: - Debug Animation Panel

  func setDebugAnimationPanel(_ enabled: Bool) {
    debugPanelVisible = enabled
  }

  private func setupDebugPanel() {
    let panel = UIView()
    panel.backgroundColor = UIColor(white: 0, alpha: 0.85)
    panel.layer.cornerRadius = 16
    panel.clipsToBounds = true
    panel.isHidden = true

    let titleLabel = UILabel()
    titleLabel.text = "Animation Debug"
    titleLabel.font = .boldSystemFont(ofSize: 14)
    titleLabel.textColor = .white
    titleLabel.tag = 300
    panel.addSubview(titleLabel)

    let durationLabel = UILabel()
    durationLabel.text = "Duration: 0.40s"
    durationLabel.font = .systemFont(ofSize: 12)
    durationLabel.textColor = .white
    panel.addSubview(durationLabel)
    debugDurationLabel = durationLabel

    let durationSlider = UISlider()
    durationSlider.minimumValue = 0.05
    durationSlider.maximumValue = 1.5
    durationSlider.value = 0.4
    durationSlider.tintColor = .systemBlue
    durationSlider.addTarget(self, action: #selector(debugDurationChanged(_:)), for: .valueChanged)
    durationSlider.tag = 301
    panel.addSubview(durationSlider)

    let offsetLabel = UILabel()
    offsetLabel.text = "Offset: 20px"
    offsetLabel.font = .systemFont(ofSize: 12)
    offsetLabel.textColor = .white
    panel.addSubview(offsetLabel)
    debugOffsetLabel = offsetLabel

    let offsetSlider = UISlider()
    offsetSlider.minimumValue = 0
    offsetSlider.maximumValue = 100
    offsetSlider.value = 20
    offsetSlider.tintColor = .systemOrange
    offsetSlider.addTarget(self, action: #selector(debugOffsetChanged(_:)), for: .valueChanged)
    offsetSlider.tag = 302
    panel.addSubview(offsetSlider)

    let statsLabel = UILabel()
    statsLabel.text = "Waiting for batch…"
    statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    statsLabel.textColor = UIColor(white: 1, alpha: 0.7)
    statsLabel.numberOfLines = 2
    panel.addSubview(statsLabel)
    debugStatsLabel = statsLabel

    addSubview(panel)
    debugPanel = panel
  }

  private func layoutDebugPanel() {
    guard let panel = debugPanel, !panel.isHidden else { return }
    let w = bounds.width - 32
    panel.frame = CGRect(x: 16, y: safeAreaInsets.top + 8, width: w, height: 180)

    let pad: CGFloat = 12
    let labelH: CGFloat = 18
    let sliderH: CGFloat = 30
    let innerW = w - pad * 2
    var cy: CGFloat = pad

    if let title = panel.viewWithTag(300) {
      title.frame = CGRect(x: pad, y: cy, width: innerW, height: labelH)
      cy += labelH + 4
    }
    debugDurationLabel?.frame = CGRect(x: pad, y: cy, width: innerW, height: labelH)
    cy += labelH
    if let slider = panel.viewWithTag(301) {
      slider.frame = CGRect(x: pad, y: cy, width: innerW, height: sliderH)
      cy += sliderH + 2
    }
    debugOffsetLabel?.frame = CGRect(x: pad, y: cy, width: innerW, height: labelH)
    cy += labelH
    if let slider = panel.viewWithTag(302) {
      slider.frame = CGRect(x: pad, y: cy, width: innerW, height: sliderH)
      cy += sliderH + 4
    }
    debugStatsLabel?.frame = CGRect(x: pad, y: cy, width: innerW, height: 36)

    bringSubviewToFront(panel)
  }

  @objc private func debugDurationChanged(_ sender: UISlider) {
    debugAnimDuration = CGFloat(sender.value)
    debugDurationLabel?.text = String(format: "Duration: %.2fs", sender.value)
  }

  @objc private func debugOffsetChanged(_ sender: UISlider) {
    debugAnimSlideOffset = CGFloat(sender.value)
    debugOffsetLabel?.text = String(format: "Offset: %.0fpx", sender.value)
  }

  private func updateDebugStats(
    shifted: Int, newSlide: Int, maxDelta: CGFloat, scrollDelta: CGFloat
  ) {
    debugStatsLabel?.text = String(
      format: "shifted:%d new:%d maxΔ:%.0f scrollΔ:%.0f\ndur:%.2fs off:%.0fpx",
      shifted, newSlide, maxDelta, scrollDelta, debugAnimDuration, debugAnimSlideOffset)
  }

  // MARK: - Native Input Bar

  func setInputBarEnabled(_ enabled: Bool) {
    guard enabled != inputBarEnabled else { return }
    inputBarEnabled = enabled

    if enabled {
      if abs(contentPaddingBottom - sectionBottomInset) > 0.5 {
        contentPaddingBottom = sectionBottomInset
        updateBottomAnchorInset()
      }
      // The glass agent composer is only for the Claude/Codex bridge DMs. The default
      // "Vibe AI" agent (agentChatMode without a bridge provider) and every normal DM use
      // the standard ChatInputBar instead.
      let bridgeProvider = currentBridgeProvider?.lowercased()
      let useAgentComposer = bridgeProvider == "claude" || bridgeProvider == "codex"
      if useAgentComposer {
        let bar = VibeComposerView()
        bar.placeholder = inputBarPlaceholder
        bar.applyAppearance(appearance.isDark ? VibeAgentKitChatAppearance.fallback : VibeAgentKitChatAppearance.lightFallback)
        bar.provider = currentBridgeProvider ?? "codex"
        bar.onSend = { [weak self] text, options in
            self?.inputBarDidSend(text: text)
        }
        bar.onAttach = { [weak self] in
            self?.inputBarDidTapAttachment()
        }
        bar.onOpenToolsSheet = { [weak self] vc in
            guard let self, let presenter = self.topPresentingViewController() else { return }
            presenter.present(vc, animated: true)
        }
        bar.onHeightChanged = { [weak self] height in
            self?.inputBarHeightDidChange()
        }
        // While a bridge task is live the composer's trailing control becomes STOP — tapping
        // it cancels the running run. Without this wiring (the agent surface uses this
        // VibeComposerView, NOT `inputBar`) the STOP button never appeared and never fired.
        bar.onStop = { [weak self] in
            self?.agentComposerStopActiveTask()
        }
        agentComposerView = bar
        addSubview(bar)
        // Seed the trailing control immediately so a composer created mid-run shows STOP.
        bar.setTaskActive(agentComposerHasLiveTask())

        inputBar?.removeFromSuperview()
        inputBar = nil
      } else {
        let bar = ChatInputBar()
        bar.delegate = self
        bar.placeholder = inputBarPlaceholder
        bar.applyAppearance(appearance)
        bar.setAgentStreaming(agentStreaming)
        // The default "Vibe AI" agent still wants ChatInputBar's dormant agent-control
        // machinery (repo chip / slash menu / STOP); normal DMs don't.
        bar.setAgentControlMode(agentChatMode || currentBridgeProvider != nil)
        inputBar = bar
        addSubview(bar)

        agentComposerView?.removeFromSuperview()
        agentComposerView = nil
      }
      updateAgentBridgeControlTitle()

      positionTransitionOverlayHost()
      VibeDebugLog.log("[ChatListView] native input bar ENABLED")
    } else {
      inputBar?.removeFromSuperview()
      inputBar = nil
      agentComposerView?.removeFromSuperview()
      agentComposerView = nil
      positionTransitionOverlayHost()
      if abs(contentPaddingBottom - requestedContentPaddingBottom) > 0.5 {
        contentPaddingBottom = requestedContentPaddingBottom
        updateBottomAnchorInset()
      }
      VibeDebugLog.log("[ChatListView] native input bar DISABLED")
    }
    setNeedsLayout()
  }

  func setInputPlaceholder(_ value: String) {
    inputBarPlaceholder = value
    inputBar?.placeholder = value
  }

  func setComposerText(_ value: String, focus: Bool = true) {
    inputBar?.setComposerText(value, focus: focus)
  }

  func setNativeSendEnabled(_ enabled: Bool) {
    guard enabled != nativeSendEnabled else { return }
    nativeSendEnabled = enabled
    if !enabled {
      nativeOutgoingRowsById.removeAll()
      nativeOutgoingOrder.removeAll()
    }
    setRows(sourceRowsPayload)
  }

  func setAgentChatMode(_ enabled: Bool) {
    guard agentChatMode != enabled else { return }
    agentChatMode = enabled
    inputBar?.setAgentControlMode(enabled)
    updateAgentBridgeControlTitle()
    updateBottomAnchorInset()
    if enabled {
      performInternalScrollAdjustment {
        collectionView.setContentOffset(.zero, animated: false)
      }
      previousOffsetY = collectionView.contentOffset.y
    } else {
      pendingAgentPushToTop = false
      clearAgentPushToTopSpacer()
    }
  }

  /// True when this DM agent surface has a live/streaming turn — used to force the
  /// composer's trailing control to STOP. Mirrors the full-page view's `isLive` check.
  private func agentComposerHasLiveTask() -> Bool {
    guard agentChatMode || currentBridgeProvider != nil else { return false }
    if agentStreaming { return true }
    return rows.contains { bridgeRowIsLive($0) }
  }

  /// Composer STOP tapped on the DM agent surface: cancel the running bridge run. Mirrors
  /// the full-page runtime view's `stopActiveTask` (chatId + provider + the live task id).
  private func agentComposerStopActiveTask() {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else {
      NSLog("[ChatListView] agentComposerStop skipped — no chatId")
      return
    }
    let provider = currentBridgeProvider ?? "codex"
    let taskId = rows.first { bridgeRowIsLive($0) }?.agentRuntime?.taskId
    var payload: [String: Any] = [
      "chatId": chatId,
      "provider": provider,
      "action": "cancel",
    ]
    if let taskId, !taskId.isEmpty { payload["taskId"] = taskId }
    NSLog("[ChatListView] agentComposerStop chat=%@ provider=%@ taskId=%@", chatId, provider, taskId ?? "nil")
    _ = ChatEngine.shared.sendAgentBridgeControl(payload)
  }

  func setAgentStreaming(_ streaming: Bool) {
    guard agentStreaming != streaming else { return }
    agentStreaming = streaming
    inputBar?.setAgentStreaming(streaming)
    agentComposerView?.setTaskActive(streaming || agentComposerHasLiveTask())
    // Note: we deliberately do NOT clear the push-to-top spacer when the answer
    // finishes. Clearing it would drop `maxOffset` below the pinned offset for a
    // short answer, and the collection view would clamp the content downward —
    // i.e. the message would "shift to the bottom" right as streaming ends. The
    // spacer is sized so `maxOffset == pinnedOffset` (see `agentReservedSpacer`),
    // so leaving it keeps the turn pinned; the next send recomputes it.
  }

  /// Agent send: scroll the just-sent user message to the top and reserve room
  /// below for the streaming answer (ChatGPT-style). No morph-from-input — the
  /// list simply pushes up. The reserve is sized so the pinned offset is exactly
  /// the max offset, so the message holds at the top on its own without any
  /// per-chunk re-pinning (which previously locked scrolling).
  private func performAgentPushToTop(animated: Bool) {
    // New send: re-arm the pin (user is no longer detached from a prior turn).
    agentPinUserDetached = false
    _ = animated  // always pin instantly so a streaming chunk can't interrupt it
    applyAgentPin(forceOffset: true)
  }

  /// Space reserved below the current turn so the user message can sit at the top
  /// with the answer's room below. Sized so `contentSize + reserve - bounds ==
  /// userMinY - paddingTop`, i.e. the max scroll offset equals the pinned offset
  /// exactly — the message holds at the top, and because the reserve is bounded by
  /// what's *already* below the user message it collapses to zero as the answer
  /// fills the viewport (no fixed empty gap, no overscroll into dead space).
  private func agentReservedSpacer(forUserMinY userMinY: CGFloat) -> CGFloat {
    let contentBelowUser = max(0.0, collectionView.contentSize.height - userMinY)
    let reserve = collectionView.bounds.height - contentPaddingTop - contentBelowUser
    return max(0.0, reserve)
  }

  /// Keep the latest user message pinned under the top inset with room reserved
  /// below for the answer. The scroll OFFSET is moved only on the deliberate send
  /// pin (`forceOffset: true`); streaming chunks pass `forceOffset: false` so they
  /// merely re-size the reserved room. The question then holds its place on its own
  /// because the answer grows *below* the offset — re-asserting the offset per
  /// chunk is what fought the user and caused the force-scroll. The reserve always
  /// tracks the answer (even after the user takes over scrolling) so it collapses
  /// to zero as the answer fills the viewport, leaving no dead space to scroll into.
  private func applyAgentPin(forceOffset: Bool) {
    guard agentChatMode || currentBridgeProvider != nil else { return }
    guard let userIndex = rows.lastIndex(where: { $0.kind == .message && $0.isMe }) else {
      clearAgentPushToTopSpacer()
      return
    }

    let indexPath = IndexPath(item: userIndex, section: 0)
    collectionView.layoutIfNeeded()
    guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else { return }
    let target = agentReservedSpacer(forUserMinY: attrs.frame.minY)

    // ── Deliberate send pin ──────────────────────────────────────────────────
    // This is the ONLY place the agent surface ever moves the scroll offset, and
    // it runs UNCONDITIONALLY (no interacting / detached guards in front of it).
    // A previous flick can leave the list `isDecelerating` at the exact moment the
    // user taps send; guarding here would swallow the pin entirely — that was the
    // "no push-to-top on send" bug. Reserve room, then put the question at the top.
    if forceOffset {
      agentPinUserDetached = false
      agentPushToTopSpacer = target
      if collectionView.contentInset.bottom != target {
        collectionView.contentInset.bottom = target
        collectionView.layoutIfNeeded()
      }
      let targetOffsetY = pixelAlignedValue(max(0.0, attrs.frame.minY - contentPaddingTop))
      performInternalScrollAdjustment {
        collectionView.setContentOffset(CGPoint(x: 0.0, y: targetOffsetY), animated: false)
      }
      previousOffsetY = collectionView.contentOffset.y
      // We own the scroll position for this turn — keep the generic "stick to
      // bottom" auto-scroll (layoutSubviews / resize) from undoing the pin.
      shouldAutoScroll = false
      return
    }

    // ── Streaming frame ──────────────────────────────────────────────────────
    // NEVER move the offset here. The user owns scrolling the instant they take it
    // over (detached) or while they are physically touching / flinging the list —
    // in those cases do absolutely nothing so we never fight their drag and they
    // can always reach the top. Otherwise only ever SHRINK the reserved room as the
    // answer grows so the dead space below collapses; growing the reserve or moving
    // the offset is what force-scrolled before. Shrinking the bottom inset while the
    // question is pinned near the top does not move any visible content.
    if agentPinUserDetached {
      return
    }
    if collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating {
      return
    }
    if target < agentPushToTopSpacer - 0.5 {
      agentPushToTopSpacer = target
      collectionView.contentInset.bottom = target
    }
  }

  private func clearAgentPushToTopSpacer() {
    agentPinUserDetached = false
    guard agentPushToTopSpacer != 0 || collectionView.contentInset.bottom != 0 else { return }
    agentPushToTopSpacer = 0
    collectionView.contentInset.bottom = 0
  }

  // MARK: - Keyboard Tracking

  @objc private func keyboardWillChangeFrame(_ notification: Notification) {
    guard inputBarEnabled else { return }
    guard let info = notification.userInfo,
      let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else { return }

    let endFrameInView = convert(endFrame, from: nil)
    let intersection = bounds.intersection(endFrameInView)
    let kbHeight = max(0, intersection.height)
    let duration =
      (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    let curveRaw =
      (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
    let options = UIView.AnimationOptions(rawValue: curveRaw << 16)

    keyboardHeight = kbHeight
    inputBar?.keyboardHeightForPanels = kbHeight
    inputBar?.keyboardProgress = kbHeight > 0 ? 1.0 : 0.0
    agentComposerView?.setKeyboardPaddingProgress(
      kbHeight > 0 ? 1.0 : 0.0,
      animation: (duration, options)
    )
    UIView.animate(withDuration: duration, delay: 0, options: options) { [weak self] in
      self?.layoutInputBarAndInset()
      self?.inputBar?.layoutIfNeeded()
      self?.agentComposerView?.layoutIfNeeded()
    }
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    guard inputBarEnabled else { return }
    guard let info = notification.userInfo else { return }
    let duration =
      (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    let curveRaw =
      (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
    let options = UIView.AnimationOptions(rawValue: curveRaw << 16)

    keyboardHeight = 0
    inputBar?.keyboardHeightForPanels = 0
    inputBar?.keyboardProgress = 0.0
    agentComposerView?.setKeyboardPaddingProgress(
      0.0,
      animation: (duration, options)
    )
    UIView.animate(withDuration: duration, delay: 0, options: options) { [weak self] in
      self?.layoutInputBarAndInset()
      self?.inputBar?.layoutIfNeeded()
      self?.agentComposerView?.layoutIfNeeded()
    }
  }

  private func layoutJumpToBottomButton() {
    guard jumpToBottomButton.superview != nil else { return }
    let activeBarFrame = agentComposerView?.frame ?? inputBar?.frame ?? .zero
    let buttonW: CGFloat = 38.0
    let buttonH: CGFloat = 38.0
    let buttonX = (bounds.width - buttonW) / 2.0
    let buttonY = (activeBarFrame != .zero ? activeBarFrame.minY : bounds.height) - buttonH - 12.0
    jumpToBottomButton.frame = CGRect(x: buttonX, y: buttonY, width: buttonW, height: buttonH)
  }

  private func layoutInputBarAndInset() {
    if let agentBar = agentComposerView {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        let distanceBeforeInsetChange = currentDistanceFromBottom()
        let wasNearBottom = distanceBeforeInsetChange <= listBottomThreshold

        let preferredHeight = agentBar.preferredHeight
        let effectiveKeyboardHeight = keyboardHeight
        let safeBottom = keyboardHeight > 0 ? 0 : safeAreaInsets.bottom

        let finalHeight = preferredHeight
        let finalY = h - effectiveKeyboardHeight - finalHeight

        agentBar.frame = CGRect(x: 0, y: finalY, width: w, height: finalHeight)
        agentBar.alpha = 1
        agentBar.isUserInteractionEnabled = true
        agentBar.layoutIfNeeded()

        let desiredBottomPadding = effectiveKeyboardHeight + finalHeight
        if abs(contentPaddingBottom - desiredBottomPadding) > 0.5 {
          contentPaddingBottom = desiredBottomPadding
          updateBottomAnchorInset()
          if wasNearBottom || shouldAutoScroll {
            scrollToBottom(animated: false, force: true)
          } else {
            restoreStationaryDistance(distanceBeforeInsetChange)
          }
        }
        positionTransitionOverlayHost()
        layoutActivityOverlay()
        layoutJumpToBottomButton()
        return
    }

    guard let bar = inputBar else { return }
    let w = bounds.width
    let h = bounds.height
    guard w > 0, h > 0 else { return }
    let distanceBeforeInsetChange = currentDistanceFromBottom()
    let wasNearBottom = distanceBeforeInsetChange <= listBottomThreshold

    let effectiveKeyboardHeight: CGFloat
    let safeBottom: CGFloat
    if bar.isGifPanelPresented {
      effectiveKeyboardHeight = 0
      safeBottom = 0
    } else {
      effectiveKeyboardHeight = keyboardHeight
      safeBottom = keyboardHeight > 0 ? 0 : safeAreaInsets.bottom
    }
    bar.bottomSafeAreaInset = safeBottom
    // Size the bar by updating its width (avoiding y-origin jumps during UIView animations)
    bar.frame = CGRect(x: 0, y: bar.frame.minY, width: w, height: bar.frame.height)
    bar.layoutIfNeeded()
    let barH = bar.barHeight

    // Position at bottom, above keyboard. When the GIF panel is open, `barH`
    // already includes both the composer and the panel.
    let barY = h - barH - effectiveKeyboardHeight
    bar.frame = CGRect(x: 0, y: barY, width: w, height: barH)
    bar.alpha = 1
    bar.isUserInteractionEnabled = true

    // Update collection view bottom inset
    let totalBottomPadding = barH + effectiveKeyboardHeight

    let baseInsets = flowLayout.sectionInset
    if abs(baseInsets.bottom - totalBottomPadding) > 0.5 {
      contentPaddingBottom = totalBottomPadding
      updateBottomAnchorInset()
      if wasNearBottom {
        scrollToBottom(animated: false)
      } else {
        restoreStationaryDistance(distanceBeforeInsetChange)
      }
      emitViewport(force: true)
    }

    // Keep transition overlay host above messages but behind the composer.
    positionTransitionOverlayHost()
    layoutActivityOverlay()
    layoutJumpToBottomButton()
  }

  // MARK: - Native Send (synchronous, no bridge delay)

  private func agentBridgeMetadataForOutgoing(
    text: String,
    mentionedAgentUsername: String?
  ) -> [String: Any] {
    let provider = resolvedBridgeProviderForOutgoing(
      text: text,
      mentionedAgentUsername: mentionedAgentUsername
    )
    // A plain group message (no @mention, not an agent DM) still fans out to the
    // group's Claude/Codex members server-side — so it must carry the selected repo
    // too, otherwise the agents run with no working directory (the repo picked in the
    // group profile was never reaching them). Detect that group-with-agents case.
    let isGroupAgentSend = provider == nil && groupHasBridgeAgents()
    guard provider != nil || isGroupAgentSend else {
      return [:]
    }
    guard let repository = AgentBridgeSelectionStore.selectedRepository() else {
      return [:]
    }

    // Repo + work mode are provider-agnostic and apply to whichever worker runs.
    var metadata: [String: Any] = [
      "agentBridgeRepoId": repository.id,
      "agentBridgeRepoName": repository.name,
      "agentBridgeRepoPath": repository.path,
      "agentBridgeCwd": repository.cwd,
      "agentBridgeWorkMode": AgentBridgeSelectionStore.selectedWorkMode().rawValue,
    ]

    guard let provider else {
      // Group fan-out to both agents: no single provider and no resume target (each
      // parallel agent starts its own fresh session, matching the new-task-per-message
      // default). Model choices ARE per-provider — ship them as a map the server
      // resolves per worker at dispatch (see chat_channel.ex resolve_provider_model).
      var models: [String: String] = [:]
      var advisors: [String: String] = [:]
      for agentProvider in ["claude", "codex"] {
        let options = AgentBridgeSelectionStore.selectedRunOptions(provider: agentProvider)
        if let model = options.model {
          models[agentProvider] = model
        }
        if let advisor = options.advisor {
          advisors[agentProvider] = advisor
        }
      }
      if !models.isEmpty {
        metadata["agentBridgeModels"] = models
      }
      if !advisors.isEmpty {
        metadata["agentBridgeAdvisors"] = advisors
      }
      return metadata
    }

    metadata["agentBridgeProvider"] = provider
    metadata.merge(
      AgentBridgeSelectionStore.selectedRunOptions(provider: provider).payload(provider: provider)
    ) { _, new in new }
    // Resume target for this send. Priority:
    //  1. A History session the user explicitly opened (`bridgeLoadedSessionId`).
    //  2. Otherwise the session the visible conversation already belongs to
    //     (`activeBridgeSessionId`, adopted from the last finished agent turn) — so a
    //     follow-up like "apply fix" continues the SAME CLI session instead of spawning
    //     a new one that lands in a different history.
    // A brand-new chat (no History pick, no completed turn) resolves to nil → the bridge
    // starts a fresh session and the message is never filed under a stale one.
    //  3. The session the ENGINE is still live-tailing for this chat (a History session
    //     opened before the view was closed/reopened, or a still-running task). The two
    //     per-instance ids above die with the view instance, so without this fallback a
    //     reopen + send silently spawned a brand-new session even though the open
    //     conversation was still on screen.
    let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let resumeSessionId =
      bridgeLoadedSessionId ?? activeBridgeSessionId
      ?? ChatEngine.shared.liveBridgeSessionId(chatId: chatKey)
    if let resumeSessionId,
      !resumeSessionId.isEmpty,
      !resumeSessionId.hasPrefix("running:")
    {
      metadata["agentBridgeResumeSessionId"] = resumeSessionId
    }
    NSLog(
      "[AgentRoute] outgoing resume id=%@ (loaded=%@ adopted=%@ engineLive=%@)",
      resumeSessionId ?? "<new-session>",
      bridgeLoadedSessionId ?? "-", activeBridgeSessionId ?? "-",
      ChatEngine.shared.liveBridgeSessionId(chatId: chatKey) ?? "-")
    return metadata
  }

  /// True when the current chat is a group that has Claude/Codex as members (their
  /// group-sender entries carry a resolved bridge `provider`). Used so a plain group
  /// message still ships the selected repo to the agents.
  private func groupHasBridgeAgents() -> Bool {
    guard isGroupOrChannel else { return false }
    return groupSenderDirectory.values.contains { $0.provider != nil }
  }

  private func resolvedBridgeProviderForOutgoing(
    text: String,
    mentionedAgentUsername: String?
  ) -> String? {
    let peer = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if peer == "11111111-1111-1111-1111-111111111111" { return "claude" }
    if peer == "22222222-2222-2222-2222-222222222222" { return "codex" }

    let mention =
      mentionedAgentUsername?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if mention == "claude" || mention == "codex" {
      return mention
    }

    if text.range(of: "(^|\\s)@claude\\b", options: [.regularExpression, .caseInsensitive]) != nil {
      return "claude"
    }
    if text.range(of: "(^|\\s)@codex\\b", options: [.regularExpression, .caseInsensitive]) != nil {
      return "codex"
    }
    return nil
  }

  private var currentBridgeProvider: String? {
    if let explicitBridgeProvider { return explicitBridgeProvider }
    let peer = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if peer == "11111111-1111-1111-1111-111111111111" { return "claude" }
    if peer == "22222222-2222-2222-2222-222222222222" { return "codex" }
    return nil
  }

  func setBridgeProvider(_ provider: String) {
    let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let next = normalized.isEmpty ? nil : normalized
    guard explicitBridgeProvider != next else { return }
    explicitBridgeProvider = next
    VibeDebugLog.log("[AgentRoute] ChatListView setBridgeProvider=%@", next ?? "nil")
    updateAgentBridgeControlTitle()
    inputBar?.setAgentControlMode(agentChatMode || currentBridgeProvider != nil)
    scheduleBridgeAgentPresenceRefresh()
  }

  func setAvatarUri(_ value: String?) {
    let next = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard avatarUri != next else { return }
    avatarUri = next
    presentedBridgeAgentVC?.avatarURI = next.isEmpty ? nil : next
  }

  private func updateAgentBridgeControlTitle() {
    // Bridge-agent DMs (Claude/Codex) drive the repo chip + agent menu regardless of the
    // legacy `agentChatMode` surface. "Open" is the fallback for the Vibe AI panel.
    guard let provider = currentBridgeProvider else {
      inputBar?.setAgentControlMenu(nil)
      inputBar?.setSlashCommandMenu(nil)
      inputBar?.setAgentControlTitle("Open")
      return
    }
    let repoName =
      AgentBridgeSelectionStore.selectedRepository()?.name
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    inputBar?.setAgentControlRepoTitle(repoName)
    inputBar?.setAgentControlMenu(agentControlMenu(provider: provider))
    inputBar?.setSlashCommandMenu(slashCommandMenu(provider: provider))
  }

  /// Build the "/" command menu for the input bar's slash button, grouped Info / Tasks /
  /// Options. Selecting an item drops "/name " into the composer so the user can add args
  /// and send (bridge info commands like /usage are answered in the glass overlay; task
  /// commands run as agent turns). Provider-aware: Codex's desktop-only ones are labelled.
  private func slashCommandMenu(provider: String) -> UIMenu {
    let isCodex = provider.lowercased().contains("codex")
    // (name, subtitle)
    let info: [(String, String)] = [
      ("usage", "Subscription limits + token usage"),
      ("status", "Account, model, remaining usage"),
      ("commands", "List available commands"),
      ("model", "Show / switch model"),
      ("compact", "Summarize to free context"),
      ("doctor", "Run the CLI health check"),
    ]
    let claudeTasks: [(String, String)] = [
      ("code-review", "Review the diff for bugs"),
      ("simplify", "Cleanup-only review"),
      ("security-review", "Scan changes for security issues"),
      ("debug", "Investigate a failure"),
      ("init", "Set up project memory"),
    ]
    let codexTasks: [(String, String)] = [
      ("review", "Review your working tree · desktop only"),
      ("init", "Set up project memory · desktop only"),
    ]
    let options: [(String, String)] = [
      ("plan", "Plan mode: research, don't edit"),
      (isCodex ? "fast" : "reasoning", isCodex ? "Faster, lighter responses" : "Adjust thinking depth"),
    ]
    func actions(_ items: [(String, String)]) -> [UIMenuElement] {
      items.map { item in
        UIAction(title: "/\(item.0)", subtitle: item.1) { [weak self] _ in
          self?.inputBar?.insertSlashCommand(item.0)
        }
      }
    }
    let infoMenu = UIMenu(title: "Info", options: .displayInline, children: actions(info))
    let taskMenu = UIMenu(
      title: "Tasks", options: .displayInline,
      children: actions(isCodex ? codexTasks : claudeTasks))
    let optionMenu = UIMenu(title: "Options", options: .displayInline, children: actions(options))
    return UIMenu(title: "Slash commands", children: [infoMenu, taskMenu, optionMenu])
  }

  /// Build the agent-control chip menu for a Claude/Codex DM: switch repository, set the
  /// permission (work mode), open the run Report, or open the full History surface. These
  /// are distinct items so History no longer bundles permission/report.
  private func agentControlMenu(provider: String) -> UIMenu {
    let repos = AgentPairingService.lastStatusSnapshot?.repositories ?? []
    let selectedRepo = AgentBridgeSelectionStore.selectedRepository()
    var repoChildren: [UIMenuElement] = repos.map { repo in
      UIAction(
        title: repo.name,
        subtitle: repo.path,
        image: UIImage(systemName: repo.isGitRepository ? "shippingbox" : "folder"),
        state: (repo.id == selectedRepo?.id || repo.cwd == selectedRepo?.cwd) ? .on : .off
      ) { [weak self] _ in
        AgentBridgeSelectionStore.select(repo)
        self?.updateAgentBridgeControlTitle()
      }
    }
    repoChildren.append(
      UIAction(title: "Pick repository…", image: UIImage(systemName: "folder.badge.plus")) {
        [weak self] _ in
        self?.onNativeEvent(["type": "openAgentPanel", "provider": provider])
      })
    let repoMenu = UIMenu(title: "Repository", options: .displayInline, children: repoChildren)

    let currentMode = AgentBridgeSelectionStore.selectedWorkMode()
    let permissionChildren = AgentBridgeWorkMode.allCases.map { mode in
      UIAction(
        title: mode.title,
        subtitle: mode.subtitle,
        image: UIImage(systemName: mode.icon),
        state: mode == currentMode ? .on : .off
      ) { _ in
        AgentBridgeSelectionStore.setWorkMode(mode)
      }
    }
    let permissionMenu = UIMenu(
      title: "Permission",
      subtitle: currentMode.title,
      image: UIImage(systemName: "hand.raised"),
      children: permissionChildren)

    let reportAction = UIAction(
      title: "Report", image: UIImage(systemName: "doc.text.magnifyingglass")
    ) { [weak self] _ in
      self?.presentLatestAgentReport()
    }
    let engineAction = UIAction(
      title: "Engine view", image: UIImage(systemName: "rectangle.stack")
    ) { [weak self] _ in
      self?.bridgeAgentManuallyShown = true
      self?.presentBridgeAgentConversation(provider: provider, surfaceMode: .transcript)
    }
    let visualAction = UIAction(
      title: "Visual workspace", image: UIImage(systemName: "rectangle.3.group.bubble.left")
    ) { [weak self] _ in
      self?.bridgeAgentManuallyShown = true
      self?.presentBridgeAgentConversation(provider: provider, surfaceMode: .visual)
    }
    let historyAction = UIAction(
      title: "History", image: UIImage(systemName: "clock.arrow.circlepath")
    ) { [weak self] _ in
      self?.presentBridgeHistorySurface(provider: provider)
    }
    return UIMenu(children: [repoMenu, permissionMenu, engineAction, visualAction, reportAction, historyAction])
  }

  /// Report: open the most recent run's files-changed / diff report (its runtime card).
  private func presentLatestAgentReport() {
    guard
      let index = rows.lastIndex(where: { $0.agentRuntime != nil }),
      let runtime = rows[index].agentRuntime
    else { return }
    presentAgentRuntimeTask(row: rows[index], runtime: runtime)
  }

  /// History: full-screen slide-in list of this agent's past/running conversations
  /// (reusing the profile's `AgentBridgeHistoryInlineView`). Picking one loads it into
  /// THIS chat view (not the agent view) — see `loadBridgeSessionIntoChat`.
  func presentBridgeHistorySurface(provider: String) {
    guard let presenter = topPresentingViewController() else { return }
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let status = AgentPairingService.lastStatusSnapshot
    let host = UIHostingController(
      rootView: AgentBridgeHistorySheet(
        provider: provider,
        chatId: chatId,
        runningTasks: status?.runningTasks ?? [],
        deviceLabel: AgentPairingService.lastDeviceLabel ?? "",
        connected: AgentPairingService.lastConnected,
        paired: status?.paired ?? false,
        onPick: { [weak self] session in
          self?.loadBridgeSessionIntoChat(provider: provider, session: session)
        }
      ))
    host.view.backgroundColor = .clear
    presenter.present(host, animated: true)
  }

  func startNewBridgeSession() {
    self.setBridgeLoadedSessionId(nil)
    self.activeBridgeSessionId = nil
    let chatKey = self.engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    if !chatKey.isEmpty {
      ChatEngine.shared.clearLiveBridgeSessionIngest(chatId: chatKey)
      Self.bridgeFreshOwnSentIdsByChat[chatKey] = []
      var hiddenIds = Set<String>()
      for row in self.sourceRowsPayload {
        if let id = self.messageId(fromRawRow: row), !id.isEmpty {
          hiddenIds.insert(id)
        }
      }
      Self.bridgeFreshHiddenIdsByChat[chatKey] = hiddenIds
    }
    presentedBridgeAgentVC?.setTranscriptLoading(false)
    presentedBridgeAgentVC?.isHistoryPicked = false
    presentedBridgeAgentVC?.setMessages([])
    if !self.sourceRowsPayload.isEmpty { self.setRows(self.sourceRowsPayload) }
  }

  /// Ingest a picked history session's transcript into THIS chat (keyed
  /// `bridge-<sessionId>-…`), reveal it through the fresh-surface filter, and show a
  /// brief spinner until its rows land.
  private func loadBridgeSessionIntoChat(provider: String, session: AgentBridgeHistorySession) {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let sessionId = session.resolvedSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionId.isEmpty, !sessionId.hasPrefix("running:") else {
      // A running task with no session id yet: jump straight to the live agent view.
      let preferredMode =
        agentSurfaceMode(for: AgentBridgeSelectionStore.defaultView(provider: provider)) ?? .transcript
      presentBridgeAgentConversation(provider: provider, surfaceMode: preferredMode)
      return
    }
    setBridgeLoadedSessionId(sessionId)
    showBridgeSessionLoadingSpinner()
    presentedBridgeAgentVC?.isHistoryPicked = true
    presentedBridgeAgentVC?.setTranscriptLoading(true)
    let result = ChatEngine.shared.loadAgentBridgeSessionIntoChat([
      "chatId": chatId,
      "provider": provider,
      "sessionId": sessionId,
    ])
    if (result["accepted"] as? Bool) != true {
      hideBridgeSessionLoadingSpinner()
      presentedBridgeAgentVC?.setTranscriptLoading(false)
    } else {
      presentedBridgeAgentVC?.isHistoryPicked = true
    }
  }

  private lazy var bridgeSessionSkeleton = VibeAgentTranscriptSkeletonView()
  private var bridgeSessionSpinnerTimeout: DispatchWorkItem?

  private func showBridgeSessionLoadingSpinner() {
    // The skeleton lives INSIDE the list as its backgroundView — behind the cells, never
    // over them. Rows already on screen (the user's own just-sent message, live rows)
    // stay fully visible while the loading placeholders fill the empty space, and the
    // moment real rows land they simply cover it.
    if collectionView.backgroundView !== bridgeSessionSkeleton {
      collectionView.backgroundView = bridgeSessionSkeleton
    }
    // Bottom clearance = the list's real bottom padding: this surface floats the
    // composer over the feed and reserves room via the flow layout's section inset
    // (contentPaddingBottom), NOT contentInset — using only contentInset left the
    // lowest placeholder hidden behind the composer.
    bridgeSessionSkeleton.contentBottomInset = max(
      20.0, contentPaddingBottom + collectionView.contentInset.bottom + 8.0)
    bridgeSessionSkeleton.applyAppearance(
      VibeAgentKitMap.appearance(for: self.traitCollection),
      userBubbleGradient: appearance.bubbleMeGradient
    )
    bridgeSessionSkeleton.isHidden = false
    bridgeSessionSkeleton.alpha = 1.0
    bridgeSessionSkeleton.startShimmer()

    bridgeSessionSpinnerTimeout?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.hideBridgeSessionLoadingSpinner() }
    bridgeSessionSpinnerTimeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
  }

  private func hideBridgeSessionLoadingSpinner() {
    bridgeSessionSpinnerTimeout?.cancel()
    bridgeSessionSpinnerTimeout = nil
    guard !bridgeSessionSkeleton.isHidden else { return }
    UIView.animate(withDuration: 0.2, animations: {
      self.bridgeSessionSkeleton.alpha = 0.0
    }) { _ in
      self.bridgeSessionSkeleton.isHidden = true
      self.bridgeSessionSkeleton.stopShimmer()
      if self.collectionView.backgroundView === self.bridgeSessionSkeleton {
        self.collectionView.backgroundView = nil
      }
    }
  }

  /// Once a picked session's rows land, drop the loading spinner.
  private func dismissBridgeSpinnerIfSessionLoaded(_ parsed: [ChatListRow]) {
    guard !bridgeSessionSkeleton.isHidden, let sessionId = bridgeLoadedSessionId else { return }
    let prefix = "bridge-\(sessionId)"
    if parsed.contains(where: { ($0.messageId ?? "").hasPrefix(prefix) }) {
      hideBridgeSessionLoadingSpinner()
      presentedBridgeAgentVC?.setTranscriptLoading(false)
    }
  }

  /// Adopt the bridge session id of the most recent finished agent turn in this fresh
  /// thread, so a follow-up resumes that same CLI session (see
  /// `agentBridgeMetadataForOutgoing`). Skipped when a History session is explicitly
  /// loaded (that id already governs the resume). Never clears here — New Chat / DM-switch
  /// own the reset — so a transient runtime-less update can't drop the active session
  /// mid-thread. A still-running turn (sessionId "running:…") is ignored until it settles.
  private func adoptActiveBridgeSessionId(from parsed: [ChatListRow]) {
    guard currentBridgeProvider != nil, bridgeLoadedSessionId == nil else { return }
    for row in parsed.reversed() {
      // Claude reports `sessionId`; Codex reports `threadId`. Both resume through the
      // same `agentBridgeResumeSessionId` slot (resumeIdFor on the bridge), so adopt
      // whichever this turn carries.
      let raw = row.agentRuntime?.sessionId ?? row.agentRuntime?.threadId
      guard
        let sid = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
        !sid.isEmpty, !sid.hasPrefix("running:")
      else { continue }
      if activeBridgeSessionId != sid {
        activeBridgeSessionId = sid
        VibeDebugLog.log("[AgentRoute] adopt activeBridgeSessionId=%@", sid)
      }
      return
    }
  }

  @objc private func handleAgentBridgeSelectionChanged(_ notification: Notification) {
    updateAgentBridgeControlTitle()
    // A live flip of this agent's "Default view" → Agent (set from the profile) is honored
    // by the presence refresh; model/repo changes are no-ops there, so the user is never
    // yanked between views by an unrelated selection change.
    scheduleBridgeAgentPresenceRefresh()
  }

  private func handleNativeSend(
    text: String,
    agentMention: Bool = false,
    agentText: String? = nil,
    mentionedAgentUsername: String? = nil,
    fromAgentSurface: Bool = false,
    agentBridgeAttachmentsEnc: [String] = []
  )
  {
    let messageId = UUID().uuidString.lowercased()
    let now = Date()
    let timestampMs = now.timeIntervalSince1970 * 1000
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let timestamp = formatter.string(from: now)

    // Capture reply-to ID before dismissing the banner (dismissing clears it).
    let replyToMessageId = inputBar?.activeReplyToMessageId
    var bridgeMetadata = agentBridgeMetadataForOutgoing(
      text: text,
      mentionedAgentUsername: mentionedAgentUsername
    )
    let attachmentBlobs = agentBridgeAttachmentsEnc
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if !attachmentBlobs.isEmpty {
      bridgeMetadata["agentBridgeAttachmentsEnc"] = attachmentBlobs
      bridgeMetadata["attachmentsEnc"] = attachmentBlobs
    }
    // A bridge-agent send opens this fresh thread — keep it visible regardless of
    // history-snapshot timing (see bridgeFreshFiltered).
    if !bridgeMetadata.isEmpty {
      noteBridgeFreshOwnSentId(messageId)
    }

    NSLog(
      "[ChatListView] handleNativeSend START — messageId: %@, text length: %lu, nativeSendEnabled: %@, replyTo: %@",
      messageId, text.count, nativeSendEnabled ? "true" : "false", replyToMessageId ?? "nil")

    // Agent chat: no morph-from-input animation and no hidden ghost cell. The
    // headless agent transport owns the rows (user bubble + streaming answer),
    // so we just hand the text off and let the list push content up to make room
    // for the streaming response. Using the morph path here leaves the user
    // bubble stuck hidden (it never arrives through the normal engine pipeline).
    // Claude/Codex bridge DMs are handled below by the native dispatch path. This
    // host event branch is only for the built-in agent surface.
    if agentChatMode && currentBridgeProvider == nil && !fromAgentSurface {
      inputBar?.dismissReplyBanner(animated: false)
      inputBar?.clearText()
      pendingAgentPushToTop = true
      // Re-use the armed id when resending an edited failed message so the
      // transport truncates the stale turn instead of appending a duplicate.
      let outgoingMessageId = editingAgentMessageId ?? messageId
      editingAgentMessageId = nil
      var sendPayload: [String: Any] = [
        "type": "sendMessage",
        "messageId": outgoingMessageId,
        "text": text,
        "timestamp": timestamp,
        "timestampMs": timestampMs,
      ]
      if let replyToMessageId {
        sendPayload["replyToMessageId"] = replyToMessageId
      }
      if !bridgeMetadata.isEmpty {
        sendPayload["metadata"] = bridgeMetadata
      }
      onNativeEvent(sendPayload)
      return
    }

    if currentBridgeProvider != nil && !fromAgentSurface {
      inputBar?.dismissReplyBanner(animated: false)
      inputBar?.clearText()
      // Inline bridge DM in the normal chat list: no pin-to-top. The list scrolls to
      // bottom on send like any other conversation (see the agentSurface note in setRows).
      let outgoingMessageId = editingAgentMessageId ?? messageId
      editingAgentMessageId = nil
      if !bridgeMetadata.isEmpty {
        noteBridgeFreshOwnSentId(outgoingMessageId)
      }
      dispatchOutgoingSend(
        messageId: outgoingMessageId,
        text: text,
        timestamp: timestamp,
        timestampMs: timestampMs,
        replyToMessageId: replyToMessageId,
        bridgeMetadata: bridgeMetadata,
        agentMention: agentMention,
        agentText: agentText,
        mentionedAgentUsername: mentionedAgentUsername
      )
      return
    }

    // Agent runtime surface: it owns its own composer (the chat input bar is offscreen
    // behind the full-screen surface), so skip the chat-view send morph + hidden-cell
    // dance. Dispatch through the shared transport, then refresh the agent feed so the
    // user's bubble appears HERE — the optimistic native row updates the chat list
    // directly without firing ChatEngine.didChange, which is the only thing the agent
    // view observes (root cause of "my message went to the chat view, not the agent view").
    if fromAgentSurface {
      inputBar?.dismissReplyBanner(animated: false)
      // Claude/Codex bridge DMs reach here too (full-page agent surface). Re-use the
      // armed id when resending an edited failed turn so the transport truncates the
      // stale run instead of stacking a duplicate, and keep the outgoing bubble visible
      // through the fresh-surface filter even if its id was rewritten by the edit.
      let outgoingMessageId = editingAgentMessageId ?? messageId
      editingAgentMessageId = nil
      if !bridgeMetadata.isEmpty {
        noteBridgeFreshOwnSentId(outgoingMessageId)
      }
      // Pin the freshly-sent question to the top (ChatGPT-style) like the bridge path did.
      pendingAgentPushToTop = true
      presentedBridgeAgentVC?.appendLocalPendingTurn(messageId: outgoingMessageId, body: text)
      dispatchOutgoingSend(
        messageId: outgoingMessageId,
        text: text,
        timestamp: timestamp,
        timestampMs: timestampMs,
        replyToMessageId: replyToMessageId,
        bridgeMetadata: bridgeMetadata,
        agentMention: agentMention,
        agentText: agentText,
        mentionedAgentUsername: mentionedAgentUsername
      )
      // Defer one runloop tick so the optimistic row is fully committed to `rows`
      // before the agent feed re-reads it.
      DispatchQueue.main.async { [weak self] in
        self?.presentedBridgeAgentVC?.reloadLiveMessages()
      }
      return
    }

    // 1. Hide the message cell immediately (before it even exists).
    hiddenMessageId = messageId

    // 2. Compute source rects and capture live text snapshot (BEFORE clearing).
    let sourceRect: CGRect
    let sourceContainerRect: CGRect?
    let sourceBackgroundRectInContainer: CGRect?
    let sourceContentRectInContainer: CGRect?
    let sourceScrollOffset: CGFloat
    let sourceBackgroundSnapshotView: UIView?
    let sourceContentSnapshotView: UIView?
    if let bar = inputBar {
      if let capture = bar.captureSendTransition(in: self) {
        sourceRect = CGRect(
          x: capture.sourceContainerRect.minX + capture.sourceContentRectInContainer.minX,
          y: capture.sourceContainerRect.minY + capture.sourceContentRectInContainer.minY,
          width: capture.sourceContentRectInContainer.width,
          height: capture.sourceContentRectInContainer.height
        )
        sourceContainerRect = capture.sourceContainerRect
        sourceBackgroundRectInContainer = capture.sourceBackgroundRectInContainer
        sourceContentRectInContainer = capture.sourceContentRectInContainer
        sourceScrollOffset = capture.sourceScrollOffset
        sourceBackgroundSnapshotView = capture.sourceBackgroundSnapshotView
        sourceContentSnapshotView = capture.sourceContentSnapshotView
      } else {
        sourceRect = bar.textRect(in: self)
        sourceContainerRect = nil
        sourceBackgroundRectInContainer = nil
        sourceContentRectInContainer = nil
        sourceScrollOffset = 0.0
        sourceBackgroundSnapshotView = bar.transitionBackgroundSnapshot(in: self)
        sourceContentSnapshotView = bar.textContentSnapshot(in: self)
      }
    } else {
      sourceRect = CGRect(x: 16, y: bounds.height - 60, width: bounds.width - 32, height: 44)
      sourceContainerRect = nil
      sourceBackgroundRectInContainer = nil
      sourceContentRectInContainer = nil
      sourceScrollOffset = 0.0
      sourceBackgroundSnapshotView = nil
      sourceContentSnapshotView = nil
    }

    // 3. Store pending transition so it starts when the cell arrives.
    let payload = SendTransitionPayload(
      messageId: messageId,
      text: text,
      timestamp: timestamp,
      startRect: sourceRect,
      sourceContainerRect: sourceContainerRect,
      sourceBackgroundRectInContainer: sourceBackgroundRectInContainer,
      sourceContentRectInContainer: sourceContentRectInContainer,
      sourceScrollOffset: sourceScrollOffset,
      sourceBackgroundSnapshotView: sourceBackgroundSnapshotView,
      sourceContentSnapshotView: sourceContentSnapshotView
    )
    pendingSendTransition = payload

    // 4. Dismiss reply banner after capture, so reply sends morph from the same composer height.
    inputBar?.dismissReplyBanner(animated: false)

    // 5. Clear the input bar.
    inputBar?.clearText()

    // 6. Either append natively (no JS dependency) or delegate to JS.
    dispatchOutgoingSend(
      messageId: messageId,
      text: text,
      timestamp: timestamp,
      timestampMs: timestampMs,
      replyToMessageId: replyToMessageId,
      bridgeMetadata: bridgeMetadata,
      agentMention: agentMention,
      agentText: agentText,
      mentionedAgentUsername: mentionedAgentUsername
    )
  }

  /// Append the outgoing row (native path) and hand the message to the transport —
  /// shared by the normal chat-input send and the agent-runtime-surface send (which
  /// skips the chat-view morph but reuses this transport logic verbatim).
  private func dispatchOutgoingSend(
    messageId: String,
    text: String,
    timestamp: String,
    timestampMs: Double,
    replyToMessageId: String?,
    bridgeMetadata: [String: Any],
    agentMention: Bool,
    agentText: String?,
    mentionedAgentUsername: String?
  ) {
    if nativeSendEnabled {
      let isBridgeSend =
        currentBridgeProvider != nil
        || ((bridgeMetadata["agentBridgeProvider"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
      if !isBridgeSend {
        queueNativeOutgoingMessage(
          messageId: messageId,
          text: text,
          timestamp: timestamp,
          timestampMs: timestampMs,
          replyToId: replyToMessageId,
          autoMarkSent: false,
          metadata: bridgeMetadata
        )
      }
      let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      let myUserId = engineMyUserId.trimmingCharacters(in: .whitespacesAndNewlines)
      let peerUserId = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
      let peerAgentId = enginePeerAgentId.trimmingCharacters(in: .whitespacesAndNewlines)
      if chatId.isEmpty {
        NSLog(
          "[ChatListView] native ChatEngine send blocked: empty chatId (messageId=%@, myUserId=%@, peerUserId=%@)",
          messageId,
          myUserId,
          peerUserId
          )
        if isBridgeSend {
          showBridgeSendFailure(messageId: messageId, reason: "invalid_chat", provider: currentBridgeProvider)
        } else {
          setNativeOutgoingMessageStatus(messageId, status: "error")
        }
        return
      }
      var sendPayload: [String: Any] = [
        "chatId": chatId,
        "messageId": messageId,
        "type": "text",
        "text": text,
        "timestampMs": timestampMs,
        "replyToId": replyToMessageId as Any,
        "myUserId": myUserId,
        "peerUserId": peerUserId,
        "peerAgentId": peerAgentId,
        "isGroup": isGroupOrChannel,
      ]
      if !bridgeMetadata.isEmpty {
        sendPayload["metadata"] = bridgeMetadata
      }
      if agentMention, let agentText {
        sendPayload["agentMention"] = true
        sendPayload["agentText"] = agentText
      }
      if let mentionedAgentUsername, !mentionedAgentUsername.isEmpty {
        sendPayload["mentionedAgentUsername"] = mentionedAgentUsername
        if let agentText, !agentText.isEmpty {
          sendPayload["agentText"] = agentText
        }
      }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let result = ChatEngine.shared.sendMessage(sendPayload)
        let accepted = (result["accepted"] as? Bool) == true
        let queued = (result["queued"] as? Bool) == true
        if !accepted {
          let statusSnapshot = ChatEngine.shared.getStatus()
          let journalTail = Array(ChatEngine.shared.getJournal().suffix(6))
          NSLog(
            "[ChatListView] native ChatEngine sendMessage rejected: %@ status=%@ journalTail=%@",
            String(describing: result),
            String(describing: statusSnapshot),
            String(describing: journalTail)
          )
          DispatchQueue.main.async {
            if isBridgeSend {
              self?.showBridgeSendFailure(
                messageId: messageId,
                reason: (result["reason"] as? String) ?? "send_failed",
                provider: (result["bridgeProvider"] as? String) ?? self?.currentBridgeProvider
              )
            } else {
              self?.setNativeOutgoingMessageStatus(messageId, status: "error")
            }
          }
          return
        }

        if queued {
          let statusSnapshot = ChatEngine.shared.getStatus()
          let journalTail = Array(ChatEngine.shared.getJournal().suffix(6))
          let reason = (result["reason"] as? String) ?? "unknown"
          NSLog(
            "[ChatListView] native ChatEngine sendMessage queued: reason=%@ result=%@ status=%@ journalTail=%@",
            reason,
            String(describing: result),
            String(describing: statusSnapshot),
            String(describing: journalTail)
          )
        }

        // Determine the status to show on the bubble.
        let resolvedStatus: String = {
          if let stateValue = result["state"] as? String {
            let normalized = stateValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "error" || normalized == "pending" || normalized == "sent"
              || normalized == "delivered" || normalized == "read"
            {
              return normalized
            }
          }
          // If the engine accepted and didn't return an explicit state, mark sent.
          return accepted ? "sent" : "error"
        }()
        DispatchQueue.main.async {
          if isBridgeSend, resolvedStatus == "error" {
            self?.showBridgeSendFailure(
              messageId: messageId,
              reason: (result["reason"] as? String) ?? "send_failed",
              provider: (result["bridgeProvider"] as? String) ?? self?.currentBridgeProvider
            )
          } else if !isBridgeSend {
            self?.setNativeOutgoingMessageStatus(messageId, status: resolvedStatus)
          }
        }
      }
    } else {
      var sendPayload: [String: Any] = [
        "type": "sendMessage",
        "messageId": messageId,
        "text": text,
        "timestamp": timestamp,
        "timestampMs": timestampMs,
      ]
      if let replyToMessageId {
        sendPayload["replyToMessageId"] = replyToMessageId
      }
      if !bridgeMetadata.isEmpty {
        sendPayload["metadata"] = bridgeMetadata
      }
      if agentMention, let agentText {
        sendPayload["agentMention"] = true
        sendPayload["agentText"] = agentText
      }
      if let mentionedAgentUsername, !mentionedAgentUsername.isEmpty {
        sendPayload["mentionedAgentUsername"] = mentionedAgentUsername
        if let agentText, !agentText.isEmpty {
          sendPayload["agentText"] = agentText
        }
      }
      onNativeEvent(sendPayload)
    }
  }

  private func makeAttachmentSendTransitionPayload(
    messageId: String,
    text: String,
    timestamp: String,
    transitionCapture: ChatAttachmentTransitionCapture?
  ) -> SendTransitionPayload? {
    guard let transitionCapture else { return nil }
    let sourceContainerRect: CGRect
    if let window {
      sourceContainerRect = convert(transitionCapture.sourceContainerFrameInWindow, from: window)
    } else {
      sourceContainerRect = transitionCapture.sourceContainerFrameInWindow
    }
    let localRect = CGRect(origin: .zero, size: sourceContainerRect.size)
    return SendTransitionPayload(
      messageId: messageId,
      text: text,
      timestamp: timestamp,
      startRect: sourceContainerRect,
      sourceContainerRect: sourceContainerRect,
      sourceBackgroundRectInContainer: localRect,
      sourceContentRectInContainer: localRect,
      sourceScrollOffset: 0.0,
      sourceBackgroundSnapshotView: transitionCapture.sourceBackgroundSnapshotView,
      sourceContentSnapshotView: transitionCapture.sourceContentSnapshotView
    )
  }

  /// Multi-image send. Agent (Claude/Codex) DMs get ONE message carrying every image
  /// as a sealed bridge blob (single dispatched task, agent-view grid renders all);
  /// normal chats fall back to one media message per image, caption on the last.
  private func handleNativeAttachmentSend(
    uris: [String],
    caption: String?,
    transitionCapture: ChatAttachmentTransitionCapture?
  ) {
    let cleaned = uris
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard let first = cleaned.first else { return }
    if cleaned.count == 1 {
      handleNativeAttachmentSend(uri: first, caption: caption, transitionCapture: transitionCapture)
      return
    }
    if currentBridgeProvider != nil {
      handleNativeAttachmentSend(
        uri: first,
        caption: caption,
        transitionCapture: transitionCapture,
        extraImageURIs: Array(cleaned.dropFirst())
      )
      return
    }
    for (index, uri) in cleaned.enumerated() {
      handleNativeAttachmentSend(
        uri: uri,
        caption: index == cleaned.count - 1 ? caption : nil,
        transitionCapture: index == 0 ? transitionCapture : nil
      )
    }
  }

  private func handleNativeAttachmentSend(
    uri: String,
    caption: String?,
    transitionCapture: ChatAttachmentTransitionCapture?,
    extraImageURIs: [String] = []
  ) {
    let messageId = UUID().uuidString.lowercased()
    let now = Date()
    let timestampMs = now.timeIntervalSince1970 * 1000
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let timestamp = formatter.string(from: now)
    let replyToMessageId = inputBar?.activeReplyToMessageId
    let isVideo = isVideoAttachmentURI(uri)
    let type = isVideo ? "video" : "image"
    let fileName = localAttachmentFileName(for: uri)
    let fileSize = localAttachmentFileSize(for: uri)
    let duration = isVideo ? localMediaDurationSeconds(for: uri) : nil
    let mediaSize = isVideo ? localVideoNaturalSize(for: uri) : localImagePixelSize(for: uri)
    let thumbnailBase64 = isVideo ? localVideoThumbnailBase64(for: uri) : nil
    let effectiveText = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    inputBar?.dismissReplyBanner(animated: false)
    if let transitionPayload = makeAttachmentSendTransitionPayload(
      messageId: messageId,
      text: effectiveText,
      timestamp: timestamp,
      transitionCapture: transitionCapture
    ) {
      hiddenMessageId = messageId
      pendingSendTransition = transitionPayload
    }

    queueNativeOutgoingMediaMessage(
      messageId: messageId,
      type: type,
      localUri: uri,
      caption: effectiveText.isEmpty ? nil : effectiveText,
      timestamp: timestamp,
      timestampMs: timestampMs,
      fileName: fileName,
      fileSize: fileSize,
      duration: duration,
      mediaSize: mediaSize,
      thumbnailBase64: thumbnailBase64,
      replyToId: replyToMessageId
    )

    if pendingSendTransition == nil {
      DispatchQueue.main.async { [weak self] in
        self?.scrollToBottom(animated: true)
      }
    }

    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let myUserId = engineMyUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    let peerUserId = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    let peerAgentId = enginePeerAgentId.trimmingCharacters(in: .whitespacesAndNewlines)
    if chatId.isEmpty {
      if currentBridgeProvider != nil {
        showBridgeSendFailure(messageId: messageId, reason: "invalid_chat", provider: currentBridgeProvider)
      } else {
        setNativeOutgoingMessageStatus(messageId, status: "error")
      }
      return
    }

    var metadata: [String: Any] = ["mediaUrl": uri]
    if let fileName, !fileName.isEmpty { metadata["fileName"] = fileName }
    if let fileSize, fileSize > 0 { metadata["fileSize"] = fileSize }
    if let duration { metadata["duration"] = duration }
    if let mediaSize, mediaSize.width > 1.0, mediaSize.height > 1.0 {
      metadata["width"] = Int(mediaSize.width)
      metadata["height"] = Int(mediaSize.height)
    }
    if let thumbnailBase64, !thumbnailBase64.isEmpty {
      metadata["thumbnailBase64"] = thumbnailBase64
    }
    if !effectiveText.isEmpty {
      metadata["caption"] = effectiveText
    }

    // Bridge-agent DM: a plain media message never reaches the agent — the daemon only
    // sees a task when the message carries the bridge run metadata + sealed attachment
    // blobs. Seal every picked image (arte1, same format as the runtime composer) into
    // ONE message and fold in the provider/repo/run metadata so this send dispatches a
    // single task carrying the whole set. The server requires non-empty dispatch text,
    // so an image-only send gets a default caption.
    var bridgeImageBody = effectiveText
    if type == "image", currentBridgeProvider != nil {
      let blobs = ([uri] + extraImageURIs).compactMap { sealedBridgeImageBlob(forLocalURI: $0) }
      if !blobs.isEmpty {
        if bridgeImageBody.isEmpty {
          bridgeImageBody =
            blobs.count == 1
            ? "Please take a look at the attached image."
            : "Please take a look at the \(blobs.count) attached images."
        }
        let bridgeMeta = agentBridgeMetadataForOutgoing(
          text: bridgeImageBody,
          mentionedAgentUsername: currentBridgeProvider
        )
        if !bridgeMeta.isEmpty {
          metadata.merge(bridgeMeta) { _, new in new }
          metadata["agentBridgeAttachmentsEnc"] = blobs
          noteBridgeFreshOwnSentId(messageId)
        }
      }
    }
    let isBridgeMediaSend =
      currentBridgeProvider != nil
      || ((metadata["agentBridgeProvider"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    if isBridgeMediaSend {
      removeNativeOutgoingMessage(messageId)
    }

    let sendPayload: [String: Any] = [
      "chatId": chatId,
      "messageId": messageId,
      "type": type,
      "text": bridgeImageBody,
      "timestampMs": timestampMs,
      "replyToId": replyToMessageId as Any,
      "metadata": metadata,
      "myUserId": myUserId,
      "peerUserId": peerUserId,
      "peerAgentId": peerAgentId,
      "isGroup": isGroupOrChannel,
    ]

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = ChatEngine.shared.sendMessage(sendPayload)
      let accepted = (result["accepted"] as? Bool) == true
      let resolvedStatus: String = {
        if let stateValue = result["state"] as? String {
          let normalized = stateValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          if normalized == "error" || normalized == "pending" || normalized == "sent"
            || normalized == "delivered" || normalized == "read"
          {
            return normalized
          }
        }
        return accepted ? "sent" : "error"
      }()
      DispatchQueue.main.async {
        if isBridgeMediaSend, !accepted || resolvedStatus == "error" {
          self?.showBridgeSendFailure(
            messageId: messageId,
            reason: (result["reason"] as? String) ?? "send_failed",
            provider: (result["bridgeProvider"] as? String) ?? self?.currentBridgeProvider
          )
        } else if !isBridgeMediaSend {
          self?.setNativeOutgoingMessageStatus(messageId, status: resolvedStatus)
        }
      }
    }
  }

  private func handleNativeAudioFileSend(uri: String, displayName: String?) {
    let messageId = UUID().uuidString.lowercased()
    let now = Date()
    let timestampMs = now.timeIntervalSince1970 * 1000
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let timestamp = formatter.string(from: now)
    let replyToMessageId = inputBar?.activeReplyToMessageId
    let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fileName =
      trimmedDisplayName?.isEmpty == false ? trimmedDisplayName : localAttachmentFileName(for: uri)
    let fileSize = localAttachmentFileSize(for: uri)
    let duration = localMediaDurationSeconds(for: uri)
    let thumbnailBase64 = localAudioThumbnailBase64(for: uri)

    inputBar?.dismissReplyBanner(animated: false)

    queueNativeOutgoingMediaMessage(
      messageId: messageId,
      type: "music",
      localUri: uri,
      caption: nil,
      timestamp: timestamp,
      timestampMs: timestampMs,
      fileName: fileName,
      fileSize: fileSize,
      duration: duration,
      thumbnailBase64: thumbnailBase64,
      replyToId: replyToMessageId
    )

    DispatchQueue.main.async { [weak self] in
      self?.scrollToBottom(animated: true)
    }

    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let myUserId = engineMyUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    let peerUserId = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    let peerAgentId = enginePeerAgentId.trimmingCharacters(in: .whitespacesAndNewlines)
    if chatId.isEmpty {
      setNativeOutgoingMessageStatus(messageId, status: "error")
      return
    }

    var metadata: [String: Any] = ["mediaUrl": uri]
    if let fileName, !fileName.isEmpty { metadata["fileName"] = fileName }
    if let fileSize, fileSize > 0 { metadata["fileSize"] = fileSize }
    if let duration { metadata["duration"] = duration }
    if let thumbnailBase64, !thumbnailBase64.isEmpty {
      metadata["thumbnailBase64"] = thumbnailBase64
    }

    let sendPayload: [String: Any] = [
      "chatId": chatId,
      "messageId": messageId,
      "type": "music",
      "text": "",
      "timestampMs": timestampMs,
      "replyToId": replyToMessageId as Any,
      "metadata": metadata,
      "myUserId": myUserId,
      "peerUserId": peerUserId,
      "peerAgentId": peerAgentId,
      "isGroup": isGroupOrChannel,
    ]

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = ChatEngine.shared.sendMessage(sendPayload)
      let accepted = (result["accepted"] as? Bool) == true
      let resolvedStatus: String = {
        if let stateValue = result["state"] as? String {
          let normalized = stateValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          if normalized == "error" || normalized == "pending" || normalized == "sent"
            || normalized == "delivered" || normalized == "read"
          {
            return normalized
          }
        }
        return accepted ? "sent" : "error"
      }()
      DispatchQueue.main.async {
        self?.setNativeOutgoingMessageStatus(messageId, status: resolvedStatus)
      }
    }
  }

  private func topPresentingViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let current = responder {
      if let vc = current as? UIViewController {
        var top = vc
        while let presented = top.presentedViewController {
          top = presented
        }
        return top
      }
      responder = current.next
    }
    return window?.rootViewController
  }

  /// True only when this chat view is the one actually on screen — it's in the window, not
  /// hidden, and frontmost at its own centre (nothing pushed/presented is covering it). Keeps
  /// an agent ask/command sheet from popping over an unrelated screen when a background /
  /// recycled chat view still holds this chatId. Structure-agnostic (works for push, modal,
  /// custom container) because it asks the window who's actually on top at this view's centre.
  private func isVisibleFrontmostChat() -> Bool {
    guard let window = self.window, !isHidden, alpha > 0.01,
      bounds.width > 1, bounds.height > 1
    else { return false }
    let probe = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: window)
    guard window.bounds.contains(probe), let hit = window.hitTest(probe, with: nil) else {
      return false
    }
    return hit === self || hit.isDescendant(of: self)
  }

  // MARK: - Native full-page agent surface (VibeAgentConversationViewController)

  /// Push the full-page agent view for the task that produced `messageId`, seeded
  /// with that task's prior messages (the user prompt + the agent reply) so the
  /// page is never empty. The default chat list stays the multiplexing surface;
  /// this view is single-task.
  private var didPrefetchBridgeHistory = false
  private var lastCurrentBridgeSessionRequestAt: TimeInterval = 0
  /// True when the in-place agent view was opened manually ("See progress") rather than by
  /// the Default view = Agent setting. A manual view is left alone by unrelated selection
  /// changes; an auto view follows a live flip of the Default-view setting.
  private var bridgeAgentManuallyShown = false
  /// One-shot guard so the legacy pushed "agent view on open" only auto-presents once per
  /// DM (reset when the peer changes). The in-place host path uses an idempotent presence
  /// refresh instead and ignores this flag.
  private var didAutoPresentAgentView = false

  /// Claude/Codex DMs open as fresh sessions. History is loaded only after the user
  /// explicitly opens History, so relaunch/open never pulls old sessions into view.
  /// Opening a Claude/Codex DM mid-run must land in the RUNNING conversation, not an
  /// empty surface that only fills in when the next stream frame happens to arrive.
  /// Ask the bridge for this chat's current session (it resolves the id — the phone
  /// doesn't know it yet). An idle chat answers `no_current_session` and the DM stays
  /// a fresh scratch surface. Retries cover the two real-world misses: the chat topic
  /// isn't joined yet at open, and the bridge is offline at open and connects a few
  /// seconds later (the connect-gate case from the device logs).
  private func prefetchBridgeHistoryIfNeeded() {
    guard !didPrefetchBridgeHistory else { return }
    didPrefetchBridgeHistory = true
    // Fire once now (covers the already-connected case), then let the channel-join event
    // (handleChatEngineChanged → chatChannelStateChanged) and a short fallback poll cover
    // the cold-launch case where the socket/join aren't ready yet at open —
    // requestAgentBridgeHistory itself nudges connect+join on each miss.
    requestCurrentBridgeSession(reason: "open")
    scheduleCurrentBridgeSessionFallback(attempt: 0)
    let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    hadLiveBridgeRun =
      !chatKey.isEmpty && ChatEngine.shared.liveBridgeSessionId(chatId: chatKey) != nil
    requestBridgeUsageSnapshot(reason: "open")
  }

  /// Ask the engine for whatever session is live for this DM right now. Throttled +
  /// idempotent: no-ops once a live session is adopted, so the open call, the channel-join
  /// event, and the fallback poll can all call it freely without stacking requests.
  private func requestCurrentBridgeSession(reason: String) {
    guard let provider = currentBridgeProvider else { return }
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return }
    // Already adopted this chat's live session — done.
    guard ChatEngine.shared.liveBridgeSessionId(chatId: chatId) == nil else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastCurrentBridgeSessionRequestAt > 1.2 else { return }
    lastCurrentBridgeSessionRequestAt = now
    let result = ChatEngine.shared.loadCurrentAgentBridgeSessionIntoChat(
      chatId: chatId, provider: provider)
    NSLog(
      "[ChatOpen] currentSession request chat=%@ provider=%@ reason=%@ accepted=%@ result=%@",
      String(chatId.prefix(12)), provider, reason,
      (result["accepted"] as? Bool) == true ? "Y" : "N",
      (result["reason"] as? String) ?? "-")
  }

  /// Bounded fallback poll — covers the case where no channel-join notification lands (the
  /// topic was already joined before this view bound). Stops as soon as a live session is
  /// adopted, the DM changes, or the view detaches.
  private func scheduleCurrentBridgeSessionFallback(attempt: Int) {
    guard attempt < 6 else { return }
    let provider = currentBridgeProvider
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, self.window != nil, self.currentBridgeProvider == provider else { return }
      // The usage snapshot rides the same join-readiness window — retry it here too
      // (throttled internally; the first attempts at open usually lose to chat_not_joined).
      self.requestBridgeUsageSnapshot(reason: "poll#\(attempt + 1)")
      let chatId = self.engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !chatId.isEmpty, ChatEngine.shared.liveBridgeSessionId(chatId: chatId) == nil else {
        return
      }
      self.requestCurrentBridgeSession(reason: "poll#\(attempt + 1)")
      self.scheduleCurrentBridgeSessionFallback(attempt: attempt + 1)
    }
  }

  private func agentSurfaceMode(for defaultView: AgentBridgeDefaultView) -> VibeAgentConversationSurfaceMode? {
    switch defaultView {
    case .chat:
      return nil
    case .agent:
      return .transcript
    case .visual:
      return .visual
    }
  }

  /// When the user set this Claude/Codex profile's default view to an agent surface,
  /// show that surface instead of the bubble chat. The one-shot guard ensures backing
  /// out to the chat surface doesn't immediately re-present; manual actions re-open on demand.
  private func presentPreferredAgentViewIfNeeded(retry: Int = 0) {
    // First, clear any agent surface left over from a DIFFERENT DM (the recycled view).
    scheduleBridgeAgentPresenceRefresh()
    // One-shot on DM open: if this provider's Default view is Agent, open the isolated
    // agent surface once.
    guard !didAutoPresentAgentView else { return }
    guard let provider = currentBridgeProvider else { return }
    let defaultView = AgentBridgeSelectionStore.defaultView(provider: provider)
    guard let surfaceMode = agentSurfaceMode(for: defaultView) else { return }
    guard window != nil else {
      guard retry < 16 else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.presentPreferredAgentViewIfNeeded(retry: retry + 1)
      }
      return
    }
    didAutoPresentAgentView = true
    bridgeAgentManuallyShown = false
    presentBridgeAgentConversation(provider: provider, animated: false, surfaceMode: surfaceMode)
  }

  /// Mount the isolated agent surface for `provider` as this DM's PRIMARY page, driven by
  /// the host controller at view-appear time. The normal trigger
  /// (`presentPreferredAgentViewIfNeeded`) can't fire this early because it resolves the
  /// provider from `enginePeerUserId`, which the controller defers to ~0.28s AFTER the
  /// transition (for a smooth push) — so the chat would be fully on screen first. Here
  /// the controller passes the provider straight from the route, so the agent mounts
  /// during the push and rides it as the page (no chat-view flash). The later
  /// deferred-binding auto-present re-enters `presentBridgeAgentConversation`, which is
  /// idempotent (already-hosted check), so this does not double-mount.
  func presentPreferredAgentViewNow(provider: String) {
    let p = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !p.isEmpty else { return }
    let hasHost = onHostBridgeAgentView != nil
    let defaultView = AgentBridgeSelectionStore.defaultView(provider: p)
    VibeDebugLog.log(
      "[AgentRoute] presentPreferredAgentViewNow provider=%@ hasHost=%@ already=%@ default=%@",
      p, hasHost ? "true" : "false", didAutoPresentAgentView ? "true" : "false",
      "\(defaultView)")
    // The in-place host path is idempotent and owns presentation here;
    // the legacy push/modal fallback owns presentation via presentPreferredAgentViewIfNeeded.
    guard !didAutoPresentAgentView else { return }
    guard let surfaceMode = agentSurfaceMode(for: defaultView) else { return }
    didAutoPresentAgentView = true
    bridgeAgentManuallyShown = false
    if hasHost {
      presentBridgeAgentConversation(provider: p, animated: false, surfaceMode: surfaceMode)
    } else {
      presentPreferredAgentViewIfNeeded()
    }
  }

  /// Coalesce DM-context changes into one presence evaluation on the next runloop tick.
  private func scheduleBridgeAgentPresenceRefresh() {
    DispatchQueue.main.async { [weak self] in self?.refreshBridgeAgentPresence() }
  }

  /// Tear down an isolated agent surface that belongs to a DIFFERENT DM (or none now) —
  /// the recycled ChatListView must not show the previous DM's agent view. Presentation
  /// itself is one-shot per DM open (see presentPreferredAgentViewIfNeeded) and on-demand
  /// via "See progress", so this never re-presents (which would fight a user back-out).
  private func refreshBridgeAgentPresence() {
    let provider = currentBridgeProvider
    let desiredMode = provider.flatMap {
      agentSurfaceMode(for: AgentBridgeSelectionStore.defaultView(provider: $0))
    }

    guard let hosted = hostedBridgeAgentProvider?() else {
      guard !bridgeAgentManuallyShown, !didAutoPresentAgentView,
        let provider, let desiredMode
      else { return }
      didAutoPresentAgentView = true
      bridgeAgentManuallyShown = false
      presentBridgeAgentConversation(provider: provider, animated: false, surfaceMode: desiredMode)
      return
    }

    guard let provider, hosted == provider else {
      onTearDownBridgeAgentView?()
      bridgeAgentManuallyShown = false
      didAutoPresentAgentView = false
      return
    }

    guard !bridgeAgentManuallyShown else { return }
    guard let desiredMode else {
      onTearDownBridgeAgentView?()
      didAutoPresentAgentView = false
      return
    }

    if hostedBridgeAgentSurfaceMode?() != desiredMode {
      didAutoPresentAgentView = true
      bridgeAgentManuallyShown = false
      presentBridgeAgentConversation(provider: provider, animated: false, surfaceMode: desiredMode)
    }
  }

  /// Open a DM-level agent runtime view for `provider` (no specific task): seeded with
  /// the conversation's current rows and kept live via the provider, sending through the
  /// normal bridge path. Reserved for the group/multi-agent case (see
  /// bubbleUsesAgentTurnContent) — a 1:1 DM renders inline instead.
  private func presentBridgeAgentConversation(
    provider: String,
    animated: Bool = true,
    surfaceMode: VibeAgentConversationSurfaceMode = .transcript
  ) {
    // Idempotent for the isolated host path: if this provider's surface is already hosted, don't
    // tear it down and rebuild (that flashes and re-runs the slide).
    if onHostBridgeAgentView != nil, hostedBridgeAgentProvider?() == provider,
      hostedBridgeAgentSurfaceMode?() == surfaceMode
    {
      return
    }
    let displayName = provider.capitalized
    let initialMessages = VibeAgentKitMap.messages(from: rows)
    let vc = VibeAgentConversationViewController(
      title: displayName,
      subtitle: "",
      messages: initialMessages,
      inputPlaceholder: "Ask \(displayName)",
      surfaceMode: surfaceMode,
      messagesProvider: { [weak self] in
        guard let self else { return [] }
        return VibeAgentKitMap.messages(from: self.rows)
      },
      onSend: { [weak self] text, _, attachments in
        self?.handleNativeSend(
          text: text,
          mentionedAgentUsername: provider,
          fromAgentSurface: true,
          agentBridgeAttachmentsEnc: attachments
        )
      }
    )
    presentedBridgeAgentVC = vc
    vc.agentBridgeProvider = provider
    // The runtime view belongs to this chat — wire its chatId so the composer's STOP
    // button (and the hold-menu Edit/revert) can reach the live bridge run.
    vc.agentBridgeChatId = engineChatId.isEmpty ? nil : engineChatId
    // Conversation identity for ask/command scoping — read live from this host so the
    // agent page tracks History picks / adopted sessions without extra plumbing.
    vc.agentBridgeAskSessionScope = { [weak self] ids in
      self?.bridgeAskSessionScope(ids) ?? (owns: false, hasIdentity: false)
    }
    vc.isHistoryPicked = !initialMessages.isEmpty
    vc.runModel = AgentBridgeSelectionStore.selectedRunOptions(provider: provider).model
    vc.deviceLabel = AgentPairingService.lastDeviceLabel
    vc.deviceConnected = AgentPairingService.lastConnected
    // Seed the header avatar identity so it renders the SAME avatar as the main chat
    // view (gradient keyed by peer/chat + the fetched push picture), not a generic glyph.
    vc.avatarTitle = displayName
    vc.avatarPeerUserId = enginePeerUserId
    vc.avatarChatId = engineChatId
    vc.avatarURI = avatarUri.isEmpty ? nil : avatarUri
    vc.hidesBottomBarWhenPushed = true
    vc.onPresentHistory = { [weak self] in
      self?.presentBridgeHistorySurface(provider: provider)
    }
    vc.onPresentProfile = { [weak self] in
      self?.onNativeEvent(["type": "headerAvatarPressed"])
    }
    vc.onNewChat = { [weak self] in
      self?.startNewBridgeSession()
    }
    vc.repoPickerMenu = agentControlMenu(provider: provider)

    // A surface opened by the Default-view=Agent setting is the DM's primary entry: Back
    // should exit straight to Home. A "See progress" drill-down (manuallyShown) is a layer
    // over the chat surface, so its Back peels back to chat. The host reads this to wire Back.
    vc.isPrimaryAgentSurface = !bridgeAgentManuallyShown

    // Preferred path: hand the VC to the owning controller, which hosts it FULL-SCREEN as
    // an isolated surface (its OWN header + full bounds — no nesting, no clipping, no
    // present/dismiss shift). embeddedInChatHost stays false so the VC draws its own header.
    if let host = onHostBridgeAgentView {
      vc.embeddedInChatHost = false
      host(vc)
      return
    }

    guard let owner = topPresentingViewController() else { return }
    if let nav = owner.navigationController {
      nav.pushViewController(vc, animated: animated)
    } else {
      let nav = UINavigationController(rootViewController: vc)
      nav.modalPresentationStyle = .fullScreen
      vc.navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: vc,
        action: #selector(VibeAgentConversationViewController.closeTapped)
      )
      owner.present(nav, animated: animated)
    }
  }

  private func presentAgentConversation(forMessageId messageId: String) {
    guard let agentIndex = rows.firstIndex(where: { $0.messageId == messageId }) else { return }
    let agentRow = rows[agentIndex]
    let sourceMessageId = agentConversationSourceId(agentRow: agentRow, agentIndex: agentIndex)
    let taskRows = agentConversationRows(forMessageId: messageId, sourceMessageId: sourceMessageId)
    let topic = agentConversationTopic(agentRow: agentRow, taskRows: taskRows)
    let subtitle = agentConversationSubtitle(agentRow: agentRow)
    let inputName = agentRow.agentName ?? agentRow.agentRuntime?.provider?.capitalized ?? "Agent"
    let mentionedAgentUsername = agentRow.agentUsername

    let vc = VibeAgentConversationViewController(
      title: topic,
      subtitle: subtitle,
      messages: VibeAgentKitMap.messages(from: taskRows),
      regeneratePrompt: agentRow.agentRegeneratePrompt ?? "",
      inputPlaceholder: "Ask \(inputName)",
      messagesProvider: { [weak self] in
        guard let self else { return [] }
        return VibeAgentKitMap.messages(
          from: self.agentConversationRows(forMessageId: messageId, sourceMessageId: sourceMessageId)
        )
      },
      onSend: { [weak self] text, _, attachments in
        self?.handleNativeSend(
          text: text,
          mentionedAgentUsername: mentionedAgentUsername,
          fromAgentSurface: true,
          agentBridgeAttachmentsEnc: attachments
        )
      }
    )
    presentedBridgeAgentVC = vc
    if let provider = agentRow.agentRuntime?.provider ?? mentionedAgentUsername ?? currentBridgeProvider {
      vc.agentBridgeProvider = provider
    }
    // The runtime view belongs to this chat — wire its chatId so the composer's STOP
    // button (and the hold-menu Edit/revert) can reach the live bridge run.
    vc.agentBridgeChatId = engineChatId.isEmpty ? nil : engineChatId
    // Conversation identity for ask/command scoping (see the other present site).
    vc.agentBridgeAskSessionScope = { [weak self] ids in
      self?.bridgeAskSessionScope(ids) ?? (owns: false, hasIdentity: false)
    }
    // Seed the header so it shows this run's real model + the connected computer.
    vc.runModel = agentRow.agentRuntime?.model
    vc.deviceLabel = AgentPairingService.lastDeviceLabel
    vc.deviceConnected = AgentPairingService.lastConnected
    // Match the main chat view's avatar (gradient + fetched picture) in the header.
    vc.avatarTitle = agentRow.agentName ?? inputName
    vc.avatarPeerUserId = enginePeerUserId
    vc.avatarChatId = engineChatId
    vc.avatarURI = avatarUri.isEmpty ? nil : avatarUri
    // Hide any host tab bar while pushed so the composer reaches the true bottom
    // edge (no tab-bar strip/edge under the input).
    vc.hidesBottomBarWhenPushed = true

    guard let owner = topPresentingViewController() else { return }
    if let nav = owner.navigationController {
      nav.pushViewController(vc, animated: true)
    } else {
      let nav = UINavigationController(rootViewController: vc)
      nav.modalPresentationStyle = .fullScreen
      vc.navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: vc,
        action: #selector(VibeAgentConversationViewController.closeTapped)
      )
      owner.present(nav, animated: true)
    }
  }

  private func agentConversationRows(forMessageId messageId: String, sourceMessageId: String? = nil) -> [ChatListRow] {
    let agentIndex = rows.firstIndex(where: { $0.messageId == messageId })
    let agentRow = agentIndex.map { rows[$0] }
    let resolvedSourceId = sourceMessageId ?? agentRow.flatMap {
      agentConversationSourceId(agentRow: $0, agentIndex: agentIndex ?? 0)
    }
    var taskRows: [ChatListRow] = []
    if let sourceId = resolvedSourceId, !sourceId.isEmpty,
       let promptRow = rows.first(where: { $0.messageId == sourceId }) {
      taskRows.append(promptRow)
    } else if let agentIndex, agentIndex > 0 {
      for i in stride(from: agentIndex - 1, through: 0, by: -1) {
        let candidate = rows[i]
        guard case .message = candidate.kind else { continue }
        if candidate.isMe && !candidate.isAgentMessage {
          taskRows.append(candidate)
          break
        }
      }
    }

    var seenKeys = Set(taskRows.map(\.key))
    for row in rows {
      guard case .message = row.kind, row.isAgentMessage else { continue }
      let rowMessageId = row.messageId ?? row.key
      let matchesTappedRow = rowMessageId == messageId
      let matchesSource =
        resolvedSourceId?.isEmpty == false
        && (row.agentActionSourceId == resolvedSourceId || row.replyToId == resolvedSourceId)
      guard matchesTappedRow || matchesSource else { continue }
      if seenKeys.insert(row.key).inserted {
        taskRows.append(row)
      }
    }

    if let agentRow, seenKeys.insert(agentRow.key).inserted {
      taskRows.append(agentRow)
    }
    return taskRows
  }

  private func agentConversationSourceId(agentRow: ChatListRow, agentIndex: Int) -> String? {
    if let sourceId = agentRow.agentActionSourceId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !sourceId.isEmpty
    {
      return sourceId
    }
    if let replyToId = agentRow.replyToId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !replyToId.isEmpty
    {
      return replyToId
    }
    guard agentIndex > 0 else { return nil }
    for i in stride(from: agentIndex - 1, through: 0, by: -1) {
      let candidate = rows[i]
      guard case .message = candidate.kind else { continue }
      if candidate.isMe && !candidate.isAgentMessage {
        return candidate.messageId
      }
    }
    return nil
  }

  private func agentConversationTopic(agentRow: ChatListRow, taskRows: [ChatListRow]) -> String {
    let candidates = [
      taskRows.first(where: { $0.isMe && !$0.isAgentMessage })?.text,
      agentRow.agentActionSourceText,
      agentRow.agentRuntime?.repoName,
      agentRow.agentName,
    ]
    for candidate in candidates {
      let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if let title = normalizedAgentConversationTitle(trimmed) {
        return title
      }
    }
    return "Agent chat"
  }

  private func normalizedAgentConversationTitle(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lower = trimmed.lowercased()
    if ["continue", "cont", "resume", "keep going", "go on", "ok", "okay", "yes"].contains(lower) {
      return nil
    }
    return trimmed.count > 80 ? String(trimmed.prefix(77)) + "..." : trimmed
  }

  private func agentConversationSubtitle(agentRow: ChatListRow) -> String {
    var parts: [String] = []
    if let repoName = agentRow.agentRuntime?.repoName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !repoName.isEmpty
    {
      parts.append(repoName)
    }
    if let provider = agentRow.agentRuntime?.provider?.trimmingCharacters(in: .whitespacesAndNewlines),
      !provider.isEmpty
    {
      parts.append(provider.capitalized)
    } else if let provider = currentBridgeProvider {
      parts.append(provider.capitalized)
    }
    return parts.joined(separator: " · ")
  }

  private func handleResolvedMediaSize(messageId: String?, mediaURL: String, size: CGSize) {
    guard size.width > 1.0, size.height > 1.0 else { return }
    let hasMatchingRow = rows.contains { row in
      if let messageId, let rowMessageId = row.messageId, rowMessageId == messageId {
        return true
      }
      return row.mediaUrl == mediaURL
    }
    guard hasMatchingRow else { return }

    flowLayout.invalidateLayout()
    collectionView.performBatchUpdates(nil)
  }

  @objc private func handleAgentStreamingTextLayoutInvalidated(_ notification: Notification) {
    // This re-layout/re-pin path exists ONLY for the dedicated agent push-to-top
    // surface (agentChatMode), where the streaming label grows in place between
    // setRows calls. In the normal chat, agent messages re-render through setRows
    // every chunk — that pipeline already owns layout AND scroll — so running this
    // handler there just races setRows and force-scrolls to the bottom on every
    // token. Bail in non-agent mode so the normal chat keeps its original behavior.
    guard agentChatMode else { return }
    guard
      let sourceView = notification.object as? UIView,
      sourceView.isDescendant(of: self)
    else {
      return
    }
    guard !isApplyingRowsUpdate else { return }
    guard !pendingStreamingTextLayoutInvalidation else { return }

    pendingStreamingTextLayoutInvalidation = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pendingStreamingTextLayoutInvalidation = false
      guard !self.isApplyingRowsUpdate else { return }

      guard self.window != nil else {
        self.flowLayout.invalidateLayout()
        return
      }

      if self.agentChatMode {
        // While the user is physically scrolling, running the full layout
        // invalidation + batch update on every streaming token competes with the
        // scroll gesture and makes it stutter (the reported "laggy" scroll). The
        // growing answer is almost always off-screen below them at that point, so
        // defer the heavy relayout and flush it once the scroll settles
        // (scrollViewDidEnd*). This keeps scrolling smooth without dropping the
        // measurement.
        if self.collectionView.isTracking || self.collectionView.isDragging
          || self.collectionView.isDecelerating
        {
          self.pendingDeferredAgentStreamingRelayout = true
          return
        }
        self.performAgentStreamingRelayout()
        return
      }

      let distanceFromBottom = self.currentDistanceFromBottom()
      let wasNearBottom = distanceFromBottom <= listBottomThreshold

      self.flowLayout.invalidateLayout()
      self.collectionView.performBatchUpdates(nil) { [weak self] _ in
        guard let self else { return }
        if wasNearBottom {
          self.scrollToBottom(animated: true)
        } else {
          self.restoreStationaryDistance(distanceFromBottom)
        }
      }
    }
  }

  /// Commit the streaming answer's new self-sized height. The answer grows in place
  /// every chunk; the default `performBatchUpdates` animation re-flows the whole list
  /// on each token, which jitters/flickers the cells and visibly rocks the pinned
  /// question. Doing it WITHOUT animation makes the answer extend downward in one step
  /// and holds the question rock-steady at the top. We re-measure the text but NEVER
  /// move the offset — only keep the reserved room in sync while a pin is active so the
  /// dead space collapses as the answer fills the viewport. Once the turn ends (no pin,
  /// no reserve) we leave the offset exactly where the user/content left it.
  private func performAgentStreamingRelayout() {
    guard agentChatMode, window != nil else { return }
    UIView.performWithoutAnimation {
      self.flowLayout.invalidateLayout()
      self.collectionView.performBatchUpdates(nil) { [weak self] _ in
        guard let self else { return }
        if self.agentStreaming || self.agentPushToTopSpacer > 0 {
          self.applyAgentPin(forceOffset: false)
        }
      }
    }
  }

  /// Flush a streaming relayout that was deferred because the user was scrolling.
  /// Called when the scroll settles so the answer cell catches up to its final height.
  private func flushDeferredAgentStreamingRelayoutIfNeeded() {
    guard pendingDeferredAgentStreamingRelayout else { return }
    pendingDeferredAgentStreamingRelayout = false
    performAgentStreamingRelayout()
  }

  @objc private func handleAgentCodeBlockExpanded(_ notification: Notification) {
    guard window != nil else {
      flowLayout.invalidateLayout()
      return
    }

    let distanceFromBottom = currentDistanceFromBottom()
    flowLayout.invalidateLayout()
    collectionView.performBatchUpdates(nil) { [weak self] _ in
      self?.restoreStationaryDistance(distanceFromBottom)
    }
  }

  @objc private func handleAgentIntegrationPackOpenPanel(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let agentId = userInfo["agentId"] as? String else {
      return
    }
    onNativeEvent(["type": "openAgentPanel", "provider": agentId])
  }

  private func resolvedMediaPreviewHeaderTitle(for row: ChatListRow?) -> String {
    if row?.isMe == true {
      return "You"
    }
    let peerDisplayName = enginePeerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !peerDisplayName.isEmpty {
      return peerDisplayName
    }
    let peerUserId = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    let myUserId = engineMyUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    if !peerUserId.isEmpty,
      myUserId.isEmpty || peerUserId.caseInsensitiveCompare(myUserId) != .orderedSame
    {
      return peerUserId
    }
    return "User"
  }

  private func normalizedMediaExtension(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let ext: String
    if let url = URL(string: trimmed), !url.pathExtension.isEmpty {
      ext = url.pathExtension
    } else {
      ext = (trimmed as NSString).pathExtension
    }
    let normalized = ext.replacingOccurrences(of: ".", with: "").lowercased()
    return normalized.isEmpty ? nil : normalized
  }

  private func isVideoMediaExtension(_ value: String?) -> Bool {
    guard let ext = normalizedMediaExtension(value) else { return false }
    return ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext)
  }

  private func isAudioMediaExtension(_ value: String?) -> Bool {
    guard let ext = normalizedMediaExtension(value) else { return false }
    return ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg", "oga", "opus", "caf", "alac"]
      .contains(ext)
  }

  private func rowRepresentsVideoMedia(_ row: ChatListRow) -> Bool {
    if row.visualKind == .video || row.visualKind == .videoNote {
      return true
    }
    let candidates = [
      row.fileName,
      row.mediaUrl,
      row.localMediaUrl,
    ]
    return candidates.contains(where: isVideoMediaExtension)
  }

  private func shouldAutoDownloadRemoteMedia(for row: ChatListRow) -> Bool {
    switch row.visualKind {
    case .video, .videoNote:
      return true
    case .media:
      return row.messageType != "file"
    case .text, .voice, .sticker:
      return false
    }
  }

  private func scheduleVisibleAutoDownloads() {
    visibleAutoDownloadWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.runVisibleAutoDownloads()
    }
    visibleAutoDownloadWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: workItem)
  }

  private func runVisibleAutoDownloads() {
    visibleAutoDownloadWorkItem?.cancel()
    visibleAutoDownloadWorkItem = nil
    let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted()
    for indexPath in visibleIndexPaths where indexPath.item < rows.count {
      scheduleAutoRemoteMediaDownloadIfNeeded(for: rows[indexPath.item])
    }
  }

  private func visibleIndexPaths(for row: ChatListRow) -> [IndexPath] {
    collectionView.indexPathsForVisibleItems.filter { indexPath in
      guard indexPath.item < rows.count else { return false }
      let visibleRow = rows[indexPath.item]
      if let messageId = row.messageId, !messageId.isEmpty {
        return visibleRow.messageId == messageId
      }
      if visibleRow.key == row.key {
        return true
      }
      if let mediaURL = row.mediaUrl, !mediaURL.isEmpty {
        return visibleRow.mediaUrl == mediaURL
      }
      return false
    }
  }

  private func updateVisibleMediaDownloadState(for row: ChatListRow, reloadCell: Bool = false) {
    let targetIndexPaths = visibleIndexPaths(for: row)
    guard !targetIndexPaths.isEmpty else { return }

    if reloadCell {
      collectionView.reloadItems(at: targetIndexPaths)
      return
    }

    let state = remoteMediaDownloadState(for: row)
    for indexPath in targetIndexPaths {
      guard let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell else { continue }
      cell.applyMediaDownloadState(
        needsDownload: state.needsDownload,
        isDownloading: state.isDownloading,
        progress: state.progress
      )
    }
  }

  private func scheduleAutoRemoteMediaDownloadIfNeeded(for row: ChatListRow) {
    guard shouldAutoDownloadRemoteMedia(for: row) else {
      if rowRepresentsVideoMedia(row) {
        chatListDebugLog(
          chatListInlineVideoVerboseDebugLogs,
          "[ChatInlineVideoList] autoDownload skip=policy msgId=%@",
          row.messageId ?? "-"
        )
      }
      return
    }
    let downloadState = remoteMediaDownloadState(for: row)
    guard downloadState.needsDownload, !downloadState.isDownloading else {
      if rowRepresentsVideoMedia(row) {
        chatListDebugLog(
          chatListInlineVideoVerboseDebugLogs,
          "[ChatInlineVideoList] autoDownload skip=state msgId=%@ needsDownload=%@ downloading=%@ progress=%.3f",
          row.messageId ?? "-",
          downloadState.needsDownload ? "Y" : "N",
          downloadState.isDownloading ? "Y" : "N",
          downloadState.progress ?? -1.0
        )
      }
      return
    }
    if rowRepresentsVideoMedia(row) {
      chatListDebugLog(
        chatListInlineVideoVerboseDebugLogs,
        "[ChatInlineVideoList] autoDownload start msgId=%@ remote=%@",
        row.messageId ?? "-",
        row.mediaUrl ?? "nil"
      )
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let refreshedState = self.remoteMediaDownloadState(for: row)
      guard refreshedState.needsDownload, !refreshedState.isDownloading else { return }
      self.startRemoteMediaDownload(for: row, presentOnComplete: false)
    }
  }

  private func mediaRequiresLocalDownload(_ row: ChatListRow) -> Bool {
    let trimmedKey = resolvedMediaKey(for: row) ?? ""
    return !trimmedKey.isEmpty
  }

  private func localFileURL(from raw: String?) -> URL? {
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let parsed = URL(string: trimmed), parsed.isFileURL {
      return Self.relocatedToCurrentContainer(parsed)
    }
    if trimmed.hasPrefix("/") {
      return Self.relocatedToCurrentContainer(URL(fileURLWithPath: trimmed))
    }
    return nil
  }

  /// The app's data-container UUID changes on every reinstall/rebuild, so any
  /// absolute path we previously persisted in `localMediaUrl` (e.g.
  /// `/var/mobile/Containers/Data/Application/<OLD-UUID>/Library/Caches/...`)
  /// points at a container that no longer exists after a rebuild — the file
  /// reads as "missing" and the image renders empty. If the original path is
  /// gone but the same sandbox-relative suffix exists under the CURRENT
  /// container's home directory, return that instead so cached media survives
  /// rebuilds.
  static func relocatedToCurrentContainer(_ url: URL) -> URL {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: url.path) {
      return url
    }
    // Anchor on a sandbox-relative marker and rebuild the path against the
    // current home directory. Order matters: match the deepest marker first.
    let markers = [
      "/Library/Caches/", "/Library/Application Support/", "/Library/",
      "/Documents/", "/tmp/",
    ]
    let path = url.path
    for marker in markers {
      guard let range = path.range(of: marker) else { continue }
      let suffix = String(path[range.lowerBound...])
      let candidatePath = NSHomeDirectory() + suffix
      if fileManager.fileExists(atPath: candidatePath) {
        return URL(fileURLWithPath: candidatePath)
      }
      // First matching marker is authoritative; don't fall through to shallower ones.
      break
    }
    return url
  }

  private func localFileSize(at url: URL) -> Int64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
  }

  private func localVideoHeaderData(url: URL, maxCount: Int = 64) -> Data? {
    guard
      let handle = try? FileHandle(forReadingFrom: url),
      let headerData = try? handle.read(upToCount: maxCount)
    else {
      return nil
    }
    defer {
      try? handle.close()
    }
    return headerData
  }

  private func localVideoHeaderSummary(url: URL) -> String {
    guard let headerData = localVideoHeaderData(url: url), !headerData.isEmpty else {
      return "none"
    }
    let bytes = [UInt8](headerData.prefix(16))
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    var brand = "-"
    if headerData.count >= 12 {
      let brandData = headerData.subdata(in: 8..<12)
      brand = String(data: brandData, encoding: .ascii) ?? "-"
    }
    return "hex=\(hex) brand=\(brand)"
  }

  private func hasRecognizableLocalVideoContainerHeader(url: URL) -> Bool {
    guard let headerData = localVideoHeaderData(url: url) else { return false }
    guard headerData.count >= 12 else { return false }
    if headerData.count >= 8 {
      let ftypRange = 4..<(min(headerData.count, 32) - 3)
      if ftypRange.lowerBound < ftypRange.upperBound {
        for index in ftypRange {
          if headerData[index] == 0x66,
            headerData[index + 1] == 0x74,
            headerData[index + 2] == 0x79,
            headerData[index + 3] == 0x70
          {
            return true
          }
        }
      }
    }
    let headerPrefix = [UInt8](headerData.prefix(4))
    if headerPrefix == [0x1A, 0x45, 0xDF, 0xA3] {
      return true
    }
    return false
  }

  private func isUsableLocalVideoPreview(url: URL, logContext: String) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let byteSize = localFileSize(at: url)
    guard byteSize > 0 else { return false }
    let asset = AVURLAsset(url: url)
    if asset.isPlayable || !asset.tracks(withMediaType: .video).isEmpty {
      return true
    }
    if hasRecognizableLocalVideoContainerHeader(url: url) {
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaVideo] local accepted by header context=%@ path=%@ bytes=%lld playable=%@ header=%@",
        logContext,
        url.path,
        byteSize,
        asset.isPlayable ? "Y" : "N",
        localVideoHeaderSummary(url: url)
      )
      return true
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 640.0, height: 640.0)
    do {
      _ = try generator.copyCGImage(at: .zero, actualTime: nil)
      return true
    } catch {
      NSLog(
        "[ChatMediaVideo] local unusable context=%@ path=%@ bytes=%lld error=%@ header=%@",
        logContext,
        url.path,
        byteSize,
        error.localizedDescription,
        localVideoHeaderSummary(url: url)
      )
      return false
    }
  }

  private func usableLocalMediaURL(
    from raw: String?,
    for row: ChatListRow,
    logContext: String,
    allowVideoPlaybackFallback: Bool = false
  ) -> URL? {
    guard let localURL = localFileURL(from: raw) else { return nil }
    guard FileManager.default.fileExists(atPath: localURL.path) else {
      NSLog(
        "[ChatMediaChoice] local missing context=%@ msgId=%@ path=%@ remote=%@",
        logContext,
        row.messageId ?? "-",
        localURL.path,
        row.mediaUrl ?? "-"
      )
      return nil
    }
    if rowRepresentsVideoMedia(row) {
      if isUsableLocalVideoPreview(url: localURL, logContext: logContext) {
        return localURL
      }
      if allowVideoPlaybackFallback {
        let byteSize = localFileSize(at: localURL)
        if byteSize > 1024 {
          chatListDebugLog(
            chatListMediaVerboseDebugLogs,
            "[ChatMediaVideo] local accepted by playback fallback context=%@ path=%@ bytes=%lld",
            logContext,
            localURL.path,
            byteSize
          )
          return localURL
        }
      }
      return nil
    }
    if row.visualKind == .media && UIImage(contentsOfFile: localURL.path) == nil {
      NSLog(
        "[ChatMediaChoice] local image unusable context=%@ msgId=%@ path=%@ bytes=%lld",
        logContext,
        row.messageId ?? "-",
        localURL.path,
        localFileSize(at: localURL)
      )
      return nil
    }
    return localURL
  }

  private func validatedCachedDownloadedMediaURL(
    remoteURL: URL,
    row: ChatListRow,
    logContext: String
  ) -> URL? {
    let mediaKey = resolvedMediaKey(for: row)
    guard
      let cachedURL = cachedDownloadedMediaURL(
        remoteURL: remoteURL,
        mediaKey: mediaKey,
        fileName: row.fileName
      )
    else {
      return nil
    }
    let allowVideoPlaybackFallback =
      rowRepresentsVideoMedia(row)
      && ((mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true)
    if usableLocalMediaURL(
      from: cachedURL.absoluteString,
      for: row,
      logContext: logContext,
      allowVideoPlaybackFallback: allowVideoPlaybackFallback
    ) != nil {
      return cachedURL
    }
    let remoteKey = remoteMediaCacheKey(remoteURL: remoteURL, mediaKey: mediaKey)
    documentPreviewCacheByRemoteURL.removeValue(forKey: remoteKey)
    try? FileManager.default.removeItem(at: cachedURL)
    NSLog(
      "[ChatMediaChoice] cached invalid context=%@ msgId=%@ removed=%@ remote=%@ hasMediaKey=%@",
      logContext,
      row.messageId ?? "-",
      cachedURL.lastPathComponent,
      remoteURL.absoluteString,
      (mediaKey?.isEmpty == false) ? "Y" : "N"
    )
    return nil
  }

  private func remoteMediaCacheKey(remoteURL: URL, mediaKey: String?) -> String {
    let trimmedKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return remoteURL.absoluteString + "|" + trimmedKey
  }

  private func persistedPreviewLocalURL(
    remoteURL: URL,
    mediaKey: String?,
    fileName: String?,
    response: URLResponse? = nil,
    tempURL: URL? = nil
  ) -> URL {
    let fileManager = FileManager.default
    let baseDir =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let previewDir = baseDir.appendingPathComponent("vibe-chat-preview-docs", isDirectory: true)
    try? fileManager.createDirectory(at: previewDir, withIntermediateDirectories: true)

    let preferredName =
      fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? fileName!
      : preferredDownloadFileName(remoteURL: remoteURL, response: response)
    let fallbackTempURL = tempURL ?? remoteURL
    let preferredExtension = preferredDownloadFileExtension(
      remoteURL: remoteURL,
      response: response,
      fallbackName: preferredName,
      tempURL: fallbackTempURL
    )
    let fileBaseName =
      preferredName
      .replacingOccurrences(of: "\\.[A-Za-z0-9]{1,12}$", with: "", options: .regularExpression)
    let safeBase =
      (fileBaseName.isEmpty ? "document" : fileBaseName)
      .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
    let remoteKey = remoteMediaCacheKey(remoteURL: remoteURL, mediaKey: mediaKey)
    let hashComponent = chatStableCacheHash(remoteKey)
    let destinationName =
      "\(safeBase)-\(hashComponent)\(preferredExtension.isEmpty ? "" : ".\(preferredExtension)")"
    return previewDir.appendingPathComponent(destinationName, isDirectory: false)
  }

  private func cachedDownloadedMediaURL(
    remoteURL: URL,
    mediaKey: String?,
    fileName: String?
  ) -> URL? {
    let remoteKey = remoteMediaCacheKey(remoteURL: remoteURL, mediaKey: mediaKey)
    if let cachedURL = documentPreviewCacheByRemoteURL[remoteKey],
      FileManager.default.fileExists(atPath: cachedURL.path)
    {
      return cachedURL
    }
    let persistedURL = persistedPreviewLocalURL(
      remoteURL: remoteURL,
      mediaKey: mediaKey,
      fileName: fileName
    )
    guard FileManager.default.fileExists(atPath: persistedURL.path) else {
      return nil
    }
    documentPreviewCacheByRemoteURL[remoteKey] = persistedURL
    return persistedURL
  }

  private func remoteMediaDownloadState(for row: ChatListRow) -> (
    needsDownload: Bool, isDownloading: Bool, progress: Double?
  ) {
    guard row.visualKind == .media || row.visualKind == .video || row.visualKind == .videoNote,
      let mediaURL = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
      let remoteURL = URL(string: mediaURL),
      let scheme = remoteURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      return (false, false, nil)
    }

    let mediaKey = resolvedMediaKey(for: row)
    let remoteKey = remoteMediaCacheKey(remoteURL: remoteURL, mediaKey: mediaKey)
    let shouldShowDownloadState =
      mediaRequiresLocalDownload(row)
      || shouldAutoDownloadRemoteMedia(for: row)
      || onDemandRemoteMediaDownloadKeys.contains(remoteKey)
    guard shouldShowDownloadState else {
      return (false, false, nil)
    }

    if usableLocalMediaURL(from: row.localMediaUrl, for: row, logContext: "download_state.local")
      != nil
    {
      return (false, false, nil)
    }

    if validatedCachedDownloadedMediaURL(
      remoteURL: remoteURL,
      row: row,
      logContext: "download_state.cached"
    ) != nil
    {
      return (false, false, nil)
    }

    let state = (
      true,
      documentPreviewInFlightURLs.contains(remoteKey),
      mediaDownloadProgressByRemoteKey[remoteKey]
    )
    chatListDebugLog(
      chatListMediaVerboseDebugLogs,
      "[ChatMediaDownload] state msgId=%@ needs=Y downloading=%@ progress=%.3f remote=%@ hasMediaKey=%@ localRaw=%@",
      row.messageId ?? "-",
      state.1 ? "Y" : "N",
      state.2 ?? -1.0,
      remoteURL.absoluteString,
      (mediaKey?.isEmpty == false) ? "Y" : "N",
      row.localMediaUrl ?? "nil"
    )
    return state
  }

  private func rowByApplyingLocalMediaURL(
    _ localMediaURL: String,
    toMessageId messageId: String,
    row: [String: Any]
  ) -> (changed: Bool, row: [String: Any]) {
    guard var message = row["message"] as? [String: Any],
      let currentId = (message["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      currentId == messageId
    else {
      return (false, row)
    }
    let currentLocalMediaURL =
      (message["localMediaUrl"] as? String)
      ?? (message["metadata"] as? [String: Any])?["localMediaUrl"] as? String
    if currentLocalMediaURL == localMediaURL {
      return (false, row)
    }
    message["localMediaUrl"] = localMediaURL
    var metadata = (message["metadata"] as? [String: Any]) ?? [:]
    metadata["localMediaUrl"] = localMediaURL
    message["metadata"] = metadata
    var patched = row
    patched["message"] = message
    return (true, patched)
  }

  private func cacheDownloadedMediaURL(_ localURL: URL, for row: ChatListRow) {
    guard let messageId = row.messageId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !messageId.isEmpty
    else {
      return
    }
    let localValue = localURL.absoluteString
    if !sourceRowsPayload.isEmpty {
      sourceRowsPayload = sourceRowsPayload.map { rowPayload in
        rowByApplyingLocalMediaURL(localValue, toMessageId: messageId, row: rowPayload).row
      }
    }
    if let rowPayload = nativeOutgoingRowsById[messageId] {
      nativeOutgoingRowsById[messageId] =
        rowByApplyingLocalMediaURL(localValue, toMessageId: messageId, row: rowPayload).row
    }
    if let rowPayload = nativeEngineRowsById[messageId] {
      nativeEngineRowsById[messageId] =
        rowByApplyingLocalMediaURL(localValue, toMessageId: messageId, row: rowPayload).row
    }
  }

  private func resolvedPreferredMediaURL(for row: ChatListRow) -> String? {
    if let localURL = usableLocalMediaURL(
      from: row.localMediaUrl,
      for: row,
      logContext: "resolved.local"
    ) {
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaChoice] resolved local msgId=%@ path=%@",
        row.messageId ?? "-",
        localURL.path
      )
      return localURL.absoluteString
    }
    if let remoteMediaURL = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
      let remoteURL = URL(string: remoteMediaURL),
      let scheme = remoteURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let cachedURL = validatedCachedDownloadedMediaURL(
        remoteURL: remoteURL,
        row: row,
        logContext: "resolved.cached"
      )
    {
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaChoice] resolved cached msgId=%@ path=%@ remote=%@",
        row.messageId ?? "-",
        cachedURL.path,
        remoteMediaURL
      )
      return cachedURL.absoluteString
    }
    if let remote = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty {
      let mediaKey = resolvedMediaKey(for: row)
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaChoice] resolved remote msgId=%@ remote=%@ hasMediaKey=%@",
        row.messageId ?? "-",
        remote,
        (mediaKey?.isEmpty == false) ? "Y" : "N"
      )
    }
    return row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func presentImageEditView(for row: ChatListRow, mediaURL: String, seedImage: UIImage?, sourceView: UIView? = nil) {
    guard let presenter = topPresentingViewController() else { return }
    ChatImageEditModule.presentEditor(
      from: presenter,
      sourceView: sourceView,
      messageId: row.messageId,
      mediaURL: mediaURL,
      initialImage: seedImage,
      initialCaption: row.text,
      headerTitle: resolvedMediaPreviewHeaderTitle(for: row)
    ) { [weak self] payload in
      guard let self else { return }
      var event: [String: Any] = [
        "type": payload.eventType.rawValue,
        "mediaUrl": payload.mediaURL,
      ]
      if let messageId = payload.messageId {
        event["messageId"] = messageId
      }
      if let caption = payload.caption, !caption.isEmpty {
        event["caption"] = caption
      }
      if let editedImageURL = payload.editedImageURL {
        event["editedImageUri"] = editedImageURL.absoluteString
      }
      self.onNativeEvent(event)

      if payload.eventType == .reply {
        self.showReplyBanner(for: row, fallbackText: "Photo")
      }
    }
  }

  private func showReplyBanner(for row: ChatListRow, fallbackText: String) {
    guard let inputBar = inputBar, let messageId = row.messageId else { return }
    let preview = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
    inputBar.showReplyBanner(
      messageId: messageId,
      text: preview.isEmpty ? fallbackText : preview,
      isMe: row.isMe
    )
  }

  private func startRemoteMediaDownload(for row: ChatListRow, presentOnComplete: Bool) {
    guard let mediaURL = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
      let remoteURL = URL(string: mediaURL),
      let scheme = remoteURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      return
    }

    let mediaKey = resolvedMediaKey(for: row)
    let remoteKey = remoteMediaCacheKey(remoteURL: remoteURL, mediaKey: mediaKey)
    let shouldTrackOnDemandState =
      !mediaRequiresLocalDownload(row) && presentOnComplete

    if let cachedURL = validatedCachedDownloadedMediaURL(
      remoteURL: remoteURL,
      row: row,
      logContext: "download_start.cached"
    ) {
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaDownload] reuse cached msgId=%@ remote=%@ path=%@",
        row.messageId ?? "-",
        remoteURL.absoluteString,
        cachedURL.path
      )
      cacheDownloadedMediaURL(cachedURL, for: row)
      onDemandRemoteMediaDownloadKeys.remove(remoteKey)
      updateVisibleMediaDownloadState(for: row, reloadCell: true)
      if presentOnComplete {
        openDocumentInApp(
          urlString: cachedURL.absoluteString,
          mediaKey: nil,
          fileName: row.fileName,
          row: row
        )
      }
      return
    }

    guard !documentPreviewInFlightURLs.contains(remoteKey) else { return }
    documentPreviewInFlightURLs.insert(remoteKey)
    if shouldTrackOnDemandState {
      onDemandRemoteMediaDownloadKeys.insert(remoteKey)
    }
    mediaDownloadProgressByRemoteKey[remoteKey] = 0.027
    chatListDebugLog(
      chatListMediaVerboseDebugLogs,
      "[ChatMediaDownload] start msgId=%@ remote=%@ hasMediaKey=%@ onDemand=%@ fileName=%@",
      row.messageId ?? "-",
      remoteURL.absoluteString,
      (mediaKey?.isEmpty == false) ? "Y" : "N",
      shouldTrackOnDemandState ? "Y" : "N",
      row.fileName ?? "-"
    )
    updateVisibleMediaDownloadState(for: row)

    var request = URLRequest(url: remoteURL)
    request.timeoutInterval = 60
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let authHeader = ChatEngine.shared.authorizationHeaderForAPI() {
      request.setValue(authHeader, forHTTPHeaderField: "Authorization")
    }

    let task = Self.documentPreviewSession.downloadTask(with: request) {
      [weak self] tempURL, response, error in
      guard let self else { return }
      let localURL = self.persistDownloadedDocument(
        tempURL: tempURL,
        remoteURL: remoteURL,
        response: response,
        error: error,
        mediaKey: mediaKey,
        originalFileName: row.fileName
      )
      DispatchQueue.main.async {
        self.documentPreviewInFlightURLs.remove(remoteKey)
        self.onDemandRemoteMediaDownloadKeys.remove(remoteKey)
        self.mediaDownloadObservations.removeValue(forKey: remoteKey)?.invalidate()
        self.mediaDownloadProgressByRemoteKey.removeValue(forKey: remoteKey)
        self.mediaDownloadTasks.removeValue(forKey: remoteKey)
        if let localURL,
          self.usableLocalMediaURL(
            from: localURL.absoluteString,
            for: row,
            logContext: "download_complete",
            allowVideoPlaybackFallback: self.rowRepresentsVideoMedia(row)
              && ((mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true)
          ) != nil
        {
          self.documentPreviewCacheByRemoteURL[remoteKey] = localURL
          self.cacheDownloadedMediaURL(localURL, for: row)
          self.updateVisibleMediaDownloadState(for: row, reloadCell: true)
          chatListDebugLog(
            chatListMediaVerboseDebugLogs,
            "[ChatMediaDownload] ready msgId=%@ remote=%@ local=%@ bytes=%lld",
            row.messageId ?? "-",
            remoteURL.absoluteString,
            localURL.path,
            self.localFileSize(at: localURL)
          )
          if presentOnComplete {
            self.openDocumentInApp(
              urlString: localURL.absoluteString,
              mediaKey: nil,
              fileName: row.fileName,
              row: row
            )
          }
        } else {
          if let localURL {
            NSLog(
              "[ChatMediaDownload] invalid local after download msgId=%@ remote=%@ local=%@ hasMediaKey=%@",
              row.messageId ?? "-",
              remoteURL.absoluteString,
              localURL.path,
              (mediaKey?.isEmpty == false) ? "Y" : "N"
            )
            try? FileManager.default.removeItem(at: localURL)
          }
          self.updateVisibleMediaDownloadState(for: row)
          NSLog("[ChatListView] remote media download failed url=%@", remoteURL.absoluteString)
        }
      }
    }

    mediaDownloadObservations[remoteKey] = task.progress.observe(
      \.fractionCompleted,
      options: [.initial, .new]
    ) { [weak self] progress, _ in
      guard let self else { return }
      let value = max(0.027, min(1.0, progress.fractionCompleted))
      DispatchQueue.main.async {
        let previous = self.mediaDownloadProgressByRemoteKey[remoteKey] ?? 0.0
        if abs(previous - value) < 0.01 {
          return
        }
        self.mediaDownloadProgressByRemoteKey[remoteKey] = value
        self.updateVisibleMediaDownloadState(for: row)
      }
    }
    mediaDownloadTasks[remoteKey] = task
    task.resume()
  }

  private func openDocumentInApp(row: ChatListRow) {
    // Stream unencrypted remote audio directly via AVPlayer.
    // AVPlayer performs progressive HTTP buffering so playback starts after the
    // first few seconds of data arrive, not after the full file is downloaded.
    let audioMediaKey = resolvedMediaKey(for: row)
    let noEncryptionKey = audioMediaKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    if noEncryptionKey,
       row.visualKind != .voice,
       let rawAudioURL = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
       isAudioAttachmentURI(rawAudioURL, fileNameHint: row.fileName),
       let remoteAudioURL = URL(string: rawAudioURL),
       ["http", "https"].contains(remoteAudioURL.scheme?.lowercased() ?? ""),
       let presenter = topPresentingViewController()
    {
      NSLog(
        "[ChatListView] streamAudio progressive msgId=%@ remote=%@",
        row.messageId ?? "-",
        remoteAudioURL.absoluteString
      )
      let player = AVPlayer(url: remoteAudioURL)
      let playerVC = AVPlayerViewController()
      playerVC.player = player
      presenter.present(playerVC, animated: true) {
        player.play()
      }
      return
    }

    let downloadState = remoteMediaDownloadState(for: row)
    if downloadState.needsDownload {
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaOpen] redirect to download msgId=%@ remote=%@ downloading=%@ progress=%.3f",
        row.messageId ?? "-",
        row.mediaUrl ?? "-",
        downloadState.isDownloading ? "Y" : "N",
        downloadState.progress ?? -1.0
      )
      startRemoteMediaDownload(for: row, presentOnComplete: true)
      return
    }
    guard let urlString = resolvedPreferredMediaURL(for: row), !urlString.isEmpty else { return }
    let mediaKey = resolvedMediaKey(for: row)
    if rowRepresentsVideoMedia(row),
      let presenter = topPresentingViewController(),
      let resolvedURL = URL(string: urlString),
      let scheme = resolvedURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      ((mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true)
    {
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaOpen] remote video streaming msgId=%@ remote=%@ header=%@",
        row.messageId ?? "-",
        resolvedURL.absoluteString,
        resolvedMediaPreviewHeaderTitle(for: row)
      )
      let asset = AVURLAsset(
        url: resolvedURL,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
      )
      ChatVideoEditModule.presentPreview(
        from: presenter,
        asset: asset,
        initialCaption: row.text,
        headerTitle: resolvedMediaPreviewHeaderTitle(for: row),
        onReply: { [weak self] in
          self?.showReplyBanner(for: row, fallbackText: "Video")
        }
      )
      return
    }
    chatListDebugLog(
      chatListMediaVerboseDebugLogs,
      "[ChatMediaOpen] open msgId=%@ resolved=%@ remote=%@ local=%@",
      row.messageId ?? "-",
      urlString,
      row.mediaUrl ?? "-",
      row.localMediaUrl ?? "-"
    )
    openDocumentInApp(
      urlString: urlString,
      mediaKey: mediaKey,
      fileName: row.fileName,
      row: row
    )
  }

  private func openDocumentInApp(
    urlString: String,
    mediaKey: String? = nil,
    fileName: String? = nil,
    row: ChatListRow? = nil
  ) {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let resolved = ChatEngine.shared.resolveURLForOpen(trimmed) ?? trimmed
    if let remoteURL = URL(string: resolved), let scheme = remoteURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    {
      let effectiveMediaKey = mediaKey ?? row.flatMap { resolvedMediaKey(for: $0) }
      openRemoteDocumentInPreview(
        remoteURL: remoteURL,
        fallbackURL: resolved,
        mediaKey: effectiveMediaKey,
        fileName: fileName,
        row: row
      )
      return
    }

    let resolvedLocalURL: URL? = {
      if let parsed = URL(string: resolved), parsed.isFileURL {
        return parsed
      }
      if resolved.hasPrefix("/") {
        return URL(fileURLWithPath: resolved)
      }
      if let decoded = resolved.removingPercentEncoding, decoded.hasPrefix("/") {
        return URL(fileURLWithPath: decoded)
      }
      return nil
    }()

    if let localURL = resolvedLocalURL {
      presentDocumentPreview(localURL: localURL, row: row)
      return
    }

    NSLog("[ChatListView] openDocumentInApp unsupported url=%@", resolved)
  }

  private func presentDocumentPreview(localURL: URL, row: ChatListRow? = nil) {
    guard let presenter = topPresentingViewController() else {
      NSLog(
        "[ChatListView] presentDocumentPreview skipped - presenter unavailable for %@",
        localURL.path)
      return
    }

    if presentVideoPreviewIfSupported(localURL: localURL, presenter: presenter, row: row) {
      return
    }

    if presentPlainTextDocumentPreviewIfSupported(localURL: localURL, presenter: presenter) {
      return
    }

    let preview = QLPreviewController()
    let dataSource = ChatListDocumentPreviewDataSource(previewURL: localURL)
    documentPreviewDataSource = dataSource
    preview.dataSource = dataSource
    presenter.present(preview, animated: true)
  }

  private func presentVideoPreviewIfSupported(
    localURL: URL,
    presenter: UIViewController,
    row: ChatListRow?
  ) -> Bool {
    let ext = localURL.pathExtension.lowercased()
    let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    guard videoExtensions.contains(ext) else { return false }
    let byteSize = localFileSize(at: localURL)
    guard byteSize > 0 else {
      NSLog(
        "[ChatListView] presentVideoPreview skipped empty local path=%@ ext=%@ bytes=%lld",
        localURL.path,
        ext,
        byteSize
      )
      return false
    }
    if !isUsableLocalVideoPreview(url: localURL, logContext: "present_video") {
      NSLog(
        "[ChatListView] presentVideoPreview continuing despite preview validation failure path=%@ ext=%@ bytes=%lld header=%@",
        localURL.path,
        ext,
        byteSize,
        localVideoHeaderSummary(url: localURL)
      )
    }

    let asset = AVURLAsset(
      url: localURL,
      options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
    )
    NSLog(
      "[ChatListView] presentVideoPreview module path=%@ ext=%@ bytes=%lld header=%@ caption=%@",
      localURL.lastPathComponent,
      ext,
      byteSize,
      localVideoHeaderSummary(url: localURL),
      row?.text ?? ""
    )
    ChatVideoEditModule.presentPreview(
      from: presenter,
      asset: asset,
      initialCaption: row?.text,
      headerTitle: resolvedMediaPreviewHeaderTitle(for: row),
      onReply: { [weak self] in
        guard let self, let row else { return }
        self.showReplyBanner(for: row, fallbackText: "Video")
      }
    )
    return true
  }

  private func openRemoteDocumentInPreview(
    remoteURL: URL,
    fallbackURL: String,
    mediaKey: String?,
    fileName: String?,
    row: ChatListRow?
  ) {
    guard topPresentingViewController() != nil else {
      NSLog(
        "[ChatListView] openRemoteDocumentInPreview skipped - presenter unavailable for %@",
        fallbackURL)
      return
    }

    let remoteKey = remoteMediaCacheKey(remoteURL: remoteURL, mediaKey: mediaKey)
    if let cachedURL = cachedDownloadedMediaURL(
      remoteURL: remoteURL,
      mediaKey: mediaKey,
      fileName: fileName
    )
    {
      presentDocumentPreview(localURL: cachedURL, row: row)
      return
    }

    guard !documentPreviewInFlightURLs.contains(remoteKey) else { return }
    documentPreviewInFlightURLs.insert(remoteKey)

    var request = URLRequest(url: remoteURL)
    request.timeoutInterval = 60
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let authHeader = ChatEngine.shared.authorizationHeaderForAPI() {
      request.setValue(authHeader, forHTTPHeaderField: "Authorization")
    }
    let task = Self.documentPreviewSession.downloadTask(with: request) {
      [weak self] tempURL, response, error in
      guard let self else { return }
      let localURL = self.persistDownloadedDocument(
        tempURL: tempURL,
        remoteURL: remoteURL,
        response: response,
        error: error,
        mediaKey: mediaKey,
        originalFileName: fileName
      )
      DispatchQueue.main.async {
        self.documentPreviewInFlightURLs.remove(remoteKey)
        if let localURL {
          self.documentPreviewCacheByRemoteURL[remoteKey] = localURL
          self.presentDocumentPreview(localURL: localURL, row: row)
          return
        }
        NSLog("[ChatListView] openRemoteDocumentInPreview failed url=%@", fallbackURL)
      }
    }
    task.resume()
  }

  private func persistDownloadedDocument(
    tempURL: URL?,
    remoteURL: URL,
    response: URLResponse?,
    error: Error?,
    mediaKey: String?,
    originalFileName: String?
  ) -> URL? {
    guard error == nil, let tempURL else { return nil }
    if let statusCode = (response as? HTTPURLResponse)?.statusCode,
      !(200...299).contains(statusCode)
    {
      return nil
    }

    let fileManager = FileManager.default
    let previewDir = fileManager.temporaryDirectory
      .appendingPathComponent("vibe-chat-preview-docs", isDirectory: true)
    do {
      try fileManager.createDirectory(at: previewDir, withIntermediateDirectories: true)
    } catch {
      return nil
    }

    let destinationURL = persistedPreviewLocalURL(
      remoteURL: remoteURL,
      mediaKey: mediaKey,
      fileName: originalFileName,
      response: response,
      tempURL: tempURL
    )

    do {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
      }
      let trimmedKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmedKey.isEmpty {
        let encryptedData = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
        guard
          let decryptedData = ChatEngine.shared.decryptMediaDataIfNeeded(
            encryptedData, mediaKey: trimmedKey),
          !decryptedData.isEmpty
        else {
          return nil
        }
        try decryptedData.write(to: destinationURL, options: [.atomic])
        try? fileManager.removeItem(at: tempURL)
      } else {
        try fileManager.moveItem(at: tempURL, to: destinationURL)
      }
      // Never cache an empty file: a 0-byte result reads back as a broken image
      // and poisons the cache until manually evicted.
      guard localFileSize(at: destinationURL) > 0 else {
        try? fileManager.removeItem(at: destinationURL)
        return nil
      }
      chatListDebugLog(
        chatListMediaVerboseDebugLogs,
        "[ChatMediaDownload] persisted remote=%@ local=%@ mime=%@ suggested=%@ bytes=%lld hasMediaKey=%@ header=%@",
        remoteURL.absoluteString,
        destinationURL.path,
        response?.mimeType ?? "nil",
        response?.suggestedFilename ?? "nil",
        localFileSize(at: destinationURL),
        trimmedKey.isEmpty ? "N" : "Y",
        localVideoHeaderSummary(url: destinationURL)
      )
      return destinationURL
    } catch {
      do {
        let trimmedKey = mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedKey.isEmpty {
          let encryptedData = try Data(contentsOf: tempURL, options: [.mappedIfSafe])
          guard
            let decryptedData = ChatEngine.shared.decryptMediaDataIfNeeded(
              encryptedData, mediaKey: trimmedKey),
            !decryptedData.isEmpty
          else {
            return nil
          }
          try decryptedData.write(to: destinationURL, options: [.atomic])
        } else {
          try fileManager.copyItem(at: tempURL, to: destinationURL)
        }
        guard localFileSize(at: destinationURL) > 0 else {
          try? fileManager.removeItem(at: destinationURL)
          return nil
        }
        chatListDebugLog(
          chatListMediaVerboseDebugLogs,
          "[ChatMediaDownload] persisted-copy remote=%@ local=%@ mime=%@ suggested=%@ bytes=%lld hasMediaKey=%@ header=%@",
          remoteURL.absoluteString,
          destinationURL.path,
          response?.mimeType ?? "nil",
          response?.suggestedFilename ?? "nil",
          localFileSize(at: destinationURL),
          trimmedKey.isEmpty ? "N" : "Y",
          localVideoHeaderSummary(url: destinationURL)
        )
        return destinationURL
      } catch {
        return nil
      }
    }
  }

  private func presentPlainTextDocumentPreviewIfSupported(
    localURL: URL,
    presenter: UIViewController
  ) -> Bool {
    let ext = localURL.pathExtension.lowercased()
    // Spreadsheet/PDF files should use native Quick Look so users get table/page previews.
    let quickLookPreferredExtensions: Set<String> = ["csv", "tsv", "xls", "xlsx", "pdf"]
    if quickLookPreferredExtensions.contains(ext) { return false }

    let textLikeExtensions: Set<String> = ["txt", "md", "markdown", "json", "log"]
    guard textLikeExtensions.contains(ext) else { return false }

    guard
      let data = try? Data(contentsOf: localURL),
      data.count <= 5_000_000
    else {
      return false
    }

    let decodedText =
      String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16)
      ?? String(data: data, encoding: .unicode)
      ?? String(data: data, encoding: .ascii)
    guard let text = decodedText else { return false }

    let title = localURL.lastPathComponent.isEmpty ? "Document" : localURL.lastPathComponent
    let controller = ChatListTextPreviewController(title: title, text: text)
    let nav = UINavigationController(rootViewController: controller)
    controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done,
      target: self,
      action: #selector(dismissPresentedPreview)
    )
    presenter.present(nav, animated: true)
    return true
  }

  @objc private func dismissPresentedPreview() {
    topPresentingViewController()?.dismiss(animated: true)
  }

  private func preferredDownloadFileName(remoteURL: URL, response: URLResponse?) -> String {
    if let http = response as? HTTPURLResponse,
      let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
      let fromHeader = parseFileNameFromContentDisposition(disposition)
    {
      return fromHeader
    }

    if let suggested = response?.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
      !suggested.isEmpty
    {
      return suggested
    }

    let urlName = remoteURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    if !urlName.isEmpty, urlName != remoteURL.host {
      return urlName
    }

    return "document"
  }

  private func preferredDownloadFileExtension(
    remoteURL: URL,
    response: URLResponse?,
    fallbackName: String,
    tempURL: URL
  ) -> String {
    let nameExtension = (fallbackName as NSString).pathExtension.lowercased()
    if !nameExtension.isEmpty { return nameExtension }

    let remoteExtension = remoteURL.pathExtension.lowercased()
    if !remoteExtension.isEmpty { return remoteExtension }

    if let mime = response?.mimeType?.lowercased() {
      switch mime {
      case "text/csv":
        return "csv"
      case "application/pdf":
        return "pdf"
      case "application/vnd.ms-excel":
        return "xls"
      case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
        return "xlsx"
      case "application/msword":
        return "doc"
      case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
        return "docx"
      case "application/vnd.ms-powerpoint":
        return "ppt"
      case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
        return "pptx"
      case "application/json":
        return "json"
      case "text/plain":
        return "txt"
      case "text/markdown":
        return "md"
      case "text/html":
        return "html"
      default:
        break
      }
    }

    return tempURL.pathExtension.lowercased()
  }

  private func parseFileNameFromContentDisposition(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let range = trimmed.range(of: "filename*=", options: .caseInsensitive) {
      let encodedPart = String(trimmed[range.upperBound...])
        .components(separatedBy: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let encodedPart, let decoded = decodeRFC5987FileName(encodedPart), !decoded.isEmpty {
        return decoded
      }
    }

    if let range = trimmed.range(of: "filename=", options: .caseInsensitive) {
      let raw = String(trimmed[range.upperBound...])
        .components(separatedBy: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let cleaned = raw?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) ?? ""
      if !cleaned.isEmpty { return cleaned }
    }
    return nil
  }

  private func decodeRFC5987FileName(_ raw: String) -> String? {
    let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    let parts = cleaned.components(separatedBy: "'")
    if parts.count >= 3 {
      let encodedName = parts[2]
      return encodedName.removingPercentEncoding ?? encodedName
    }
    return cleaned.removingPercentEncoding
  }
}

// MARK: - ChatInputBarDelegate

extension ChatListView: ChatInputBarDelegate {
  func inputBarDidRequestSelectionAction(_ action: String, payload: [String: Any]?) {
    if action == "shareOutside" {
      let selectedRows = rows.filter { selectedMessageIds.contains($0.messageId ?? "") }
      let textToShare = selectedRows.map { $0.text }.filter { !$0.isEmpty }.joined(separator: "\n\n")
      guard !textToShare.isEmpty else { return }

      let activityVC = UIActivityViewController(activityItems: [textToShare], applicationActivities: nil)
      if let popover = activityVC.popoverPresentationController {
        popover.sourceView = inputBar
        popover.sourceRect = inputBar?.bounds ?? .zero
      }

      // Find top view controller
      if let window = self.window, let rootVC = window.rootViewController {
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
          topVC = presented
        }
        topVC.present(activityVC, animated: true, completion: nil)
      }

      // Optionally clear selection after sharing
      clearMessageSelection()
      return
    }

    var event: [String: Any] = ["type": "inputActionPressed", "action": action]
    if let payload = payload {
      for (key, value) in payload {
        event[key] = value
      }
    }
    // For delete and shareInside, append the selected message IDs
    if action == "delete" || action == "shareInside" {
      event["messageIds"] = Array(selectedMessageIds)
    }
    onNativeEvent(event)

    if action == "delete" {
      clearMessageSelection()
    }
  }

  func inputBarDidSend(text: String) {
    handleNativeSend(text: text)
  }

  func inputBarDidSubmitEdit(messageId: String, text: String) {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else {
      NSLog("[ChatListView] editMessage skipped — no engineChatId (mid=%@)", messageId)
      return
    }
    let result = ChatEngine.shared.editMessage([
      "chatId": chatId,
      "messageId": messageId,
      "text": text,
    ])
    let accepted = (result["accepted"] as? Bool) ?? false
    if !accepted {
      NSLog(
        "[ChatListView] editMessage rejected mid=%@ reason=%@",
        messageId,
        (result["reason"] as? String) ?? "-"
      )
    }
  }

	  func inputBarDidRequestStopStreaming() {
	    guard (agentChatMode || currentBridgeProvider != nil), agentStreaming else { return }
	    onNativeEvent(["type": "agentStopStreaming"])
	  }

  func inputBarDidSendWithAgentMention(text: String, agentText: String) {
    handleNativeSend(text: text, agentMention: true, agentText: agentText)
  }

  func inputBarDidSendWithStandaloneAgentMention(
    text: String,
    agentText: String,
    agentUsername: String
  ) {
    handleNativeSend(
      text: text,
      agentText: agentText,
      mentionedAgentUsername: agentUsername
    )
  }

  func inputBarDidRequestVibeAgentBuilder() {
    onNativeEvent(["type": "openVibeAgentBuilder"])
  }

  func inputBarDidRequestAgentPanel() {
    onNativeEvent(["type": "openAgentPanel"])
  }

  func inputBarDidTapAttachment() {
    onNativeEvent(["type": "attachmentPressed"])
  }

  func inputBarDidTapAction() {
    onNativeEvent(["type": "inputActionPressed", "action": "mic"])
  }

  func inputBarTextDidChange(text: String) {
    if nativeSendEnabled {
      let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !chatId.isEmpty {
        let isTyping = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        DispatchQueue.global(qos: .utility).async {
          _ = ChatEngine.shared.sendTypingState([
            "chatId": chatId,
            "typing": isTyping,
          ])
        }
      }
    }
    onNativeEvent(["type": "textChanged", "text": text])
  }

  func inputBarHeightDidChange() {
    setNeedsLayout()
  }

  func inputBarRecordingStateDidChange(isRecording: Bool, isLocked: Bool, mode: String) {
    if nativeSendEnabled {
      let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !chatId.isEmpty {
        DispatchQueue.global(qos: .utility).async {
          _ = ChatEngine.shared.sendRecordingState([
            "chatId": chatId,
            "isRecording": isRecording,
            "isLocked": isLocked,
            "mode": mode,
          ])
        }
      }
    }
    onNativeEvent([
      "type": "recordingState",
      "isRecording": isRecording,
      "isLocked": isLocked,
      "mode": mode,
    ])
  }

  func inputBarRecordingDidCancel() {
    if nativeSendEnabled {
      let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !chatId.isEmpty {
        DispatchQueue.global(qos: .utility).async {
          _ = ChatEngine.shared.sendRecordingState([
            "chatId": chatId,
            "isRecording": false,
            "isLocked": false,
            "mode": "voice",
          ])
        }
      }
    }
    onNativeEvent(["type": "recordingCanceled"])
  }

  func inputBarDidRecordVoice(uri: String, duration: Double, waveform: [Double]) {
    onNativeEvent([
      "type": "attachmentVoice",
      "uri": uri,
      "duration": duration,
      "name": "voice-message.m4a",
      "waveform": waveform,
    ])
  }

  func inputBarDidRecordVideoNote(uri: String, duration: Double) {
    onNativeEvent([
      "type": "attachmentVideoNote",
      "uri": uri,
      "duration": duration,
      "name": "video-note.mov",
    ])
  }

  func inputBarDidSelectImage(
    uri: String,
    caption: String?,
    transitionCapture: ChatAttachmentTransitionCapture?
  ) {
    if nativeSendEnabled {
      handleNativeAttachmentSend(
        uri: uri,
        caption: caption,
        transitionCapture: transitionCapture
      )
      return
    }
    var payload: [String: Any] = ["type": "attachmentImage", "uri": uri]
    if let caption = caption, !caption.isEmpty {
      payload["caption"] = caption
    }
    if isVideoAttachmentURI(uri) {
      if let duration = localMediaDurationSeconds(for: uri) {
        payload["duration"] = duration
      }
      if let fileName = localAttachmentFileName(for: uri), !fileName.isEmpty {
        payload["name"] = fileName
      }
      if let thumbnailBase64 = localVideoThumbnailBase64(for: uri), !thumbnailBase64.isEmpty {
        payload["thumbnailBase64"] = thumbnailBase64
      }
      // Extract natural video dimensions so the bubble sizes correctly.
      if let size = localVideoNaturalSize(for: uri) {
        payload["width"] = Int(size.width)
        payload["height"] = Int(size.height)
      }
    }
    onNativeEvent(payload)
  }

  func inputBarDidSelectImages(
    uris: [String],
    caption: String?,
    transitionCapture: ChatAttachmentTransitionCapture?
  ) {
    if nativeSendEnabled {
      handleNativeAttachmentSend(
        uris: uris,
        caption: caption,
        transitionCapture: transitionCapture
      )
      return
    }
    for (index, uri) in uris.enumerated() {
      inputBarDidSelectImage(
        uri: uri,
        caption: index == uris.count - 1 ? caption : nil,
        transitionCapture: nil
      )
    }
  }

  func inputBarDidSelectGif(
    id: String,
    url: String,
    previewUrl: String,
    width: Int,
    height: Int
  ) {
    // Prefetch the GIF into the media cache so it displays instantly
    // when the optimistic row appears.
    chatMediaPrefetch(urlString: url, animated: true)
    if previewUrl != url {
      chatMediaPrefetch(urlString: previewUrl, animated: true)
    }
    onNativeEvent([
      "type": "attachmentGif",
      "id": id,
      "url": url,
      "previewUrl": previewUrl,
      "width": width,
      "height": height,
    ])
  }

  private func isVideoAttachmentURI(_ raw: String, fileNameHint: String? = nil) -> Bool {
    isVideoMediaExtension(fileNameHint) || isVideoMediaExtension(raw)
  }

  private func isAudioAttachmentURI(_ raw: String, fileNameHint: String? = nil) -> Bool {
    isAudioMediaExtension(fileNameHint) || isAudioMediaExtension(raw)
  }

  private func localAttachmentFileURL(for raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), url.isFileURL {
      return url
    }
    if trimmed.hasPrefix("/") {
      return URL(fileURLWithPath: trimmed)
    }
    return nil
  }

  private func materializedLocalAttachmentURI(
    for raw: String,
    preferredFileName: String? = nil,
    logContext: String
  ) -> String? {
    guard let sourceURL = localAttachmentFileURL(for: raw) else { return nil }
    let normalizedURL = sourceURL.standardizedFileURL
    let normalizedPath = normalizedURL.path
    let homePath = NSHomeDirectory()
    if normalizedPath == homePath || normalizedPath.hasPrefix(homePath + "/") {
      return normalizedURL.absoluteString
    }

    let fileManager = FileManager.default
    let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let importDir = caches.appendingPathComponent("chat-local-attachments", isDirectory: true)
    do {
      try fileManager.createDirectory(at: importDir, withIntermediateDirectories: true)
    } catch {
      NSLog(
        "[ChatListView] local import create-dir failed context=%@ error=%@",
        logContext,
        error.localizedDescription
      )
      return nil
    }

    let preferredName = preferredFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceName =
      preferredName?.isEmpty == false
      ? preferredName!
      : localAttachmentFileName(for: raw) ?? normalizedURL.lastPathComponent
    let baseName = (sourceName as NSString).deletingPathExtension
    let safeBase =
      (baseName.isEmpty ? "attachment" : baseName)
      .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
    let ext = {
      let fromPreferred = (sourceName as NSString).pathExtension
      if !fromPreferred.isEmpty { return fromPreferred }
      return normalizedURL.pathExtension.isEmpty ? "dat" : normalizedURL.pathExtension
    }()
    let hashComponent = chatStableCacheHash(normalizedURL.absoluteString)
    let destinationURL = importDir
      .appendingPathComponent("\(safeBase)-\(hashComponent)", isDirectory: false)
      .appendingPathExtension(ext)

    if fileManager.fileExists(atPath: destinationURL.path) {
      return destinationURL.absoluteString
    }

    let didAccessScopedResource = normalizedURL.startAccessingSecurityScopedResource()
    defer {
      if didAccessScopedResource {
        normalizedURL.stopAccessingSecurityScopedResource()
      }
    }

    var coordinationError: NSError?
    var copyError: Error?
    let coordinator = NSFileCoordinator()
    coordinator.coordinate(readingItemAt: normalizedURL, options: [], error: &coordinationError) {
      readableURL in
      do {
        if fileManager.fileExists(atPath: destinationURL.path) {
          try fileManager.removeItem(at: destinationURL)
        }
        do {
          try fileManager.copyItem(at: readableURL, to: destinationURL)
        } catch {
          let data = try Data(contentsOf: readableURL, options: [.mappedIfSafe])
          try data.write(to: destinationURL, options: [.atomic])
        }
      } catch {
        copyError = error
      }
    }

    if let copyError {
      NSLog(
        "[ChatListView] local import failed context=%@ source=%@ error=%@",
        logContext,
        normalizedURL.path,
        copyError.localizedDescription
      )
    } else if let coordinationError {
      NSLog(
        "[ChatListView] local import coordination failed context=%@ source=%@ error=%@",
        logContext,
        normalizedURL.path,
        coordinationError.localizedDescription
      )
    }

    guard fileManager.fileExists(atPath: destinationURL.path) else {
      return nil
    }
    return destinationURL.absoluteString
  }

  private func localAttachmentFileName(for raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), !url.lastPathComponent.isEmpty {
      return url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
    }
    let pathComponent = (trimmed as NSString).lastPathComponent
    return pathComponent.isEmpty ? nil : pathComponent
  }

  private func localAttachmentFileSize(for raw: String) -> Int64? {
    guard let fileURL = localAttachmentFileURL(for: raw) else { return nil }
    guard
      let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
      let size = attrs[.size] as? NSNumber
    else {
      return nil
    }
    let bytes = size.int64Value
    return bytes > 0 ? bytes : nil
  }

  private func localMediaDurationSeconds(for raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let fileURL = localAttachmentFileURL(for: trimmed)
    guard let fileURL else { return nil }
    let duration = AVURLAsset(url: fileURL).duration.seconds
    guard duration.isFinite, duration > 0 else { return nil }
    return duration
  }

  private func localImagePixelSize(for raw: String) -> CGSize? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let fileURL = localAttachmentFileURL(for: trimmed)
    guard let fileURL else { return nil }
    if let image = UIImage(contentsOfFile: fileURL.path) {
      return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }
    return nil
  }

  /// Load a picked image from its local uri and seal it into an arte1 blob for the
  /// agent (same downscale/encrypt path the runtime composer uses). Returns nil if the
  /// file can't be read or there's no pairing key, so the caller falls back to a plain
  /// media send.
  private func sealedBridgeImageBlob(forLocalURI raw: String) -> String? {
    guard let fileURL = localAttachmentFileURL(for: raw),
      let image = UIImage(contentsOfFile: fileURL.path)
    else { return nil }
    return VibeAgentConversationViewController.sealedImageBlob(from: image)
  }

  private func localVideoThumbnailImage(for raw: String, maxDimension: CGFloat = 480.0) -> UIImage? {
    guard let fileURL = localAttachmentFileURL(for: raw) else { return nil }
    let asset = AVURLAsset(url: fileURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
    let durationSeconds = asset.duration.seconds
    let safeDuration = durationSeconds.isFinite ? max(0.0, durationSeconds) : 0.0
    let candidateTimes: [Double] = [0.0, 0.04, 0.12, 0.24, 0.5, 1.0]
      .filter { safeDuration <= 0.01 || $0 <= safeDuration }
    for seconds in candidateTimes {
      do {
        let cgImage = try generator.copyCGImage(
          at: CMTime(seconds: seconds, preferredTimescale: 600),
          actualTime: nil
        )
        return UIImage(cgImage: cgImage)
      } catch {
        continue
      }
    }
    return nil
  }

  private func localVideoThumbnailBase64(for raw: String) -> String? {
    guard let thumbnailImage = localVideoThumbnailImage(for: raw) else {
      NSLog("[ChatVideoThumb] generation failed uri=%@", raw)
      return nil
    }
    let maxDimension: CGFloat = 480.0
    let imageSize = thumbnailImage.size
    let scaleRatio = min(
      1.0,
      min(
        maxDimension / max(1.0, imageSize.width),
        maxDimension / max(1.0, imageSize.height)
      )
    )
    let targetSize = CGSize(
      width: max(1.0, floor(imageSize.width * scaleRatio)),
      height: max(1.0, floor(imageSize.height * scaleRatio))
    )
    let renderer = UIGraphicsImageRenderer(size: targetSize)
    let renderedImage = renderer.image { _ in
      thumbnailImage.draw(in: CGRect(origin: .zero, size: targetSize))
    }
    guard let jpegData = renderedImage.jpegData(compressionQuality: 0.72) else {
      NSLog("[ChatVideoThumb] jpeg encode failed uri=%@", raw)
      return nil
    }
    NSLog(
      "[ChatVideoThumb] generated uri=%@ bytes=%lu size=%@",
      raw,
      jpegData.count,
      NSCoder.string(for: CGRect(origin: .zero, size: targetSize))
    )
    return jpegData.base64EncodedString()
  }

  private func localAudioThumbnailBase64(for raw: String) -> String? {
    guard let fileURL = localAttachmentFileURL(for: raw) else { return nil }
    let asset = AVURLAsset(url: fileURL)
    let artworkData: Data? = asset.commonMetadata.first(where: { item in
      item.commonKey?.rawValue.lowercased() == "artwork"
    })?.dataValue
      ?? asset.commonMetadata.first(where: { item in
        item.commonKey?.rawValue.lowercased() == "artwork"
      })?.value as? Data
    guard let artworkData, let image = UIImage(data: artworkData) else { return nil }

    let maxDimension: CGFloat = 240.0
    let imageSize = image.size
    let scaleRatio = min(
      1.0,
      min(
        maxDimension / max(1.0, imageSize.width),
        maxDimension / max(1.0, imageSize.height)
      )
    )
    let targetSize = CGSize(
      width: max(1.0, floor(imageSize.width * scaleRatio)),
      height: max(1.0, floor(imageSize.height * scaleRatio))
    )
    let renderer = UIGraphicsImageRenderer(size: targetSize)
    let renderedImage = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: targetSize))
    }
    guard let jpegData = renderedImage.jpegData(compressionQuality: 0.72) else {
      return nil
    }
    return jpegData.base64EncodedString()
  }

  private func localVideoNaturalSize(for raw: String) -> CGSize? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let fileURL = localAttachmentFileURL(for: trimmed)
    guard let fileURL else { return nil }
    let asset = AVURLAsset(url: fileURL)
    guard let track = asset.tracks(withMediaType: .video).first else { return nil }
    let naturalSize = track.naturalSize
    // Apply the preferred transform to handle portrait videos correctly.
    let transformed = naturalSize.applying(track.preferredTransform)
    let w = abs(transformed.width)
    let h = abs(transformed.height)
    guard w > 1, h > 1 else { return nil }
    return CGSize(width: w, height: h)
  }

  func inputBarDidSelectSticker(
    stickerId: String,
    packId: String,
    bundleFileName: String?,
    emoji: String?,
    width: Int,
    height: Int
  ) {
    var payload: [String: Any] = [
      "type": "attachmentSticker",
      "stickerId": stickerId,
      "packId": packId,
      "width": width,
      "height": height,
    ]
    if let bundleFileName { payload["bundleFileName"] = bundleFileName }
    if let emoji { payload["emoji"] = emoji }
    onNativeEvent(payload)
  }

  func inputBarDidSelectFile(uri: String, name: String) {
    let effectiveURI =
      materializedLocalAttachmentURI(
        for: uri,
        preferredFileName: name,
        logContext: "document_picker"
      ) ?? uri

    if nativeSendEnabled, isAudioAttachmentURI(effectiveURI, fileNameHint: name) {
      handleNativeAudioFileSend(uri: effectiveURI, displayName: name)
      return
    }

    var payload: [String: Any] = ["type": "attachmentFile", "uri": effectiveURI, "name": name]
    if isAudioAttachmentURI(effectiveURI, fileNameHint: name) {
      if let duration = localMediaDurationSeconds(for: effectiveURI) {
        payload["duration"] = duration
      }
      if let thumbnailBase64 = localAudioThumbnailBase64(for: effectiveURI),
        !thumbnailBase64.isEmpty
      {
        payload["thumbnailBase64"] = thumbnailBase64
      }
      if let fileSize = localAttachmentFileSize(for: effectiveURI), fileSize > 0 {
        payload["fileSize"] = fileSize
      }
    }
    onNativeEvent(payload)
  }

  func inputBarDidSelectLocation(latitude: Double, longitude: Double) {
    onNativeEvent(["type": "attachmentLocation", "latitude": latitude, "longitude": longitude])
  }

  func inputBarReplyDismissed() {
    onNativeEvent(["type": "replyDismissed"])
  }

  // MARK: - Activity Overlay (Typing / Agent Progress)

  private func setupActivityOverlay() {
    activityOverlay.isUserInteractionEnabled = false
    activityOverlay.alpha = 0
    activityOverlay.clipsToBounds = true

    // Dot container holds the three animated dots
    activityDotContainer.isUserInteractionEnabled = false
    let dotSize: CGFloat = 5
    let dotSpacing: CGFloat = 4
    for (i, dot) in activityDots.enumerated() {
      dot.frame = CGRect(
        x: CGFloat(i) * (dotSize + dotSpacing), y: 0,
        width: dotSize, height: dotSize)
      dot.layer.cornerRadius = dotSize / 2
      activityDotContainer.addSubview(dot)
    }
    let dotsW = CGFloat(activityDots.count) * dotSize + CGFloat(activityDots.count - 1) * dotSpacing
    activityDotContainer.frame = CGRect(x: 10, y: 0, width: dotsW, height: dotSize)
    activityOverlay.addSubview(activityDotContainer)

    activityTextLabel.font = .systemFont(ofSize: 13, weight: .medium)
    activityTextLabel.numberOfLines = 1
    activityTextLabel.lineBreakMode = .byTruncatingTail
    activityOverlay.addSubview(activityTextLabel)

    insertSubview(activityOverlay, belowSubview: transitionOverlayHost)
  }

  private func applyActivityOverlayTheme() {
    let isDark = appearance.isDark
    activityOverlay.backgroundColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.08)
      : UIColor(white: 0.0, alpha: 0.05)
    activityOverlay.layer.cornerRadius = 14
    let dotColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.5)
      : UIColor(white: 0.0, alpha: 0.35)
    for dot in activityDots {
      dot.backgroundColor = dotColor
    }
    activityTextLabel.textColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.65)
      : UIColor(white: 0.0, alpha: 0.5)
  }

  private func layoutActivityOverlay() {
    guard activityOverlay.alpha > 0 || isPeerTyping else { return }

    let overlayH: CGFloat = 28
    let overlayMaxW = min(bounds.width - 32, 260)
    let dotSize: CGFloat = 5
    let dotSpacing: CGFloat = 4
    let dotsW = CGFloat(activityDots.count) * dotSize + CGFloat(activityDots.count - 1) * dotSpacing
    let labelX: CGFloat = 10 + dotsW + 6
    let text = activityTextLabel.text ?? ""
    let textSize = (text as NSString).size(withAttributes: [.font: activityTextLabel.font!])
    let labelW = min(ceil(textSize.width), overlayMaxW - labelX - 10)
    let overlayW = labelX + labelW + 10

    // Position dots vertically centered
    activityDotContainer.frame = CGRect(
      x: 10, y: (overlayH - dotSize) / 2, width: dotsW, height: dotSize)
    activityTextLabel.frame = CGRect(
      x: labelX, y: 0, width: labelW, height: overlayH)

    // Position overlay just above the content padding (input bar area)
    let bottomY: CGFloat
    if inputBarEnabled, let bar = activeNativeInputView {
      bottomY = bar.frame.minY - 6
    } else {
      bottomY = bounds.height - contentPaddingBottom - 6
    }
    let overlayX: CGFloat = messageHorizontalInset
    activityOverlay.frame = CGRect(
      x: overlayX, y: bottomY - overlayH,
      width: overlayW, height: overlayH)
  }

  private func showActivityOverlay(text: String) {
    applyActivityOverlayTheme()
    activityTextLabel.text = text
    layoutActivityOverlay()
    startDotPulseAnimation()

    guard activityOverlay.alpha < 1.0 else {
      // Already visible — just update text + layout
      UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
        self.layoutActivityOverlay()
      }
      return
    }

    activityOverlay.transform = CGAffineTransform(translationX: 0, y: 8)
    UIView.animate(
      withDuration: 0.25, delay: 0,
      usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
      options: .curveEaseOut
    ) {
      self.activityOverlay.alpha = 1.0
      self.activityOverlay.transform = .identity
    }
  }

  private func hideActivityOverlay() {
    guard activityOverlay.alpha > 0 else { return }
    UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn) {
      self.activityOverlay.alpha = 0
      self.activityOverlay.transform = CGAffineTransform(translationX: 0, y: 4)
    } completion: { _ in
      self.stopDotPulseAnimation()
      self.activityOverlay.transform = .identity
    }
  }

  private func startDotPulseAnimation() {
    for (i, dot) in activityDots.enumerated() {
      dot.layer.removeAnimation(forKey: "dotPulse")
      let anim = CABasicAnimation(keyPath: "opacity")
      anim.fromValue = 0.3
      anim.toValue = 1.0
      anim.duration = 0.5
      anim.autoreverses = true
      anim.repeatCount = .infinity
      anim.beginTime = CACurrentMediaTime() + Double(i) * 0.15
      anim.isRemovedOnCompletion = false
      dot.layer.add(anim, forKey: "dotPulse")
    }
  }

  private func stopDotPulseAnimation() {
    for dot in activityDots {
      dot.layer.removeAnimation(forKey: "dotPulse")
    }
  }

  private func setPeerTyping(_ _: Bool) {
    let next = false
    if isPeerTyping == next { return }
    isPeerTyping = next
    updateActivityOverlayState()
  }

  private func updateActivityOverlayState() {
    hideActivityOverlay()
  }
}

/// Small circular avatar used by the floating group-sender overlay. Shows the member's
/// photo when there is one, otherwise a coloured initials tile in the sender's tint.
final class SenderRunAvatarView: UIView {
  private let imageView = UIImageView()
  private let initialsLabel = UILabel()
  private let gradientLayer = CAGradientLayer()
  private var loadedURL: String?
  private var loadToken = UUID()

  // Claude/Codex always have a profile image even when the group members payload omits
  // the avatar URL — resolve it from the provider so agents never fall back to a letter.
  static func agentAvatarURL(for provider: String?) -> String? {
    switch provider {
    case "claude": return "https://media.vibegram.io/chat-media/agent-profiles/claude.png"
    case "codex": return "https://media.vibegram.io/chat-media/agent-profiles/codex.png"
    default: return nil
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    isUserInteractionEnabled = false
    // Gradient tile behind the initials (matches the home-list fallback look) instead of
    // a flat fill. The photo (imageView) covers it whenever one is available.
    gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    gradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
    layer.insertSublayer(gradientLayer, at: 0)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    initialsLabel.textAlignment = .center
    initialsLabel.textColor = .white
    initialsLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    initialsLabel.adjustsFontSizeToFitWidth = true
    initialsLabel.minimumScaleFactor = 0.6
    addSubview(imageView)
    addSubview(initialsLabel)
    layer.borderWidth = 1.0 / UIScreen.main.scale
    layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.height / 2.0
    gradientLayer.frame = bounds
    imageView.frame = bounds
    initialsLabel.frame = bounds
  }

  func configure(name: String, avatarUrl: String?, tint: UIColor, provider: String?) {
    let explicitURL = avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
    // Fall back to the known agent image when the payload carried no URL (root cause of
    // Claude/Codex showing a "C" tile even though their profile images exist).
    let trimmedURL =
      (explicitURL?.isEmpty ?? true)
      ? SenderRunAvatarView.agentAvatarURL(for: provider)
      : explicitURL
    initialsLabel.text = SenderRunAvatarView.initials(from: name, provider: provider)
    // Home-style gradient behind the initials, seeded from the sender colour.
    let base = SenderRunAvatarView.tileColor(for: tint, provider: provider)
    let (top, bottom) = SenderRunAvatarView.gradientColors(base: base)
    gradientLayer.colors = [top.cgColor, bottom.cgColor]
    backgroundColor = .clear

    guard let url = trimmedURL, !url.isEmpty else {
      loadedURL = nil
      imageView.image = nil
      imageView.isHidden = true
      initialsLabel.isHidden = false
      return
    }

    if url == loadedURL, imageView.image != nil {
      imageView.isHidden = false
      initialsLabel.isHidden = true
      return
    }

    if let cached = ChatAvatarImageStore.cached(for: url) {
      loadedURL = url
      imageView.image = cached
      imageView.isHidden = false
      initialsLabel.isHidden = true
      return
    }

    // No cached image yet: show the initials tile now, swap in the photo when it lands.
    imageView.isHidden = true
    initialsLabel.isHidden = false
    let token = UUID()
    loadToken = token
    loadedURL = url
    Task { [weak self] in
      let image = await ChatAvatarImageStore.load(from: url)
      await MainActor.run {
        guard let self, self.loadToken == token, let image else { return }
        self.imageView.image = image
        self.imageView.isHidden = false
        self.initialsLabel.isHidden = true
      }
    }
  }

  private static func tileColor(for tint: UIColor, provider: String?) -> UIColor {
    if provider == "codex" { return UIColor(white: 0.32, alpha: 1.0) }
    var white: CGFloat = 0
    var alpha: CGFloat = 0
    if tint.getWhite(&white, alpha: &alpha), white > 0.82 {
      return UIColor(white: 0.4, alpha: 1.0)
    }
    return tint
  }

  /// Two shades of the base colour for the fallback gradient (slightly lighter on top,
  /// darker on the bottom) — the same soft top-down look the home list uses.
  private static func gradientColors(base: UIColor) -> (UIColor, UIColor) {
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard base.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
      return (base, base)
    }
    let top = UIColor(hue: h, saturation: s, brightness: min(1.0, b * 1.16), alpha: a)
    let bottom = UIColor(hue: h, saturation: s, brightness: max(0.0, b * 0.82), alpha: a)
    return (top, bottom)
  }

  private static func initials(from name: String, provider: String?) -> String {
    let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
    if parts.isEmpty {
      // Never a bare "?": prefer the provider name's first two letters, else nothing
      // (a clean gradient tile reads better than a question mark).
      if let provider, !provider.isEmpty { return String(provider.prefix(2)).uppercased() }
      return ""
    }
    // Single-word names (e.g. "Codex") show two letters, not one.
    if parts.count == 1 { return String(parts[0].prefix(2)).uppercased() }
    return (String(parts[0].prefix(1)) + String(parts[1].prefix(1))).uppercased()
  }
}
