#if canImport(Lottie)
import Lottie
#else
import UIKit

enum LottieLoopMode {
  case loop
}

enum LottieBackgroundBehavior {
  case pauseAndRestore
}

final class LottieAnimation {
  static func filepath(_ path: String) -> LottieAnimation? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    return nil
  }
}

final class LottieAnimationView: UIView {
  var animation: LottieAnimation?
  var loopMode: LottieLoopMode = .loop
  var backgroundBehavior: LottieBackgroundBehavior = .pauseAndRestore
  private(set) var isAnimationPlaying = false

  override init(frame: CGRect) {
    super.init(frame: frame)
  }

  convenience init(animation: LottieAnimation?) {
    self.init(frame: .zero)
    self.animation = animation
  }

  required init?(coder: NSCoder) { nil }

  func play() {
    isAnimationPlaying = animation != nil
  }

  func pause() {
    isAnimationPlaying = false
  }

  func stop() {
    isAnimationPlaying = false
  }
}
#endif
