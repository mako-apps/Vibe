import UIKit

// ---------------------------------------------------------------------------
// TelegramSendMorphProfile: "All in one" handling for the list morph bubbles/input
// ---------------------------------------------------------------------------

public enum TelegramSendMorphProfile {
  static let duration: CFTimeInterval = 0.36

  static let horizontalTiming = CAMediaTimingFunction(
    controlPoints: Float(0.23), Float(1.0), Float(0.32), Float(1.0)
  )
  static let verticalTiming = CAMediaTimingFunction(
    controlPoints: Float(0.19919472913616398), Float(0.010644531250000006),
    Float(0.27920937042459737), Float(0.91025390625)
  )

  // The bubble plate comes in early but with a short beat of delay and a
  // gentle build, so the morph neither reads as a transparent glass shape
  // waiting for the real cell nor snaps to a hard solid block. The envelope's
  // uniform corner radius keeps masking the plate's baked corners being
  // stretched by the width morph until the shape has settled.
  static let bubbleFadeFrom: Float = 0.0
  static let bubbleFadeDelay: CFTimeInterval = 0.045
  static let bubbleFadeDuration: CFTimeInterval = 0.15

  static let sourceBackgroundFadeDelay: CFTimeInterval = 0.045
  static let sourceBackgroundFadeDuration: CFTimeInterval = 0.15

  // The envelope holds the bubble's uniform radius through the crossfade and
  // only releases to the plate's baked asymmetric corners + tail at the end.
  static let clipRadiusSettleFraction: Float = 0.45
  static let clipRadiusReleaseFraction: Float = 0.78

  // Composer text and bubble text ride the same path and crossfade midway,
  // top-left coincident, so the glyphs appear to morph in place.
  static let textCrossfadeDelay: CFTimeInterval = 0.10
  static let textCrossfadeMaxDelay: CFTimeInterval = 0.16
  static let textCrossfadeDuration: CFTimeInterval = 0.12

  // Timestamp + status tick never travel: they fade in at their final
  // placement while the bubble is settling. Kept quick so they snap in with
  // the plate rather than lagging visibly behind it.
  static let metaFadeDelay: CFTimeInterval = 0.155
  static let metaFadeDuration: CFTimeInterval = 0.07

  // The tail is a constant-size, vector-matched lobe that RIDES the plate's
  // bottom-trailing corner as the bubble forms — it never gets width/height
  // morphed (no stretch) and it is present-and-moving while the bubble is still
  // forming (no end-of-flight pop). It eases in mid-morph, once the clip
  // envelope has settled to the bubble's 18pt corner radius (clipRadiusSettle
  // ≈ 0.45× → 0.16s), which is exactly the corner the Android tail contour is
  // designed to splice into, then glides into final placement with the corner.
  static let tailFadeDelay: CFTimeInterval = 0.15
  static let tailFadeDuration: CFTimeInterval = 0.12
}

final class SendTransitionState: NSObject {
  weak var host: ChatListView?
  let payload: SendTransitionPayload
  let overlayContainer: UIView
  let clippingView: UIView
  let sourceBackgroundSnapshot: UIView
  let bubbleBackgroundSnapshot: UIView
  let destinationContentSnapshot: UIView
  let sourceTextSnapshot: UIView?
  let metaSnapshot: UIView?
  let tailSnapshot: UIView?
  // Additive from-offset that makes the tail ride the plate's bottom-trailing
  // corner: at t=0 the tail sits at (final + this offset) = the plate's START
  // corner, and it animates the offset to zero on the same timing as the plate
  // frame, so it stays glued to the moving corner. nil = a separate-view media
  // tail (pinned at final placement, opacity-only, old behavior).
  let tailCornerTravel: CGSize?
  let sourceBackgroundStartFrame: CGRect
  let sourceBackgroundEndFrame: CGRect
  let sourceContentStartFrame: CGRect
  let destinationContentFrame: CGRect
  let sourceScrollOffset: CGFloat

  init(
    host: ChatListView,
    payload: SendTransitionPayload,
    overlayContainer: UIView,
    clippingView: UIView,
    sourceBackgroundSnapshot: UIView,
    bubbleBackgroundSnapshot: UIView,
    destinationContentSnapshot: UIView,
    sourceTextSnapshot: UIView?,
    metaSnapshot: UIView?,
    tailSnapshot: UIView?,
    tailCornerTravel: CGSize?,
    sourceBackgroundStartFrame: CGRect,
    sourceBackgroundEndFrame: CGRect,
    sourceContentStartFrame: CGRect,
    destinationContentFrame: CGRect,
    sourceScrollOffset: CGFloat
  ) {
    self.host = host
    self.payload = payload
    self.overlayContainer = overlayContainer
    self.clippingView = clippingView
    self.sourceBackgroundSnapshot = sourceBackgroundSnapshot
    self.bubbleBackgroundSnapshot = bubbleBackgroundSnapshot
    self.destinationContentSnapshot = destinationContentSnapshot
    self.sourceTextSnapshot = sourceTextSnapshot
    self.metaSnapshot = metaSnapshot
    self.tailSnapshot = tailSnapshot
    self.tailCornerTravel = tailCornerTravel
    self.sourceBackgroundStartFrame = sourceBackgroundStartFrame
    self.sourceBackgroundEndFrame = sourceBackgroundEndFrame
    self.sourceContentStartFrame = sourceContentStartFrame
    self.destinationContentFrame = destinationContentFrame
    self.sourceScrollOffset = sourceScrollOffset
    super.init()
  }

  private func addScalarAnimation(
    layer: CALayer,
    keyPath: String,
    from: CGFloat,
    to: CGFloat,
    duration: CFTimeInterval,
    timing: CAMediaTimingFunction,
    key: String,
    additive: Bool = false
  ) {
    let anim = CABasicAnimation(keyPath: keyPath)
    anim.fromValue = from as NSNumber
    anim.toValue = to as NSNumber
    anim.duration = duration
    anim.timingFunction = timing
    anim.isAdditive = additive
    anim.isRemovedOnCompletion = true
    layer.add(anim, forKey: key)
  }

  private func addFrameAnimation(layer: CALayer, from: CGRect, to: CGRect, keyPrefix: String) {
    addScalarAnimation(
      layer: layer, keyPath: "position.x", from: from.midX, to: to.midX,
      duration: TelegramSendMorphProfile.duration,
      timing: TelegramSendMorphProfile.horizontalTiming, key: "\(keyPrefix).positionX")
    addScalarAnimation(
      layer: layer, keyPath: "position.y", from: from.midY, to: to.midY,
      duration: TelegramSendMorphProfile.duration, timing: TelegramSendMorphProfile.verticalTiming,
      key: "\(keyPrefix).positionY")
    addScalarAnimation(
      layer: layer, keyPath: "bounds.size.width", from: from.width, to: to.width,
      duration: TelegramSendMorphProfile.duration,
      timing: TelegramSendMorphProfile.horizontalTiming, key: "\(keyPrefix).width")
    addScalarAnimation(
      layer: layer, keyPath: "bounds.size.height", from: from.height, to: to.height,
      duration: TelegramSendMorphProfile.duration, timing: TelegramSendMorphProfile.verticalTiming,
      key: "\(keyPrefix).height")
  }

  private func addBoundsPositionAnimation(
    layer: CALayer, startBounds: CGRect, endBounds: CGRect, startPos: CGPoint, endPos: CGPoint,
    keyPrefix: String
  ) {
    addScalarAnimation(
      layer: layer, keyPath: "position.x", from: startPos.x, to: endPos.x,
      duration: TelegramSendMorphProfile.duration,
      timing: TelegramSendMorphProfile.horizontalTiming, key: "\(keyPrefix).posX")
    addScalarAnimation(
      layer: layer, keyPath: "position.y", from: startPos.y, to: endPos.y,
      duration: TelegramSendMorphProfile.duration, timing: TelegramSendMorphProfile.verticalTiming,
      key: "\(keyPrefix).posY")
    addScalarAnimation(
      layer: layer, keyPath: "bounds.size.width", from: startBounds.width, to: endBounds.width,
      duration: TelegramSendMorphProfile.duration,
      timing: TelegramSendMorphProfile.horizontalTiming, key: "\(keyPrefix).bgW")
    addScalarAnimation(
      layer: layer, keyPath: "bounds.size.height", from: startBounds.height, to: endBounds.height,
      duration: TelegramSendMorphProfile.duration, timing: TelegramSendMorphProfile.verticalTiming,
      key: "\(keyPrefix).bgH")
  }

  private func addOpacityAnimation(
    layer: CALayer,
    from: Float,
    to: Float,
    delay: CFTimeInterval,
    duration: CFTimeInterval,
    timing: CAMediaTimingFunction,
    key: String
  ) {
    let anim = CABasicAnimation(keyPath: "opacity")
    anim.fromValue = from
    anim.toValue = to
    anim.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
    anim.duration = duration
    anim.timingFunction = timing
    anim.fillMode = .both
    anim.isRemovedOnCompletion = true
    layer.add(anim, forKey: key)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = to
    CATransaction.commit()
  }

  func start(sourceRect: CGRect, targetRect: CGRect) {
    overlayContainer.frame = targetRect

    let dx = sourceRect.minX - targetRect.minX
    let dy = sourceRect.maxY - targetRect.maxY

    let animX = CABasicAnimation(keyPath: "position.x")
    animX.fromValue = dx as NSNumber
    animX.toValue = 0.0 as NSNumber
    animX.isAdditive = true
    animX.duration = TelegramSendMorphProfile.duration
    animX.timingFunction = TelegramSendMorphProfile.horizontalTiming
    animX.isRemovedOnCompletion = true
    overlayContainer.layer.add(animX, forKey: "sendTransitionX")

    let animY = CABasicAnimation(keyPath: "position.y")
    animY.fromValue = dy as NSNumber
    animY.toValue = 0.0 as NSNumber
    animY.isAdditive = true
    animY.duration = TelegramSendMorphProfile.duration
    animY.timingFunction = TelegramSendMorphProfile.verticalTiming
    animY.isRemovedOnCompletion = true
    animY.delegate = self
    overlayContainer.layer.add(animY, forKey: "sendTransitionY")

    // Morph the clipping envelope
    clippingView.frame = sourceBackgroundEndFrame
    addFrameAnimation(
      layer: clippingView.layer, from: sourceBackgroundStartFrame, to: sourceBackgroundEndFrame,
      keyPrefix: "clipEnvelope")

    // Morph background views inside clipping envelope
    let startBounds = CGRect(origin: .zero, size: sourceBackgroundStartFrame.size)
    let endBounds = CGRect(origin: .zero, size: sourceBackgroundEndFrame.size)
    let startPos = CGPoint(
      x: sourceBackgroundStartFrame.width / 2, y: sourceBackgroundStartFrame.height / 2)
    let endPos = CGPoint(
      x: sourceBackgroundEndFrame.width / 2, y: sourceBackgroundEndFrame.height / 2)

    sourceBackgroundSnapshot.bounds = endBounds
    sourceBackgroundSnapshot.center = endPos
    addBoundsPositionAnimation(
      layer: sourceBackgroundSnapshot.layer, startBounds: startBounds, endBounds: endBounds,
      startPos: startPos, endPos: endPos, keyPrefix: "sourceBgMorph")

    bubbleBackgroundSnapshot.bounds = endBounds
    bubbleBackgroundSnapshot.center = endPos
    addBoundsPositionAnimation(
      layer: bubbleBackgroundSnapshot.layer, startBounds: startBounds, endBounds: endBounds,
      startPos: startPos, endPos: endPos, keyPrefix: "bubbleBgMorph")

    addOpacityAnimation(
      layer: sourceBackgroundSnapshot.layer,
      from: 1.0,
      to: 0.0,
      delay: TelegramSendMorphProfile.sourceBackgroundFadeDelay,
      duration: TelegramSendMorphProfile.sourceBackgroundFadeDuration,
      timing: CAMediaTimingFunction(name: .easeOut),
      key: "sourceBgFadeOut"
    )

    addOpacityAnimation(
      layer: bubbleBackgroundSnapshot.layer,
      from: TelegramSendMorphProfile.bubbleFadeFrom,
      to: 1.0,
      delay: TelegramSendMorphProfile.bubbleFadeDelay,
      duration: TelegramSendMorphProfile.bubbleFadeDuration,
      // easeOut: the plate rises quickly then settles gently into full
      // opacity, so it reads as color right away without a hard pop at the end.
      timing: CAMediaTimingFunction(name: .easeOut),
      key: "destBgFadeIn"
    )

    // The envelope's uniform cornerRadius owns the visible rounding for most
    // of the flight: it eases from the composer capsule to the bubble radius,
    // holds it there while the plate crossfades in (hiding the plate's baked
    // corners being stretched), and only releases to zero at the end so the
    // real asymmetric corners and tail take over un-clipped.
    let startRadius = min(sourceBackgroundStartFrame.height / 2.0, 22.0)
    let destRadius = min(sourceBackgroundEndFrame.height / 2.0, 18.0)
    clippingView.layer.cornerRadius = 0
    clippingView.layer.cornerCurve = .continuous
    let radiusAnim = CAKeyframeAnimation(keyPath: "cornerRadius")
    radiusAnim.values = [startRadius, destRadius, destRadius, 0.0]
    radiusAnim.keyTimes = [
      0.0,
      NSNumber(value: TelegramSendMorphProfile.clipRadiusSettleFraction),
      NSNumber(value: TelegramSendMorphProfile.clipRadiusReleaseFraction),
      1.0,
    ]
    radiusAnim.timingFunctions = [
      TelegramSendMorphProfile.horizontalTiming,
      CAMediaTimingFunction(name: .linear),
      CAMediaTimingFunction(name: .easeInEaseOut),
    ]
    radiusAnim.duration = TelegramSendMorphProfile.duration
    radiusAnim.isRemovedOnCompletion = true
    clippingView.layer.add(radiusAnim, forKey: "clipEnvelope.radius")

    // Composer text and bubble text ride the same path, top-left aligned, and
    // crossfade midway so the glyphs appear to morph in place instead of the
    // source dying at the composer while the destination flies off alone.
    let srcSize = sourceContentStartFrame.size
    let destSize = destinationContentFrame.size

    let srcStartRelativePos = CGPoint(
      x: sourceContentStartFrame.midX - sourceBackgroundStartFrame.minX,
      y: sourceContentStartFrame.midY - sourceBackgroundStartFrame.minY
    )
    let destEndRelativePos = CGPoint(
      x: destinationContentFrame.midX - sourceBackgroundEndFrame.minX,
      y: destinationContentFrame.midY - sourceBackgroundEndFrame.minY
    )
    let srcEndRelativePos = CGPoint(
      x: destEndRelativePos.x - destSize.width / 2.0 + srcSize.width / 2.0,
      y: destEndRelativePos.y - destSize.height / 2.0 + srcSize.height / 2.0
    )
    let destStartRelativePos = CGPoint(
      x: srcStartRelativePos.x - srcSize.width / 2.0 + destSize.width / 2.0,
      y: srcStartRelativePos.y - srcSize.height / 2.0 + destSize.height / 2.0 - sourceScrollOffset
    )

    // Tall sends push the crossfade slightly later so the incoming text is
    // not readable outside the still-short envelope.
    let heightExpansion = max(
      0.0, sourceBackgroundEndFrame.height - sourceBackgroundStartFrame.height)
    let textCrossfadeDelay = min(
      TelegramSendMorphProfile.textCrossfadeMaxDelay,
      TelegramSendMorphProfile.textCrossfadeDelay
        + CFTimeInterval(min(1.0, heightExpansion / 180.0)) * 0.05
    )

    if let sourceTextSnapshot {
      sourceTextSnapshot.bounds = CGRect(origin: .zero, size: srcSize)
      sourceTextSnapshot.center = srcEndRelativePos
      addScalarAnimation(
        layer: sourceTextSnapshot.layer, keyPath: "position.x", from: srcStartRelativePos.x,
        to: srcEndRelativePos.x,
        duration: TelegramSendMorphProfile.duration,
        timing: TelegramSendMorphProfile.horizontalTiming, key: "sourceText.posX")
      addScalarAnimation(
        layer: sourceTextSnapshot.layer, keyPath: "position.y", from: srcStartRelativePos.y,
        to: srcEndRelativePos.y,
        duration: TelegramSendMorphProfile.duration, timing: TelegramSendMorphProfile.verticalTiming,
        key: "sourceText.posY")
      addOpacityAnimation(
        layer: sourceTextSnapshot.layer,
        from: 1.0,
        to: 0.0,
        delay: textCrossfadeDelay,
        duration: TelegramSendMorphProfile.textCrossfadeDuration,
        timing: CAMediaTimingFunction(name: .easeInEaseOut),
        key: "sourceTextFadeOut"
      )
    }

    destinationContentSnapshot.bounds = CGRect(origin: .zero, size: destSize)
    destinationContentSnapshot.center = destEndRelativePos
    destinationContentSnapshot.layer.opacity = 0.0

    addScalarAnimation(
      layer: destinationContentSnapshot.layer, keyPath: "position.x", from: destStartRelativePos.x, to: destEndRelativePos.x,
      duration: TelegramSendMorphProfile.duration,
      timing: TelegramSendMorphProfile.horizontalTiming, key: "destContent.positionX")
    addScalarAnimation(
      layer: destinationContentSnapshot.layer, keyPath: "position.y", from: destStartRelativePos.y, to: destEndRelativePos.y,
      duration: TelegramSendMorphProfile.duration, timing: TelegramSendMorphProfile.verticalTiming,
      key: "destContent.positionY")

    addOpacityAnimation(
      layer: destinationContentSnapshot.layer,
      from: 0.0,
      to: 1.0,
      delay: textCrossfadeDelay,
      duration: TelegramSendMorphProfile.textCrossfadeDuration,
      timing: CAMediaTimingFunction(name: .easeInEaseOut),
      key: "destContentFadeIn"
    )

    // Timestamp + status tick: no travel — they fade in at their final
    // placement once the bubble has essentially settled.
    if let metaSnapshot {
      addOpacityAnimation(
        layer: metaSnapshot.layer,
        from: 0.0,
        to: 1.0,
        delay: TelegramSendMorphProfile.metaFadeDelay,
        duration: TelegramSendMorphProfile.metaFadeDuration,
        timing: CAMediaTimingFunction(name: .easeIn),
        key: "metaFadeIn"
      )
    }

    // Tail: a constant-size vector lobe outside the clip envelope. For
    // integrated-tail bubbles it RIDES the plate's bottom-trailing corner
    // (additive position on the plate's own timing) so it is glued to the
    // forming bubble instead of popping in at a fixed final spot; it just eases
    // its opacity in mid-morph once the corner has settled to 18pt. Media tails
    // (no corner travel) keep the pinned opacity-only reveal.
    if let tailSnapshot {
      if let travel = tailCornerTravel {
        addScalarAnimation(
          layer: tailSnapshot.layer, keyPath: "position.x",
          from: travel.width, to: 0.0,
          duration: TelegramSendMorphProfile.duration,
          timing: TelegramSendMorphProfile.horizontalTiming, key: "tail.trackX",
          additive: true)
        addScalarAnimation(
          layer: tailSnapshot.layer, keyPath: "position.y",
          from: travel.height, to: 0.0,
          duration: TelegramSendMorphProfile.duration,
          timing: TelegramSendMorphProfile.verticalTiming, key: "tail.trackY",
          additive: true)
      }
      addOpacityAnimation(
        layer: tailSnapshot.layer,
        from: 0.0,
        to: 1.0,
        delay: TelegramSendMorphProfile.tailFadeDelay,
        duration: TelegramSendMorphProfile.tailFadeDuration,
        timing: CAMediaTimingFunction(name: .easeOut),
        key: "tailFadeIn"
      )
    }
  }

  func compensateScroll(targetRect: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    overlayContainer.frame = targetRect
    CATransaction.commit()
  }

  func invalidate() {
    overlayContainer.layer.removeAllAnimations()
    clippingView.layer.removeAllAnimations()
    sourceBackgroundSnapshot.layer.removeAllAnimations()
    bubbleBackgroundSnapshot.layer.removeAllAnimations()
    destinationContentSnapshot.layer.removeAllAnimations()
    sourceTextSnapshot?.layer.removeAllAnimations()
    metaSnapshot?.layer.removeAllAnimations()
    tailSnapshot?.layer.removeAllAnimations()
  }
}

extension SendTransitionState: CAAnimationDelegate {
  func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
    host?.completeTransition(self)
  }
}

enum SendTransitionOverlayFactory {
  struct Result {
    let container: UIView
    let clippingView: UIView
    let sourceBackgroundSnapshot: UIView
    let bubbleBackgroundSnapshot: UIView
    let destinationContentSnapshot: UIView
    let sourceTextSnapshot: UIView?
    let metaSnapshot: UIView?
    let tailSnapshot: UIView?
    let tailCornerTravel: CGSize?
    let sourceBackgroundStartFrame: CGRect
    let sourceBackgroundEndFrame: CGRect
    let sourceContentStartFrame: CGRect
    let destinationContentFrame: CGRect
    let sourceScrollOffset: CGFloat
    let sourceRect: CGRect
  }

  private static func mapSourceRectToContainer(
    _ sourceRect: CGRect, motionSourceRect: CGRect, targetRect: CGRect
  ) -> CGRect {
    let startContainerOriginY = motionSourceRect.maxY - targetRect.height
    return CGRect(
      x: sourceRect.minX - motionSourceRect.minX,
      y: sourceRect.minY - startContainerOriginY,
      width: max(1.0, sourceRect.width),
      height: max(1.0, sourceRect.height)
    )
  }

  private static func makeRenderedSnapshotView(
    from sourceView: UIView, captureRect: CGRect, targetFrame: CGRect
  ) -> UIView? {
    guard captureRect.width > 1.0, captureRect.height > 1.0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = UIScreen.main.scale
    let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)
    let image = renderer.image { context in
      context.cgContext.translateBy(x: -captureRect.minX, y: -captureRect.minY)
      if !sourceView.drawHierarchy(in: sourceView.bounds, afterScreenUpdates: true) {
        sourceView.layer.render(in: context.cgContext)
      }
    }
    let imageView = UIImageView(image: image)
    imageView.frame = targetFrame
    imageView.backgroundColor = .clear
    imageView.isOpaque = false
    imageView.clipsToBounds = false
    return imageView
  }

  private enum BubbleSnapshotPart {
    case text
    case meta
  }

  private static func makeContentSnapshot(
    snapshotCell: ChatListCell, captureRect: CGRect, targetFrame: CGRect,
    part: BubbleSnapshotPart
  ) -> UIView? {
    // Text and meta (timestamp/status icons) are captured separately: the
    // text travels with the composer text and crossfades mid-flight, while
    // meta fades in at its final placement at the end of the morph.
    let hiddenViews: [UIView]
    switch part {
    case .text:
      hiddenViews = [
        snapshotCell.bubbleView, snapshotCell.tailView, snapshotCell.metaContainerView,
      ]
    case .meta:
      // The capture rect is confined to metaContainerView's frame, which the
      // cell layout reserves for meta alone, so only the plate needs hiding.
      hiddenViews = [snapshotCell.bubbleView, snapshotCell.tailView]
    }
    let savedHidden = hiddenViews.map(\.isHidden)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hiddenViews.forEach { $0.isHidden = true }
    snapshotCell.contentView.layoutIfNeeded()
    CATransaction.commit()
    defer {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for (view, wasHidden) in zip(hiddenViews, savedHidden) {
        view.isHidden = wasHidden
      }
      snapshotCell.contentView.layoutIfNeeded()
      CATransaction.commit()
    }
    if let rendered = makeRenderedSnapshotView(
      from: snapshotCell.contentView, captureRect: captureRect, targetFrame: targetFrame)
    {
      return rendered
    }
    if let snapshot = snapshotCell.contentView.resizableSnapshotView(
      from: captureRect, afterScreenUpdates: false, withCapInsets: .zero)
    {
      snapshot.frame = targetFrame
      return snapshot
    }
    return nil
  }

  static func make(
    appearance: ChatListAppearance,
    snapshotCell: ChatListCell,
    targetBubbleRect: CGRect,
    payload: SendTransitionPayload,
    hostView: UIView
  ) -> Result {
    let motionSourceRect = payload.resolvedSourceBackgroundRect.integral
    let container = UIView()
    container.isUserInteractionEnabled = false
    container.clipsToBounds = false

    guard let captureRects = snapshotCell.transitionBubbleCaptureRects() else {
      let fallbackBg = UIView(frame: CGRect(origin: .zero, size: targetBubbleRect.size))
      let fallbackBubbleColor =
        appearance.bubbleMeGradient.first
        ?? appearance.bubbleThemColor
      fallbackBg.backgroundColor = fallbackBubbleColor.withAlphaComponent(1.0)
      fallbackBg.layer.cornerRadius = 18.0
      fallbackBg.layer.cornerCurve = .continuous

      let sourceBg = UIView(frame: fallbackBg.bounds)
      sourceBg.backgroundColor = fallbackBubbleColor.withAlphaComponent(1.0)
      sourceBg.layer.cornerRadius = 18.0
      sourceBg.layer.cornerCurve = .continuous

      let fallbackContentFrame = fallbackBg.frame.insetBy(dx: 12, dy: 9)
      let fallbackContent = UILabel(frame: fallbackContentFrame)
      fallbackContent.font = UIFont.systemFont(ofSize: 16)
      fallbackContent.textColor = appearance.textColorThem.withAlphaComponent(0.95)
      fallbackContent.text = payload.text
      fallbackContent.numberOfLines = 0

      let clippingView = UIView(frame: fallbackBg.frame)
      clippingView.clipsToBounds = true
      clippingView.addSubview(sourceBg)
      clippingView.addSubview(fallbackBg)
      container.addSubview(clippingView)
      container.addSubview(fallbackContent)

      return SendTransitionOverlayFactory.Result(
        container: container,
        clippingView: clippingView,
        sourceBackgroundSnapshot: sourceBg,
        bubbleBackgroundSnapshot: fallbackBg,
        destinationContentSnapshot: fallbackContent,
        sourceTextSnapshot: nil,
        metaSnapshot: nil,
        tailSnapshot: nil,
        tailCornerTravel: nil,
        sourceBackgroundStartFrame: fallbackBg.frame,
        sourceBackgroundEndFrame: fallbackBg.frame,
        sourceContentStartFrame: fallbackContentFrame,
        destinationContentFrame: fallbackContentFrame,
        sourceScrollOffset: payload.sourceScrollOffset,
        sourceRect: payload.resolvedSourceBackgroundRect
      )
    }

    let bubbleBodyRect = captureRects.bubbleBodyRect
    // Plate only — the tail is overlaid separately so the morph can't stretch it.
    let fullCaptureRect = captureRects.plateRect
    var contentCaptureRect = captureRects.contentRect.intersection(fullCaptureRect)
    if contentCaptureRect.isNull || contentCaptureRect.width <= 1.0
      || contentCaptureRect.height <= 1.0
    {
      contentCaptureRect = bubbleBodyRect.insetBy(dx: 10, dy: 6)
    }
    contentCaptureRect = contentCaptureRect.integral

    let bubbleBackgroundEndFrame = CGRect(
      x: fullCaptureRect.minX - bubbleBodyRect.minX,
      y: fullCaptureRect.minY - bubbleBodyRect.minY,
      width: fullCaptureRect.width,
      height: fullCaptureRect.height
    )

    let destinationContentFrame = CGRect(
      x: contentCaptureRect.minX - bubbleBodyRect.minX,
      y: contentCaptureRect.minY - bubbleBodyRect.minY,
      width: contentCaptureRect.width,
      height: contentCaptureRect.height
    )

    let sourceBackgroundRect = payload.resolvedSourceBackgroundRect.integral
    let sourceContentRect = payload.resolvedSourceContentRect.integral

    let sourceBackgroundStartFrame = mapSourceRectToContainer(
      sourceBackgroundRect, motionSourceRect: motionSourceRect, targetRect: targetBubbleRect)
    let sourceContentStartFrame = mapSourceRectToContainer(
      sourceContentRect, motionSourceRect: motionSourceRect, targetRect: targetBubbleRect)

    let bubbleBackgroundSnapshot: UIView = {
      if let snapshot = snapshotCell.bubbleBackgroundSnapshotView(in: snapshotCell.contentView) {
        snapshot.frame = bubbleBackgroundEndFrame
        return snapshot
      }
      let fallback = UIView(frame: bubbleBackgroundEndFrame)
      fallback.backgroundColor =
        appearance.bubbleMeGradient.first
        ?? appearance.bubbleThemColor.withAlphaComponent(1.0)
      fallback.layer.cornerCurve = .continuous
      fallback.layer.cornerRadius = 18.0
      return fallback
    }()

    let sourceBackgroundSnapshot: UIView = {
      if let snapshot = payload.sourceBackgroundSnapshotView {
        snapshot.frame = CGRect(origin: .zero, size: sourceBackgroundStartFrame.size)
        snapshot.contentMode = .scaleToFill
        return snapshot
      }
      let replica = BubbleBackgroundView(frame: CGRect(origin: .zero, size: sourceBackgroundStartFrame.size))
      let isMe = snapshotCell.row?.isMe ?? true
      let radius = min(sourceBackgroundStartFrame.height / 2.0, 18.0)
      replica.configure(isMe: isMe, shape: BubbleShape(
        isMe: isMe, showTail: false, borderTopLeftRadius: radius, borderTopRightRadius: radius,
        borderBottomLeftRadius: radius, borderBottomRightRadius: radius), hidden: false, appearance: appearance)
      
      if let wallpaper = snapshotCell.bubbleView.wallpaperSnapshot {
        replica.applyWallpaperBackdrop(
          snapshot: wallpaper,
          containerSize: snapshotCell.bubbleView.wallpaperContainerSize,
          sampleRect: snapshotCell.bubbleView.wallpaperSampleRect
        )
      }

      replica.setNeedsLayout()
      replica.layoutIfNeeded()

      let imageView = UIImageView(image: replica.renderToImage())
      imageView.frame = CGRect(origin: .zero, size: sourceBackgroundStartFrame.size)
      imageView.contentMode = .scaleToFill
      return imageView
    }()

    let relativeDestinationContentFrame = CGRect(
      x: destinationContentFrame.minX - bubbleBackgroundEndFrame.minX,
      y: destinationContentFrame.minY - bubbleBackgroundEndFrame.minY,
      width: destinationContentFrame.width,
      height: destinationContentFrame.height
    )

    let destinationContentSnapshot: UIView = {
      if let contentOnly = makeContentSnapshot(
        snapshotCell: snapshotCell, captureRect: contentCaptureRect,
        targetFrame: relativeDestinationContentFrame, part: .text)
      {
        return contentOnly
      }
      let label = UILabel(frame: relativeDestinationContentFrame)
      label.font = UIFont.systemFont(ofSize: 16)
      label.textColor = appearance.textColorThem.withAlphaComponent(0.95)
      label.textAlignment = .left
      label.numberOfLines = 0
      label.text = payload.text
      return label
    }()

    let relativeSourceContentFrame = CGRect(
      x: sourceContentStartFrame.minX - sourceBackgroundStartFrame.minX,
      y: sourceContentStartFrame.minY - sourceBackgroundStartFrame.minY,
      width: sourceContentStartFrame.width,
      height: sourceContentStartFrame.height
    )

    let sourceTextSnapshot: UIView? = {
      if let snapshot = payload.sourceContentSnapshotView {
        snapshot.frame = relativeSourceContentFrame
        return snapshot
      }
      if let contentFallback = makeContentSnapshot(
        snapshotCell: snapshotCell,
        captureRect: contentCaptureRect,
        targetFrame: relativeSourceContentFrame,
        part: .text
      ) {
        return contentFallback
      }
      let trimmedText = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedText.isEmpty else {
        return nil
      }
      let label = UILabel(frame: relativeSourceContentFrame)
      label.font = UIFont.systemFont(ofSize: 16)
      label.textColor = appearance.textColorThem.withAlphaComponent(0.95)
      label.textAlignment = .left
      label.numberOfLines = 1
      label.lineBreakMode = .byTruncatingTail
      label.text = trimmedText
      return label
    }()

    // Meta (timestamp + status tick) is anchored at its end placement
    // relative to the envelope so it never travels with the text; it just
    // fades in there once the bubble has essentially settled.
    let metaSnapshot: UIView? = {
      let metaCaptureRect = captureRects.metaRect
      guard !metaCaptureRect.isNull, metaCaptureRect.width > 1.0, metaCaptureRect.height > 1.0
      else {
        return nil
      }
      let relativeMetaFrame = CGRect(
        x: metaCaptureRect.minX - bubbleBodyRect.minX - bubbleBackgroundEndFrame.minX,
        y: metaCaptureRect.minY - bubbleBodyRect.minY - bubbleBackgroundEndFrame.minY,
        width: metaCaptureRect.width,
        height: metaCaptureRect.height
      )
      return makeContentSnapshot(
        snapshotCell: snapshotCell, captureRect: metaCaptureRect.integral,
        targetFrame: relativeMetaFrame, part: .meta)
    }()

    // Tail lives OUTSIDE the clipping envelope at its exact final frame — it
    // must never be part of the plate that gets width/height-morphed, or it
    // stretches/shifts during the flight and lands with a jump.
    let tailBuild: (view: UIView, cornerTravel: CGSize?)? = {
      // Integrated-tail bubbles (normal text sends): the cell hands out the
      // tail lobe as a masked snapshot complementary to the tail-suppressed
      // plate raster — plate ∪ lobe equals the real bubble render exactly, so
      // revealing the real cell at completion cannot shift the tail. The lobe
      // rides the plate's bottom-trailing corner (cornerTravel) as it forms.
      if let integrated = snapshotCell.transitionTailSnapshotView() {
        integrated.view.frame = integrated.frameInContent.offsetBy(
          dx: -bubbleBodyRect.minX, dy: -bubbleBodyRect.minY)
        let isMe = snapshotCell.row?.isMe ?? true
        let travel: CGSize
        if isMe {
          travel = CGSize(
            width: sourceBackgroundStartFrame.maxX - bubbleBackgroundEndFrame.maxX,
            height: sourceBackgroundStartFrame.maxY - bubbleBackgroundEndFrame.maxY)
        } else {
          travel = CGSize(
            width: sourceBackgroundStartFrame.minX - bubbleBackgroundEndFrame.minX,
            height: sourceBackgroundStartFrame.maxY - bubbleBackgroundEndFrame.maxY)
        }
        return (integrated.view, travel)
      }
      // Separate BubbleTailView (full-bleed media): render + display it at its
      // EXACT bounds size so the raster is shown 1:1 — any width/height
      // difference between render and frame scales the image and produces a
      // ~1px height snap when the real tail is revealed at completeTransition.
      let tailRect = captureRects.tailRect
      guard !tailRect.isNull, tailRect.width > 1.0, tailRect.height > 1.0 else { return nil }
      let tailBounds = snapshotCell.tailView.bounds
      let relativeTailFrame = CGRect(
        x: tailRect.minX - bubbleBodyRect.minX,
        y: tailRect.minY - bubbleBodyRect.minY,
        width: tailBounds.width,
        height: tailBounds.height
      )
      guard
        let view = makeRenderedSnapshotView(
          from: snapshotCell.tailView,
          captureRect: tailBounds,
          targetFrame: relativeTailFrame
        )
      else { return nil }
      return (view, nil)
    }()
    let tailSnapshot = tailBuild?.view
    let tailCornerTravel = tailBuild?.cornerTravel

    let clippingView = UIView(frame: sourceBackgroundStartFrame)
    clippingView.clipsToBounds = true
    clippingView.isUserInteractionEnabled = false

    bubbleBackgroundSnapshot.layer.opacity = TelegramSendMorphProfile.bubbleFadeFrom

    clippingView.addSubview(sourceBackgroundSnapshot)
    clippingView.addSubview(bubbleBackgroundSnapshot)
    container.addSubview(clippingView)

    if let tailSnapshot {
      tailSnapshot.layer.opacity = 0.0
      container.addSubview(tailSnapshot)
    }

    if let sourceTextSnapshot {
      sourceTextSnapshot.layer.opacity = 1.0
      clippingView.addSubview(sourceTextSnapshot)
    }

    destinationContentSnapshot.layer.opacity = 0.0
    clippingView.addSubview(destinationContentSnapshot)

    if let metaSnapshot {
      metaSnapshot.layer.opacity = 0.0
      clippingView.addSubview(metaSnapshot)
    }

    return Result(
      container: container,
      clippingView: clippingView,
      sourceBackgroundSnapshot: sourceBackgroundSnapshot,
      bubbleBackgroundSnapshot: bubbleBackgroundSnapshot,
      destinationContentSnapshot: destinationContentSnapshot,
      sourceTextSnapshot: sourceTextSnapshot,
      metaSnapshot: metaSnapshot,
      tailSnapshot: tailSnapshot,
      tailCornerTravel: tailCornerTravel,
      sourceBackgroundStartFrame: sourceBackgroundStartFrame,
      sourceBackgroundEndFrame: bubbleBackgroundEndFrame,
      sourceContentStartFrame: sourceContentStartFrame,
      destinationContentFrame: destinationContentFrame,
      sourceScrollOffset: payload.sourceScrollOffset,
      sourceRect: motionSourceRect
    )
  }
}
