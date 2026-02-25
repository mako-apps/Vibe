import ExpoModulesCore
import UIKit

private struct ChatNativeTabItem {
  let key: String
  let title: String
  let sfSymbol: String?
  let iconUri: String?
  let badge: String?
  let isVibe: Bool
}

private final class ChatNativeVibeButton: UIControl {
  private let glassView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
  private let iconView = UIImageView()
  private let glassPressedOverlayColor = UIColor(white: 1.0, alpha: 0.08)

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    backgroundColor = .clear
    translatesAutoresizingMaskIntoConstraints = false

    glassView.translatesAutoresizingMaskIntoConstraints = false
    glassView.clipsToBounds = true
    glassView.layer.cornerCurve = .continuous
    glassView.isUserInteractionEnabled = false
    addSubview(glassView)

    NSLayoutConstraint.activate([
      glassView.topAnchor.constraint(equalTo: topAnchor),
      glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.isUserInteractionEnabled = false
    iconView.contentMode = .scaleAspectFit
    iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 24, weight: .bold)
    glassView.contentView.addSubview(iconView)
    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: glassView.contentView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: glassView.contentView.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 30),
      iconView.heightAnchor.constraint(equalToConstant: 30),
    ])

    refreshGlass()
  }

  override var isHighlighted: Bool {
    didSet {
      let isPressed = isHighlighted
      let scale: CGFloat = isPressed ? 0.96 : 1.0
      let duration: TimeInterval = isPressed ? 0.1 : 0.22
      let damping: CGFloat = isPressed ? 1.0 : 0.72

      UIView.animate(
        withDuration: duration,
        delay: 0,
        usingSpringWithDamping: damping,
        initialSpringVelocity: 0.25,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        self.iconView.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.glassView.contentView.backgroundColor =
          isPressed ? self.glassPressedOverlayColor : .clear
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    glassView.layer.cornerRadius = bounds.height / 2
  }

  func apply(
    item: ChatNativeTabItem,
    focused: Bool,
    activeTintColor: UIColor,
    isDark: Bool
  ) {
    refreshGlass()

    if let logo = resolveLogoImage(from: item) {
      iconView.image = logo.withRenderingMode(.alwaysOriginal)
      iconView.tintColor = nil
      iconView.alpha = focused ? 1.0 : 0.82
      return
    }

    let iconName = item.sfSymbol ?? "sparkles"
    iconView.image = UIImage(systemName: iconName)
    iconView.tintColor =
      focused
      ? activeTintColor
      : (isDark ? UIColor.white.withAlphaComponent(0.86) : UIColor.black.withAlphaComponent(0.78))
    iconView.alpha = 1.0
  }

  private func refreshGlass() {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = true
      glassView.effect = effect
      glassView.backgroundColor = .clear
    } else {
      glassView.effect = UIBlurEffect(style: .systemMaterial)
      glassView.backgroundColor = .clear
    }
  }

  private func resolveLogoImage(from item: ChatNativeTabItem) -> UIImage? {
    if let iconUri = item.iconUri, let image = imageFromURI(iconUri) {
      return image
    }
    if let named = UIImage(named: "logotransparent") {
      return named
    }
    if let path = Bundle.main.path(forResource: "logotransparent", ofType: "png"),
      let image = UIImage(contentsOfFile: path)
    {
      return image
    }
    return nil
  }

  private func imageFromURI(_ uriString: String) -> UIImage? {
    guard !uriString.isEmpty else { return nil }

    if let url = URL(string: uriString) {
      if url.isFileURL {
        let image = UIImage(contentsOfFile: url.path)
        if image != nil { return image }
      }

      let filename = url.lastPathComponent
      let base = (filename as NSString).deletingPathExtension
      let ext = (filename as NSString).pathExtension
      if !base.isEmpty,
        let path = Bundle.main.path(forResource: base, ofType: ext.isEmpty ? nil : ext)
      {
        return UIImage(contentsOfFile: path)
      }
    }

    if uriString.hasPrefix("/") {
      let image = UIImage(contentsOfFile: uriString)
      if image != nil { return image }
    }

    let localFilename = (uriString as NSString).lastPathComponent
    let localBase = (localFilename as NSString).deletingPathExtension
    if !localBase.isEmpty, let named = UIImage(named: localBase) {
      return named
    }

    return UIImage(named: uriString)
  }
}

public final class ChatNativeTabBarView: ExpoView {
  public var onIndexChange = EventDispatcher()

  private let backgroundBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let containerStack = UIStackView()

  // System segmented control — replaces custom pill + buttons
  private let segmentedControl = UISegmentedControl()

  private let vibeButton = ChatNativeVibeButton()

  private var tabs: [ChatNativeTabItem] = []
  private var mainTabs: [ChatNativeTabItem] = []
  private var mainTabIndexes: [Int] = []
  private var vibeTab: ChatNativeTabItem?
  private var vibeTabIndex: Int?

  private var currentIndex = 0
  private var activeTintColor = UIColor.systemBlue
  private var inactiveTintColor = UIColor.systemGray
  private var isDark = false
  private let tabControlSide: CGFloat = 64
  private let horizontalOuterPadding: CGFloat = 18
  private let selectionFeedback = UISelectionFeedbackGenerator()
  private var remoteIconCache: [String: UIImage] = [:]
  private var remoteIconRequests: Set<String> = []

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    setupView()
  }

  public override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 96)
  }

  private func setupView() {
    backgroundColor = .clear
    isOpaque = false

    containerStack.axis = .horizontal
    containerStack.alignment = .center
    containerStack.distribution = .fill
    containerStack.spacing = 8
    containerStack.backgroundColor = .clear
    containerStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(containerStack)

    NSLayoutConstraint.activate([
      containerStack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
      containerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      containerStack.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: horizontalOuterPadding),
      containerStack.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -horizontalOuterPadding),
    ])

    // Glass background behind the segmented control
    backgroundBlur.translatesAutoresizingMaskIntoConstraints = false
    backgroundBlur.layer.cornerRadius = tabControlSide / 2
    backgroundBlur.layer.cornerCurve = .continuous
    backgroundBlur.clipsToBounds = true
    backgroundBlur.isUserInteractionEnabled = true

    // Segmented control setup
    segmentedControl.translatesAutoresizingMaskIntoConstraints = false
    segmentedControl.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
    backgroundBlur.contentView.addSubview(segmentedControl)

    NSLayoutConstraint.activate([
      backgroundBlur.heightAnchor.constraint(equalToConstant: tabControlSide),
      segmentedControl.topAnchor.constraint(
        equalTo: backgroundBlur.contentView.topAnchor, constant: 8),
      segmentedControl.bottomAnchor.constraint(
        equalTo: backgroundBlur.contentView.bottomAnchor, constant: -8),
      segmentedControl.leadingAnchor.constraint(
        equalTo: backgroundBlur.contentView.leadingAnchor, constant: 10),
      segmentedControl.trailingAnchor.constraint(
        equalTo: backgroundBlur.contentView.trailingAnchor, constant: -10),
    ])

    vibeButton.translatesAutoresizingMaskIntoConstraints = false
    vibeButton.setContentHuggingPriority(.required, for: .horizontal)
    vibeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      vibeButton.widthAnchor.constraint(equalToConstant: tabControlSide),
      vibeButton.heightAnchor.constraint(equalToConstant: tabControlSide),
    ])
    vibeButton.addTarget(self, action: #selector(vibeTapped), for: .touchUpInside)
    vibeButton.addTarget(self, action: #selector(vibeTapped), for: .primaryActionTriggered)

    containerStack.addArrangedSubview(backgroundBlur)
    containerStack.addArrangedSubview(vibeButton)

    vibeButton.isHidden = true
    selectionFeedback.prepare()

    applyChrome()
  }

  func setTabs(_ rawTabs: [[String: Any]]) {
    tabs = rawTabs.map { raw in
      let key = (raw["key"] as? String) ?? UUID().uuidString
      let title = (raw["title"] as? String) ?? key
      let sfSymbol = raw["sfSymbol"] as? String
      let iconUri = raw["iconUri"] as? String
      let badgeValue = raw["badge"]
      let badge = badgeValue.map { String(describing: $0) }
      let isVibe = (raw["isVibe"] as? Bool) ?? false
      return ChatNativeTabItem(
        key: key, title: title, sfSymbol: sfSymbol, iconUri: iconUri, badge: badge, isVibe: isVibe)
    }

    if let vibeIndex = tabs.firstIndex(where: { $0.isVibe }) {
      vibeTabIndex = vibeIndex
      vibeTab = tabs[vibeIndex]
    } else {
      vibeTabIndex = nil
      vibeTab = nil
    }

    let filtered = tabs.enumerated().filter { !$0.element.isVibe }
    mainTabs = filtered.map(\.element)
    mainTabIndexes = filtered.map(\.offset)

    rebuildSegments()
  }

  func setCurrentIndex(_ value: Int) {
    currentIndex = value
    applySelection()
  }

  func setActiveTintColor(_ value: UIColor?) {
    if let value {
      activeTintColor = value
      applySelection()
    }
  }

  func setInactiveTintColor(_ value: UIColor?) {
    if let value {
      inactiveTintColor = value
      applySelection()
    }
  }

  func setIsDark(_ value: Bool) {
    isDark = value
    applyChrome()
    applySelection()
  }

  @objc private func segmentChanged(_ sender: UISegmentedControl) {
    let segmentIndex = sender.selectedSegmentIndex
    guard segmentIndex >= 0, segmentIndex < mainTabIndexes.count else { return }
    let tabIndex = mainTabIndexes[segmentIndex]
    if tabIndex != currentIndex {
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
    }
    onIndexChange(["index": tabIndex])
  }

  @objc private func vibeTapped() {
    guard let vibeTabIndex else { return }
    if vibeTabIndex != currentIndex {
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
    }
    onIndexChange(["index": vibeTabIndex])
  }

  private func rebuildSegments() {
    segmentedControl.removeAllSegments()

    for i in 0..<mainTabs.count {
      let item = mainTabs[i]
      // Try to use SF Symbol image, falling back to title only
      if let resolvedIcon = resolvedIcon(for: item) {
        let tinted = resolvedIcon.withRenderingMode(.alwaysTemplate)
        segmentedControl.insertSegment(with: tinted, at: i, animated: false)
      } else if let sfSymbol = item.sfSymbol,
        let img = UIImage(systemName: sfSymbol)
      {
        segmentedControl.insertSegment(with: img, at: i, animated: false)
      } else {
        segmentedControl.insertSegment(withTitle: item.title, at: i, animated: false)
      }
    }

    vibeButton.isHidden = vibeTab == nil
    applySelection()
  }

  private func applySelection() {
    guard !tabs.isEmpty else { return }
    let normalized = max(0, min(currentIndex, tabs.count - 1))
    if normalized != currentIndex {
      currentIndex = normalized
    }

    // Figure out which segment corresponds to the current tab index
    if let segIndex = mainTabIndexes.firstIndex(of: currentIndex) {
      if segmentedControl.selectedSegmentIndex != segIndex {
        segmentedControl.selectedSegmentIndex = segIndex
      }
    } else {
      // Current tab is the vibe tab — deselect the segmented control
      segmentedControl.selectedSegmentIndex = UISegmentedControl.noSegment
    }

    if let vibeTab {
      let focused = vibeTabIndex == currentIndex
      vibeButton.apply(
        item: vibeTab,
        focused: focused,
        activeTintColor: isDark ? .white : .black,
        isDark: isDark
      )
    }
  }

  private func resolvedIcon(for item: ChatNativeTabItem) -> UIImage? {
    guard let iconUri = item.iconUri, !iconUri.isEmpty else {
      return nil
    }

    if let cachedRemote = remoteIconCache[iconUri] {
      return cachedRemote
    }

    if let localImage = localImageFromURI(iconUri) {
      return localImage
    }

    guard let url = URL(string: iconUri), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      return nil
    }

    requestRemoteIcon(from: url, cacheKey: iconUri)
    return nil
  }

  private func requestRemoteIcon(from url: URL, cacheKey: String) {
    guard !remoteIconRequests.contains(cacheKey) else { return }
    remoteIconRequests.insert(cacheKey)

    URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.remoteIconRequests.remove(cacheKey)
        guard let data, let image = UIImage(data: data) else { return }
        self.remoteIconCache[cacheKey] = image
        self.rebuildSegments()
      }
    }.resume()
  }

  private func localImageFromURI(_ uriString: String) -> UIImage? {
    guard !uriString.isEmpty else { return nil }

    if let url = URL(string: uriString) {
      if url.isFileURL {
        let image = UIImage(contentsOfFile: url.path)
        if image != nil { return image }
      }

      let filename = url.lastPathComponent
      let base = (filename as NSString).deletingPathExtension
      let ext = (filename as NSString).pathExtension
      if !base.isEmpty,
        let path = Bundle.main.path(forResource: base, ofType: ext.isEmpty ? nil : ext)
      {
        return UIImage(contentsOfFile: path)
      }
    }

    if uriString.hasPrefix("/") {
      let image = UIImage(contentsOfFile: uriString)
      if image != nil { return image }
    }

    let localFilename = (uriString as NSString).lastPathComponent
    let localBase = (localFilename as NSString).deletingPathExtension
    if !localBase.isEmpty, let named = UIImage(named: localBase) {
      return named
    }

    return UIImage(named: uriString)
  }

  private func applyChrome() {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = true
      backgroundBlur.effect = effect
    } else {
      backgroundBlur.effect = UIBlurEffect(style: .systemThinMaterial)
    }
    backgroundBlur.backgroundColor = .clear
    backgroundBlur.contentView.backgroundColor = .clear
    backgroundBlur.layer.borderWidth = 0.7
    backgroundBlur.layer.borderColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.08).cgColor
      : UIColor.black.withAlphaComponent(0.06).cgColor

    // Style the segmented control
    segmentedControl.backgroundColor = .clear
    segmentedControl.selectedSegmentTintColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.16)
      : UIColor.black.withAlphaComponent(0.10)

    let normalAttrs: [NSAttributedString.Key: Any] = [
      .foregroundColor: isDark
        ? UIColor.white.withAlphaComponent(0.6)
        : UIColor.black.withAlphaComponent(0.5),
      .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
    ]
    let selectedAttrs: [NSAttributedString.Key: Any] = [
      .foregroundColor: isDark ? UIColor.white : UIColor.black,
      .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
    ]
    segmentedControl.setTitleTextAttributes(normalAttrs, for: .normal)
    segmentedControl.setTitleTextAttributes(selectedAttrs, for: .selected)
  }
}

public class ChatNativeTabBarModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatNativeTabs")

    View(ChatNativeTabBarView.self) {
      Prop("tabs") { (view: ChatNativeTabBarView, tabs: [[String: Any]]) in
        view.setTabs(tabs)
      }

      Prop("currentIndex") { (view: ChatNativeTabBarView, index: Int) in
        view.setCurrentIndex(index)
      }

      Prop("activeTintColor") { (view: ChatNativeTabBarView, color: UIColor?) in
        view.setActiveTintColor(color)
      }

      Prop("inactiveTintColor") { (view: ChatNativeTabBarView, color: UIColor?) in
        view.setInactiveTintColor(color)
      }

      Prop("isDark") { (view: ChatNativeTabBarView, isDark: Bool) in
        view.setIsDark(isDark)
      }

      Events("onIndexChange")
    }
  }
}
