import Foundation
import UIKit

final class VibeNativeCallUiCoordinator {
  static let shared = VibeNativeCallUiCoordinator()

  private weak var module: VibeNativeCallModule?
  private var overlayWindow: UIWindow?
  private weak var controller: VibeNativeCallScreenController?
  private var state: [String: Any] = [:]

  private init() {}

  func attach(module: VibeNativeCallModule) {
    self.module = module
  }

  func detach(module: VibeNativeCallModule) {
    if self.module === module {
      self.module = nil
    }
  }

  func setState(_ payload: [String: Any]) {
    state = payload
    DispatchQueue.main.async {
      self.applyStateOnMain(payload)
    }
  }

  func hide() {
    DispatchQueue.main.async {
      self.overlayWindow?.rootViewController = nil
      self.overlayWindow?.isHidden = true
      self.overlayWindow = nil
      self.controller = nil
    }
  }

  func emitEvent(_ type: String, extra: [String: Any] = [:]) {
    var payload = extra
    payload["type"] = type
    module?.emitCallUiEvent(payload)
  }

  private func applyStateOnMain(_ payload: [String: Any]) {
    let visible = (payload["visible"] as? Bool) ?? (((payload["mode"] as? String) ?? "hidden") != "hidden")
    guard visible else {
      hide()
      return
    }

    // In-app native call pages are only for foreground runtime.
    // Background/closed call UI should remain OS-native (CallKit / notifications).
    if UIApplication.shared.applicationState != .active {
      hide()
      return
    }

    let controller = ensureController()
    controller.applyState(payload)
  }

  private func ensureController() -> VibeNativeCallScreenController {
    if let controller {
      return controller
    }

    let windowScene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

    let window: UIWindow
    if let windowScene {
      window = UIWindow(windowScene: windowScene)
    } else {
      window = UIWindow(frame: UIScreen.main.bounds)
    }
    window.windowLevel = .alert + 1
    let root = VibeNativeCallScreenController(coordinator: self)
    window.rootViewController = root
    window.isHidden = false
    window.makeKeyAndVisible()
    overlayWindow = window
    controller = root
    return root
  }
}

final class VibeNativeCallScreenController: UIViewController {
  private weak var coordinator: VibeNativeCallUiCoordinator?
  private var currentState: [String: Any] = [:]

  private let rootStack = UIStackView()
  private let chipLabel = UILabel()
  private let avatarView = UIView()
  private let initialsLabel = UILabel()
  private let nameLabel = UILabel()
  private let statusLabel = UILabel()
  private let spacer = UIView()
  private let utilityRow = UIStackView()
  private let incomingRow = UIStackView()
  private let activeRow = UIStackView()

  private var buttons: [String: UIButton] = [:]
  private var buttonLabels: [String: UILabel] = [:]

  init(coordinator: VibeNativeCallUiCoordinator) {
    self.coordinator = coordinator
    super.init(nibName: nil, bundle: nil)
    modalPresentationCapturesStatusBarAppearance = true
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupUi()
  }

  func applyState(_ state: [String: Any]) {
    currentState = state
    let isDark = (state["isDark"] as? Bool) ?? true
    let palette = isDark ? Palette.dark : .light
    view.backgroundColor = palette.background

    let mode = (state["mode"] as? String) ?? "hidden"
    let callType = (state["callType"] as? String) ?? "voice"
    chipLabel.text = mode == "incoming"
      ? (callType == "video" ? "Incoming video call" : "Incoming voice call")
      : (callType == "video" ? "Vibe Video" : "Vibe Audio")
    chipLabel.textColor = palette.subtle
    chipLabel.backgroundColor = palette.surface

    let remoteName = ((state["remoteUserName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown"
    nameLabel.text = remoteName
    initialsLabel.text = String(remoteName.prefix(1)).uppercased()
    nameLabel.textColor = palette.text
    statusLabel.textColor = palette.subtle
    initialsLabel.textColor = palette.text
    avatarView.backgroundColor = palette.avatar

    statusLabel.text = mode == "incoming"
      ? "Tap accept to answer"
      : activeStatus(from: state)

    utilityRow.isHidden = mode != "incoming"
    incomingRow.isHidden = mode != "incoming"
    activeRow.isHidden = mode != "active"

    styleButton("incomingDecline", bg: palette.red, fg: .white)
    styleButton("incomingAccept", bg: palette.blue, fg: .white)
    styleButton("msg", bg: palette.surface, fg: palette.text)
    styleButton("remind", bg: palette.surface, fg: palette.text)
    styleButton("end", bg: palette.red, fg: .white)

    let isMuted = (state["isMuted"] as? Bool) ?? false
    let isSpeaker = (state["isSpeakerOn"] as? Bool) ?? false
    let isVideo = (state["isVideoEnabled"] as? Bool) ?? false
    styleToggle("mute", active: isMuted, palette: palette)
    styleToggle("speaker", active: isSpeaker, palette: palette)
    styleToggle("video", active: isVideo, palette: palette)
    styleButton("flip", bg: palette.surface, fg: palette.text)
    buttons["flip"]?.isHidden = !(((state["canFlipCamera"] as? Bool) ?? false) && isVideo)
  }

  private func activeStatus(from state: [String: Any]) -> String {
    let status = (state["callStatus"] as? String) ?? "active"
    switch status {
    case "connecting": return "Connecting..."
    case "reconnecting": return "Reconnecting..."
    case "ringing": return "Ringing..."
    case "active":
      let total = (state["callDuration"] as? NSNumber)?.intValue ?? 0
      return "\(total / 60):" + String(format: "%02d", total % 60)
    default:
      return status.capitalized
    }
  }

  private func setupUi() {
    view.isOpaque = true
    view.addSubview(rootStack)
    rootStack.axis = .vertical
    rootStack.alignment = .center
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    rootStack.spacing = 12

    NSLayoutConstraint.activate([
      rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
      rootStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])

    chipLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    chipLabel.textAlignment = .center
    chipLabel.layer.cornerRadius = 18
    chipLabel.layer.masksToBounds = true
    chipLabel.layer.borderWidth = 1
    chipLabel.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    chipLabel.layoutMargins = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
    chipLabel.translatesAutoresizingMaskIntoConstraints = false
    let chipWrap = UIView()
    chipWrap.addSubview(chipLabel)
    chipLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      chipLabel.leadingAnchor.constraint(equalTo: chipWrap.leadingAnchor),
      chipLabel.trailingAnchor.constraint(equalTo: chipWrap.trailingAnchor),
      chipLabel.topAnchor.constraint(equalTo: chipWrap.topAnchor),
      chipLabel.bottomAnchor.constraint(equalTo: chipWrap.bottomAnchor),
    ])
    rootStack.addArrangedSubview(chipWrap)

    avatarView.translatesAutoresizingMaskIntoConstraints = false
    avatarView.layer.cornerRadius = 78
    avatarView.layer.masksToBounds = true
    NSLayoutConstraint.activate([
      avatarView.widthAnchor.constraint(equalToConstant: 156),
      avatarView.heightAnchor.constraint(equalToConstant: 156),
    ])
    initialsLabel.translatesAutoresizingMaskIntoConstraints = false
    initialsLabel.font = .systemFont(ofSize: 52, weight: .bold)
    initialsLabel.textAlignment = .center
    avatarView.addSubview(initialsLabel)
    NSLayoutConstraint.activate([
      initialsLabel.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
      initialsLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
    ])
    let avatarSpacer = UIView()
    avatarSpacer.addSubview(avatarView)
    avatarView.centerXAnchor.constraint(equalTo: avatarSpacer.centerXAnchor).isActive = true
    avatarView.topAnchor.constraint(equalTo: avatarSpacer.topAnchor, constant: 28).isActive = true
    avatarView.bottomAnchor.constraint(equalTo: avatarSpacer.bottomAnchor).isActive = true
    rootStack.addArrangedSubview(avatarSpacer)

    nameLabel.font = .systemFont(ofSize: 30, weight: .bold)
    nameLabel.textAlignment = .center
    rootStack.addArrangedSubview(nameLabel)

    statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
    statusLabel.textAlignment = .center
    rootStack.addArrangedSubview(statusLabel)

    spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
    rootStack.addArrangedSubview(spacer)

    utilityRow.axis = .horizontal
    utilityRow.alignment = .center
    utilityRow.spacing = 14
    utilityRow.distribution = .fillEqually
    utilityRow.translatesAutoresizingMaskIntoConstraints = false
    utilityRow.addArrangedSubview(makeButtonStack(key: "msg", glyph: "✉︎", label: "Message", size: 52))
    utilityRow.addArrangedSubview(makeButtonStack(key: "remind", glyph: "⏰", label: "Remind", size: 52))
    rootStack.addArrangedSubview(utilityRow)

    incomingRow.axis = .horizontal
    incomingRow.alignment = .center
    incomingRow.spacing = 18
    incomingRow.distribution = .fillEqually
    incomingRow.translatesAutoresizingMaskIntoConstraints = false
    incomingRow.addArrangedSubview(makeButtonStack(key: "incomingDecline", glyph: "✕", label: "Decline", size: 76))
    incomingRow.addArrangedSubview(makeButtonStack(key: "incomingAccept", glyph: "✓", label: "Accept", size: 76))
    rootStack.addArrangedSubview(incomingRow)

    activeRow.axis = .horizontal
    activeRow.alignment = .top
    activeRow.spacing = 8
    activeRow.distribution = .fillEqually
    activeRow.translatesAutoresizingMaskIntoConstraints = false
    activeRow.addArrangedSubview(makeButtonStack(key: "mute", glyph: "🎤", label: "Mic", size: 48))
    activeRow.addArrangedSubview(makeButtonStack(key: "video", glyph: "▶︎", label: "Video", size: 48))
    activeRow.addArrangedSubview(makeButtonStack(key: "flip", glyph: "⇄", label: "Flip", size: 48))
    activeRow.addArrangedSubview(makeButtonStack(key: "speaker", glyph: "🔊", label: "Audio", size: 48))
    activeRow.addArrangedSubview(makeButtonStack(key: "end", glyph: "✕", label: "End", size: 56))
    rootStack.addArrangedSubview(activeRow)
  }

  private func makeButtonStack(key: String, glyph: String, label: String, size: CGFloat) -> UIView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = size >= 70 ? 8 : 5

    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.layer.cornerRadius = size / 2
    button.layer.masksToBounds = true
    button.layer.borderWidth = 1
    button.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    button.addTarget(self, action: #selector(onButtonTap(_:)), for: .touchUpInside)
    button.accessibilityIdentifier = key
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: size),
      button.heightAnchor.constraint(equalToConstant: size),
    ])

    let glyphLabel = UILabel()
    glyphLabel.text = glyph
    glyphLabel.font = .systemFont(ofSize: size >= 70 ? 28 : 18, weight: .bold)
    glyphLabel.translatesAutoresizingMaskIntoConstraints = false
    glyphLabel.textAlignment = .center
    button.addSubview(glyphLabel)
    NSLayoutConstraint.activate([
      glyphLabel.centerXAnchor.constraint(equalTo: button.centerXAnchor),
      glyphLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
    ])

    let labelView = UILabel()
    labelView.text = label
    labelView.font = .systemFont(ofSize: size >= 70 ? 13 : 10, weight: .semibold)
    labelView.textAlignment = .center

    stack.addArrangedSubview(button)
    stack.addArrangedSubview(labelView)
    buttons[key] = button
    buttonLabels[key] = labelView
    return stack
  }

  @objc private func onButtonTap(_ sender: UIButton) {
    guard let key = sender.accessibilityIdentifier else { return }
    let event: String
    switch key {
    case "incomingAccept": event = "accept"
    case "incomingDecline": event = "decline"
    case "msg": event = "message"
    case "remind": event = "remind"
    case "mute": event = "toggleMute"
    case "speaker": event = "toggleSpeaker"
    case "video": event = "toggleVideo"
    case "flip": event = "flipCamera"
    case "end": event = "end"
    default: event = "noop"
    }
    coordinator?.emitEvent(event)
  }

  private func styleToggle(_ key: String, active: Bool, palette: Palette) {
    styleButton(key, bg: active ? palette.text : palette.surface, fg: active ? palette.background : palette.text)
  }

  private func styleButton(_ key: String, bg: UIColor, fg: UIColor) {
    buttons[key]?.backgroundColor = bg
    buttons[key]?.tintColor = fg
    if let glyph = buttons[key]?.subviews.compactMap({ $0 as? UILabel }).first {
      glyph.textColor = fg
    }
    buttonLabels[key]?.textColor = fg
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    let isDark = (currentState["isDark"] as? Bool) ?? true
    return isDark ? .lightContent : .darkContent
  }
}

private struct Palette {
  let background: UIColor
  let text: UIColor
  let subtle: UIColor
  let surface: UIColor
  let avatar: UIColor
  let blue: UIColor
  let red: UIColor

  static let dark = Palette(
    background: UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1),
    text: .white,
    subtle: UIColor(white: 0.78, alpha: 1),
    surface: UIColor(red: 0.14, green: 0.17, blue: 0.21, alpha: 1),
    avatar: UIColor(red: 0.11, green: 0.13, blue: 0.19, alpha: 1),
    blue: UIColor(red: 0.17, green: 0.44, blue: 1, alpha: 1),
    red: UIColor(red: 0.91, green: 0.30, blue: 0.36, alpha: 1)
  )

  static let light = Palette(
    background: UIColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1),
    text: UIColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1),
    subtle: UIColor(red: 0.35, green: 0.40, blue: 0.47, alpha: 1),
    surface: UIColor(red: 0.90, green: 0.93, blue: 0.97, alpha: 1),
    avatar: UIColor(red: 0.87, green: 0.91, blue: 0.97, alpha: 1),
    blue: UIColor(red: 0.17, green: 0.44, blue: 1, alpha: 1),
    red: UIColor(red: 0.91, green: 0.30, blue: 0.36, alpha: 1)
  )
}
