import UIKit

public protocol ChatContextMenuOverlayDelegate: AnyObject {
  func contextMenuDidDismiss(overlay: ChatContextMenuOverlay)
  func contextMenuDidSelectReaction(_ reaction: String, messageId: String, sourcePoint: CGPoint?)
  func contextMenuDidSelectAction(_ actionId: String, messageId: String)
}

// MARK: - Glass Helper

/// Creates a UIVisualEffectView that uses real UIGlassEffect on iOS 26+,
/// and falls back to UIBlurEffect on older iOS versions.
private func makeLiquidGlassView(
  style: UIBlurEffect.Style = .systemMaterial,
  cornerRadius: CGFloat,
  capsuleCorners: Bool = false,
  interactive: Bool = false
) -> UIVisualEffectView {
  let view = UIVisualEffectView(effect: nil)
  if #available(iOS 26.0, *) {
    let effect = UIGlassEffect(style: .regular)
    effect.isInteractive = interactive
    view.effect = effect
    if capsuleCorners {
      view.cornerConfiguration = .capsule()
    } else {
      view.layer.cornerRadius = cornerRadius
      view.layer.cornerCurve = .continuous
    }
  } else {
    view.effect = UIBlurEffect(style: style)
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
  }
  view.clipsToBounds = true
  return view
}

// MARK: - ChatContextMenuOverlay

public final class ChatContextMenuOverlay: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?

  let messageId: String

  // The bubble snapshot (bubble+tail only, already positioned in window coords)
  private let bubbleSnapshot: UIView
  // The bubble's original frame in window coords (before any shifting)
  private let originalBubbleFrame: CGRect
  private let bubbleIsMe: Bool

  private let appearance: ChatListAppearance

  // Full-screen native glass background (same as Telegram / UIContextMenuInteraction)
  private let backgroundGlassView: UIVisualEffectView

  // Reaction picker pill
  private let reactionPicker: ReactionPickerView

  // Action menu card
  private let contextMenu: ContextMenuView

  private var isDismissing = false
  private var reactionMaskLayer: CALayer?
  private var contextMenuMaskLayer: CALayer?

  // MARK: - Init

  init(
    messageId: String,
    bubbleSnapshot: UIView,
    bubbleFrame: CGRect,
    bubbleIsMe: Bool,
    appearance: ChatListAppearance,
    showResendAction: Bool
  ) {
    self.messageId = messageId
    self.bubbleSnapshot = bubbleSnapshot
    self.originalBubbleFrame = bubbleFrame
    self.bubbleIsMe = bubbleIsMe
    self.appearance = appearance

    // Full-screen background: native system glass (ultraThin), same as Telegram
    let bgStyle: UIBlurEffect.Style =
      appearance.isDark
      ? .systemMaterialDark
      : .systemMaterialLight
    self.backgroundGlassView = UIVisualEffectView(effect: UIBlurEffect(style: bgStyle))

    let colorOverlay = UIView()
    let isDarkMode = appearance.isDark
    let overlayBaseColor: UIColor = isDarkMode ? .black : .white
    let overlayAlpha: CGFloat = isDarkMode ? 0.42 : 0.32
    colorOverlay.backgroundColor = overlayBaseColor.withAlphaComponent(overlayAlpha)
    colorOverlay.translatesAutoresizingMaskIntoConstraints = false
    self.backgroundGlassView.contentView.addSubview(colorOverlay)
    NSLayoutConstraint.activate([
      colorOverlay.topAnchor.constraint(equalTo: self.backgroundGlassView.contentView.topAnchor),
      colorOverlay.bottomAnchor.constraint(equalTo: self.backgroundGlassView.contentView.bottomAnchor),
      colorOverlay.leadingAnchor.constraint(equalTo: self.backgroundGlassView.contentView.leadingAnchor),
      colorOverlay.trailingAnchor.constraint(equalTo: self.backgroundGlassView.contentView.trailingAnchor),
    ])

    self.reactionPicker = ReactionPickerView(appearance: appearance, messageId: messageId)
    self.contextMenu = ContextMenuView(
      appearance: appearance,
      messageId: messageId,
      showResendAction: showResendAction
    )

    super.init(frame: .zero)

    setupViews()
    setupGestures()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupViews() {
    // 1. Full-screen glass background
    backgroundGlassView.alpha = 0
    addSubview(backgroundGlassView)

    // 2. Bubble snapshot (already has correct frame in window coords)
    bubbleSnapshot.alpha = 0
    addSubview(bubbleSnapshot)

    // 3. Reaction picker (above bubble)
    reactionPicker.alpha = 0
    reactionPicker.delegate = self
    let pickerSize = reactionPicker.intrinsicContentSize
    reactionPicker.frame = CGRect(origin: .zero, size: pickerSize)
    addSubview(reactionPicker)

    // 4. Context menu (below or above bubble)
    contextMenu.alpha = 0
    contextMenu.delegate = self
    contextMenu.frame = CGRect(x: 0, y: 0, width: 250, height: 1)
    addSubview(contextMenu)
  }

  private func setupGestures() {
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
    tap.delegate = self
    addGestureRecognizer(tap)
  }

  @objc private func handleBackgroundTap() {
    animateOut()
  }

  // MARK: - Layout

  private func keyboardTopInOverlaySpace() -> CGFloat? {
    guard #available(iOS 13.0, *) else { return nil }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    var top: CGFloat?

    for candidate in windows {
      guard !candidate.isHidden else { continue }
      let className = NSStringFromClass(type(of: candidate))
      let looksLikeKeyboard =
        className.contains("UIRemoteKeyboardWindow")
        || className.contains("UITextEffectsWindow")
      guard looksLikeKeyboard else { continue }

      let frameInScreen = candidate.convert(candidate.bounds, to: nil)
      let frameInOverlay = convert(frameInScreen, from: nil)
      let intersection = bounds.intersection(frameInOverlay)
      guard !intersection.isNull, intersection.height > 0 else { continue }
      top = min(top ?? intersection.minY, intersection.minY)
    }

    return top
  }

  /// Computes the shifted bubble frame and positions all elements.
  /// Returns the final bubble frame (may be shifted from original).
  @discardableResult
  private func layoutMenus() -> CGRect {
    let safeTop = safeAreaInsets.top + 10
    var safeBottom = bounds.height - safeAreaInsets.bottom - 10
    if let keyboardTop = keyboardTopInOverlaySpace() {
      safeBottom = min(safeBottom, keyboardTop - 10)
    }
    if safeBottom <= safeTop + 40 {
      safeBottom = bounds.height - safeAreaInsets.bottom - 10
    }
    let safeLeft: CGFloat = 12
    let safeRight = bounds.width - 12

    // Measure reaction picker
    let pickerSize = reactionPicker.intrinsicContentSize
    let pickerHeight = pickerSize.height
    let pickerGap: CGFloat = 8

    // Measure context menu
    let menuWidth: CGFloat = min(250, bounds.width - 24)
    let menuHeight = contextMenu.systemLayoutSizeFitting(
      CGSize(width: menuWidth, height: UIView.layoutFittingCompressedSize.height)
    ).height
    // Keep the action menu visually attached to the bubble (Telegram-like spacing).
    let menuGap: CGFloat = 4

    // Horizontal alignment: align to bubble edge, then clamp to viewport.
    let isRightAligned = bubbleIsMe || originalBubbleFrame.midX > bounds.midX

    // Reaction picker: align to bubble edge, clamped strictly to safe viewport
    let pickerWidth = min(pickerSize.width, bounds.width - 24)
    let targetPickerX =
      isRightAligned ? originalBubbleFrame.maxX - pickerWidth : originalBubbleFrame.minX
    let pickerX = max(safeLeft, min(safeRight - pickerWidth, targetPickerX))

    // Vertical placement prefers original bubble Y, then shifts minimally to fit picker+menu.
    var bubbleY = originalBubbleFrame.minY
    var pickerY = bubbleY - pickerHeight - pickerGap
    var menuY = bubbleY + originalBubbleFrame.height + menuGap

    let totalBottom = menuY + menuHeight
    if totalBottom > safeBottom {
      let shiftUp = totalBottom - safeBottom
      bubbleY -= shiftUp
      pickerY -= shiftUp
      menuY -= shiftUp
    }

    if pickerY < safeTop {
      let shiftDown = safeTop - pickerY
      bubbleY += shiftDown
      pickerY += shiftDown
      menuY += shiftDown
    }

    reactionPicker.frame = CGRect(
      x: pickerX,
      y: pickerY,
      width: pickerWidth,
      height: pickerHeight
    )

    // Bubble: keep original X, shift Y to computed safe position.
    let finalBubbleFrame = CGRect(
      x: originalBubbleFrame.minX,
      y: bubbleY,
      width: originalBubbleFrame.width,
      height: originalBubbleFrame.height
    )
    bubbleSnapshot.frame = finalBubbleFrame

    // Context menu: align to bubble edge
    let menuX: CGFloat
    if isRightAligned {
      menuX = max(safeLeft, finalBubbleFrame.maxX - menuWidth)
    } else {
      menuX = min(safeRight - menuWidth, finalBubbleFrame.minX)
    }
    contextMenu.frame = CGRect(
      x: max(safeLeft, min(safeRight - menuWidth, menuX)),
      y: max(safeTop, min(safeBottom - menuHeight, menuY)),
      width: menuWidth,
      height: menuHeight
    )

    return finalBubbleFrame
  }

  // MARK: - Animate In / Out

  private func setAnchorPoint(_ anchorPoint: CGPoint, for view: UIView) {
    let oldOrigin = view.frame.origin
    view.layer.anchorPoint = anchorPoint
    let newOrigin = view.frame.origin
    let transition = CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y)
    view.center = CGPoint(x: view.center.x - transition.x, y: view.center.y - transition.y)
  }

  func animateIn() {
    guard let window = window else { return }
    frame = window.bounds
    backgroundGlassView.frame = bounds

    // Place bubble at original position first (before layout shifts it)
    bubbleSnapshot.frame = originalBubbleFrame
    bubbleSnapshot.alpha = 1

    layoutIfNeeded()

    // Compute final layout (this shifts the bubble)
    let finalBubbleFrame = layoutMenus()
    let isRightAligned = bubbleIsMe || finalBubbleFrame.midX > bounds.midX
    let pickerFinalFrame = reactionPicker.frame
    let menuFinalFrame = contextMenu.frame

    // --- Background glass fade in ---
    UIView.animate(withDuration: 0.20, delay: 0, options: .curveEaseOut) {
      self.backgroundGlassView.alpha = 1
    }

    // --- Bubble: Telegram-like hold scale on bubble itself (translation kept independent) ---
    let startCenter = CGPoint(x: originalBubbleFrame.midX, y: originalBubbleFrame.midY)
    let endCenter = CGPoint(x: finalBubbleFrame.midX, y: finalBubbleFrame.midY)
    bubbleSnapshot.bounds = CGRect(origin: .zero, size: originalBubbleFrame.size)
    bubbleSnapshot.center = startCenter
    bubbleSnapshot.transform = .identity

    // Telegram uses target content width; for compact bubbles clamp the side so hold-scale
    // doesn't over-shrink tiny messages.
    let scaleSide = max(finalBubbleFrame.width, 180.0)
    let heldScale = max(0.90, (scaleSide - 15.0) / scaleSide)
    UIView.animate(
      withDuration: 0.22,
      delay: 0,
      options: [.curveEaseOut, .beginFromCurrentState]
    ) {
      self.bubbleSnapshot.center = endCenter
      self.bubbleSnapshot.transform = CGAffineTransform(scaleX: heldScale, y: heldScale)
    }

    // --- Reaction picker: directional clip reveal (left/right based on bubble side) ---
    reactionPicker.frame = pickerFinalFrame
    setAnchorPoint(CGPoint(x: isRightAligned ? 1.0 : 0.0, y: 0.5), for: reactionPicker)
    reactionPicker.alpha = 0
    reactionPicker.transform = CGAffineTransform(translationX: isRightAligned ? 6 : -6, y: 0)

    let pickerMask = CALayer()
    pickerMask.backgroundColor = UIColor.black.cgColor
    pickerMask.frame = CGRect(
      x: isRightAligned ? pickerFinalFrame.width : 0,
      y: 0,
      width: 0,
      height: pickerFinalFrame.height
    )
    reactionPicker.layer.mask = pickerMask
    reactionMaskLayer = pickerMask

    UIView.animate(
      withDuration: 0.42, delay: 0.02, options: [.curveEaseOut, .beginFromCurrentState]
    ) {
      self.reactionPicker.alpha = 1
      self.reactionPicker.transform = .identity
    }
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.42)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
    pickerMask.frame = CGRect(
      x: 0,
      y: 0,
      width: pickerFinalFrame.width,
      height: pickerFinalFrame.height
    )
    CATransaction.commit()

    // --- Context menu: height reveal (no pop-in scale) ---
    contextMenu.frame = menuFinalFrame
    setAnchorPoint(CGPoint(x: isRightAligned ? 1.0 : 0.0, y: 0.0), for: contextMenu)
    contextMenu.transform = CGAffineTransform(translationX: 0, y: -2)
    contextMenu.alpha = 0

    let menuMask = CALayer()
    menuMask.backgroundColor = UIColor.black.cgColor
    menuMask.frame = CGRect(x: 0, y: 0, width: menuFinalFrame.width, height: 0)
    contextMenu.layer.mask = menuMask
    contextMenuMaskLayer = menuMask

    UIView.animate(
      withDuration: 0.42, delay: 0.02, options: [.curveEaseOut, .beginFromCurrentState]
    ) {
      self.contextMenu.alpha = 1
      self.contextMenu.transform = .identity
    }
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.42)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
    menuMask.frame = CGRect(x: 0, y: 0, width: menuFinalFrame.width, height: menuFinalFrame.height)
    CATransaction.commit()
  }

  func animateOut(completion: (() -> Void)? = nil) {
    if isDismissing { return }
    isDismissing = true

    UIView.animate(
      withDuration: 0.18, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]
    ) {
      self.backgroundGlassView.alpha = 0
      self.reactionPicker.alpha = 0
      self.contextMenu.alpha = 0
      // Snap bubble back to original position smoothly (keep alpha at 1 to prevent flicker)
      self.bubbleSnapshot.transform = .identity
      self.bubbleSnapshot.bounds = CGRect(origin: .zero, size: self.originalBubbleFrame.size)
      self.bubbleSnapshot.center = CGPoint(
        x: self.originalBubbleFrame.midX,
        y: self.originalBubbleFrame.midY
      )
      self.contextMenu.transform = CGAffineTransform(translationX: 0, y: -2)
      self.reactionPicker.transform = CGAffineTransform(
        translationX: self.bubbleIsMe ? 6 : -6,
        y: 0
      )
    } completion: { _ in
      self.reactionPicker.layer.mask = nil
      self.contextMenu.layer.mask = nil
      self.reactionMaskLayer = nil
      self.contextMenuMaskLayer = nil
      self.removeFromSuperview()
      self.delegate?.contextMenuDidDismiss(overlay: self)
      completion?()
    }
  }
}

// MARK: - UIGestureRecognizerDelegate

extension ChatContextMenuOverlay: UIGestureRecognizerDelegate {
  public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer)
    -> Bool
  {
    let point = gestureRecognizer.location(in: self)
    // Only dismiss if tap is outside the bubble, picker, and menu
    if bubbleSnapshot.frame.contains(point) { return false }
    if reactionPicker.frame.contains(point) { return false }
    if contextMenu.frame.contains(point) { return false }
    return true
  }
}

// MARK: - ChatContextMenuOverlayDelegate (self-forwarding)

extension ChatContextMenuOverlay: ChatContextMenuOverlayDelegate {
  public func contextMenuDidDismiss(overlay: ChatContextMenuOverlay) {}

  public func contextMenuDidSelectReaction(
    _ reaction: String,
    messageId _: String,
    sourcePoint: CGPoint?
  ) {
    delegate?.contextMenuDidSelectReaction(reaction, messageId: messageId, sourcePoint: sourcePoint)
  }

  public func contextMenuDidSelectAction(_ actionId: String, messageId _: String) {
    delegate?.contextMenuDidSelectAction(actionId, messageId: messageId)
  }
}

// MARK: - Reaction Picker View

final class ReactionPickerView: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?

  private let glassView: UIVisualEffectView
  private let stack: UIStackView
  private let emojis = ["👍", "👎", "❤️", "🔥", "🎉", "💩"]

  let messageId: String

  override var intrinsicContentSize: CGSize {
    let emojiCount = CGFloat(emojis.count)
    let buttonSize: CGFloat = 44
    let spacing: CGFloat = 4
    let padding: CGFloat = 12
    let width = emojiCount * buttonSize + (emojiCount - 1) * spacing + padding * 2
    return CGSize(width: width, height: buttonSize + 8)
  }

  init(appearance: ChatListAppearance, messageId: String) {
    self.messageId = messageId
    // Liquid glass pill for reaction bar
    self.glassView = makeLiquidGlassView(
      style: appearance.isDark ? .systemThinMaterialDark : .systemThinMaterial,
      cornerRadius: 26,
      capsuleCorners: true
    )
    self.stack = UIStackView()

    super.init(frame: .zero)

    glassView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glassView)

    stack.axis = .horizontal
    stack.distribution = .fillEqually
    stack.spacing = 4
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false

    // Add stack to glass view's contentView so it renders above the glass
    glassView.contentView.addSubview(stack)

    let stackTop = stack.topAnchor.constraint(
      greaterThanOrEqualTo: glassView.contentView.topAnchor,
      constant: 4
    )
    let stackBottom = stack.bottomAnchor.constraint(
      lessThanOrEqualTo: glassView.contentView.bottomAnchor,
      constant: -4
    )
    let stackCenterY = stack.centerYAnchor.constraint(equalTo: glassView.contentView.centerYAnchor)
    stackTop.priority = .defaultHigh
    stackBottom.priority = .defaultHigh
    stackCenterY.priority = .defaultHigh

    NSLayoutConstraint.activate([
      glassView.topAnchor.constraint(equalTo: topAnchor),
      glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor),

      stackTop,
      stackBottom,
      stackCenterY,
      stack.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor, constant: -12),
    ])

    for emoji in emojis {
      let btn = UIButton(type: .system)
      btn.setTitle(emoji, for: .normal)
      btn.titleLabel?.font = UIFont.systemFont(ofSize: 28)
      btn.translatesAutoresizingMaskIntoConstraints = false
      let width = btn.widthAnchor.constraint(equalToConstant: 44)
      width.priority = .defaultHigh
      width.isActive = true
      let height = btn.heightAnchor.constraint(equalToConstant: 44)
      height.priority = .defaultHigh
      height.isActive = true
      btn.addTarget(self, action: #selector(didTapEmoji(_:)), for: .touchUpInside)
      stack.addArrangedSubview(btn)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func didTapEmoji(_ sender: UIButton) {
    guard let emoji = sender.title(for: .normal) else { return }
    // Spring bounce on tap
    UIView.animate(
      withDuration: 0.12, delay: 0, options: .curveEaseIn,
      animations: { sender.transform = CGAffineTransform(scaleX: 1.3, y: 1.3) }
    ) { _ in
      UIView.animate(withDuration: 0.18, delay: 0, options: .curveEaseOut) {
        sender.transform = .identity
      }
    }
    let sourcePoint = sender.convert(
      CGPoint(x: sender.bounds.midX, y: sender.bounds.midY),
      to: nil
    )
    delegate?.contextMenuDidSelectReaction(emoji, messageId: messageId, sourcePoint: sourcePoint)
  }
}

// MARK: - Context Menu View

final class ContextMenuView: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?

  private let glassView: UIVisualEffectView
  private let stack: UIStackView

  struct ActionItem {
    let id: String
    let title: String
    let iconName: String
    let isDestructive: Bool
  }

  private let actions: [ActionItem]

  let messageId: String

  init(appearance: ChatListAppearance, messageId: String, showResendAction: Bool) {
    self.messageId = messageId
    var resolvedActions: [ActionItem] = [
      ActionItem(
        id: "reply", title: "Reply", iconName: "arrowshape.turn.up.left", isDestructive: false),
      ActionItem(id: "copy", title: "Copy", iconName: "doc.on.doc", isDestructive: false),
      ActionItem(id: "pin", title: "Pin", iconName: "pin", isDestructive: false),
      ActionItem(id: "delete", title: "Delete", iconName: "trash", isDestructive: true),
    ]
    if showResendAction {
      resolvedActions.insert(
        ActionItem(
          id: "resend",
          title: "Resend",
          iconName: "arrow.clockwise",
          isDestructive: false
        ),
        at: 2
      )
    }
    self.actions = resolvedActions
    self.glassView = makeLiquidGlassView(
      style: appearance.isDark ? .systemMaterialDark : .systemMaterial,
      cornerRadius: 24,
      capsuleCorners: false
    )
    self.stack = UIStackView()

    super.init(frame: .zero)

    glassView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glassView)

    stack.axis = .vertical
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    glassView.contentView.addSubview(stack)

    glassView.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
    glassView.layer.borderWidth = 1.0 / UIScreen.main.scale

    NSLayoutConstraint.activate([
      glassView.topAnchor.constraint(equalTo: topAnchor),
      glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor),
    ])
    let stackTop = stack.topAnchor.constraint(
      greaterThanOrEqualTo: glassView.contentView.topAnchor,
      constant: 8
    )
    let stackBottom = stack.bottomAnchor.constraint(
      lessThanOrEqualTo: glassView.contentView.bottomAnchor,
      constant: -8
    )
    let stackCenterY = stack.centerYAnchor.constraint(equalTo: glassView.contentView.centerYAnchor)
    stackTop.priority = .defaultHigh
    stackBottom.priority = .defaultHigh
    stackCenterY.priority = .defaultHigh
    NSLayoutConstraint.activate([stackTop, stackBottom, stackCenterY])

    for (index, action) in actions.enumerated() {
      if index > 0 {
        let sepContainer = UIView()
        sepContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sepContainer)

        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        line.translatesAutoresizingMaskIntoConstraints = false
        sepContainer.addSubview(line)

        let sepHeight = sepContainer.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale)
        sepHeight.priority = .defaultHigh
        let lineLeading = line.leadingAnchor.constraint(
          greaterThanOrEqualTo: sepContainer.leadingAnchor,
          constant: 58
        )
        lineLeading.priority = .defaultLow
        let lineTrailing = line.trailingAnchor.constraint(
          lessThanOrEqualTo: sepContainer.trailingAnchor,
          constant: -16
        )
        lineTrailing.priority = .defaultLow
        let lineCenterX = line.centerXAnchor.constraint(equalTo: sepContainer.centerXAnchor)
        lineCenterX.priority = .defaultLow
        NSLayoutConstraint.activate([
          sepHeight,
          lineLeading,
          lineTrailing,
          lineCenterX,
          line.topAnchor.constraint(equalTo: sepContainer.topAnchor),
          line.bottomAnchor.constraint(equalTo: sepContainer.bottomAnchor),
        ])
      }
      let row = ContextMenuRow(action: action)
      row.addTarget(self, action: #selector(didTapAction(_:)), for: .touchUpInside)
      stack.addArrangedSubview(row)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func didTapAction(_ sender: ContextMenuRow) {
    delegate?.contextMenuDidSelectAction(sender.actionId, messageId: messageId)
  }
}

// MARK: - Context Menu Row

final class ContextMenuRow: UIControl {
  let actionId: String
  private let titleLabel: UILabel
  private let iconView: UIImageView

  init(action: ContextMenuView.ActionItem) {
    self.actionId = action.id
    self.titleLabel = UILabel()
    self.iconView = UIImageView()
    super.init(frame: .zero)

    backgroundColor = .clear

    titleLabel.text = action.title
    titleLabel.font = UIFont.systemFont(ofSize: 17.5, weight: .regular)
    titleLabel.textColor = action.isDestructive ? .systemRed : .label
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
    if let image = UIImage(systemName: action.iconName, withConfiguration: config) {
      iconView.image = image
      iconView.tintColor = action.isDestructive ? .systemRed : .label
    }
    iconView.contentMode = .scaleAspectFit

    addSubview(titleLabel)
    addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    iconView.translatesAutoresizingMaskIntoConstraints = false

    let rowHeight = heightAnchor.constraint(equalToConstant: 52)
    rowHeight.priority = .defaultHigh
    let labelLeading = titleLabel.leadingAnchor.constraint(
      greaterThanOrEqualTo: iconView.trailingAnchor,
      constant: 16
    )
    labelLeading.priority = .defaultHigh
    let labelTrailing = titleLabel.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor,
      constant: -18
    )
    labelTrailing.priority = .defaultLow

    NSLayoutConstraint.activate([
      rowHeight,

      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 24),
      iconView.heightAnchor.constraint(equalToConstant: 24),

      labelLeading,
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      labelTrailing,
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.1) {
        self.backgroundColor =
          self.isHighlighted
          ? UIColor.label.withAlphaComponent(0.08)
          : .clear
      }
    }
  }
}
