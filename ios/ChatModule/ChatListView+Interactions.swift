import AudioToolbox
import UIKit
import SwiftUI

private let swipeReplyTrigger: CGFloat = 56.0
private let swipeReplyMaxOffset: CGFloat = 80.0
private let chatHoldDebugLogs = true

/// Telegram-style circular reply indicator. Soft blur disc, thin outline arrow,
/// no colour tint. It emerges from the right edge as the bubble slides, scaling
/// and rotating in from the first pixel of the swipe. On the reply hit it fires a
/// dedicated FX pass: a springy bounce, an expanding burst ring, and a glint
/// shimmer that sweeps across the disc.
final class ChatSwipeReplyIconView: UIView {
  static let diameter: CGFloat = 28.0
  private let blurView = UIVisualEffectView(effect: nil)
  private let arrow = UIImageView()
  private let ringLayer = CAShapeLayer()
  private let shimmerHost = UIView()
  private let shimmerLayer = CAGradientLayer()
  private(set) var didPop = false

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
    isUserInteractionEnabled = false

    blurView.frame = bounds
    blurView.layer.cornerRadius = Self.diameter / 2.0
    blurView.clipsToBounds = true
    blurView.layer.borderWidth = 0.5
    addSubview(blurView)

    // Burst-ring FX layer — invisible until the hit, then expands + fades.
    ringLayer.frame = bounds
    ringLayer.fillColor = UIColor.clear.cgColor
    ringLayer.lineWidth = 1.5
    ringLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75)).cgPath
    ringLayer.opacity = 0.0
    layer.addSublayer(ringLayer)

    // Thin outline arrow (not filled) for a lighter stroke at small size.
    let cfg = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)
    arrow.image = UIImage(systemName: "arrowshape.turn.up.left", withConfiguration: cfg)
    arrow.contentMode = .center
    arrow.frame = bounds
    addSubview(arrow)

    // Glint-shimmer FX layer — a diagonal highlight clipped to the disc that
    // sweeps across once on the hit. Hidden until then.
    shimmerHost.frame = bounds
    shimmerHost.layer.cornerRadius = Self.diameter / 2.0
    shimmerHost.clipsToBounds = true
    shimmerHost.isUserInteractionEnabled = false
    shimmerHost.isHidden = true
    addSubview(shimmerHost)

    shimmerLayer.frame = CGRect(x: -Self.diameter, y: 0, width: Self.diameter, height: Self.diameter)
    shimmerLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    shimmerLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    shimmerLayer.colors = [
      UIColor.white.withAlphaComponent(0.0).cgColor,
      UIColor.white.withAlphaComponent(0.75).cgColor,
      UIColor.white.withAlphaComponent(0.0).cgColor,
    ]
    shimmerLayer.locations = [0.0, 0.5, 1.0]
    shimmerHost.layer.addSublayer(shimmerLayer)

    alpha = 0.0
    // Start from nothing so it visibly scales up as the swipe begins.
    transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
  }

  required init?(coder: NSCoder) { nil }

  func applyTheme(isDark: Bool) {
    // Soft, modern material — no colour tint, just a frosted disc.
    blurView.effect = UIBlurEffect(
      style: isDark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight)
    blurView.layer.borderColor = UIColor(white: isDark ? 1.0 : 0.0, alpha: 0.12).cgColor
    arrow.tintColor = isDark ? .white : UIColor(white: 0.12, alpha: 1.0)
    ringLayer.strokeColor = UIColor(white: isDark ? 1.0 : 0.1, alpha: 0.9).cgColor
  }

  /// progress: 0 at rest, 1 at the trigger threshold (may exceed 1 past it).
  func apply(progress: CGFloat) {
    guard !didPop else { return }
    let p = max(0.0, min(1.0, progress))
    // Fade in faster than it scales so it's visible from the first movement,
    // while the scale keeps growing toward the threshold.
    alpha = min(1.0, p * 1.7)
    let angle = (1.0 - p) * (.pi / 5.0)  // rotate 36° -> 0° as it locks in
    let scale = 0.2 + (0.8 * p)  // grows from tiny to full
    transform = CGAffineTransform(rotationAngle: -angle).scaledBy(x: scale, y: scale)
  }

  func pop() {
    guard !didPop else { return }
    didPop = true
    alpha = 1.0

    // 1) Springy bounce — low damping for a lively overshoot.
    UIView.animate(
      withDuration: 0.55, delay: 0.0, usingSpringWithDamping: 0.42,
      initialSpringVelocity: 0.9, options: [.allowUserInteraction, .beginFromCurrentState],
      animations: { self.transform = CGAffineTransform(scaleX: 1.18, y: 1.18) },
      completion: nil)

    // 2) Burst ring — expands beyond the disc and fades out.
    let ringScale = CABasicAnimation(keyPath: "transform.scale")
    ringScale.fromValue = 0.85
    ringScale.toValue = 2.0
    let ringFade = CABasicAnimation(keyPath: "opacity")
    ringFade.fromValue = 0.9
    ringFade.toValue = 0.0
    let ringGroup = CAAnimationGroup()
    ringGroup.animations = [ringScale, ringFade]
    ringGroup.duration = 0.45
    ringGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
    ringGroup.isRemovedOnCompletion = true
    ringLayer.add(ringGroup, forKey: "ringBurst")

    // 3) Glint shimmer — a highlight sweeps diagonally across the disc once.
    shimmerHost.isHidden = false
    let sweep = CABasicAnimation(keyPath: "position.x")
    sweep.fromValue = -Self.diameter / 2.0
    sweep.toValue = Self.diameter * 1.5
    sweep.duration = 0.5
    sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    sweep.isRemovedOnCompletion = true
    shimmerLayer.add(sweep, forKey: "shimmerSweep")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) { [weak self] in
      self?.shimmerHost.isHidden = true
    }
  }
}

private func isKeyboardHostWindow(_ window: UIWindow) -> Bool {
  let typeName = String(describing: type(of: window))
  return typeName.contains("UIRemoteKeyboardWindow") || typeName.contains("UITextEffectsWindow")
}

private final class ChatKeyboardWindowObserver: NSObject {
  static let shared = ChatKeyboardWindowObserver()

  private weak var keyboardWindow: UIWindow?

  private override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeVisible(_:)),
      name: UIWindow.didBecomeVisibleNotification,
      object: nil
    )
  }

  @objc private func windowDidBecomeVisible(_ notification: Notification) {
    guard let window = notification.object as? UIWindow else { return }
    guard isKeyboardHostWindow(window) else { return }
    keyboardWindow = window
  }

  private func discoverKeyboardWindow() -> UIWindow? {
    // iOS can keep the keyboard in a separate window that may not always be exposed
    // through the current scene's window list. Scan UIApplication windows first.
    for window in UIApplication.shared.windows.reversed() {
      guard isKeyboardHostWindow(window) else { continue }
      return window
    }

    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows.reversed() {
        guard isKeyboardHostWindow(window) else { continue }
        return window
      }
    }
    return nil
  }

  func currentKeyboardWindow() -> UIWindow? {
    if keyboardWindow == nil {
      keyboardWindow = discoverKeyboardWindow()
    }
    guard let keyboardWindow else { return nil }
    guard !keyboardWindow.isHidden, keyboardWindow.alpha > 0.01 else { return nil }
    return keyboardWindow
  }
}

extension ChatListView: UIGestureRecognizerDelegate, ChatContextMenuOverlayDelegate {
  private func holdDebugLog(_ message: String) {
    guard chatHoldDebugLogs else { return }
    NSLog("[ChatHold] %@", message)
  }

  private func resolveContextMenuHostWindow(appWindow: UIWindow) -> UIWindow {
    _ = ChatKeyboardWindowObserver.shared

    if let keyboardWindow = ChatKeyboardWindowObserver.shared.currentKeyboardWindow() {
      return keyboardWindow
    }
    return appWindow
  }

  func installInteractionGestures() {
    // Start observing keyboard windows as early as possible so first open is stable.
    _ = ChatKeyboardWindowObserver.shared

    // A UIScrollView runs an implicit ~150ms timer before it delivers touches to
    // its content / lets other recognizers proceed (WWDC "Advanced Scrollviews
    // and Touch Handling"). That delay is what made the swipe-reply bubble lag
    // behind the finger. Disabling it lets our pan track from the first pixel.
    collectionView.delaysContentTouches = false
    collectionView.canCancelContentTouches = true

    let tap = UITapGestureRecognizer(
      target: self, action: #selector(handleDismissInputTap(_:)))
    tap.delegate = self
    tap.cancelsTouchesInView = false
    tap.delaysTouchesBegan = false
    tap.delaysTouchesEnded = false
    collectionView.addGestureRecognizer(tap)
    dismissInputTapGesture = tap

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipeReplyPan(_:)))
    pan.delegate = self
    pan.maximumNumberOfTouches = 1
    pan.delaysTouchesBegan = false
    pan.delaysTouchesEnded = false
    pan.cancelsTouchesInView = false
    collectionView.addGestureRecognizer(pan)
    swipeReplyPanGesture = pan

    let longPress = UILongPressGestureRecognizer(
      target: self, action: #selector(handleLongPress(_:)))
    // Telegram-like cadence: fast enough for real-time feel without accidental triggers.
    longPress.minimumPressDuration = 0.24
    longPress.allowableMovement = 10.0
    // The hold detector must never hold up touch delivery to the swipe pan: a
    // swipe (movement) and a hold (stationary) are two independent detections.
    // Without these, the long-press can swallow the first touches and the swipe
    // only starts tracking after the hold gives up — felt as lag.
    longPress.delaysTouchesBegan = false
    longPress.delaysTouchesEnded = false
    longPress.cancelsTouchesInView = false
    // Prevent a long-press from also being treated as a tap that dismisses keyboard.
    tap.require(toFail: longPress)
    collectionView.addGestureRecognizer(longPress)
    contextMenuLongPressGesture = longPress
  }

  @objc private func handleDismissInputTap(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended else { return }
    // Ignore dismiss taps that are part of a context-menu hold/open sequence.
    if let longPress = contextMenuLongPressGesture {
      switch longPress.state {
      case .began, .changed, .ended:
        return
      default:
        break
      }
    }
    guard customContextMenuOverlay == nil else { return }
    guard inputBar != nil else { return }
    _ = endEditing(true)
  }

  public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer)
    -> Bool
  {
    guard gestureRecognizer === swipeReplyPanGesture,
      let pan = gestureRecognizer as? UIPanGestureRecognizer
    else {
      return true
    }

    let translation = pan.translation(in: collectionView)
    let velocity = pan.velocity(in: collectionView)
    let translationVertical = abs(translation.y)

    // Reply swipe is LEFTWARD only. Begin the moment a leftward, mostly-
    // horizontal drag is detected; reject rightward/vertical drags so the scroll
    // view keeps handling them.
    if translation.x < -2.0 || translationVertical > 2.0 {
      return -translation.x > translationVertical * 0.9
    }

    let velocityVertical = abs(velocity.y)
    return velocity.x < -8.0 && -velocity.x > velocityVertical * 0.9
  }

  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // Tap-to-dismiss must not run with context-menu long-press.
    if (gestureRecognizer === dismissInputTapGesture
      && otherGestureRecognizer === contextMenuLongPressGesture)
      || (gestureRecognizer === contextMenuLongPressGesture
        && otherGestureRecognizer === dismissInputTapGesture)
    {
      return false
    }
    // Don't allow our swipe-reply pan to run simultaneously with the long-press
    // context menu gesture — this prevents unwanted X movement during hold.
    if (gestureRecognizer === swipeReplyPanGesture
      && otherGestureRecognizer is UILongPressGestureRecognizer)
      || (gestureRecognizer is UILongPressGestureRecognizer
        && otherGestureRecognizer === swipeReplyPanGesture)
    {
      return false
    }
    // Allow simultaneous with scrollView's built-in pan so swiping tracks at 120fps.
    return true
  }

  @objc private func handleSwipeReplyPan(_ gesture: UIPanGestureRecognizer) {
    let location = gesture.location(in: collectionView)
    let translation = gesture.translation(in: collectionView)

    switch gesture.state {
    case .began:
      beginSwipeReply(at: location)
    case .changed:
      updateSwipeReply(translation: translation)
    case .ended, .cancelled, .failed:
      finishSwipeReply()
    default:
      break
    }
  }

  private func beginSwipeReply(at location: CGPoint) {
    resetSwipeReplyTransform(animated: false)
    swipeReplyDidTrigger = false

    guard let indexPath = collectionView.indexPathForItem(at: location),
      indexPath.item < rows.count
    else {
      clearSwipeReplyState()
      return
    }
    let row = rows[indexPath.item]
    guard row.kind == .message, let messageId = row.messageId else {
      clearSwipeReplyState()
      return
    }

    swipeReplyIndexPath = indexPath
    swipeReplyMessageId = messageId
    swipeReplyIsMe = row.isMe

    // Freeze the list for the duration of the reply drag. Without this the scroll
    // view keeps panning/laying out simultaneously and each layout pass fights the
    // cell's transform — which is what made the bubble trail behind the finger.
    // With scrolling off, the transform we set in .changed is the only thing
    // moving the bubble, so it pins to the finger 1:1.
    collectionView.isScrollEnabled = false

    // Rasterize the cell into a bitmap while it's dragged. The bubble background
    // is a live UIVisualEffectView blur; without this it re-samples the wallpaper
    // every frame as it moves, which reads as shimmer/flicker. Caching it as a
    // bitmap (at screen scale, so text stays crisp) makes the slide buttery and
    // solid like Telegram. Cleared again in resetSwipeReplyTransform.
    if let cell = collectionView.cellForItem(at: indexPath) {
      cell.layer.rasterizationScale = window?.screen.scale ?? UIScreen.main.scale
      cell.layer.shouldRasterize = true
    }

    // Build the reply indicator that tracks the drag (Telegram-style). Add it
    // INSIDE the collection view at index 0 — behind the cells but above the
    // wallpaper — so the bubble slides over it to reveal it on the right edge
    // (true "behind" effect) while still being guaranteed visible.
    let icon = ChatSwipeReplyIconView()
    icon.applyTheme(isDark: resolvedAppearance().isDark)
    collectionView.insertSubview(icon, at: 0)
    swipeReplyIconView = icon
  }

  private func updateSwipeReply(translation: CGPoint) {
    guard let indexPath = swipeReplyIndexPath else {
      return
    }

    guard let cell = collectionView.cellForItem(at: indexPath) else { return }

    // Reply swipe is LEFTWARD only. Ignore rightward drags entirely.
    let distance = max(0.0, -translation.x)
    // Rubber-band past the max so the pull feels elastic instead of hitting a wall.
    let visualDistance: CGFloat
    if distance <= swipeReplyMaxOffset {
      visualDistance = distance
    } else {
      visualDistance = swipeReplyMaxOffset + (distance - swipeReplyMaxOffset) * 0.18
    }

    // Set the transform directly (no per-frame CATransaction). A UIView transform
    // doesn't implicitly animate outside an animation block, and the extra commit
    // was adding a redundant render pass that read as flicker.
    cell.transform = CGAffineTransform(translationX: -visualDistance, y: 0.0)

    // Drive the reply indicator (subview of the collection view → content coords).
    // Emerge it from the right edge tracking the gap the bubble opens, so a sliver
    // shows from the very first movement and it settles at its rest spot. Pinning
    // it at a fixed far-right x kept it hidden behind the bubble until the end.
    if let icon = swipeReplyIconView {
      let rightEdge = collectionView.bounds.width
      let restX = rightEdge - 30.0
      let emergeX = rightEdge - (visualDistance * 0.7)
      icon.center = CGPoint(x: max(restX, emergeX), y: cell.frame.midY)
      icon.apply(progress: distance / swipeReplyTrigger)
    }

    guard distance >= swipeReplyTrigger,
      !swipeReplyDidTrigger,
      let messageId = swipeReplyMessageId
    else {
      return
    }
    swipeReplyDidTrigger = true
    swipeReplyIconView?.pop()
    // Harder feedback when the reply locks in: heavy haptic + an audible tick.
    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    AudioServicesPlaySystemSound(1104)
    onNativeEvent([
      "type": "swipeReply",
      "messageId": messageId,
    ])

    // Show reply banner in native input bar
    if let idx = swipeReplyIndexPath?.item, idx < rows.count {
      let row = rows[idx]
      inputBar?.showReplyBanner(messageId: messageId, text: row.text, isMe: row.isMe)
    }
  }

  private func finishSwipeReply() {
    resetSwipeReplyTransform(animated: true)
    clearSwipeReplyState()
  }

  private func resetSwipeReplyTransform(animated: Bool) {
    let icon = swipeReplyIconView
    swipeReplyIconView = nil
    let cell = swipeReplyIndexPath.flatMap { collectionView.cellForItem(at: $0) }
    guard cell != nil || icon != nil else { return }

    let apply = {
      cell?.transform = .identity
      cell?.contentView.transform = .identity
      icon?.alpha = 0.0
      icon?.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
    }
    if animated {
      // Snappy spring return instead of a slow ease-out, so the bubble settles
      // with a lively feel rather than appearing laggy. Keep the cell rasterized
      // through the return so the blur stays smooth, then clear it on completion.
      UIView.animate(
        withDuration: 0.34, delay: 0.0, usingSpringWithDamping: 0.72,
        initialSpringVelocity: 0.5,
        options: [.allowUserInteraction, .beginFromCurrentState],
        animations: apply,
        completion: { _ in
          cell?.layer.shouldRasterize = false
          icon?.removeFromSuperview()
        })
    } else {
      apply()
      cell?.layer.shouldRasterize = false
      icon?.removeFromSuperview()
    }
  }

  private func clearSwipeReplyState() {
    swipeReplyIndexPath = nil
    swipeReplyMessageId = nil
    swipeReplyIsMe = false
    swipeReplyDidTrigger = false
    // Safety: if any path cleared state without going through the reset, make sure
    // the indicator never lingers on screen.
    swipeReplyIconView?.removeFromSuperview()
    swipeReplyIconView = nil
    // Always restore scrolling — this is the single exit point for every swipe path.
    collectionView.isScrollEnabled = true
  }

  private func openContextMenu(at point: CGPoint) {
    guard customContextMenuOverlay == nil else { return }
    guard let indexPath = collectionView.indexPathForItem(at: point),
      let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
    else { return }

    guard indexPath.item < rows.count else { return }
    let row = rows[indexPath.item]
    guard row.kind == .message, let messageId = row.messageId else { return }
    let isMe = row.isMe
    let showResendAction =
      row.isMe && (row.status?.lowercased() == "error" || row.isDeliveryFailed)
    // Regenerate is only offered on errored responses (matches the side button).
    let showRegenerateAction =
      row.isAgentMessage
      && row.isAgentError
      && !row.isStreamingText
      && (row.agentActionSourceId?.isEmpty == false)
      && (row.agentRegeneratePrompt?.isEmpty == false)

    holdDebugLog(
      "openContextMenu begin mid=\(messageId) cellTransform=\(NSCoder.string(for: cell.transform)) contentTransform=\(NSCoder.string(for: cell.contentView.transform))"
    )

    // Hold is a pre-menu pulse only. Force identity before snapshot/open.
    cell.setContextMenuHeld(false, animated: false, strategy: "scaleCell")

    guard let window = window else { return }

    // Snapshot only the bubble+tail (not the full cell row).
    // bubbleSnapshotView already sets the snapshot's frame in window coordinates.
    // It captures at full scale to ensure tail bounding boxes remain mathematically identical.
    guard let bubbleSnapshot = cell.bubbleSnapshotView(in: window) else { return }
    let bubbleFrame = bubbleSnapshot.frame
    holdDebugLog(
      "openContextMenu snapshot mid=\(messageId) bubbleFrame=\(NSCoder.string(for: bubbleFrame))"
    )

    let hostWindow = resolveContextMenuHostWindow(appWindow: window)
    let bubbleFrameInHost =
      hostWindow === window
      ? bubbleFrame
      : hostWindow.convert(bubbleFrame, from: window)
    bubbleSnapshot.frame = bubbleFrameInHost

    let overlay = ChatContextMenuOverlay(
      messageId: messageId,
      bubbleSnapshot: bubbleSnapshot,
      bubbleFrame: bubbleFrameInHost,
      bubbleIsMe: isMe,
      appearance: self.resolvedAppearance(),
      showResendAction: showResendAction,
      showRegenerateAction: showRegenerateAction
    )
    overlay.delegate = self

    overlay.frame = hostWindow.bounds
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    hostWindow.addSubview(overlay)
    self.customContextMenuWindow = nil

    let hostClass = NSStringFromClass(type(of: hostWindow))
    NSLog(
      "[ChatListView] contextMenu hostWindow=%@ level=%.1f keyboardHost=%@",
      hostClass,
      hostWindow.windowLevel.rawValue,
      hostWindow === window ? "N" : "Y"
    )

    // Clear any conflicting swipe reply state when context menu opens
    if customContextMenuOverlay == nil {
      resetSwipeReplyTransform(animated: false)
      clearSwipeReplyState()
    }

    self.customContextMenuOverlay = overlay
    self.contextMenuHostCell = cell
    self.contextMenuHostCellOriginalTransform = .identity

    // Animate In
    overlay.animateIn()

    // Extract right after overlay is in place so we don't get a blank frame/flicker.
    cell.setContextMenuExtracted(true)
    holdDebugLog("openContextMenu extracted mid=\(messageId)")

    self.onNativeEvent(["type": "contextMenuOpened", "messageId": messageId])
  }

  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    switch gesture.state {
    case .began:
      guard customContextMenuOverlay == nil else { return }

      // Cancel any in-progress swipe reply immediately to avoid residual X offset.
      resetSwipeReplyTransform(animated: false)
      clearSwipeReplyState()

      let point = gesture.location(in: collectionView)
      guard let indexPath = collectionView.indexPathForItem(at: point),
        let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
      else { return }
      holdDebugLog(
        "longPress began point=\(NSCoder.string(for: point)) index=\(indexPath.item) cellTransform=\(NSCoder.string(for: cell.transform))"
      )

      // Home-list style: subtle quick press pulse before menu open.
      cell.contentView.transform = .identity
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      cell.setContextMenuHeld(true, animated: true, strategy: "scaleCell")

      // The scale down animation takes 0.18s. We wait exactly that long so the cell
      // reaches its scaled state smoothly, then synchronously pop open the menu.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak cell] in
        guard let self = self else { return }
        guard gesture.state == .began || gesture.state == .changed else {
          self.holdDebugLog("longPress delayed cancel state=\(gesture.state.rawValue)")
          cell?.setContextMenuHeld(false, animated: true, strategy: "scaleCell")
          return
        }
        if self.customContextMenuOverlay != nil {
          cell?.setContextMenuHeld(false, animated: false, strategy: "scaleCell")
          return
        }
        self.holdDebugLog("longPress delayed open state=\(gesture.state.rawValue)")
        self.openContextMenu(at: point)

        if self.customContextMenuOverlay == nil {
          self.holdDebugLog("longPress delayed open failed")
          cell?.setContextMenuHeld(false, animated: true, strategy: "scaleCell")
        }
      }

    case .ended, .cancelled, .failed:
      holdDebugLog(
        "longPress end state=\(gesture.state.rawValue) overlay=\(customContextMenuOverlay != nil)")
      if customContextMenuOverlay == nil {
        let point = gesture.location(in: collectionView)
        if let indexPath = collectionView.indexPathForItem(at: point),
          let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
        {
          cell.setContextMenuHeld(false, animated: true, strategy: "scaleCell")
        }
      }

    default:
      break
    }
  }

  @available(iOS 13.0, *)
  public func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    return nil
  }

  // MARK: - ChatContextMenuOverlayDelegate

  public func contextMenuDidDismiss(overlay: ChatContextMenuOverlay) {
    holdDebugLog("contextMenuDidDismiss")
    if let cell = contextMenuHostCell as? ChatListCell {
      cell.setContextMenuHeld(false, animated: false, strategy: "scaleCell")
      cell.setContextMenuExtracted(false)
      cell.transform = contextMenuHostCellOriginalTransform
    }
    contextMenuHostCell = nil
    customContextMenuOverlay = nil

    customContextMenuWindow?.isHidden = true
    customContextMenuWindow = nil
  }

  public func contextMenuDidSelectReaction(
    _ reaction: String,
    messageId: String,
    sourcePoint: CGPoint?
  ) {
    holdDebugLog(
      "contextMenuDidSelectReaction id=\(messageId) emoji=\(reaction) source=\(sourcePoint.map { NSCoder.string(for: $0) } ?? "nil")"
    )
    var resolvedSourcePoint = sourcePoint
    if let window, let hostCell = contextMenuHostCell as? ChatListCell,
      let badgePoint = hostCell.reactionBadgeCenter(in: window)
    {
      resolvedSourcePoint = badgePoint
    }
    let resolvedMessageId = messageId
    applyLocalReactionEmoji(reaction, toMessageId: resolvedMessageId)

    let emitReactionEvent = { [weak self] in
      guard let self else { return }
      var payload: [String: Any] = [
        "type": "contextMenuReaction",
        "emoji": reaction,
        "messageId": resolvedMessageId,
      ]
      if let resolvedSourcePoint {
        payload["sourceX"] = resolvedSourcePoint.x
        payload["sourceY"] = resolvedSourcePoint.y
      }
      self.holdDebugLog(
        "emit contextMenuReaction id=\(resolvedMessageId) emoji=\(reaction) source=\(resolvedSourcePoint.map { NSCoder.string(for: $0) } ?? "nil")"
      )
      self.onNativeEvent(payload)
    }

    // Overlay handles icon flight first. Dispatch reaction only after dismiss so
    // the final native FX is visible above chat content, not behind the overlay.
    if customContextMenuOverlay != nil {
      customContextMenuOverlay?.animateOut(reason: "reaction", completion: emitReactionEvent)
    } else {
      emitReactionEvent()
    }
  }

  public func contextMenuDidSelectAction(_ actionId: String, messageId _: String) {
    guard let overlay = customContextMenuOverlay else { return }
    let mid = overlay.messageId

    if actionId == "delete" {
      if let row = rows.first(where: { $0.messageId == mid }),
         let hostCell = self.contextMenuHostCell as? ChatListCell {
         self.showDeleteDialog(for: mid, row: row, cell: hostCell)
      }
      overlay.animateOut(reason: "action:\(actionId)", completion: nil)
      return
    }

    if actionId == "select" {
      self.beginMessageSelection(messageId: mid)
      overlay.animateOut(reason: "action:\(actionId)", completion: nil)
      return
    }

    overlay.animateOut(reason: "action:\(actionId)", completion: nil)

    onNativeEvent([
      "type": "contextMenuAction",
      "action": actionId,
      "messageId": mid,
    ])

    if let row = rows.first(where: { $0.messageId == mid }) {
      if actionId == "reply" {
        inputBar?.showReplyBanner(messageId: mid, text: row.text, isMe: row.isMe)
      } else if actionId == "copy" {
        UIPasteboard.general.string = row.plainContent ?? row.text
      } else if actionId == "resend" {
        retryOutgoingMessage(row: row, source: "context_menu")
      } else if actionId == "regenerate" {
        let sourceMessageId = row.agentActionSourceId ?? ""
        if !sourceMessageId.isEmpty {
          onNativeEvent([
            "type": "agentMessageAction",
            "action": "regenerate",
            "sourceMessageId": sourceMessageId,
            "sourceText": row.agentActionSourceText ?? row.plainContent ?? row.text,
            "regeneratePrompt": row.agentRegeneratePrompt ?? "",
          ])
        }
      }
    }
  }

  func dismissCustomContextMenu(animated: Bool) {
    guard let overlay = customContextMenuOverlay else { return }

    let cleanup = { [weak self] in
      overlay.removeFromSuperview()
      self?.customContextMenuOverlay = nil
      if let hostCell = self?.contextMenuHostCell as? ChatListCell {
        hostCell.setContextMenuHeld(
          false, animated: false, strategy: "scaleCell")
        hostCell.setContextMenuExtracted(false)
        hostCell.transform = self?.contextMenuHostCellOriginalTransform ?? .identity
        self?.contextMenuHostCell = nil
        self?.contextMenuHostCellOriginalTransform = .identity
      }
    }

    if animated {
      overlay.animateOut(reason: "dismiss", completion: cleanup)
    } else {
      cleanup()
    }
  }
}

// MARK: - Message Deletion Dialog & Wipe Overlay

private var deleteDialogControllerKey: UInt8 = 0

extension ChatListView {
  private var deleteDialogController: UIViewController? {
    get { objc_getAssociatedObject(self, &deleteDialogControllerKey) as? UIViewController }
    set { objc_setAssociatedObject(self, &deleteDialogControllerKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }

  fileprivate func showDeleteDialog(for messageId: String, row: ChatListRow, cell: ChatListCell) {
    let dialogView = ChatMessageDeleteDialogView(
      isDark: self.resolvedAppearance().isDark,
      deleteForMe: { [weak self] in
        self?.executeMessageDeletion(messageId: messageId, row: row, cell: cell, deleteForEveryone: false)
      },
      deleteForEveryone: { [weak self] in
        self?.executeMessageDeletion(messageId: messageId, row: row, cell: cell, deleteForEveryone: true)
      },
      cancel: { [weak self] in
        self?.dismissDeleteDialog()
      }
    )
    let hostingController = UIHostingController(rootView: dialogView)
    hostingController.view.backgroundColor = .clear
    hostingController.view.frame = self.bounds
    hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    
    self.addSubview(hostingController.view)
    self.deleteDialogController = hostingController
  }

  private func dismissDeleteDialog() {
    self.deleteDialogController?.view.removeFromSuperview()
    self.deleteDialogController = nil
  }

  private func executeMessageDeletion(messageId: String, row: ChatListRow, cell: ChatListCell, deleteForEveryone: Bool) {
    dismissDeleteDialog()

    // 1. Show the wipe overlay
    if let snapshot = cell.bubbleSnapshotView(in: self) {
       let overlay = ChatMessageDeletionWipeOverlayView(frame: self.bounds, snapshot: snapshot, isDark: self.resolvedAppearance().isDark)
       self.addSubview(overlay)
       overlay.animateAndRemove()
       
       // Hide the actual cell content so it doesn't show behind the wipe
       cell.isHidden = true
       DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
           cell.isHidden = false
       }
    }

    // 2. Perform deletion natively via ChatEngine
    let chatId = row.chatId ?? ""
    ChatEngine.shared.deleteMessage([
      "chatId": chatId,
      "messageId": messageId,
      "skipRemoteDelete": !deleteForEveryone
    ])
  }
}

private struct ChatMessageDeleteDialogView: View {
  let isDark: Bool
  let deleteForMe: () -> Void
  let deleteForEveryone: () -> Void
  let cancel: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.3)
        .ignoresSafeArea()
        .onTapGesture { cancel() }
      
      VStack(spacing: 0) {
        Text("Delete Message")
          .font(.headline)
          .foregroundColor(isDark ? .white : .black)
          .padding(.top, 20)
          .padding(.bottom, 12)
        
        Button(role: .destructive, action: deleteForEveryone) {
          Text("Delete for everyone")
            .foregroundColor(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        Divider()
        Button(role: .destructive, action: deleteForMe) {
          Text("Delete for me")
            .foregroundColor(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        Divider()
        Button(role: .cancel, action: cancel) {
          Text("Cancel")
            .foregroundColor(isDark ? .white : .black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
      }
      .background(ChatGlassEffectView(cornerRadius: 24))
      .padding(40)
    }
  }
}

private struct ChatGlassEffectView: UIViewRepresentable {
  let cornerRadius: CGFloat
  func makeUIView(context: Context) -> UIVisualEffectView {
    let view = UIVisualEffectView(effect: nil)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = true
      view.effect = glass
      view.contentView.backgroundColor = .clear
    } else {
      view.effect = UIBlurEffect(style: .systemThinMaterial)
    }
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
    return view
  }
  func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

private final class ChatMessageDeletionWipeOverlayView: UIView {
  private let snapshotContainer = UIView()
  private let emitter = CAEmitterLayer()

  init(frame: CGRect, snapshot: UIView, isDark: Bool) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = false

    snapshotContainer.frame = snapshot.frame
    addSubview(snapshotContainer)

    snapshot.frame = snapshotContainer.bounds
    snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    snapshotContainer.addSubview(snapshot)

    emitter.emitterPosition = CGPoint(x: snapshotContainer.bounds.width, y: snapshotContainer.bounds.midY)
    emitter.emitterSize = CGSize(width: 1, height: snapshotContainer.bounds.height)
    emitter.emitterShape = .line

    let cell = CAEmitterCell()
    cell.contents = createParticleImage(isDark: isDark)?.cgImage
    cell.birthRate = 6000
    cell.lifetime = 0.55
    cell.velocity = 500
    cell.velocityRange = 250
    cell.emissionLongitude = .pi // Point left
    cell.emissionRange = .pi / 6 // Slight spread
    cell.scale = 0.2
    cell.scaleRange = 0.1
    cell.scaleSpeed = -0.3
    cell.alphaSpeed = -1.5
    cell.yAcceleration = -400 // Go to top

    emitter.emitterCells = [cell]
    snapshotContainer.layer.addSublayer(emitter)
  }

  required init?(coder: NSCoder) { fatalError() }

  func animateAndRemove() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
      self.emitter.birthRate = 0
    }

    let maskLayer = CAGradientLayer()
    maskLayer.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
    maskLayer.locations = [0.0, 0.05]
    maskLayer.startPoint = CGPoint(x: 1.0, y: 0.5) // Start right
    maskLayer.endPoint = CGPoint(x: 0.0, y: 0.5)   // End left
    maskLayer.frame = snapshotContainer.bounds
    snapshotContainer.layer.mask = maskLayer

    let duration: TimeInterval = 0.55

    let maskAnimation = CABasicAnimation(keyPath: "locations")
    maskAnimation.fromValue = [-0.1, 0.0]
    maskAnimation.toValue = [1.0, 1.1]
    maskAnimation.duration = duration * 0.8
    maskAnimation.fillMode = .forwards
    maskAnimation.isRemovedOnCompletion = false
    maskLayer.add(maskAnimation, forKey: "maskWipe")

    let moveEmitterAnimation = CABasicAnimation(keyPath: "emitterPosition.x")
    moveEmitterAnimation.fromValue = snapshotContainer.bounds.width
    moveEmitterAnimation.toValue = 0
    moveEmitterAnimation.duration = duration * 0.8
    moveEmitterAnimation.fillMode = .forwards
    moveEmitterAnimation.isRemovedOnCompletion = false
    emitter.add(moveEmitterAnimation, forKey: "moveEmitter")

    UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut, animations: {
      // Dissolves perfectly in place, no transform
    }) { _ in
      self.removeFromSuperview()
    }
  }

  private func createParticleImage(isDark: Bool) -> UIImage? {
    let size = CGSize(width: 1, height: 4)
    UIGraphicsBeginImageContextWithOptions(size, false, 0)
    guard let context = UIGraphicsGetCurrentContext() else { return nil }
    context.setFillColor(isDark ? UIColor.white.withAlphaComponent(0.9).cgColor : UIColor.black.withAlphaComponent(0.9).cgColor)
    context.fill(CGRect(origin: .zero, size: size))
    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image
  }
}
