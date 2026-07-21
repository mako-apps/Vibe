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

/// Always-on layout diagnostics (not gated by VIBE_VERBOSE_LOGS). Writes to
/// stderr (console attach) + Documents/layout-shift.log for pull after a run.
private func layoutShiftLog(_ format: String, _ args: CVarArg...) {
  let message = String(format: format, arguments: args)
  NSLog("%@", message)
  fputs(message + "\n", stderr)
  fflush(stderr)
  // Append to Documents so we can pull even if console isn't attached.
  let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
  let url = dir?.appendingPathComponent("layout-shift.log")
  guard let url else { return }
  let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
  if let data = line.data(using: .utf8) {
    if FileManager.default.fileExists(atPath: url.path) {
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      }
    } else {
      try? data.write(to: url)
    }
  }
}

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
private let chatListBubbleFlickerDebugLogs = false
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

/// Stable SwiftUI state for the viewport-pinned jump control. The hosting tree is created
/// once; count changes never rebuild the glass hierarchy (rebuilding/fading UIGlassEffect
/// was the source of the warped translucent plate seen on device).
/// Full-bleed host that only intercepts hits on its interactive subviews (glass chips).
private final class ChatListPassthroughOverlayView: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }
}

private final class ChatJumpToLatestModel: ObservableObject {
  @Published var unreadCount = 0
}

private struct ChatJumpToLatestControlView: View {
  @ObservedObject var model: ChatJumpToLatestModel
  let action: () -> Void

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button(action: action) {
        jumpSurface
      }
      .buttonStyle(.plain)
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .accessibilityLabel(
        model.unreadCount > 0
          ? "Jump to latest, \(model.unreadCount) new messages"
          : "Jump to latest"
      )

      if model.unreadCount > 0 {
        Text(model.unreadCount > 99 ? "99+" : "\(model.unreadCount)")
          .font(.system(size: 10.5, weight: .bold, design: .monospaced))
          .foregroundStyle(.white)
          .padding(.horizontal, 5)
          .frame(minWidth: 18, minHeight: 18)
          .background(Color.blue, in: Capsule())
          .overlay(Capsule().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
          .offset(x: 1, y: -1)
          .allowsHitTesting(false)
      }
    }
    .frame(width: 44, height: 44)
    .transaction { transaction in
      transaction.disablesAnimations = true
      transaction.animation = nil
    }
  }

  @ViewBuilder
  private var jumpSurface: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: 0) {
        Image(systemName: "chevron.down")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.primary)
          .frame(width: 36, height: 36)
          .glassEffect(.regular.interactive(true), in: .circle)
      }
      .frame(width: 44, height: 44)
    } else {
      Image(systemName: "chevron.down")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.primary)
        .frame(width: 36, height: 36)
        .background(.thinMaterial, in: Circle())
        .frame(width: 44, height: 44)
    }
  }
}

/// UIKit-owned placement with SwiftUI-owned material and interaction. Keeping the host
/// view at 44pt provides a comfortable hit target while the visible glass stays 36pt.
private final class ChatJumpToLatestHostView: UIView {
  private let model = ChatJumpToLatestModel()
  private let hostingController: UIHostingController<ChatJumpToLatestControlView>

  init(action: @escaping () -> Void) {
    hostingController = UIHostingController(
      rootView: ChatJumpToLatestControlView(
        model: model,
        action: action
      )
    )
    super.init(frame: .zero)

    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    isAccessibilityElement = false

    let hostedView = hostingController.view!
    hostedView.backgroundColor = .clear
    hostedView.isOpaque = false
    hostedView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hostedView)
    NSLayoutConstraint.activate([
      hostedView.topAnchor.constraint(equalTo: topAnchor),
      hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostedView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostedView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func setUnreadCount(_ count: Int) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      model.unreadCount = max(0, count)
    }
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
/// Presentation-layer sampling of the last cells across a send flight (see
/// startSendFlightSampler). Diagnostic-only; the reported jump is mid-animation, which
/// no settle-time log can capture.
private let chatListSendFlightSamplerEnabled = true

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
  private enum RowsAuthority {
    case incremental
    case fullSnapshot
  }
  private var pendingRowsAuthority: RowsAuthority?
  /// Row/status emissions may arrive at 60+ Hz while UIKit is tracking a fling. Applying
  /// even a same-identity snapshot in that window synchronously measures visible cells and
  /// steals a frame from the pan. Keep only the newest snapshot and apply it once scrolling
  /// settles; message ordering and the jump-to-latest unread counter update in that pass.
  private var rowsDeferredUntilScrollSettles: [[String: Any]]?
  private var rowsDeferredUntilScrollSettlesAuthority: RowsAuthority?
  private var rowsDeferredUntilScrollSettlesHistoryPrepend = false
  /// Navigation owns the main thread until the destination page has appeared. Route,
  /// engine, and warm-cache emissions are coalesced here during that interval so neither
  /// the bounded tail nor a complete cached transcript can start collection measurement
  /// inside the push animation.
  private var defersTranscriptUpdatesForPresentation = false
  /// Large transcripts always stay mounted as one stable collection. Uncached rows use
  /// the same cheap sizing as the navigation seed, then exact heights are filled during
  /// short post-presentation slices. This keeps the push free of rich-cell measurement
  /// without reintroducing a visible 16-row load/prepend every time the user scrolls up.
  private var usesProgressiveTranscriptSizing = false
  /// Preview surfaces (home hold-preview) only ever show the resting tail; their
  /// narrower bounds miss every cached height, so a full progressive sweep would
  /// re-measure the whole transcript on the main thread for nothing.
  var suppressesProgressiveHeightWarmup = false
  /// The home long-press PREVIEW list (a transient, read-only, non-scrolling card
  /// showing the resting tail). The card is narrower than the real chat (416 vs
  /// 440pt → rows 400 vs 424pt), so every persisted height — measured at the real
  /// width — MISSes on width and the whole visible tail re-measures on the MAIN
  /// thread during the hold (the per-hold lag; logged `height-promote MISS
  /// reason=w[424→400]`). When set: persisted exact-content heights are reused as
  /// close-enough estimates regardless of width, and this list NEVER writes heights
  /// to the shared on-disk store (it would clobber the real chat's true-width cache
  /// with narrow-width values). The real chat, opened for real, still measures exact.
  var isEphemeralPreview = false
  /// The first authoritative snapshot after a presentation seed is a reconciliation,
  /// never a live list mutation. Even if cache/server content differs, replace it in one
  /// disabled-actions reload instead of exposing insert/delete animations or offset churn.
  private var pendingPresentationSeedReconcile = false
  /// Starts transcript windowing for that same reconciliation. The mounted seed normally
  /// contains 16 rows, so using the old `rows.count <= largeTranscriptThreshold` proxy
  /// incorrectly parsed and measured the complete transcript immediately after the push.
  private var pendingPresentationSeedWindowStart = false
  /// Commit-first push: a seed computed while this view is detached (engine bind runs
  /// before pushViewController) is stashed here instead of mounting. Mounting pre-attach
  /// makes UIKit materialize every visible cell synchronously before the transition's
  /// first frame — the measured 114-547ms of dead screen between tap and slide — and
  /// measures bubbles at detached-view width (no safe area), poisoning the height cache
  /// (w[365→385] promote misses). didMoveToWindow mounts the stash one runloop tick
  /// after the first frame commits; the slide starts instantly and content joins it
  /// mid-flight, animated by the render server regardless of this main-thread work.
  private var deferredPresentationSeedSourceRows: [[String: Any]]? = nil
  private var deferredPresentationSeedPreferredRows: [ChatListRow]? = nil
  private var deferredPresentationSeedStashedAt: TimeInterval = 0
  /// Frame-1 content for reopens: a bitmap of the transcript captured when the chat
  /// was last closed, shown in the otherwise-empty shell the commit-first push
  /// presents, then crossfaded out once the deferred seed mounts. Memory-only by
  /// design — transcripts are E2E plaintext once rendered, so they must never be
  /// written to disk as images. Keyed by chatId|width|theme; capture is skipped when
  /// the user left the chat scrolled away from the bottom (the mount lands at the
  /// bottom, and a mismatched overlay would visibly jump at swap).
  private static let reopenSnapshotCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    // Launch prewarm inserts both theme twins for the top-3 chats (6 images); a limit
    // of 4 made the prewarm evict its own entries before the user ever opened a chat.
    cache.countLimit = 8
    return cache
  }()
  private var reopenSnapshotOverlay: UIImageView?
  private var seedLoadingIndicator: UIActivityIndicatorView?
  private var seedSpinnerGraceWorkItem: DispatchWorkItem?
  /// A cold-launched agent DM opens intentionally clean (the transcript cache is purged
  /// at launch, and auto-mounting a past session was removed for dropping an unrelated
  /// transcript in late). So on an empty 1:1 agent DM we surface ONE obvious tap to the
  /// History sheet — past work is a tap away without the fresh view ever being replaced.
  private var bridgeEmptyHistoryPromptView: UIView?
  private var bridgeEmptyHistoryPromptShowWork: DispatchWorkItem?
  /// Marks the one rows application initiated by the cached-history reveal path. That
  /// update is a strict prefix insert and must not run through the generic new-message
  /// finalize/scroll behavior while the user's finger owns the list.
  private var requestsNextHistoryRevealPrepend = false
  private var pendingRowsHistoryRevealPrepend = false
  private var sourceRowsPayload: [[String: Any]] = []
  private var allowsNextExplicitEmptyRows = false
  /// The navigation transition paints only this useful tail. Once the destination has
  /// appeared, the complete cached transcript is mounted with progressive sizing.
  private static let initialTranscriptWindow = 16
  private static let largeTranscriptThreshold = 12
  private static let warmTranscriptCacheLimit = 8
  /// Upper bound for mounting a COMPLETE cached transcript during the push when only the
  /// disk heights are warm and the in-memory parse cache is cold (see the seed's coverage
  /// gate). Keeps a pathological transcript from turning the push into a long parse.
  private static let coldFullWindowMountLimit = 400
  private struct WarmTranscriptSnapshot {
    let rows: [ChatListRow]
    let sourceRows: [[String: Any]]
    let messageHeightCache: [String: RowHeightCacheEntry]
    let agentTurnHeightCache: [String: RowHeightCacheEntry]
  }
  private static var warmTranscriptSnapshots: [String: WarmTranscriptSnapshot] = [:]
  private static var warmTranscriptSnapshotOrder: [String] = []
  /// Disk-persisted exact row heights (survive relaunch, unlike the warm snapshots
  /// above). Keyed by row key; validated against the row's content signature, width,
  /// and expand state before use, then promoted into the in-memory caches. This is
  /// what lets a cold reopen mount with exact sizing instead of estimated heights
  /// that the progressive warmup later corrects with visible offset nudges.
  private struct PersistedHeightEntry: Codable {
    let w: Double
    let s: String
    let h: Double
    let v: String
    let sig: String
    /// Per-field short hashes of the content signature (agent-turn rows only, else
    /// nil), so a `reason=sig` miss can diff element-wise and NAME the field that
    /// flipped between measure-time and reopen instead of guessing. Optional →
    /// old on-disk entries decode fine.
    let f: [String]?
  }
  private var persistedHeightsByKey: [String: PersistedHeightEntry] = [:]
  /// Per-open cap on `height-promote MISS` diagnostics (reset at heights restore).
  private var persistedHeightMissLogBudget = 0
  private var persistedHeightsChatId = ""
  private var persistedHeightsWriteWorkItem: DispatchWorkItem?
  private static let persistedHeightsWriteQueue = DispatchQueue(
    label: "vibe.chatlist.heights", qos: .utility)
  /// Last parse results keyed by row key, with the exact raw payload that produced
  /// each. A rows application reuses these whenever the incoming raw row is unchanged,
  /// so a full-transcript pass only pays ChatListRow.init (decrypt, runtime parse) for
  /// rows that actually changed — typically just the streaming one.
  private var reusableParsedRowsByKey: [String: (raw: NSDictionary, row: ChatListRow)] = [:]
  private struct PersistedViewport: Codable {
    let messageId: String?
    let screenY: Double
    let atBottom: Bool
    let savedAt: Double
    /// Session identity of the record. Scroll memory is same-run only: a reopen within
    /// this app process restores, a relaunch is a clean slate (record deleted, chat
    /// opens at the bottom / unread anchor). See loadPersistedOpeningViewport.
    var bootToken: String?
  }

  /// One value per app process — the viewport records' session identity.
  private static let viewportBootToken = UUID().uuidString
  private static let persistedViewportKeyPrefix = "vibe.ios.chat.viewport.v1"
  private var persistedOpeningViewport: PersistedViewport?
  private var openingUnreadCount = 0
  private var shouldApplyOpeningViewport = true
  private var progressiveHeightWarmupWorkItem: DispatchWorkItem?
  private var progressiveHeightWarmupKeys: [String] = []
  private var progressiveHeightWarmupGeneration: UInt64 = 0
  private var progressiveHeightWarmupStartedAt: TimeInterval = 0
  private var progressiveHeightWarmupInitialCount = 0
  private var progressiveHeightWarmupMeasuredCount = 0
  /// Uptime when this view bound to the current chat (the tap). Open-path stage logs
  /// print deltas from it so a slow open names its blocker instead of being guessed at.
  private var chatOpenStartedAt: TimeInterval = 0
  private var windowedTranscriptSourceRows: [[String: Any]]?
  private var windowedTranscriptVisibleCount = 0
  private var isRevealingOlderTranscriptRows = false
  /// Crossing the cached-history threshold only queues work while UIKit owns the pan.
  /// Performing a batch insert (even with a mathematically exact anchor correction)
  /// during drag/deceleration cancels momentum and feels like an invisible scroll lock.
  /// Consume this latch only after the gesture has fully settled.
  private var pendingHistoryRevealAfterScroll = false
  /// Engine older-history page request currently in flight for this chat.
  private var olderHistoryLoadInFlight = false
  /// Stop asking until the chat id changes once the engine reports no older pages.
  private var olderHistoryExhaustedForChat = false
  /// First row key + count captured when a load was requested. A later payload that still
  /// contains this key with new rows above it arms the strict history-reveal prepend path.
  private var olderHistoryPrependExpectedKey: String?
  private var olderHistoryPrependExpectedCount = 0
  private var olderHistoryPrependExpectedAt: TimeInterval = 0
  private var olderHistoryLoadStartedAt: TimeInterval = 0
  private var olderHistorySpinnerWorkItem: DispatchWorkItem?
  private var olderHistoryTimeoutWorkItem: DispatchWorkItem?
  /// When true, the viewport spinner is owned by an engine older-history load and must
  /// not be cleared by the dead windowed-history indicator path.
  private var olderHistorySpinnerVisible = false
  private static let olderHistoryTriggerOffsetY: CGFloat = 600.0
  private static let olderHistorySpinnerDelay: TimeInterval = 0.15
  private static let olderHistoryLoadTimeout: TimeInterval = 10.0
  private static let olderHistoryExpectationTTL: TimeInterval = 15.0
  /// A compact viewport-pinned arc communicates cached-history progress without changing
  /// collection insets (and therefore without interfering with the active pan/anchor).
  private lazy var cachedHistoryPullIndicator = CachedHistoryPullIndicatorView()
  private var cachedHistoryPullIndicatorInstalled = false
  private var searchQuery = ""
  private var nativeSendEnabled = false
  private var agentChatMode = false
  // When the user taps "!" on a failed agent message, its id is armed here so the
  // next composer send re-uses it (triggering a clean truncate-and-resend).
  private var editingAgentMessageId: String?
  private var agentStreaming = false
  /// After the user taps STOP, keep the composer out of stop-mode even while rows
  /// briefly still report live (cancel is in flight). Keys are per-task / per-row;
  /// cleared when those rows settle or after a short grace timeout.
  private var stopCancelRequestedKeys = Set<String>()
  /// Optimistic hide for the native Vibe AI stream (no bridge task id).
  private var stopRequestedAgentStream = false
  private var stopCancelClearWorkItem: DispatchWorkItem?
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
  // user expanded via the double-chevron control — see the shared tall-content rule in
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
    /// Extra fingerprint for agent turns (progress/text growth). Empty for plain bubbles.
    let contentVersion: String
    init(
      row: ChatListRow,
      rowWidth: CGFloat,
      state: AgentTurnBubbleState,
      height: CGFloat,
      contentVersion: String = ""
    ) {
      self.row = row
      self.rowWidth = rowWidth
      self.state = state
      self.height = height
      self.contentVersion = contentVersion
    }
  }
  private var agentTurnHeightCache: [String: RowHeightCacheEntry] = [:]
  // Same memoization for ordinary message rows. Their height is an
  // NSAttributedString.boundingRect measurement that was recomputed from scratch on every
  // layout pass — and one chat open drives several full passes (deferred-rows flush, the
  // forced subtree layout before setRows, the initial bottom-scroll double pass, the
  // wallpaper-snapshot relayout). For a 120-row transcript that meant measuring 120 bubbles
  // several times over on the main thread during the push — the bulk of the open-latency
  // hitch. Caching collapses it to one measurement per row. `tallExpanded` rides in `state`,
  // so a tall-bubble expand toggle correctly misses the cache and re-measures.
  private var messageHeightCache: [String: RowHeightCacheEntry] = [:]
  private var nativeHistoryHydrationGeneration: UInt = 0
  private var nativeOutgoingRowsById: [String: [String: Any]] = [:]
  private var nativeOutgoingOrder: [String] = []
  private var nativeEngineRowsById: [String: [String: Any]] = [:]
  /// Pipeline-v2 (stage B1): row updates arrive as engine `chatDelta` events and are
  /// applied via ONE coalesced, off-main engine read — replacing the legacy per-message
  /// path that did a synchronous engine-queue fetch per mutation on the main thread.
  private var engineDeltaRefreshInFlight = false
  private var engineDeltaRefreshPending = false
  private var nextApplyBaseIsEngineAuthoritative = false
  private var deltaStreamCoalesceWorkItem: DispatchWorkItem?
  private var lastDeltaStreamApplyAt: CFTimeInterval = 0
  private var nativeEngineOrder: [String] = []
  /// Richest row seen for a still-live logical agent turn. Bridge transports can briefly
  /// deliver an older snapshot after a newer one (for example 29 nodes -> 32 -> 29). The
  /// transcript must never regress to that poorer snapshot or create a second cell for the
  /// same task while live and history paths overlap.
  private var liveAgentTurnHighWaterByKey: [String: ChatListRow] = [:]
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
  /// Number of genuine incoming messages appended while the reader is away from the
  /// bottom. History-prefix reveals and stream-to-final identity swaps never increment it.
  private var newMessagesWhileAwayCount = 0
  /// The jump-to-latest motion is deterministic and interruptible. Keeping the animator
  /// lets a real pan take ownership without the old spring finishing underneath it.
  /// True while the jump-to-bottom native animated scroll is traveling. Cleared by its
  /// didEndScrollingAnimation, by a user grab (willBeginDragging), or by any unanimated
  /// scrollToBottom that supersedes it.
  private var isBottomGlideInFlight = false
  private lazy var jumpToBottomButton: ChatJumpToLatestHostView = {
    let view = ChatJumpToLatestHostView { [weak self] in
      self?.jumpToBottomTapped()
    }
    view.alpha = 1.0
    view.isHidden = true
    return view
  }()
  private let scrollingDateLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 12.0, weight: .semibold)
    label.textAlignment = .center
    label.textColor = .label
    label.isUserInteractionEnabled = false
    return label
  }()
  private lazy var scrollingDatePill: UIView = {
    let view = UIView()
    // Clean solid capsule (radius set in layout from the real height) — identical to the
    // in-list day separators so the header stick reads as the same element.
    view.layer.cornerCurve = .circular
    view.clipsToBounds = true
    view.isUserInteractionEnabled = false
    view.isHidden = true
    view.addSubview(self.scrollingDateLabel)
    self.scrollingDateLabel.textColor = appearance.dayTextColor
    view.backgroundColor = appearance.dayBackgroundColor
    return view
  }()
  /// Precomputed while rows are applied, so a scroll tick only does an index lookup.
  private var scrollingDateLabelsByRowKey: [String: String] = [:]
  /// Signed per-tick scroll delta — drives the sticky date pill's push direction.
  private var lastScrollDeltaY: CGFloat = 0.0
  /// Pending linger fade-out for the sticky date pill after scrolling settles.
  private var scrollingDatePillHideWorkItem: DispatchWorkItem?
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
  /// Broadcast channel (not a group chat). History loading uses bubble skeleton only here;
  /// direct + group use a clean modern arc spinner instead.
  private var isChannel: Bool = false
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
    let changed = isGroupOrChannel != value
    isGroupOrChannel = value
    // Direct chats can't be channels; clear so History loading uses the modern spinner.
    if !value { isChannel = false }
    // Cold open can land rows before the route marks the chat as a group. When the
    // flag flips true we must:
    //  1) stamp row.isGroupOrChannel so bubbleUsesAgentTurnContent stays off
    //  2) drop height caches (agent-turn vs plain bubble heights diverge)
    //  3) remeasure + redecorate so avatars don't sit under flush-left bubbles
    guard changed else { return }
    if value, !rows.isEmpty {
      rows = rows.map { row in
        var next = row
        next.isGroupOrChannel = true
        return next
      }
    } else if !value, !rows.isEmpty {
      rows = rows.map { row in
        var next = row
        next.isGroupOrChannel = false
        return next
      }
    }
    guard !rows.isEmpty else { return }
    messageHeightCache.removeAll(keepingCapacity: true)
    agentTurnHeightCache.removeAll(keepingCapacity: true)
    flowLayout.invalidateLayout()
    reconfigureVisibleMessageCells(reason: "setIsGroupOrChannel")
    if value {
      updateFloatingSenderAvatars()
    }
  }

  /// Broadcast channel vs group. Only true channels keep the chat-bubble skeleton
  /// on History load; direct + group use the modern arc spinner.
  func setIsChannel(_ value: Bool) {
    isChannel = value && isGroupOrChannel
  }

  // MARK: - Group sender identity (per-sender name label + floating avatar)

  /// One group participant, resolved from the room member list. Powers the name label
  /// + avatar shown on incoming group messages. Agents (Claude/Codex) carry a `provider`
  /// so their name renders in the brand colour (Claude ≈ orange, Codex ≈ white).
  struct GroupSenderInfo {
    let userId: String
    let name: String
    let avatarUrl: String?
    let provider: String?  // "claude" / "codex" / "grok" / nil for a human
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
  /// Host for outer tall-bubble glass expand/collapse chips (siblings of the list,
  /// not inside cells — so Liquid Glass samples the chat wallpaper cleanly).
  /// Empty areas pass touches through so the list keeps scrolling.
  private let tallToggleOverlay = ChatListPassthroughOverlayView()
  private var tallToggleViewsById: [String: ChatTallBubbleGlassToggleView] = [:]
  /// True while a tall expand/collapse height morph is animating. Scroll-tick overlay
  /// updates are suppressed for its duration: mid-morph ticks read MODEL frames (already
  /// at the final height) while the cells are still visually interpolating, so avatars
  /// and chips snapped ahead of the content. The morph animates them in-transaction and
  /// re-places them exactly at completion instead.
  private var isTallMorphInFlight = false
  /// Invalidates stale expand/collapse completions when the user taps repeatedly.
  private var tallBubbleAnimationGeneration: UInt = 0
  private var senderAvatarViews: [String: SenderRunAvatarView] = [:]
  /// Recycle the small number of viewport avatars instead of allocating/removing views as
  /// sender runs cross the screen edge during a fling.
  private var senderAvatarReusePool: [SenderRunAvatarView] = []
  /// Last logged composer-occlusion height ([AvatarPin] clamp log dedupe).
  private var lastAvatarOcclusionLogged: CGFloat = -1

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
  private static let grokAgentUserId = "33333333-3333-3333-3333-333333333333"
  private static let agyAgentUserId = "44444444-4444-4444-4444-444444444444"

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
      || next.contains { key, value in
        guard let current = groupSenderDirectory[key] else { return true }
        return current.name != value.name
          || current.avatarUrl != value.avatarUrl
          || current.provider != value.provider
      }
    groupSenderDirectory = next
    // Start member-photo work as soon as the route roster binds, before collection cells
    // ask the floating overlay to paint. Known agents get their canonical CDN image even
    // when the members payload carries only the reserved user id. The initials tile remains
    // the synchronous first-frame fallback when this is a genuinely cold network load.
    let avatarURLs = Set(next.values.compactMap { info in
      info.avatarUrl ?? SenderRunAvatarView.agentAvatarURL(for: info.provider)
    })
    for url in avatarURLs where ChatAvatarImageStore.cached(for: url) == nil {
      Task { _ = await ChatAvatarImageStore.load(from: url) }
    }
    // Group agent membership drives the repo chip on the composer — refresh it
    // when the roster lands so Claude/Codex groups get a working picker.
    updateAgentBridgeControlTitle()
    guard changed, isGroupOrChannel else { return }
    // Directory can land after the rows do — re-decorate what's on screen.
    // Use the decoration funnel (not bare reconfigureItems alone) so group
    // gutter/name are reapplied with the new directory names/avatars.
    if !rows.isEmpty {
      messageHeightCache.removeAll(keepingCapacity: true)
      flowLayout.invalidateLayout()
      reconfigureVisibleMessageCells(reason: "setGroupSenderDirectory")
    }
    updateFloatingSenderAvatars()
  }

  private func groupNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  /// Stable identity for run-grouping: an agent by its shadow-user id, a human by `from_id`.
  /// Falls back generously so a stream/final frame missing one field still reserves the
  /// group avatar gutter (prevents the "default list" flush-left bubble that overlaps
  /// the floating avatar and then jumps when metadata arrives).
  private func resolvedSenderKey(_ row: ChatListRow) -> String? {
    if row.isAgentMessage {
      if let key =
        groupNonEmpty(row.agentUserId)
        ?? groupNonEmpty(row.agentUsername)
        ?? groupNonEmpty(row.agentName)
        ?? groupNonEmpty(row.senderUserId)
      {
        return key.uppercased()
      }
      // Last resort: map known display names already stored on the row text path.
      if let provider = Self.resolveGroupSenderProvider(
        userId: row.agentUserId, name: row.agentName, username: row.agentUsername
      ) {
        return provider.uppercased()
      }
      return nil
    }
    return groupNonEmpty(row.senderUserId)?.uppercased()
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

  /// Width available for the bubble body + extra top for the sender name (first of run).
  /// Shared by `sizeForItemAt` and height-delta checks so they cannot diverge.
  private func groupMeasurementExtras(at indexPath: IndexPath) -> (
    measurementWidth: CGFloat, extraTop: CGFloat, extraLeading: CGFloat
  ) {
    let width = max(0.0, bounds.width - (messageHorizontalInset * 2.0))
    let ctx = groupCellContext(at: indexPath)
    let extraLeading = ctx.reservesGutter ? Self.groupIncomingExtraLeading : 0.0
    let extraTop = ctx.showsName ? Self.groupSenderNameHeight : 0.0
    return (max(1.0, width - extraLeading), extraTop, extraLeading)
  }

  /// Single funnel for every message-cell configure. Always reapplies group gutter /
  /// name from the current indexPath so content-reload / status / send-morph paths
  /// cannot strip decoration back to the default DM layout (avatar overlap + jump).
  private func configureMessageCell(
    _ cell: ChatListCell,
    at indexPath: IndexPath,
    row: ChatListRow,
    hiddenMessageId: String? = nil,
    skipRemoteMediaLoad: Bool = false,
    preferredLocalMediaURLOverride: String? = nil,
    selectionMode: Bool? = nil,
    selected: Bool? = nil
  ) {
    // Individual rich-cell configures are the main unattributed cost of a chat open —
    // the visible tail builds during the navigation push, and reconfigure funnels can
    // repeat the work. Log only slow passes (covers every configure call site).
    let configureStartedAt = ProcessInfo.processInfo.systemUptime
    defer {
      let configureMs = Int((ProcessInfo.processInfo.systemUptime - configureStartedAt) * 1000)
      if configureMs >= 8 {
        NSLog(
          "[CellPerf] configure %dms item=%d key=%@ agent=%@ nodes=%d chars=%d",
          configureMs, indexPath.item, String(row.key.suffix(14)),
          bubbleUsesAgentTurnContent(row) ? "Y" : "N",
          row.agentProgressNodes.count,
          (row.plainContent ?? row.text).count)
      }
    }
    // A live agent view can shrink dramatically when its stream settles. UIKit may keep
    // the old subview geometry for part of that update; clipping this one cell class keeps
    // the stale runtime card from painting over the outgoing bubble/composer below it.
    // Ordinary chat cells stay unclipped so their bubble tails and media affordances keep
    // their existing appearance.
    let clipsAgentTurn = bubbleUsesAgentTurnContent(row)
    cell.clipsToBounds = clipsAgentTurn
    cell.contentView.clipsToBounds = clipsAgentTurn
    cell.resolveDisplayStatus = { [weak self] r in
      self?.resolvedDisplayStatus(for: r)
    }
    let groupContext = groupCellContext(at: indexPath)
    let isSelected =
      selected
      ?? (row.messageId.map { selectedMessageIds.contains($0) } ?? false)
    if chatListBubbleFlickerDebugLogs, isGroupOrChannel {
      NSLog(
        "[BubbleFlicker] list.configure item=%d id=%@ isMe=%@ agent=%@ gutter=%@ name=%@ color=%@ isGroupFlag=%@",
        indexPath.item,
        row.messageId ?? row.key,
        row.isMe ? "Y" : "N",
        row.isAgentMessage ? "Y" : "N",
        groupContext.reservesGutter ? "Y" : "N",
        groupContext.senderName ?? "—",
        groupContext.senderColor.map { Self.debugUIColorHex($0) } ?? "nil",
        row.isGroupOrChannel ? "Y" : "N"
      )
    }
    cell.configure(
      row: row,
      hiddenMessageId: hiddenMessageId ?? self.hiddenMessageId,
      skipRemoteMediaLoad: skipRemoteMediaLoad,
      preferredLocalMediaURLOverride: preferredLocalMediaURLOverride,
      selectionMode: selectionMode ?? self.selectionMode,
      selected: isSelected,
      agentTurnState: agentTurnBubbleState(for: row),
      groupExtraLeading: groupContext.reservesGutter ? Self.groupIncomingExtraLeading : 0.0,
      groupSenderName: groupContext.senderName,
      groupSenderColor: groupContext.senderColor,
      groupSenderNameHeight: Self.groupSenderNameHeight
    )
  }

  private static func debugUIColorHex(_ color: UIColor) -> String {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    return String(
      format: "#%02X%02X%02X@%.2f",
      Int((r * 255).rounded()),
      Int((g * 255).rounded()),
      Int((b * 255).rounded()),
      a
    )
  }

  private func reconfigureVisibleMessageCells(reason: String) {
    guard !rows.isEmpty else { return }
    if chatListBubbleFlickerDebugLogs {
      NSLog(
        "[BubbleFlicker] list.reconfigureVisible reason=%@ visible=%d isGroup=%@ rows=%d",
        reason,
        collectionView.visibleCells.count,
        isGroupOrChannel ? "Y" : "N",
        rows.count
      )
    }
    UIView.performWithoutAnimation {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for case let cell as ChatListCell in collectionView.visibleCells {
        guard let indexPath = collectionView.indexPath(for: cell),
          indexPath.item < rows.count
        else { continue }
        let row = rows[indexPath.item]
        cell.applyAppearance(appearance)
        configureMessageCell(cell, at: indexPath, row: row)
        bindWallpaperBackdrop(to: cell)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
      }
      CATransaction.commit()
    }
    VibeDebugLog.log(
      "[GroupDecor] reconfigureVisible reason=%@ visible=%d isGroup=%@",
      reason, collectionView.visibleCells.count, isGroupOrChannel ? "Y" : "N")
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
    case "grok":
      // Grok / xAI near-black with slight blue lift.
      return UIColor(red: 0.55, green: 0.72, blue: 0.95, alpha: 1.0)
    case "agy", "antigravity":
      // Antigravity / Agy purple-blue.
      return UIColor(red: 0.62, green: 0.48, blue: 0.98, alpha: 1.0)
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
    if idLower == grokAgentUserId || idLower == "00000000-0000-0000-0000-0000000000c3"
      || hay.contains(where: { $0.contains("grok") })
    {
      return "grok"
    }
    if idLower == agyAgentUserId || idLower == "00000000-0000-0000-0000-0000000000c4"
      || hay.contains(where: { $0.contains("agy") || $0.contains("antigravity") })
    {
      return "agy"
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

    // Glass expand/collapse chips live above the list (and avatars) so they can
    // receive taps and sample the wallpaper through UIGlassEffect.
    tallToggleOverlay.backgroundColor = .clear
    tallToggleOverlay.isOpaque = false
    tallToggleOverlay.clipsToBounds = false
    tallToggleOverlay.isUserInteractionEnabled = true
    addSubview(tallToggleOverlay)

    setupBridgeEmptyHistoryPrompt()

    collectionView.backgroundColor = .clear
    collectionView.clipsToBounds = false
    collectionView.alwaysBounceVertical = true
    collectionView.showsVerticalScrollIndicator = false

    if #available(iOS 11.0, *) {
      collectionView.contentInsetAdjustmentBehavior = .never
    }

    if #available(iOS 26.0, *) {
      // Top fade is owned by ChatMainView's custom soft header mask (blur + tint).
      // Keep system soft edge only at the bottom (composer).
      collectionView.topEdgeEffect.isHidden = true
      collectionView.bottomEdgeEffect.isHidden = false
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

    // Telegram-style viewport date feedback. It is screen-fixed, non-interactive and
    // changes text without an opacity transition, so it never participates in list layout.
    addSubview(scrollingDatePill)

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
      mountDeferredPresentationSeedAfterFirstFrame()
      revalidateListRenderOnAttach()
      hydrateRowsFromNativeHistoryIfReady(trigger: "didMoveToWindow")
      presentPreferredAgentViewIfNeeded()
      prefetchBridgeHistoryIfNeeded()
      replayOutstandingAgentBridgeAskIfNeeded()
    } else {
      removeReopenSnapshotOverlay(reason: "detached", animated: false)
      removeSeedLoadingIndicator(reason: "detached")
    }
  }

  /// Commit-first push, step 2: this fires during transition setup — the same runloop
  /// tick whose commit carries the slide's first frame. Deferring the mount by exactly
  /// one tick puts the cell build AFTER that commit; the slide is render-server-driven
  /// from then on, so the 100-500ms transcript materialization no longer delays (or
  /// janks) the animation — content simply appears mid-slide, at correct in-window
  /// widths so persisted heights promote instead of re-measuring.
  private func mountDeferredPresentationSeedAfterFirstFrame() {
    guard deferredPresentationSeedSourceRows != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil,
        let sourceRows = self.deferredPresentationSeedSourceRows
      else { return }
      let preferred = self.deferredPresentationSeedPreferredRows
      self.deferredPresentationSeedSourceRows = nil
      self.deferredPresentationSeedPreferredRows = nil
      guard self.rows.isEmpty else { return }
      NSLog(
        "[ChatOpen] seed-mount POST-COMMIT chat=%@ rows=%d waitMs=%d",
        String(self.engineChatId.prefix(12)), sourceRows.count,
        Int((ProcessInfo.processInfo.systemUptime - self.deferredPresentationSeedStashedAt) * 1000))
      self.installPresentationSeedIfNeeded(
        sourceRows: sourceRows, preferredParsedRows: preferred)
      self.removeReopenSnapshotOverlay(reason: "seed-mounted", animated: false)
    }
  }

  private func reopenSnapshotKey() -> NSString? {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return nil }
    // Screen width, not collectionView width: the key must be computable at engine
    // bind (pre-layout) so the disk copy can start decoding before the first layout.
    // Theme comes from the host-driven appearance (bootstrapped from cache in init),
    // not traitCollection — a detached view's traits don't reflect dark mode yet.
    let width = Int(UIScreen.main.bounds.width.rounded())
    let theme = appearance.isDark ? "dark" : "light"
    return NSString(string: "\(chatId)|w\(width)|\(theme)")
  }

  // userInitiated, not utility: the per-open disk decode races the shell commit
  // (~30-50ms) — at utility it lost essentially every first-open race and the chat
  // showed the spinner despite a valid raster sitting on disk.
  private static let reopenSnapshotIOQueue = DispatchQueue(
    label: "vibe.reopen-snapshot.io", qos: .userInitiated)

  private static func reopenSnapshotFileURL(for key: NSString) -> URL? {
    guard
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    let dir = caches.appendingPathComponent("VibeReopenSnapshots", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = (key as String).map { ch -> Character in
      ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
    }
    return dir.appendingPathComponent(String(name) + ".jpg")
  }

  /// Called by the host as the chat leaves the screen. Rasterizing the transcript here
  /// costs a few ms once per close and buys a fully drawn first frame on the next open.
  /// The JPEG twin (same data-protection class as the plaintext SQLite message store)
  /// makes the FIRST open after a relaunch frame-1 too, not just same-session reopens.
  func captureReopenSnapshot() {
    guard window != nil, !rows.isEmpty, let key = reopenSnapshotKey() else { return }
    let size = collectionView.bounds.size
    guard size.width > 1, size.height > 1 else { return }
    let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height
    let contentBottom = collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
    // Mid-history closes are captured too: scroll memory now restores the SAME viewport
    // on the next open (RESTORE-AT-SEED), so this raster is exactly the next first
    // frame. When the next open cannot honor the record (stale/dropped), viewport LOAD
    // drops the raster with it.
    let capturedAtBottom = visibleBottom >= contentBottom - 60
    let renderer = UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: size))
    let image = renderer.image { _ in
      collectionView.drawHierarchy(
        in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
      // Floating sender avatars are siblings glued over the list, so the subtree
      // render above misses them — composite the visible ones in, or group reopens
      // show bubbles with the avatars popping in only at the live mount. Convert via
      // self (screen space), not the scroll view (content space).
      for avatarView in senderAvatarViews.values where !avatarView.isHidden {
        let frameInSelf = avatarView.convert(avatarView.bounds, to: self)
        let target = frameInSelf.offsetBy(
          dx: -collectionView.frame.minX, dy: -collectionView.frame.minY)
        guard target.intersects(CGRect(origin: .zero, size: size)) else { continue }
        avatarView.drawHierarchy(in: target, afterScreenUpdates: false)
      }
      // Same for the expand/collapse glass chips and the jump-to-bottom button —
      // both live on sibling overlays. Without them the raster covers the first
      // ~300ms WITHOUT this chrome and it pops in when the live list mounts (the
      // reported "expand button has a delay to appear" / perceived layout shift).
      for chip in tallToggleViewsById.values where !chip.isHidden {
        let frameInSelf = chip.convert(chip.bounds, to: self)
        let target = frameInSelf.offsetBy(
          dx: -collectionView.frame.minX, dy: -collectionView.frame.minY)
        guard target.intersects(CGRect(origin: .zero, size: size)) else { continue }
        chip.drawHierarchy(in: target, afterScreenUpdates: false)
      }
      if jumpToBottomButton.superview != nil, !jumpToBottomButton.isHidden {
        let frameInSelf = jumpToBottomButton.frame
        let target = frameInSelf.offsetBy(
          dx: -collectionView.frame.minX, dy: -collectionView.frame.minY)
        if target.intersects(CGRect(origin: .zero, size: size)) {
          jumpToBottomButton.drawHierarchy(in: target, afterScreenUpdates: false)
        }
      }
    }
    // A capture with no drawable content (drawHierarchy teardown race → flat frame)
    // must never poison a good raster: overlaying a flat frame for the next open's
    // first ~200-700ms IS the reported "empty chat" + image-opacity flash.
    guard let lumaRange = Self.rasterLumaRange(image), lumaRange >= 4 else {
      NSLog(
        "[ChatOpen] reopen-snapshot CAPTURE-BLANK chat=%@ luma=%d — kept previous",
        String(engineChatId.prefix(12)), Self.rasterLumaRange(image) ?? -1)
      return
    }
    Self.reopenSnapshotCache.setObject(image, forKey: key)
    if let url = Self.reopenSnapshotFileURL(for: key) {
      Self.reopenSnapshotIOQueue.async {
        guard let data = image.jpegData(compressionQuality: 0.75) else { return }
        try? data.write(
          to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      }
    }
    NSLog(
      "[ChatOpen] reopen-snapshot CAPTURE chat=%@ size=%.0fx%.0f atBottom=%@ luma=%d",
      String(engineChatId.prefix(12)), size.width, size.height,
      capturedAtBottom ? "Y" : "N", lumaRange)
  }

  /// 8×8 luminance spread of a raster — a screenful of transcript always spans more
  /// than a few luma steps; a flat frame (blank capture) spans ~0. nil = unprobeable.
  private static func rasterLumaRange(_ image: UIImage) -> Int? {
    guard let cg = image.cgImage else { return nil }
    let side = 8
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard
      let ctx = CGContext(
        data: &pixels, width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .low
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
    var minLuma = Int.max
    var maxLuma = Int.min
    for i in stride(from: 0, to: pixels.count, by: 4) {
      let luma =
        (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
      minLuma = min(minLuma, luma)
      maxLuma = max(maxLuma, luma)
    }
    guard minLuma <= maxLuma else { return nil }
    return maxLuma - minLuma
  }

  /// Kicked at engine bind (pre-push): pulls the disk twin into the memory cache so
  /// the first open after a relaunch can overlay it at first layout. Decode happens
  /// off-main; a lost race simply means no overlay for that one open.
  private func preloadReopenSnapshotFromDiskIfNeeded() {
    guard let key = reopenSnapshotKey(),
      Self.reopenSnapshotCache.object(forKey: key) == nil,
      let url = Self.reopenSnapshotFileURL(for: key)
    else { return }
    let chatId = engineChatId
    let screenScale = UIScreen.main.scale
    Self.reopenSnapshotIOQueue.async { [weak self] in
      // JPEG data carries pixels, not scale — decoding without the screen scale made
      // the image report 3x the point size, and the .bottom overlay drew it unscaled:
      // the "zoomed transcript" on the first open after a relaunch.
      guard let data = try? Data(contentsOf: url),
        let raw = UIImage(data: data, scale: screenScale)
      else { return }
      let image = raw.preparingForDisplay() ?? raw
      // Probe HERE (IO queue, off the open's critical path): a flat disk twin from an
      // older build must never reach the overlay cache — covering the mount with it is
      // the "empty chat" flash. Captures are probed before store, so disk is the only
      // unverified source.
      guard (Self.rasterLumaRange(image) ?? -1) >= 4 else {
        try? FileManager.default.removeItem(at: url)
        NSLog("[ChatOpen] reopen-snapshot DISK-BLANK dropped chat=%@", String(chatId.prefix(12)))
        return
      }
      DispatchQueue.main.async {
        guard let self, self.engineChatId == chatId else { return }
        if Self.reopenSnapshotCache.object(forKey: key) == nil {
          Self.reopenSnapshotCache.setObject(image, forKey: key)
          NSLog("[ChatOpen] reopen-snapshot DISK-HIT chat=%@", String(chatId.prefix(12)))
          // The shell may already be committed (fast push, slow disk): attach late —
          // still better than popping in with the mount.
          if self.deferredPresentationSeedSourceRows != nil, self.window != nil {
            self.installReopenSnapshotOverlayIfAvailable()
          }
        }
      }
    }
  }

  private func installReopenSnapshotOverlayIfAvailable() {
    // The raster's ONLY job is covering an empty shell. The tap-time disk decode can
    // lose the race to the seed mount — installing then would drop a stale
    // bottom-anchored screenshot on top of the LIVE transcript until the next rows
    // flush peeled it off (a full second of wrong-position cover + two extra swaps).
    guard rows.isEmpty else { return }
    guard reopenSnapshotOverlay == nil,
      let key = reopenSnapshotKey(),
      let image = Self.reopenSnapshotCache.object(forKey: key)
    else { return }
    // An unread landing scrolls to the first-unread anchor, not the captured viewport —
    // the raster would flash the wrong rows. Let the shell show instead.
    guard openingUnreadCount == 0 else { return }
    // Size sanity: a snapshot whose point width disagrees with the live list would
    // render as a zoomed/offset transcript — never show it, and drop it so the next
    // close re-captures cleanly.
    guard collectionView.frame.width <= 1.0
      || abs(image.size.width - collectionView.frame.width) < 2.0
    else {
      Self.reopenSnapshotCache.removeObject(forKey: key)
      NSLog(
        "[ChatOpen] reopen-snapshot DROP chat=%@ size=%.0fx%.0f expected-w=%.0f",
        String(engineChatId.prefix(12)), image.size.width, image.size.height,
        collectionView.frame.width)
      return
    }
    // Blank-frame safety runs OFF this path: captures are probed before store and disk
    // twins are probed in the decode callback (both off the open's critical path), so
    // every image reaching this cache is known-good. Probing here cost 83ms of main
    // thread at the push's first frame (measured decorateMs=83) — never again.
    let overlay = UIImageView(image: image)
    overlay.frame = collectionView.frame
    // Bottom-anchored: if the reopened viewport height differs slightly (banner,
    // inset settle) the newest messages stay pinned exactly like the real list.
    overlay.contentMode = .bottom
    overlay.clipsToBounds = true
    overlay.isUserInteractionEnabled = false
    insertSubview(overlay, aboveSubview: collectionView)
    reopenSnapshotOverlay = overlay
    removeSeedLoadingIndicator(reason: "raster")
    // A mid-history reopen shows a mid-history raster — the jump-to-bottom button
    // belongs on screen from this very frame (layoutSubviews keeps it above the
    // overlay). Waiting for the seed mount to place it was the "scroll-to-bottom
    // toggle has a delay to appear".
    if let viewport = persistedOpeningViewport, viewport.atBottom == false,
      openingUnreadCount == 0
    {
      setJumpButtonVisible(true)
    }
    NSLog("[ChatOpen] reopen-snapshot SHOW chat=%@", String(engineChatId.prefix(12)))
  }

  private func removeReopenSnapshotOverlay(reason: String, animated: Bool) {
    guard let overlay = reopenSnapshotOverlay else { return }
    reopenSnapshotOverlay = nil
    NSLog(
      "[ChatOpen] reopen-snapshot REMOVE chat=%@ reason=%@",
      String(engineChatId.prefix(12)), reason)
    guard animated else {
      overlay.removeFromSuperview()
      return
    }
    UIView.animate(
      withDuration: 0.15, delay: 0, options: [.beginFromCurrentState],
      animations: { overlay.alpha = 0 },
      completion: { [weak self] _ in
        overlay.removeFromSuperview()
        // The snapshot gated the empty-DM prompt; re-evaluate now that it's gone.
        self?.updateBridgeEmptyHistoryPromptVisibility()
      })
  }

  private func setupBridgeEmptyHistoryPrompt() {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.isHidden = true
    addSubview(container)
    NSLayoutConstraint.activate([
      container.centerXAnchor.constraint(equalTo: centerXAnchor),
      container.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24),
      container.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
      container.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
    ])

    let hint = UILabel()
    hint.text = "Pick up a past conversation"
    hint.font = .systemFont(ofSize: 14.0, weight: .regular)
    hint.textColor = .secondaryLabel
    hint.textAlignment = .center
    hint.numberOfLines = 2

    var config = UIButton.Configuration.gray()
    config.cornerStyle = .capsule
    config.buttonSize = .large
    config.image = UIImage(systemName: "clock.arrow.circlepath")
    config.imagePadding = 8.0
    config.title = "Recent sessions"
    config.baseForegroundColor = .label
    let button = UIButton(
      configuration: config,
      primaryAction: UIAction { [weak self] _ in self?.handleEmptyHistoryPromptTapped() })

    let stack = UIStackView(arrangedSubviews: [hint, button])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 12.0
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    bridgeEmptyHistoryPromptView = container
  }

  private func handleEmptyHistoryPromptTapped() {
    guard let provider = currentBridgeProvider, !provider.isEmpty else { return }
    presentBridgeHistorySurface(provider: provider)
  }

  /// Show the "Recent sessions" tap only on a genuinely empty 1:1 agent DM — never over a
  /// group, a loaded transcript, a history-session load, or the reopen snapshot.
  private func bridgeEmptyHistoryPromptShouldShow() -> Bool {
    currentBridgeProvider != nil
      && !isGroupOrChannel
      && rows.isEmpty
      && bridgeLoadedSessionId == nil
      && !isBridgeHistorySessionLoading()
      && reopenSnapshotOverlay == nil
  }

  private func updateBridgeEmptyHistoryPromptVisibility() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.updateBridgeEmptyHistoryPromptVisibility()
      }
      return
    }
    guard let prompt = bridgeEmptyHistoryPromptView else { return }
    bridgeEmptyHistoryPromptShowWork?.cancel()
    bridgeEmptyHistoryPromptShowWork = nil
    guard bridgeEmptyHistoryPromptShouldShow() else {
      if !prompt.isHidden { prompt.isHidden = true }
      return
    }
    // Debounce the reveal: a warm reopen is briefly empty before its cached rows land —
    // only show if the DM is STILL empty after a short settle, so it never flashes over
    // a chat that is about to paint.
    guard prompt.isHidden else {
      bringSubviewToFront(prompt)
      return
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self, let prompt = self.bridgeEmptyHistoryPromptView,
        self.bridgeEmptyHistoryPromptShouldShow()
      else { return }
      prompt.alpha = 0.0
      prompt.isHidden = false
      self.bringSubviewToFront(prompt)
      UIView.animate(withDuration: 0.2) { prompt.alpha = 1.0 }
    }
    bridgeEmptyHistoryPromptShowWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
  }

  /// Telegram-style loading affordance for a deferred open with NOTHING to show — but
  /// only when the wait is genuinely long. The typical seed mounts in 120-350ms and the
  /// tap-time raster decode lands in ~40-80ms; a spinner that appears and vanishes inside
  /// that window is itself the flicker (spinner-flash → content = two visible swaps).
  /// So arm a grace timer instead: bare wallpaper for up to `seedSpinnerGraceSeconds`,
  /// and only if NOTHING (raster or seed) has arrived by then does the spinner install.
  private static let seedSpinnerGraceSeconds: TimeInterval = 0.4

  private func installSeedLoadingIndicatorIfNeeded() {
    guard seedLoadingIndicator == nil, seedSpinnerGraceWorkItem == nil,
      reopenSnapshotOverlay == nil, rows.isEmpty
    else { return }
    let armedChatId = engineChatId
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.seedSpinnerGraceWorkItem = nil
      // Re-check at fire time: the raster or the seed usually won the race, and then
      // no spinner ever shows — that's the good path, silent by design.
      guard self.seedLoadingIndicator == nil, self.reopenSnapshotOverlay == nil,
        self.rows.isEmpty, self.window != nil, self.engineChatId == armedChatId
      else { return }
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.color =
        self.appearance.isDark
        ? UIColor(white: 1.0, alpha: 0.45) : UIColor(white: 0.0, alpha: 0.35)
      spinner.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY - 40.0)
      spinner.autoresizingMask = [
        .flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin,
      ]
      self.addSubview(spinner)
      spinner.startAnimating()
      self.seedLoadingIndicator = spinner
      NSLog("[ChatOpen] seed-spinner SHOW chat=%@ — nothing after grace", String(armedChatId.prefix(12)))
    }
    seedSpinnerGraceWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.seedSpinnerGraceSeconds, execute: work)
  }

  private func removeSeedLoadingIndicator(reason: String) {
    // A pending grace timer counts as "the spinner": cancel it so it can never fire
    // after content has arrived.
    seedSpinnerGraceWorkItem?.cancel()
    seedSpinnerGraceWorkItem = nil
    guard let spinner = seedLoadingIndicator else { return }
    seedLoadingIndicator = nil
    spinner.stopAnimating()
    spinner.removeFromSuperview()
    NSLog(
      "[ChatOpen] seed-spinner REMOVE chat=%@ reason=%@",
      String(engineChatId.prefix(12)), reason)
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
      VibeDebugLog.log(
        "[FirstMsg] attach REVALIDATE reloading — rows=%d visible=0 offset=%.0f contentH=%.0f boundsH=%.0f",
        rows.count, collectionView.contentOffset.y, contentH, boundsH)
      collectionView.reloadData()
      collectionView.layoutIfNeeded()
    } else if rows.count <= 4 {
      VibeDebugLog.log(
        "[FirstMsg] attach revalidate ok rows=%d visible=%d offset=%.0f contentH=%.0f",
        rows.count, visibleCount, collectionView.contentOffset.y, contentH)
    }
    // Stale send-morph ghost state must never survive a detach: if the morph never
    // completed (chat closed mid-send) the only message would re-render hidden.
    if activeSendTransition == nil, pendingSendTransition == nil, hiddenMessageId != nil {
      VibeDebugLog.log(
        "[FirstMsg] attach clearing stale hiddenMessageId=%@",
        String(hiddenMessageId?.prefix(12) ?? "nil"))
      hiddenMessageId = nil
      collectionView.reloadData()
    }
    // Re-attach re-creates cells but nothing re-places the overlay chrome (avatars,
    // expand chips, jump button) until the first scroll tick — place it now so the
    // re-opened frame is complete.
    updateFloatingSenderAvatars()
    updateTallBubbleGlassToggles(animatedIcons: false)
    updateJumpToBottomButtonVisibility()
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
    tallToggleOverlay.frame = bounds
    // Keep glass chips above avatars / list, below jump-to-latest and composer chrome.
    bringSubviewToFront(tallToggleOverlay)
    if jumpToBottomButton.superview != nil {
      bringSubviewToFront(jumpToBottomButton)
    }
    layoutCachedHistoryPullIndicator()
    layoutScrollingDatePill()
    layoutDebugPanel()
    updateTallBubbleGlassToggles(animatedIcons: false)

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
    layoutAgentResponseNotice()
    layoutBridgeUsageBanner()
    layoutBridgeTaskBanner()
    layoutPendingBridgeQueue()
    // History-pick loading overlay: keep frame/insets in sync with the feed (keyboard /
    // composer / header changes). Gate on the in-flight flag so we never instantiate
    // the lazy skeleton on chats that never open History.
    if bridgeHistoryLoadInFlight {
      layoutBridgeSessionLoadingOverlay()
    }

    let currentHeight = collectionView.bounds.height
    let currentWidth = collectionView.bounds.width
    lastKnownViewportHeight = currentHeight
    lastKnownViewportWidth = currentWidth
    reopenSnapshotOverlay?.frame = collectionView.frame

    if abs(previousWidth - currentWidth) > 0.5 {
      collectionView.collectionViewLayout.invalidateLayout()
    }

    if previousHeight <= 0.0 {
      let firstLayoutStartedAt = ProcessInfo.processInfo.systemUptime
      updateBottomAnchorInset()
      let firstLayoutInsetDoneAt = ProcessInfo.processInfo.systemUptime
      if shouldAutoScroll || !rows.isEmpty {
        collectionView.layoutIfNeeded()
        // First layout of the chat: land on the latest message even in agent mode.
        scrollToBottom(animated: false, force: true)
      }
      let firstLayoutScrollDoneAt = ProcessInfo.processInfo.systemUptime
      // Rows are frequently applied while this list is still 0×0 (the host defers
      // setRows to viewWillAppear/attach, but the conversation VC's view isn't sized
      // by the nav controller until this first real layout pass). A reloadData issued
      // at 0×0 builds zero cells and computes contentSize=0; the width-change
      // invalidateLayout above recomputes item metrics, but the cells were never
      // created, so the transcript can stay blank until a later touch/scroll. Force a
      // reloadData HERE — the first pass with real bounds — so the already-applied rows
      // materialize immediately as the chat appears, closing the "empty for ~1s then
      // pops in" gap.
      if rows.isEmpty {
        if deferredPresentationSeedSourceRows != nil {
          // Intentional: the shell commits empty so the slide starts instantly; the
          // stashed seed mounts on the next tick (seed-mount POST-COMMIT). If the last
          // close left a snapshot, the shell's first frame already shows the transcript.
          installReopenSnapshotOverlayIfAvailable()
          // No raster to cover the shell → deliberate loading affordance, never a bare
          // empty transcript. Replaced by the raster (late disk decode) or the seed.
          installSeedLoadingIndicatorIfNeeded()
          NSLog(
            "[ChatOpen] firstRealBounds seed-deferred chat=%@ — shell committed",
            String(engineChatId.prefix(12)))
        } else {
          // Sized but still blank — kick engine seed again (history may have landed).
          NSLog(
            "[ChatOpen] firstRealBounds EMPTY surface=%@ chat=%@ — rehydrate",
            surfaceId.isEmpty ? "<none>" : surfaceId,
            String(engineChatId.prefix(12)))
          hydrateRowsFromNativeHistoryIfReady(trigger: "firstRealBounds")
        }
      } else if collectionView.indexPathsForVisibleItems.isEmpty {
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
      } else {
        VibeDebugLog.log(
          "[ChatOpen] firstRealBounds ok surface=%@ rows=%d bounds=%.0fx%.0f visible=%d contentH=%.0f",
          surfaceId.isEmpty ? "<none>" : surfaceId, rows.count,
          collectionView.bounds.width, collectionView.bounds.height,
          collectionView.indexPathsForVisibleItems.count, collectionView.contentSize.height)
      }
      // The composer inset and initial bottom scroll above decide which sender runs are
      // actually visible. The previous avatar pass ran before both operations, so the
      // overlay stayed empty until a user scroll delivered another callback.
      updateFloatingSenderAvatars()
      if isGroupOrChannel, pendingPresentationSeedReconcile {
        NSLog(
          "[AvatarPin] first-real-layout ready visible=%d avatars=%d",
          collectionView.indexPathsForVisibleItems.count,
          senderAvatarViews.count)
        // A presentation seed commonly arrived while this view was 0×0. Give UIKit one
        // committed runloop to publish the final post-scroll attributes, then refresh once
        // more; this is the programmatic equivalent of the tiny scroll that exposed the
        // cached avatar in the reported failure.
        DispatchQueue.main.async { [weak self] in
          guard let self, self.pendingPresentationSeedReconcile else { return }
          self.collectionView.layoutIfNeeded()
          self.updateFloatingSenderAvatars()
          NSLog(
            "[AvatarPin] post-attach ready visible=%d avatars=%d",
            self.collectionView.indexPathsForVisibleItems.count,
            self.senderAvatarViews.count)
        }
      }
      let firstLayoutNow = ProcessInfo.processInfo.systemUptime
      NSLog(
        "[ChatOpen] first-layout chat=%@ insetMs=%d layoutScrollMs=%d decorateMs=%d totalMs=%d visible=%d sinceOpenMs=%d",
        String(engineChatId.prefix(12)),
        Int((firstLayoutInsetDoneAt - firstLayoutStartedAt) * 1000),
        Int((firstLayoutScrollDoneAt - firstLayoutInsetDoneAt) * 1000),
        Int((firstLayoutNow - firstLayoutScrollDoneAt) * 1000),
        Int((firstLayoutNow - firstLayoutStartedAt) * 1000),
        collectionView.indexPathsForVisibleItems.count,
        chatOpenStartedAt > 0 ? Int((firstLayoutNow - chatOpenStartedAt) * 1000) : -1)
      emitViewport(force: true)
      maybeStartPendingSendTransition()
      return
    }

    guard abs(previousHeight - currentHeight) > 0.5 else {
      updateBottomAnchorInset()
      updateFloatingSenderAvatars()
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
    updateFloatingSenderAvatars()
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
  // Outgoing message ids the user typed WHILE a History session is open. Cleared on
  // every history pick / New Chat so prior-session own-sends never leak into the
  // isolated historical view (process-lifetime `bridgeFreshOwnSentIdsByChat` alone
  // would re-surface every earlier follow-up on this DM).
  private var bridgeHistoryFollowUpSentIds: Set<String> = []

  /// Register an outgoing message id so the fresh-surface filter never hides it.
  func noteBridgeFreshOwnSentId(_ messageId: String) {
    let id = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { return }
    let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatKey.isEmpty else { return }
    Self.bridgeFreshOwnSentIdsByChat[chatKey, default: []].insert(id)
    // If a History session is currently open, also tag this id as a follow-up so
    // bridgeFreshFiltered keeps it under historical isolation.
    if bridgeLoadedSessionId != nil {
      bridgeHistoryFollowUpSentIds.insert(id)
    }
  }

  /// Load (or clear, when nil) an explicitly-picked history session into this chat
  /// surface. Re-applies the fresh-surface filter so the session's rows appear without
  /// leaking the rest of the stored transcript.
  func setBridgeLoadedSessionId(_ sessionId: String?) {
    let next = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = (next?.isEmpty == false) ? next : nil
    let changed = bridgeLoadedSessionId != resolved
    guard changed else { return }
    bridgeLoadedSessionId = resolved
    // New history pick (or clear) starts a clean follow-up window.
    bridgeHistoryFollowUpSentIds = []
    // Re-paint under the new filter. Prefer engine rows so an already-ingested
    // `bridge-<sessionId>-…` transcript is not stuck behind a stale empty payload.
    reapplyRowsAfterBridgeSessionScopeChange()
    updateBridgeEmptyHistoryPromptVisibility()
  }

  /// Whether a History session is currently scoped into this chat surface.
  func bridgeHistorySessionId() -> String? {
    bridgeLoadedSessionId
  }

  /// True while a History pick is waiting for its `bridge-<sessionId>-…` rows
  /// (custom skeleton overlay is up). Used by the chat header so it shows
  /// "Loading…" instead of the idle "Start session" default.
  func isBridgeHistorySessionLoading() -> Bool {
    bridgeHistoryLoadInFlight
  }

  /// Pull the latest engine rows (or fall back to the current payload) and re-run
  /// `setRows` so historical isolation shows the picked session immediately when its
  /// transcript is already in the store.
  private func reapplyRowsAfterBridgeSessionScopeChange() {
    let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    if chatKey.isEmpty {
      if !sourceRowsPayload.isEmpty { setRows(sourceRowsPayload) }
      return
    }
    let fallback = sourceRowsPayload
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let engineRows = ChatEngine.shared.getChatRows(["chatId": chatKey])
      DispatchQueue.main.async {
        guard let self else { return }
        guard self.engineChatId.trimmingCharacters(in: .whitespacesAndNewlines) == chatKey else {
          return
        }
        self.setRows(engineRows.isEmpty ? fallback : engineRows)
      }
    }
  }

  private func bridgeRowIsLive(_ row: ChatListRow) -> Bool {
    if row.isStreamingText { return true }
    let status = (row.status ?? "").lowercased()
    if status == "running" || status == "streaming" { return true }
    if let runtime = row.agentRuntime {
      let runtimeStatus = runtime.status.lowercased()
      if runtimeStatus == "running" || runtimeStatus == "streaming"
        || runtimeStatus == "starting" || runtimeStatus == "pending"
      {
        return true
      }
      // Bridge can advertise cancel while status is still mid-flight.
      if runtime.controls?.canCancel == true { return true }
      // Supervisor team: any under-hood worker still running counts as live.
      if runtime.teamWorkersStatus.contains(where: \.isRunning) { return true }
    }
    return false
  }

  /// Stable key for optimistic STOP suppression after a cancel is fired.
  private func liveBridgeTaskKey(for row: ChatListRow) -> String {
    if let taskId = row.agentRuntime?.taskId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !taskId.isEmpty
    {
      return "task:\(taskId)"
    }
    if let teamRunId = row.agentRuntime?.teamRunId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !teamRunId.isEmpty
    {
      return "team:\(teamRunId)"
    }
    let provider =
      (row.agentRuntime?.provider ?? currentBridgeProvider ?? "agent")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let mid = (row.messageId ?? row.key).trimmingCharacters(in: .whitespacesAndNewlines)
    return "row:\(provider):\(mid)"
  }

  /// Drop optimistic cancel markers for rows that have already settled so a
  /// brand-new run on the same provider shows STOP again.
  private func pruneStopCancelRequestedKeys(using rows: [ChatListRow]) {
    guard !stopCancelRequestedKeys.isEmpty else { return }
    let liveKeys = Set(rows.filter(bridgeRowIsLive).map(liveBridgeTaskKey))
    stopCancelRequestedKeys = stopCancelRequestedKeys.intersection(liveKeys)
  }

  /// Session id a row claims (live stream / finished agent turn). Used to keep
  /// historical isolation scoped to the resumed session when follow-ups stream in
  /// as non-`bridge-` rows that share the DM chatId with every other session.
  private func bridgeRowSessionId(_ row: ChatListRow) -> String? {
    if let sid = row.agentRuntime?.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !sid.isEmpty, !sid.hasPrefix("running:")
    {
      return sid
    }
    if let tid = row.agentRuntime?.threadId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !tid.isEmpty, !tid.hasPrefix("running:")
    {
      return tid
    }
    return nil
  }

  /// A Claude/Codex DM opens showing its persisted transcript (seeded instantly from the
  /// engine's on-disk row cache), like any other chat. Hidden rows exist only after an
  /// explicit "New Chat": startNewBridgeSession snapshots the then-visible row ids into
  /// `bridgeFreshHiddenIdsByChat`, so the deliberate fresh thread starts clean while a
  /// plain open keeps its history. Session-transcript rows (`bridge-<sessionId>-…`) are
  /// still scoped: shown only for the explicitly-loaded/live session, never leaked from
  /// other sessions.
  private func bridgeFreshFiltered(_ parsed: [ChatListRow]) -> [ChatListRow] {
    // Agent DMs always filter. Multi-agent groups only isolate when a History
    // session is explicitly loaded (bridgeLoadedSessionId) so report picks work.
    let groupHistoryIsolation = groupHasBridgeAgents() && bridgeLoadedSessionId != nil
    guard currentBridgeProvider != nil || groupHistoryIsolation else { return parsed }
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
      // they are not part of that past transcript, so suppress foreign activity to keep
      // the view isolated.
      //
      // CRITICAL exception: follow-ups typed WHILE a History session is open must still
      // appear. The send was reaching the bridge, but the list filtered the optimistic
      // user row (and the live stream response) before `ownSentIds` could keep them —
      // the "message goes nowhere" bug. Scope exceptions to THIS history pick only:
      //   • follow-up own-sent ids registered after the history session opened
      //   • non-bridge rows that claim the loaded session id (live or just-settled)
      //   • live rows while the engine is live-tailing THAT same session
      // Never re-open the full process-lifetime ownSent set (would mix prior threads).
      if historicalSessionPicked {
        if bridgeHistoryFollowUpSentIds.contains(id) { return true }
        if let loaded = bridgeLoadedSessionId,
          let rowSid = bridgeRowSessionId(row),
          rowSid == loaded
        {
          return true
        }
        if bridgeRowIsLive(row) {
          let liveSid = ChatEngine.shared.liveBridgeSessionId(chatId: chatKey)
          if let loaded = bridgeLoadedSessionId, let liveSid {
            return liveSid == loaded
          }
          // Resume just started: engine has not registered the live session yet.
          // Allow the in-flight stream so the first frame is not blank.
          return true
        }
        return false
      }
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

  /// True when a row is a subscription/rate-limit notice that must stay out of the list.
  private static func isUsageLimitRow(_ row: ChatListRow) -> Bool {
    let body = (row.plainContent ?? row.text ?? "").lowercased()
    guard !body.isEmpty else { return false }
    // Only consider agent-side rows — never hide the user's own text.
    guard row.isAgentMessage || row.agentRuntime != nil || row.agentUsername != nil else {
      return false
    }
    // Failed agent turn with only a limit message (and no real tool work).
    let looksLikeLimit =
      body.contains("usage limit")
      || body.contains("session limit")
      || body.contains("rate limit")
      || body.contains("you've hit your")
      || body.contains("youve hit your")
      || body.contains("hit your usage")
      || body.contains("hit your session")
      || body.contains("quota exceeded")
      || body.contains("quota exhausted")
      || body.contains("out of usage")
      || body.contains("out of credits")
      || body.range(of: #"reached your .{0,40}limit"#, options: .regularExpression) != nil
    guard looksLikeLimit else { return false }
    // Text is not an event. Historical answers routinely discuss rate/usage limits and
    // must remain ordinary bubbles. Only a row that also carries explicit failure state
    // may synthesize a banner; the engine's dedicated `agentUsageLimit` event remains the
    // authoritative path for providers that do not persist a failed result row.
    let runtimeFailed: Bool = {
      guard let runtime = row.agentRuntime else { return false }
      let state = runtime.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if ["failed", "error", "rate_limited", "rate-limited", "limit"].contains(state) {
        return true
      }
      if let exitStatus = runtime.exitStatus, exitStatus != 0 { return true }
      return false
    }()
    return row.isAgentError || row.isDeliveryFailed || runtimeFailed
  }

  private func extractBridgeCommandRows(
    _ parsed: [ChatListRow], reportToHost: Bool = true
  ) -> [ChatListRow] {
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
    guard !commandRows.isEmpty, reportToHost else { return kept }

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

  // MARK: - Agent no-response watchdog + retry notice
  //
  // A prompt sent to an agent surface — a multi-agent group OR a 1:1 bridge DM —
  // can silently evaporate: a dropped run_task, a reconnecting computer, or an
  // exhausted/failed agent means the send is acked but NOTHING ever comes back
  // (no stream, no typing, no reply). Instead of "send and do nothing", arm a
  // watchdog on every accepted agent send. Any agent activity (a live stream, a
  // typing indicator, a new reply, or the engine's live agent state) stands it
  // down. If the window elapses in total silence, show a clear inline notice above
  // the composer with a one-tap Retry that re-dispatches the exact same prompt.
  private struct PendingAgentSend {
    let text: String
    let bridgeMetadata: [String: Any]
    let agentMention: Bool
    let agentText: String?
    let mentionedAgentUsername: String?
  }
  private static let agentResponseWatchdogSeconds: TimeInterval = 24.0
  private var agentResponseWatchdogWork: DispatchWorkItem?
  private var agentResponseWatchdogMessageId: String?
  private var agentResponseWatchdogChatId: String?
  private var agentResponseWatchdogBaselineAgentRows = 0
  private var agentResponseWatchdogSend: PendingAgentSend?
  private var lastAgentResponseSend: PendingAgentSend?
  private var agentResponseNoticeView: AgentResponseNoticeView?

  private func currentAgentRowCount() -> Int {
    rows.reduce(0) { acc, row in
      (row.kind == .message && row.isAgentMessage && row.messageType != "typing") ? acc + 1 : acc
    }
  }

  /// Arm the watchdog for a prompt just accepted for an agent surface. Runs on main.
  private func armAgentResponseWatchdog(messageId: String, send: PendingAgentSend) {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return }
    cancelAgentResponseWatchdog(reason: "re-arm")
    hideAgentResponseNotice(animated: false)
    agentResponseWatchdogMessageId = messageId
    agentResponseWatchdogChatId = chatId
    agentResponseWatchdogSend = send
    agentResponseWatchdogBaselineAgentRows = currentAgentRowCount()
    let work = DispatchWorkItem { [weak self] in
      self?.fireAgentResponseWatchdog(messageId: messageId, chatId: chatId)
    }
    agentResponseWatchdogWork = work
    NSLog(
      "[AgentWatchdog] armed chatId=%@ messageId=%@ baselineAgentRows=%d window=%.0fs",
      String(chatId.suffix(12)), messageId, agentResponseWatchdogBaselineAgentRows,
      Self.agentResponseWatchdogSeconds)
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.agentResponseWatchdogSeconds, execute: work)
  }

  private func cancelAgentResponseWatchdog(reason: String) {
    guard agentResponseWatchdogWork != nil || agentResponseWatchdogMessageId != nil else { return }
    agentResponseWatchdogWork?.cancel()
    agentResponseWatchdogWork = nil
    if let mid = agentResponseWatchdogMessageId {
      NSLog("[AgentWatchdog] cancelled messageId=%@ reason=%@", mid, reason)
    }
    agentResponseWatchdogMessageId = nil
    agentResponseWatchdogChatId = nil
    agentResponseWatchdogSend = nil
  }

  /// Called after each row-apply: if an agent started streaming / typing / replied
  /// since the send was armed, stand the watchdog down — and clear a notice already
  /// shown (covers a late reply that lands after the notice popped).
  private func noteAgentActivityForWatchdog() {
    let armed = agentResponseWatchdogMessageId != nil
    let noticeShown = agentResponseNoticeView.map { !$0.isHidden } ?? false
    guard armed || noticeShown else { return }
    // Cancel only on REAL output — a live stream or a new reply/notice row. A bare
    // typing indicator is deliberately NOT a cancel signal here: the server can flash
    // an optimistic "typing" the instant it dispatches, even when the paired computer
    // never actually runs the task (the exact silent-drop we exist to catch). Persistent
    // typing/progress is re-checked at fire time, where a genuinely-working agent stands
    // the watchdog down and a transient dispatch flicker has long since cleared.
    let hasLiveAgent = rows.contains { $0.isAgentMessage && bridgeRowIsLive($0) }
    let newAgentReply = currentAgentRowCount() > agentResponseWatchdogBaselineAgentRows
    guard hasLiveAgent || newAgentReply else { return }
    if armed { cancelAgentResponseWatchdog(reason: "agent_activity") }
    if noticeShown { hideAgentResponseNotice(animated: true) }
  }

  private func fireAgentResponseWatchdog(messageId: String, chatId: String) {
    guard agentResponseWatchdogMessageId == messageId else { return }
    let currentChat = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard currentChat == chatId else {
      cancelAgentResponseWatchdog(reason: "chat_changed")
      return
    }
    // Last-chance sign-of-life: rows may not carry a stream row yet, but the engine's
    // live typing/progress state can lead the first frame — treat either as "working".
    let hasLiveAgent = rows.contains { $0.isAgentMessage && bridgeRowIsLive($0) }
    let hasTyping = rows.contains { $0.kind == .message && $0.messageType == "typing" }
    let newAgentReply = currentAgentRowCount() > agentResponseWatchdogBaselineAgentRows
    let engineTyping = !ChatEngine.shared.typingUserIds(chatId: chatId).isEmpty
    let engineProgress = ChatEngine.shared.agentProgress(chatId: chatId) != nil
    if hasLiveAgent || hasTyping || newAgentReply || engineTyping || engineProgress {
      NSLog("[AgentWatchdog] stand-down at fire messageId=%@ (activity present)", messageId)
      cancelAgentResponseWatchdog(reason: "activity_at_fire")
      return
    }
    let send = agentResponseWatchdogSend
    NSLog(
      "[AgentWatchdog] FIRED — no agent response messageId=%@ chatId=%@", messageId,
      String(chatId.suffix(12)))
    cancelAgentResponseWatchdog(reason: "fired")
    showAgentResponseNotice(message: agentResponseNoticeMessage(), send: send)
  }

  private func agentResponseNoticeMessage() -> String {
    if isGroupOrChannel && groupHasBridgeAgents() {
      return "No response from your agents yet — your computer may be reconnecting."
    }
    let name = currentBridgeProvider?.capitalized ?? "The agent"
    return "\(name) hasn't responded — your computer may be reconnecting."
  }

  private func showAgentResponseNotice(message: String, send: PendingAgentSend?) {
    lastAgentResponseSend = send ?? lastAgentResponseSend
    let notice: AgentResponseNoticeView
    if let existing = agentResponseNoticeView {
      notice = existing
    } else {
      let created = AgentResponseNoticeView()
      created.onClose = { [weak self] in self?.hideAgentResponseNotice(animated: true) }
      addSubview(created)
      agentResponseNoticeView = created
      notice = created
    }
    notice.onRetry = { [weak self] in self?.retryAgentResponseSend() }
    notice.configure(message: message)
    notice.applyColors(
      isDark: appearance.isDark,
      textColor: appearance.textColorThem,
      accent: ChatListAppearance.brandAccentFallback)
    notice.isHidden = false
    bringSubviewToFront(notice)
    setNeedsLayout()
    layoutIfNeeded()
    notice.alpha = 0.0
    notice.transform = CGAffineTransform(translationX: 0, y: 10)
    UIView.animate(
      withDuration: 0.24, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      notice.alpha = 1.0
      notice.transform = .identity
    }
    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
  }

  private func hideAgentResponseNotice(animated: Bool) {
    guard let notice = agentResponseNoticeView, !notice.isHidden else { return }
    guard animated else {
      notice.isHidden = true
      notice.alpha = 0.0
      return
    }
    UIView.animate(
      withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      notice.alpha = 0.0
      notice.transform = CGAffineTransform(translationX: 0, y: 8)
    } completion: { _ in
      if notice.alpha <= 0.01 { notice.isHidden = true }
    }
  }

  private func layoutAgentResponseNotice() {
    guard let notice = agentResponseNoticeView, !notice.isHidden else { return }
    let barMinY = agentComposerView?.frame.minY ?? inputBar?.frame.minY ?? bounds.height
    let width = max(0.0, bounds.width - 24.0)
    let targetSize = notice.systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel)
    let height = max(46.0, targetSize.height)
    notice.frame = CGRect(x: 12.0, y: barMinY - height - 10.0, width: width, height: height)
  }

  private func retryAgentResponseSend() {
    guard let send = lastAgentResponseSend else {
      hideAgentResponseNotice(animated: true)
      return
    }
    hideAgentResponseNotice(animated: true)
    let newId = UUID().uuidString.lowercased()
    let now = Date()
    let ts = now.timeIntervalSince1970 * 1000
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm"
    NSLog("[AgentWatchdog] retry re-dispatch newMessageId=%@", newId)
    dispatchOutgoingSend(
      messageId: newId,
      text: send.text,
      timestamp: fmt.string(from: now),
      timestampMs: ts,
      replyToMessageId: nil,
      bridgeMetadata: send.bridgeMetadata,
      agentMention: send.agentMention,
      agentText: send.agentText,
      mentionedAgentUsername: send.mentionedAgentUsername)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

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

  /// Providers that should contribute to the usage banner for this surface
  /// (agent DM: that provider; multi-agent group: every bridge member).
  private func usageBannerProviders() -> [String] {
    if let provider = currentBridgeProvider, !provider.isEmpty {
      return [provider]
    }
    if groupHasBridgeAgents() {
      let providers = Set(
        groupSenderDirectory.values.compactMap { entry -> String? in
          let p = entry.provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          return (p?.isEmpty == false) ? p : nil
        })
      let ordered = ["claude", "codex", "grok", "agy"].filter { providers.contains($0) }
      return ordered.isEmpty ? Array(providers).sorted() : ordered
    }
    return []
  }

  /// Pending multi-provider usage replies keyed by requestId (group carousel).
  private var pendingGroupUsageRequestIds: [String: String] = [:]
  private var groupUsageSnapshotsByProvider: [String: (util: Int, label: String, resetsAt: String?, limitHit: Bool)] = [:]
  private var groupUsageCarouselIndex: Int = 0
  private var groupUsageCarouselTimer: Timer?
  /// Ordered providers currently represented by banner dots (manual swipe target).
  private var lastUsageCarouselProviders: [String] = []
  /// Interactive carousel pan on the usage banner (gated to horizontal drags).
  weak var usageBannerPanGesture: UIPanGestureRecognizer?

  /// Ask the bridge for a fresh structured usage snapshot. Throttled; a rejected push
  /// (socket/join not ready) clears the throttle so the channel-join retry fires freely.
  /// In multi-agent groups, requests every member provider so the banner can carousel.
  private func requestBridgeUsageSnapshot(reason: String) {
    let providers = usageBannerProviders()
    guard !providers.isEmpty else { return }
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return }
    let now = ProcessInfo.processInfo.systemUptime
    // Hard limit hits bypass the 30s throttle so the banner appears on send.
    let force = reason == "usageLimit" || reason == "send" || reason.hasPrefix("usageLimit")
    guard force || now - lastBridgeUsageRequestAt > 30.0 else { return }
    lastBridgeUsageRequestAt = now
    pendingGroupUsageRequestIds.removeAll()
    var anyAccepted = false
    for provider in providers {
      let requestId = UUID().uuidString
      let result = ChatEngine.shared.requestAgentBridgeUsage([
        "chatId": chatId, "provider": provider, "requestId": requestId,
      ])
      let accepted = (result["accepted"] as? Bool) == true
      if accepted {
        anyAccepted = true
        let rid = (result["requestId"] as? String) ?? requestId
        lastBridgeUsageRequestId = rid
        pendingGroupUsageRequestIds[rid] = provider
      }
      VibeDebugLog.log(
        "[ChatUsage] request chat=%@ provider=%@ reason=%@ accepted=%@ result=%@",
        String(chatId.prefix(12)), provider, reason, accepted ? "Y" : "N",
        (result["reason"] as? String) ?? "-")
    }
    if !anyAccepted {
      // Socket/join not ready — allow a retry after a short backoff.
      lastBridgeUsageRequestAt = now - 25.0
    }
  }

  /// Parse the usage reply this surface requested; show the banner when the worst
  /// subscription bucket is at/over the threshold, hide it when usage dropped back.
  private func applyBridgeUsageReply(requestId: String) {
    let providerForReply = pendingGroupUsageRequestIds[requestId]
    let isTracked =
      requestId == lastBridgeUsageRequestId || providerForReply != nil
    guard isTracked,
      let payload = ChatEngine.shared.latestAgentBridgeUsage(requestId: requestId),
      (payload["ok"] as? Bool) ?? true,
      let report = payload["report"] as? [String: Any]
    else { return }

    let provider =
      (providerForReply
        ?? (report["provider"] as? String)
        ?? currentBridgeProvider
        ?? "agent")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let buckets = report["buckets"] as? [[String: Any]] ?? []
    let limitHitFlag = (report["limitHit"] as? Bool) == true
    var worstLabel: String?
    var worstUtil = 0
    var worstResetsAt: String?
    for bucket in buckets {
      guard let label = bucket["label"] as? String, !label.isEmpty else { continue }
      // Older bridge builds fabricated this exact Codex label when primary-window
      // metadata was absent. Current bridge builds use the CLI's real window length
      // and label it "5-hour limit" only when a 300-minute window is actually present.
      if provider == "codex", label.caseInsensitiveCompare("5-hour session") == .orderedSame {
        continue
      }
      // Skip closed windows — their utilization is stale until the source refreshes.
      let resetsAt = bucket["resetsAt"] as? String
      if Self.bridgeUsageWindowExpired(resetsAt) { continue }
      let util = (bucket["utilization"] as? NSNumber)?.intValue
        ?? Int((bucket["utilization"] as? Double) ?? 0)
      if util > worstUtil {
        worstUtil = util
        worstLabel = label
        worstResetsAt = resetsAt
      }
    }
    // Don't trust a sticky limitHit alone — live utilization wins. A settled
    // "hit" flag after buckets recover was showing "Rate limit hit" forever.
    let effectiveLimitHit: Bool = {
      if worstUtil >= 100 { return true }
      if buckets.isEmpty { return limitHitFlag }
      // Only honor the flag when the live worst bucket is still near the ceiling.
      return limitHitFlag && worstUtil >= 95
    }()
    if effectiveLimitHit, worstLabel == nil {
      // A hard-limit event without a live bucket says nothing about the window length.
      // Never turn that missing metadata into a Codex 5-hour session.
      worstLabel = "Usage limit"
      worstUtil = max(worstUtil, 100)
    }
    pendingGroupUsageRequestIds.removeValue(forKey: requestId)
    if !provider.isEmpty {
      if let label = worstLabel {
        groupUsageSnapshotsByProvider[provider] = (
          util: worstUtil,
          label: label,
          resetsAt: worstResetsAt,
          limitHit: effectiveLimitHit
        )
      } else if !effectiveLimitHit {
        // Fresh report with no near-limit buckets → clear a sticky prior hit.
        groupUsageSnapshotsByProvider.removeValue(forKey: provider)
      }
    }
    VibeDebugLog.log(
      "[ChatUsage] reply provider=%@ buckets=%d worst=%@ %d%% flag=%@ effectiveHit=%@",
      provider, buckets.count, worstLabel ?? "-", worstUtil,
      limitHitFlag ? "Y" : "N", effectiveLimitHit ? "Y" : "N")

    refreshUsageBannerFromSnapshots()
  }

  /// Rebuild the floating usage banner from the latest per-provider snapshots.
  private func refreshUsageBannerFromSnapshots() {
    // A snapshot whose window already reset is stale — drop it instead of showing
    // yesterday's "Rate limit hit" on a recovered account.
    groupUsageSnapshotsByProvider = groupUsageSnapshotsByProvider.filter {
      !Self.bridgeUsageWindowExpired($0.value.resetsAt)
    }
    // Prefer limit-hit agents, then highest utilization ≥ 75%. The final provider-rank
    // tiebreak keeps the order DETERMINISTIC — dictionary enumeration order would
    // otherwise flip the banner between equal-utilization providers on every refresh.
    let rank: (String) -> Int = {
      ["claude": 0, "codex": 1, "grok": 2, "agy": 3][$0] ?? 4
    }
    let candidates = groupUsageSnapshotsByProvider
      .filter { $0.value.limitHit || $0.value.util >= 75 }
      .sorted { a, b in
        if a.value.limitHit != b.value.limitHit { return a.value.limitHit && !b.value.limitHit }
        if a.value.util != b.value.util { return a.value.util > b.value.util }
        return rank(a.key) < rank(b.key)
      }
    guard !candidates.isEmpty else {
      hideBridgeUsageBanner()
      stopGroupUsageCarousel()
      return
    }
    // Manual paging only (no auto-switch). Dots on the left; swipe to change.
    // Keep the page pinned to the provider currently shown — a refresh must not
    // silently swap the banner's identity out from under the reader.
    stopGroupUsageCarousel()
    if let shown = lastUsageBannerProvider,
      let pinned = candidates.firstIndex(where: { $0.key == shown })
    {
      groupUsageCarouselIndex = pinned
    }
    groupUsageCarouselIndex = min(max(0, groupUsageCarouselIndex), candidates.count - 1)
    let pageIndex = groupUsageCarouselIndex
    let (provider, snap) = candidates[pageIndex]
    presentUsageBanner(
      provider: provider,
      snap: snap,
      pageCount: candidates.count,
      pageIndex: pageIndex
    )
    // Remember ordered providers so swipe can advance.
    lastUsageCarouselProviders = candidates.map(\.key)
    scheduleUsageBannerRefreshPoll()
  }

  /// While a usage banner is visible, re-request fresh reports periodically so the
  /// banner recovers on its own (countdown advances, resets clear it) instead of
  /// freezing on whatever snapshot happened to be current at send time.
  private func scheduleUsageBannerRefreshPoll() {
    guard groupUsageCarouselTimer == nil else { return }
    groupUsageCarouselTimer = Timer.scheduledTimer(
      withTimeInterval: 60.0, repeats: true
    ) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      guard self.bridgeUsageBanner != nil else {
        self.stopGroupUsageCarousel()
        return
      }
      self.requestBridgeUsageSnapshot(reason: "bannerRefresh")
      // Re-render even without a reply so the "resets in Xm" countdown and
      // expired-window purge stay honest.
      self.refreshUsageBannerFromSnapshots()
    }
  }

  private func presentUsageBanner(
    provider: String,
    snap: (util: Int, label: String, resetsAt: String?, limitHit: Bool),
    pageCount: Int = 1,
    pageIndex: Int = 0
  ) {
    let key = "\(provider)#\(snap.label)#\(snap.util / 5)#\(snap.limitHit ? "H" : "N")"
    guard key != dismissedBridgeUsageKey else { return }
    let title =
      provider.isEmpty
      ? "Usage"
      : provider.prefix(1).uppercased() + provider.dropFirst()
    var text: String
    if snap.util >= 100 || (snap.limitHit && snap.util >= 95) {
      text = snap.label == "Usage limit" ? "Rate limit hit" : "Rate limit hit · \(snap.label)"
    } else {
      // Always prefer live % when we're not actually at the ceiling.
      text = "You've used \(snap.util)% of your \(snap.label) limit"
    }
    if let reset = Self.bridgeUsageResetText(snap.resetsAt) {
      text += " · resets in \(reset)"
    }
    showBridgeUsageBanner(
      text: text,
      key: key,
      title: title,
      provider: provider,
      pageCount: pageCount,
      pageIndex: pageIndex
    )
  }


  private func stopGroupUsageCarousel() {
    groupUsageCarouselTimer?.invalidate()
    groupUsageCarouselTimer = nil
  }

  /// Advance the multi-agent usage banner by one page (manual swipe).
  private func pageUsageBanner(by delta: Int) {
    let n = lastUsageCarouselProviders.count
    guard n > 1 else { return }
    groupUsageCarouselIndex = (groupUsageCarouselIndex + delta + n) % n
    // The refresh pins the page to the shown provider so background updates can't
    // swap identity — point the pin at the page the user just chose.
    lastUsageBannerProvider = lastUsageCarouselProviders[groupUsageCarouselIndex]
    refreshUsageBannerFromSnapshots()
  }

  /// Force-show a hard limit banner (from `agent-usage-limit` event) and refresh buckets.
  private func handleAgentUsageLimitEvent(provider: String, message: String) {
    let p = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !p.isEmpty else { return }
    let resetsAt = Self.parseResetHintFromLimitMessage(message)
    groupUsageSnapshotsByProvider[p] = (
      util: 100, label: "Usage limit", resetsAt: resetsAt, limitHit: true
    )
    // Clear dismiss so a fresh limit always reappears.
    dismissedBridgeUsageKey = nil
    refreshUsageBannerFromSnapshots()
    lastBridgeUsageRequestAt = 0
    requestBridgeUsageSnapshot(reason: "usageLimit:\(p)")
  }

  private static func parseResetHintFromLimitMessage(_ text: String) -> String? {
    // "resets in 3h 12m" / "resets 1am" — only the relative form is convertible.
    let pattern = #"resets?\s+(?:in\s+)?(?:(\d+)\s*d)?\s*(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
      return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = re.firstMatch(in: text, options: [], range: range) else { return nil }
    func group(_ i: Int) -> Int {
      let r = match.range(at: i)
      guard r.location != NSNotFound, let swift = Range(r, in: text) else { return 0 }
      return Int(text[swift]) ?? 0
    }
    let d = group(1)
    let h = group(2)
    let m = group(3)
    guard d + h + m > 0 else { return nil }
    let date = Date().addingTimeInterval(TimeInterval(((d * 24 + h) * 60 + m) * 60))
    return ISO8601DateFormatter().string(from: date)
  }

  /// "2h 15m" / "45m" / "3d" until the bucket resets, from the report's ISO timestamp.
  private static func bridgeUsageResetDate(_ iso: String?) -> Date? {
    guard let iso, !iso.isEmpty else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
  }

  /// A snapshot whose reset moment already passed describes a closed window — its
  /// utilization is stale by definition (the source cache just hasn't refreshed yet).
  private static func bridgeUsageWindowExpired(_ iso: String?) -> Bool {
    guard let date = bridgeUsageResetDate(iso) else { return false }
    return date.timeIntervalSinceNow < 0
  }

  private static func bridgeUsageResetText(_ iso: String?) -> String? {
    guard let date = bridgeUsageResetDate(iso) else { return nil }
    let seconds = date.timeIntervalSinceNow
    guard seconds > 0 else { return nil }
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    if hours > 48 { return "\(hours / 24)d" }
    if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
    return "\(max(1, minutes))m"
  }

  private var lastUsageBannerProvider: String?
  /// Snapshot of carousel page count last applied to the banner (for left dots).
  private var lastUsageBannerPageCount: Int = 0
  private var lastUsageBannerPageIndex: Int = 0

  private func showBridgeUsageBanner(
    text: String,
    key: String,
    title: String = "Usage",
    provider: String? = nil,
    pageCount: Int = 1,
    pageIndex: Int = 0
  ) {
    let banner: ChatPinnedBannerView
    if let existing = bridgeUsageBanner {
      banner = existing
    } else {
      let created = ChatPinnedBannerView()
      created.addTarget(self, action: #selector(handleBridgeUsageBannerTapped), for: .touchUpInside)
      created.onClose = { [weak self] in self?.dismissBridgeUsageBanner() }
      // Interactive horizontal pan pages multi-agent usage: content follows the
      // finger and commits/springs back on release (no auto-rotate). The delegate
      // gates it to mostly-horizontal drags so list scrolling over the banner wins.
      let pan = UIPanGestureRecognizer(target: self, action: #selector(handleUsageBannerPan(_:)))
      pan.delegate = self
      created.addGestureRecognizer(pan)
      usageBannerPanGesture = pan
      addSubview(created)
      bridgeUsageBanner = created
      banner = created
    }
    lastUsageBannerProvider = provider
    lastUsageBannerPageCount = pageCount
    lastUsageBannerPageIndex = pageIndex
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
    let isSwap = !banner.isHidden && banner.accessibilityValue != nil && banner.accessibilityValue != key
    banner.configure(
      title: title,
      body: text,
      systemImage: "gauge.with.dots.needle.bottom.50percent",
      animateIcon: isSwap || banner.accessibilityValue == nil
    )
    banner.setPageIndicator(count: pageCount, index: pageIndex)
    banner.accessibilityValue = key
    let wasHidden = banner.isHidden
    banner.isHidden = false
    banner.alpha = 1.0
    banner.transform = .identity
    bringSubviewToFront(banner)
    // This overlay owns no inset and has a fixed preferred height. Position it directly;
    // forcing the entire ChatListView through layoutIfNeeded here remeasures visible cells
    // on the same frame that a usage reply lands, which reads as a list/header flex.
    layoutBridgeUsageBanner()
    if wasHidden {
      onBridgeUsageBannerVisibilityChanged?()
      // First show: only the INNER content slides in — glass shell stays solid (no fade).
      banner.animateContentTranslateY(from: -10)
    } else if isSwap {
      // Carousel page change: translate content only, never fade the banner.
      banner.animateContentTranslateY(from: 8)
    }
  }

  @objc private func handleUsageBannerPan(_ gr: UIPanGestureRecognizer) {
    guard let banner = bridgeUsageBanner else { return }
    let dx = gr.translation(in: banner).x
    let width = max(1.0, banner.bounds.width)
    let pageable = lastUsageCarouselProviders.count > 1
    switch gr.state {
    case .changed:
      // Full finger-follow when neighbor pages exist; rubber-band when alone.
      banner.setContentTranslationX(pageable ? dx : dx / 3.0)
    case .ended, .cancelled, .failed:
      let vx = gr.velocity(in: banner).x
      let commit = pageable && (abs(dx) > width * 0.28 || abs(vx) > 600.0)
      guard commit else {
        banner.animateContentTranslateX(from: pageable ? dx : dx / 3.0)
        return
      }
      // Continue the drag out the same edge, swap page, slide the new
      // content in from the opposite edge — one continuous hand-off.
      let delta = (dx < 0 || (dx == 0 && vx < 0)) ? 1 : -1
      let outX: CGFloat = delta == 1 ? -width : width
      UIView.animate(
        withDuration: 0.14, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]
      ) {
        banner.setContentTranslationX(outX)
      } completion: { [weak self] _ in
        guard let self else { return }
        self.pageUsageBanner(by: delta)
        self.bridgeUsageBanner?.animateContentTranslateX(from: -outX * 0.55)
      }
    default:
      break
    }
  }

  /// Tap opens the structured Usage sheet (5h / weekly + reset). Close (✕) only dismisses.
  @objc private func handleBridgeUsageBannerTapped() {
    let provider =
      (lastUsageBannerProvider ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let resolved =
      provider.isEmpty
      ? (currentBridgeProvider
        ?? usageBannerProviders().first
        ?? "claude")
      : provider
    NSLog("[ChatUsage] banner tapped provider=%@", resolved)
    // Prefetch before present so the sheet opens with data, not a spinner.
    lastBridgeUsageRequestAt = 0
    requestBridgeUsageSnapshot(reason: "usageLimit:preopen")
    presentUsageSheet(provider: resolved)
  }

  private func dismissBridgeUsageBanner() {
    dismissedBridgeUsageKey = bridgeUsageBanner?.accessibilityValue
    hideBridgeUsageBanner()
  }

  /// Present the per-provider Usage panel with the same glass material as the
  /// agent progress / "Worked for…" sheet (clear chrome + system pageSheet glass).
  private func presentUsageSheet(provider: String) {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else {
      NSLog("[ChatUsage] presentUsageSheet skipped — empty chatId")
      return
    }
    guard let presenter = topPresentingViewController() else {
      NSLog("[ChatUsage] presentUsageSheet skipped — no presenter")
      return
    }
    if presenter.presentedViewController != nil {
      presenter.dismiss(animated: false)
    }
    // Kick a fresh bridge fetch, but seed the sheet from any prefetched cache so
    // the first frame already shows buckets/reset times.
    let prefresh = ChatEngine.shared.requestAgentBridgeUsage([
      "chatId": chatId, "provider": provider,
    ])
    let seedRequestId = (prefresh["requestId"] as? String)
    let cached = ChatEngine.shared.cachedAgentBridgeUsage(chatId: chatId, provider: provider)
    let kitAppearance = VibeAgentKitMap.appearance(for: traitCollection)
    let root = VibeAgentUsageSheetRoot(
      chatId: chatId,
      provider: provider,
      appearance: kitAppearance,
      seedPayload: cached,
      pendingRequestId: seedRequestId
    )
    let host = UIHostingController(rootView: root)
    // Match progress-sheet glass: clear host so ultra-thin material (light/dark) shows.
    host.view.backgroundColor = .clear
    host.overrideUserInterfaceStyle = kitAppearance.isDark ? .dark : .light
    host.modalPresentationStyle = .pageSheet
    if let sheet = host.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      if #available(iOS 16.0, *) {
        sheet.preferredCornerRadius = 30
      }
    }
    presenter.present(host, animated: true)
    NSLog(
      "[ChatUsage] presentUsageSheet presented provider=%@ chat=%@ cached=%@",
      provider, String(chatId.prefix(12)), cached != nil ? "Y" : "N")
  }

  /// Multi-agent: pick which provider's usage sheet to open (each sheet fetches that
  /// provider's real bridge payload). Single provider opens directly.
  private func presentUsageMenuOrSheet(providers: [String]? = nil) {
    let list = (providers?.isEmpty == false ? providers! : usageBannerProviders())
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
    guard !list.isEmpty else { return }
    if list.count == 1 {
      presentUsageSheet(provider: list[0])
      return
    }
    guard let presenter = topPresentingViewController() else { return }
    let sheet = UIAlertController(
      title: "Usage",
      message: "Open subscription limits for…",
      preferredStyle: .actionSheet
    )
    for provider in list {
      let title = provider.prefix(1).uppercased() + provider.dropFirst()
      sheet.addAction(
        UIAlertAction(title: title, style: .default) { [weak self] _ in
          self?.presentUsageSheet(provider: provider)
        })
    }
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let pop = sheet.popoverPresentationController {
      pop.sourceView = presenter.view
      pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: 80, width: 1, height: 1)
    }
    presenter.present(sheet, animated: true)
  }

  private func hideBridgeUsageBanner() {
    stopGroupUsageCarousel()
    guard let banner = bridgeUsageBanner, !banner.isHidden else { return }
    // Collapse by sliding content away; glass shell stays opaque until hide.
    banner.animateContentTranslateY(from: 0)
    UIView.animate(
      withDuration: 0.16, delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      // Prefer transform over alpha so we never leave a half-faded glass shell.
      banner.transform = CGAffineTransform(translationX: 0, y: -10)
    } completion: { [weak self] _ in
      banner.isHidden = true
      banner.transform = .identity
      banner.alpha = 1.0
      self?.onBridgeUsageBannerVisibilityChanged?()
    }
  }

  /// Float the usage banner as an absolute overlay pinned just below the header (and
  /// below any pinned/inbox banners that reserve space in `contentPaddingTop`). It
  /// deliberately reserves NO list inset of its own — it slides in over the feed and
  /// out again without shifting a single row (the old reserved-band placement first
  /// drew it behind the header, then pushed the whole list down when the inset landed).
  private func layoutBridgeUsageBanner() {
    guard let banner = bridgeUsageBanner, !banner.isHidden else { return }
    let width = max(0.0, bounds.width - 32.0)
    let height = ChatPinnedBannerView.preferredHeight
    let topY = contentPaddingTop + 4.0
    banner.frame = CGRect(x: 16.0, y: topY, width: width, height: height)
  }

  // MARK: - Pending sends while a bridge run is live

  /// A message typed while the agent was still running. Held out of the transcript
  /// (no optimistic row, nothing dispatched) and shown as a "waiting" preview above
  /// the input until the run settles, the user cancels it, or the user steers.
  private struct PendingBridgeSend {
    let messageId: String
    let text: String
    let replyToMessageId: String?
    let bridgeMetadata: [String: Any]
    let agentMention: Bool
    let agentText: String?
    let mentionedAgentUsername: String?
    let createdAtMs: Int64
  }

  /// Survives view rebinds (leaving/reopening the DM) for the app session.
  private static var pendingBridgeSendsByChat: [String: [PendingBridgeSend]] = [:]
  private var pendingBridgeQueueContainer: UIView?
  private var pendingBridgeQueueScroll: UIScrollView?
  private var pendingBridgeQueueStack: UIStackView?
  private var pendingBridgeQueueHeader: UILabel?
  private var bridgeQueueFlushWorkItem: DispatchWorkItem?

  private var pendingBridgeChatKey: String {
    engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var pendingBridgeSends: [PendingBridgeSend] {
    get { Self.pendingBridgeSendsByChat[pendingBridgeChatKey] ?? [] }
    set { Self.pendingBridgeSendsByChat[pendingBridgeChatKey] = newValue }
  }

  /// Is a bridge run live for THIS chat right now? Checks active progress/ask state
  /// plus any live agent row on screen. Mounted History sessions are not "busy".
  private func bridgeRunIsLive() -> Bool {
    let chatId = pendingBridgeChatKey
    guard !chatId.isEmpty, currentBridgeProvider != nil else { return false }
    if ChatEngine.shared.bridgeRunIsActive(chatId: chatId) { return true }
    return rows.contains { $0.isAgentMessage && bridgeRowIsLive($0) }
  }

  private func enqueuePendingBridgeSend(
    messageId: String,
    text: String,
    replyToMessageId: String?,
    bridgeMetadata: [String: Any],
    agentMention: Bool,
    agentText: String?,
    mentionedAgentUsername: String?
  ) {
    guard !pendingBridgeChatKey.isEmpty else { return }
    let item = PendingBridgeSend(
      messageId: messageId,
      text: text,
      replyToMessageId: replyToMessageId,
      bridgeMetadata: bridgeMetadata,
      agentMention: agentMention,
      agentText: agentText,
      mentionedAgentUsername: mentionedAgentUsername,
      createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
    )
    pendingBridgeSends.append(item)
    NSLog(
      "[BridgeQueue] enqueue id=%@ queued=%d textLen=%d",
      String(messageId.prefix(8)), pendingBridgeSends.count, text.count)
    refreshPendingBridgeQueueUI(animated: true)
    // Safety: if the settle signal was already in flight while the user typed,
    // don't strand the message — re-check shortly.
    schedulePendingBridgeQueueFlush(reason: "post-enqueue-check")
  }

  private func cancelPendingBridgeSend(messageId: String) {
    var queue = pendingBridgeSends
    queue.removeAll { $0.messageId == messageId }
    pendingBridgeSends = queue
    NSLog("[BridgeQueue] cancel id=%@ queued=%d", String(messageId.prefix(8)), queue.count)
    refreshPendingBridgeQueueUI(animated: true)
  }

  /// Steer: force-stop the live run, then dispatch THIS pending message immediately
  /// (the resume-session id keeps the conversation context). Remaining queued items
  /// wait for the steered run to settle like normal.
  private func steerPendingBridgeSend(messageId: String) {
    var queue = pendingBridgeSends
    guard let index = queue.firstIndex(where: { $0.messageId == messageId }) else { return }
    let item = queue.remove(at: index)
    pendingBridgeSends = queue
    refreshPendingBridgeQueueUI(animated: true)
    let chatId = pendingBridgeChatKey
    guard let provider = currentBridgeProvider, !chatId.isEmpty else {
      performPendingBridgeSend(item)
      return
    }
    let result = ChatEngine.shared.sendAgentBridgeControl([
      "chatId": chatId, "provider": provider, "action": "cancel",
    ])
    NSLog(
      "[BridgeQueue] steer id=%@ cancelAccepted=%@",
      String(messageId.prefix(8)), ((result["accepted"] as? Bool) == true) ? "Y" : "N")
    // Give the cancel a beat to reach the CLI before the fresh prompt spawns the
    // next run; the daemon treats a cancel racing a natural finish as a no-op.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      self?.performPendingBridgeSend(item)
    }
  }

  /// Dispatch a held message through the normal outgoing path (optimistic row now
  /// appears in the list, exactly like a direct send).
  private func performPendingBridgeSend(_ item: PendingBridgeSend) {
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    if !item.bridgeMetadata.isEmpty {
      noteBridgeFreshOwnSentId(item.messageId)
    }
    NSLog("[BridgeQueue] dispatch id=%@", String(item.messageId.prefix(8)))
    dispatchOutgoingSend(
      messageId: item.messageId,
      text: item.text,
      timestamp: formatter.string(from: now),
      timestampMs: now.timeIntervalSince1970 * 1000,
      replyToMessageId: item.replyToMessageId,
      bridgeMetadata: item.bridgeMetadata,
      agentMention: item.agentMention,
      agentText: item.agentText,
      mentionedAgentUsername: item.mentionedAgentUsername
    )
  }

  /// Debounced "run may have settled" probe. Fired from the agentProgress-idle
  /// engine event and from row settles; flushes ONE item per settle (each flush
  /// starts a new run; the rest keep waiting for that run).
  private func schedulePendingBridgeQueueFlush(reason: String) {
    guard !pendingBridgeSends.isEmpty else { return }
    bridgeQueueFlushWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.bridgeQueueFlushWorkItem = nil
      self.flushPendingBridgeQueueIfIdle()
    }
    bridgeQueueFlushWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
  }

  private func flushPendingBridgeQueueIfIdle() {
    var queue = pendingBridgeSends
    guard !queue.isEmpty else {
      refreshPendingBridgeQueueUI(animated: false)
      return
    }
    guard !bridgeRunIsLive() else {
      // Still running — the next settle signal re-arms the flush.
      refreshPendingBridgeQueueUI(animated: false)
      return
    }
    let item = queue.removeFirst()
    pendingBridgeSends = queue
    refreshPendingBridgeQueueUI(animated: true)
    performPendingBridgeSend(item)
  }

  /// Push the pending-queue strip into the input bar (preview + Steer + ✕).
  /// No separate floating overlay over the list.
  private func refreshPendingBridgeQueueUI(animated: Bool) {
    // Tear down any legacy floating overlay if it still exists.
    if let container = pendingBridgeQueueContainer {
      container.removeFromSuperview()
      pendingBridgeQueueContainer = nil
      pendingBridgeQueueScroll = nil
      pendingBridgeQueueStack = nil
      pendingBridgeQueueHeader = nil
    }

    guard let inputBar else { return }
    let queue = pendingBridgeSends
    let show = !queue.isEmpty && currentBridgeProvider != nil
    let items: [ChatInputBar.PendingQueueItem] =
      show
      ? queue.map { ChatInputBar.PendingQueueItem(messageId: $0.messageId, text: $0.text) }
      : []
    inputBar.onPendingQueueCancel = { [weak self] id in
      self?.cancelPendingBridgeSend(messageId: id)
    }
    inputBar.onPendingQueueSteer = { [weak self] id in
      self?.steerPendingBridgeSend(messageId: id)
    }
    inputBar.setPendingQueueItems(items, animated: animated)
  }

  private func layoutPendingBridgeQueue() {
    // Queue UI lives inside ChatInputBar now — nothing to layout on the list.
  }

  // MARK: - Live background-task banner (bridge runs)

  private var bridgeTaskBanner: UIView?
  private var bridgeTaskBannerScroll: UIScrollView?
  private var bridgeTaskBannerCountLabel: UILabel?
  private var bridgeTaskBannerItems: [VibeAgentKitProgressItem] = []
  /// Node ids already surfaced for the CURRENT live turn — once a task appears it
  /// stays in the banner (flipping to done/failed) until the turn settles.
  private var bridgeTaskBannerSeenNodeIds: Set<String> = []
  private var bridgeTaskBannerRowKey: String?
  private var lastBridgeTaskBannerRefreshAt: CFTimeInterval = 0
  /// Pending delayed hide — the banner must not blink out on transient states (the
  /// live row's uid flip, the stream→settled swap gap) while the task payload still
  /// says the run is live. Cancelled by the next refresh that finds tasks.
  private var bridgeTaskBannerHideWorkItem: DispatchWorkItem?
  /// Turn key the currently DISPLAYED banner items belong to — the delayed hide
  /// keeps the banner only while this same turn is still live.
  private var bridgeTaskBannerItemsTurnKey: String?

  /// Rebuild the "N tasks live" banner from the live turn's progress nodes. A node
  /// counts as a TASK when it's a terminal/subagent-style step (bash/task/tool/mcp)
  /// that is running in PARALLEL — i.e. it's still `running` while a later step has
  /// already started (Claude/Codex background terminals, subagents). The current
  /// foreground step never shows here (the header already narrates it).
  private func refreshBridgeTaskBanner() {
    guard currentBridgeProvider != nil else {
      hideBridgeTaskBanner()
      return
    }
    let now = CACurrentMediaTime()
    guard now - lastBridgeTaskBannerRefreshAt > 0.4 else { return }
    lastBridgeTaskBannerRefreshAt = now

    guard let liveRow = rows.last(where: { $0.isAgentMessage && bridgeRowIsLive($0) }) else {
      // Settle gap / brief live-state blink — hide through the grace timer so the
      // banner reads as stable while the run itself is still going.
      scheduleBridgeTaskBannerHide()
      return
    }
    // Key the surfaced-task set by TURN, not by row key: the live row's uid can flip
    // mid-run (grok-live↔rs_, stream→settled swap) and a row-key reset would drop
    // every already-surfaced task — the "banner randomly disappears" report.
    let taskId = liveRow.agentRuntime?.taskId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let rowKey = (taskId?.isEmpty == false) ? taskId! : (liveRow.messageId ?? liveRow.key)
    if rowKey != bridgeTaskBannerRowKey {
      bridgeTaskBannerRowKey = rowKey
      bridgeTaskBannerSeenNodeIds = []
    }
    let message = VibeAgentKitMap.chatMessage(from: liveRow)
    let taskKinds: Set<String> = ["bash", "task", "tool", "mcp"]
    let items = message.progressItems
    var tasks: [VibeAgentKitProgressItem] = []
    for (index, item) in items.enumerated() {
      let kind = (item.itemType ?? item.tool ?? "").lowercased()
      guard taskKinds.contains(kind) else { continue }
      let nodeKey = item.nodeId ?? "\(rowKey)#\(index)"
      let isRunning = vibeAgentKitRunningStepStatuses.contains((item.status ?? "").lowercased())
      let hasLaterStep = index < items.count - 1
      if isRunning && hasLaterStep {
        // Parallel/backgrounded: still running while later steps already started.
        bridgeTaskBannerSeenNodeIds.insert(nodeKey)
        tasks.append(item)
      } else if bridgeTaskBannerSeenNodeIds.contains(nodeKey) {
        // Previously surfaced task that has since finished — keep it, now "done".
        tasks.append(item)
      }
    }
    guard !tasks.isEmpty else {
      scheduleBridgeTaskBannerHide()
      return
    }
    bridgeTaskBannerHideWorkItem?.cancel()
    bridgeTaskBannerHideWorkItem = nil
    bridgeTaskBannerItems = tasks
    bridgeTaskBannerItemsTurnKey = rowKey
    rebuildBridgeTaskBanner(tasks: tasks)
  }

  /// Current live turn's key (taskId when available), or nil when no live agent row.
  private func bridgeTaskBannerLiveTurnKey() -> String? {
    guard let liveRow = rows.last(where: { $0.isAgentMessage && bridgeRowIsLive($0) }) else {
      return nil
    }
    let taskId = liveRow.agentRuntime?.taskId?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (taskId?.isEmpty == false) ? taskId! : (liveRow.messageId ?? liveRow.key)
  }

  /// Grace-delayed hide: transient no-live/no-task frames (uid flips, settle swaps)
  /// must not blink the banner. At fire time the check is authoritative: keep the
  /// banner only if the SAME turn its items belong to is live again — otherwise the
  /// run is over (or a new turn started) and the banner animates out.
  private func scheduleBridgeTaskBannerHide() {
    guard let banner = bridgeTaskBanner, !banner.isHidden else {
      // Nothing visible — just clear the turn state immediately.
      hideBridgeTaskBanner()
      return
    }
    guard bridgeTaskBannerHideWorkItem == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.bridgeTaskBannerHideWorkItem = nil
      if let liveKey = self.bridgeTaskBannerLiveTurnKey(),
        let itemsKey = self.bridgeTaskBannerItemsTurnKey,
        liveKey == itemsKey
      {
        return  // same turn still live — the blink was transient, keep the banner
      }
      self.hideBridgeTaskBanner()
    }
    bridgeTaskBannerHideWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
  }

  private func rebuildBridgeTaskBanner(tasks: [VibeAgentKitProgressItem]) {
    let banner: UIVisualEffectView
    let scroll: UIScrollView
    if let existing = bridgeTaskBanner as? UIVisualEffectView,
      let existingScroll = bridgeTaskBannerScroll
    {
      banner = existing
      scroll = existingScroll
    } else {
      bridgeTaskBanner?.removeFromSuperview()
      // Same material family as the usage banner (ChatPinnedBannerView): a single
      // glass shell, capsule corners, no solid fill and no border.
      let container = UIVisualEffectView(effect: nil)
      container.layer.cornerRadius = 26.0
      container.layer.cornerCurve = .continuous
      container.clipsToBounds = true
      addSubview(container)

      let paging = UIScrollView()
      paging.isPagingEnabled = true
      paging.showsHorizontalScrollIndicator = false
      paging.translatesAutoresizingMaskIntoConstraints = false
      container.contentView.addSubview(paging)

      let count = UILabel()
      count.font = .systemFont(ofSize: 11.0, weight: .bold)
      count.textAlignment = .center
      count.layer.cornerRadius = 9.0
      count.layer.cornerCurve = .continuous
      count.clipsToBounds = true
      count.translatesAutoresizingMaskIntoConstraints = false
      container.contentView.addSubview(count)

      NSLayoutConstraint.activate([
        paging.topAnchor.constraint(equalTo: container.contentView.topAnchor),
        paging.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor),
        paging.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor),
        paging.trailingAnchor.constraint(
          equalTo: container.contentView.trailingAnchor, constant: -34.0),
        count.trailingAnchor.constraint(
          equalTo: container.contentView.trailingAnchor, constant: -8.0),
        count.centerYAnchor.constraint(equalTo: container.contentView.centerYAnchor),
        count.widthAnchor.constraint(greaterThanOrEqualToConstant: 18.0),
        count.heightAnchor.constraint(equalToConstant: 18.0),
      ])
      bridgeTaskBanner = container
      bridgeTaskBannerScroll = paging
      bridgeTaskBannerCountLabel = count
      banner = container
      scroll = paging
    }

    // Set the material once — re-assigning a fresh effect every rebuild re-runs the
    // material transition and reads as flicker.
    if banner.effect == nil {
      if #available(iOS 26.0, *) {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        banner.effect = glass
      } else {
        banner.effect = UIBlurEffect(style: .systemThinMaterial)
      }
    }
    if #available(iOS 26.0, *) {
      banner.contentView.backgroundColor = .clear
    } else {
      banner.contentView.backgroundColor =
        appearance.bubbleThemColor.withAlphaComponent(appearance.isDark ? 0.16 : 0.10)
    }
    banner.backgroundColor = .clear
    let liveCount = tasks.filter {
      vibeAgentKitRunningStepStatuses.contains(($0.status ?? "").lowercased())
    }.count
    bridgeTaskBannerCountLabel?.text = "\(liveCount)"
    bridgeTaskBannerCountLabel?.textColor = appearance.isDark ? .black : .white
    bridgeTaskBannerCountLabel?.backgroundColor =
      liveCount > 0
      ? (appearance.isDark
        ? UIColor(red: 0.98, green: 0.76, blue: 0.28, alpha: 1.0)
        : UIColor(red: 0.70, green: 0.48, blue: 0.04, alpha: 1.0))
      : appearance.textColorThem.withAlphaComponent(0.35)

    for view in scroll.subviews where view is BridgeTaskBannerPageView {
      view.removeFromSuperview()
    }
    for (index, item) in tasks.enumerated() {
      let page = BridgeTaskBannerPageView(
        item: item, index: index, total: tasks.count, appearance: appearance)
      page.onTap = { [weak self] in self?.presentBridgeTaskDetail(index: index) }
      scroll.addSubview(page)
    }

    let wasHidden = banner.isHidden || banner.alpha <= 0.01
    banner.isHidden = false
    bringSubviewToFront(banner)
    setNeedsLayout()
    if wasHidden {
      layoutIfNeeded()
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
  }

  private func hideBridgeTaskBanner() {
    bridgeTaskBannerHideWorkItem?.cancel()
    bridgeTaskBannerHideWorkItem = nil
    bridgeTaskBannerItems = []
    bridgeTaskBannerRowKey = nil
    bridgeTaskBannerItemsTurnKey = nil
    bridgeTaskBannerSeenNodeIds = []
    guard let banner = bridgeTaskBanner, !banner.isHidden else { return }
    UIView.animate(
      withDuration: 0.16, delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      banner.alpha = 0.0
      banner.transform = CGAffineTransform(translationX: 0, y: -8)
    } completion: { _ in
      if banner.alpha <= 0.01 { banner.isHidden = true }
    }
  }

  /// Task RESULT lives in a sheet, not the transcript: tapping a banner page opens
  /// the standard step-detail sheet (command + output / subagent detail).
  private func presentBridgeTaskDetail(index: Int) {
    guard index >= 0, index < bridgeTaskBannerItems.count,
      let presenter = topPresentingViewController()
    else { return }
    let detail = VibeAgentKitStepDetailViewController(
      item: bridgeTaskBannerItems[index],
      appearance: VibeAgentKitMap.appearance(for: traitCollection)
    )
    let nav = UINavigationController(rootViewController: detail)
    nav.modalPresentationStyle = .pageSheet
    let vibeAppearance = VibeAgentKitMap.appearance(for: traitCollection)
    nav.view.backgroundColor =
      vibeAppearance.isDark ? UIColor.black.withAlphaComponent(0.3) : .clear
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    presenter.present(nav, animated: true)
  }

  /// Pinned like the usage banner (top, floating over the feed); when both are
  /// visible the task banner stacks directly below the usage banner. Pages lay out
  /// side-by-side at banner width for the inner horizontal scroll.
  private func layoutBridgeTaskBanner() {
    guard let banner = bridgeTaskBanner, !banner.isHidden,
      let scroll = bridgeTaskBannerScroll
    else { return }
    let width = max(0.0, bounds.width - 32.0)
    let height: CGFloat = 52.0
    var topY = contentPaddingTop + 4.0
    if let usage = bridgeUsageBanner, !usage.isHidden {
      topY = usage.frame.maxY + 8.0
    }
    banner.frame = CGRect(x: 16.0, y: topY, width: width, height: height)
    let pageWidth = max(0.0, width - 34.0)
    var pageIndex = 0
    for view in scroll.subviews where view is BridgeTaskBannerPageView {
      view.frame = CGRect(
        x: CGFloat(pageIndex) * pageWidth, y: 0.0, width: pageWidth, height: height)
      pageIndex += 1
    }
    scroll.contentSize = CGSize(width: CGFloat(pageIndex) * pageWidth, height: height)
  }

  private static func rememberWarmTranscript(
    chatId: String,
    rows: [ChatListRow],
    sourceRows: [[String: Any]],
    messageHeightCache: [String: RowHeightCacheEntry],
    agentTurnHeightCache: [String: RowHeightCacheEntry]
  ) {
    guard !chatId.isEmpty, !rows.isEmpty else { return }
    // Some native-only refreshes call setRows([]) and still produce a complete parsed
    // transcript because mergedRowsPayload substitutes ChatEngine history. Do not let
    // that empty transport payload replace the last usable raw source: a new controller
    // starts with status authority deferred, so replaying [] there would wipe its warm
    // tail until the asynchronous engine read finishes.
    let retainedSourceRows: [[String: Any]]
    if !sourceRows.isEmpty {
      retainedSourceRows = sourceRows
    } else {
      retainedSourceRows = warmTranscriptSnapshots[chatId]?.sourceRows ?? []
    }
    warmTranscriptSnapshots[chatId] = WarmTranscriptSnapshot(
      rows: rows,
      sourceRows: retainedSourceRows,
      messageHeightCache: messageHeightCache,
      agentTurnHeightCache: agentTurnHeightCache
    )
    warmTranscriptSnapshotOrder.removeAll { $0 == chatId }
    warmTranscriptSnapshotOrder.append(chatId)
    while warmTranscriptSnapshotOrder.count > warmTranscriptCacheLimit {
      let evicted = warmTranscriptSnapshotOrder.removeFirst()
      warmTranscriptSnapshots.removeValue(forKey: evicted)
    }
  }

  private static func removeWarmTranscript(chatId: String) {
    guard !chatId.isEmpty else { return }
    warmTranscriptSnapshots.removeValue(forKey: chatId)
    warmTranscriptSnapshotOrder.removeAll { $0 == chatId }
  }

  /// Launch prewarm: install a complete parsed snapshot for a chat whose raw cached
  /// rows Home already fetched off-main. ChatListRow(raw:) is data-only, so parsing
  /// stays on the caller's (background) queue; snapshot installation hops to main.
  /// A richer snapshot from a live session always wins — this never replaces one.
  /// Heights are not part of this snapshot; the seed covers them from the disk cache.
  static func prewarmWarmTranscriptSnapshot(
    chatId: String,
    sourceRows: [[String: Any]],
    peerDisplayName: String
  ) {
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, sourceRows.count > initialTranscriptWindow else { return }
    // Match the live list pipeline before parsing. Cached engine rows carry replyToId,
    // but older rows may not persist the denormalized preview fields; resolving them
    // here prevents the first post-push flush from treating every reply as changed.
    let resolvedSourceRows = rowsByResolvingReplyPreviews(
      sourceRows,
      peerDisplayName: peerDisplayName
    )
    let parsed = resolvedSourceRows.compactMap { ChatListRow(raw: $0) }
    guard !parsed.isEmpty else { return }
    DispatchQueue.main.async {
      guard warmTranscriptSnapshots[trimmed] == nil else { return }
      rememberWarmTranscript(
        chatId: trimmed,
        rows: parsed,
        sourceRows: resolvedSourceRows,
        messageHeightCache: [:],
        agentTurnHeightCache: [:]
      )
      NSLog(
        "[ChatOpen] prewarm SNAPSHOT chat=%@ rows=%d",
        String(trimmed.prefix(12)), parsed.count)
    }
  }

  /// Launch prewarm twin for the reopen raster: decode the disk JPEG into the memory
  /// cache BEFORE any tap, so the overlay is available at the shell commit itself (first
  /// visible frame of the push) instead of racing a ~30-120ms disk decode at open. Runs
  /// for the same few chats the transcript prewarm covers; both theme twins are tried
  /// since only the file matching the capture-time theme exists. Off-main throughout.
  static func prewarmReopenSnapshotRaster(chatId: String) {
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let width = Int(UIScreen.main.bounds.width.rounded())
    let screenScale = UIScreen.main.scale
    for theme in ["dark", "light"] {
      let key = NSString(string: "\(trimmed)|w\(width)|\(theme)")
      guard reopenSnapshotCache.object(forKey: key) == nil,
        let url = reopenSnapshotFileURL(for: key)
      else { continue }
      reopenSnapshotIOQueue.async {
        guard FileManager.default.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url),
          let raw = UIImage(data: data, scale: screenScale)
        else { return }
        let image = raw.preparingForDisplay() ?? raw
        // Same blank-frame safety as the per-open disk path: a flat raster must never
        // enter the overlay cache.
        guard (rasterLumaRange(image) ?? -1) >= 4 else {
          try? FileManager.default.removeItem(at: url)
          return
        }
        DispatchQueue.main.async {
          guard reopenSnapshotCache.object(forKey: key) == nil else { return }
          reopenSnapshotCache.setObject(image, forKey: key)
          NSLog(
            "[ChatOpen] reopen-snapshot PREWARM chat=%@ theme=%@",
            String(trimmed.prefix(12)), theme)
        }
      }
    }
  }

  /// Pure reply-preview normalization shared by launch prewarm and the live rows merge.
  /// Keeping both callers on this exact transform makes their raw rows reusable byte-for-byte.
  private static func rowsByResolvingReplyPreviews(
    _ rows: [[String: Any]],
    peerDisplayName: String
  ) -> [[String: Any]] {
    func nonEmptyString(_ raw: Any?) -> String? {
      if let value = raw as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      }
      if let value = raw as? NSNumber { return value.stringValue }
      if let value = raw as? Int { return String(value) }
      if let value = raw as? Double, value.isFinite { return String(value) }
      return nil
    }

    func messageId(from row: [String: Any]) -> String? {
      guard (row["kind"] as? String) == "message",
        let message = row["message"] as? [String: Any]
      else { return nil }
      return nonEmptyString(message["id"])
    }

    func replyToId(from message: [String: Any]) -> String? {
      let metadata = message["metadata"] as? [String: Any]
      let extra = message["extra"] as? [String: Any]
      return nonEmptyString(message["replyToId"])
        ?? nonEmptyString(message["reply_to_id"])
        ?? nonEmptyString(message["replyToMessageId"])
        ?? nonEmptyString(message["reply_to_message_id"])
        ?? nonEmptyString(metadata?["replyToId"])
        ?? nonEmptyString(metadata?["reply_to_id"])
        ?? nonEmptyString(extra?["replyToId"])
        ?? nonEmptyString(extra?["reply_to_id"])
    }

    func descriptor(for row: [String: Any]) -> (title: String, text: String)? {
      guard (row["kind"] as? String) == "message",
        let message = row["message"] as? [String: Any],
        messageId(from: row) != nil
      else { return nil }

      let metadata = message["metadata"] as? [String: Any]
      let type = (nonEmptyString(message["type"]) ?? "text").lowercased()
      let isMe =
        (message["isMe"] as? Bool)
        ?? (message["isMe"] as? NSNumber)?.boolValue
        ?? false
      let trimmedPeerName = peerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
      let title = isMe
        ? "You"
        : (nonEmptyString(message["senderName"])
          ?? nonEmptyString(message["sender_name"])
          ?? nonEmptyString(metadata?["senderName"])
          ?? nonEmptyString(metadata?["sender_name"])
          ?? (trimmedPeerName.isEmpty ? "Reply" : trimmedPeerName))

      if let text = nonEmptyString(message["text"])
        ?? nonEmptyString(message["caption"])
        ?? nonEmptyString(metadata?["caption"])
      {
        return (title, text)
      }
      if let fileName = nonEmptyString(message["fileName"])
        ?? nonEmptyString(message["file_name"])
        ?? nonEmptyString(metadata?["fileName"])
        ?? nonEmptyString(metadata?["file_name"])
      {
        return (title, fileName)
      }

      switch type {
      case "image", "gif": return (title, "Photo")
      case "video": return (title, "Video")
      case "voice", "audio", "music", "mp3": return (title, "Voice message")
      case "sticker": return (title, "Sticker")
      case "file": return (title, "File")
      default: return (title, "Message")
      }
    }

    var previewsById: [String: (title: String, text: String)] = [:]
    previewsById.reserveCapacity(rows.count)
    for row in rows {
      guard let id = messageId(from: row), let preview = descriptor(for: row) else { continue }
      previewsById[id] = preview
    }

    return rows.map { row in
      guard (row["kind"] as? String) == "message",
        var message = row["message"] as? [String: Any],
        let replyToId = replyToId(from: message)
      else { return row }

      message["replyToId"] = replyToId
      if let preview = previewsById[replyToId] {
        if (nonEmptyString(message["replyPreviewTitle"])
          ?? nonEmptyString(message["reply_preview_title"])) == nil
        {
          message["replyPreviewTitle"] = preview.title
        }
        if (nonEmptyString(message["replyPreviewText"])
          ?? nonEmptyString(message["reply_preview_text"])) == nil
        {
          message["replyPreviewText"] = preview.text
        }
      }

      var resolvedRow = row
      resolvedRow["message"] = message
      return resolvedRow
    }
  }

  // MARK: - Persisted row heights (disk)

  private static func persistedHeightsFileURL(chatId: String) -> URL? {
    guard !chatId.isEmpty,
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { return nil }
    let dir = base.appendingPathComponent("VibeChatHeights", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let safe = String(chatId.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    return dir.appendingPathComponent("heights-\(safe).json")
  }

  /// `streamingStartDate` is intentionally excluded: rows that are still streaming are
  /// never persisted, and a settled row's state carries no date.
  private static func bubbleStateSignature(_ state: AgentTurnBubbleState) -> String {
    "\(state.isProgressExpanded ? 1 : 0).\(state.isRuntimeExpanded ? 1 : 0)."
      + "\(state.expandedStepIds.sorted().joined(separator: ",")).\(state.tallExpanded ? 1 : 0)"
  }

  /// Synchronous by design: the file is a few tens of KB and must be readable before
  /// the presentation seed's first sizing pass, which happens on this same runloop.
  private func loadPersistedRowHeights(chatId: String) {
    persistedHeightsWriteWorkItem?.cancel()
    persistedHeightsWriteWorkItem = nil
    persistedHeightsByKey = [:]
    persistedHeightMissLogBudget = 8
    persistedHeightsChatId = chatId
    guard !chatId.isEmpty,
      let url = Self.persistedHeightsFileURL(chatId: chatId),
      let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode([String: PersistedHeightEntry].self, from: data)
    else { return }
    persistedHeightsByKey = decoded
    NSLog(
      "[ChatOpen] heights RESTORE chat=%@ entries=%d",
      String(chatId.prefix(12)), decoded.count)
  }

  /// Exact-height fallback consulted only after the in-memory caches miss. On a hit the
  /// entry is promoted into the normal cache (with the live row) so every later lookup —
  /// including `hasExactProgressiveHeight` — takes the standard path.
  private func promotePersistedHeightIfAvailable(
    _ row: ChatListRow,
    rowWidth: CGFloat,
    state: AgentTurnBubbleState,
    contentVersion: String
  ) -> CGFloat? {
    guard !persistedHeightsByKey.isEmpty, let entry = persistedHeightsByKey[row.key] else {
      // No entry at all for a row the file should cover — the write side (admit)
      // dropped it. Named here so the heavy re-measured rows can be told apart from
      // genuinely new messages.
      if !persistedHeightsByKey.isEmpty, persistedHeightMissLogBudget > 0,
        bubbleUsesAgentTurnContent(row)
      {
        persistedHeightMissLogBudget -= 1
        NSLog(
          "[ChatOpen] height-promote MISS key=%@ reason=no-entry", String(row.key.suffix(14)))
      }
      return nil
    }
    let widthMatches = abs(entry.w - Double(rowWidth)) < 0.5
    let contentMatches =
      entry.v == contentVersion
      && entry.s == Self.bubbleStateSignature(state)
      && entry.sig == chatListRowContentSignature(row)
    // Transient preview: the content is identical, only the card width differs.
    // Reuse the real-width height as a close-enough estimate rather than
    // re-measuring the whole tail on the main thread mid-hold. Pure read — the
    // width-keyed in-memory cache and the shared on-disk file are left untouched
    // (never promote a narrow-width value that a real open would then trust).
    if isEphemeralPreview, contentMatches, !widthMatches {
      return CGFloat(entry.h)
    }
    guard widthMatches, contentMatches else {
      if persistedHeightMissLogBudget > 0 {
        persistedHeightMissLogBudget -= 1
        var reasons: [String] = []
        if abs(entry.w - Double(rowWidth)) >= 0.5 {
          reasons.append("w[\(Int(entry.w))→\(Int(rowWidth))]")
        }
        if entry.v != contentVersion { reasons.append("v[\(entry.v)→\(contentVersion)]") }
        if entry.s != Self.bubbleStateSignature(state) { reasons.append("state") }
        if entry.sig != chatListRowContentSignature(row) {
          // Name the field(s) that flipped, so the sig can be corrected surgically
          // (drop a height-inert flipper; keep a height-relevant one) instead of
          // removing fields by guesswork. Needs the fingerprint the write side
          // stored (agent rows only).
          if let persistedFields = entry.f {
            let flipped = chatListRowSignatureFlippedFieldNames(row, against: persistedFields)
            reasons.append(
              flipped.isEmpty ? "sig" : "sig[\(flipped.joined(separator: ","))]")
          } else {
            reasons.append("sig")
          }
        }
        NSLog(
          "[ChatOpen] height-promote MISS key=%@ reason=%@",
          String(row.key.suffix(14)), reasons.joined(separator: "+"))
      }
      return nil
    }
    persistedHeightsByKey.removeValue(forKey: row.key)
    let height = CGFloat(entry.h)
    let cacheEntry = RowHeightCacheEntry(
      row: row, rowWidth: rowWidth, state: state, height: height,
      contentVersion: contentVersion)
    if contentVersion.isEmpty {
      messageHeightCache[row.key] = cacheEntry
    } else {
      agentTurnHeightCache[row.key] = cacheEntry
    }
    return height
  }

  private func schedulePersistRowHeights() {
    // The preview list sizes at the narrow card width; persisting those heights
    // would overwrite the real chat's true-width on-disk cache. Never write.
    guard !isEphemeralPreview else { return }
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty, chatId == persistedHeightsChatId,
      persistedHeightsWriteWorkItem == nil
    else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.persistedHeightsWriteWorkItem = nil
      self.persistRowHeightsNow(chatId: chatId)
    }
    persistedHeightsWriteWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }

  private func persistRowHeightsNow(chatId: String) {
    guard chatId == engineChatId.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
    let liveKeys = Set(rows.map(\.key))
    // Snapshot on main (struct dictionaries, CoW copy); signature building and the
    // encode+write happen off-main — signatures over long transcripts are not free.
    let messageEntries = messageHeightCache
    let agentEntries = agentTurnHeightCache
    // Un-promoted survivors from the last restore stay in the file. Progressive sizing
    // only measures the viewport + warmup progress, so replacing the file with this
    // pass's caches decays coverage on every short visit (observed: 120 → 9 entries,
    // which fails the full-window seed gate and brings back the 108-row insert stall).
    let unpromotedEntries = persistedHeightsByKey
    guard let url = Self.persistedHeightsFileURL(chatId: chatId) else { return }
    Self.persistedHeightsWriteQueue.async {
      var entries: [String: PersistedHeightEntry] = unpromotedEntries
      var freshCount = 0
      var rejectedNotLive = 0
      var rejectedStreaming = 0
      var rejectedKeys: [String] = []
      func admit(_ key: String, _ cached: RowHeightCacheEntry) {
        guard liveKeys.contains(key) else {
          rejectedNotLive += 1
          return
        }
        guard !cached.row.isStreamingText, cached.state.streamingStartDate == nil else {
          rejectedStreaming += 1
          if rejectedKeys.count < 8 { rejectedKeys.append(String(key.suffix(14))) }
          return
        }
        freshCount += 1
        entries[key] = PersistedHeightEntry(
          w: Double(cached.rowWidth),
          s: Self.bubbleStateSignature(cached.state),
          h: Double(cached.height),
          v: cached.contentVersion,
          sig: chatListRowContentSignature(cached.row),
          // Fingerprint agent-turn rows only (the ones that thrash reason=sig).
          f: bubbleUsesAgentTurnContent(cached.row)
            ? chatListRowSignatureFieldHashes(cached.row) : nil)
      }
      for (key, cached) in messageEntries { admit(key, cached) }
      for (key, cached) in agentEntries { admit(key, cached) }
      guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else { return }
      try? data.write(to: url, options: [.atomic])
      NSLog(
        "[ChatOpen] heights PERSIST chat=%@ total=%d carried=%d fresh=%d rejLive=%d rejStream=%d rejKeys=[%@]",
        String(chatId.prefix(12)), entries.count, unpromotedEntries.count, freshCount,
        rejectedNotLive, rejectedStreaming, rejectedKeys.joined(separator: ","))
    }
  }

  // MARK: - Parsed-row reuse

  /// Names the top-level (and one nested level of) raw fields whose values differ —
  /// attribution for parse reuse-cache misses, so a cold-open re-parse storm can be
  /// traced to the specific volatile field instead of guessed at.
  private static func rawRowDiffKeys(_ old: NSDictionary, _ new: [String: Any]) -> [String] {
    var diffs: [String] = []
    let newDict = new as NSDictionary
    var allKeys = Set(old.allKeys.compactMap { $0 as? String })
    allKeys.formUnion(new.keys)
    for key in allKeys.sorted() {
      guard let a = old[key], let b = newDict[key] else {
        diffs.append("\(key)±")
        continue
      }
      if (a as AnyObject).isEqual(b) { continue }
      if let ad = a as? NSDictionary, let bd = b as? NSDictionary {
        var nested = Set(ad.allKeys.compactMap { $0 as? String })
        nested.formUnion(bd.allKeys.compactMap { $0 as? String })
        for nk in nested.sorted() {
          let na = ad[nk]
          let nb = bd[nk]
          if let na, let nb, (na as AnyObject).isEqual(nb) { continue }
          if na == nil, nb == nil { continue }
          diffs.append("\(key).\(nk)")
        }
      } else {
        diffs.append(key)
      }
    }
    return diffs
  }

  /// Compact value preview at a (possibly one-level-nested) key path, for diff logs.
  private static func rawRowValue(_ dict: NSDictionary, _ path: String) -> String {
    var current: Any? = dict
    for part in path.split(separator: ".").map(String.init) {
      guard let container = current as? NSDictionary else {
        current = nil
        break
      }
      current = container[part]
    }
    guard let current else { return "nil" }
    let described = String(describing: current)
    return described.count > 36 ? String(described.prefix(36)) + "…" : described
  }

  private func parsedRowsReusingCache(_ rawRows: [[String: Any]]) -> [ChatListRow] {
    var nextCache: [String: (raw: NSDictionary, row: ChatListRow)] = [:]
    nextCache.reserveCapacity(rawRows.count)
    var parsed: [ChatListRow] = []
    parsed.reserveCapacity(rawRows.count)
    var reuseMissCount = 0
    var reuseMissDiffs: [String] = []
    var reuseMissFieldCounts: [String: Int] = [:]
    for raw in rawRows {
      let rawKey = (raw["key"] as? String) ?? ""
      if !rawKey.isEmpty, let cached = reusableParsedRowsByKey[rawKey] {
        if cached.raw.isEqual(to: raw) {
          parsed.append(cached.row)
          nextCache[rawKey] = cached
          continue
        }
        // Cached entry exists but the raw changed — this re-parse is what turns the
        // cold-open flush into a reload storm. Attribute the differing fields with
        // their old→new values so the volatile side is identifiable from one log.
        reuseMissCount += 1
        if pendingPresentationSeedReconcile {
          // Bucket EVERY differing field across ALL misses (the 4-example cap below only
          // showed a sample — one dominant field means a single unresolved transform, a
          // long flat tail means genuine row churn). This histogram is what tells us
          // on-device whether the reply-preview seed fix closed the gap or something else
          // is still volatile.
          let diffKeys = Self.rawRowDiffKeys(cached.raw, raw)
          for key in diffKeys {
            let field = key.hasSuffix("±") ? String(key.dropLast()) : key
            reuseMissFieldCounts[field, default: 0] += 1
          }
          if reuseMissDiffs.count < 4 {
            let detail = diffKeys.prefix(2)
              .map { key -> String in
                let path = key.hasSuffix("±") ? String(key.dropLast()) : key
                return
                  "\(key)[\(Self.rawRowValue(cached.raw, path))→\(Self.rawRowValue(raw as NSDictionary, path))]"
              }
              .joined(separator: "+")
            reuseMissDiffs.append("\(String(rawKey.suffix(8))):\(detail)")
          }
        }
      }
      guard let row = ChatListRow(raw: raw) else { continue }
      parsed.append(row)
      if !rawKey.isEmpty {
        nextCache[rawKey] = (raw as NSDictionary, row)
      }
    }
    if pendingPresentationSeedReconcile, reuseMissCount > 0 {
      let fieldHistogram = reuseMissFieldCounts
        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ",")
      NSLog(
        "[ChatOpen] parse reuse-MISS chat=%@ count=%d of=%d fields=[%@] diffs=[%@]",
        String(engineChatId.prefix(12)), reuseMissCount, rawRows.count,
        fieldHistogram,
        reuseMissDiffs.joined(separator: " "))
    }
    if rawRows.count < reusableParsedRowsByKey.count, reusableParsedRowsByKey.count <= 400 {
      // Partial pass (e.g. the 16-row presentation seed over a warm-restored full
      // transcript): keep the wider cache alive, refreshed with this pass's results,
      // so the full flush immediately after still reuses instead of re-parsing.
      reusableParsedRowsByKey.merge(nextCache) { _, new in new }
    } else {
      reusableParsedRowsByKey = nextCache
    }
    return parsed
  }

  /// `rememberWarmTranscript` runs before UICollectionView asks for every item height.
  /// Refresh the cache record after layout so subsequent opens reuse those completed
  /// measurements instead of rebuilding rich AgentKit text during the next page push.
  private func refreshWarmTranscriptHeightSnapshot() {
    // Ride every completed-layout refresh: heights measured this pass reach disk too
    // (debounced), so the next cold open of this chat mounts with exact sizing.
    schedulePersistRowHeights()
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty, let snapshot = Self.warmTranscriptSnapshots[chatId] else { return }
    let liveKeys = Set(snapshot.rows.map(\.key))
    Self.warmTranscriptSnapshots[chatId] = WarmTranscriptSnapshot(
      rows: snapshot.rows,
      sourceRows: snapshot.sourceRows,
      messageHeightCache: messageHeightCache.filter { liveKeys.contains($0.key) },
      agentTurnHeightCache: agentTurnHeightCache.filter { liveKeys.contains($0.key) }
    )
  }

  /// Reopen fast path: the previous controller is gone, but its complete already-parsed
  /// snapshot and exact height cache are still safe to reuse. The navigation transition
  /// gets a bounded seed; the completed page mounts the whole snapshot at once.
  private func restoreWarmTranscriptIfAvailable(chatId: String) {
    guard rows.isEmpty, let snapshot = Self.warmTranscriptSnapshots[chatId] else { return }
    Self.warmTranscriptSnapshotOrder.removeAll { $0 == chatId }
    Self.warmTranscriptSnapshotOrder.append(chatId)
    sourceRowsPayload = snapshot.sourceRows
    messageHeightCache = snapshot.messageHeightCache
    agentTurnHeightCache = snapshot.agentTurnHeightCache
    // Arm parsed-row reuse with the snapshot's already-parsed transcript so the
    // post-push flush only re-parses rows whose raw payload actually changed.
    var reuseCache: [String: (raw: NSDictionary, row: ChatListRow)] = [:]
    reuseCache.reserveCapacity(snapshot.rows.count)
    let parsedByKey = Dictionary(
      snapshot.rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    for raw in snapshot.sourceRows {
      guard let key = raw["key"] as? String, !key.isEmpty, let row = parsedByKey[key] else {
        continue
      }
      reuseCache[key] = (raw as NSDictionary, row)
    }
    if !reuseCache.isEmpty { reusableParsedRowsByKey = reuseCache }
    if defersTranscriptUpdatesForPresentation {
      // Mount the snapshot as the presentation seed; nothing is retained for a flush
      // any more — presentation completion reconciles against ONE engine read (v2).
      installPresentationSeedIfNeeded(
        sourceRows: snapshot.sourceRows,
        preferredParsedRows: snapshot.rows
      )
      NSLog(
        "[ChatOpen] warm-cache DEFER chat=%@ cached=%d heights=%d",
        String(chatId.prefix(12)), max(snapshot.rows.count, snapshot.sourceRows.count),
        snapshot.messageHeightCache.count + snapshot.agentTurnHeightCache.count)
      return
    }
    windowedTranscriptSourceRows = nil
    windowedTranscriptVisibleCount = snapshot.rows.count
    rows = snapshot.rows
    usesProgressiveTranscriptSizing = rows.count > Self.largeTranscriptThreshold
    pruneAgentTurnState(for: rows)
    pruneStopCancelRequestedKeys(using: rows)
    syncComposerStopState()
    collectionView.reloadData()
    setNeedsLayout()
    NSLog(
      "[ChatOpen] warm-tail RESTORE chat=%@ visible=%d cached=%d",
      String(chatId.prefix(12)), rows.count, max(snapshot.rows.count, snapshot.sourceRows.count))
  }

  /// Parsing is cheap compared with rich-cell measurement, so retain every cached row in
  /// one stable collection. `sizeForItemAt` bounds open cost through progressive sizing;
  /// no identities are inserted merely because the user scrolled upward.
  private func windowedPayloadForParsing(_ fullRows: [[String: Any]]) -> [[String: Any]] {
    pendingPresentationSeedWindowStart = false
    windowedTranscriptSourceRows = nil
    windowedTranscriptVisibleCount = fullRows.count
    return fullRows
  }

  func setOpeningUnreadCount(_ value: Int) {
    openingUnreadCount = max(0, value)
    shouldApplyOpeningViewport = true
  }

  private static func persistedViewportKey(chatId: String) -> String {
    "\(persistedViewportKeyPrefix).\(chatId)"
  }

  private func loadPersistedOpeningViewport(chatId: String) {
    guard !chatId.isEmpty,
      let data = UserDefaults.standard.data(forKey: Self.persistedViewportKey(chatId: chatId)),
      let viewport = try? JSONDecoder().decode(PersistedViewport.self, from: data)
    else {
      persistedOpeningViewport = nil
      return
    }
    // Scroll memory is SAME-RUN ONLY (explicit product decision): reopening a chat
    // within one app run lands where you left off; a full app relaunch is a clean
    // slate that opens at the bottom like a fresh conversation. Cross-launch restore
    // was tried (72h mid-history anchors) and read as "the layout shifted" — the
    // leftover session surprised more than it helped.
    let sameRun = viewport.bootToken == Self.viewportBootToken
    let ageSeconds = Date().timeIntervalSince1970 - viewport.savedAt
    guard sameRun else {
      NSLog(
        "[ChatOpen] viewport LOAD chat=%@ dropped sameRun=N atBottom=%@ hasAnchor=%@ age=%.0fs",
        String(chatId.prefix(12)), viewport.atBottom ? "Y" : "N",
        (viewport.messageId?.isEmpty == false) ? "Y" : "N", ageSeconds)
      if viewport.atBottom == false, let key = reopenSnapshotKey() {
        // The raster captured at that close shows the dropped record's mid-history
        // viewport; this open lands at the bottom, so the raster would flash the wrong
        // rows. Runs before preloadReopenSnapshotFromDiskIfNeeded, so the disk twin is
        // gone before it could decode. Bottom-captured rasters stay: bottom ↔ bottom
        // is aligned and still buys the frame-one cover after a relaunch.
        Self.reopenSnapshotCache.removeObject(forKey: key)
        if let url = Self.reopenSnapshotFileURL(for: key) {
          Self.reopenSnapshotIOQueue.async { try? FileManager.default.removeItem(at: url) }
        }
      }
      // Clean up the dead record so every later open of this chat skips the decode.
      UserDefaults.standard.removeObject(forKey: Self.persistedViewportKey(chatId: chatId))
      persistedOpeningViewport = nil
      return
    }
    NSLog(
      "[ChatOpen] viewport LOAD chat=%@ restore=same-run atBottom=%@ hasAnchor=%@ age=%.0fs",
      String(chatId.prefix(12)),
      viewport.atBottom ? "Y" : "N", (viewport.messageId?.isEmpty == false) ? "Y" : "N",
      ageSeconds)
    persistedOpeningViewport = viewport
  }

  private func topVisibleMessageAnchor() -> (key: String, messageId: String, screenY: CGFloat)? {
    let visible = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
    for indexPath in visible where indexPath.item < rows.count {
      let row = rows[indexPath.item]
      guard row.kind == .message, let messageId = row.messageId, !messageId.isEmpty,
        let attributes = collectionView.layoutAttributesForItem(at: indexPath)
      else { continue }
      return (
        row.key,
        messageId,
        attributes.frame.minY - collectionView.contentOffset.y
      )
    }
    return nil
  }

  func persistViewportState() {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty, !rows.isEmpty, !shouldApplyOpeningViewport else { return }
    let atBottom = currentDistanceFromBottom() <= listBottomThreshold
    let anchor = atBottom ? nil : topVisibleMessageAnchor()
    let viewport = PersistedViewport(
      messageId: anchor?.messageId,
      screenY: Double(anchor?.screenY ?? 0.0),
      atBottom: atBottom,
      savedAt: Date().timeIntervalSince1970,
      bootToken: Self.viewportBootToken
    )
    guard let data = try? JSONEncoder().encode(viewport) else { return }
    UserDefaults.standard.set(data, forKey: Self.persistedViewportKey(chatId: chatId))
    persistedOpeningViewport = viewport
    // Leaving a chat with the keyboard UP and returning with it DOWN reportedly lands the
    // list shifted. This view is reused across open/close, so capture the keyboard-derived
    // geometry on BOTH sides of the boundary to see whether the saved anchor/atBottom was
    // measured against a keyboard inset that no longer exists at restore.
    NSLog(
      "[KbViewport] PERSIST chat=%@ kb=%.0f insetB=%.0f off=%.0f contentH=%.0f boundsH=%.0f atBottom=%@ anchor=%@ screenY=%.0f",
      String(chatId.prefix(12)), keyboardHeight, collectionView.contentInset.bottom,
      collectionView.contentOffset.y, collectionView.contentSize.height,
      collectionView.bounds.height, atBottom ? "Y" : "N",
      String((anchor?.messageId ?? "none").prefix(8)), anchor?.screenY ?? 0.0)
  }

  /// Applies exactly once, after the complete cached snapshot has mounted. New unread
  /// messages win over the saved viewport; otherwise reopening returns to the message and
  /// screen-space position the user left, with bottom as the safe fallback.
  @discardableResult
  private func applyOpeningViewportIfNeeded() -> Bool {
    guard shouldApplyOpeningViewport, !rows.isEmpty, searchQuery.isEmpty else { return false }
    shouldApplyOpeningViewport = false
    collectionView.layoutIfNeeded()
    NSLog(
      "[KbViewport] RESTORE chat=%@ kb=%.0f insetB=%.0f contentH=%.0f boundsH=%.0f savedAtBottom=%@ savedScreenY=%.0f",
      String(engineChatId.prefix(12)), keyboardHeight, collectionView.contentInset.bottom,
      collectionView.contentSize.height, collectionView.bounds.height,
      (persistedOpeningViewport?.atBottom ?? false) ? "Y" : "N",
      persistedOpeningViewport?.screenY ?? -1.0)

    let unreadTargetIndex: Int? = {
      guard openingUnreadCount > 0 else { return nil }
      let incomingIndices = rows.indices.filter { index in
        let row = rows[index]
        guard row.kind == .message, !row.isMe else { return false }
        return row.messageType != "typing" && row.messageType != "agent_actions"
      }
      guard !incomingIndices.isEmpty else { return nil }
      return incomingIndices.suffix(min(openingUnreadCount, incomingIndices.count)).first
    }()

    let savedTargetIndex: Int? = {
      guard unreadTargetIndex == nil,
        let messageId = persistedOpeningViewport?.messageId,
        !messageId.isEmpty
      else { return nil }
      return rows.firstIndex { $0.messageId == messageId }
    }()

    if let targetIndex = unreadTargetIndex ?? savedTargetIndex,
      let attributes = collectionView.layoutAttributesForItem(
        at: IndexPath(item: targetIndex, section: 0))
    {
      let screenY: CGFloat = unreadTargetIndex != nil
        ? 12.0
        : CGFloat(persistedOpeningViewport?.screenY ?? 12.0)
      let maxOffset = max(0.0, collectionView.contentSize.height - collectionView.bounds.height)
      let targetOffset = pixelAlignedValue(
        max(0.0, min(maxOffset, attributes.frame.minY - screenY)))
      performInternalScrollAdjustment {
        collectionView.setContentOffset(CGPoint(x: 0.0, y: targetOffset), animated: false)
      }
      shouldAutoScroll = currentDistanceFromBottom() <= listBottomThreshold
      previousOffsetY = collectionView.contentOffset.y
      NSLog(
        "[ChatOpen] viewport RESTORE chat=%@ reason=%@ row=%d unread=%d offset=%.0f",
        String(engineChatId.prefix(12)), unreadTargetIndex != nil ? "unread" : "saved",
        targetIndex, openingUnreadCount, targetOffset)
      openingUnreadCount = 0
      // Mid-history restores must show the jump chrome immediately, not after the
      // first scroll callback.
      updateJumpToBottomButtonVisibility()
      return true
    }

    scrollToBottom(animated: false, force: true)
    openingUnreadCount = 0
    NSLog(
      "[ChatOpen] viewport RESTORE chat=%@ reason=bottom saved=%@",
      String(engineChatId.prefix(12)), persistedOpeningViewport == nil ? "N" : "Y")
    updateJumpToBottomButtonVisibility()
    return true
  }

  /// Seed-time restore: when the freshly mounted presentation seed already contains the
  /// saved mid-history anchor and heights are exact, position the FIRST painted frame on
  /// it instead of mounting at the bottom and letting the post-appear flush jump there
  /// ~500ms later (the felt bottom→scroll-memory shift on open, which also re-exposed a
  /// whole new viewport of async-decoding media mid-view — the image pop/flicker).
  /// Conservative by construction: unread opens, bottom-saved records, progressive
  /// (estimated) sizing, search, or an anchor outside this seed window all return false
  /// with the restore flag still armed, so the post-appear flush restores exactly as
  /// before once the complete transcript is in.
  private func applySavedViewportAtSeedIfPossible() -> Bool {
    guard shouldApplyOpeningViewport, searchQuery.isEmpty, openingUnreadCount == 0,
      !usesProgressiveTranscriptSizing,
      let viewport = persistedOpeningViewport, viewport.atBottom == false,
      let messageId = viewport.messageId, !messageId.isEmpty,
      rows.contains(where: { $0.messageId == messageId })
    else { return false }
    let applied = applyOpeningViewportIfNeeded()
    if applied {
      NSLog(
        "[ChatOpen] viewport RESTORE-AT-SEED chat=%@ anchor=%@",
        String(engineChatId.prefix(12)), String(messageId.prefix(8)))
      // The restore teleported the offset AFTER the mount's layout pass, so the
      // anchor region's cells were never created (measured visible=3 of a full
      // viewport) — bubbles/images/expand toggles stayed invisible until a touch
      // dirtied the layout. Materialize the restored viewport in the same mount.
      materializeCellsAfterProgrammaticJump(context: "seed-restore")
    }
    return applied
  }

  private func hasExactProgressiveHeight(row: ChatListRow, rowWidth: CGFloat) -> Bool {
    let state = agentTurnBubbleState(for: row)
    if bubbleUsesAgentTurnContent(row) {
      let contentVersion =
        "\(row.plainContent?.count ?? row.text.count).\(row.agentProgressNodes.count)."
        + "\(row.agentProgressNodes.reduce(0) { $0 + $1.label.count }).\(row.isStreamingText)"
      guard let cached = agentTurnHeightCache[row.key] else {
        return promotePersistedHeightIfAvailable(
          row, rowWidth: rowWidth, state: state, contentVersion: contentVersion) != nil
      }
      return cached.rowWidth == rowWidth && cached.state == state
        && chatListRowContentEqual(cached.row, row)
        && cached.contentVersion == contentVersion
    }
    guard let cached = messageHeightCache[row.key] else {
      return promotePersistedHeightIfAvailable(
        row, rowWidth: rowWidth, state: state, contentVersion: "") != nil
    }
    return cached.rowWidth == rowWidth && cached.state == state
      && chatListRowContentEqual(cached.row, row)
  }

  /// Exact self-sizing remains on the main thread because the existing measurement path
  /// uses UIKit. One row per runloop bounds each slice; stable message anchoring absorbs
  /// estimate corrections above the viewport without moving the reader.
  private func scheduleProgressiveHeightWarmup() {
    progressiveHeightWarmupWorkItem?.cancel()
    progressiveHeightWarmupWorkItem = nil
    progressiveHeightWarmupGeneration &+= 1
    let generation = progressiveHeightWarmupGeneration
    guard usesProgressiveTranscriptSizing, !suppressesProgressiveHeightWarmup,
      rows.count > Self.largeTranscriptThreshold,
      window != nil, bounds.width > 1.0
    else {
      progressiveHeightWarmupKeys = []
      return
    }

    let visibleIndices = collectionView.indexPathsForVisibleItems.map(\.item).sorted()
    let visibleKeys = visibleIndices.compactMap { rows.indices.contains($0) ? rows[$0].key : nil }
    let visibleSet = Set(visibleKeys)
    progressiveHeightWarmupKeys = visibleKeys + rows.compactMap { row in
      guard row.kind == .message, !visibleSet.contains(row.key) else { return nil }
      return row.key
    }
    progressiveHeightWarmupStartedAt = ProcessInfo.processInfo.systemUptime
    progressiveHeightWarmupInitialCount = progressiveHeightWarmupKeys.count
    progressiveHeightWarmupMeasuredCount = 0
    scheduleNextProgressiveHeightWarmup(generation: generation, delay: 0.012)
  }

  private func scheduleNextProgressiveHeightWarmup(generation: UInt64, delay: TimeInterval) {
    let work = DispatchWorkItem { [weak self] in
      self?.performNextProgressiveHeightWarmup(generation: generation)
    }
    progressiveHeightWarmupWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func performNextProgressiveHeightWarmup(generation: UInt64) {
    guard generation == progressiveHeightWarmupGeneration,
      usesProgressiveTranscriptSizing, !progressiveHeightWarmupKeys.isEmpty
    else { return }
    // A detached list can't paint what it measures: a dismissed preview's
    // transcript kept sweeping off-window cells for ~30s of main-thread churn.
    // Abandon outright — a real (re)attach settles rows and reschedules fresh.
    guard window != nil else {
      progressiveHeightWarmupKeys = []
      progressiveHeightWarmupWorkItem = nil
      return
    }
    guard !isApplyingRowsUpdate, !collectionView.isTracking, !collectionView.isDragging,
      !collectionView.isDecelerating
    else {
      scheduleNextProgressiveHeightWarmup(generation: generation, delay: 0.08)
      return
    }

    let key = progressiveHeightWarmupKeys.removeFirst()
    guard let index = rows.firstIndex(where: { $0.key == key }), rows[index].kind == .message else {
      scheduleNextProgressiveHeightWarmup(generation: generation, delay: 0.0)
      return
    }
    let row = rows[index]
    let extras = groupMeasurementExtras(at: IndexPath(item: index, section: 0))
    if !hasExactProgressiveHeight(row: row, rowWidth: extras.measurementWidth) {
      progressiveHeightWarmupMeasuredCount += 1
      let anchor = topVisibleMessageAnchor()
      let wasNearBottom = currentDistanceFromBottom() <= listBottomThreshold
      let estimated = presentationSeedMessageHeight(row, rowWidth: extras.measurementWidth)
      let exact = estimateMessageHeight(row, rowWidth: extras.measurementWidth)
      if abs(exact - estimated) > 0.5 {
        UIView.performWithoutAnimation {
          flowLayout.invalidateLayout()
          collectionView.layoutIfNeeded()
          if wasNearBottom {
            scrollToBottom(animated: false, force: true)
          } else if let anchor,
            let newIndex = rows.firstIndex(where: { $0.key == anchor.key }),
            let attributes = collectionView.layoutAttributesForItem(
              at: IndexPath(item: newIndex, section: 0))
          {
            let maxOffset = max(
              0.0, collectionView.contentSize.height - collectionView.bounds.height)
            let offset = pixelAlignedValue(
              max(0.0, min(maxOffset, attributes.frame.minY - anchor.screenY)))
            performInternalScrollAdjustment {
              collectionView.setContentOffset(CGPoint(x: 0.0, y: offset), animated: false)
            }
          }
          // Group full-window seeds now reach this path too: a corrected height moves
          // every row below it, and the floating avatars are pinned to row geometry.
          if isGroupOrChannel {
            updateFloatingSenderAvatars()
          }
        }
      }
    }

    if progressiveHeightWarmupKeys.isEmpty {
      progressiveHeightWarmupWorkItem = nil
      // Only sweeps that measured something are interesting; every setRows settle
      // restarts a (usually all-cached) sweep and logging those would be noise.
      if progressiveHeightWarmupMeasuredCount > 0 {
        NSLog(
          "[ChatOpen] height-warmup DONE chat=%@ keys=%d measured=%d ms=%d sinceOpenMs=%d",
          String(engineChatId.prefix(12)),
          progressiveHeightWarmupInitialCount, progressiveHeightWarmupMeasuredCount,
          Int((ProcessInfo.processInfo.systemUptime - progressiveHeightWarmupStartedAt) * 1000),
          chatOpenStartedAt > 0
            ? Int((ProcessInfo.processInfo.systemUptime - chatOpenStartedAt) * 1000) : -1)
      }
      refreshWarmTranscriptHeightSnapshot()
      return
    }
    scheduleNextProgressiveHeightWarmup(generation: generation, delay: 0.012)
  }

  private static let scrollingDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    // Full month name ("July 20"), not the abbreviated "Jul 20" — the in-list day
    // divider and the floating scroll pill both read from here.
    formatter.setLocalizedDateFormatFromTemplate("MMMM d")
    return formatter
  }()

  private static let scrollingDayYearFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("MMMM d yyyy")
    return formatter
  }()

  private static func scrollingDateLabel(for date: Date) -> String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let currentYear = calendar.component(.year, from: Date())
    let rowYear = calendar.component(.year, from: date)
    return rowYear == currentYear
      ? scrollingDayFormatter.string(from: date)
      : scrollingDayYearFormatter.string(from: date)
  }

  private static func rawMessageDate(from raw: [String: Any]) -> Date? {
    guard let message = raw["message"] as? [String: Any] else { return nil }
    let value = message["timestampMs"] ?? message["timestamp_ms"]
    let milliseconds: Double?
    if let number = value as? NSNumber {
      milliseconds = number.doubleValue
    } else if let double = value as? Double {
      milliseconds = double
    } else if let int = value as? Int {
      milliseconds = Double(int)
    } else if let int64 = value as? Int64 {
      milliseconds = Double(int64)
    } else if let string = value as? String, let parsed = Double(string) {
      milliseconds = parsed
    } else {
      milliseconds = nil
    }
    guard let milliseconds, milliseconds > 0 else { return nil }
    let seconds = milliseconds > 10_000_000_000 ? milliseconds / 1000.0 : milliseconds
    return Date(timeIntervalSince1970: seconds)
  }

  private static func calendarDayKey(for date: Date) -> String {
    let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0, components.month ?? 0, components.day ?? 0)
  }

  /// The native engine and optimistic-send paths both produce message rows, but not every
  /// producer includes the day dividers used by the web payload. Normalize that omission
  /// after search filtering and canonical ordering, before transcript windowing. Keys are
  /// calendar-day identities, so reopening, a status reapply, and a cached prefix prepend
  /// all address the same separator instead of deleting/reinserting it.
  private static func rowsByInsertingDaySeparators(
    _ rawRows: [[String: Any]]
  ) -> [[String: Any]] {
    guard !rawRows.isEmpty else { return [] }
    var result: [[String: Any]] = []
    result.reserveCapacity(rawRows.count + 4)
    var lastMessageDayKey: String?

    for raw in rawRows {
      // Existing date rows are regenerated from the surviving messages below. This also
      // removes orphan separators after search/filtering and prevents mixed producer key
      // schemes from creating two pills for the same day.
      if (raw["kind"] as? String)?.lowercased() == "day" {
        continue
      }

      if let date = rawMessageDate(from: raw) {
        let dayKey = calendarDayKey(for: date)
        if dayKey != lastMessageDayKey {
          result.append([
            "kind": "day",
            "key": "chat-day-\(dayKey)",
            "label": scrollingDateLabel(for: date),
            "timestampMs": date.timeIntervalSince1970 * 1000.0,
          ])
          lastMessageDayKey = dayKey
        }
      }
      result.append(raw)
    }
    return result
  }

  /// Build once per rows application. `scrollViewDidScroll` only asks for the already
  /// formatted label of its top visible row; it never parses dates or payloads mid-fling.
  private static func scrollingDateLabels(from rawRows: [[String: Any]]) -> [String: String] {
    var result: [String: String] = [:]
    var currentLabel: String?
    for raw in rawRows {
      let key = (raw["key"] as? String) ?? ""
      if (raw["kind"] as? String) == "day" {
        let label = ((raw["label"] as? String) ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { currentLabel = label }
        if !key.isEmpty, let currentLabel { result[key] = currentLabel }
        continue
      }
      if let date = rawMessageDate(from: raw) {
        currentLabel = scrollingDateLabel(for: date)
      }
      if !key.isEmpty, let currentLabel { result[key] = currentLabel }
    }
    return result
  }

  private func cachedHistoryRevealTriggerOffset() -> CGFloat {
    let maxOffset = max(0.0, collectionView.contentSize.height - collectionView.bounds.height)
    // Start while the cached prefix is still comfortably above the viewport, rather
    // than waiting until it is already visible at 96pt. On the first short tail, leave
    // a little room below the current bottom so opening the chat does not immediately
    // start parsing history on the user's first one-pixel touch.
    let aheadOfViewport = max(96.0, collectionView.bounds.height * 1.2)
    return min(aheadOfViewport, max(96.0, maxOffset - 160.0))
  }

  private func ensureCachedHistoryPullIndicator() {
    guard !cachedHistoryPullIndicatorInstalled else { return }
    cachedHistoryPullIndicatorInstalled = true
    cachedHistoryPullIndicator.isUserInteractionEnabled = false
    cachedHistoryPullIndicator.alpha = 0.0
    cachedHistoryPullIndicator.transform = CGAffineTransform(scaleX: 0.78, y: 0.78)
    cachedHistoryPullIndicator.applyAppearance(
      isDark: appearance.isDark,
      color: appearance.timeColorThem
    )
    addSubview(cachedHistoryPullIndicator)
    layoutCachedHistoryPullIndicator()
  }

  private func layoutCachedHistoryPullIndicator() {
    guard cachedHistoryPullIndicatorInstalled else { return }
    let side: CGFloat = 34.0
    // Share the non-glass safe-area slot used by the scrolling date pill. Keeping this
    // viewport-only control out of the collection's content origin prevents it from
    // appearing behind the Dynamic Island/header or moving with prepended rows.
    let y = max(8.0, safeAreaInsets.top + 63.0)
    cachedHistoryPullIndicator.frame = CGRect(
      x: pixelAlignedValue((bounds.width - side) / 2.0),
      y: y,
      width: side,
      height: side
    )
  }

  private func showCachedHistoryPullProgress(_ progress: CGFloat) {
    ensureCachedHistoryPullIndicator()
    cachedHistoryPullIndicator.layer.removeAllAnimations()
    cachedHistoryPullIndicator.stopAnimating()
    let clamped = max(0.0, min(1.0, progress))
    cachedHistoryPullIndicator.setPullProgress(clamped)
    cachedHistoryPullIndicator.alpha = 0.18 + (0.82 * clamped)
    let scale = 0.78 + (0.22 * clamped)
    cachedHistoryPullIndicator.transform = CGAffineTransform(scaleX: scale, y: scale)
    bringSubviewToFront(cachedHistoryPullIndicator)
  }

  private func showCachedHistoryLoadingIndicator() {
    ensureCachedHistoryPullIndicator()
    cachedHistoryPullIndicator.layer.removeAllAnimations()
    cachedHistoryPullIndicator.alpha = 1.0
    cachedHistoryPullIndicator.transform = .identity
    cachedHistoryPullIndicator.startAnimating()
    bringSubviewToFront(cachedHistoryPullIndicator)
  }

  private func hideCachedHistoryPullIndicator(animated: Bool) {
    guard cachedHistoryPullIndicatorInstalled else { return }
    let finish = { [weak self] in
      guard let self else { return }
      guard !self.pendingHistoryRevealAfterScroll, !self.isRevealingOlderTranscriptRows else {
        return
      }
      // Engine older-history owns the spinner while a delayed load is still showing it.
      guard !self.olderHistorySpinnerVisible else { return }
      self.cachedHistoryPullIndicator.stopAnimating()
      self.cachedHistoryPullIndicator.alpha = 0.0
      self.cachedHistoryPullIndicator.transform = CGAffineTransform(scaleX: 0.78, y: 0.78)
    }
    guard animated, cachedHistoryPullIndicator.alpha > 0.01 else {
      finish()
      return
    }
    UIView.animate(
      withDuration: 0.16,
      delay: 0.0,
      options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
    ) {
      self.cachedHistoryPullIndicator.alpha = 0.0
      self.cachedHistoryPullIndicator.transform = CGAffineTransform(scaleX: 0.78, y: 0.78)
    } completion: { _ in
      finish()
    }
  }

  private func updateCachedHistoryPullIndicator(offsetY: CGFloat) {
    guard !isGroupOrChannel,
      searchQuery.isEmpty,
      let fullRows = windowedTranscriptSourceRows,
      windowedTranscriptVisibleCount < fullRows.count
    else {
      // Windowed path is inactive; do not clobber an engine older-history spinner.
      if !olderHistorySpinnerVisible {
        hideCachedHistoryPullIndicator(animated: false)
      }
      return
    }
    if pendingHistoryRevealAfterScroll || isRevealingOlderTranscriptRows {
      showCachedHistoryLoadingIndicator()
      return
    }
    guard collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    else {
      hideCachedHistoryPullIndicator(animated: false)
      return
    }

    // Fill the arc over the last short approach to the cached-prefix threshold. This is
    // purely visual: it never changes contentInset/contentOffset and cannot own touches.
    let trigger = cachedHistoryRevealTriggerOffset()
    let approach: CGFloat = max(120.0, collectionView.bounds.height * 0.18)
    let progress = (trigger + approach - offsetY) / approach
    if progress > 0.0 {
      showCachedHistoryPullProgress(progress)
    } else {
      hideCachedHistoryPullIndicator(animated: false)
    }
  }

  private func completeCachedHistoryReveal() {
    isRevealingOlderTranscriptRows = false
    olderHistorySpinnerVisible = false
    hideCachedHistoryPullIndicator(animated: true)
  }

  private func resetOlderHistoryPaginationState(clearExhausted: Bool) {
    olderHistoryLoadInFlight = false
    if clearExhausted {
      olderHistoryExhaustedForChat = false
    }
    olderHistoryPrependExpectedKey = nil
    olderHistoryPrependExpectedCount = 0
    olderHistoryPrependExpectedAt = 0
    olderHistoryLoadStartedAt = 0
    olderHistorySpinnerWorkItem?.cancel()
    olderHistorySpinnerWorkItem = nil
    olderHistoryTimeoutWorkItem?.cancel()
    olderHistoryTimeoutWorkItem = nil
    if olderHistorySpinnerVisible {
      olderHistorySpinnerVisible = false
      hideCachedHistoryPullIndicator(animated: false)
    }
  }

  private func clearOlderHistoryExpectation() {
    olderHistoryPrependExpectedKey = nil
    olderHistoryPrependExpectedCount = 0
    olderHistoryPrependExpectedAt = 0
  }

  private func expireOlderHistoryExpectationIfNeeded() {
    guard olderHistoryPrependExpectedKey != nil, olderHistoryPrependExpectedAt > 0 else { return }
    let age = ProcessInfo.processInfo.systemUptime - olderHistoryPrependExpectedAt
    if age > Self.olderHistoryExpectationTTL {
      clearOlderHistoryExpectation()
    }
  }

  /// When a load has been in flight long enough, show the shared pull indicator.
  /// Store-served pages are near-instant and must not flash it.
  private func scheduleOlderHistorySpinnerIfNeeded() {
    olderHistorySpinnerWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.olderHistorySpinnerWorkItem = nil
      guard self.olderHistoryLoadInFlight else { return }
      self.olderHistorySpinnerVisible = true
      self.showCachedHistoryLoadingIndicator()
    }
    olderHistorySpinnerWorkItem = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.olderHistorySpinnerDelay, execute: work)
  }

  private func scheduleOlderHistoryLoadTimeout() {
    olderHistoryTimeoutWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.olderHistoryTimeoutWorkItem = nil
      guard self.olderHistoryLoadInFlight else { return }
      self.olderHistoryLoadInFlight = false
      self.olderHistorySpinnerWorkItem?.cancel()
      self.olderHistorySpinnerWorkItem = nil
      if self.olderHistorySpinnerVisible {
        self.olderHistorySpinnerVisible = false
        self.hideCachedHistoryPullIndicator(animated: true)
      }
      // Leave the prepend expectation until its 15s TTL so a late page can still arm.
    }
    olderHistoryTimeoutWorkItem = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.olderHistoryLoadTimeout, execute: work)
  }

  private func finishOlderHistoryLoadBookkeeping(hideSpinner: Bool) {
    olderHistoryLoadInFlight = false
    olderHistorySpinnerWorkItem?.cancel()
    olderHistorySpinnerWorkItem = nil
    olderHistoryTimeoutWorkItem?.cancel()
    olderHistoryTimeoutWorkItem = nil
    olderHistoryLoadStartedAt = 0
    if hideSpinner, olderHistorySpinnerVisible {
      olderHistorySpinnerVisible = false
      hideCachedHistoryPullIndicator(animated: true)
    }
  }

  /// Arms `requestsNextHistoryRevealPrepend` when a grown payload still contains the
  /// remembered first-row key with new rows above it. Unrelated ticks leave the
  /// expectation alone until TTL / chat switch.
  private func armOlderHistoryPrependIfNeeded(for nextRows: [[String: Any]]) {
    expireOlderHistoryExpectationIfNeeded()
    guard let expectedKey = olderHistoryPrependExpectedKey, !expectedKey.isEmpty else { return }
    guard
      let expectedIndex = nextRows.firstIndex(where: { ($0["key"] as? String) == expectedKey })
    else {
      // Partial / unrelated payload — do not consume the expectation.
      return
    }
    // New rows above the remembered key → strict top-prepend.
    guard expectedIndex > 0 else { return }

    requestsNextHistoryRevealPrepend = true
    NSLog(
      "[ChatOpen] older-history PREPEND-ARMED chat=%@ expected=%@ idx=%d count=%d→%d",
      String(engineChatId.prefix(12)),
      String(expectedKey.prefix(16)),
      expectedIndex,
      olderHistoryPrependExpectedCount,
      nextRows.count)
    clearOlderHistoryExpectation()
    // Keep the spinner up until the anchored prepend completes (historyRevealCompleted).
    finishOlderHistoryLoadBookkeeping(hideSpinner: false)
  }

  /// Demand-load one older engine page when the user scrolls near the top of a normal chat.
  /// Never call ChatEngine from the main-thread scroll callback — it syncs an internal queue.
  private func maybeRequestOlderChatHistory(offsetY: CGFloat) {
    expireOlderHistoryExpectationIfNeeded()

    guard !isInternalScrollAdjustment,
      !olderHistoryLoadInFlight,
      !olderHistoryExhaustedForChat,
      searchQuery.isEmpty,
      currentBridgeProvider == nil,
      (collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating),
      offsetY <= Self.olderHistoryTriggerOffsetY
    else { return }

    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return }

    let firstKey =
      rows.first(where: { $0.kind == .message })?.key
      ?? rows.first?.key
    let rowCount = rows.count
    guard let firstKey, !firstKey.isEmpty else { return }

    olderHistoryLoadInFlight = true
    olderHistoryLoadStartedAt = ProcessInfo.processInfo.systemUptime
    olderHistoryPrependExpectedKey = firstKey
    olderHistoryPrependExpectedCount = rowCount
    olderHistoryPrependExpectedAt = olderHistoryLoadStartedAt
    scheduleOlderHistorySpinnerIfNeeded()
    scheduleOlderHistoryLoadTimeout()

    NSLog(
      "[ChatOpen] older-history REQUEST chat=%@ offset=%.0f expected=%@ rows=%d",
      String(chatId.prefix(12)), offsetY, String(firstKey.prefix(16)), rowCount)

    chatListEngineBindingQueue.async { [weak self] in
      // Public ChatEngine methods block via syncOnQueue — never call from main scroll.
      let started = ChatEngine.shared.loadOlderChatHistory(chatId: chatId)
      let hasOlder = ChatEngine.shared.hasOlderChatHistory(chatId: chatId)
      DispatchQueue.main.async {
        guard let self else { return }
        // Chat switched while the probe was in flight.
        let current = self.engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == chatId else { return }

        if !started {
          if !hasOlder {
            // No more pages for this chat until the id changes.
            self.olderHistoryExhaustedForChat = true
            self.clearOlderHistoryExpectation()
            self.finishOlderHistoryLoadBookkeeping(hideSpinner: true)
          }
          // else: already loading / transient deny — keep expectation + in-flight so a
          // concurrent page can still arm the prepend; the 10s timeout is the backstop.
          return
        }
        // Load accepted (store-served or network started). Spinner / timeout already armed;
        // prepend arming happens when the grown payload arrives via setRows/applyRows.
      }
    }
  }

  private func maybeRevealOlderTranscriptRows(offsetY: CGFloat) {
    // Also drive engine older-history pagination (windowed source path below is dead —
    // windowedTranscriptSourceRows is always nil). Keep both so a future windowed
    // restore still works without another scroll hook.
    maybeRequestOlderChatHistory(offsetY: offsetY)

    let revealTriggerOffset = cachedHistoryRevealTriggerOffset()

    guard !isRevealingOlderTranscriptRows,
      !pendingHistoryRevealAfterScroll,
      searchQuery.isEmpty,
      (collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating),
      offsetY <= revealTriggerOffset,
      let fullRows = windowedTranscriptSourceRows,
      windowedTranscriptVisibleCount < fullRows.count,
      !sourceRowsPayload.isEmpty
    else { return }

    pendingHistoryRevealAfterScroll = true
    if !isGroupOrChannel {
      showCachedHistoryLoadingIndicator()
    }
    NSLog(
      "[ChatOpen] history-window QUEUE chat=%@ visible=%d of %d offset=%.0f trigger=%.0f",
      String(engineChatId.prefix(12)), windowedTranscriptVisibleCount, fullRows.count,
      offsetY, revealTriggerOffset)
  }

  private func performPendingHistoryRevealIfNeeded(trigger: String) {
    guard pendingHistoryRevealAfterScroll else { return }
    // A deferred row/status update may still own the collection batch when the gesture
    // settles. Keep the latch alive; finishRowsUpdate consumes it once UIKit is idle.
    guard !isApplyingRowsUpdate else { return }
    pendingHistoryRevealAfterScroll = false
    guard !isRevealingOlderTranscriptRows,
      !collectionView.isTracking,
      !collectionView.isDragging,
      !collectionView.isDecelerating,
      searchQuery.isEmpty,
      let fullRows = windowedTranscriptSourceRows,
      windowedTranscriptVisibleCount < fullRows.count,
      !sourceRowsPayload.isEmpty
    else {
      hideCachedHistoryPullIndicator(animated: true)
      return
    }

    isRevealingOlderTranscriptRows = true
    if !isGroupOrChannel {
      showCachedHistoryLoadingIndicator()
    }
    windowedTranscriptVisibleCount = fullRows.count
    let sourceRows = sourceRowsPayload
    NSLog(
      "[ChatOpen] history-window REVEAL chat=%@ visible=%d of %d trigger=%@",
      String(engineChatId.prefix(12)), windowedTranscriptVisibleCount, fullRows.count, trigger)
    // End-scroll delegates are still inside UIKit's callback stack. Apply on the next
    // runloop, when the pan/deceleration transaction is completely finished.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.requestsNextHistoryRevealPrepend = true
      self.setRows(sourceRows)
    }
  }

  /// The hosting controller toggles this around its navigation transition. Pipeline-v2:
  /// nothing is retained during the push — the mounted seed carries the transition, and
  /// releasing the defer reconciles it against ONE coalesced off-main engine read (the
  /// same path chatDelta updates use). Render-aware equality makes the no-change case a
  /// zero-repaint reconcile; real changes batch without animations into the seed.
  func setDefersTranscriptUpdatesForPresentation(_ value: Bool) {
    guard defersTranscriptUpdatesForPresentation != value else { return }
    defersTranscriptUpdatesForPresentation = value
    guard !value else { return }
    NSLog(
      "[ChatOpen] presentation-complete chat=%@ — reconciling from engine",
      String(engineChatId.prefix(12)))
    refreshRowsFromEngineDelta()
    scheduleProgressiveHeightWarmup()
  }

  /// Called from the destination controller's `viewDidAppear`, after UIKit has released
  /// the navigation transaction.
  func completeTranscriptPresentation() {
    guard defersTranscriptUpdatesForPresentation else { return }
    DispatchQueue.main.async { [weak self] in
      self?.setDefersTranscriptUpdatesForPresentation(false)
    }
  }

  /// Keep a real (but bounded) transcript tail on screen throughout the navigation push.
  /// `reloadData` only installs identities here; seed sizing deliberately avoids rich
  /// AgentKit measurement. The normal rows pipeline replaces this seed after viewDidAppear.
  private func installPresentationSeedIfNeeded(
    sourceRows: [[String: Any]],
    preferredParsedRows: [ChatListRow]? = nil
  ) {
    guard defersTranscriptUpdatesForPresentation, rows.isEmpty, !sourceRows.isEmpty else {
      return
    }
    if window == nil {
      // Detached = the push hasn't presented this view yet. Mount nothing now — stash
      // the freshest inputs and let didMoveToWindow mount them one tick after the
      // transition's first frame commits. Repeated calls during the defer window
      // (route rows, engine snapshot, warm restore) keep replacing the stash.
      deferredPresentationSeedSourceRows = sourceRows
      // Preferred rows are only valid for the sourceRows they were parsed from; a
      // stash replace without its own preferred set must drop the old one (the reuse
      // cache still parses unchanged rows cheaply, changed rows parse fresh).
      deferredPresentationSeedPreferredRows = preferredParsedRows
      deferredPresentationSeedStashedAt = ProcessInfo.processInfo.systemUptime
      NSLog(
        "[ChatOpen] presentation-seed DEFER chat=%@ rows=%d (await window attach)",
        String(engineChatId.prefix(12)), sourceRows.count)
      return
    }
    deferredPresentationSeedSourceRows = nil
    deferredPresentationSeedPreferredRows = nil
    let seedStartedAt = ProcessInfo.processInfo.systemUptime
    var seedPhaseMarkAt = seedStartedAt
    func seedPhaseMs() -> Int {
      let now = ProcessInfo.processInfo.systemUptime
      defer { seedPhaseMarkAt = now }
      return Int((now - seedPhaseMarkAt) * 1000)
    }

    // Resolve reply previews on the seed's source with the EXACT transform the post-appear
    // flush uses (rowsByAttachingReplyPreviews wraps rowsByResolvingReplyPreviews with the
    // same peer name). The setRows-DEFER seed caller passes raw effectiveRows, so without
    // this the seed parsed preview-less raw while the flush re-attached previews — every
    // reply row then missed the parse-reuse cache (the wasted 77-of-128 re-parse + ~53ms
    // setRows stall that stuttered the reopen-snapshot fade and flickered group avatars).
    // Fill-nil-only + identical output ⇒ this can only REDUCE the flush diff, never add
    // one, and is a no-op for the warm-snapshot caller (already resolved). Runs BEFORE day
    // separators so synthesized rows never feed previewsById.
    let resolvedSource = rowsByAttachingReplyPreviews(sourceRows)
    // Normalize the COMPLETE source before taking the suffix, exactly as the real rows
    // pipeline does. Taking messages first and synthesizing day rows afterward produces
    // a different boundary and was the source of the visible 5 -> 16 replacement.
    let normalizedSource = Self.rowsByInsertingDaySeparators(resolvedSource)
    guard !normalizedSource.isEmpty else { return }
    // Decoupled push: when the whole transcript's parse and heights are already paid
    // for (warm/prewarm snapshot in the reuse cache + persisted disk heights), mount
    // it all during the navigation push. The post-appear flush then reconciles as
    // near-equal instead of batch-inserting ~100 rows a second after the open. Rows
    // that miss coverage fall back to the bounded tail — today's behavior.
    var fullWindow = false
    var fullWindowHeightsCovered = false
    if normalizedSource.count > Self.initialTranscriptWindow {
      var messageRowCount = 0
      var parsedHits = 0
      var heightHits = 0
      for raw in normalizedSource {
        guard let key = raw["key"] as? String, !key.isEmpty else { continue }
        // Synthesized day rows parse and size trivially; exclude them from coverage.
        if key.hasPrefix("chat-day-") { continue }
        messageRowCount += 1
        if reusableParsedRowsByKey[key] != nil { parsedHits += 1 }
        if messageHeightCache[key] != nil || agentTurnHeightCache[key] != nil
          || persistedHeightsByKey[key] != nil
        {
          heightHits += 1
        }
      }
      if messageRowCount > 0 {
        // Parse coverage keeps the seed cheapest: reused rows mean the post-appear flush
        // reconciles mode=equal instead of batch-inserting ~100 rows.
        let parseCovered = parsedHits * 100 >= messageRowCount * 95
        fullWindowHeightsCovered = heightHits * 100 >= messageRowCount * 90
        // ...but reusableParsedRowsByKey is IN-MEMORY, so a cold launch — or any chat that
        // missed the bounded launch prewarm — has zero parse hits and could NEVER qualify.
        // Those opens mounted a 16-row tail and then batch-inserted the remainder ~800ms
        // later: the "chat opens empty / still only 16 rows even though it's cached"
        // report, which also cost a 145ms stall (layoutMs=120) right after the open.
        //
        // Disk-persisted heights DO survive relaunch, and they are the signal that makes
        // the mount cheap: with a known height, sizeForItemAt is a dictionary lookup.
        // Re-parsing the rest is comparatively trivial (~4ms for 130 rows, measured, vs
        // the 120ms layout pass it replaces), so height coverage alone is enough to mount
        // the whole cached transcript during the push instead of after it.
        fullWindow =
          parseCovered
          || (fullWindowHeightsCovered
            && normalizedSource.count <= Self.coldFullWindowMountLimit)
      }
    }
    let seedNormalizeMs = seedPhaseMs()
    let visibleCount =
      fullWindow
      ? normalizedSource.count
      : min(Self.initialTranscriptWindow, normalizedSource.count)
    let normalizedTail = Array(normalizedSource.suffix(visibleCount))
    let parsedTail = parsedRowsReusingCache(normalizedTail)
    let seedParseMs = seedPhaseMs()
    let preferredByKey = Dictionary(
      uniqueKeysWithValues: (preferredParsedRows ?? []).map { ($0.key, $0) })
    var seedRows = parsedTail.map { preferredByKey[$0.key] ?? $0 }
    seedRows = seedRows.filter { row in
      guard row.messageType != "agent_progress" else { return false }
      guard !Self.isUsageLimitRow(row) else { return false }
      guard !(bubbleUsesAgentTurnContent(row) && agentTurnBubbleIsCompactThinking(row)) else {
        return false
      }
      // Mirror the pipeline's inbox split: rows it routes out of the transcript must
      // not be seeded either, or every open mounts zombies the first flush deletes.
      if row.kind == .message,
        row.hiddenFromTranscript
          || (eventInboxModeEnabled && row.isEventNotification && !row.isEventInboxSummary)
      {
        return false
      }
      return true
    }
    // Run the flush's REMAINING post-parse stages too — any stage the seed skips
    // mounts rows the first flush must delete, and deleting them reloads their heavy
    // AgentKit neighbors on every open (the measured 70-200ms reconcile stall). The
    // same-turn high-water dedup is what strips duplicate team-run rows.
    seedRows = bridgeFreshFiltered(seedRows)
    seedRows = extractBridgeCommandRows(seedRows, reportToHost: false)
    seedRows = rowsPreservingAgentTurnHighWater(seedRows)
    if currentBridgeProvider != nil,
      (bridgeLoadedSessionId
        ?? ChatEngine.shared.liveBridgeSessionId(
          chatId: engineChatId.trimmingCharacters(in: .whitespacesAndNewlines))) == nil,
      seedRows.count > Self.agentTranscriptWindow
    {
      seedRows = Array(seedRows.suffix(Self.agentTranscriptWindow))
    }
    let seedFilterMs = seedPhaseMs()
    guard !seedRows.isEmpty else { return }

    if isGroupOrChannel {
      seedRows = seedRows.map { row in
        var next = row
        next.isGroupOrChannel = true
        return next
      }
    }

    rows = seedRows
    scrollingDateLabelsByRowKey = Self.scrollingDateLabels(from: normalizedTail)
    // A group tail seed must be frame-stable because its sender labels and floating
    // avatars are tied to row geometry — it is bounded to 16 rows, so measure those
    // through the exact cached path on first paint. DMs keep the cheaper estimate that
    // avoids rich AgentKit measurement during navigation. A full-window mount sizes
    // exactly only when the coverage gate found cached heights for ~everything;
    // otherwise it must NOT run heavy AgentKit measurement during the push — mount on
    // estimates and let the progressive warmup correct heights after the transition.
    usesProgressiveTranscriptSizing =
      fullWindow ? !fullWindowHeightsCovered : !isGroupOrChannel
    pendingPresentationSeedReconcile = true
    pendingPresentationSeedWindowStart = true
    pruneAgentTurnState(for: seedRows)
    pruneStopCancelRequestedKeys(using: seedRows)
    syncComposerStopState()
    UIView.performWithoutAnimation {
      flowLayout.invalidateLayout()
      collectionView.reloadData()
      if collectionView.bounds.width > 1.0, collectionView.bounds.height > 1.0 {
        // Avatar placement consumes visible-item layout attributes. Materialize the
        // bounded seed layout now so group avatars join the first painted frame instead
        // of appearing only after the authoritative transcript reconciliation.
        collectionView.layoutIfNeeded()
        if lastKnownViewportHeight > 0.5 {
          // Post-commit mount: the first real layout already ran on the empty shell
          // and owned the initial positioning, so this pass must land the freshly
          // mounted transcript on the latest message itself — or directly on the saved
          // mid-history anchor when this seed already contains it, so the first painted
          // frame IS the restored position instead of bottom-then-jump.
          updateBottomAnchorInset()
          collectionView.layoutIfNeeded()
          if !applySavedViewportAtSeedIfPossible() {
            scrollToBottom(animated: false, force: true)
          }
          emitViewport(force: true)
        }
        updateFloatingSenderAvatars()
        if isGroupOrChannel {
          NSLog(
            "[AvatarPin] presentation-seed ready visible=%d avatars=%d",
            collectionView.indexPathsForVisibleItems.count,
            senderAvatarViews.count)
        }
      } else {
        // Pre-attachment seeds receive their first real layout from layoutSubviews,
        // which also refreshes the floating-avatar overlay.
        setNeedsLayout()
      }
    }
    let seedMountMs = seedPhaseMs()
    NSLog(
      "[ChatOpen] presentation-seed chat=%@ visible=%d retained=%d cachedHeights=%d sizing=%@ window=%@ normMs=%d parseMs=%d filterMs=%d mountMs=%d totalMs=%d sinceOpenMs=%d",
      String(engineChatId.prefix(12)), seedRows.count, sourceRows.count,
      messageHeightCache.count + agentTurnHeightCache.count,
      usesProgressiveTranscriptSizing ? "estimated" : "exact",
      fullWindow ? "full" : "tail",
      seedNormalizeMs, seedParseMs, seedFilterMs, seedMountMs,
      Int((ProcessInfo.processInfo.systemUptime - seedStartedAt) * 1000),
      chatOpenStartedAt > 0
        ? Int((ProcessInfo.processInfo.systemUptime - chatOpenStartedAt) * 1000) : -1)
    // The seed just mounted the real transcript (positioned at bottom or the restored
    // anchor). Hand off from the raster NOW — every actual mount path runs through
    // here, whereas the POST-COMMIT wrapper's removal only covered its own path, so
    // the overlay used to sit on top of live content until the post-appear flush
    // (~700ms): a stale/flat raster over a ready list was the felt "empty chat".
    // Instant, never a crossfade: identical content swaps invisibly and newer content
    // cuts cleanly in one frame — the 0.15s alpha dissolve is exactly the "shifting
    // opacity" the flicker reports describe (Telegram never cross-fades a chat in).
    removeReopenSnapshotOverlay(reason: "seed-mounted", animated: false)
    removeSeedLoadingIndicator(reason: "seed-mounted")
    // Late layout passes (exact text sizing, inset settle) can grow content AFTER the
    // bottom landing, leaving the list a few points short of the true bottom with
    // nothing re-evaluating ("it's not at the very bottom, needs a slight scroll").
    // Verify twice after things settle; each check logs the drift it repairs.
    scheduleBottomIntegrityChecks()
  }

  private var userHasScrolledSinceOpen = false

  private func scheduleBottomIntegrityChecks() {
    let openChatId = engineChatId
    for delay in [1.2, 2.6] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.verifyBottomIntegrity(context: "post-seed-\(delay)s", armedChatId: openChatId)
      }
    }
  }

  /// Self-heal for silent bottom drift on a fresh open. Only acts when the user has
  /// not touched the list since the open, we still believe we're pinned to the bottom,
  /// and no other offset owner is active — then a short offset means late layout moved
  /// the content bottom out from under the landing.
  private func verifyBottomIntegrity(context: String, armedChatId: String) {
    guard window != nil, engineChatId == armedChatId, !rows.isEmpty,
      !userHasScrolledSinceOpen, shouldAutoScroll,
      !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating,
      !isBottomGlideInFlight, !isApplyingRowsUpdate, !agentStreaming,
      persistedOpeningViewport?.atBottom != false
    else { return }
    let maxOffset = max(0.0, collectionView.contentSize.height - collectionView.bounds.height)
    let drift = maxOffset - collectionView.contentOffset.y
    guard drift > 8.0 else { return }
    NSLog(
      "[ChatOpen] bottom DRIFT context=%@ chat=%@ dy=%.0f — re-pin",
      context, String(engineChatId.prefix(12)), drift)
    scrollToBottom(animated: false, force: true)
  }

  /// Real clears opt in explicitly. Empty payloads emitted by route/input/status setup are
  /// refresh signals, not transcript deletion; accepting them used to produce 8 -> 0 -> 8
  /// immediately after every warm restore.
  func clearRows() {
    if isApplyingRowsUpdate {
      DispatchQueue.main.async { [weak self] in self?.clearRows() }
      return
    }
    allowsNextExplicitEmptyRows = true
    applyRows([], authority: .fullSnapshot)
  }

  func setRows(_ nextRows: [[String: Any]]) {
    applyRows(nextRows, authority: .incremental)
  }

  func setAuthoritativeRows(_ nextRows: [[String: Any]]) {
    applyRows(nextRows, authority: .fullSnapshot)
  }

  private func applyRows(_ nextRows: [[String: Any]], authority: RowsAuthority) {
    let startedAt = ProcessInfo.processInfo.systemUptime
    // Engine older-history pages arrive through the normal rows pipeline as a top-prepend.
    // Arm the existing strict history-reveal path before consuming the one-shot flag.
    armOlderHistoryPrependIfNeeded(for: nextRows)
    let isHistoryRevealPrepend = requestsNextHistoryRevealPrepend
    requestsNextHistoryRevealPrepend = false
    let isExplicitEmpty = allowsNextExplicitEmptyRows
    allowsNextExplicitEmptyRows = false
    let traceChatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    // Empty network/bridge snapshots are refresh signals, never transcript deletion.
    // Only clearRows() arms allowsNextExplicitEmptyRows, so even a nominally-authoritative
    // empty refresh cannot erase an already-visible or retained conversation.
    if nextRows.isEmpty,
      !isExplicitEmpty,
      (!rows.isEmpty || !sourceRowsPayload.isEmpty || !nativeEngineRowsById.isEmpty
        || !nativeOutgoingRowsById.isEmpty)
    {
      NSLog(
        "[ChatOpen] setRows KEEP visible=%d retained=%d chat=%@ reason=non-explicit-empty authority=%@",
        rows.count, sourceRowsPayload.count, String(engineChatId.prefix(12)),
        authority == .fullSnapshot ? "full" : "incremental")
      return
    }
    // Delivery/status/stream emissions are allowed to coalesce while UIKit owns a user
    // gesture. Applying them synchronously here was the remaining 55–64 ms scroll hitch.
    // A local-history mount is already guarded by advanceCachedHistoryWarmup and remains
    // eligible so its strict prepend bookkeeping cannot be lost.
    if !isHistoryRevealPrepend, !isExplicitEmpty,
      collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    {
      rowsDeferredUntilScrollSettles = nextRows
      rowsDeferredUntilScrollSettlesAuthority = authority
      rowsDeferredUntilScrollSettlesHistoryPrepend = false
      return
    }
    VibeDebugLog.log(
      "[ChatListView] setRows called — count: %d, isApplying: %@", nextRows.count,
      isApplyingRowsUpdate ? "true" : "false")
    chatListUITrace(
      "ChatListView setRows start chatId=\(traceChatId.isEmpty ? "<empty>" : String(traceChatId.prefix(12))) incoming=\(nextRows.count) current=\(rows.count) applying=\(isApplyingRowsUpdate ? "Y" : "N") searchActive=\(searchQuery.isEmpty ? "N" : "Y")"
    )
    // Queue the raw update before it can touch sourceRowsPayload. Previously a partial or
    // empty snapshot arriving during a batch replaced the retained baseline immediately,
    // then the queued pass rebuilt from that damaged source and made messages disappear.
    if isApplyingRowsUpdate {
      pendingRowsPayload = nextRows
      pendingRowsAuthority = authority
      pendingRowsHistoryRevealPrepend = isHistoryRevealPrepend
      chatListUITrace(
        "ChatListView setRows queued chatId=\(traceChatId.isEmpty ? "<empty>" : String(traceChatId.prefix(12))) incoming=\(nextRows.count)"
      )
      return
    }
    if isExplicitEmpty {
      liveAgentTurnHighWaterByKey.removeAll()
    }
    // Pipeline-v2: no warm-baseline union — mergedRowsPayload's native-primary path
    // already replaces partial incremental arrays with the full engine read once
    // history is loaded, and pre-history partial arrays ARE the truth.
    let effectiveRows = nextRows
    if defersTranscriptUpdatesForPresentation, !isExplicitEmpty {
      // Mid-push: keep the seed fresh; presentation completion reconciles from the
      // engine, so nothing is retained here any more.
      installPresentationSeedIfNeeded(sourceRows: effectiveRows)
      VibeDebugLog.log(
        "[ChatOpen] setRows presentation-DEFER chat=%@ incoming=%d authority=%@",
        String(engineChatId.prefix(12)), nextRows.count,
        authority == .fullSnapshot ? "full" : "incremental")
      return
    }
    // A real mount supersedes any still-unmounted seed stash (e.g. the didAppear flush
    // racing a pop that detached the view before its post-commit mount tick ran).
    deferredPresentationSeedSourceRows = nil
    deferredPresentationSeedPreferredRows = nil
    removeReopenSnapshotOverlay(reason: "rows-applied", animated: false)
    removeSeedLoadingIndicator(reason: "rows-applied")
    isApplyingRowsUpdate = true
    _setRowsGeneration &+= 1
    let mySetRowsGeneration = _setRowsGeneration

    // Resolve reply previews on the live path too — the warm snapshot (reopen seed) and
    // the reuse cache are both populated from `visibleRows`, and the launch prewarm path
    // already enriches (see prewarmWarmTranscriptSnapshot). Without this, the seed cached
    // preview-less raw while the post-appear flush re-attached previews, so every reply
    // row missed the parse-reuse cache (the felt 77-of-128 re-parse + 54ms stall that
    // stuttered the reopen-snapshot fade). Idempotent: the resolver only fills nil fields.
    let mergedRows =
      isExplicitEmpty ? [] : rowsByAttachingReplyPreviews(mergedRowsPayload(from: effectiveRows))
    let visibleRows = Self.rowsByInsertingDaySeparators(filterRowsForSearch(mergedRows))
    var retainedSourceRows = effectiveRows
    if effectiveRows.isEmpty, !visibleRows.isEmpty {
      // Engine authority supplied the effective transcript. Retain that full payload so
      // incremental history reveal and later route refreshes never fall back to raw [].
      retainedSourceRows = visibleRows
    }
    let rowsToParse = windowedPayloadForParsing(visibleRows)
    let nextScrollingDateLabels = Self.scrollingDateLabels(from: rowsToParse)
    let applyMergeDoneAt = ProcessInfo.processInfo.systemUptime
    let applyMergeMs = Int((applyMergeDoneAt - startedAt) * 1000)
    // Flush passes that reconcile a mounted presentation seed attribute every row a
    // filter stage drops — a seed/flush disagreement here is what mounts zombies the
    // reconcile then pays to delete on every open.
    let attributesFlushDrops = pendingPresentationSeedReconcile
    var flushDropProgressCount = 0
    var flushDropUsageKeys: [String] = []
    var flushDropThinkingKeys: [String] = []
    var flushInboxRoutedKeys: [String] = []
    let parsedAll = parsedRowsReusingCache(rowsToParse).filter { row in
      guard row.messageType != "agent_progress" else {
        flushDropProgressCount += 1
        return false
      }
      // Rate/usage-limit notices never belong in the transcript — they shift the list.
      // Route them to the floating usage banner instead.
      if Self.isUsageLimitRow(row) {
        let provider =
          row.agentRuntime?.provider
          ?? row.agentUsername
          ?? ""
        if !provider.isEmpty {
          DispatchQueue.main.async { [weak self] in
            self?.handleAgentUsageLimitEvent(
              provider: provider,
              message: row.plainContent ?? row.text ?? ""
            )
          }
        }
        if attributesFlushDrops { flushDropUsageKeys.append(String(row.key.suffix(14))) }
        return false
      }
      // A live agent turn with nothing renderable yet (no tool/step, no narration, no
      // answer text) is held out of the transcript entirely — the header already shows
      // "Thinking…" for this state. The row appears the moment the first real chunk
      // streams in, landing directly at its normal full-width layout instead of a
      // centered placeholder pill that then grows.
      if bubbleUsesAgentTurnContent(row), agentTurnBubbleIsCompactThinking(row) {
        if attributesFlushDrops { flushDropThinkingKeys.append(String(row.key.suffix(14))) }
        return false
      }
      return true
    }
    let applyParseDoneAt = ProcessInfo.processInfo.systemUptime
    let applyParseMs = Int((applyParseDoneAt - applyMergeDoneAt) * 1000)
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
      if attributesFlushDrops { flushInboxRoutedKeys = inbox.map { String($0.key.suffix(14)) } }
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
    let flushCountAfterInbox = parsed.count
    parsed = bridgeFreshFiltered(parsed)
    let flushCountAfterBridgeFresh = parsed.count
    // Bridge info-command results (/usage, /status, /commands, …) are answered right
    // here by the bridge (runtime.command.executable == "vibe-bridge"). They must NOT
    // land in the transcript — route them to the host (banner/overlay) and drop them.
    parsed = extractBridgeCommandRows(parsed)
    parsed = rowsPreservingAgentTurnHighWater(parsed)
    let applyFilterDoneAt = ProcessInfo.processInfo.systemUptime
    let applyFilterMs = Int((applyFilterDoneAt - applyParseDoneAt) * 1000)
    if attributesFlushDrops {
      NSLog(
        "[ChatOpen] flush-stages chat=%@ visible=%d windowed=%d parsedAll=%d progress=%d usage=[%@] thinking=[%@] inboxMode=%@ inbox=[%@] afterInbox=%d afterBridgeFresh=%d final=%d",
        String(engineChatId.prefix(12)), visibleRows.count, rowsToParse.count, parsedAll.count,
        flushDropProgressCount,
        flushDropUsageKeys.prefix(6).joined(separator: ","),
        flushDropThinkingKeys.prefix(6).joined(separator: ","),
        eventInboxModeEnabled ? "Y" : "N",
        flushInboxRoutedKeys.prefix(6).joined(separator: ","),
        flushCountAfterInbox, flushCountAfterBridgeFresh, parsed.count)
    }
#if DEBUG
    collectionView.accessibilityIdentifier = "chat.messages"
    collectionView.accessibilityValue =
      "incoming=\(nextRows.count);merged=\(mergedRows.count);parsed=\(parsed.count);displayed=\(rows.count)"
#endif
    if parsed.isEmpty, !effectiveRows.isEmpty {
      // Incoming rows all dropped before render — dump the first raw row's shape so
      // the drop point (ChatListRow.init vs a filter) is identifiable from device logs.
      let firstRow = effectiveRows[0]
      VibeDebugLog.log(
        "[ChatOpen] setRows ALL-DROPPED incoming=%d merged=%d parsedAll=%d keys=[%@] kind=%@ type=%@",
        effectiveRows.count, mergedRows.count, parsedAll.count,
        firstRow.keys.sorted().joined(separator: ","),
        (firstRow["kind"] as? String) ?? "nil",
        ((firstRow["message"] as? [String: Any])?["type"] as? String) ?? "nil")
    }
    if parsed.isEmpty, !isExplicitEmpty, searchQuery.isEmpty, !rows.isEmpty {
      NSLog(
        "[ChatOpen] setRows KEEP visible=%d chat=%@ reason=non-explicit-all-dropped incoming=%d merged=%d",
        rows.count, String(engineChatId.prefix(12)), nextRows.count, mergedRows.count)
      finishRowsUpdate(historyRevealCompleted: isHistoryRevealPrepend)
      return
    }
    // Commit the retained baseline only after the candidate survived parsing/filtering.
    // A malformed or stale bridge payload can no longer poison the next merge.
    sourceRowsPayload = retainedSourceRows
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
    usesProgressiveTranscriptSizing =
      searchQuery.isEmpty && parsed.count > Self.largeTranscriptThreshold
    let warmCacheChatId: String = {
      let bound = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !bound.isEmpty { return bound }
      return parsed.compactMap { row in
        row.chatId?.trimmingCharacters(in: .whitespacesAndNewlines)
      }.first(where: { !$0.isEmpty }) ?? ""
    }()
    if parsed.isEmpty, nextRows.isEmpty, isExplicitEmpty {
      Self.removeWarmTranscript(chatId: warmCacheChatId)
    } else if !parsed.isEmpty, searchQuery.isEmpty {
      // Cache the parsed visible tail plus the COMPLETE raw list. Reopen paints the tail
      // immediately, while older rows remain available for incremental parsing on scroll.
      Self.rememberWarmTranscript(
        chatId: warmCacheChatId,
        rows: parsed,
        sourceRows: visibleRows,
        messageHeightCache: messageHeightCache,
        agentTurnHeightCache: agentTurnHeightCache
      )
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
    let reconcilesPresentationSeed = pendingPresentationSeedReconcile
    pendingPresentationSeedReconcile = false
    // Drop height cache for rows that left the list (stream-… / lan-… → final UUID).
    // Stale heights after that swap are a primary cause of empty gaps + overlaps.
    let nextKeys = Set(parsed.map(\.key))
    var removedKeys: [String] = []
    for row in previousRows where !nextKeys.contains(row.key) {
      messageHeightCache.removeValue(forKey: row.key)
      agentTurnHeightCache.removeValue(forKey: row.key)
      removedKeys.append(row.key)
    }
    let insertedKeys = parsed.filter { prev in !previousRows.contains(where: { $0.key == prev.key }) }
      .map(\.key)
    if isGroupOrChannel, !removedKeys.isEmpty || !insertedKeys.isEmpty {
      layoutShiftLog(
        "[LayoutShift] setRows group swap removed=%d inserted=%d rem=[%@] ins=[%@] prevCount=%d nextCount=%d",
        removedKeys.count, insertedKeys.count,
        removedKeys.prefix(4).map { String($0.suffix(14)) }.joined(separator: ","),
        insertedKeys.prefix(4).map { String($0.suffix(14)) }.joined(separator: ","),
        previousRows.count, parsed.count)
    }
    let previousContentOffsetY = collectionView.contentOffset.y
    let previousDistanceFromBottom = currentDistanceFromBottom()
    let wasNearBottom = previousDistanceFromBottom <= listBottomThreshold

    if wasNearBottom {
      if newMessagesWhileAwayCount != 0 {
        newMessagesWhileAwayCount = 0
        updateJumpToBottomBadge()
      }
    } else if !isHistoryRevealPrepend, !previousRows.isEmpty, removedKeys.isEmpty {
      let previousKeys = Set(previousRows.map(\.key))
      let lastExistingIndex = parsed.lastIndex { previousKeys.contains($0.key) } ?? -1
      let firstAppendIndex = lastExistingIndex + 1
      if firstAppendIndex >= 0, firstAppendIndex < parsed.count {
        let appendedIncomingCount = parsed[firstAppendIndex...].reduce(into: 0) { count, row in
          guard !previousKeys.contains(row.key), row.kind == .message, !row.isMe else { return }
          guard row.messageType != "typing", row.messageType != "agent_actions" else { return }
          count += 1
        }
        if appendedIncomingCount > 0 {
          newMessagesWhileAwayCount += appendedIncomingCount
          updateJumpToBottomBadge()
        }
      }
    }

    // NOTE: Do NOT set `rows = parsed` here. The data source (`rows`) must
    // reflect the OLD count until inside performBatchUpdates, otherwise UIKit
    // sees a mismatch between "before" count and the insert/delete operations.

    // Capture a stationary anchor: the topmost visible item's key and its screen-Y.
    let stationaryAnchor: (key: String, screenY: CGFloat)? = {
      // A history reveal can be prefetched while still fairly close to the bottom. It
      // always needs a viewport anchor; generic live inserts keep their old bottom rule.
      guard isHistoryRevealPrepend || !wasNearBottom else { return nil }
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
      self.scrollingDateLabelsByRowKey = nextScrollingDateLabels
      // Any live stream / typing / new reply here means the send didn't evaporate —
      // stand the no-response watchdog down (and clear a notice if it already popped).
      self.noteAgentActivityForWatchdog()
      if let agentVC = self.presentedBridgeAgentVC {
        agentVC.setMessages(VibeAgentKitMap.messages(from: parsed))
      }
      // Keep the composer trailing control (SEND vs STOP) in sync with live agent
      // turns — streaming/running forces STOP so the user can interrupt immediately
      // (Claude/Codex DMs, multi-agent groups, and Vibe AI).
      self.pruneStopCancelRequestedKeys(using: parsed)
      self.syncComposerStopState()
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
      self.updateBridgeEmptyHistoryPromptVisibility()
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
      // "apply" = everything between the end of the filter chain and finalize entry:
      // diff computation, batch updates / reloadData, and visible-cell configuration.
      let finalizeEnteredAt = ProcessInfo.processInfo.systemUptime
      let applyPhaseMs = Int((finalizeEnteredAt - applyFilterDoneAt) * 1000)
      self.collectionView.layoutIfNeeded()
      let layoutDoneAt = ProcessInfo.processInfo.systemUptime
      let layoutPhaseMs = Int((layoutDoneAt - finalizeEnteredAt) * 1000)
      // updateBottomAnchorInset performs its own second layout when the inset changes,
      // so another unconditional pass here only configures the same cells twice.
      self.updateBottomAnchorInset()
      let insetDoneAt = ProcessInfo.processInfo.systemUptime
      let insetPhaseMs = Int((insetDoneAt - layoutDoneAt) * 1000)
      self.refreshWarmTranscriptHeightSnapshot()
      let warmSnapPhaseMs = Int((ProcessInfo.processInfo.systemUptime - insetDoneAt) * 1000)
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
          "[MainThreadStall] setRows took %dms rows=%d streaming=%@ tracking=%@ mergeMs=%d parseMs=%d filterMs=%d applyMs=%d layoutMs=%d insetMs=%d warmSnapMs=%d",
          setRowsDurationMs, parsed.count,
          parsed.contains(where: { $0.isStreamingText }) ? "Y" : "N",
          self.collectionView.isTracking ? "Y" : "N",
          applyMergeMs, applyParseMs, applyFilterMs,
          applyPhaseMs, layoutPhaseMs, insetPhaseMs, warmSnapPhaseMs)
      }
      // Only the dedicated "Vibe AI" surface (agentChatMode) uses the ChatGPT-style
      // pin-question-to-top / reserve-room-below scroll strategy. An inline Claude/Codex
      // bridge DM (currentBridgeProvider != nil) now renders in the NORMAL chat list and
      // must behave like any other chat — stick-to-bottom / stationary-anchor — so it
      // falls through to the normal branches below instead of pinning to the top.
      let agentSurface = self.agentChatMode
      if self.applyOpeningViewportIfNeeded() {
        // Initial unread/saved positioning owns this one finalize pass.
      } else if agentSurface, self.pendingAgentPushToTop {
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
      self.finishRowsUpdate(historyRevealCompleted: isHistoryRevealPrepend)
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

    if reconcilesPresentationSeed {
      let contentIsEqual =
        previousRows.count == parsed.count
        && zip(previousRows, parsed).allSatisfy { pair in
          let (previous, next) = pair
          return previous.key == next.key && chatListRowContentEqual(previous, next)
        }
      // A full-window seed makes this reconcile a tiny diff (a few zombie removals /
      // status flips), but reloadData rebuilds EVERY visible rich AgentKit cell —
      // the 111-174ms stall measured on device. When the shared-key order is stable,
      // apply the diff as a non-animated batch instead so untouched cells survive.
      let hasUniqueKeys = oldKeys.count == oldSet.count && newKeys.count == newSet.count
      let orderIsStable = hasUniqueKeys && oldSharedOrder == newSharedOrder
      var reconcileMode = "equal"
      var reconcileChangedCount = 0
      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if contentIsEqual {
          applyDataSource()
        } else if orderIsStable {
          reconcileMode = "batch"
          let removed = previousRows.enumerated()
            .filter { !newSet.contains($0.element.key) }
            .map { IndexPath(item: $0.offset, section: 0) }
          let inserted = parsed.enumerated()
            .filter { !oldSet.contains($0.element.key) }
            .map { IndexPath(item: $0.offset, section: 0) }
          if !removed.isEmpty {
            // Name the zombies: rows the seed keeps mounting that the authoritative
            // pipeline keeps dropping point at stale snapshot/store content upstream.
            // Flags (evaluated NOW, with flush-time view state, on the seeded row):
            // H hiddenFromTranscript · E eventNotification · S inboxSummary ·
            // U usageLimit · T compactThinking — names which filter disagreed.
            let zombies = previousRows.filter { !newSet.contains($0.key) }
              .prefix(6)
              .map { row -> String in
                var flags = ""
                if row.hiddenFromTranscript { flags += "H" }
                if row.isEventNotification { flags += "E" }
                if row.isEventInboxSummary { flags += "S" }
                if Self.isUsageLimitRow(row) { flags += "U" }
                if bubbleUsesAgentTurnContent(row), agentTurnBubbleIsCompactThinking(row) {
                  flags += "T"
                }
                return "\(String(row.key.suffix(14))):\(row.messageType):\(flags.isEmpty ? "-" : flags)"
              }
              .joined(separator: ",")
            NSLog(
              "[ChatOpen] reconcile ZOMBIES chat=%@ removed=%d inboxMode=%@ [%@]",
              String(engineChatId.prefix(12)), removed.count,
              eventInboxModeEnabled ? "Y" : "N", zombies)
          }
          var previousByKey: [String: ChatListRow] = [:]
          previousByKey.reserveCapacity(previousRows.count)
          for row in previousRows { previousByKey[row.key] = row }
          var changed: [IndexPath] = []
          for (index, row) in parsed.enumerated() {
            guard let previous = previousByKey[row.key] else { continue }
            if !chatListRowContentEqual(previous, row) {
              changed.append(IndexPath(item: index, section: 0))
            }
          }
          reconcileChangedCount = changed.count
          collectionView.performBatchUpdates {
            applyDataSource()
            if !removed.isEmpty { collectionView.deleteItems(at: removed) }
            if !inserted.isEmpty { collectionView.insertItems(at: inserted) }
          }
          if !changed.isEmpty { collectionView.reloadItems(at: changed) }
        } else {
          reconcileMode = "reload"
          applyDataSource()
          collectionView.reloadData()
        }
        finalize(false)
        CATransaction.commit()
      }
      NSLog(
        "[ChatOpen] presentation-reconcile chat=%@ rows=%d equal=%@ structural=N mode=%@ changed=%d ms=%d sinceOpenMs=%d",
        String(engineChatId.prefix(12)), parsed.count, contentIsEqual ? "Y" : "N",
        reconcileMode, reconcileChangedCount,
        Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000),
        chatOpenStartedAt > 0
          ? Int((ProcessInfo.processInfo.systemUptime - chatOpenStartedAt) * 1000) : -1)
      return
    }

    // Initial load or full replacement: use reloadData (no batch update needed).
    guard !previousRows.isEmpty else {
      if parsed.count <= 4 {
        VibeDebugLog.log(
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
      if window != nil, parsed.count == 1, bounds.width > 1.0, bounds.height > 1.0 {
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
        VibeDebugLog.log(
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
        VibeDebugLog.log(
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

    // [PostSend] "The previous cell jumps a beat AFTER the new message lands."
    // Root suspect: the backfillNewest echo of a just-sent message re-inserts /
    // re-slots it ~0.6s later, and THAT second setRows moves the list after the
    // send morph has already completed — so hasPendingSend is false and none of the
    // [SendShift] audits (which gate on a pending send) fire. Capture the geometry
    // of any own-message insert/reload settle at whichever exit path runs, so the
    // device log shows whether the list actually SCROLLED (offset moved), GREW (a
    // genuine duplicate durable row was added → contentH jumps by ~one bubble), or
    // merely reloaded in place (offset & contentH unchanged = harmless).
    let meInsertKeys = insertions.compactMap {
      $0.item < parsed.count && parsed[$0.item].isMe ? parsed[$0.item].key : nil
    }
    let meReloadKeys = safeReloads.compactMap {
      $0.item < previousRows.count && previousRows[$0.item].isMe ? previousRows[$0.item].key : nil
    }
    let postSendPreContentH = collectionView.contentSize.height
    let logPostSendSettle: (String) -> Void = { [weak self] path in
      guard let self, !meInsertKeys.isEmpty || !meReloadKeys.isEmpty else { return }
      let pendingSend = self.pendingSendTransition != nil || self.activeSendTransition != nil
      NSLog(
        "[PostSend] settle path=%@ pendingSend=%@ group=%@ offset=%.0f→%.0f contentH=%.0f→%.0f "
          + "ins=%d reload=%d meIns=[%@] meReload=[%@]",
        path, pendingSend ? "Y" : "N", self.isGroupOrChannel ? "Y" : "N",
        previousContentOffsetY, self.collectionView.contentOffset.y,
        postSendPreContentH, self.collectionView.contentSize.height,
        insertions.count, safeReloads.count,
        meInsertKeys.map { String($0.suffix(6)) }.joined(separator: ","),
        meReloadKeys.map { String($0.suffix(6)) }.joined(separator: ","))
      // [BubbleFrames] The user's screenshot shows the last bubble OVERLAPPING the one
      // above it, yet cell heights + contentH are clean — so the overlap is inside the
      // cells: the bubble is bottom-aligned and unclipped, so a bubble taller than its
      // cell spills into the neighbor. Dump the last few message cells' absolute bubble
      // top/bottom (cell.minY + bubbleFrameInCell) so a NEGATIVE gap between one bubble's
      // bottom and the next bubble's top is the overlap, in points, naming the culprit.
      let visible = self.collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
      var prevBubbleBottom: CGFloat = -.greatestFiniteMagnitude
      var prevKey = ""
      for ip in visible.suffix(6) {
        guard ip.item < self.rows.count, self.rows[ip.item].kind == .message,
          let attr = self.collectionView.layoutAttributesForItem(at: ip),
          let cell = self.collectionView.cellForItem(at: ip) as? ChatListCell
        else { continue }
        let bf = cell.renderedBubbleFrameInCell
        let bubbleTop = attr.frame.minY + bf.minY
        let bubbleBottom = bubbleTop + bf.height
        let key = String(self.rows[ip.item].key.suffix(6))
        let gap = prevBubbleBottom == -.greatestFiniteMagnitude ? 0 : bubbleTop - prevBubbleBottom
        NSLog(
          "[BubbleFrames] %@ cellY=%.1f cellH=%.1f bubY=%.1f bubH=%.1f absTop=%.1f absBot=%.1f gapToPrev=%.1f%@",
          key, attr.frame.minY, attr.frame.height, bf.minY, bf.height,
          bubbleTop, bubbleBottom, gap,
          (gap < -0.5 && !prevKey.isEmpty) ? " OVERLAP(\(prevKey))" : "")
        prevBubbleBottom = bubbleBottom
        prevKey = key
      }
    }

    // Cached history is a strict PREPEND, not a live-message insertion. Routing it
    // through the generic finalize path reconfigures visible cells, recalculates normal
    // bottom/send behavior, then writes the offset after layout. During an active drag
    // that produces a one-frame opacity/position flash. Insert only the new prefix and
    // restore the same visible bubble inside one disabled-actions transaction.
    let historyPrependCount = parsed.count - previousRows.count
    let isStrictHistoryPrepend =
      isHistoryRevealPrepend
      && historyPrependCount > 0
      && deletions.isEmpty
      && safeReloads.isEmpty
      && insertions.map { $0.item } == Array(0..<historyPrependCount)
      && Array(parsed.suffix(previousRows.count).map(\.key)) == previousRows.map(\.key)
      && stationaryAnchor != nil
    if isStrictHistoryPrepend, let anchor = stationaryAnchor {
      let offsetBefore = collectionView.contentOffset.y
      let contentHeightBefore = collectionView.contentSize.height
      var anchorDelta: CGFloat = 0.0

      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.performBatchUpdates(
          {
            applyDataSource()
            collectionView.insertItems(at: insertions)
          },
          completion: nil)
        collectionView.layoutIfNeeded()

        // If the original latest tail was shorter than the viewport, its top filler can
        // shrink now that older rows exist. Resolve it before the anchor correction so a
        // later layoutSubviews pass cannot move the list under the user's finger.
        updateBottomAnchorInset()

        if let newIndex = parsed.firstIndex(where: { $0.key == anchor.key }),
          let attrs = collectionView.layoutAttributesForItem(
            at: IndexPath(item: newIndex, section: 0))
        {
          let desiredOffset = attrs.frame.minY - anchor.screenY
          let maxOffset = max(
            0.0, collectionView.contentSize.height - collectionView.bounds.height)
          let clampedOffset = pixelAlignedValue(max(0.0, min(maxOffset, desiredOffset)))
          performInternalScrollAdjustment {
            collectionView.setContentOffset(
              CGPoint(x: 0.0, y: clampedOffset), animated: false)
          }
          anchorDelta = (attrs.frame.minY - collectionView.contentOffset.y) - anchor.screenY
        }

        // The one old row at the prepend seam can gain/lose group-run decoration. Keep
        // its existing cell and update it in place; never reload/recreate visible cells.
        let seam = IndexPath(item: historyPrependCount, section: 0)
        if seam.item < rows.count,
          let cell = collectionView.cellForItem(at: seam) as? ChatListCell
        {
          cell.applyAppearance(appearance)
          configureMessageCell(cell, at: seam, row: rows[seam.item])
          bindWallpaperBackdrop(to: cell)
          cell.setNeedsLayout()
          cell.layoutIfNeeded()
        }

        // UIKit can still attach implicit transition actions to cells created during a
        // collection update. Strip them before this transaction reaches the renderer.
        for cell in collectionView.visibleCells {
          cell.alpha = 1.0
          cell.contentView.alpha = 1.0
          cell.layer.opacity = 1.0
          cell.contentView.layer.opacity = 1.0
          for key in ["opacity", "position", "bounds", "bounds.origin", "bounds.size", "transform"] {
            cell.layer.removeAnimation(forKey: key)
          }
          cell.contentView.layer.removeAnimation(forKey: "opacity")
          cell.contentView.layer.removeAnimation(forKey: "position")
        }
        CATransaction.commit()
      }

      updateFloatingSenderAvatars()
      previousOffsetY = collectionView.contentOffset.y
      emitViewport(force: true)
      NSLog(
        "[ChatOpen] history-window PREPEND chat=%@ inserted=%d anchorDelta=%.2f offset=%.0f→%.0f contentH=%.0f→%.0f",
        String(engineChatId.prefix(12)), historyPrependCount, anchorDelta,
        offsetBefore, collectionView.contentOffset.y,
        contentHeightBefore, collectionView.contentSize.height)
      finishRowsUpdate(historyRevealCompleted: true)
      maybeStartPendingSendTransition()
      return
    }

    guard !deletions.isEmpty || !insertions.isEmpty || !safeReloads.isEmpty else {
      // A status/presence notification can replay an identical full transcript many
      // times. Full row equality has already been checked above; avoid layoutIfNeeded,
      // bottom-inset recomputation, audio snapshots, and visible-cell configuration.
      // Live streams deliberately stay on the regular path so state-only transitions
      // cannot be hidden by this shortcut.
      if !parsed.contains(where: { $0.isStreamingText }) {
        scrollingDateLabelsByRowKey = nextScrollingDateLabels
        finishRowsUpdate(historyRevealCompleted: isHistoryRevealPrepend)
      } else {
        applyDataSource()
        finalize(false)
      }
      return
    }

    if deletions.isEmpty && insertions.isEmpty && !safeReloads.isEmpty {
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
        // Same group-aware width as sizeForItemAt — full-width measurement here used
        // to misclassify reloads and then reconfigure without invalidating layout.
        let extras = groupMeasurementExtras(at: indexPath)
        return abs(
          estimateMessageHeight(previousRow, rowWidth: extras.measurementWidth)
            - estimateMessageHeight(nextRow, rowWidth: extras.measurementWidth)
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
        // Keep the SAME cell for any live streaming agent row (1:1 agent-turn feed OR
        // group plain-text stream). reloadItems recreates the cell → full re-fade +
        // group gutter re-apply = the "flicker / content shift" user sees in multi-agent
        // groups. reconfigureItems grows text in place; invalidateLayout picks new height.
        let inPlaceStreamReloads = safeReloads.filter { indexPath in
          guard indexPath.item < rows.count else { return false }
          let row = rows[indexPath.item]
          if bubbleUsesAgentTurnContent(row) { return true }
          if row.isAgentMessage, row.isStreamingText { return true }
          return false
        }
        let otherReloads = safeReloads.filter { !inPlaceStreamReloads.contains($0) }
        inPlaceAgentTurnGrowth = otherReloads.isEmpty && !inPlaceStreamReloads.isEmpty
        let wasNearBottom = currentDistanceFromBottom() <= listBottomThreshold
        let contentHBefore = collectionView.contentSize.height
        let offsetBefore = collectionView.contentOffset.y
        // DIAG: which rows grew and by how much (layout shift root-cause).
        var heightDeltas: [String] = []
        for ip in safeReloads where ip.item < previousRows.count && ip.item < rows.count {
          let prev = previousRows[ip.item]
          let next = rows[ip.item]
          let extras = groupMeasurementExtras(at: ip)
          let h0 = estimateMessageHeight(prev, rowWidth: extras.measurementWidth)
          // Bust cache for next so we measure fresh
          messageHeightCache.removeValue(forKey: next.key)
          agentTurnHeightCache.removeValue(forKey: next.key)
          let h1 = estimateMessageHeight(next, rowWidth: extras.measurementWidth)
          if abs(h1 - h0) > 0.5 {
            heightDeltas.append(
              String(
                format: "%@ Δ%.0f (%.0f→%.0f) stream=%@ agent=%@",
                String((next.messageId ?? next.key).suffix(10)),
                h1 - h0, h0, h1,
                next.isStreamingText ? "Y" : "N",
                next.isAgentMessage ? "Y" : "N"))
          }
        }
        layoutShiftLog(
          "[LayoutShift] path=heightReload group=%@ nearBottom=%@ inPlace=%@ otherReloads=%d streamReloads=%d offset=%.0f contentH=%.0f deltas=[%@]",
          isGroupOrChannel ? "Y" : "N",
          wasNearBottom ? "Y" : "N",
          inPlaceAgentTurnGrowth ? "Y" : "N",
          otherReloads.count,
          inPlaceStreamReloads.count,
          offsetBefore,
          contentHBefore,
          heightDeltas.prefix(6).joined(separator: "; "))
        UIView.performWithoutAnimation {
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          flowLayout.invalidateLayout()
          collectionView.performBatchUpdates(
            {
              if !otherReloads.isEmpty {
                collectionView.reloadItems(at: otherReloads)
              }
              if !inPlaceStreamReloads.isEmpty {
                if #available(iOS 15.0, *), self.rows.count > 1 {
                  collectionView.reconfigureItems(at: inPlaceStreamReloads)
                } else {
                  collectionView.reloadItems(at: inPlaceStreamReloads)
                }
              }
            },
            completion: nil)
          collectionView.layoutIfNeeded()
          // Growing a bottom stream row without pin makes the whole list "jump".
          if wasNearBottom {
            scrollToBottom(animated: false)
          }
          if isGroupOrChannel {
            updateFloatingSenderAvatars(animateShift: true)
          }
          CATransaction.commit()
        }
        layoutShiftLog(
          "[LayoutShift] after heightReload offset=%.0f→%.0f contentH=%.0f→%.0f scrolledBottom=%@",
          offsetBefore, collectionView.contentOffset.y,
          contentHBefore, collectionView.contentSize.height,
          wasNearBottom ? "Y" : "N")
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
      // ALWAYS re-apply group gutter/name via configureMessageCell — bare
      // configure() defaults strip decoration and put the bubble under the avatar.
      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var decoratePaths = Set(safeReloads)
        for indexPath in safeReloads {
          if indexPath.item > 0 {
            decoratePaths.insert(IndexPath(item: indexPath.item - 1, section: 0))
          }
          if indexPath.item + 1 < rows.count {
            decoratePaths.insert(IndexPath(item: indexPath.item + 1, section: 0))
          }
        }
        for indexPath in decoratePaths.sorted(by: { $0.item < $1.item }) {
          guard indexPath.item < rows.count else { continue }
          if let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell {
            // A cell mid-send-slide carries an additive `insertionShift` (existing
            // cell riding up) or `insertSlideUp` (the new cell) animation. This path
            // runs for EVERY content reload — including the just-sent cell's own
            // sending→sent status flip mid-flight — and it expands to item±1, so it
            // re-decorates the reloaded PREVIOUS cell while it is still sliding. The
            // removeAllAnimations() below then strips that ride and SNAPS the cell to
            // its final slot ~250ms before its neighbors finish, so it briefly overlaps
            // the cell above it (the "previous cell jumps a few px on send" the
            // [SendFlight] sampler pinned: reloaded neighbor at final while everyone
            // else was mid-slide). Leave mid-flight cells alone — they were already
            // decorated correctly in the send batch and settle on their own. Only ever
            // skips during a live send; no other path has these animations in flight.
            if cell.layer.animation(forKey: "insertionShift") != nil
              || cell.layer.animation(forKey: "insertSlideUp") != nil
            {
              continue
            }
            let row = rows[indexPath.item]
            cell.applyAppearance(appearance)
            configureMessageCell(cell, at: indexPath, row: row)
            bindWallpaperBackdrop(to: cell)
            cell.alpha = 1.0
            cell.contentView.alpha = 1.0
            cell.layer.opacity = 1.0
            cell.contentView.layer.opacity = 1.0
            cell.layer.removeAllAnimations()
            cell.contentView.layer.removeAllAnimations()
          }
        }
        if isGroupOrChannel {
          updateFloatingSenderAvatars(animateShift: true)
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
      finishRowsUpdate(historyRevealCompleted: isHistoryRevealPrepend)
      maybeStartPendingSendTransition()
      logPostSendSettle("reconfigure")
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
    let containsAgentInsertion = insertions.contains { indexPath in
      indexPath.item < parsed.count && parsed[indexPath.item].isAgentMessage
    }
    let shouldAnimateUpdate =
      isSmallUpdate
      && wasNearBottom
      && animMode > 0  // mode 0 = no animation
      && !isAgentSettleSwap
      // Agent rows already grow through their in-place streaming renderer. A
      // second generic collection animation at settle time transforms every
      // visible cell and can tear a user bubble that just completed send morph.
      && !containsAgentInsertion

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
    // Pre-update cell heights, keyed the same as preUpdateScreenY. A cell whose
    // height changes across the insert (e.g. the previous own-message losing its
    // grouping tail when a newer one lands) can't ride the additive push-up as a
    // pure translation without shearing into its neighbor — this lets the ride
    // audit print the actual height delta, not just infer it from divergence.
    var preUpdateScreenH: [String: CGFloat] = [:]
    var didCaptureAvatarPositions = false
    var preUpdateOffset: CGFloat = 0
    if shouldAnimateUpdate && animMode == 2 {
      preUpdateOffset = collectionView.contentOffset.y
      for cell in collectionView.visibleCells {
        guard let ip = collectionView.indexPath(for: cell), ip.item < previousRows.count else {
          continue
        }
        let key = previousRows[ip.item].key
        preUpdateScreenY[key] = cell.center.y - preUpdateOffset
        preUpdateScreenH[key] = cell.bounds.height
      }
      // Floating gutter avatars live in a screen-fixed overlay: record their
      // positions ON THE VIEW (not keyed by run id — run identity can churn across
      // the update: temp→server rekey, index shift, run growth) so pass 3 can give
      // the surviving view the same additive ride as its run's cells.
      for view in senderAvatarViews.values where !view.isHidden {
        view.capturedMidY = view.frame.midY
        didCaptureAvatarPositions = true
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

      logPostSendSettle("animScrollInsert")
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

    // Agent settle swaps (delete+insert) in groups have left stale/orphaned cells
    // painting over real rows — verify the cell layer before this frame renders.
    if isGroupOrChannel, !deletions.isEmpty || !insertions.isEmpty {
      sweepGroupAgentCellIntegrity(reason: "postBatch")
    }
    // [SendShift] The user reports older messages overlapping + extra gap when
    // sending. Log the offset/content geometry of every own-send insert so the next
    // repro shows exactly which pass moved the list and by how much. Fires for DM
    // sends too (pending-send morph active), not just groups.
    if isGroupOrChannel || pendingSendTransition != nil || activeSendTransition != nil,
      insertions.contains(where: { $0.item < parsed.count && parsed[$0.item].isMe })
    {
      NSLog(
        "[SendShift] group me-insert offset %.0f→%.0f contentH=%.0f nearBottom=%@ morph=%@ del=%d ins=%d rel=%d",
        previousContentOffsetY, collectionView.contentOffset.y,
        collectionView.contentSize.height, wasNearBottom ? "Y" : "N",
        (pendingSendTransition != nil || activeSendTransition != nil) ? "Y" : "N",
        deletions.count, insertions.count, safeReloads.count)
    }

    if queuedUpdateProcessed {
      NSLog("[ChatListAnim] skipping additive — queued setRows processed during finalize")
      maybeStartPendingSendTransition()
      return
    }

    if shouldAnimateUpdate {
      // Telegram timing: 0.3s spring (matches kCAMediaTimingFunctionSpring).
      // During a send morph the cell ride MUST share the overlay's clock
      // (same curve, same 0.36s duration) — a shorter ride makes the plate's
      // growing top edge overrun the still-sliding previous cell mid-flight
      // (visible overlap on tall sends) and land 60ms after the list stops.
      let animDuration: CFTimeInterval =
        hasPendingSend ? SendMorphProfile.duration : 0.3
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
            var delta = pixelAlignedValue(oldScreenY - currentScreenY)
            // The push-up is a rigid translation of the whole stack above the
            // insertion, so every cell's TOP edge rides the same delta. But this
            // delta is measured from the CENTER, and a cell that changed height
            // across the insert (the previous own-message regaining its grouping
            // tail/timestamp footer when a newer one lands: h35→h51) moves its
            // center by (stackPush − heightΔ/2), not the uniform stackPush. That
            // divergence shears it out of sync with its flush neighbors — the
            // reported "older messages overlap and get extra gap" on send
            // ([SendShift] proved aa2f5e rode 61 vs the stack's 69 after +16h).
            // Recompute from the top edge so it rejoins the rigid ride.
            if let oldH = preUpdateScreenH[key],
              abs(cell.bounds.height - oldH) > 0.5
            {
              let oldTop = oldScreenY - oldH / 2.0
              let newTop = currentScreenY - cell.bounds.height / 2.0
              delta = pixelAlignedValue(oldTop - newTop)
            }
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
            // Day separators too: this block is only reached during a SEND transition, so
            // a send that crosses a day boundary inserts the divider in the same batch as
            // the sent bubble. Sliding the divider while the morph overlay crossfades into
            // that bubble reads as two animations competing/overlapping in one spot — the
            // date should simply be there when the crossfade lands.
            let skipSlide: Bool = {
              guard info.indexPath.item < rows.count else { return false }
              let row = rows[info.indexPath.item]
              if row.kind == .day { return true }
              let vk = row.visualKind
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

        // [SendShift] per-cell ride audit: every visible cell should carry the SAME
        // delta (pure translation). A diverging delta means that cell's height
        // changed across the insert (it will visibly shear against its neighbors
        // during the ride — the reported "older messages overlap and get extra
        // gap" on send). Fires for DM sends too, not just groups, so a 1:1 repro
        // prints the numbers. Each entry: key=<delta>h<postH>(<±heightChange>) with
        // a trailing R if the cell was reloaded across this update.
        if hasPendingSend, !cellInfos.isEmpty {
          let reloadedKeys = Set(
            safeReloads.compactMap { $0.item < previousRows.count ? previousRows[$0.item].key : nil }
          )
          let rides = cellInfos.sorted { $0.indexPath.item < $1.indexPath.item }
            .suffix(8)
            .map { info -> String in
              let tag = info.isNew ? "new" : String(format: "%.0f", info.delta)
              let postH = info.cell.bounds.height
              let dh = preUpdateScreenH[info.key].map { postH - $0 } ?? 0
              let dhTag = abs(dh) > 0.5 ? String(format: "%+.0f", dh) : "0"
              let reloadTag = reloadedKeys.contains(info.key) ? "R" : ""
              return "\(info.key.suffix(6))=\(tag)h\(Int(postH))(\(dhTag))\(reloadTag)"
            }
            .joined(separator: " ")
          NSLog(
            "[SendShift] rides group=%@ dur=%.2f scrollΔ=%.0f %@",
            isGroupOrChannel ? "Y" : "N", animDuration, dbgScrollDelta, rides)
          // Settle geometry is provably clean (see [BubbleFrames]), so the reported
          // jump lives INSIDE the 0.36s flight. Sample the actual PRESENTATION-layer
          // positions of the last cells across the animation so a transient negative
          // gap (the reloaded previous cell riding ahead of its neighbor) is caught in
          // motion, which no settle-time log can see.
          startSendFlightSampler(reason: "send", duration: animDuration)
        }

        // --- Pass 3: keep floating sender avatars glued to their run ---
        // The cells animate the shift additively while updateFloatingSenderAvatars
        // (fired by finalize's instant scroll) snapped the avatars straight to the
        // final spot — the avatar visibly detaches from its cells on every group
        // send. Re-resolve final frames, then give each avatar the same additive
        // ride its run's cells are on.
        if isGroupOrChannel, didCaptureAvatarPositions {
          updateFloatingSenderAvatars()
          for view in senderAvatarViews.values {
            let oldY = view.capturedMidY
            view.capturedMidY = nil
            guard !view.isHidden, let oldY else { continue }
            let delta = pixelAlignedValue(oldY - view.frame.midY)
            guard abs(delta) > 0.5 else { continue }
            let anim = CABasicAnimation(keyPath: "position.y")
            anim.fromValue = delta as NSNumber
            anim.toValue = 0.0 as NSNumber
            anim.isAdditive = true
            anim.duration = animDuration
            anim.timingFunction = animTiming
            anim.isRemovedOnCompletion = true
            view.layer.add(anim, forKey: "avatarInsertionShift")
            NSLog("[AvatarPin] glue delta=%.1f", delta)
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
    logPostSendSettle("batchEnd")
  }

  /// Samples the PRESENTATION-layer position of the last few message cells across a send
  /// flight. Every settle-time log shows the final layout clean, so the reported "previous
  /// cell jumps / overlaps" must be a transient DURING the 0.36s animation — the reloaded
  /// previous cell's additive ride briefly diverging from its un-reloaded neighbor. The
  /// presentation layer is the only place that value is visible mid-animation. Each sample:
  /// key top=<animated top in content coords> gap=<to previous bubble's bottom>, a trailing
  /// `!` when the gap goes negative (the overlap, caught in motion) plus the live offset.
  private func startSendFlightSampler(reason: String, duration: CFTimeInterval) {
    guard chatListSendFlightSamplerEnabled else { return }
    let keys =
      collectionView.indexPathsForVisibleItems
      .sorted { $0.item < $1.item }
      .suffix(4)
      .compactMap { ip -> String? in
        ip.item < rows.count && rows[ip.item].kind == .message ? rows[ip.item].key : nil
      }
    guard !keys.isEmpty else { return }
    let startedAt = ProcessInfo.processInfo.systemUptime
    let lastMs = Int((duration + 0.06) * 1000.0)
    for ms in stride(from: 0, through: lastMs, by: 45) {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(ms) / 1000.0) { [weak self] in
        guard let self else { return }
        let t = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0)
        var parts: [String] = []
        var prevBottom: CGFloat = -.greatestFiniteMagnitude
        for key in keys {
          guard let idx = self.rows.firstIndex(where: { $0.key == key }),
            let cell = self.collectionView.cellForItem(at: IndexPath(item: idx, section: 0))
          else { continue }
          let pres = cell.layer.presentation() ?? cell.layer
          let top = pres.position.y - pres.bounds.height / 2.0
          let bottom = top + pres.bounds.height
          let gap = prevBottom == -.greatestFiniteMagnitude ? 0.0 : top - prevBottom
          parts.append(
            String(
              format: "%@ top=%.1f gap=%.1f%@", String(key.suffix(6)), top, gap,
              gap < -0.5 ? "!" : ""))
          prevBottom = bottom
        }
        NSLog(
          "[SendFlight] %@ +%dms off=%.1f %@", reason, t,
          self.collectionView.contentOffset.y, parts.joined(separator: " "))
      }
    }
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

  private func logicalAgentTurnKey(for row: ChatListRow) -> String? {
    guard row.isAgentMessage else { return nil }
    let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    if let taskId = row.agentRuntime?.taskId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !taskId.isEmpty
    {
      return "\(chatKey)|task:\(taskId)"
    }
    if let teamRunId = row.agentRuntime?.teamRunId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !teamRunId.isEmpty
    {
      return "\(chatKey)|team:\(teamRunId)"
    }
    return nil
  }

  private func agentTurnRichness(_ row: ChatListRow) -> (nodes: Int, text: Int) {
    let progressText = row.agentProgressNodes.reduce(0) { partial, node in
      partial + node.label.count + (node.detail?.count ?? 0)
    }
    return (
      row.agentProgressNodes.count,
      (row.plainContent?.count ?? row.text.count) + progressText
    )
  }

  /// One logical task owns one transcript cell. A settled row always wins; while live,
  /// keep the richest snapshot observed so out-of-order bridge packets cannot shrink the
  /// card or duplicate it under a second transport row.
  private func rowsPreservingAgentTurnHighWater(_ candidateRows: [ChatListRow]) -> [ChatListRow] {
    guard !candidateRows.isEmpty else { return candidateRows }
    var result: [ChatListRow] = []
    result.reserveCapacity(candidateRows.count)
    var resultIndexByTurnKey: [String: Int] = [:]
    var settledTurnKeys = Set<String>()

    for row in candidateRows {
      guard let turnKey = logicalAgentTurnKey(for: row) else {
        result.append(row)
        continue
      }

      if !bridgeRowIsLive(row) {
        liveAgentTurnHighWaterByKey.removeValue(forKey: turnKey)
        settledTurnKeys.insert(turnKey)
        if let existingIndex = resultIndexByTurnKey[turnKey] {
          result[existingIndex] = row
        } else {
          resultIndexByTurnKey[turnKey] = result.count
          result.append(row)
        }
        continue
      }

      // A late live packet must never replace a final row for this same task.
      if settledTurnKeys.contains(turnKey) { continue }
      var richest = row
      if let previous = liveAgentTurnHighWaterByKey[turnKey] {
        let old = agentTurnRichness(previous)
        let new = agentTurnRichness(row)
        if new.nodes < old.nodes, new.text <= old.text {
          richest = previous
        }
      }
      liveAgentTurnHighWaterByKey[turnKey] = richest
      if let existingIndex = resultIndexByTurnKey[turnKey] {
        let existing = result[existingIndex]
        let old = agentTurnRichness(existing)
        let new = agentTurnRichness(richest)
        if new.nodes > old.nodes || (new.nodes == old.nodes && new.text >= old.text) {
          result[existingIndex] = richest
        }
      } else {
        resultIndexByTurnKey[turnKey] = result.count
        result.append(richest)
      }
    }
    return result
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
    chatOpenStartedAt = ProcessInfo.processInfo.systemUptime
    openingUnreadCount = 0
    shouldApplyOpeningViewport = true
    userHasScrolledSinceOpen = false
    loadPersistedOpeningViewport(chatId: next)
    preloadReopenSnapshotFromDiskIfNeeded()
    progressiveHeightWarmupWorkItem?.cancel()
    progressiveHeightWarmupWorkItem = nil
    progressiveHeightWarmupKeys = []
    progressiveHeightWarmupGeneration &+= 1
    usesProgressiveTranscriptSizing = false
    pendingPresentationSeedReconcile = false
    pendingPresentationSeedWindowStart = false
    deferredPresentationSeedSourceRows = nil
    deferredPresentationSeedPreferredRows = nil
    removeReopenSnapshotOverlay(reason: "chat-switch", animated: false)
    removeSeedLoadingIndicator(reason: "chat-switch")
    deltaStreamCoalesceWorkItem?.cancel()
    deltaStreamCoalesceWorkItem = nil
    engineDeltaRefreshPending = false
    nextApplyBaseIsEngineAuthoritative = false
    windowedTranscriptSourceRows = nil
    windowedTranscriptVisibleCount = 0
    isRevealingOlderTranscriptRows = false
    pendingHistoryRevealAfterScroll = false
    resetOlderHistoryPaginationState(clearExhausted: true)
    rowsDeferredUntilScrollSettles = nil
    rowsDeferredUntilScrollSettlesAuthority = nil
    rowsDeferredUntilScrollSettlesHistoryPrepend = false
    hideCachedHistoryPullIndicator(animated: false)
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
    liveAgentTurnHighWaterByKey.removeAll()
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
    bridgeHistoryFollowUpSentIds = []
    bridgeAgentManuallyShown = false
    agentTurnExpandedStepIdsByRow.removeAll()
    agentTurnProgressExpandedRowIds.removeAll()
    agentTurnRuntimeExpandedRowIds.removeAll()
    agentTurnStreamStartByRow.removeAll()
    cancelAgentResponseWatchdog(reason: "chat_switch")
    lastAgentResponseSend = nil
    hideAgentResponseNotice(animated: false)
    reusableParsedRowsByKey = [:]
    // Stage timings from the tap: everything below runs synchronously on main before
    // the push can settle, so a slow open shows up as one of these numbers.
    func stageMs(_ since: TimeInterval) -> Int {
      Int((ProcessInfo.processInfo.systemUptime - since) * 1000)
    }
    var stageStartedAt = ProcessInfo.processInfo.systemUptime
    loadPersistedRowHeights(chatId: next)
    let heightsMs = stageMs(stageStartedAt)
    stageStartedAt = ProcessInfo.processInfo.systemUptime
    restoreWarmTranscriptIfAvailable(chatId: next)
    let warmRestoreMs = stageMs(stageStartedAt)
    scheduleBridgeAgentPresenceRefresh()
    updateChatEngineBinding()
    updateChatEngineChannelBinding()
    if statusAuthorityEnabled {
      refreshVisibleStatuses(reason: "chatId")
    }
    // Always try early seed — do not wait for statusAuthority (that deferral caused
    // empty wallpaper for the full push on large agent groups).
    stageStartedAt = ProcessInfo.processInfo.systemUptime
    hydrateRowsFromNativeHistoryIfReady(trigger: "chatId")
    NSLog(
      "[ChatOpen] engine-bind chat=%@ heightsMs=%d warmRestoreMs=%d hydrateMs=%d totalMs=%d",
      String(next.prefix(12)), heightsMs, warmRestoreMs, stageMs(stageStartedAt),
      stageMs(chatOpenStartedAt))
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
    inputBar?.setAgentControlMode(
      agentChatMode || currentBridgeProvider != nil || groupHasBridgeAgents())
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
    NSLog(
      "[ChatOpen] inbox-mode chat=%@ enabled=%@ seeded=%@ rows=%d",
      String(engineChatId.prefix(12)), enabled ? "Y" : "N",
      pendingPresentationSeedReconcile ? "Y" : "N", rows.count)
    // The mode routinely flips ON only after the presentation seed mounted (host
    // resolves agent config async). The seed then holds event-notification rows the
    // flush must delete — and deleting them reloads their heavy AgentKit neighbors
    // on EVERY open. Re-apply the seed filter in place so the flush reconciles equal.
    if enabled, pendingPresentationSeedReconcile, !rows.isEmpty {
      let filtered = rows.filter { row in
        guard row.kind == .message else { return true }
        if row.hiddenFromTranscript { return false }
        if row.isEventNotification, !row.isEventInboxSummary { return false }
        return true
      }
      if filtered.count != rows.count {
        // Removing a day's only messages orphans its synthesized day row; the flush's
        // freshly-normalized source has no such row, so prune it here too.
        var pruned: [ChatListRow] = []
        pruned.reserveCapacity(filtered.count)
        var pendingDayRow: ChatListRow?
        for row in filtered {
          if row.key.hasPrefix("chat-day-") {
            pendingDayRow = row
            continue
          }
          if let day = pendingDayRow {
            pruned.append(day)
            pendingDayRow = nil
          }
          pruned.append(row)
        }
        let removedCount = rows.count - pruned.count
        rows = pruned
        UIView.performWithoutAnimation {
          flowLayout.invalidateLayout()
          collectionView.reloadData()
          if collectionView.bounds.width > 1.0, collectionView.bounds.height > 1.0 {
            collectionView.layoutIfNeeded()
            updateFloatingSenderAvatars()
          }
        }
        NSLog(
          "[ChatOpen] seed inbox-refilter chat=%@ removed=%d remaining=%d",
          String(engineChatId.prefix(12)), removedCount, rows.count)
      }
    }
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
    // Lock list chrome materials to chat theme dark/light (not ambient system style).
    overrideUserInterfaceStyle = next.isDark ? .dark : .light
    collectionView.overrideUserInterfaceStyle = next.isDark ? .dark : .light
    inputBar?.applyAppearance(next)
    applyScrollingDatePillAppearance(next)
    if cachedHistoryPullIndicatorInstalled {
      cachedHistoryPullIndicator.applyAppearance(
        isDark: next.isDark,
        color: next.timeColorThem
      )
    }
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
    collectionView.layoutIfNeeded()
    let maxOffsetY = pixelAlignedValue(
      max(0.0, collectionView.contentSize.height - collectionView.bounds.height))
    if animated {
      if isBottomGlideInFlight {
        isBottomGlideInFlight = false
        isInternalScrollAdjustment = false
      }
      shouldAutoScroll = true
      // Long-distance jumps must not glide the whole way: Telegram-style teleport —
      // hop (unanimated) to one viewport above the bottom, then travel the last screen.
      let viewportH = max(1.0, collectionView.bounds.height)
      if maxOffsetY - collectionView.contentOffset.y > viewportH * 2.5 {
        performInternalScrollAdjustment {
          collectionView.setContentOffset(
            CGPoint(x: 0.0, y: max(0.0, maxOffsetY - viewportH)), animated: false)
        }
        collectionView.layoutIfNeeded()
        // Mounting the destination converts estimated heights to exact ones and can
        // move the real bottom. Re-anchor the hop against the REMEASURED bottom —
        // gliding to the stale target overshot into blank space (the "list cleared"
        // flash) and then visibly snapped back in the completion.
        let remeasuredMaxY = pixelAlignedValue(
          max(0.0, collectionView.contentSize.height - collectionView.bounds.height))
        if abs(remeasuredMaxY - maxOffsetY) > 1.0 {
          performInternalScrollAdjustment {
            collectionView.setContentOffset(
              CGPoint(x: 0.0, y: max(0.0, remeasuredMaxY - viewportH)), animated: false)
          }
          collectionView.layoutIfNeeded()
        }
        // The glide's starting screen must be REAL — materialized cells, placed
        // avatars/toggles — or the travel departs from bare wallpaper.
        materializeCellsAfterProgrammaticJump(context: "bottom-hop")
      }
      let targetMaxOffsetY = pixelAlignedValue(
        max(0.0, collectionView.contentSize.height - collectionView.bounds.height))
      guard abs(targetMaxOffsetY - collectionView.contentOffset.y) > 1.0 else {
        // Already there (or the hop landed exactly): a zero-distance animated set
        // fires no didEndScrollingAnimation, which would strand the in-flight flags.
        materializeCellsAfterProgrammaticJump(context: "bottom-noop")
        previousOffsetY = collectionView.contentOffset.y
        emitViewport(force: true)
        return
      }
      // NATIVE animated scroll, not a UIViewPropertyAnimator over contentOffset: the
      // property animator moves the MODEL offset instantly, so the cells at the start
      // screen are recycled on the next layout pass and the presentation layer sweeps
      // across never-mounted rows — the reported "tap the button and the list goes
      // empty / it skips instead of traveling". The native scroll ticks the model
      // offset every frame, so cells materialize continuously and every overlay
      // (avatars, toggles, wallpaper) rides the travel via scrollViewDidScroll.
      // Completion lands in scrollViewDidEndScrollingAnimation.
      isInternalScrollAdjustment = true
      isBottomGlideInFlight = true
      collectionView.setContentOffset(CGPoint(x: 0.0, y: targetMaxOffsetY), animated: true)
    } else {
      if isBottomGlideInFlight {
        // The non-animated set below cancels the native glide mid-flight, and its
        // didEndScrollingAnimation never fires — clear the flags here or every pan
        // stops updating shouldAutoScroll and the jump chrome ("button appears late").
        isBottomGlideInFlight = false
        isInternalScrollAdjustment = false
      }
      performInternalScrollAdjustment {
        collectionView.setContentOffset(CGPoint(x: 0.0, y: maxOffsetY), animated: false)
      }
      materializeCellsAfterProgrammaticJump(context: "bottom-teleport")
      previousOffsetY = collectionView.contentOffset.y
      shouldAutoScroll = true
      emitViewport(force: true)
    }
  }

  /// Native-glide completion (jump-to-bottom travel). Fires only for animated
  /// setContentOffset — a user grab mid-glide cancels the animation and routes through
  /// scrollViewWillBeginDragging instead.
  public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    guard isBottomGlideInFlight else { return }
    isBottomGlideInFlight = false
    isInternalScrollAdjustment = false
    // Streaming or a late cell measurement can extend OR shrink content during the
    // glide. Correct the final remainder, then verify the destination actually
    // materialized cells.
    collectionView.layoutIfNeeded()
    let finalMaxOffsetY = pixelAlignedValue(
      max(0.0, collectionView.contentSize.height - collectionView.bounds.height))
    if abs(finalMaxOffsetY - collectionView.contentOffset.y) > 1.0 {
      performInternalScrollAdjustment {
        collectionView.setContentOffset(CGPoint(x: 0.0, y: finalMaxOffsetY), animated: false)
      }
    }
    materializeCellsAfterProgrammaticJump(context: "bottom-glide")
    previousOffsetY = collectionView.contentOffset.y
    emitViewport(force: true)
  }

  /// Programmatic offset teleports (seed restore, jump-to-bottom hop/land) move the
  /// model offset without a user scroll, and the destination's cells only materialize
  /// on a later layout pass. If content shrank during the move (estimated→exact
  /// heights), the offset can even land in blank space BELOW the last cell: zero
  /// visible cells while the floating-avatar overlay deliberately preserves its last
  /// frame — the reported "tap the toggle and the list goes empty except one avatar,
  /// content reappears after a pinch". Run the pass NOW, clamp any overshoot, and
  /// reload if cells still failed to materialize (same self-heal as attach).
  private func materializeCellsAfterProgrammaticJump(context: String) {
    guard !rows.isEmpty, collectionView.bounds.height > 1.0 else { return }
    collectionView.layoutIfNeeded()
    let maxOffset = max(0.0, collectionView.contentSize.height - collectionView.bounds.height)
    if collectionView.contentOffset.y > maxOffset + 1.0 {
      performInternalScrollAdjustment {
        collectionView.setContentOffset(
          CGPoint(x: 0.0, y: pixelAlignedValue(maxOffset)), animated: false)
      }
      collectionView.layoutIfNeeded()
      NSLog(
        "[ChatOpen] jump CLAMP context=%@ chat=%@ — offset overshot content",
        context, String(engineChatId.prefix(12)))
    }
    if collectionView.indexPathsForVisibleItems.isEmpty, collectionView.contentSize.height > 0 {
      NSLog(
        "[ChatOpen] jump REVALIDATE context=%@ chat=%@ — 0 cells at offset=%.0f",
        context, String(engineChatId.prefix(12)), collectionView.contentOffset.y)
      collectionView.reloadData()
      collectionView.layoutIfNeeded()
    }
    updateFloatingSenderAvatars()
    // The expand/collapse chips live on the same overlay pattern as the avatars and
    // were only re-placed by scroll ticks / container layout — after a programmatic
    // jump neither runs, so the chips trailed the content ("toggle appears late").
    updateTallBubbleGlassToggles(animatedIcons: false)
    updateJumpToBottomButtonVisibility()
  }

  private func updateJumpToBottomButtonVisibility() {
    let dist = currentDistanceFromBottom()
    let isFar = dist > listBottomThreshold
    if !isFar, newMessagesWhileAwayCount != 0 {
      newMessagesWhileAwayCount = 0
      updateJumpToBottomBadge()
    }
    setJumpButtonVisible(isFar)
  }

  private func updateJumpToBottomBadge() {
    let count = newMessagesWhileAwayCount
    jumpToBottomButton.setUnreadCount(count)
    layoutJumpToBottomButton()
  }

  private func setJumpButtonVisible(_ visible: Bool) {
    let shouldShow = visible && !rows.isEmpty
    guard shouldShow != !jumpToBottomButton.isHidden else { return }

    if jumpToBottomButton.superview == nil {
      addSubview(jumpToBottomButton)
      setNeedsLayout()
      layoutIfNeeded()
    }

    // Never animate a live glass effect's opacity/transform. Direct visibility avoids
    // the iOS glass fade glitch and, unlike the old centered scale animation, cannot
    // steal a frame from an active list pan.
    jumpToBottomButton.layer.removeAllAnimations()
    jumpToBottomButton.alpha = 1.0
    jumpToBottomButton.transform = .identity
    jumpToBottomButton.isHidden = !shouldShow
  }

  @objc private func jumpToBottomTapped() {
    newMessagesWhileAwayCount = 0
    updateJumpToBottomBadge()
    scrollToBottom(animated: true, force: true)
  }

  /// The sticky date pill's fixed slot, just under the header chrome. In-list day
  /// separators hand off to this slot as they scroll behind the header.
  private func scrollingDatePillSlotY() -> CGFloat {
    max(8.0, safeAreaInsets.top + 63.0)
  }

  private func layoutScrollingDatePill() {
    guard !scrollingDatePill.isHidden else { return }
    // Metrics mirror the in-list day pill exactly (same paddings, same capsule) so the
    // header stick reads as the SAME element, not a second material.
    let textSize = scrollingDateLabel.sizeThatFits(
      CGSize(width: max(0.0, bounds.width - 80.0), height: 24.0))
    let width = min(
      max(58.0, ceil(textSize.width) + (dayPillHorizontalPadding * 2.0)),
      max(58.0, bounds.width - 40.0))
    let height = ceil(textSize.height) + (dayPillVerticalPadding * 2.0)
    scrollingDatePill.frame = CGRect(
      x: floor((bounds.width - width) * 0.5),
      y: scrollingDatePillSlotY(),
      width: width,
      height: height)
    scrollingDatePill.layer.cornerRadius = height / 2.0
    scrollingDateLabel.frame = scrollingDatePill.bounds
  }

  private func applyScrollingDatePillAppearance(_ value: ChatListAppearance) {
    scrollingDateLabel.textColor = value.dayTextColor
    scrollingDatePill.backgroundColor = value.dayBackgroundColor
    scrollingDatePill.layer.borderWidth = 0.0
  }

  private func cancelScrollingDatePillLinger() {
    scrollingDatePillHideWorkItem?.cancel()
    scrollingDatePillHideWorkItem = nil
  }

  /// Scroll settled: keep the date visible for a beat, then fade it out — instead of the
  /// old instant blink-out the moment the finger lifted.
  private func scheduleScrollingDatePillLinger() {
    cancelScrollingDatePillLinger()
    guard !scrollingDatePill.isHidden else { return }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.scrollingDatePillHideWorkItem = nil
      UIView.animate(
        withDuration: 0.22,
        delay: 0.0,
        options: [.beginFromCurrentState, .curveEaseOut]
      ) {
        self.scrollingDatePill.alpha = 0.0
      } completion: { finished in
        guard finished, self.scrollingDatePillHideWorkItem == nil else { return }
        self.scrollingDatePill.isHidden = true
        self.scrollingDatePill.alpha = 1.0
      }
    }
    scrollingDatePillHideWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
  }

  private func updateScrollingDatePill(visible: Bool) {
    // The history progress control and date use one viewport-pinned safe-area slot.
    // Showing both would read as a warped double material while pulling toward history.
    guard visible, !rows.isEmpty, cachedHistoryPullIndicator.alpha <= 0.01 else {
      cancelScrollingDatePillLinger()
      scrollingDatePill.isHidden = true
      scrollingDatePill.alpha = 1.0
      return
    }
    let visibleItems = collectionView.indexPathsForVisibleItems.sorted { lhs, rhs in
      guard
        let left = collectionView.layoutAttributesForItem(at: lhs),
        let right = collectionView.layoutAttributesForItem(at: rhs)
      else { return lhs.item < rhs.item }
      return left.frame.minY < right.frame.minY
    }
    guard let indexPath = visibleItems.first(where: { $0.item < rows.count }) else {
      cancelScrollingDatePillLinger()
      scrollingDatePill.isHidden = true
      scrollingDatePill.alpha = 1.0
      return
    }
    let row = rows[indexPath.item]
    let label =
      scrollingDateLabelsByRowKey[row.key]
      ?? (row.kind == .day ? row.label : nil)
    guard let label, !label.isEmpty else {
      cancelScrollingDatePillLinger()
      scrollingDatePill.isHidden = true
      scrollingDatePill.alpha = 1.0
      return
    }

    // Shared-element hand-off: while the in-list day separator that owns this label sits
    // at/under the sticky slot, IT is the pill — showing the overlay too would render the
    // same capsule twice. The overlay takes over the moment the separator slides behind
    // the header chrome.
    let slotY = scrollingDatePillSlotY()
    let offsetY = collectionView.contentOffset.y
    for candidate in visibleItems {
      guard candidate.item < rows.count, rows[candidate.item].kind == .day else { continue }
      guard rows[candidate.item].label == label else { break }
      guard let attrs = collectionView.layoutAttributesForItem(at: candidate) else { break }
      let pillHeight = ceil(scrollingDateLabel.font.lineHeight) + (dayPillVerticalPadding * 2.0)
      let cellPillMinY = attrs.frame.midY - offsetY - (pillHeight / 2.0)
      if cellPillMinY > slotY - 4.0 {
        cancelScrollingDatePillLinger()
        scrollingDatePill.isHidden = true
        scrollingDatePill.alpha = 1.0
        return
      }
      break
    }

    cancelScrollingDatePillLinger()
    scrollingDatePill.layer.removeAnimation(forKey: "opacity")
    let wasVisible = !scrollingDatePill.isHidden && scrollingDatePill.alpha > 0.01
    if scrollingDateLabel.text != label {
      // Day boundary crossed while stuck: the incoming date pushes the old one out the
      // way the in-list separator is travelling (up toward now, down toward history).
      if wasVisible {
        let push = CATransition()
        push.type = .push
        push.subtype = lastScrollDeltaY < 0.0 ? .fromTop : .fromBottom
        push.duration = 0.18
        push.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scrollingDatePill.layer.add(push, forKey: "datePillPush")
      }
      scrollingDateLabel.text = label
    }
    scrollingDatePill.isHidden = false
    scrollingDatePill.alpha = 1.0
    layoutScrollingDatePill()

    // Pinned-section-header shove: when the NEXT day's in-list separator rises into the
    // sticky slot from below, translate the current floating date UP so it tucks up behind
    // the header, then that separator hands off as the new sticky date (the reverse,
    // scroll-up direction, is covered by the same-label suppression above). This is what
    // makes the date read as an attached element that y-translates behind the header,
    // rather than a fixed pill that only cross-fades its text in place.
    let pillHeight = scrollingDatePill.bounds.height
    var shoveUp: CGFloat = 0.0
    if pillHeight > 0.0 {
      for candidate in visibleItems {
        guard candidate.item < rows.count, rows[candidate.item].kind == .day,
          rows[candidate.item].label != label,
          let attrs = collectionView.layoutAttributesForItem(at: candidate)
        else { continue }
        let separatorTop = attrs.frame.midY - offsetY - (pillHeight / 2.0)
        guard separatorTop >= slotY - 0.5 else { continue }  // only separators still below the slot
        if separatorTop <= slotY + pillHeight {
          shoveUp = min(pillHeight, max(0.0, (slotY + pillHeight) - separatorTop))
        }
        break  // the nearest upcoming boundary owns the shove
      }
    }
    if shoveUp > 0.5 {
      scrollingDatePill.transform = CGAffineTransform(translationX: 0.0, y: -shoveUp)
      scrollingDatePill.alpha = max(0.0, 1.0 - (shoveUp / pillHeight))
    } else {
      scrollingDatePill.transform = .identity
      scrollingDatePill.alpha = 1.0
    }
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
    let mediaDownloadState = remoteMediaDownloadState(for: row)
    if let hid = hiddenMessageId, row.kind == .message, row.messageId == hid {
      VibeDebugLog.log(
        "[FirstMsg] cellForItemAt GHOST configure item=%d msgId=%@ rows=%d pending=%@ active=%@",
        indexPath.item, String(hid.prefix(12)), rows.count,
        pendingSendTransition != nil ? "Y" : "N",
        activeSendTransition != nil ? "Y" : "N")
    }
    // NEVER skip remote preview for images/gifs — empty shells were the reported bug.
    // Network path already decrypts with mediaKey when present.
    let isImageLike =
      row.visualKind == .media
      && row.messageType != "file"
    let skipRemotePreview = mediaDownloadState.needsDownload && !isImageLike
    configureMessageCell(
      cell,
      at: indexPath,
      row: row,
      skipRemoteMediaLoad: skipRemotePreview,
      preferredLocalMediaURLOverride: preferredLocalMediaURLOverride
    )
    bindWallpaperBackdrop(to: cell)
    // Don't show the download ring for images we stream-decrypt inline — it looked like
    // an empty cell with a stuck spinner/placeholder.
    let showDownloadChrome = mediaDownloadState.needsDownload && !isImageLike
    cell.applyMediaDownloadState(
      needsDownload: showDownloadChrome,
      isDownloading: showDownloadChrome && mediaDownloadState.isDownloading,
      progress: showDownloadChrome ? mediaDownloadState.progress : nil
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
    cell.onMediaGridTileTap = { [weak self] row, tileIndex, sourceView in
      guard let self else { return }
      // Cell-internal tile taps have no failure dependency on the context-menu
      // long press, so a hold on an image fired this on finger-lift and opened
      // the editor over the menu.
      guard self.customContextMenuOverlay == nil else { return }
      self.presentNativeImageOpen(for: row, gridIndex: tileIndex, sourceView: sourceView)
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
            // Tools + Grok exposed thinking (compact row → sheet with full CoT) +
            // compacting notes. Thinking is slightly different from Claude's
            // encrypted CoT: Grok ships plaintext detail on the node.
            if kind == "bash" || kind == "edit" || kind == "write" || kind == "read"
              || kind == "todo" || kind == "planning" || kind == "thinking" || kind == "compacting"
              || kind == "mcp" || kind == "tool" || kind == "web" || kind == "search" || kind == "task"
            {
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
          // diffs row CONTENT, which is unchanged here, and would no-op). Animate so
          // the cell height morphs with the double-chevron instead of jumping.
          if self.tallBubbleExpandedRowIds.contains(messageId) {
            self.tallBubbleExpandedRowIds.remove(messageId)
          } else {
            self.tallBubbleExpandedRowIds.insert(messageId)
          }
          self.reloadAgentTurnStateRow(
            messageId: messageId, reason: "toggleTallBubble", animated: true)
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
      let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
      let sourceView = cell?.currentMediaImageView()
      // Always native image open — do not route through file download/QL for photos.
      presentNativeImageOpen(for: row, gridIndex: 0, sourceView: sourceView)
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
    // Team-worker rows in a supervisor lead bubble share the subagent tap channel with
    // a "teamworker:<handle>" node id — route them to the worker detail instead.
    if parentNodeId.hasPrefix("teamworker:") {
      presentTeamWorkerDetailView(
        row: row, worker: String(parentNodeId.dropFirst("teamworker:".count)))
      return
    }
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

  /// One supervisor team worker's read-only detail — reached by tapping its avatar row
  /// inside the lead bubble. Lead taps show the lead's own step feed; under-hood workers
  /// show their cached fold-in stream (`latestTeamWorkerProgressNodes`).
  private func presentTeamWorkerDetailView(row: ChatListRow, worker: String) {
    guard let presenter = topPresentingViewController() else { return }
    guard let runtime = row.agentRuntime else { return }
    let status = runtime.teamWorkersStatus.first {
      $0.worker.caseInsensitiveCompare(worker) == .orderedSame
    }
    let leadHandle = runtime.leadWorker ?? runtime.teamWorker ?? runtime.provider ?? ""
    let isLead = worker.caseInsensitiveCompare(leadHandle) == .orderedSame
    let items: [VibeAgentKitProgressItem]
    if isLead {
      items = row.agentProgressNodes.map { VibeAgentKitMap.progressItem(from: $0) }
    } else if let raw = ChatEngine.shared.latestTeamWorkerProgressNodes(
      chatId: (row.chatId?.isEmpty == false ? row.chatId! : engineChatId),
      teamRunId: runtime.teamRunId ?? ""
    )?[worker] {
      items = parseAgentProgressNodesPublic(raw).map { VibeAgentKitMap.progressItem(from: $0) }
    } else {
      items = []
    }
    let running = status?.isRunning ?? row.isStreamingText
    // A worker with nothing to show AND no live run would present empty glass chrome.
    guard running || !items.isEmpty || status?.summary?.isEmpty == false else { return }
    let name = status?.label.isEmpty == false ? status!.label : worker.capitalized
    let title = status?.compactLine ?? (running ? "\(name) — working…" : name)
    let detail = VibeAgentSubagentDetailViewController(
      subagentType: worker,
      titleOverride: title,
      bodyText: status?.summary ?? "",
      progressItems: items,
      running: running,
      appearance: VibeAgentKitMap.appearance(for: traitCollection)
    )
    let nav = UINavigationController(rootViewController: detail)
    nav.modalPresentationStyle = .pageSheet
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
  /// Supervisor team runs open the multi-agent sheet (per-worker sections + cancel team).
  private func presentAgentTurnDetailView(row: ChatListRow) {
    guard let presenter = topPresentingViewController() else { return }
    let message = VibeAgentKitMap.chatMessage(from: row)
    let bodyText = resoloAssistantDisplayText(for: message)

    if let runtime = row.agentRuntime,
      (!runtime.teamWorkersStatus.isEmpty
        || runtime.teamMode == "supervisor"
        || runtime.teamMode == "group_supervisor"),
      let teamRunId = runtime.teamRunId, !teamRunId.isEmpty
    {
      presentTeamRunDetailView(
        row: row, runtime: runtime, bodyText: bodyText, streaming: message.isStreaming)
      return
    }

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

  private func presentTeamRunDetailView(
    row: ChatListRow,
    runtime: ChatListRow.AgentRuntimeSummary,
    bodyText: String,
    streaming: Bool
  ) {
    guard let presenter = topPresentingViewController() else { return }
    let appearance = VibeAgentKitMap.appearance(for: traitCollection)
    let leadHandle =
      runtime.leadWorker
      ?? runtime.teamWorker
      ?? runtime.provider
      ?? "lead"

    // Per-worker progress cache (under-hood workers) for the multi-agent sheet.
    let byWorkerRaw =
      ChatEngine.shared.latestTeamWorkerProgressNodes(
        chatId: row.chatId ?? engineChatId,
        teamRunId: runtime.teamRunId ?? ""
      ) ?? [:]

    var sections: [VibeAgentTeamRunDetailViewController.Section] = []
    let statuses =
      runtime.teamWorkersStatus.isEmpty
      ? runtime.teamWorkers.map {
        ChatListRow.TeamWorkerStatus(
          worker: $0,
          label: $0.capitalized,
          status: streaming ? "running" : "done",
          startedAt: nil,
          finishedAt: nil,
          durationMs: nil,
          summary: nil,
          taskId: nil,
          lastLabel: nil
        )
      } : runtime.teamWorkersStatus

    for status in statuses {
      let isLead = status.worker == leadHandle
      let nodes: [ChatListRow.AgentProgressNode]
      if isLead {
        nodes = row.agentProgressNodes
      } else if let raw = byWorkerRaw[status.worker] {
        nodes = parseAgentProgressNodesPublic(raw)
      } else {
        nodes = []
      }
      let items = nodes.map { VibeAgentKitMap.progressItem(from: $0) }
      sections.append(
        .init(
          worker: status.worker,
          label: status.label,
          statusLine: status.compactLine,
          isLead: isLead,
          progressItems: items
        )
      )
    }

    let title =
      streaming
      ? "Team working…"
      : "Team finished"
    let running = streaming || runtime.status == "running"
    let detail = VibeAgentTeamRunDetailViewController(
      title: title,
      bodyText: bodyText,
      sections: sections,
      running: running,
      canCancel: running,
      appearance: appearance
    )
    let chatId = (row.chatId?.isEmpty == false ? row.chatId! : engineChatId)
    let teamRunId = runtime.teamRunId
    let provider = runtime.provider ?? leadHandle
    detail.onCancelTeam = { [weak self] in
      guard let teamRunId, !teamRunId.isEmpty else { return }
      var payload: [String: Any] = [
        "chatId": chatId,
        "provider": provider,
        "action": "cancel",
        "teamRunId": teamRunId,
      ]
      if let taskId = runtime.taskId, !taskId.isEmpty {
        payload["taskId"] = taskId
      }
      _ = ChatEngine.shared.sendAgentBridgeControl(payload)
      self?.refreshAgentTurnRows()
    }
    let nav = UINavigationController(rootViewController: detail)
    nav.modalPresentationStyle = .pageSheet
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
    // (tall bubble, step expand) a silent no-op on those chats.
    guard
      !sourceRowsPayload.isEmpty || !nativeEngineRowsById.isEmpty || !nativeOutgoingRowsById.isEmpty
    else { return }
    setRows(sourceRowsPayload)
  }

  /// Targeted re-render for a purely LOCAL expand/collapse flip (tall bubble, progress
  /// expand, runtime expand). These flips change NO row content, so routing them through
  /// setRows is a guaranteed no-op: the diff compares row payloads (`chatListRowContentEqual`),
  /// finds zero reloads, and short-circuits before any reconfigure or layout invalidation —
  /// the flipped state is never re-read. Reload the one row directly instead: drop its
  /// cached height (keyed on the expand state), invalidate layout, reconfigure the cell.
  /// Pass `animated: true` for tall-bubble morph so the cell height eases instead of jumps.
  private func reloadAgentTurnStateRow(
    messageId: String, reason: String, animated: Bool = false
  ) {
    guard let index = rows.firstIndex(where: { ($0.messageId ?? $0.key) == messageId }) else {
      NSLog(
        "[TallToggle] %@ row NOT FOUND id=%@ rows=%d", reason, String(messageId.prefix(24)),
        rows.count)
      return
    }
    let row = rows[index]
    let indexPath = IndexPath(item: index, section: 0)
    // Match sizeForItemAt exactly. Group/channel rows subtract the sender-avatar gutter;
    // seeding with the unadjusted list width makes presentationSeedMessageHeight reject
    // the cache and fall back to its 430pt cap, so an expanded bubble stays clipped.
    let rowWidth = groupMeasurementExtras(at: indexPath).measurementWidth
    let oldHeight =
      agentTurnHeightCache[row.key]?.height ?? messageHeightCache[row.key]?.height ?? -1.0
    agentTurnHeightCache.removeValue(forKey: row.key)
    messageHeightCache.removeValue(forKey: row.key)
    // Populate the NEW expand-state cache before invalidating layout. Progressive sizing
    // consults this cache during the batch update; computing it afterward leaves the row
    // at the bounded presentation estimate with no second size query.
    let newHeight = estimateMessageHeight(row, rowWidth: rowWidth)
    tallBubbleAnimationGeneration &+= 1
    let animationGeneration = tallBubbleAnimationGeneration
    let expanding = tallBubbleExpandedRowIds.contains(messageId)
    // Anchor interrupted transitions from what is actually on screen, not the previous
    // model-layer destination. The overlay and list share this view's coordinate space.
    let anchoredToggleY: CGFloat? = {
      guard animated, let control = tallToggleViewsById[messageId] else { return nil }
      return control.layer.presentation()?.frame.minY ?? control.frame.minY
    }()

    let apply: () -> Void = { [weak self] in
      guard let self else { return }
      self.flowLayout.invalidateLayout()
      self.collectionView.performBatchUpdates(
        {
          if #available(iOS 15.0, *), self.rows.count > 1 {
            self.collectionView.reconfigureItems(at: [indexPath])
          } else {
            self.collectionView.reloadItems(at: [indexPath])
          }
        },
        completion: nil)
      self.collectionView.layoutIfNeeded()
      // A collapse near the bottom shrinks content above the viewport floor — clamp the
      // offset back into range so the list doesn't hang past its own end.
      let maxOffset = max(
        0.0, self.collectionView.contentSize.height - self.collectionView.bounds.height)
      if self.collectionView.contentOffset.y > maxOffset {
        self.performInternalScrollAdjustment {
          self.collectionView.setContentOffset(
            CGPoint(x: 0.0, y: maxOffset), animated: false)
        }
      }
    }

    if animated {
      isTallMorphInFlight = true
      // Height-only in Y: ease the cell bounds at a medium pace. The offset correction
      // is part of this same transaction; doing it after completion made collapse snap.
      UIView.animate(
        withDuration: 0.30,
        delay: 0,
        options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut],
        animations: {
          // Invalidate only after the exact new-state height is cached, and inside the
          // animation transaction so the old→new cell bounds interpolate vertically.
          self.flowLayout.invalidateLayout()
          self.collectionView.performBatchUpdates(
            {
              if #available(iOS 15.0, *), self.rows.count > 1 {
                self.collectionView.reconfigureItems(at: [indexPath])
              } else {
                self.collectionView.reloadItems(at: [indexPath])
              }
            },
            completion: nil)
          self.collectionView.layoutIfNeeded()
          if let anchoredToggleY {
            self.anchorTallBubble(
              messageId: messageId,
              at: indexPath,
              screenY: anchoredToggleY
            )
          }
          if let cell = self.collectionView.cellForItem(at: indexPath) as? ChatListCell {
            cell.animateTallBubbleInnerContent(
              expanding: expanding,
              duration: 0.30
            )
          }
          self.updateTallBubbleGlassToggles(animatedIcons: true)
          // Frames set inside the transaction, so every floating avatar RIDES the same
          // 0.30 ease to its post-morph spot alongside the cells. Without this the
          // avatars froze at pre-morph positions and overlapped the neighbor bubbles
          // until the next scroll tick ("expansion conflicts with another cell").
          self.updateFloatingSenderAvatars()
        },
        completion: { _ in
          // Unconditional: any interleaved reload bumps the generation, and the guard
          // below skipping must never leave the in-flight flag stuck (frozen overlays
          // on every future scroll).
          self.isTallMorphInFlight = false
          guard self.tallBubbleAnimationGeneration == animationGeneration else { return }
          self.updateTallBubbleGlassToggles(animatedIcons: false)
          self.updateFloatingSenderAvatars()
        })
    } else {
      isTallMorphInFlight = false
      UIView.performWithoutAnimation {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply()
        CATransaction.commit()
      }
      updateTallBubbleGlassToggles(animatedIcons: false)
      updateFloatingSenderAvatars()
    }
    NSLog(
      "[TallToggle] %@ id=%@ index=%d height %.0f→%.0f expanded=%@ animated=%@",
      reason, String(messageId.prefix(24)), index, oldHeight, newHeight,
      tallBubbleExpandedRowIds.contains(messageId) ? "Y" : "N",
      animated ? "Y" : "N")
  }

  /// Preserve the tapped tall-toggle's screen Y while its row changes height. At the
  /// scroll boundaries the bounded content offset wins, but it still reaches that bound
  /// inside the height animation instead of snapping in completion.
  private func anchorTallBubble(
    messageId: String,
    at indexPath: IndexPath,
    screenY: CGFloat
  ) {
    guard
      let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell,
      let anchor = cell.tallToggleAnchor(),
      anchor.messageId == messageId
    else { return }

    let bubbleScreenY = cell.convert(anchor.bubbleFrameInCell, to: self).minY
    let unboundedOffsetY = collectionView.contentOffset.y + (bubbleScreenY - screenY)
    let maxOffsetY = max(
      0.0, collectionView.contentSize.height - collectionView.bounds.height)
    let targetOffsetY = pixelAlignedValue(
      min(max(0.0, unboundedOffsetY), maxOffsetY)
    )
    guard abs(targetOffsetY - collectionView.contentOffset.y) > 0.25 else { return }
    performInternalScrollAdjustment {
      collectionView.setContentOffset(
        CGPoint(x: 0.0, y: targetOffsetY),
        animated: false
      )
    }
    collectionView.layoutIfNeeded()
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
    // The chat channel just (re)joined its topic. Refresh usage only. Session history is
    // never mounted speculatively here: doing so replaced a fresh "Start session" view
    // with an unrelated desktop transcript several seconds after the chat appeared.
    if (note.userInfo?["reason"] as? String) == "chatChannelStateChanged",
      currentBridgeProvider != nil || groupHasBridgeAgents()
    {
      let changed = (note.userInfo?["chatId"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !chatKey.isEmpty, changed == nil || changed?.isEmpty == true || changed == chatKey {
        requestBridgeUsageSnapshot(reason: "channelJoined")
      }
    }
    // Usage banner plumbing — ahead of the statusAuthority gate (bridge DMs keep
    // statusAuthority OFF; groups with bridge agents also need this path).
    if currentBridgeProvider != nil || groupHasBridgeAgents() {
      let reason = (note.userInfo?["reason"] as? String) ?? ""
      if reason == "agentBridgeUsage" {
        if let requestId = note.userInfo?["requestId"] as? String, !requestId.isEmpty {
          applyBridgeUsageReply(requestId: requestId)
        }
      } else if reason == "agentUsageLimit" {
        let changed = (note.userInfo?["chatId"] as? String)?.trimmingCharacters(
          in: .whitespacesAndNewlines)
        let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chatKey.isEmpty, changed == nil || changed?.isEmpty == true || changed == chatKey {
          let provider = (note.userInfo?["provider"] as? String) ?? ""
          let message = (note.userInfo?["message"] as? String) ?? ""
          handleAgentUsageLimitEvent(provider: provider, message: message)
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
            // Any activity (a result landing, a limit-hit message) refreshes usage;
            // the 30s throttle keeps this quiet during streaming.
            requestBridgeUsageSnapshot(reason: "activity")
          }
          hadLiveBridgeRun = liveNow

          // Bridge DMs often keep statusAuthority OFF. History picks still need the
          // engine overlay to accept `bridge-<sessionId>-…` inserts / edits, or the
          // list stays empty under historical isolation with only the skeleton up.
          if !statusAuthorityEnabled {
            let messageId = normalizedMessageId(note.userInfo?["messageId"])
            let action = (note.userInfo?["action"] as? String)?.trimmingCharacters(
              in: .whitespacesAndNewlines)
            syncNativeEngineMessageMutation(reason: reason, messageId: messageId, action: action)
          }
        }
      } else if reason == "chatRowsReloaded", !statusAuthorityEnabled {
        let changed = (note.userInfo?["chatId"] as? String)?.trimmingCharacters(
          in: .whitespacesAndNewlines)
        let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chatKey.isEmpty, changed == nil || changed?.isEmpty == true || changed == chatKey {
          // already_loaded History re-pick: re-pull engine rows so the session filter
          // can paint without waiting on statusAuthority.
          reapplyRowsAfterBridgeSessionScopeChange()
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
    if reason == "agentProgress" {
      // Run settled (isActive false) → this is the moment a held message may go out.
      // Run started/ticked → keep the task banner fresh even between row updates.
      let isActive = (note.userInfo?["isActive"] as? Bool) ?? false
      if isActive {
        refreshBridgeTaskBanner()
      } else {
        schedulePendingBridgeQueueFlush(reason: "agentProgress-idle")
        refreshBridgeTaskBanner()
      }
    }
    if reason == "chatDelta" {
      applyChatDeltaFromEngine(note.userInfo)
      return
    }
    if reason == "chatMessageInserted"
      || reason == "chatMessageEdited"
      || reason == "chatMessageDeleted"
      || reason == "chatMessageChanged"
    {
      // Pipeline-v2: every engine write now posts a chatDelta (stage A2), which is
      // handled above with ONE coalesced off-main refresh. The legacy per-message
      // path (sync engine-queue fetch per mutation) remains only for the
      // statusAuthority-OFF surfaces handled earlier in this observer.
      return
    }
    if reason == "messageStatusChanged" {
      // Row-dict status changes ride chatDelta (source=status). Receipt-index-only
      // writes post no delta, so keep the cheap visible-cell tick repaint here.
      refreshVisibleStatuses(reason: reason)
      return
    }
    if reason == "chatRowsReloaded" {
      hydrateRowsFromNativeHistoryIfReady(trigger: "chatRowsReloaded")
      return
    }
    refreshVisibleStatuses(reason: reason)
  }

  /// Present a mid-run agent ask / plan-approval sheet from the bubble (chat) surface.
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
    let infoKind = ((info["kind"] as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let surfaceEngaged =
      !(Self.bridgeFreshOwnSentIdsByChat[chatKey] ?? []).isEmpty
      || bridgeLoadedSessionId != nil
      || ChatEngine.shared.liveBridgeSessionId(chatId: chatKey) != nil
    // Command approvals / ask_user requests may arrive before the bridge has captured a
    // CLI session id (or from an interactive desktop hook). With no session scope, dropping
    // a fresh provider DM makes the phone look like it missed the approval entirely. Fail
    // open for these live control sheets; scoped asks still use the session guard below.
    let unscopedLiveControlAsk =
      askSessionIds.isEmpty && (infoKind == "command" || infoKind == "ask")
    guard surfaceEngaged || unscopedLiveControlAsk else {
      NSLog(
        "[ChatListView][ask] DROP — fresh un-engaged surface, ask belongs to a prior conversation requestId=%@ chat=%@ kind=%@",
        requestId, chatId, infoKind)
      return
    }
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
    let resolvedChatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolvedChatId.isEmpty else {
      VibeDebugLog.log("[ChatOpen] hydrate SKIP trigger=%@ reason=noChatId", trigger)
      return
    }

    // ChatConversationController already owns an off-main engine read during its push.
    // Avoid launching duplicate hydration reads from didMoveToWindow/first layout; their
    // results would only coalesce into the same presentation-deferred transcript anyway.
    guard !defersTranscriptUpdatesForPresentation else {
      VibeDebugLog.log(
        "[ChatOpen] hydrate DEFER trigger=%@ chatId=%@ reason=presentation",
        trigger, resolvedChatId)
      return
    }

    // Paint from engine as soon as chatId is known — even while statusAuthority is still
    // deferred during push. Skipping until statusAuthority=true left prevCount=0 for the
    // whole push animation (empty wallpaper flash) on large group transcripts.
    if rows.isEmpty {
      let historyReadyNow = ChatEngine.shared.isChatHistoryLoaded(chatId: resolvedChatId)
      if historyReadyNow || !nativeEngineRowsById.isEmpty {
        VibeDebugLog.log(
          "[ChatOpen] hydrate FAST-PATH trigger=%@ chatId=%@ historyReady=%@ overlay=%d sourceRows=%d statusAuth=%@ — rendering",
          trigger, resolvedChatId, historyReadyNow ? "Y" : "N",
          nativeEngineRowsById.count, sourceRowsPayload.count,
          statusAuthorityEnabled ? "Y" : "N")
        // Prefer engine rows over empty source payload so we don't paint blank.
        if sourceRowsPayload.isEmpty {
          DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let engineRows = ChatEngine.shared.getChatRows(["chatId": resolvedChatId])
            DispatchQueue.main.async {
              guard let self else { return }
              guard self.engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
                == resolvedChatId
              else { return }
              guard self.rows.isEmpty, !engineRows.isEmpty else { return }
              NSLog(
                "[ChatOpen] hydrate engine-seed chat=%@ rows=%d trigger=%@",
                String(resolvedChatId.prefix(12)), engineRows.count, trigger)
              self.setRows(engineRows)
            }
          }
        } else {
          setRows(sourceRowsPayload)
        }
      } else {
        // Warm cache may still be on disk — pull off-main immediately.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
          let engineRows = ChatEngine.shared.getChatRows(["chatId": resolvedChatId])
          DispatchQueue.main.async {
            guard let self else { return }
            guard self.engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
              == resolvedChatId
            else { return }
            guard self.rows.isEmpty, !engineRows.isEmpty else { return }
            NSLog(
              "[ChatOpen] hydrate early-seed chat=%@ rows=%d trigger=%@",
              String(resolvedChatId.prefix(12)), engineRows.count, trigger)
            self.setRows(engineRows)
          }
        }
        VibeDebugLog.log(
          "[ChatOpen] hydrate async-seed kick trigger=%@ chatId=%@ statusAuth=%@",
          trigger, resolvedChatId, statusAuthorityEnabled ? "Y" : "N")
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
          VibeDebugLog.log(
            "[ChatOpen] hydrate async BAIL trigger=%@ chatId=%@ historyLoaded=N overlay=0 rows=%d — chat stays as-is until JS setRows arrives",
            trigger, resolvedChatId, self.rows.count)
          return
        }
        // Never re-apply empty source over an already-painted list (race with early seed).
        if self.sourceRowsPayload.isEmpty, !self.rows.isEmpty {
          NSLog(
            "[ChatOpen] hydrate async KEEP painted rows=%d trigger=%@ chat=%@",
            self.rows.count, trigger, String(resolvedChatId.prefix(12)))
          return
        }
        if self.sourceRowsPayload.isEmpty, self.rows.isEmpty {
          // Last chance: pull engine again on the utility queue result we already have.
          DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let engineRows = ChatEngine.shared.getChatRows(["chatId": resolvedChatId])
            DispatchQueue.main.async {
              guard let self else { return }
              guard self.engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
                == resolvedChatId
              else { return }
              guard self.rows.isEmpty, !engineRows.isEmpty else { return }
              NSLog(
                "[ChatOpen] hydrate async late-seed chat=%@ rows=%d trigger=%@",
                String(resolvedChatId.prefix(12)), engineRows.count, trigger)
              self.setRows(engineRows)
            }
          }
          return
        }
        VibeDebugLog.log(
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
    // Must go through the group-decoration funnel — a bare configure() strips the
    // avatar gutter and makes floating avatars overlap the bubble.
    reconfigureVisibleMessageCells(reason: "refreshVisibleStatuses:\(reason)")
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
    // the cell lays out — same helper as the setRows height-delta check.
    let extras = groupMeasurementExtras(at: indexPath)
    let bubbleHeight =
      usesProgressiveTranscriptSizing
      ? presentationSeedMessageHeight(row, rowWidth: extras.measurementWidth)
      : estimateMessageHeight(row, rowWidth: extras.measurementWidth)
    return CGSize(width: width, height: bubbleHeight + extras.extraTop)
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
    lastScrollDeltaY = offsetY - previousOffsetY
    previousOffsetY = offsetY
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
    // Cached history is demand-loaded. Crossing the prefix threshold only arms a reveal;
    // the actual prepend waits until UIKit has completely released the active gesture.
    updateCachedHistoryPullIndicator(offsetY: offsetY)
    maybeRevealOlderTranscriptRows(offsetY: offsetY)
    // Keep the avatar overlay frame-exact with the cells. The previous next-runloop
    // coalescing made avatars visibly trail a fling and then pop/shift into place.
    // EXCEPT while a rows batch is mid-commit: the collection's layout attributes are
    // transiently inconsistent there (history prepends fire during a fling), and
    // repositioning against them made avatars jump/flicker for a frame. The batch's own
    // completion re-places the avatars against settled attributes.
    // ... and while a tall expand/collapse morph is in flight: its offset anchoring
    // fires didScroll mid-transaction, and placing overlays against the MODEL frames
    // (already final) while cells visually interpolate snapped them ahead of the
    // content. The morph animates them in-transaction and re-places at completion.
    if !isApplyingRowsUpdate, !isTallMorphInFlight {
      updateFloatingSenderAvatars()
    }
    if !isTallMorphInFlight {
      updateTallBubbleGlassToggles(animatedIcons: false)
    }
    // Only user-driven scrolling refreshes/shows the pill. Internal offset adjustments
    // (anchored prepends, keyboard) must not blink it out — the post-scroll linger fade
    // owns hiding now.
    if collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating {
      updateScrollingDatePill(visible: true)
    }
    emitViewport()
    updateJumpToBottomButtonVisibility()
  }

  /// Place outer glass expand/collapse chips OUTSIDE the bubble plate:
  /// them → top-trailing (just past the right edge), me → top-leading (just past the left).
  /// Hosted on the list overlay so UIGlassEffect samples wallpaper, not cell chrome.
  private func updateTallBubbleGlassToggles(animatedIcons: Bool) {
    tallToggleOverlay.frame = bounds
    var seen = Set<String>()
    for case let cell as ChatListCell in collectionView.visibleCells {
      guard let anchor = cell.tallToggleAnchor() else { continue }
      seen.insert(anchor.messageId)
      let bubbleInList = cell.convert(anchor.bubbleFrameInCell, to: self)
      let hit = tallBubbleChevronHitSize
      let gap = tallBubbleToggleSpacing
      // Outside the plate horizontally; top-aligned with the bubble.
      let x = anchor.isMe
        ? bubbleInList.minX - hit - gap
        : bubbleInList.maxX + gap
      let y = bubbleInList.minY
      let frame = CGRect(
        x: pixelAlignedValue(x),
        y: pixelAlignedValue(y),
        width: hit,
        height: hit
      )
      // Skip chips that are fully off-screen (above top or below bottom).
      if frame.maxY < -hit || frame.minY > bounds.height + hit {
        if let existing = tallToggleViewsById.removeValue(forKey: anchor.messageId) {
          existing.removeFromSuperview()
        }
        continue
      }
      let control: ChatTallBubbleGlassToggleView
      if let existing = tallToggleViewsById[anchor.messageId] {
        control = existing
      } else {
        control = ChatTallBubbleGlassToggleView(frame: frame)
        control.onTap = { [weak self] in
          guard let self else { return }
          let id = control.messageId
          guard !id.isEmpty else { return }
          NSLog("[TallToggle] glass tap id=%@", String(id.prefix(24)))
          if self.tallBubbleExpandedRowIds.contains(id) {
            self.tallBubbleExpandedRowIds.remove(id)
          } else {
            self.tallBubbleExpandedRowIds.insert(id)
          }
          self.reloadAgentTurnStateRow(
            messageId: id, reason: "toggleTallBubble", animated: true)
        }
        tallToggleViewsById[anchor.messageId] = control
        tallToggleOverlay.addSubview(control)
      }
      let iconColor = appearance.tallToggleColor(isMe: anchor.isMe)
      control.configure(
        messageId: anchor.messageId,
        collapsed: anchor.collapsed,
        iconColor: iconColor,
        animated: animatedIcons
      )
      if control.frame != frame {
        if animatedIcons {
          control.frame = frame
        } else {
          control.frame = frame
        }
      }
      control.isHidden = false
      control.alpha = 1.0
    }
    // Drop chips for rows that scrolled away or lost tall state.
    for (id, view) in tallToggleViewsById where !seen.contains(id) {
      view.removeFromSuperview()
      tallToggleViewsById.removeValue(forKey: id)
    }
  }

  /// Position one floating avatar per visible incoming sender-run in the reserved gutter.
  /// The avatar bottom-aligns to the run's last message but stays clamped inside the run's
  /// vertical span, so it "follows" the run up/down as you scroll instead of duplicating
  /// per message. Cheap: only touches currently-visible runs.
  ///
  /// `animateShift: true` (data-driven reloads only — never scroll ticks, which must stay
  /// frame-exact) rides an existing avatar to its new spot with a short additive ease
  /// instead of snapping.
  private func updateFloatingSenderAvatars(animateShift _: Bool = false) {
    guard isGroupOrChannel, !rows.isEmpty else {
      if !senderAvatarViews.isEmpty {
        senderAvatarViews.values.forEach { $0.removeFromSuperview() }
        senderAvatarViews.removeAll()
      }
      return
    }
    let avatarPassStartedAt = ProcessInfo.processInfo.systemUptime
    defer {
      let avatarPassMs = Int(
        (ProcessInfo.processInfo.systemUptime - avatarPassStartedAt) * 1000)
      if avatarPassMs >= 8 {
        NSLog("[CellPerf] avatar-pass %dms avatars=%d", avatarPassMs, senderAvatarViews.count)
      }
    }

    let visible = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
    // During a batch-layout handoff UIKit can transiently report zero visible items.
    // Preserve the last valid overlay frame rather than blinking every avatar out for
    // one display turn and recreating it on the next scroll callback.
    guard let firstVisible = visible.first?.item, let lastVisible = visible.last?.item else { return }

    let offsetY = collectionView.contentOffset.y
    let size = Self.groupAvatarSize
    let avatarX = messageHorizontalInset + bubbleSideMargin
    // The floating composer's clearance lives in contentPaddingBottom (flow-layout
    // section inset — part of contentSize), NOT contentInset, so clamping against
    // adjustedContentInset alone pinned tall-run avatars at the physical screen bottom,
    // hidden behind the input bar. Clamp above whichever occludes more, plus a small
    // margin so the avatar reads "sitting above the composer".
    let bottomOcclusion = max(collectionView.adjustedContentInset.bottom, contentPaddingBottom)
    let viewportBottom = offsetY + collectionView.bounds.height - bottomOcclusion - 6.0
    if abs(bottomOcclusion - lastAvatarOcclusionLogged) > 0.5 {
      lastAvatarOcclusionLogged = bottomOcclusion
      NSLog(
        "[AvatarPin] clamp occlusion=%.0f (inset=%.0f padding=%.0f) viewportH=%.0f",
        bottomOcclusion, collectionView.adjustedContentInset.bottom, contentPaddingBottom,
        collectionView.bounds.height)
    }
    var liveRunIds = Set<String>()
    var consumedUpTo = -1

    // Walk visible rows; the first gutter row of each not-yet-consumed run resolves the
    // run's [top, bottom] span and places the run's single avatar.
    var item = firstVisible
    while item <= lastVisible {
      defer { item += 1 }
      guard item > consumedUpTo else { continue }
      let ctx = groupCellContext(at: IndexPath(item: item, section: 0))
      guard ctx.reservesGutter, let key = ctx.senderKey else { continue }

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
      // Find the run's last index by walking DATA forward — it may extend below the
      // viewport (previously a run whose last cell scrolled offscreen simply lost its
      // avatar). Early-exit once the span already reaches a full avatar past the clamp
      // line: the avatar pins at viewportBottom regardless of the true run end.
      var lastIndex = item
      while lastIndex < rows.count - 1 {
        if let attrs = collectionView.layoutAttributesForItem(
          at: IndexPath(item: lastIndex, section: 0)),
          attrs.frame.maxY >= viewportBottom + size
        {
          break
        }
        let next = adjacentGroupMessageRow(from: lastIndex, delta: 1)
        if let next, resolvedSenderKey(next) == key {
          lastIndex += 1
        } else {
          break
        }
      }
      consumedUpTo = lastIndex

      guard
        let lastAttrs = collectionView.layoutAttributesForItem(
          at: IndexPath(item: lastIndex, section: 0)),
        let firstAttrs = collectionView.layoutAttributesForItem(
          at: IndexPath(item: firstIndex, section: 0))
      else { continue }

      let runTop = firstAttrs.frame.minY
      let runBottom = lastAttrs.frame.maxY
      // Bottom-align to the last bubble, but never let the avatar leave the run's span and
      // keep it inside the viewport when the run extends past the screen.
      let desiredBottom = min(runBottom, max(runTop + size, viewportBottom))
      let avatarContentY = max(runTop, min(runBottom, desiredBottom) - size)
      // Anchor the run id to the run's FIRST row (stable while the run grows). It is
      // still just a cache hint — matching below survives any rekey via senderKey +
      // row-key overlap.
      var runRowKeys = Set<String>()
      for i in firstIndex...lastIndex where i < rows.count {
        runRowKeys.insert(rows[i].key)
        if let mid = rows[i].messageId { runRowKeys.insert(mid) }
      }
      let runId = "\(key)#\(rows[firstIndex].messageId ?? rows[firstIndex].key)"
      liveRunIds.insert(runId)

      let avatarView: SenderRunAvatarView
      let targetMidY = avatarContentY - offsetY + size / 2.0
      if let existing = senderAvatarViews[runId] {
        avatarView = existing
      } else if let (oldId, rehomed) = senderAvatarViews.first(where: { id, v in
        !liveRunIds.contains(id) && v.runSenderKey == key
          && !v.runRowKeys.isDisjoint(with: runRowKeys)
      }) {
        // Same run under a new identity (temp→server rekey, first-row change from a
        // history prepend, live-row uid flip): keep the existing view for visual
        // continuity instead of retire+recreate.
        senderAvatarViews.removeValue(forKey: oldId)
        senderAvatarViews[runId] = rehomed
        avatarView = rehomed
        NSLog("[AvatarPin] rehome %@ → %@", oldId, runId)
      } else if let (oldId, rehomed) = senderAvatarViews.first(where: { id, v in
        !liveRunIds.contains(id) && v.runSenderKey == key && !v.isHidden
          && abs(v.frame.midY - targetMidY) <= size
      }) {
        // Positional fallback: a stream→settle swap replaces every row identity in
        // the run (key AND messageId both change), so key overlap can't match — but
        // the settled run lands in the same spot. Same sender + same screen position
        // ⇒ same run.
        senderAvatarViews.removeValue(forKey: oldId)
        senderAvatarViews[runId] = rehomed
        avatarView = rehomed
        NSLog("[AvatarPin] rehomePos %@ → %@", oldId, runId)
      } else {
        if let recycled = senderAvatarReusePool.popLast() {
          avatarView = recycled
        } else {
          avatarView = SenderRunAvatarView()
          senderAvatarOverlay.addSubview(avatarView)
        }
        senderAvatarViews[runId] = avatarView
      }
      avatarView.runSenderKey = key
      avatarView.runRowKeys = runRowKeys
      avatarView.isHidden = false
      let targetFrame = CGRect(
        x: avatarX, y: avatarContentY - offsetY, width: size, height: size)
      avatarView.frame = targetFrame
      // Avatars share the cells' model frame exactly. A separate additive ease made
      // them drift relative to an anchored prepend/stream relayout and look detached.
      avatarView.layer.removeAnimation(forKey: "avatarDataShift")
      let info = ctx.senderKey.flatMap { groupSenderDirectory[$0] }
      avatarView.configure(
        name: info?.name ?? ctx.senderName ?? "",
        avatarUrl: ctx.avatarUrl,
        tint: ctx.senderColor ?? .systemGray,
        provider: ctx.provider)
      // A newly-created overlay view has never participated in a hierarchy layout pass.
      // Resolve its gradient/image/initials frames synchronously so the fallback avatar is
      // present in the same first paint as the seeded message cell.
      avatarView.layoutIfNeeded()
    }

    // Retire avatars whose run scrolled away.
    let retiredRunIds = senderAvatarViews.keys.filter { !liveRunIds.contains($0) }
    for runId in retiredRunIds {
      guard let view = senderAvatarViews.removeValue(forKey: runId) else { continue }
      view.layer.removeAllAnimations()
      view.isHidden = true
      view.runSenderKey = nil
      view.runRowKeys = []
      view.capturedMidY = nil
      if senderAvatarReusePool.count < 12 {
        senderAvatarReusePool.append(view)
      } else {
        view.removeFromSuperview()
      }
    }
  }

  // [GroupCellOverlap] Debug probe for the "messy overlapping Codex cell" report. Logs
  // (via NSLog so it shows in Console) only when two ADJACENT group rows are laid out with
  // overlapping frames — silent otherwise. Captures each row's identity (agent kind / error
  // / notice), assigned frame Y+height, and a text prefix so we can tell whether it's a
  // notice+result pair or a single row that grew without reflow. Remove once fixed.
  private var lastOverlapProbeAt: TimeInterval = 0

  /// After group batch updates (agent settle swaps), verify the CELL layer matches the
  /// data source. The flow layout's frames never overlap by construction, but rapid
  /// multi-agent settles (3 delete+insert swaps in <1s) have left two kinds of debris
  /// that layout probes can't see: an orphaned cell UIKit no longer tracks still painting
  /// stale content in the viewport, and a visible cell whose configured row no longer
  /// matches the row at its index path — both render as "overlapping/duplicated replies".
  /// Silent when everything is consistent.
  private func sweepGroupAgentCellIntegrity(reason: String) {
    guard isGroupOrChannel, !rows.isEmpty else { return }
    var ghosts = 0
    var mismatches = 0
    let visibleRect = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
    for case let cell as ChatListCell in collectionView.subviews {
      guard collectionView.indexPath(for: cell) == nil else { continue }
      // Off-viewport / hidden orphans are UIKit's reuse pool — leave those alone.
      guard !cell.isHidden, cell.alpha > 0.01, cell.frame.intersects(visibleRect) else { continue }
      ghosts += 1
      NSLog(
        "[GroupCellIntegrity] %@ ORPHAN cell key=%@ frame=(%.0f,%.0f %.0fx%.0f) — removing",
        reason, String((cell.row?.key ?? "?").suffix(16)),
        cell.frame.minX, cell.frame.minY, cell.frame.width, cell.frame.height)
      cell.removeFromSuperview()
    }
    for case let cell as ChatListCell in collectionView.visibleCells {
      guard let indexPath = collectionView.indexPath(for: cell), indexPath.item < rows.count
      else { continue }
      let row = rows[indexPath.item]
      guard let cellKey = cell.row?.key, cellKey != row.key else { continue }
      mismatches += 1
      NSLog(
        "[GroupCellIntegrity] %@ MISMATCH item=%d cell=%@ row=%@ — reconfiguring",
        reason, indexPath.item, String(cellKey.suffix(16)), String(row.key.suffix(16)))
      cell.applyAppearance(appearance)
      configureMessageCell(cell, at: indexPath, row: row)
      bindWallpaperBackdrop(to: cell)
    }
    if ghosts > 0 || mismatches > 0 {
      flowLayout.invalidateLayout()
      updateFloatingSenderAvatars()
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

  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    userHasScrolledSinceOpen = true
    if isBottomGlideInFlight {
      // The touch itself already stopped the native scroll animation at the current
      // model offset (it ticks per frame — no presentation-layer readback needed);
      // didEndScrollingAnimation will not fire, so clear the flags here.
      isBottomGlideInFlight = false
      isInternalScrollAdjustment = false
      shouldAutoScroll = false
    }
    // A fresh gesture owns a fresh demand-load latch. The indicator is viewport-pinned
    // and does not change collection insets or the user's content offset.
    pendingHistoryRevealAfterScroll = false
    hideCachedHistoryPullIndicator(animated: false)
    updateScrollingDatePill(visible: true)
  }

  public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate {
      if !flushRowsDeferredUntilScrollSettlesIfNeeded() {
        performPendingHistoryRevealIfNeeded(trigger: "drag-ended")
      }
      runVisibleAutoDownloads()
      flushDeferredAgentStreamingRelayoutIfNeeded()
      scheduleScrollingDatePillLinger()
      settleWallpaperAfterScroll(offsetY: scrollView.contentOffset.y)
      persistViewportState()
    }
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    if !flushRowsDeferredUntilScrollSettlesIfNeeded() {
      performPendingHistoryRevealIfNeeded(trigger: "deceleration-ended")
    }
    runVisibleAutoDownloads()
    flushDeferredAgentStreamingRelayoutIfNeeded()
    scheduleScrollingDatePillLinger()
    settleWallpaperAfterScroll(offsetY: scrollView.contentOffset.y)
    persistViewportState()
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

  /// Transition-time sizing is cache-only when possible and otherwise uses a bounded
  /// plain-text/media estimate. In particular it never asks VibeAgentTurnContentView to
  /// parse progress payloads or run an offscreen Auto Layout pass during navigation.
  private func presentationSeedMessageHeight(_ row: ChatListRow, rowWidth: CGFloat) -> CGFloat {
    if agentSystemDividerText(for: row) != nil {
      return 36.0
    }

    let state = agentTurnBubbleState(for: row)
    if bubbleUsesAgentTurnContent(row) {
      let contentVersion =
        "\(row.plainContent?.count ?? row.text.count).\(row.agentProgressNodes.count)."
        + "\(row.agentProgressNodes.reduce(0) { $0 + $1.label.count }).\(row.isStreamingText)"
      if let cached = agentTurnHeightCache[row.key],
        cached.rowWidth == rowWidth,
        cached.state == state,
        chatListRowContentEqual(cached.row, row),
        cached.contentVersion == contentVersion
      {
        return cached.height
      }
      if let persisted = promotePersistedHeightIfAvailable(
        row, rowWidth: rowWidth, state: state, contentVersion: contentVersion)
      {
        return persisted
      }
    } else if let cached = messageHeightCache[row.key],
      cached.rowWidth == rowWidth,
      cached.state == state,
      chatListRowContentEqual(cached.row, row)
    {
      return cached.height
    } else if let persisted = promotePersistedHeightIfAvailable(
      row, rowWidth: rowWidth, state: state, contentVersion: "")
    {
      return persisted
    }

    switch row.visualKind {
    case .voice:
      return 72.0
    case .videoNote:
      return 220.0
    case .sticker:
      return 184.0
    case .video, .media:
      let mediaWidth = max(1.0, row.mediaWidth ?? 1.0)
      let mediaHeight = max(1.0, row.mediaHeight ?? 0.78)
      let displayWidth = min(286.0, max(160.0, rowWidth * 0.74))
      let aspectHeight = displayWidth * CGFloat(mediaHeight / mediaWidth)
      return min(360.0, max(148.0, aspectHeight))
    case .text:
      // A plain text bubble measures with pure text metrics — the very same
      // NSAttributedString.boundingRect the estimate below would run — so estimating
      // it saves nothing, and the estimate was WRONG: it padded by 32pt where the
      // real bubble pads by bubbleTopPadding + bubbleBottomPadding (15pt) and floored
      // at 48 vs the real 36. That systematic +16pt is what made every send shift
      // twice. On send the batch is ins:1 reload:1 — the new row AND the previously
      // last row (it loses its tail once it stops being last, so it fails
      // chatListRowContentEqual) both miss the height caches, both get sized 16pt too
      // tall, the insert pushes the list by the inflated delta, and then the
      // progressive warmup re-measures exact and yanks it back. Measuring exactly here
      // also seeds messageHeightCache, so hasExactProgressiveHeight is already true and
      // the warmup skips the row entirely — no correction pass, no second movement.
      // Agent turns keep the estimate: theirs is the measurement that genuinely costs
      // (full progress-payload parse + offscreen Auto Layout pass).
      if !bubbleUsesAgentTurnContent(row) {
        let metrics = measureMessageBubbleLayout(
          row: row, rowWidth: rowWidth, agentTurnState: state
        )
        let height = metrics.bubbleHeight + metrics.tallOuterToggleReserve
        messageHeightCache[row.key] = RowHeightCacheEntry(
          row: row, rowWidth: rowWidth, state: state, height: height)
        return height
      }
      let text = (row.plainContent ?? row.text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty { return 52.0 }
      let textWidth = max(120.0, rowWidth - 54.0)
      let measured = (text as NSString).boundingRect(
        with: CGSize(width: textWidth, height: 10_000.0),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: UIFont.systemFont(ofSize: 16.0)],
        context: nil
      ).height
      let characterHeight = CGFloat((text.count + 27) / 28) * 22.0 + 72.0
      let progressHeight = CGFloat(min(4, row.agentProgressNodes.count)) * 28.0
      return min(
        430.0,
        max(86.0, max(measured + 64.0, characterHeight + progressHeight))
      )
    }
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
      // Content-version fingerprint: progress node count + label lengths + text length
      // so settle / history upsert / live ticks never reuse a stale height (overlap).
      let contentVersion =
        "\(row.plainContent?.count ?? row.text.count).\(row.agentProgressNodes.count)."
        + "\(row.agentProgressNodes.reduce(0) { $0 + $1.label.count }).\(row.isStreamingText)"
      if let cached = agentTurnHeightCache[row.key],
        cached.rowWidth == rowWidth,
        cached.state == state,
        chatListRowContentEqual(cached.row, row),
        cached.contentVersion == contentVersion
      {
        return cached.height
      }
      if let persisted = promotePersistedHeightIfAvailable(
        row, rowWidth: rowWidth, state: state, contentVersion: contentVersion)
      {
        return persisted
      }
      let measureStartedAt = ProcessInfo.processInfo.systemUptime
      let metrics = measureMessageBubbleLayout(
        row: row, rowWidth: rowWidth, agentTurnState: state
      )
      let measureMs = Int((ProcessInfo.processInfo.systemUptime - measureStartedAt) * 1000)
      if measureMs >= 8 {
        NSLog(
          "[CellPerf] measure %dms key=%@ nodes=%d chars=%d",
          measureMs, String(row.key.suffix(14)), row.agentProgressNodes.count,
          (row.plainContent ?? row.text).count)
      }
      // Top-corner glass chip is overlay-only (no bottom cell reserve).
      let height = metrics.bubbleHeight + metrics.tallOuterToggleReserve
      agentTurnHeightCache[row.key] = RowHeightCacheEntry(
        row: row, rowWidth: rowWidth, state: state, height: height,
        contentVersion: contentVersion)
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
    if let persisted = promotePersistedHeightIfAvailable(
      row, rowWidth: rowWidth, state: state, contentVersion: "")
    {
      return persisted
    }
    let metrics = measureMessageBubbleLayout(
      row: row, rowWidth: rowWidth, agentTurnState: state
    )
    let height = metrics.bubbleHeight + metrics.tallOuterToggleReserve
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

  private func finishRowsUpdate(historyRevealCompleted: Bool = false) {
    isApplyingRowsUpdate = false
    if historyRevealCompleted {
      completeCachedHistoryReveal()
    }
    // Bridge-run companions driven by row state: the live-task banner, the queued-send
    // strip, and the settle-triggered flush of held messages (covers settles that
    // arrive as row updates rather than agentProgress events).
    refreshBridgeTaskBanner()
    if !pendingBridgeSends.isEmpty {
      refreshPendingBridgeQueueUI(animated: false)
      if !bridgeRunIsLive() {
        schedulePendingBridgeQueueFlush(reason: "rowsSettled")
      }
    }
    guard let queued = pendingRowsPayload else {
      if pendingHistoryRevealAfterScroll,
        !collectionView.isTracking,
        !collectionView.isDragging,
        !collectionView.isDecelerating
      {
        performPendingHistoryRevealIfNeeded(trigger: "rows-settled")
      }
      scheduleProgressiveHeightWarmup()
      return
    }
    let queuedAuthority = pendingRowsAuthority ?? .incremental
    let queuedHistoryRevealPrepend = pendingRowsHistoryRevealPrepend
    pendingRowsPayload = nil
    pendingRowsAuthority = nil
    pendingRowsHistoryRevealPrepend = false
    requestsNextHistoryRevealPrepend = queuedHistoryRevealPrepend
    applyRows(queued, authority: queuedAuthority)
  }

  @discardableResult
  private func flushRowsDeferredUntilScrollSettlesIfNeeded() -> Bool {
    guard !collectionView.isTracking, !collectionView.isDragging,
      !collectionView.isDecelerating,
      let payload = rowsDeferredUntilScrollSettles
    else { return false }

    let authority = rowsDeferredUntilScrollSettlesAuthority ?? .incremental
    let historyPrepend = rowsDeferredUntilScrollSettlesHistoryPrepend
    rowsDeferredUntilScrollSettles = nil
    rowsDeferredUntilScrollSettlesAuthority = nil
    rowsDeferredUntilScrollSettlesHistoryPrepend = false
    requestsNextHistoryRevealPrepend = historyPrepend
    applyRows(payload, authority: authority)
    return true
  }

  private func performInternalScrollAdjustment(_ block: () -> Void) {
    isInternalScrollAdjustment = true
    block()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // A clear pending from a pre-glide adjustment (the jump-to-bottom hop) fires on
      // the runloop AFTER the native glide starts — it must not strip the glide's
      // flag mid-travel; didEndScrollingAnimation / willBeginDragging own it then.
      if !self.isBottomGlideInFlight {
        self.isInternalScrollAdjustment = false
      }
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

  private func rawRowStableIdentity(_ row: [String: Any]) -> String? {
    if let key = row["key"] as? String {
      let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return "key:\(trimmed)" }
    }
    if let messageId = messageId(fromRawRow: row) { return "message:\(messageId)" }
    if let kind = row["kind"] as? String,
      let timestamp = row["timestampMs"] ?? row["timestamp_ms"]
    {
      return "\(kind):\(String(describing: timestamp))"
    }
    return nil
  }


  private func rowsByAttachingReplyPreviews(_ rows: [[String: Any]]) -> [[String: Any]] {
    Self.rowsByResolvingReplyPreviews(rows, peerDisplayName: enginePeerDisplayName)
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

  /// True when an overlay-only row is the CLI transcript's mirror (`bridge-…`, isMe)
  /// of a prompt whose real sent row already exists — in the base rows or in the
  /// optimistic outgoing overlay. Matches the engine's mirror dedup so the view never
  /// re-adds a row the engine deliberately dropped.
  private func overlayRowIsMirroredOwnPrompt(
    _ overlay: [String: Any], overlayId: String, baseRows: [[String: Any]]
  ) -> Bool {
    guard overlayId.hasPrefix("bridge-") else { return false }
    guard let message = overlay["message"] as? [String: Any],
      (message["isMe"] as? Bool) == true
    else { return false }
    let text = ChatEngine.bridgeMirrorComparableText((message["text"] as? String) ?? "")
    guard !text.isEmpty else { return false }
    func rowIsTwin(_ row: [String: Any], id: String?) -> Bool {
      guard let id, !id.hasPrefix("bridge-"), !id.hasPrefix("stream-"),
        let msg = row["message"] as? [String: Any],
        (msg["isMe"] as? Bool) == true
      else { return false }
      let twinText = ((msg["text"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return !twinText.isEmpty && twinText == text
    }
    for row in baseRows where rowIsTwin(row, id: messageId(fromRawRow: row)) { return true }
    for (mid, row) in nativeOutgoingRowsById where rowIsTwin(row, id: mid) { return true }
    return false
  }

  private func mergedRowsPayload(from baseRows: [[String: Any]]) -> [[String: Any]] {
    let effectiveBaseRows: [[String: Any]] = {
      guard statusAuthorityEnabled, !engineChatId.isEmpty else { return baseRows }
      // Delta-driven applies (stage B1) already fetched a fresh engine read off-main;
      // repeating the synchronous fetch below would re-add the main-thread
      // engine-queue hop the delta path exists to remove.
      if nextApplyBaseIsEngineAuthoritative {
        nextApplyBaseIsEngineAuthoritative = false
        return baseRows
      }
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
            VibeDebugLog.log(
              "[FirstMsg] mergedRows base=NATIVE native=%d js=%d outgoing=%d overlay=%d",
              nativeRows.count, baseRows.count, nativeOutgoingOrder.count,
              nativeEngineRowsById.count)
          }
          return nativeRows
        }
        if nativeRows.isEmpty, baseRows.count <= 4 {
          VibeDebugLog.log(
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
        // The engine's merged snapshot dedups a `bridge-…` transcript mirror of the
        // user's OWN prompt against its real sent row. This overlay is fed per-insert
        // straight from the live store, so without the same check here it re-appends
        // exactly the row the engine dropped — the duplicated "my message" bubble.
        if overlayRowIsMirroredOwnPrompt(overlay, overlayId: messageId, baseRows: filteredBase) {
          nativeEngineRowsById.removeValue(forKey: messageId)
          continue
        }
        mergedRows.append(overlay)
        nextEngineOrder.append(messageId)
      }
      nativeEngineOrder = nextEngineOrder
      engineMergedRows = mergedRows
    }

    // If the server has acknowledged an optimistic outgoing row, the authoritative
    // payload must inherit the local row's timestamp before the optimistic copy is
    // removed. Otherwise a missing/rounded server timestamp can move the newest message
    // to the first slot on the next merge.
    var acknowledgedOutgoingIds = Set<String>()
    for messageId in nativeOutgoingOrder {
      guard let optimistic = nativeOutgoingRowsById[messageId],
        let authoritativeIndex = engineMergedRows.firstIndex(where: {
          self.messageId(fromRawRow: $0) == messageId
        })
      else { continue }
      engineMergedRows[authoritativeIndex] = rawRowAdoptingChronology(
        engineMergedRows[authoritativeIndex], from: optimistic)
      nativeOutgoingRowsById.removeValue(forKey: messageId)
      acknowledgedOutgoingIds.insert(messageId)
      VibeDebugLog.log(
        "[ChatOrder] ACK preserve-slot msgId=%@ index=%d",
        String(messageId.prefix(12)), authoritativeIndex)
    }
    if !acknowledgedOutgoingIds.isEmpty {
      nativeOutgoingOrder.removeAll { acknowledgedOutgoingIds.contains($0) }
    }

    guard nativeSendEnabled, !nativeOutgoingOrder.isEmpty else {
      return rowsByAttachingReplyPreviews(rowsInCanonicalMessageOrder(engineMergedRows))
    }

    var baseMessageIds = Set<String>()
    for row in engineMergedRows {
      if let messageId = messageId(fromRawRow: row) {
        baseMessageIds.insert(messageId)
      }
    }

    // Remove missing optimistic bookkeeping, but never discard an optimistic slot merely
    // because a partial base snapshot mentions the id. The acknowledged path above only
    // retires it once the corresponding row actually exists in the final merged list.
    var nextOrder: [String] = []
    for messageId in nativeOutgoingOrder {
      if nativeOutgoingRowsById[messageId] == nil {
        continue
      }
      nextOrder.append(messageId)
    }
    nativeOutgoingOrder = nextOrder

    guard !nativeOutgoingOrder.isEmpty else {
      return rowsByAttachingReplyPreviews(rowsInCanonicalMessageOrder(engineMergedRows))
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
      rowsInCanonicalMessageOrder(merged),
      nativeOutgoingIds: Set(nativeOutgoingOrder)
    )
    return rowsByAttachingReplyPreviews(shapedRows)
  }

  private func rawRowAdoptingChronology(_ row: [String: Any], from slotRow: [String: Any])
    -> [String: Any]
  {
    guard var message = row["message"] as? [String: Any],
      let slotMessage = slotRow["message"] as? [String: Any]
    else { return row }
    let timestamp = slotMessage["timestampMs"] ?? slotMessage["timestamp_ms"]
    guard let timestamp else { return row }
    message["timestampMs"] = timestamp
    message["timestamp_ms"] = timestamp
    var result = row
    result["message"] = message
    return result
  }

  /// Engine overlays arrive in mutation order, which is not timeline order. Reorder only
  /// message slots that carry a real timestamp; untimestamped/system rows remain exactly
  /// where their producer placed them. Equal timestamps retain their existing order.
  private func rowsInCanonicalMessageOrder(_ rawRows: [[String: Any]]) -> [[String: Any]] {
    var dated: [(slot: Int, row: [String: Any], timestamp: TimeInterval)] = []
    for (slot, row) in rawRows.enumerated() {
      guard messageId(fromRawRow: row) != nil,
        let date = Self.rawMessageDate(from: row)
      else { continue }
      dated.append((slot, row, date.timeIntervalSince1970))
    }
    guard dated.count > 1 else { return rawRows }
    let sorted = dated.enumerated().sorted { lhs, rhs in
      if lhs.element.timestamp == rhs.element.timestamp {
        return lhs.offset < rhs.offset
      }
      return lhs.element.timestamp < rhs.element.timestamp
    }.map(\.element.row)
    var result = rawRows
    for (index, item) in dated.enumerated() {
      result[item.slot] = sorted[index]
    }
    return result
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

  /// Pipeline-v2 stage B1: apply an engine `chatDelta`. The engine is authoritative
  /// for every id in the delta, so stale overlay copies are dropped (the overlay
  /// drains as deltas flow and remains only for statusAuthority-OFF surfaces), and
  /// the transcript refreshes from ONE coalesced, off-main engine read — the
  /// existing apply pipeline (parse reuse + render-aware equality) then repaints
  /// only rows whose rendered content actually changed.
  private func applyChatDeltaFromEngine(_ userInfo: [AnyHashable: Any]?) {
    let inserted = (userInfo?["insertedIds"] as? [String]) ?? []
    let updated = (userInfo?["updatedIds"] as? [String]) ?? []
    let deleted = (userInfo?["deletedIds"] as? [String]) ?? []
    guard !inserted.isEmpty || !updated.isEmpty || !deleted.isEmpty else { return }
    for id in inserted { nativeEngineRowsById.removeValue(forKey: id) }
    for id in updated { nativeEngineRowsById.removeValue(forKey: id) }
    for id in deleted {
      nativeEngineRowsById.removeValue(forKey: id)
      nativeDeletedMessageIds.insert(id)
    }
    let source = (userInfo?["source"] as? String) ?? ""
    if source == "stream" {
      scheduleDeltaCoalescedEngineRefresh()
    } else {
      refreshRowsFromEngineDelta()
    }
  }

  private func refreshRowsFromEngineDelta() {
    guard !engineDeltaRefreshInFlight else {
      engineDeltaRefreshPending = true
      return
    }
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return }
    engineDeltaRefreshInFlight = true
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let rows = ChatEngine.shared.getChatRows(["chatId": chatId])
      DispatchQueue.main.async {
        guard let self else { return }
        self.engineDeltaRefreshInFlight = false
        defer {
          if self.engineDeltaRefreshPending {
            self.engineDeltaRefreshPending = false
            self.refreshRowsFromEngineDelta()
          }
        }
        guard self.engineChatId.trimmingCharacters(in: .whitespacesAndNewlines) == chatId,
          !rows.isEmpty
        else { return }
        // These rows ARE a fresh engine read; mergedRowsPayload must not repeat the
        // synchronous main-thread fetch it does for stale-source applies.
        self.nextApplyBaseIsEngineAuthoritative = true
        self.setRows(rows)
      }
    }
  }

  /// Stream ticks arrive many times per second; coalesce their refreshes to the same
  /// ~20fps cadence the legacy path used, always ending on a trailing refresh.
  private func scheduleDeltaCoalescedEngineRefresh() {
    guard deltaStreamCoalesceWorkItem == nil else { return }
    let now = CACurrentMediaTime()
    if now - lastDeltaStreamApplyAt >= Self.streamSyncMinInterval {
      lastDeltaStreamApplyAt = now
      refreshRowsFromEngineDelta()
      return
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.deltaStreamCoalesceWorkItem = nil
      self.lastDeltaStreamApplyAt = CACurrentMediaTime()
      self.refreshRowsFromEngineDelta()
    }
    deltaStreamCoalesceWorkItem = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.streamSyncMinInterval, execute: work)
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

  // ~16–20 fps for live stream ticks. 120ms felt laggy on Grok (sub-second CLI)
  // while still batching enough to avoid main-thread thrash on multi-agent groups.
  private static let streamSyncMinInterval: CFTimeInterval = 0.05
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

    // Sealed bridge image attachments must surface as media so the list shows a
    // thumbnail immediately (type "text" alone renders as an empty-looking bubble).
    let bridgeImageBlobs: [String] = {
      let a = (metadata["agentBridgeAttachmentsEnc"] as? [String]) ?? []
      let b = (metadata["attachmentsEnc"] as? [String]) ?? []
      return (a + b).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }()
    let hasBridgeImages = !bridgeImageBlobs.isEmpty
    let messageType = hasBridgeImages ? "image" : "text"

    var message: [String: Any] = [
      "id": messageId,
      "text": text,
      "timestamp": timestamp,
      "timestampMs": timestampMs,
      "isMe": true,
      "status": "pending",
      "type": messageType,
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
    // No fake seed progress — a tiny constant looked like a frozen ring. Until real
    // byte progress arrives the cell shows an indeterminate Settings-style spinner.
    var metadata: [String: Any] = [
      "mediaUrl": localUri,
      "localMediaUrl": localUri,
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
      VibeDebugLog.log(
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
        self.configureMessageCell(cell, at: indexPath, row: row, hiddenMessageId: nil)
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
        configureMessageCell(cell, at: indexPath, row: row, hiddenMessageId: nil)
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
      VibeDebugLog.log(
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
        VibeDebugLog.log(
          "[FirstMsg] reveal SWEEP un-ghosting stale visible cell msgId=%@",
          String(revealedMessageId.prefix(12)))
        guard let row = cell.row,
          let indexPath = collectionView.indexPath(for: cell),
          indexPath.item < rows.count
        else { continue }
        cell.applyAppearance(appearance)
        configureMessageCell(cell, at: indexPath, row: row, hiddenMessageId: nil)
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
    // Re-rendering a full-screen wallpaper snapshot for each gradient phase bucket
    // costs a fling frame. Freeze the decorative phase while UIKit owns momentum and
    // settle it once afterward; bubble backdrop crops still track continuously.
    if !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating {
      applyWallpaperScrollPhase(offsetY: offsetY)
    }

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

  private func settleWallpaperAfterScroll(offsetY: CGFloat) {
    applyWallpaperScrollPhase(offsetY: offsetY)
    refreshWallpaperSnapshotIfNeeded()
    updateVisibleWallpaperBackdropLayouts()
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
    let hasSnap =
      wallpaperSnapshot != nil
      && wallpaperSnapshotSize.width > 1.0
      && wallpaperSnapshotSize.height > 1.0
    // Scroll rebinds every frame — only log when the snap presence flips for this cell.
    if chatListBubbleFlickerDebugLogs, isGroupOrChannel {
      let rowId = cell.bubbleView.debugRowId
      let prevHas = cell.bubbleView.wallpaperSnapshot != nil
      if prevHas != hasSnap {
        NSLog(
          "[BubbleFlicker] list.bindWallpaper id=%@ snap %@->%@ size=%.0fx%.0f",
          rowId.isEmpty ? "—" : rowId,
          prevHas ? "Y" : "N",
          hasSnap ? "Y" : "N",
          wallpaperSnapshotSize.width,
          wallpaperSnapshotSize.height
        )
      }
    }
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
    ChatWallpaperMaskStore.image(
      forKey: key,
      bundles: [Bundle.main, Bundle(for: ChatListView.self)]
    )
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
      let useAgentComposer = false
      if useAgentComposer {
        let bar = VibeComposerView()
        bar.placeholder = inputBarPlaceholder
        bar.applyAppearance(appearance.isDark ? VibeAgentKitChatAppearance.fallback : VibeAgentKitChatAppearance.lightFallback)
        bar.provider = currentBridgeProvider ?? "codex"
        bar.onSend = { [weak self] text, options in
            self?.inputBarDidSend(text: text, attachments: [], imageLocalURIs: [])
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
        bar.provider = currentBridgeProvider
        bar.placeholder = inputBarPlaceholder
        bar.applyAppearance(appearance)
        // Seed STOP immediately if a run is already live (re-open mid-stream, group fan-out).
        bar.setAgentStreaming(agentComposerHasLiveTask())
        // Vibe AI, Claude/Codex DMs, and multi-agent groups want agent-control chrome
        // (repo chip / slash menu / STOP). Normal human DMs don't.
        bar.setAgentControlMode(
          agentChatMode || currentBridgeProvider != nil || groupHasBridgeAgents())
        inputBar = bar
        addSubview(bar)

        agentComposerView?.removeFromSuperview()
        agentComposerView = nil
      }
      updateAgentBridgeControlTitle()
      // Re-sync after title wiring in case group control mode / live rows changed.
      syncComposerStopState()

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
    let hadNativeOutgoingRows = !nativeOutgoingOrder.isEmpty
    nativeSendEnabled = enabled
    if !enabled {
      nativeOutgoingRowsById.removeAll()
      nativeOutgoingOrder.removeAll()
    }
    // This flag only changes whether optimistic outgoing overlays participate in the
    // merge. On chat open there are none, so re-running an empty source payload is both
    // unnecessary and harmful: it clears a restored warm tail while status authority is
    // still deferred, producing the visible 8 -> 0 -> 8 push flicker.
    if hadNativeOutgoingRows {
      setRows(sourceRowsPayload)
    }
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

  /// True when this surface has a live/streaming agent turn — used to force the
  /// composer's trailing control to STOP. Covers Vibe AI, Claude/Codex DMs, and
  /// multi-agent groups. Mirrors the full-page view's `isLive` check.
  private func agentComposerHasLiveTask() -> Bool {
    guard agentChatMode || currentBridgeProvider != nil || groupHasBridgeAgents() else {
      return false
    }
    if agentStreaming && !stopRequestedAgentStream { return true }
    return rows.contains { row in
      guard bridgeRowIsLive(row) else { return false }
      return !stopCancelRequestedKeys.contains(liveBridgeTaskKey(for: row))
    }
  }

  /// Push SEND vs STOP onto whichever composer is mounted (ChatInputBar is the
  /// production path; VibeComposerView is retained for the optional agent glass bar).
  private func syncComposerStopState() {
    let live = agentComposerHasLiveTask()
    inputBar?.setAgentStreaming(live)
    agentComposerView?.setTaskActive(live)
  }

  /// Composer STOP: cancel every live bridge run in this chat (DM or multi-agent
  /// group). Prefer per-row provider/taskId; bridge falls back to the single
  /// running task for chat+provider when taskId is absent.
  private func agentComposerStopActiveTask() {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else {
      NSLog("[ChatListView] agentComposerStop skipped — no chatId")
      return
    }

    let liveRows = rows.filter(bridgeRowIsLive)
    // Record optimistic cancels first so STOP flips off even if the socket is slow.
    for row in liveRows {
      stopCancelRequestedKeys.insert(liveBridgeTaskKey(for: row))
    }
    scheduleStopCancelClearTimeout()
    syncComposerStopState()

    if liveRows.isEmpty {
      // No live row yet (race after send) — still cancel the DM provider if known.
      if let provider = currentBridgeProvider, !provider.isEmpty {
        let payload: [String: Any] = [
          "chatId": chatId,
          "provider": provider,
          "action": "cancel",
        ]
        NSLog("[ChatListView] agentComposerStop chat=%@ provider=%@ taskId=nil (no live row)", chatId, provider)
        _ = ChatEngine.shared.sendAgentBridgeControl(payload)
      }
      return
    }

    // Dedupe by teamRunId (one team cancel) and by provider+taskId for solo runs.
    var cancelledTeamRuns = Set<String>()
    var cancelledProviderTasks = Set<String>()
    for row in liveRows {
      let runtime = row.agentRuntime
      if let teamRunId = runtime?.teamRunId?.trimmingCharacters(in: .whitespacesAndNewlines),
        !teamRunId.isEmpty
      {
        if cancelledTeamRuns.insert(teamRunId).inserted {
          var payload: [String: Any] = [
            "chatId": chatId,
            "action": "cancel",
            "teamRunId": teamRunId,
          ]
          if let provider = runtime?.provider ?? currentBridgeProvider, !provider.isEmpty {
            payload["provider"] = provider
          }
          if let taskId = runtime?.taskId, !taskId.isEmpty { payload["taskId"] = taskId }
          NSLog(
            "[ChatListView] agentComposerStop team chat=%@ teamRunId=%@ provider=%@",
            chatId, teamRunId, (payload["provider"] as? String) ?? "-")
          _ = ChatEngine.shared.sendAgentBridgeControl(payload)
        }
        continue
      }

      let provider =
        (runtime?.provider ?? currentBridgeProvider ?? row.agentUsername ?? "codex")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      guard !provider.isEmpty else { continue }
      let taskId = runtime?.taskId?.trimmingCharacters(in: .whitespacesAndNewlines)
      let dedupe = "\(provider)|\(taskId ?? "")"
      guard cancelledProviderTasks.insert(dedupe).inserted else { continue }
      var payload: [String: Any] = [
        "chatId": chatId,
        "provider": provider,
        "action": "cancel",
      ]
      if let taskId, !taskId.isEmpty { payload["taskId"] = taskId }
      NSLog(
        "[ChatListView] agentComposerStop chat=%@ provider=%@ taskId=%@",
        chatId, provider, taskId ?? "nil")
      _ = ChatEngine.shared.sendAgentBridgeControl(payload)
    }
  }

  /// If cancel never settles (bridge offline), re-show STOP after a grace window
  /// so the user can try again instead of being stuck without a control.
  private func scheduleStopCancelClearTimeout() {
    stopCancelClearWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.stopCancelClearWorkItem = nil
      // Only clear keys that are still live — settled ones already pruned.
      if !self.stopCancelRequestedKeys.isEmpty || self.stopRequestedAgentStream {
        NSLog(
          "[ChatListView] stopCancel grace expired — re-evaluating STOP (keys=%d agentStream=%@)",
          self.stopCancelRequestedKeys.count,
          self.stopRequestedAgentStream ? "Y" : "N")
        self.stopCancelRequestedKeys.removeAll()
        self.stopRequestedAgentStream = false
        self.syncComposerStopState()
      }
    }
    stopCancelClearWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: work)
  }

  func setAgentStreaming(_ streaming: Bool) {
    guard agentStreaming != streaming else {
      // Still re-sync in case bridge rows flipped without the transport flag changing.
      syncComposerStopState()
      return
    }
    agentStreaming = streaming
    if !streaming {
      stopRequestedAgentStream = false
    }
    syncComposerStopState()
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
    // The hosted hit area is 44pt; SwiftUI keeps the visible glass at a compact 36pt.
    let buttonW: CGFloat = 44.0
    let buttonH: CGFloat = 44.0
    let buttonX = max(8.0, bounds.width - safeAreaInsets.right - buttonW - 8.0)
    let buttonY = (activeBarFrame != .zero ? activeBarFrame.minY : bounds.height) - buttonH - 8.0
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
    let repository = AgentBridgeSelectionStore.selectedRepository(
      chatId: engineChatId.isEmpty ? nil : engineChatId
    )

    // Repo + work mode are provider-agnostic and apply to whichever worker runs. A
    // missing per-chat repo must not suppress the provider/resume metadata: history
    // follow-ups should still dispatch, and the bridge can fall back to its default cwd.
    var metadata: [String: Any] = [
      "agentBridgeWorkMode": AgentBridgeSelectionStore.selectedWorkMode().rawValue
    ]
    if let repository {
      metadata["agentBridgeRepoId"] = repository.id
      metadata["agentBridgeRepoName"] = repository.name
      metadata["agentBridgeRepoPath"] = repository.path
      metadata["agentBridgeCwd"] = repository.cwd
      if let computerId = repository.computerId, !computerId.isEmpty {
        metadata["agentBridgeComputerId"] = computerId
      }
      if let computerLabel = repository.computerLabel, !computerLabel.isEmpty {
        metadata["agentBridgeComputerLabel"] = computerLabel
      }
    } else {
      NSLog(
        "[AgentRoute] outgoing bridge metadata without repo provider=%@ chat=%@",
        provider ?? "<group>", engineChatId.isEmpty ? "-" : engineChatId)
    }

    guard let provider else {
      // Group fan-out: no single DM provider. Model choices ARE per-provider — ship them
      // as a map the server resolves per worker at dispatch (chat_channel.ex
      // resolve_provider_model). When a History report is open, also attach its session
      // id so follow-ups stay on that conversation (each agent still gets its own run
      // unless the user @mentions a single worker).
      var models: [String: String] = [:]
      var advisors: [String: String] = [:]
      for agentProvider in ["claude", "codex", "grok", "agy"] {
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
      // History-picked report in a multi-agent group: keep the conversation scoped.
      if let resume = bridgeLoadedSessionId ?? activeBridgeSessionId,
        !resume.isEmpty, !resume.hasPrefix("running:")
      {
        metadata["agentBridgeResumeSessionId"] = resume
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
    let engineLiveSessionId = ChatEngine.shared.liveBridgeSessionId(chatId: chatKey)
    if bridgeLoadedSessionId == nil, activeBridgeSessionId == nil, engineLiveSessionId == nil {
      // A speculative current-session load must not land after this fresh send:
      // it would append an old transcript above the user row and make keyboard
      // dismissal look like a jump to the header. A History pick never takes
      // this branch, so its follow-up still resumes the selected session.
      ChatEngine.shared.cancelAutomaticAgentBridgeSessionLoad(chatId: chatKey)
    }
    let resumeSessionId =
      bridgeLoadedSessionId ?? activeBridgeSessionId
      ?? engineLiveSessionId
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
      engineLiveSessionId ?? "-")
    return metadata
  }

  /// True when the current chat is a group that has Claude/Codex as members (their
  /// group-sender entries carry a resolved bridge `provider`). Used so a plain group
  /// message still ships the selected repo to the agents.
  private func groupHasBridgeAgents() -> Bool {
    guard isGroupOrChannel else { return false }
    return groupSenderDirectory.values.contains { $0.provider != nil }
  }

  /// Public read for ChatMainView header controls (history vs call).
  var groupHasBridgeAgentsPublic: Bool { groupHasBridgeAgents() }

  /// Multi-agent group History entry: if one provider, open its history; if several,
  /// let the user pick which agent's reports to browse.
  func presentGroupBridgeHistorySurface() {
    let providers = usageBannerProviders()
    guard !providers.isEmpty else { return }
    if providers.count == 1 {
      presentBridgeHistorySurface(provider: providers[0])
      return
    }
    guard let presenter = topPresentingViewController() else { return }
    let sheet = UIAlertController(
      title: "History",
      message: "Whose conversation history?",
      preferredStyle: .actionSheet
    )
    for provider in providers {
      let title = provider.prefix(1).uppercased() + provider.dropFirst()
      sheet.addAction(
        UIAlertAction(title: title, style: .default) { [weak self] _ in
          self?.presentBridgeHistorySurface(provider: provider)
        })
    }
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let pop = sheet.popoverPresentationController {
      pop.sourceView = presenter.view
      pop.sourceRect = CGRect(
        x: presenter.view.bounds.midX, y: 80, width: 1, height: 1)
    }
    presenter.present(sheet, animated: true)
  }

  private func resolvedBridgeProviderForOutgoing(
    text: String,
    mentionedAgentUsername: String?
  ) -> String? {
    let peer = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if peer == "11111111-1111-1111-1111-111111111111" { return "claude" }
    if peer == "22222222-2222-2222-2222-222222222222" { return "codex" }
    if peer == "33333333-3333-3333-3333-333333333333" { return "grok" }
    if peer == "44444444-4444-4444-4444-444444444444" { return "agy" }

    let mention =
      mentionedAgentUsername?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if mention == "claude" || mention == "codex" || mention == "grok" {
      return mention
    }
    if mention == "agy" || mention == "antigravity" {
      return "agy"
    }

    if text.range(of: "(^|\\s)@claude\\b", options: [.regularExpression, .caseInsensitive]) != nil {
      return "claude"
    }
    if text.range(of: "(^|\\s)@codex\\b", options: [.regularExpression, .caseInsensitive]) != nil {
      return "codex"
    }
    if text.range(of: "(^|\\s)@grok\\b", options: [.regularExpression, .caseInsensitive]) != nil {
      return "grok"
    }
    if text.range(of: "(^|\\s)@(agy|antigravity)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
      return "agy"
    }
    if let currentBridgeProvider {
      return currentBridgeProvider
    }
    return nil
  }

  private var currentBridgeProvider: String? {
    if let explicitBridgeProvider { return explicitBridgeProvider }
    let peerAgent = enginePeerAgentId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if peerAgent == "claude" || peerAgent == "11111111-1111-1111-1111-111111111111" {
      return "claude"
    }
    if peerAgent == "codex" || peerAgent == "22222222-2222-2222-2222-222222222222" {
      return "codex"
    }
    if peerAgent == "grok" || peerAgent == "33333333-3333-3333-3333-333333333333" {
      return "grok"
    }
    if peerAgent == "agy" || peerAgent == "antigravity"
      || peerAgent == "44444444-4444-4444-4444-444444444444"
    {
      return "agy"
    }
    let peer = enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if peer == "11111111-1111-1111-1111-111111111111" { return "claude" }
    if peer == "22222222-2222-2222-2222-222222222222" { return "codex" }
    if peer == "33333333-3333-3333-3333-333333333333" { return "grok" }
    if peer == "44444444-4444-4444-4444-444444444444" { return "agy" }
    return nil
  }

  func setBridgeProvider(_ provider: String) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.setBridgeProvider(provider)
      }
      return
    }
    let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let next = normalized.isEmpty ? nil : normalized
    guard explicitBridgeProvider != next else { return }
    explicitBridgeProvider = next
    VibeDebugLog.log("[AgentRoute] ChatListView setBridgeProvider=%@", next ?? "nil")
    updateAgentBridgeControlTitle()
    inputBar?.setAgentControlMode(
      agentChatMode || currentBridgeProvider != nil || groupHasBridgeAgents())
    scheduleBridgeAgentPresenceRefresh()
    updateBridgeEmptyHistoryPromptVisibility()
  }

  func setAvatarUri(_ value: String?) {
    let next = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard avatarUri != next else { return }
    avatarUri = next
    presentedBridgeAgentVC?.avatarURI = next.isEmpty ? nil : next
  }

  private func updateAgentBridgeControlTitle() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.updateAgentBridgeControlTitle()
      }
      return
    }
    // Bridge-agent DMs (Claude/Codex/Grok) drive the repo chip + agent menu regardless of the
    // legacy `agentChatMode` surface. Groups that include Claude/Codex also need the repo
    // chip so a pick in the group profile (or here) is visible and changeable mid-chat.
    // "Open" is the fallback for the Vibe AI panel.
    let chatScopedRepo =
      AgentBridgeSelectionStore.selectedRepository(
        chatId: engineChatId.isEmpty ? nil : engineChatId
      )
    let repoName = chatScopedRepo?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if let provider = currentBridgeProvider {
      inputBar?.setAgentControlMode(true)
      inputBar?.setAgentControlRepoTitle(repoName)
      inputBar?.setAgentControlMenu(agentControlMenu(provider: provider))
      inputBar?.setSlashCommandMenu(slashCommandMenu(provider: provider))
      return
    }

    if groupHasBridgeAgents() {
      // No single DM provider — repo menu + per-agent usage slash menu (payload sheets).
      let provider = groupSenderDirectory.values.compactMap(\.provider).first ?? "claude"
      inputBar?.setAgentControlMode(true)
      inputBar?.setAgentControlRepoTitle(repoName.isEmpty ? "Repo" : repoName)
      inputBar?.setAgentControlMenu(groupRepositoryMenu(fallbackProvider: provider))
      inputBar?.setSlashCommandMenu(groupUsageSlashMenu())
      return
    }

    inputBar?.setAgentControlMenu(nil)
    inputBar?.setSlashCommandMenu(nil)
    inputBar?.setAgentControlTitle("Open")
  }

  /// Repo-only menu for group chats that have Claude/Codex members. Selecting a
  /// repo stores it under this chat id so the next group send carries the cwd.
  private func groupRepositoryMenu(fallbackProvider: String) -> UIMenu {
    let repos = AgentPairingService.lastStatusSnapshot?.repositories ?? []
    let selectedRepo = AgentBridgeSelectionStore.selectedRepository(
      chatId: engineChatId.isEmpty ? nil : engineChatId
    )
    var children: [UIMenuElement] = repos.map { repo in
      UIAction(
        title: repo.name,
        subtitle: repo.path,
        image: UIImage(systemName: repo.isGitRepository ? "shippingbox" : "folder"),
        state: (repo.id == selectedRepo?.id || repo.cwd == selectedRepo?.cwd) ? .on : .off
      ) { [weak self] _ in
        guard let self else { return }
        AgentBridgeSelectionStore.select(
          repo, chatId: self.engineChatId.isEmpty ? nil : self.engineChatId)
        self.updateAgentBridgeControlTitle()
      }
    }
    children.append(
      UIAction(title: "Browse repositories…", image: UIImage(systemName: "folder.badge.plus")) {
        [weak self] _ in
        self?.onNativeEvent(["type": "openAgentPanel", "provider": fallbackProvider])
      })
    return UIMenu(title: "Repository", children: children)
  }

  /// Build the "/" command menu for the input bar's slash button, grouped Info / Tasks /
  /// Options. Selecting an item drops "/name " into the composer so the user can add args
  /// and send (bridge info commands like /usage are answered in the glass overlay; task
  /// commands run as agent turns). Provider-aware: Codex's desktop-only ones are labelled.
  private func slashCommandMenu(provider: String) -> UIMenu {
    let isCodex = provider.lowercased().contains("codex")
    let isGrok = provider.lowercased().contains("grok")
    let isAgy = provider.lowercased().contains("agy") || provider.lowercased().contains("antigravity")
    // (name, subtitle) — `usage` is special: opens the real bridge usage sheet instead
    // of inserting a /usage chat command.
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
    let grokTasks: [(String, String)] = [
      ("init", "Set up project memory"),
    ]
    let agyTasks: [(String, String)] = [
      ("init", "Set up project memory"),
    ]
    let options: [(String, String)] = [
      ("plan", "Plan mode: research, don't edit"),
      (isCodex ? "fast" : "reasoning", isCodex ? "Faster, lighter responses" : "Adjust thinking depth"),
    ]
    func actions(_ items: [(String, String)]) -> [UIMenuElement] {
      items.map { item in
        UIAction(title: "/\(item.0)", subtitle: item.1) { [weak self] _ in
          guard let self else { return }
          if item.0 == "usage" {
            // Open payload-backed detail (or multi-provider picker in groups).
            self.presentUsageMenuOrSheet(providers: self.usageBannerProviders())
            return
          }
          self.inputBar?.insertSlashCommand(item.0)
        }
      }
    }
    let tasks = isCodex ? codexTasks : (isGrok ? grokTasks : (isAgy ? agyTasks : claudeTasks))
    let infoMenu = UIMenu(title: "Info", options: .displayInline, children: actions(info))
    let taskMenu = UIMenu(
      title: "Tasks", options: .displayInline,
      children: actions(tasks))
    let optionMenu = UIMenu(title: "Options", options: .displayInline, children: actions(options))
    return UIMenu(title: "Slash commands", children: [infoMenu, taskMenu, optionMenu])
  }

  /// Group-with-agents slash menu: Usage opens per-provider detail sheets from payload.
  private func groupUsageSlashMenu() -> UIMenu {
    let providers = usageBannerProviders()
    var children: [UIMenuElement] = []
    if providers.count <= 1 {
      children.append(
        UIAction(
          title: "/usage",
          subtitle: "Subscription limits + token usage",
          image: UIImage(systemName: "gauge.with.dots.needle.bottom.50percent")
        ) { [weak self] _ in
          self?.presentUsageMenuOrSheet(providers: providers)
        })
    } else {
      // One action per agent so the menu itself is the per-provider tab list.
      for provider in providers {
        let title = provider.prefix(1).uppercased() + provider.dropFirst()
        children.append(
          UIAction(
            title: "\(title) usage",
            subtitle: "5h / weekly limits from bridge",
            image: UIImage(systemName: "gauge.with.dots.needle.bottom.50percent")
          ) { [weak self] _ in
            self?.presentUsageSheet(provider: provider)
          })
      }
    }
    return UIMenu(title: "Usage", children: children)
  }

  /// Agent composer menu. Attachments are prepended by `ChatInputBar`; this menu owns
  /// only run configuration controls.
  private func agentControlMenu(provider: String) -> UIMenu {
    let repos = AgentPairingService.lastStatusSnapshot?.repositories ?? []
    let chatId = engineChatId.isEmpty ? nil : engineChatId
    let selectedRepo = AgentBridgeSelectionStore.selectedRepository(chatId: chatId)
    var repoChildren: [UIMenuElement] = repos.map { repo in
      UIAction(
        title: repo.name,
        subtitle: repo.path,
        image: UIImage(systemName: repo.isGitRepository ? "shippingbox" : "folder"),
        state: (repo.id == selectedRepo?.id || repo.cwd == selectedRepo?.cwd) ? .on : .off
      ) { [weak self] _ in
        AgentBridgeSelectionStore.select(repo, chatId: chatId)
        self?.updateAgentBridgeControlTitle()
      }
    }
    repoChildren.append(
      UIAction(title: "Pick repository…", image: UIImage(systemName: "folder.badge.plus")) {
        [weak self] _ in
        self?.onNativeEvent(["type": "openAgentPanel", "provider": provider])
      })
    let repoMenu = UIMenu(
      title: "Repository",
      subtitle: selectedRepo?.name,
      image: UIImage(systemName: "folder"),
      children: repoChildren)

    let selectedModel = AgentBridgeSelectionStore.selectedModel(provider: provider)
    let primaryModels = AgentBridgeSelectionStore.primaryModelChoices(provider: provider)
    let otherModels = AgentBridgeSelectionStore.otherModelChoices(provider: provider)
    var modelChildren: [UIMenuElement] = [
      UIAction(title: "Default", state: selectedModel == nil ? .on : .off) { _ in
        AgentBridgeSelectionStore.setModel(provider: provider, model: nil)
      }
    ]
    modelChildren.append(contentsOf: primaryModels.map { choice in
      UIAction(
        title: choice.title,
        subtitle: choice.subtitle,
        state: selectedModel == choice.value ? .on : .off
      ) { _ in
        AgentBridgeSelectionStore.setModel(provider: provider, model: choice.value)
      }
    })
    if !otherModels.isEmpty {
      let otherChildren = otherModels.map { choice in
        UIAction(
          title: choice.title,
          subtitle: choice.subtitle,
          state: selectedModel == choice.value ? .on : .off
        ) { _ in
          AgentBridgeSelectionStore.setModel(provider: provider, model: choice.value)
        }
      }
      modelChildren.append(UIMenu(title: "Other Models", children: otherChildren))
    }
    let selectedModelTitle =
      AgentBridgeSelectionStore.modelChoices(provider: provider)
      .first(where: { $0.value == selectedModel })?.title ?? "Default"
    let modelMenu = UIMenu(
      title: "Model",
      subtitle: selectedModelTitle,
      image: UIImage(systemName: "cpu"),
      children: modelChildren)

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

    return UIMenu(children: [modelMenu, permissionMenu, repoMenu])
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
    hideBridgeSessionLoadingSpinner()
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
    updateBridgeEmptyHistoryPromptVisibility()
  }

  /// Ingest a picked history session's transcript into THIS chat (keyed
  /// `bridge-<sessionId>-…`), reveal it through the fresh-surface filter, and show a
  /// custom skeleton spinner until its rows land. Public so both the in-chat History
  /// sheet and the App shell title-tap path share one loading UX.
  func loadBridgeSessionIntoChat(provider: String, session: AgentBridgeHistorySession) {
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let sessionId = session.resolvedSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionId.isEmpty, !sessionId.hasPrefix("running:") else {
      // A running task with no session id yet: jump straight to the live agent view.
      let preferredMode =
        agentSurfaceMode(for: AgentBridgeSelectionStore.defaultView(provider: provider)) ?? .transcript
      presentBridgeAgentConversation(provider: provider, surfaceMode: preferredMode)
      presentedBridgeAgentVC?.runModel = session.model
      presentedBridgeAgentVC?.runReasoningEffort = session.reasoningEffort
      return
    }
    // 1) Scope isolation so foreign DM rows drop out.
    // 2) Clear the visible feed immediately so we never leave the previous session
    //    (or "Start session" empty chrome) on screen while the pick loads.
    // 3) Cover with an OVERLAY skeleton (not collectionView.backgroundView — that
    //    sits under the wallpaper and was invisible).
    setBridgeLoadedSessionId(sessionId)
    clearRows()
    showBridgeSessionLoadingSpinner()
    presentedBridgeAgentVC?.isHistoryPicked = true
    presentedBridgeAgentVC?.runModel = session.model
    presentedBridgeAgentVC?.runReasoningEffort = session.reasoningEffort
    presentedBridgeAgentVC?.setTranscriptLoading(true)
    let result = ChatEngine.shared.loadAgentBridgeSessionIntoChat([
      "chatId": chatId,
      "provider": provider,
      "sessionId": sessionId,
      // Seed the header's session title from the picked row; the detail reply
      // re-asserts it once the transcript lands.
      "topic": session.topic,
    ])
    if (result["accepted"] as? Bool) != true {
      hideBridgeSessionLoadingSpinner()
      presentedBridgeAgentVC?.setTranscriptLoading(false)
    } else {
      presentedBridgeAgentVC?.isHistoryPicked = true
      // already_loaded: re-pull engine rows under the new filter; dismiss only once
      // this session's bridge- rows actually paint (not on stale previous rows).
      reapplyRowsAfterBridgeSessionScopeChange()
    }
  }

  /// Explicit load flag — independent of view hierarchy so the header can show
  /// "Loading…" even if the overlay hasn't been laid out yet.
  private var bridgeHistoryLoadInFlight = false
  /// Which overlay is active for the current load (channel skeleton vs DM/group spinner).
  private var bridgeHistoryLoadingUsesSkeleton = false
  /// Channel-only: chat-bubble skeleton over the feed.
  private lazy var bridgeSessionSkeleton = VibeAgentTranscriptSkeletonView()
  /// Direct + group: clean modern arc spinner (Settings/home style).
  private lazy var bridgeSessionModernSpinner = ChatHistoryModernLoadingView()
  private var bridgeSessionSpinnerTimeout: DispatchWorkItem?

  /// Active loading overlay for the current mode (skeleton or modern spinner).
  private var bridgeHistoryLoadingView: UIView {
    bridgeHistoryLoadingUsesSkeleton ? bridgeSessionSkeleton : bridgeSessionModernSpinner
  }

  private func showBridgeSessionLoadingSpinner() {
    bridgeHistoryLoadInFlight = true
    // Channels keep the bubble skeleton; direct + group get a clean centered spinner.
    bridgeHistoryLoadingUsesSkeleton = isChannel
    // Hide the other mode so a channel→DM switch mid-session never stacks both.
    if bridgeHistoryLoadingUsesSkeleton {
      stopModernHistorySpinner()
    } else {
      stopSkeletonHistoryLoader()
    }

    let overlay = bridgeHistoryLoadingView
    if overlay.superview !== self {
      overlay.isUserInteractionEnabled = false
      insertSubview(overlay, aboveSubview: collectionView)
    }
    layoutBridgeSessionLoadingOverlay()

    if bridgeHistoryLoadingUsesSkeleton {
      bridgeSessionSkeleton.applyAppearance(
        VibeAgentKitMap.appearance(for: self.traitCollection),
        userBubbleGradient: appearance.bubbleMeGradient,
        agentBubbleColor: appearance.bubbleThemColor
      )
      bridgeSessionSkeleton.isHidden = false
      bridgeSessionSkeleton.alpha = 1.0
      bridgeSessionSkeleton.startShimmer()
    } else {
      bridgeSessionModernSpinner.applyAppearance(
        isDark: appearance.isDark,
        accent: appearance.bubbleMeGradient.last
          ?? appearance.bubbleMeGradient.first
          ?? UIColor.systemBlue,
        secondaryText: appearance.timeColorThem
      )
      bridgeSessionModernSpinner.isHidden = false
      bridgeSessionModernSpinner.alpha = 1.0
      bridgeSessionModernSpinner.startAnimating()
    }
    bringSubviewToFront(overlay)

    bridgeSessionSpinnerTimeout?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.hideBridgeSessionLoadingSpinner() }
    bridgeSessionSpinnerTimeout = work
    // Longer than the old 8s — Codex history detail on a cold bridge can exceed that.
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
  }

  private func layoutBridgeSessionLoadingOverlay() {
    var frame = collectionView.frame
    if frame.isEmpty { frame = bounds }
    let bottomInset = max(20.0, contentPaddingBottom + collectionView.contentInset.bottom + 8.0)
    if bridgeHistoryLoadingUsesSkeleton, bridgeSessionSkeleton.superview === self {
      bridgeSessionSkeleton.frame = frame
      bridgeSessionSkeleton.contentBottomInset = bottomInset
      bridgeSessionSkeleton.contentTopInset = contentPaddingTop
    }
    if !bridgeHistoryLoadingUsesSkeleton, bridgeSessionModernSpinner.superview === self {
      bridgeSessionModernSpinner.frame = frame
      bridgeSessionModernSpinner.contentTopInset = contentPaddingTop
      bridgeSessionModernSpinner.contentBottomInset = bottomInset
    }
  }

  private func stopSkeletonHistoryLoader() {
    bridgeSessionSkeleton.stopShimmer()
    bridgeSessionSkeleton.isHidden = true
    bridgeSessionSkeleton.alpha = 1.0
  }

  private func stopModernHistorySpinner() {
    bridgeSessionModernSpinner.stopAnimating()
    bridgeSessionModernSpinner.isHidden = true
    bridgeSessionModernSpinner.alpha = 1.0
  }

  private func hideBridgeSessionLoadingSpinner() {
    bridgeSessionSpinnerTimeout?.cancel()
    bridgeSessionSpinnerTimeout = nil
    let wasInFlight = bridgeHistoryLoadInFlight
    bridgeHistoryLoadInFlight = false
    let overlay = bridgeHistoryLoadingView
    let visible = !overlay.isHidden || wasInFlight
    guard visible else { return }
    UIView.animate(withDuration: 0.22, animations: {
      overlay.alpha = 0.0
    }) { _ in
      // A newer pick may have re-shown a loader mid-fade.
      guard !self.bridgeHistoryLoadInFlight else { return }
      self.stopSkeletonHistoryLoader()
      self.stopModernHistorySpinner()
    }
  }

  /// Once a picked session's rows land, drop the loading spinner.
  private func dismissBridgeSpinnerIfSessionLoaded(_ parsed: [ChatListRow]) {
    guard bridgeHistoryLoadInFlight, let sessionId = bridgeLoadedSessionId else { return }
    let prefix = "bridge-\(sessionId)"
    if parsed.contains(where: { ($0.messageId ?? "").hasPrefix(prefix) }) {
      hideBridgeSessionLoadingSpinner()
      presentedBridgeAgentVC?.setTranscriptLoading(false)
      // Nudge the chat header off "Loading…" onto the session topic.
      NotificationCenter.default.post(
        name: ChatEngine.didChangeNotification,
        object: nil,
        userInfo: ["reason": "bridgeSessionRowsVisible", "chatId": engineChatId]
      )
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
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.handleAgentBridgeSelectionChanged(notification)
      }
      return
    }
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
    agentBridgeAttachmentsEnc: [String] = [],
    imageLocalURIs: [String] = []
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
      "[ChatListView] handleNativeSend START — messageId: %@, text length: %lu, nativeSendEnabled: %@, replyTo: %@ images=%d blobs=%d",
      messageId, text.count, nativeSendEnabled ? "true" : "false", replyToMessageId ?? "nil",
      imageLocalURIs.count, attachmentBlobs.count)

    // Prefer staged local file URIs (written when the user picked photos). Fall back to
    // re-materializing sealed blobs. NEVER stay on a text-only path when images exist.
    let stagedURIs = imageLocalURIs
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if !stagedURIs.isEmpty || !attachmentBlobs.isEmpty {
      let localURIs: [String] = {
        if !stagedURIs.isEmpty { return stagedURIs }
        return materializeSealedAttachmentBlobsToLocalURIs(attachmentBlobs)
      }()
      if !localURIs.isEmpty {
        inputBar?.dismissReplyBanner(animated: false)
        inputBar?.clearText()
        handleNativeAttachmentSend(
          uris: localURIs,
          caption: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text,
          transitionCapture: nil
        )
        return
      }
    }

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

    // On every bridge/group-agent send, refresh usage so a near-limit banner can
    // animate in without waiting for a finished run (and hard limits surface immediately).
    if currentBridgeProvider != nil || groupHasBridgeAgents() {
      requestBridgeUsageSnapshot(reason: "send")
    }

    // Bridge DM OR multi-agent group with sealed image blobs: skip the chat-view
    // send morph. Morph captures text only and hides the cell until complete — that
    // drops image previews in groups and agent DMs. Dispatch directly so the
    // optimistic media row stays visible.
    let hasAttachmentBlobs = !attachmentBlobs.isEmpty
    let isGroupAgentSurface = groupHasBridgeAgents()
    if (currentBridgeProvider != nil || (isGroupAgentSurface && hasAttachmentBlobs))
      && !fromAgentSurface
    {
      inputBar?.dismissReplyBanner(animated: false)
      inputBar?.clearText()
      // A LIVE run owns the CLI right now: dispatching would spawn a second concurrent
      // run (or be dropped by the daemon's duplicate guard) and its mirrored prompt
      // rows corrupt the visible thread. Hold the message in the pending queue instead:
      // it shows as a "waiting" preview above the input (cancel ✕ / Steer ⚡) and
      // auto-sends the moment the current run settles. Edited-resends keep their
      // truncate semantics and never queue.
      if currentBridgeProvider != nil, editingAgentMessageId == nil, bridgeRunIsLive() {
        enqueuePendingBridgeSend(
          messageId: messageId,
          text: text,
          replyToMessageId: replyToMessageId,
          bridgeMetadata: bridgeMetadata,
          agentMention: agentMention,
          agentText: agentText,
          mentionedAgentUsername: mentionedAgentUsername
        )
        return
      }
      // Inline bridge DM / group-agent image send: no morph, no hidden cell.
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

    // Multi-agent group text send (no attachments): also skip morph when the
    // fan-out metadata is present so agent-bound messages don't hide mid-flight.
    if isGroupAgentSurface && !fromAgentSurface && !bridgeMetadata.isEmpty {
      inputBar?.dismissReplyBanner(animated: false)
      inputBar?.clearText()
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
      // Bridge-agent conversations are chronological chat timelines. Pinning a new
      // question to the top made it appear before the earlier conversation instead of
      // after it, and could hide the sender's context while the response streamed.
      pendingAgentPushToTop = false
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
      let hasBridgeImageAttachments: Bool = {
        let a = (bridgeMetadata["agentBridgeAttachmentsEnc"] as? [String]) ?? []
        let b = (bridgeMetadata["attachmentsEnc"] as? [String]) ?? []
        return !(a + b).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
          .isEmpty
      }()
      // Always queue a local optimistic row when images are attached — including
      // Claude/Codex DMs and multi-agent groups — so the preview never drops while
      // the engine/server round-trip runs. Pre-clean removes it once the engine row lands.
      if !isBridgeSend || hasBridgeImageAttachments {
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
          // Watch agent sends for total silence: a group with agent members or a 1:1
          // bridge DM should never "send and do nothing". If nothing comes back within
          // the window, surface a clear Retry notice. (A hard error already showed its
          // own affordance above, so only arm on a non-error accept.)
          if resolvedStatus != "error", let self {
            let isAgentSurface =
              isBridgeSend || (self.isGroupOrChannel && self.groupHasBridgeAgents())
            if isAgentSurface {
              self.armAgentResponseWatchdog(
                messageId: messageId,
                send: ChatListView.PendingAgentSend(
                  text: text,
                  bridgeMetadata: bridgeMetadata,
                  agentMention: agentMention,
                  agentText: agentText,
                  mentionedAgentUsername: mentionedAgentUsername))
            }
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

  /// Multi-image send. Agent (Claude/Codex) DMs and multi-agent groups get ONE message
  /// carrying every image as a sealed bridge blob (single dispatched task, grid renders
  /// all); normal chats fall back to one media message per image, caption on the last.
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
    if currentBridgeProvider != nil || groupHasBridgeAgents() {
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
    // Agent DMs / multi-agent groups: skip send-morph. Morph hides the cell until
    // complete and was dropping image previews (no reliable media morph target).
    let skipMorphForAgentMedia =
      currentBridgeProvider != nil || groupHasBridgeAgents()
    if !skipMorphForAgentMedia,
      let transitionPayload = makeAttachmentSendTransitionPayload(
        messageId: messageId,
        text: effectiveText,
        timestamp: timestamp,
        transitionCapture: transitionCapture
      )
    {
      hiddenMessageId = messageId
      pendingSendTransition = transitionPayload
    }

    // Compute a durable thumbnail early so optimistic + profile grids show the image
    // even after sealed blobs are stripped from the server copy.
    let optimisticThumb: String? = {
      if let thumbnailBase64, !thumbnailBase64.isEmpty { return thumbnailBase64 }
      guard type == "image",
        let fileURL = localAttachmentFileURL(for: uri),
        let image = UIImage(contentsOfFile: fileURL.path),
        let jpeg = image.jpegData(compressionQuality: 0.45)
      else { return nil }
      return jpeg.base64EncodedString()
    }()

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
      thumbnailBase64: optimisticThumb,
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
    // Durable preview for history/profile: server keeps thumbnailBase64 (blobs are stripped).
    if let optimisticThumb, !optimisticThumb.isEmpty {
      metadata["thumbnailBase64"] = optimisticThumb
    }
    if !effectiveText.isEmpty {
      metadata["caption"] = effectiveText
    }

    // Bridge-agent DM / multi-agent group: a plain media message never reaches the agent —
    // the daemon only sees a task when the message carries the bridge run metadata +
    // sealed attachment blobs. Seal every picked image (arte1, same format as the runtime
    // composer) into ONE message and fold in the provider/repo/run metadata so this send
    // dispatches a task carrying the whole set. The server requires non-empty dispatch
    // text, so an image-only send gets a default caption.
    var bridgeImageBody = effectiveText
    let shouldSealForAgents =
      type == "image" && (currentBridgeProvider != nil || groupHasBridgeAgents())
    if shouldSealForAgents {
      let allURIs = [uri] + extraImageURIs
      let blobs = allURIs.compactMap { sealedBridgeImageBlob(forLocalURI: $0) }
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
        }
        // Always stamp sealed blobs even when group metadata is repo-only (no provider key).
        metadata["agentBridgeAttachmentsEnc"] = blobs
        metadata["attachmentsEnc"] = blobs
        // Durable multi-image thumbs (server strips sealed blobs; these stay in metadata).
        let thumbs = allURIs.compactMap { raw -> String? in
          guard let fileURL = localAttachmentFileURL(for: raw),
            let image = UIImage(contentsOfFile: fileURL.path),
            let jpeg = image.jpegData(compressionQuality: 0.4)
          else { return nil }
          return jpeg.base64EncodedString()
        }
        if !thumbs.isEmpty {
          metadata["attachmentThumbnailsB64"] = thumbs
          if metadata["thumbnailBase64"] == nil {
            metadata["thumbnailBase64"] = thumbs[0]
          }
        }
        noteBridgeFreshOwnSentId(messageId)
      }
    }
    // Do NOT removeNativeOutgoingMessage here — that was dropping the image preview
    // mid-send for Claude/Codex and agent groups. Pre-clean in mergedRows swaps when
    // the engine row lands with the same messageId.
    let isBridgeMediaSend =
      currentBridgeProvider != nil
      || ((metadata["agentBridgeProvider"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
      || (groupHasBridgeAgents()
        && ((metadata["agentBridgeAttachmentsEnc"] as? [String])?.isEmpty == false))

    // Stamp sealed blobs onto the already-queued optimistic media row so the list
    // can also render them if the local URI is cleared later.
    if let blobs = metadata["agentBridgeAttachmentsEnc"] as? [String], !blobs.isEmpty,
      var row = nativeOutgoingRowsById[messageId],
      var message = row["message"] as? [String: Any]
    {
      var meta = (message["metadata"] as? [String: Any]) ?? [:]
      meta["agentBridgeAttachmentsEnc"] = blobs
      meta["attachmentsEnc"] = blobs
      for (k, v) in metadata {
        if meta[k] == nil { meta[k] = v }
      }
      message["metadata"] = meta
      message["type"] = type
      row["message"] = message
      nativeOutgoingRowsById[messageId] = row
      setRows(sourceRowsPayload)
    }

    // Put mediaUrl at the TOP level too — ChatEngine + server read it for upload/persist.
    var sendPayload: [String: Any] = [
      "chatId": chatId,
      "messageId": messageId,
      "type": type,
      "text": bridgeImageBody,
      "timestampMs": timestampMs,
      "replyToId": replyToMessageId as Any,
      "metadata": metadata,
      "mediaUrl": uri,
      "myUserId": myUserId,
      "peerUserId": peerUserId,
      "peerAgentId": peerAgentId,
      "isGroup": isGroupOrChannel,
    ]
    if let optimisticThumb, !optimisticThumb.isEmpty {
      sendPayload["thumbnailBase64"] = optimisticThumb
    }
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
  /// True when the in-place agent view was opened manually ("See progress") rather than by
  /// the Default view = Agent setting. A manual view is left alone by unrelated selection
  /// changes; an auto view follows a live flip of the Default-view setting.
  private var bridgeAgentManuallyShown = false
  /// One-shot guard so the legacy pushed "agent view on open" only auto-presents once per
  /// DM (reset when the peer changes). The in-place host path uses an idempotent presence
  /// refresh instead and ignores this flag.
  private var didAutoPresentAgentView = false

  /// Bridge DMs open as fresh sessions. History enters this list only after an explicit
  /// History selection; live chat-owned stream frames still arrive through ChatEngine.
  private func prefetchBridgeHistoryIfNeeded() {
    guard !didPrefetchBridgeHistory else { return }
    didPrefetchBridgeHistory = true
    let chatKey = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    hadLiveBridgeRun =
      !chatKey.isEmpty && ChatEngine.shared.liveBridgeSessionId(chatId: chatKey) != nil
    requestBridgeUsageSnapshot(reason: "open")
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

  /// When the user set this Claude/Codex/Grok profile's default view to an agent surface,
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
    let displayName = AgentBridgeProfile.displayName(for: provider)
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
    vc.runReasoningEffort = agentRow.agentRuntime?.reasoningEffort
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
    // A bridge DM is a persistent Claude/Codex/Grok/Agy conversation, not a
    // one-off task sheet. The first prompt is content and must not replace the
    // agent's navigation title (for example, a raw Codex command in the header).
    if let provider = currentBridgeProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
      !provider.isEmpty
    {
      return provider.capitalized
    }
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

  /// Native full-screen image open (`ChatImageEdit` glass chrome + zoom transition).
  /// Multi-image messages get a **centered** bottom filmstrip of that message's tiles only.
  private func presentNativeImageOpen(
    for row: ChatListRow,
    gridIndex: Int,
    sourceView: UIView?
  ) {
    // Never open the editor while the message context menu is up (or opening):
    // the image hold must yield the menu, not both surfaces stacked.
    guard customContextMenuOverlay == nil else { return }
    guard let presenter = topPresentingViewController() else { return }
    let cell = collectionView.visibleCells.compactMap { $0 as? ChatListCell }
      .first { $0.row?.messageId == row.messageId || $0.row?.key == row.key }

    let pages = buildNativeImagePages(for: row, cell: cell)
    guard !pages.isEmpty else {
      let seed = cell?.mediaImage(atGridIndex: gridIndex) ?? cell?.currentMediaImage()
      let url = resolvedPreferredMediaURL(for: row) ?? row.mediaUrl ?? ""
      guard !url.isEmpty || seed != nil else { return }
      presentImageEditView(
        for: row, mediaURL: url, seedImage: seed, sourceView: sourceView, galleryPages: [],
        startIndex: 0)
      return
    }
    let start = max(0, min(gridIndex, pages.count - 1))
    let primary = pages[start]
    presentImageEditView(
      for: row,
      mediaURL: primary.mediaURL,
      seedImage: primary.image,
      sourceView: sourceView,
      galleryPages: pages,
      startIndex: start
    )
  }

  /// Pages for one message only (not the whole chat). Seeds from visible tiles / blobs / thumbs.
  private func buildNativeImagePages(for row: ChatListRow, cell: ChatListCell?)
    -> [ChatImageEditGalleryPage]
  {
    let multiCount = max(row.agentBridgeAttachmentsEnc.count, row.attachmentThumbnailsB64.count)
    if multiCount > 1 {
      var pages: [ChatImageEditGalleryPage] = []
      for index in 0..<multiCount {
        let seed: UIImage? = {
          if let cellImg = cell?.mediaImage(atGridIndex: index) { return cellImg }
          if index < row.agentBridgeAttachmentsEnc.count {
            return ChatListCell.decodeBridgeGridImagePublic(
              blob: row.agentBridgeAttachmentsEnc[index])
          }
          if index < row.attachmentThumbnailsB64.count {
            return chatMediaImageFromBase64Public(row.attachmentThumbnailsB64[index])
          }
          return nil
        }()
        let url: String = {
          if index == 0 {
            return resolvedPreferredMediaURL(for: row) ?? row.mediaUrl ?? ""
          }
          return ""
        }()
        if seed == nil && url.isEmpty { continue }
        pages.append(ChatImageEditGalleryPage(mediaURL: url, image: seed))
      }
      return pages
    }

    let seed = cell?.currentMediaImage()
      ?? row.agentBridgeAttachmentsEnc.first.flatMap {
        ChatListCell.decodeBridgeGridImagePublic(blob: $0)
      }
      ?? chatMediaImageFromBase64Public(row.thumbnailBase64)
    let url = resolvedPreferredMediaURL(for: row) ?? row.mediaUrl ?? ""
    if url.isEmpty && seed == nil { return [] }
    return [ChatImageEditGalleryPage(mediaURL: url, image: seed)]
  }

  private func presentImageEditView(
    for row: ChatListRow,
    mediaURL: String,
    seedImage: UIImage?,
    sourceView: UIView? = nil,
    galleryPages: [ChatImageEditGalleryPage] = [],
    startIndex: Int = 0
  ) {
    guard let presenter = topPresentingViewController() else { return }
    ChatImageEditModule.presentEditor(
      from: presenter,
      sourceView: sourceView,
      messageId: row.messageId,
      mediaURL: mediaURL,
      initialImage: seedImage,
      initialCaption: row.text,
      headerTitle: resolvedMediaPreviewHeaderTitle(for: row),
      galleryPages: galleryPages,
      startIndex: startIndex
    ) { [weak self] payload in
      guard let self else { return }
      // Reply only arms the banner — no media re-send.
      if payload.eventType == .reply {
        self.showReplyBanner(for: row, fallbackText: "Photo")
        var event: [String: Any] = [
          "type": payload.eventType.rawValue,
          "mediaUrl": payload.mediaURL,
        ]
        if let messageId = payload.messageId { event["messageId"] = messageId }
        self.onNativeEvent(event)
        return
      }

      // Draw/text/crop send MUST go through the durable media path so the edited
      // JPEG is uploaded and shown as a new image bubble (onNativeEvent alone was a no-op).
      let caption = payload.caption
      if let edited = payload.editedImageURL {
        let uri = edited.isFileURL ? edited.absoluteString : edited.path
        self.handleNativeAttachmentSend(
          uris: [uri],
          caption: caption,
          transitionCapture: nil
        )
      } else if payload.eventType == .resend || payload.eventType == .edit
        || payload.eventType == .sendNew
      {
        // No visual edits — re-send original remote/local media if we have a URL.
        let original = payload.mediaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !original.isEmpty {
          self.handleNativeAttachmentSend(
            uris: [original],
            caption: caption,
            transitionCapture: nil
          )
        }
      }

      var event: [String: Any] = [
        "type": payload.eventType.rawValue,
        "mediaUrl": payload.mediaURL,
      ]
      if let messageId = payload.messageId { event["messageId"] = messageId }
      if let caption, !caption.isEmpty { event["caption"] = caption }
      if let editedImageURL = payload.editedImageURL {
        event["editedImageUri"] = editedImageURL.absoluteString
      }
      self.onNativeEvent(event)
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

  func inputBarDidSend(text: String, attachments: [String], imageLocalURIs: [String]) {
    handleNativeSend(
      text: text,
      agentBridgeAttachmentsEnc: attachments,
      imageLocalURIs: imageLocalURIs
    )
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
    let canStop =
      agentChatMode || currentBridgeProvider != nil || groupHasBridgeAgents()
    guard canStop, agentComposerHasLiveTask() || agentStreaming else { return }

    // Bridge / multi-agent group: cancel every live run immediately (SIGTERM on the
    // computer). Do this first so cancel is not gated on the native stream path.
    let hasLiveBridge = rows.contains(where: bridgeRowIsLive)
      || currentBridgeProvider != nil
      || groupHasBridgeAgents()
    if hasLiveBridge && (currentBridgeProvider != nil || groupHasBridgeAgents()) {
      agentComposerStopActiveTask()
    }

    // Native Vibe AI stream (agent chat without a bridge provider).
    if agentChatMode || agentStreaming {
      stopRequestedAgentStream = true
      syncComposerStopState()
      scheduleStopCancelClearTimeout()
      onNativeEvent(["type": "agentStopStreaming"])
    }
  }

  func inputBarDidSendWithAgentMention(
    text: String, agentText: String, attachments: [String], imageLocalURIs: [String]
  ) {
    handleNativeSend(
      text: text,
      agentMention: true,
      agentText: agentText,
      agentBridgeAttachmentsEnc: attachments,
      imageLocalURIs: imageLocalURIs
    )
  }

  func inputBarDidSendWithStandaloneAgentMention(
    text: String,
    agentText: String,
    agentUsername: String,
    attachments: [String],
    imageLocalURIs: [String]
  ) {
    handleNativeSend(
      text: text,
      agentText: agentText,
      mentionedAgentUsername: agentUsername,
      agentBridgeAttachmentsEnc: attachments,
      imageLocalURIs: imageLocalURIs
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

  /// Reverse of sealing: write composer `arte1` blobs to local files so the normal
  /// image upload path can produce a durable `media_url` (survives chat reopen).
  private func materializeSealedAttachmentBlobsToLocalURIs(_ blobs: [String]) -> [String] {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = caches.appendingPathComponent("chat-local-attachments", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var uris: [String] = []
    for (index, blob) in blobs.enumerated() {
      guard let object = AgentRuntimeCrypto.decrypt(blob) else { continue }
      let name =
        (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? "image-\(Int(Date().timeIntervalSince1970 * 1000))-\(index).jpg"
      let data: Data? = {
        if let b64 = (object["dataB64"] as? String)
          ?? (object["data_b64"] as? String)
          ?? (object["base64"] as? String),
          let decoded = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters])
        {
          return decoded
        }
        if let uri = (object["uri"] as? String) ?? (object["url"] as? String)
          ?? (object["path"] as? String)
        {
          let path: String
          if let parsed = URL(string: uri), parsed.isFileURL {
            path = parsed.path
          } else {
            path = uri
          }
          return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        return nil
      }()
      guard let data, !data.isEmpty else { continue }
      let safeName = name.replacingOccurrences(of: "/", with: "_")
      let fileURL = dir.appendingPathComponent(
        "\(UUID().uuidString.lowercased())-\(safeName)")
      do {
        try data.write(to: fileURL, options: .atomic)
        uris.append(fileURL.absoluteString)
      } catch {
        NSLog(
          "[ChatListView] materialize sealed attach failed name=%@ err=%@",
          safeName, error.localizedDescription)
      }
    }
    return uris
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

/// Small cached-history affordance pinned to the chat viewport. The arc fills as the
/// user approaches older cached rows, then rotates while the settled prepend is being
/// measured. It is layer-only and non-interactive so it never competes with scrolling.
private final class CachedHistoryPullIndicatorView: UIView {
  private let plateLayer = CAShapeLayer()
  private let spinHost = CALayer()
  private let trackLayer = CAShapeLayer()
  private let progressLayer = CAShapeLayer()
  private let spinKey = "chat.cachedHistory.spin"
  private var isAnimating = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear

    layer.addSublayer(plateLayer)
    layer.addSublayer(spinHost)
    for ring in [trackLayer, progressLayer] {
      ring.fillColor = UIColor.clear.cgColor
      ring.lineCap = .round
      spinHost.addSublayer(ring)
    }
    trackLayer.strokeStart = 0.0
    trackLayer.strokeEnd = 1.0
    progressLayer.strokeStart = 0.08
    progressLayer.strokeEnd = 0.12
  }

  required init?(coder: NSCoder) { nil }

  func applyAppearance(isDark: Bool, color: UIColor) {
    plateLayer.fillColor = UIColor(
      white: isDark ? 0.08 : 0.98,
      alpha: isDark ? 0.82 : 0.90
    ).cgColor
    plateLayer.strokeColor = color.withAlphaComponent(isDark ? 0.18 : 0.12).cgColor
    trackLayer.strokeColor = color.withAlphaComponent(isDark ? 0.14 : 0.11).cgColor
    progressLayer.strokeColor = color.withAlphaComponent(isDark ? 0.72 : 0.62).cgColor
  }

  func setPullProgress(_ progress: CGFloat) {
    let clamped = max(0.0, min(1.0, progress))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    progressLayer.strokeStart = 0.08
    progressLayer.strokeEnd = 0.12 + (0.68 * clamped)
    spinHost.transform = CATransform3DMakeRotation(clamped * .pi * 1.35, 0.0, 0.0, 1.0)
    CATransaction.commit()
  }

  func startAnimating() {
    guard !isAnimating else { return }
    isAnimating = true
    layoutIfNeeded()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    progressLayer.strokeStart = 0.10
    progressLayer.strokeEnd = 0.68
    spinHost.transform = CATransform3DIdentity
    CATransaction.commit()
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0.0
    spin.toValue = Double.pi * 2.0
    spin.duration = 0.78
    spin.repeatCount = .infinity
    spin.timingFunction = CAMediaTimingFunction(name: .linear)
    spin.isRemovedOnCompletion = false
    spinHost.add(spin, forKey: spinKey)
  }

  func stopAnimating() {
    guard isAnimating || spinHost.animation(forKey: spinKey) != nil else { return }
    isAnimating = false
    spinHost.removeAnimation(forKey: spinKey)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    spinHost.transform = CATransform3DIdentity
    progressLayer.strokeStart = 0.08
    progressLayer.strokeEnd = 0.12
    CATransaction.commit()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let plateRect = bounds.insetBy(dx: 1.0, dy: 1.0)
    plateLayer.frame = bounds
    plateLayer.path = UIBezierPath(ovalIn: plateRect).cgPath
    plateLayer.lineWidth = 1.0 / max(1.0, traitCollection.displayScale)

    let spinnerSide: CGFloat = 19.0
    let lineWidth: CGFloat = 2.1
    spinHost.bounds = CGRect(x: 0.0, y: 0.0, width: spinnerSide, height: spinnerSide)
    spinHost.position = CGPoint(x: bounds.midX, y: bounds.midY)
    let ringRect = spinHost.bounds.insetBy(dx: lineWidth / 2.0, dy: lineWidth / 2.0)
    let path = UIBezierPath(ovalIn: ringRect).cgPath
    for ring in [trackLayer, progressLayer] {
      ring.frame = spinHost.bounds
      ring.path = path
      ring.lineWidth = lineWidth
    }
  }
}

/// Small circular avatar used by the floating group-sender overlay. Shows the member's
/// photo when there is one, otherwise a coloured initials tile in the sender's tint.
final class SenderRunAvatarView: UIView {
  private let imageView = UIImageView()
  private let initialsLabel = UILabel()
  private let gradientLayer = CAGradientLayer()
  private var loadedURL: String?
  private var loadingURL: String?
  private var loadToken = UUID()
  private var configuredName: String?
  private var configuredAvatarURL: String?
  private var configuredProvider: String?
  private var configuredTint: UIColor?

  // Run bookkeeping owned by ChatListView.updateFloatingSenderAvatars: which sender-run
  // this view is glued to, so run identity churn (temp→server rekey, index shift, run
  // growth) re-matches the SAME view by senderKey + row-key overlap instead of
  // retire+recreate (the "avatar catches up seconds after the cells" pop).
  var runSenderKey: String?
  var runRowKeys: Set<String> = []
  // Screen-space midY captured just before an animated batch update; the pass-3 glue
  // consumes it so the avatar rides the same additive shift as its run's cells.
  var capturedMidY: CGFloat?

  // Claude/Codex always have a profile image even when the group members payload omits
  // the avatar URL — resolve it from the provider so agents never fall back to a letter.
  static func agentAvatarURL(for provider: String?) -> String? {
    switch provider {
    case "claude": return "https://media.vibegram.io/chat-media/agent-profiles/claude.png"
    case "codex": return "https://media.vibegram.io/chat-media/agent-profiles/codex.png"
    case "grok": return "https://media.vibegram.io/chat-media/agent-profiles/grok-v2.png"
    case "agy", "antigravity": return "https://media.vibegram.io/chat-media/agent-profiles/agy.png"
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
    let identityUnchanged =
      configuredName == name
      && configuredAvatarURL == trimmedURL
      && configuredProvider == provider
      && (configuredTint?.isEqual(tint) ?? false)
    if identityUnchanged {
      let noImageNeeded = trimmedURL == nil || trimmedURL?.isEmpty == true
      let imageReady = trimmedURL == loadedURL && imageView.image != nil
      let imageLoading = trimmedURL == loadingURL
      if noImageNeeded || imageReady || imageLoading { return }
    }
    configuredName = name
    configuredAvatarURL = trimmedURL
    configuredProvider = provider
    configuredTint = tint
    initialsLabel.text = SenderRunAvatarView.initials(from: name, provider: provider)
    // Home-style gradient behind the initials, seeded from the sender colour.
    let base = SenderRunAvatarView.tileColor(for: tint, provider: provider)
    let (top, bottom) = SenderRunAvatarView.gradientColors(base: base)
    gradientLayer.colors = [top.cgColor, bottom.cgColor]
    backgroundColor = .clear

    guard let url = trimmedURL, !url.isEmpty else {
      loadToken = UUID()
      loadedURL = nil
      loadingURL = nil
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
      loadToken = UUID()
      loadedURL = url
      loadingURL = nil
      imageView.image = cached
      imageView.isHidden = false
      initialsLabel.isHidden = true
      return
    }

    // `configure` runs as the floating avatar follows a scroll. Do not start another
    // identical network/cache task on every frame while the first request is in flight.
    if loadingURL == url {
      return
    }

    // No cached image yet: show the initials tile now, swap in the photo when it lands.
    // [AvatarPop] this branch IS the initials→photo flash: memory AND sync disk seed both
    // missed. Firing repeatedly for the same sender across opens means the disk cache is
    // not retaining (the reported avatar flicker) — name it.
    NSLog(
      "[AvatarPop] cache-miss name=%@ inWindow=%@ url=%@",
      name, window != nil ? "Y" : "N", String(url.suffix(40)))
    imageView.image = nil
    imageView.isHidden = true
    initialsLabel.isHidden = false
    let token = UUID()
    loadToken = token
    loadedURL = nil
    loadingURL = url
    let requestedAt = ProcessInfo.processInfo.systemUptime
    Task { [weak self] in
      let image = await ChatAvatarImageStore.load(from: url)
      await MainActor.run {
        guard let self, self.loadToken == token else { return }
        self.loadingURL = nil
        guard let image else { return }
        if self.window != nil {
          NSLog(
            "[AvatarPop] late name=%@ afterMs=%d",
            self.configuredName ?? "?",
            Int((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000))
        }
        self.loadedURL = url
        self.imageView.image = image
        self.imageView.isHidden = false
        self.initialsLabel.isHidden = true
      }
    }
  }

  private static func tileColor(for tint: UIColor, provider: String?) -> UIColor {
    if provider == "codex" { return UIColor(white: 0.32, alpha: 1.0) }
    if provider == "grok" { return UIColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0) }
    if provider == "agy" || provider == "antigravity" { return UIColor(red: 0.18, green: 0.10, blue: 0.32, alpha: 1.0) }
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

// MARK: - Bridge task banner page

/// One page of the live-task banner: status icon (spinner while running, ✓/✗ when
/// settled), the task's label, and a "Task i of N" position line. Tap opens the
/// step-detail sheet with the task's full command/output.
final class BridgeTaskBannerPageView: UIView {
  var onTap: (() -> Void)?

  private let spinner = UIActivityIndicatorView(style: .medium)
  private let statusIcon = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  init(
    item: VibeAgentKitProgressItem,
    index: Int,
    total: Int,
    appearance: ChatListAppearance
  ) {
    super.init(frame: .zero)
    let isRunning = vibeAgentKitRunningStepStatuses.contains((item.status ?? "").lowercased())
    let isFailed = ["failed", "error", "failure", "cancelled", "canceled"]
      .contains((item.status ?? "").lowercased())

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = appearance.textColorThem.withAlphaComponent(0.6)
    addSubview(spinner)

    statusIcon.translatesAutoresizingMaskIntoConstraints = false
    statusIcon.contentMode = .scaleAspectFit
    addSubview(statusIcon)

    if isRunning {
      spinner.startAnimating()
      statusIcon.isHidden = true
    } else {
      spinner.isHidden = true
      statusIcon.image = UIImage(
        systemName: isFailed ? "xmark.circle.fill" : "checkmark.circle.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold))
      statusIcon.tintColor = isFailed ? .systemRed : .systemGreen
    }

    let kind = (item.itemType ?? item.tool ?? "").lowercased()
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
    titleLabel.textColor = appearance.textColorThem
    titleLabel.lineBreakMode = .byTruncatingTail
    let fallbackTitle: String
    switch kind {
    case "bash": fallbackTitle = "Terminal command"
    case "task": fallbackTitle = "Subagent"
    case "mcp": fallbackTitle = "MCP tool"
    default: fallbackTitle = "Tool"
    }
    let trimmedLabel = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
    titleLabel.text = trimmedLabel.isEmpty ? fallbackTitle : trimmedLabel
    addSubview(titleLabel)

    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    subtitleLabel.font = .systemFont(ofSize: 11.0, weight: .medium)
    subtitleLabel.textColor = appearance.textColorThem.withAlphaComponent(0.5)
    let stateText = isRunning ? "running" : (isFailed ? "failed" : "done")
    subtitleLabel.text =
      total > 1 ? "Task \(index + 1) of \(total) · \(stateText) · tap for result"
      : "\(stateText.capitalized) · tap for result"
    addSubview(subtitleLabel)

    NSLayoutConstraint.activate([
      spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14.0),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
      statusIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14.0),
      statusIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
      statusIcon.widthAnchor.constraint(equalToConstant: 20.0),
      statusIcon.heightAnchor.constraint(equalToConstant: 20.0),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44.0),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8.0),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9.0),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8.0),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2.0),
    ])

    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
  }

  required init?(coder: NSCoder) { return nil }

  @objc private func handleTap() { onTap?() }
}

/// Slim, actionable notice pinned just above the composer when a prompt sent to an
/// agent surface gets no response at all. Warning glyph + one-line reason + a filled
/// Retry pill + a dismiss. Styled from the chat's live appearance so it reads as part
/// of the same surface in light and dark.
final class AgentResponseNoticeView: UIView {
  private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let iconView = UIImageView()
  private let messageLabel = UILabel()
  private let retryButton = UIButton(type: .system)
  private let closeButton = UIButton(type: .system)
  private var accentColor: UIColor = .systemBlue

  var onRetry: (() -> Void)?
  var onClose: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) { return nil }

  func configure(message: String) {
    messageLabel.text = message
    setNeedsLayout()
  }

  func applyColors(isDark: Bool, textColor: UIColor, accent: UIColor) {
    accentColor = accent
    blurView.contentView.backgroundColor =
      (isDark ? UIColor.white : UIColor.black).withAlphaComponent(isDark ? 0.07 : 0.05)
    layer.borderColor = UIColor.systemOrange.withAlphaComponent(isDark ? 0.5 : 0.4).cgColor
    iconView.tintColor = .systemOrange
    messageLabel.textColor = textColor.withAlphaComponent(0.92)
    closeButton.tintColor = textColor.withAlphaComponent(0.6)
    applyRetryConfiguration()
  }

  private func applyRetryConfiguration() {
    var cfg = UIButton.Configuration.filled()
    cfg.baseBackgroundColor = accentColor
    cfg.baseForegroundColor = .white
    cfg.cornerStyle = .capsule
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 15, bottom: 6, trailing: 15)
    var title = AttributedString("Retry")
    title.font = .systemFont(ofSize: 13.0, weight: .semibold)
    cfg.attributedTitle = title
    retryButton.configuration = cfg
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerRadius = 16.0
    layer.cornerCurve = .continuous
    layer.borderWidth = 0.8

    blurView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blurView)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.image = UIImage(
      systemName: "exclamationmark.triangle.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .semibold))
    iconView.contentMode = .scaleAspectFit
    iconView.setContentHuggingPriority(.required, for: .horizontal)
    blurView.contentView.addSubview(iconView)

    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    messageLabel.font = .systemFont(ofSize: 13.0, weight: .medium)
    messageLabel.numberOfLines = 2
    blurView.contentView.addSubview(messageLabel)

    retryButton.translatesAutoresizingMaskIntoConstraints = false
    retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
    retryButton.setContentHuggingPriority(.required, for: .horizontal)
    retryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    blurView.contentView.addSubview(retryButton)

    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.setImage(
      UIImage(
        systemName: "xmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 11.0, weight: .semibold)),
      for: .normal)
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    closeButton.setContentHuggingPriority(.required, for: .horizontal)
    blurView.contentView.addSubview(closeButton)

    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

      iconView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 14.0),
      iconView.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 18.0),
      iconView.heightAnchor.constraint(equalToConstant: 18.0),

      messageLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10.0),
      messageLabel.topAnchor.constraint(
        equalTo: blurView.contentView.topAnchor, constant: 9.0),
      messageLabel.bottomAnchor.constraint(
        equalTo: blurView.contentView.bottomAnchor, constant: -9.0),
      messageLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: retryButton.leadingAnchor, constant: -10.0),

      retryButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4.0),
      retryButton.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),

      closeButton.trailingAnchor.constraint(
        equalTo: blurView.contentView.trailingAnchor, constant: -8.0),
      closeButton.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 30.0),
      closeButton.heightAnchor.constraint(equalToConstant: 30.0),
    ])

    applyColors(isDark: true, textColor: .white, accent: .systemBlue)
  }

  @objc private func retryTapped() { onRetry?() }
  @objc private func closeTapped() { onClose?() }
}
