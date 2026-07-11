import UIKit

final class ChatPinnedBannerView: UIControl {
  static let preferredHeight: CGFloat = 44.0

  private let blurView = UIVisualEffectView(effect: nil)
  /// Content that can translate on carousel swaps without fading the glass shell.
  private let contentContainer = UIView()
  private let iconContainer = UIView()
  private let iconGlowView = UIView()
  private let iconImageView = UIImageView()
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()
  private let textStack = UIStackView()
  private let closeButton = UIButton(type: .system)
  /// Vertical page dots (left edge) for multi-agent usage carousel.
  private let pageDotsStack = UIStackView()
  private var pageDotViews: [UIView] = []
  private var isFilePinned = false
  private var iconAccentColor: UIColor?
  private var textColor: UIColor = .label
  private var pageCount: Int = 0
  private var pageIndex: Int = 0

  /// When set, a trailing ✕ appears and taps on it call this instead of the banner's
  /// own touch-up action (the button swallows its touches as a UIControl subview).
  var onClose: (() -> Void)? {
    didSet { closeButton.isHidden = onClose == nil }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(title: String, body: String, isFile: Bool, animateIcon: Bool = false) {
    let shouldAnimate =
      animateIcon
      || titleLabel.text != title
      || bodyLabel.text != body
      || isFilePinned != isFile

    titleLabel.text = title
    bodyLabel.text = body
    isFilePinned = isFile
    iconImageView.image = UIImage(systemName: isFile ? "pin.circle.fill" : "pin.fill")
    if animateIcon || shouldAnimate {
      animatePinIcon()
    }
    setNeedsLayout()
  }

  /// Configures the banner with an explicit SF Symbol — used by the agent Inbox
  /// banner (tray icon) rather than the default pin glyph.
  func configure(title: String, body: String, systemImage: String, animateIcon: Bool = false) {
    let titleChanged = titleLabel.text != title
    let bodyChanged = bodyLabel.text != body
    titleLabel.text = title
    bodyLabel.text = body
    iconImageView.image = UIImage(systemName: systemImage)
    if animateIcon || titleChanged || bodyChanged {
      animatePinIcon()
    }
    setNeedsLayout()
  }

  /// Multi-agent usage carousel: left-side vertical dots for page count/index.
  /// `count <= 1` hides the dots.
  func setPageIndicator(count: Int, index: Int) {
    let nextCount = max(0, count)
    let nextIndex = nextCount == 0 ? 0 : min(max(0, index), nextCount - 1)
    pageCount = nextCount
    pageIndex = nextIndex
    rebuildPageDotsIfNeeded()
    applyPageDotStyles()
    pageDotsStack.isHidden = nextCount <= 1
    setNeedsLayout()
  }

  /// Slide only the inner content (icon + text) along Y — glass shell stays put, no fade.
  func animateContentTranslateY(from dy: CGFloat) {
    contentContainer.layer.removeAllAnimations()
    contentContainer.transform = CGAffineTransform(translationX: 0, y: dy)
    UIView.animate(
      withDuration: 0.28,
      delay: 0,
      usingSpringWithDamping: 0.86,
      initialSpringVelocity: 0.4,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.contentContainer.transform = .identity
    }
  }

  func applyTheme(textColor: UIColor, surfaceColor: UIColor, isDark: Bool) {
    self.textColor = textColor
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = true
      blurView.effect = glass
      blurView.contentView.backgroundColor = .clear
    } else {
      blurView.effect = UIBlurEffect(style: .systemThinMaterial)
      blurView.contentView.backgroundColor = surfaceColor.withAlphaComponent(isDark ? 0.16 : 0.10)
    }
    // Glass shell stays fully opaque; only content may animate.
    blurView.alpha = 1.0
    alpha = 1.0
    let iconColor = iconAccentColor ?? textColor
    let iconFillColor = iconAccentColor ?? surfaceColor
    iconContainer.backgroundColor = iconFillColor.withAlphaComponent(isDark ? 0.24 : 0.16)
    iconGlowView.backgroundColor = iconColor.withAlphaComponent(isDark ? 0.30 : 0.20)
    iconImageView.tintColor = iconColor.withAlphaComponent(0.95)
    titleLabel.textColor = textColor.withAlphaComponent(0.96)
    bodyLabel.textColor = textColor.withAlphaComponent(0.82)
    closeButton.tintColor = textColor.withAlphaComponent(0.55)
    applyPageDotStyles()
  }

  func applyIconAccent(_ color: UIColor?) {
    iconAccentColor = color
  }

  private func setup() {
    backgroundColor = .clear
    isUserInteractionEnabled = true
    // Important: blur must not steal touches from UIControl hit-tracking.
    blurView.isUserInteractionEnabled = false
    contentContainer.isUserInteractionEnabled = false
    pageDotsStack.isUserInteractionEnabled = false

    addSubview(blurView)
    blurView.layer.cornerCurve = .continuous
    blurView.layer.cornerRadius = ChatPinnedBannerView.preferredHeight / 2.0
    blurView.clipsToBounds = true

    addSubview(contentContainer)
    contentContainer.addSubview(iconContainer)
    iconContainer.addSubview(iconGlowView)
    iconContainer.addSubview(iconImageView)
    contentContainer.addSubview(textStack)

    addSubview(pageDotsStack)
    pageDotsStack.axis = .vertical
    pageDotsStack.alignment = .center
    pageDotsStack.distribution = .equalSpacing
    pageDotsStack.spacing = 4.0
    pageDotsStack.isHidden = true

    iconImageView.image = UIImage(systemName: "pin.fill")
    iconImageView.contentMode = .scaleAspectFit
    iconImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 13, weight: .semibold)

    iconContainer.layer.cornerCurve = .continuous
    iconContainer.layer.cornerRadius = 14.0
    iconGlowView.layer.cornerCurve = .continuous
    iconGlowView.layer.cornerRadius = 14.0
    iconGlowView.alpha = 0.0

    titleLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail

    bodyLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
    bodyLabel.numberOfLines = 1
    bodyLabel.lineBreakMode = .byTruncatingTail

    textStack.axis = .vertical
    textStack.alignment = .fill
    textStack.distribution = .fill
    textStack.spacing = 0.0
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(bodyLabel)

    // Close sits above blur as a real control so it receives taps without killing
    // the banner's own touchUpInside on the rest of the chrome.
    closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    closeButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold), forImageIn: .normal)
    closeButton.isHidden = true
    closeButton.addAction(
      UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
    addSubview(closeButton)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    blurView.frame = bounds

    let closeSize: CGFloat = 32.0
    closeButton.frame = CGRect(
      x: bounds.width - closeSize - 6.0,
      y: (bounds.height - closeSize) * 0.5,
      width: closeSize,
      height: closeSize
    )

    let showsDots = pageCount > 1
    let dotsWidth: CGFloat = showsDots ? 10.0 : 0.0
    let dotsLeading: CGFloat = showsDots ? 10.0 : 0.0
    if showsDots {
      let dotsHeight = CGFloat(pageCount) * 5.0 + CGFloat(max(0, pageCount - 1)) * 4.0
      pageDotsStack.frame = CGRect(
        x: dotsLeading,
        y: (bounds.height - dotsHeight) * 0.5,
        width: dotsWidth,
        height: dotsHeight
      )
    } else {
      pageDotsStack.frame = .zero
    }

    let contentLeading = showsDots ? (pageDotsStack.frame.maxX + 6.0) : 0.0
    let trailingReserve: CGFloat = closeButton.isHidden ? 12.0 : closeSize + 8.0
    contentContainer.frame = CGRect(
      x: contentLeading,
      y: 0,
      width: max(0, bounds.width - contentLeading - trailingReserve + (closeButton.isHidden ? 0 : 6)),
      height: bounds.height
    )

    let iconSize: CGFloat = 28.0
    iconContainer.frame = CGRect(
      x: 10.0, y: (contentContainer.bounds.height - iconSize) * 0.5, width: iconSize, height: iconSize)
    iconGlowView.frame = iconContainer.bounds
    iconImageView.frame = iconContainer.bounds.insetBy(dx: 7.0, dy: 7.0)

    let hasTextLayoutSpace = contentContainer.bounds.width > 40.0 && contentContainer.bounds.height > 12.0
    textStack.isHidden = !hasTextLayoutSpace
    titleLabel.isHidden = !hasTextLayoutSpace
    bodyLabel.isHidden = !hasTextLayoutSpace
    guard hasTextLayoutSpace else {
      textStack.frame = .zero
      return
    }

    let textX = iconContainer.frame.maxX + 10.0
    textStack.frame = CGRect(
      x: textX,
      y: 6.0,
      width: max(0.0, contentContainer.bounds.width - textX - 4.0),
      height: max(0.0, contentContainer.bounds.height - 12.0)
    )
  }

  /// Prefer banner tap over child views except the close button.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled, bounds.contains(point) else {
      return nil
    }
    if !closeButton.isHidden {
      let closePoint = closeButton.convert(point, from: self)
      if closeButton.bounds.contains(closePoint) {
        return closeButton
      }
    }
    return self
  }

  private func rebuildPageDotsIfNeeded() {
    while pageDotViews.count < pageCount {
      let dot = UIView()
      dot.layer.cornerCurve = .continuous
      pageDotsStack.addArrangedSubview(dot)
      pageDotViews.append(dot)
    }
    while pageDotViews.count > pageCount {
      let last = pageDotViews.removeLast()
      pageDotsStack.removeArrangedSubview(last)
      last.removeFromSuperview()
    }
    for (i, dot) in pageDotViews.enumerated() {
      let size: CGFloat = i == pageIndex ? 6.0 : 5.0
      dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
      dot.layer.cornerRadius = size * 0.5
      // Fixed size via constraints so stack spacing is stable.
      dot.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.deactivate(dot.constraints)
      NSLayoutConstraint.activate([
        dot.widthAnchor.constraint(equalToConstant: size),
        dot.heightAnchor.constraint(equalToConstant: size),
      ])
    }
  }

  private func applyPageDotStyles() {
    for (i, dot) in pageDotViews.enumerated() {
      let active = i == pageIndex
      dot.backgroundColor = textColor.withAlphaComponent(active ? 0.92 : 0.28)
    }
  }

  private func animatePinIcon() {
    iconContainer.layer.removeAnimation(forKey: "pinScale")
    iconImageView.layer.removeAnimation(forKey: "pinWiggle")
    iconGlowView.layer.removeAnimation(forKey: "pinGlow")

    let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
    wiggle.values = [0.0, -0.18, 0.14, -0.08, 0.04, 0.0]
    wiggle.keyTimes = [0.0, 0.2, 0.42, 0.62, 0.82, 1.0]
    wiggle.duration = 0.46
    wiggle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    iconImageView.layer.add(wiggle, forKey: "pinWiggle")

    let scale = CASpringAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.88
    scale.toValue = 1.0
    scale.initialVelocity = 0.7
    scale.damping = 10.0
    scale.stiffness = 140.0
    scale.mass = 0.9
    scale.duration = scale.settlingDuration
    iconContainer.layer.add(scale, forKey: "pinScale")

    iconGlowView.alpha = 0.0
    UIView.animate(
      withDuration: 0.18,
      delay: 0.0,
      options: [.beginFromCurrentState, .curveEaseOut]
    ) {
      self.iconGlowView.alpha = 1.0
    } completion: { _ in
      UIView.animate(
        withDuration: 0.32,
        delay: 0.0,
        options: [.beginFromCurrentState, .curveEaseIn]
      ) {
        self.iconGlowView.alpha = 0.0
      }
    }
  }
}
