import ExpoModulesCore
import UIKit

final class NativeGlobalMusicPlayerView: ExpoView {
  private let bannerView = NativeMusicPlayerBannerView()
  private var stateObserver: NSObjectProtocol?
  private var voiceObserver: NSObjectProtocol?
  private var enginePayload: [String: Any] = NativeMusicPlayerEngine.shared.getStatePayload()
  private var voiceSnapshot = VoiceBubblePlaybackCoordinator.shared.currentSnapshot
  private var isDark = true
  private var surfaceColor = UIColor(white: 0.08, alpha: 1.0)
  private var textColor = UIColor.white
  private var textSecondaryColor = UIColor(white: 1.0, alpha: 0.68)
  private var primaryColor = UIColor.systemBlue
  private var topInset: CGFloat = 0.0
  private var voiceIsExpanded = false

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = false
    backgroundColor = .clear

    addSubview(bannerView)
    bannerView.onTogglePlayback = { [weak self] in
      guard let self else { return }
      if self.shouldRenderVoiceSnapshot {
        VoiceBubblePlaybackCoordinator.shared.toggleCurrentPlayback()
        return
      }
      let engine = NativeMusicPlayerEngine.shared
      engine.setIsPlaying(!((engine.getStatePayload()["isPlaying"] as? Bool) ?? false))
    }
    bannerView.onClose = { [weak self] in
      guard let self else { return }
      if self.shouldRenderVoiceSnapshot {
        self.voiceIsExpanded = false
        VoiceBubblePlaybackCoordinator.shared.stopCurrentPlayback()
        return
      }
      NativeMusicPlayerEngine.shared.reset()
    }
    bannerView.onSetExpanded = { [weak self] expanded in
      guard let self else { return }
      if self.shouldRenderVoiceSnapshot {
        self.voiceIsExpanded = expanded
        self.applyResolvedState()
        return
      }
      NativeMusicPlayerEngine.shared.setIsExpanded(expanded)
    }
    bannerView.onPlayNext = { [weak self] in
      guard let self else { return }
      if self.shouldRenderVoiceSnapshot {
        VoiceBubblePlaybackCoordinator.shared.playNextTrack()
        return
      }
      NativeMusicPlayerEngine.shared.playNext()
    }
    bannerView.onPlayPrev = { [weak self] in
      guard let self else { return }
      if self.shouldRenderVoiceSnapshot {
        VoiceBubblePlaybackCoordinator.shared.playPreviousTrack()
        return
      }
      NativeMusicPlayerEngine.shared.playPrev()
    }
    bannerView.onPlaybackRateToggle = { [weak self] in
      guard let self, !self.shouldRenderVoiceSnapshot else { return }
      let currentRate =
        (NativeMusicPlayerEngine.shared.getStatePayload()["playbackRate"] as? NSNumber)?.doubleValue
        ?? (NativeMusicPlayerEngine.shared.getStatePayload()["playbackRate"] as? Double)
        ?? 1.0
      let rates: [Double] = [1.0, 1.5, 2.0]
      let index = rates.firstIndex(where: { abs($0 - currentRate) < 0.05 }) ?? 0
      let next = rates[(index + 1) % rates.count]
      NativeMusicPlayerEngine.shared.setPlaybackRate(next)
    }
    bannerView.onSeek = { [weak self] value in
      guard let self else { return }
      if self.shouldRenderVoiceSnapshot {
        VoiceBubblePlaybackCoordinator.shared.seek(toSeconds: value / 1000.0)
        return
      }
      NativeMusicPlayerEngine.shared.seek(toMilliseconds: value)
    }
    bannerView.onSelectTrack = { [weak self] trackId in
      guard let self else { return }
      if self.shouldRenderVoiceSnapshot {
        VoiceBubblePlaybackCoordinator.shared.selectQueuedTrack(trackId)
        return
      }
      NativeMusicPlayerEngine.shared.selectTrack(trackId)
    }

    stateObserver = NotificationCenter.default.addObserver(
      forName: .nativeMusicPlayerStateDidChange,
      object: NativeMusicPlayerEngine.shared,
      queue: .main
    ) { [weak self] notification in
      guard let payload = notification.userInfo?["payload"] as? [String: Any] else { return }
      self?.enginePayload = payload
      self?.applyResolvedState()
    }

    voiceObserver = NotificationCenter.default.addObserver(
      forName: .voiceBubblePlaybackDidChange,
      object: VoiceBubblePlaybackCoordinator.shared,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.voiceSnapshot = VoiceBubblePlaybackCoordinator.shared.currentSnapshot
      if !(self.voiceSnapshot.presentsGlobalPlayer && self.voiceSnapshot.messageId != nil) {
        self.voiceIsExpanded = false
      }
      self.applyResolvedState()
    }

    applyTheme()
    applyResolvedState()
  }

  deinit {
    if let stateObserver {
      NotificationCenter.default.removeObserver(stateObserver)
    }
    if let voiceObserver {
      NotificationCenter.default.removeObserver(voiceObserver)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    bannerView.frame = bounds
    bannerView.setTopInset(topInset)
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bannerView.containsInteractivePoint(point)
  }

  func setIsDark(_ value: Bool) {
    guard isDark != value else { return }
    isDark = value
    applyTheme()
  }

  func setSurfaceColor(_ value: String?) {
    if let value = UIColor.nativeMusicColor(from: value) {
      surfaceColor = value
      applyTheme()
    }
  }

  func setTextColor(_ value: String?) {
    if let value = UIColor.nativeMusicColor(from: value) {
      textColor = value
      applyTheme()
    }
  }

  func setTextSecondaryColor(_ value: String?) {
    if let value = UIColor.nativeMusicColor(from: value) {
      textSecondaryColor = value
      applyTheme()
    }
  }

  func setPrimaryColor(_ value: String?) {
    if let value = UIColor.nativeMusicColor(from: value) {
      primaryColor = value
      applyTheme()
    }
  }

  func setTopInset(_ value: Double) {
    let next = CGFloat(value)
    guard abs(topInset - next) > 0.5 else { return }
    topInset = next
    setNeedsLayout()
  }

  private func applyTheme() {
    bannerView.applyTheme(
      NativeMusicPlayerTheme(
        isDark: isDark,
        surface: surfaceColor,
        text: textColor,
        secondaryText: textSecondaryColor,
        primary: primaryColor
      )
    )
  }

  private var shouldRenderVoiceSnapshot: Bool {
    voiceSnapshot.presentsGlobalPlayer && voiceSnapshot.messageId != nil
  }

  private func applyResolvedState() {
    if shouldRenderVoiceSnapshot {
      bannerView.applyVoiceSnapshot(voiceSnapshot, isExpanded: voiceIsExpanded)
    } else {
      bannerView.applyStatePayload(enginePayload)
    }
    setNeedsLayout()
  }
}

public final class NativeGlobalMusicPlayerModule: Module {
  private var stateObserver: NSObjectProtocol?

  deinit {
    if let stateObserver {
      NotificationCenter.default.removeObserver(stateObserver)
    }
  }

  public func definition() -> ModuleDefinition {
    Name("NativeGlobalMusicPlayer")

    OnCreate {
      self.stateObserver = NotificationCenter.default.addObserver(
        forName: .nativeMusicPlayerStateDidChange,
        object: NativeMusicPlayerEngine.shared,
        queue: .main
      ) { [weak self] notification in
        guard let payload = notification.userInfo?["payload"] as? [String: Any] else { return }
        self?.sendEvent("onPlaybackState", payload)
      }
    }

    OnDestroy {
      if let stateObserver = self.stateObserver {
        NotificationCenter.default.removeObserver(stateObserver)
        self.stateObserver = nil
      }
    }

    Events("onPlaybackState")

    Function("isSupported") {
      true
    }

    Function("getState") {
      NativeMusicPlayerEngine.shared.getStatePayload()
    }

    Function("setQueue") { (payload: [[String: Any]]) in
      NativeMusicPlayerEngine.shared.setQueue(payload)
    }

    Function("setTrack") { (payload: [String: Any]) in
      NativeMusicPlayerEngine.shared.setTrack(payload)
    }

    Function("setIsPlaying") { (value: Bool) in
      NativeMusicPlayerEngine.shared.setIsPlaying(value)
    }

    Function("setIsExpanded") { (value: Bool) in
      NativeMusicPlayerEngine.shared.setIsExpanded(value)
    }

    Function("setPlaybackRate") { (value: Double) in
      NativeMusicPlayerEngine.shared.setPlaybackRate(value)
    }

    Function("playNext") {
      NativeMusicPlayerEngine.shared.playNext()
    }

    Function("playPrev") {
      NativeMusicPlayerEngine.shared.playPrev()
    }

    Function("reset") {
      NativeMusicPlayerEngine.shared.reset()
    }

    Function("seekTo") { (milliseconds: Double) in
      NativeMusicPlayerEngine.shared.seek(toMilliseconds: milliseconds)
    }

    Function("cacheTrack") { (payload: [String: Any]) -> Any in
      if let track = NativeMusicPlayerEngine.shared.cacheTrack(payload) {
        return track
      }
      return NSNull()
    }

    Function("getTrack") { (trackId: String) -> Any in
      if let track = NativeMusicPlayerEngine.shared.getTrack(trackId) {
        return track
      }
      return NSNull()
    }

    Function("removeTrack") { (trackId: String) in
      NativeMusicPlayerEngine.shared.removeTrack(trackId)
    }

    AsyncFunction("downloadTrack") { (payload: [String: Any], promise: Promise) in
      NativeMusicPlayerEngine.shared.downloadTrack(payload) { result in
        promise.resolve(result)
      }
    }

    View(NativeGlobalMusicPlayerView.self) {
      Prop("isDark") { (view: NativeGlobalMusicPlayerView, value: Bool) in
        view.setIsDark(value)
      }

      Prop("surfaceColor") { (view: NativeGlobalMusicPlayerView, value: String?) in
        view.setSurfaceColor(value)
      }

      Prop("textColor") { (view: NativeGlobalMusicPlayerView, value: String?) in
        view.setTextColor(value)
      }

      Prop("textSecondaryColor") { (view: NativeGlobalMusicPlayerView, value: String?) in
        view.setTextSecondaryColor(value)
      }

      Prop("primaryColor") { (view: NativeGlobalMusicPlayerView, value: String?) in
        view.setPrimaryColor(value)
      }

      Prop("topInset") { (view: NativeGlobalMusicPlayerView, value: Double?) in
        view.setTopInset(value ?? 0.0)
      }
    }
  }
}

private extension UIColor {
  static func nativeMusicColor(from value: String?) -> UIColor? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    if raw.hasPrefix("#") {
      let hex = String(raw.dropFirst())
      guard hex.count == 6, let number = Int(hex, radix: 16) else { return nil }
      return UIColor(
        red: CGFloat((number >> 16) & 0xff) / 255.0,
        green: CGFloat((number >> 8) & 0xff) / 255.0,
        blue: CGFloat(number & 0xff) / 255.0,
        alpha: 1.0
      )
    }
    return nil
  }
}
