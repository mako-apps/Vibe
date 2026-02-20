import UIKit

// ---------------------------------------------------------------------------
// Telegram-style send transition.
//
// Uses Telegram's 0.3s split-axis timing curves and adds:
//   1) source input/background ghost fade-out
//   2) source text ghost fade-out
//   3) destination bubble fade-in + frame morph
//
// Telegram source: ChatMessageTransitionNode.swift
//   Vertical curve:   (0.199, 0.0106, 0.279, 0.910)
//   Horizontal curve:  (0.23, 1.0, 0.32, 1.0)
//   Duration: 0.3s
// ---------------------------------------------------------------------------

private let transitionDuration: CFTimeInterval = 0.3

private func makeTimingFunction(_ c1x: Float, _ c1y: Float, _ c2x: Float, _ c2y: Float)
  -> CAMediaTimingFunction
{
  CAMediaTimingFunction(controlPoints: c1x, c1y, c2x, c2y)
}

/// Horizontal timing — fast ease-out (matches Telegram's `horizontalAnimationCurve`).
private let horizontalTiming = makeTimingFunction(0.23, 1.0, 0.32, 1.0)

/// Vertical timing — slow-start with overshoot feel (matches Telegram's `verticalAnimationCurve`).
private let verticalTiming = makeTimingFunction(
  Float(0.19919472913616398),
  Float(0.010644531250000006),
  Float(0.27920937042459737),
  Float(0.91025390625)
)

final class SendTransitionState: NSObject {
  weak var host: ChatListView?
  let payload: SendTransitionPayload
  let overlayContainer: UIView
  private let bubbleSnapshot: UIView
  private let sourceBackgroundSnapshot: UIView?
  private let sourceTextSnapshot: UIView?
  private let bubbleStartFrame: CGRect
  private let bubbleEndFrame: CGRect
  private let sourceBackgroundStartFrame: CGRect?
  private let sourceBackgroundEndFrame: CGRect?
  private let sourceTextStartFrame: CGRect?
  private let sourceTextEndFrame: CGRect?

  init(
    host: ChatListView,
    payload: SendTransitionPayload,
    overlayContainer: UIView,
    bubbleSnapshot: UIView,
    sourceBackgroundSnapshot: UIView?,
    sourceTextSnapshot: UIView?,
    bubbleStartFrame: CGRect,
    bubbleEndFrame: CGRect,
    sourceBackgroundStartFrame: CGRect?,
    sourceBackgroundEndFrame: CGRect?,
    sourceTextStartFrame: CGRect?,
    sourceTextEndFrame: CGRect?
  ) {
    self.host = host
    self.payload = payload
    self.overlayContainer = overlayContainer
    self.bubbleSnapshot = bubbleSnapshot
    self.sourceBackgroundSnapshot = sourceBackgroundSnapshot
    self.sourceTextSnapshot = sourceTextSnapshot
    self.bubbleStartFrame = bubbleStartFrame
    self.bubbleEndFrame = bubbleEndFrame
    self.sourceBackgroundStartFrame = sourceBackgroundStartFrame
    self.sourceBackgroundEndFrame = sourceBackgroundEndFrame
    self.sourceTextStartFrame = sourceTextStartFrame
    self.sourceTextEndFrame = sourceTextEndFrame
    super.init()
  }

  private func addScalarAnimation(
    layer: CALayer,
    keyPath: String,
    from: CGFloat,
    to: CGFloat,
    duration: CFTimeInterval,
    timing: CAMediaTimingFunction,
    key: String
  ) {
    let anim = CABasicAnimation(keyPath: keyPath)
    anim.fromValue = from as NSNumber
    anim.toValue = to as NSNumber
    anim.duration = duration
    anim.timingFunction = timing
    anim.isRemovedOnCompletion = true
    layer.add(anim, forKey: key)
  }

  private func addFrameAnimation(layer: CALayer, from: CGRect, to: CGRect, keyPrefix: String) {
    addScalarAnimation(
      layer: layer,
      keyPath: "position.x",
      from: from.midX,
      to: to.midX,
      duration: transitionDuration,
      timing: horizontalTiming,
      key: "\(keyPrefix).positionX")
    addScalarAnimation(
      layer: layer,
      keyPath: "position.y",
      from: from.midY,
      to: to.midY,
      duration: transitionDuration,
      timing: verticalTiming,
      key: "\(keyPrefix).positionY")
    addScalarAnimation(
      layer: layer,
      keyPath: "bounds.size.width",
      from: from.width,
      to: to.width,
      duration: transitionDuration,
      timing: horizontalTiming,
      key: "\(keyPrefix).width")
    addScalarAnimation(
      layer: layer,
      keyPath: "bounds.size.height",
      from: from.height,
      to: to.height,
      duration: transitionDuration,
      timing: verticalTiming,
      key: "\(keyPrefix).height")
  }

  /// Kick off Telegram-style split-axis motion + source/bubble crossfade.
  ///
  /// Telegram's crossfade has three overlapping opacity layers:
  ///   - Source background (input pill): fades 1→0 over ~0.18s
  ///   - Source text (input text):       fades 1→0 over ~0.16s starting at 0.02s
  ///   - Bubble snapshot (target):       fades 0→1 over ~0.18s starting at 0.04s
  ///
  /// The key is the **overlap window** (~0.12s) where both source and target
  /// are partially visible, creating a true crossfade rather than a pop.
  func start(sourceRect: CGRect, targetRect: CGRect) {
    // Place overlay at target position (final destination).
    overlayContainer.frame = targetRect

    // Compute deltas from source to target.
    // Telegram uses maxY for vertical alignment (bottom-anchored).
    let dx = sourceRect.minX - targetRect.minX
    let dy = sourceRect.maxY - targetRect.maxY

    // X position — horizontal curve
    let animX = CABasicAnimation(keyPath: "position.x")
    animX.fromValue = dx as NSNumber
    animX.toValue = 0.0 as NSNumber
    animX.isAdditive = true
    animX.duration = transitionDuration
    animX.timingFunction = horizontalTiming
    animX.isRemovedOnCompletion = true
    overlayContainer.layer.add(animX, forKey: "sendTransitionX")

    // Y position — vertical curve
    let animY = CABasicAnimation(keyPath: "position.y")
    animY.fromValue = dy as NSNumber
    animY.toValue = 0.0 as NSNumber
    animY.isAdditive = true
    animY.duration = transitionDuration
    animY.timingFunction = verticalTiming
    animY.isRemovedOnCompletion = true
    animY.delegate = self
    overlayContainer.layer.add(animY, forKey: "sendTransitionY")

    // ── Bubble snapshot: morph frame + crossfade in ──
    // Starts at 0.04s delay, fades in over 0.18s — overlaps with source fade-out.
    bubbleSnapshot.frame = bubbleEndFrame
    addFrameAnimation(
      layer: bubbleSnapshot.layer,
      from: bubbleStartFrame,
      to: bubbleEndFrame,
      keyPrefix: "bubble")
    bubbleSnapshot.layer.opacity = 0.0
    let bubbleFadeIn = CABasicAnimation(keyPath: "opacity")
    bubbleFadeIn.fromValue = 0.0
    bubbleFadeIn.toValue = 1.0
    bubbleFadeIn.beginTime = CACurrentMediaTime() + 0.04
    bubbleFadeIn.duration = 0.18
    bubbleFadeIn.timingFunction = CAMediaTimingFunction(name: .easeIn)
    bubbleFadeIn.fillMode = .backwards
    bubbleFadeIn.isRemovedOnCompletion = false
    bubbleSnapshot.layer.add(bubbleFadeIn, forKey: "bubbleFadeIn")
    bubbleSnapshot.layer.opacity = 1.0

    // ── Source background ghost: morphs frame + fades out ──
    // Starts immediately, fades over 0.18s — overlaps with bubble fade-in.
    if
      let sourceBackgroundSnapshot,
      let sourceBackgroundStartFrame,
      let sourceBackgroundEndFrame
    {
      sourceBackgroundSnapshot.frame = sourceBackgroundEndFrame
      addFrameAnimation(
        layer: sourceBackgroundSnapshot.layer,
        from: sourceBackgroundStartFrame,
        to: sourceBackgroundEndFrame,
        keyPrefix: "sourceBackground")
      sourceBackgroundSnapshot.layer.opacity = 1.0
      let bgFadeOut = CABasicAnimation(keyPath: "opacity")
      bgFadeOut.fromValue = 1.0
      bgFadeOut.toValue = 0.0
      bgFadeOut.duration = 0.18
      bgFadeOut.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      bgFadeOut.isRemovedOnCompletion = false
      bgFadeOut.fillMode = .forwards
      sourceBackgroundSnapshot.layer.add(bgFadeOut, forKey: "bgFadeOut")
      sourceBackgroundSnapshot.layer.opacity = 0.0
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
        sourceBackgroundSnapshot.removeFromSuperview()
      }
    }

    // ── Source text ghost: morphs frame + crossfades out ──
    // Starts at 0.02s, fades over 0.16s — the text dissolves as bubble text appears.
    if
      let sourceTextSnapshot,
      let sourceTextStartFrame,
      let sourceTextEndFrame
    {
      sourceTextSnapshot.frame = sourceTextEndFrame
      addFrameAnimation(
        layer: sourceTextSnapshot.layer,
        from: sourceTextStartFrame,
        to: sourceTextEndFrame,
        keyPrefix: "sourceText")
      sourceTextSnapshot.layer.opacity = 1.0
      let textFadeOut = CABasicAnimation(keyPath: "opacity")
      textFadeOut.fromValue = 1.0
      textFadeOut.toValue = 0.0
      textFadeOut.beginTime = CACurrentMediaTime() + 0.02
      textFadeOut.duration = 0.16
      textFadeOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
      textFadeOut.fillMode = .backwards
      textFadeOut.isRemovedOnCompletion = false
      sourceTextSnapshot.layer.add(textFadeOut, forKey: "textFadeOut")
      sourceTextSnapshot.layer.opacity = 0.0
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
        sourceTextSnapshot.removeFromSuperview()
      }
    }
  }

  /// Called by the host when the list scrolls during animation.
  /// Because the position animation is additive, we just need to
  /// update the model frame to track the cell's real position.
  func compensateScroll(targetRect: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    overlayContainer.frame = targetRect
    CATransaction.commit()
  }

  func invalidate() {
    overlayContainer.layer.removeAllAnimations()
    bubbleSnapshot.layer.removeAllAnimations()
    sourceBackgroundSnapshot?.layer.removeAllAnimations()
    sourceTextSnapshot?.layer.removeAllAnimations()
  }
}

// MARK: - CAAnimationDelegate (completion)
extension SendTransitionState: CAAnimationDelegate {
  func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
    host?.completeTransition(self)
  }
}
