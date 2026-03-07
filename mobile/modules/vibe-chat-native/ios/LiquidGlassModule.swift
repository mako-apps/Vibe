import ExpoModulesCore
import UIKit

private enum LiquidGlassControlKind: String {
  case buttons
  case tabs
}

private struct LiquidGlassControlItem {
  let key: String
  let title: String?
  let sfSymbol: String?
  let foregroundColor: UIColor?
  let isSelected: Bool
  let isDisabled: Bool
}

private func liquidGlassString(_ value: Any?) -> String? {
  if let string = value as? String {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  if let number = value as? NSNumber {
    return number.stringValue
  }
  return nil
}

private func liquidGlassOptionalTitle(_ value: Any?) -> String? {
  if let string = value as? String {
    return string
  }
  if let number = value as? NSNumber {
    return number.stringValue
  }
  return nil
}

private func liquidGlassColor(_ value: Any?) -> UIColor? {
  guard let raw = value as? String else { return nil }
  let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !value.isEmpty else { return nil }

  if value.hasPrefix("#") {
    let hex = String(value.dropFirst())
    var intValue: UInt64 = 0
    guard Scanner(string: hex).scanHexInt64(&intValue) else { return nil }

    switch hex.count {
    case 6:
      return UIColor(
        red: CGFloat((intValue >> 16) & 0xFF) / 255.0,
        green: CGFloat((intValue >> 8) & 0xFF) / 255.0,
        blue: CGFloat(intValue & 0xFF) / 255.0,
        alpha: 1.0
      )
    case 8:
      return UIColor(
        red: CGFloat((intValue >> 16) & 0xFF) / 255.0,
        green: CGFloat((intValue >> 8) & 0xFF) / 255.0,
        blue: CGFloat(intValue & 0xFF) / 255.0,
        alpha: CGFloat((intValue >> 24) & 0xFF) / 255.0
      )
    default:
      return nil
    }
  }

  let normalized = value.lowercased()
  if normalized.hasPrefix("rgba(") || normalized.hasPrefix("rgb(") {
    let inner =
      normalized
      .replacingOccurrences(of: "rgba(", with: "")
      .replacingOccurrences(of: "rgb(", with: "")
      .replacingOccurrences(of: ")", with: "")
    let components = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard components.count == 3 || components.count == 4 else { return nil }
    guard
      let red = Double(components[0]),
      let green = Double(components[1]),
      let blue = Double(components[2])
    else { return nil }
    let alpha = components.count == 4 ? (Double(components[3]) ?? 1.0) : 1.0
    return UIColor(
      red: CGFloat(red) / 255.0,
      green: CGFloat(green) / 255.0,
      blue: CGFloat(blue) / 255.0,
      alpha: CGFloat(alpha)
    )
  }

  return nil
}

private func liquidGlassBool(_ value: Any?, defaultValue: Bool = false) -> Bool {
  if let boolValue = value as? Bool {
    return boolValue
  }
  if let number = value as? NSNumber {
    return number.boolValue
  }
  if let string = value as? String {
    switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "1", "yes", "on":
      return true
    case "false", "0", "no", "off":
      return false
    default:
      break
    }
  }
  return defaultValue
}

class LiquidGlassView: ExpoView {
  public var onNativeControlPress = EventDispatcher()

  private let visualEffectView: UIVisualEffectView
  private let nativeControlsHostView = UIView()
  private let nativeControlsStackView = UIStackView()
  private var cachedIntrinsicContentSize = CGSize(
    width: UIView.noIntrinsicMetric,
    height: UIView.noIntrinsicMetric
  )

  private var currentBlurStyle: UIBlurEffect.Style?
  private var glassStyle: String = "clear"
  private var glassInteractive: Bool = true
  private var pressFeedbackEnabled: Bool = false
  private var isPressFeedbackActive: Bool = false
  private let glassPressedOverlayColor = UIColor(white: 1.0, alpha: 0.08)
  private var glassTintColor: UIColor?
  private var glassTint: String?
  private var glassCornerRadius: CGFloat?

  private var nativeControlKind: LiquidGlassControlKind?
  private var nativeControlItems: [LiquidGlassControlItem] = []
  private var nativeControlSelectedKey: String?
  private var nativeControlInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
  private var nativeControlSpacing: CGFloat = 8

  private var hasNativeControls: Bool {
    nativeControlKind != nil && !nativeControlItems.isEmpty
  }

  required init(appContext: AppContext? = nil) {
    visualEffectView = UIVisualEffectView(effect: nil)
    currentBlurStyle = .systemUltraThinMaterial

    super.init(appContext: appContext)

    visualEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    visualEffectView.isUserInteractionEnabled = false
    visualEffectView.backgroundColor = .clear
    visualEffectView.layer.zPosition = -1

    nativeControlsHostView.backgroundColor = .clear
    nativeControlsHostView.isHidden = true
    nativeControlsHostView.clipsToBounds = false
    visualEffectView.contentView.addSubview(nativeControlsHostView)

    nativeControlsStackView.axis = .horizontal
    nativeControlsStackView.alignment = .fill
    nativeControlsStackView.distribution = .fill
    nativeControlsStackView.spacing = nativeControlSpacing
    nativeControlsHostView.addSubview(nativeControlsStackView)

    backgroundColor = .clear
    addSubview(visualEffectView)
    ensureEffectViewLayering()
    layer.cornerCurve = .continuous
    applyCornerStyling()
    applyCurrentEffect()
  }

  override var intrinsicContentSize: CGSize {
    cachedIntrinsicContentSize
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    visualEffectView.frame = bounds
    layoutNativeControls()
    ensureEffectViewLayering()
    applyCornerStyling()
  }

  override func didAddSubview(_ subview: UIView) {
    super.didAddSubview(subview)
    guard subview !== visualEffectView else { return }
    syncReactManagedContentVisibility()
    ensureEffectViewLayering()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard #available(iOS 26.0, *) else {
      return
    }
    let oldStyle = previousTraitCollection?.userInterfaceStyle
    if oldStyle != traitCollection.userInterfaceStyle {
      applyCurrentEffect()
      rebuildNativeControls()
    }
  }

  private func applyBlurStyle(_ style: UIBlurEffect.Style) {
    currentBlurStyle = style
    if #available(iOS 26.0, *) {
      return
    }
    visualEffectView.effect = UIBlurEffect(style: style)
  }

  private func applyCurrentEffect() {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = glassInteractive
      visualEffectView.effect = effect
      visualEffectView.backgroundColor = .clear
      visualEffectView.contentView.backgroundColor = resolvedGlassTintColor()
      return
    }

    if let blurStyle = currentBlurStyle {
      visualEffectView.effect = UIBlurEffect(style: blurStyle)
    } else {
      visualEffectView.effect = nil
    }
    visualEffectView.backgroundColor = .clear
  }

  private func applyCornerStyling() {
    if #available(iOS 26.0, *) {
      let radius = max(0, Double(glassCornerRadius ?? 0))
      let shouldClip = radius > 0
      clipsToBounds = shouldClip
      visualEffectView.clipsToBounds = shouldClip
      visualEffectView.cornerConfiguration = .uniformCorners(radius: .fixed(radius))
      return
    }

    let radius = max(0, glassCornerRadius ?? 0)
    layer.cornerRadius = radius
    visualEffectView.layer.cornerRadius = radius
    clipsToBounds = radius > 0
    visualEffectView.clipsToBounds = radius > 0
  }

  private func ensureEffectViewLayering() {
    guard visualEffectView.superview === self else { return }
    bringSubviewToFront(visualEffectView)
  }

  private func animatePressFeedback(isPressed: Bool) {
    guard pressFeedbackEnabled else { return }
    guard !hasNativeControls else { return }
    guard #unavailable(iOS 26.0) else { return }
    guard isPressFeedbackActive != isPressed else { return }
    isPressFeedbackActive = isPressed

    let duration: TimeInterval = isPressed ? 0.1 : 0.25
    let damping: CGFloat = isPressed ? 1.0 : 0.6
    let velocity: CGFloat = isPressed ? 0.0 : 0.4

    UIView.animate(
      withDuration: duration,
      delay: 0,
      usingSpringWithDamping: damping,
      initialSpringVelocity: velocity,
      options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.visualEffectView.contentView.backgroundColor =
        isPressed
        ? self.glassPressedOverlayColor
        : .clear
    }
  }

  private func resetPressFeedbackAppearance() {
    isPressFeedbackActive = false
    if #available(iOS 26.0, *) {
      visualEffectView.contentView.backgroundColor = resolvedGlassTintColor()
    } else {
      visualEffectView.contentView.backgroundColor = .clear
    }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    animatePressFeedback(isPressed: true)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesMoved(touches, with: event)
    guard let touch = touches.first else { return }
    let isInside = bounds.contains(touch.location(in: self))
    animatePressFeedback(isPressed: isInside)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    animatePressFeedback(isPressed: false)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesCancelled(touches, with: event)
    animatePressFeedback(isPressed: false)
  }

  private func resolvedGlassTintColor() -> UIColor? {
    if let explicitTint = glassTintColor {
      return explicitTint
    }

    guard #available(iOS 26.0, *) else {
      return nil
    }
    guard let tint = glassTint, !tint.isEmpty else {
      return nil
    }

    let isDarkMode = traitCollection.userInterfaceStyle == .dark
    let styleMultiplier: CGFloat = glassStyle == "regular" ? 1.3 : 1.0
    let scaledAlpha: (CGFloat) -> CGFloat = { base in
      min(0.28, max(0.02, base * styleMultiplier))
    }

    switch tint {
    case "dark":
      return UIColor.black.withAlphaComponent(scaledAlpha(isDarkMode ? 0.16 : 0.14))
    case "light":
      return UIColor.white.withAlphaComponent(scaledAlpha(isDarkMode ? 0.08 : 0.1))
    case "extraLight":
      return UIColor.white.withAlphaComponent(scaledAlpha(isDarkMode ? 0.12 : 0.14))
    case "prominent":
      return isDarkMode
        ? UIColor.white.withAlphaComponent(scaledAlpha(0.16))
        : UIColor.black.withAlphaComponent(scaledAlpha(0.12))
    case "regular":
      return isDarkMode
        ? UIColor.white.withAlphaComponent(scaledAlpha(0.095))
        : UIColor.black.withAlphaComponent(scaledAlpha(0.08))
    case "default":
      return isDarkMode
        ? UIColor.white.withAlphaComponent(scaledAlpha(0.085))
        : UIColor.black.withAlphaComponent(scaledAlpha(0.07))
    default:
      return nil
    }
  }

  private func layoutNativeControls() {
    let hostFrame = visualEffectView.contentView.bounds.inset(by: nativeControlInsets)
    nativeControlsHostView.frame = hostFrame.integral
    nativeControlsStackView.frame = nativeControlsHostView.bounds
  }

  private func clearNativeControls() {
    nativeControlsStackView.arrangedSubviews.forEach { subview in
      nativeControlsStackView.removeArrangedSubview(subview)
      subview.removeFromSuperview()
    }
  }

  private func syncReactManagedContentVisibility() {
    visualEffectView.isUserInteractionEnabled = hasNativeControls
    nativeControlsHostView.isHidden = !hasNativeControls

    for subview in subviews where subview !== visualEffectView {
      subview.isHidden = hasNativeControls
      subview.isUserInteractionEnabled = !hasNativeControls
    }
  }

  private func effectiveSelectedKey() -> String? {
    if let selectedKey = nativeControlSelectedKey, !selectedKey.isEmpty {
      return selectedKey
    }
    if let selectedItem = nativeControlItems.first(where: { $0.isSelected }) {
      return selectedItem.key
    }
    guard nativeControlKind == .tabs else {
      return nil
    }
    return nativeControlItems.first?.key
  }

  private func controlTextColor(isSelected: Bool, isDisabled: Bool) -> UIColor {
    let isDarkMode = traitCollection.userInterfaceStyle == .dark
    let color: UIColor
    if isSelected {
      color = isDarkMode ? .white : .black
    } else {
      color =
        isDarkMode ? UIColor.white.withAlphaComponent(0.92) : UIColor.black.withAlphaComponent(0.88)
    }
    return isDisabled ? color.withAlphaComponent(0.45) : color
  }

  private func selectedControlBackgroundColor() -> UIColor {
    let isDarkMode = traitCollection.userInterfaceStyle == .dark
    return isDarkMode
      ? UIColor.white.withAlphaComponent(0.14)
      : UIColor.black.withAlphaComponent(0.08)
  }

  private func unselectedControlBorderColor() -> UIColor {
    let isDarkMode = traitCollection.userInterfaceStyle == .dark
    return isDarkMode
      ? UIColor.white.withAlphaComponent(0.08)
      : UIColor.black.withAlphaComponent(0.06)
  }

  private func rebuildNativeControls() {
    clearNativeControls()
    syncReactManagedContentVisibility()
    layoutNativeControls()

    guard let kind = nativeControlKind, hasNativeControls else {
      updateIntrinsicContentSize()
      return
    }

    let selectedKey = effectiveSelectedKey()
    nativeControlsStackView.spacing = nativeControlSpacing
    nativeControlsStackView.distribution = kind == .tabs ? .fillEqually : .fill

    for (index, item) in nativeControlItems.enumerated() {
      let isSelected = selectedKey == item.key
      let button = UIButton(type: .system)
      button.tag = index
      button.isEnabled = !item.isDisabled
      button.alpha = item.isDisabled ? 0.45 : 1.0
      button.addTarget(self, action: #selector(handleNativeControlPress(_:)), for: .touchUpInside)
      button.configuration = configuredButtonConfiguration(
        for: item,
        kind: kind,
        isSelected: isSelected
      )
      if #available(iOS 26.0, *), kind == .tabs {
        button.backgroundColor = .clear
        button.layer.cornerRadius = 0
        button.layer.borderWidth = 0
        button.layer.borderColor = nil
      } else {
        button.backgroundColor =
          (kind == .tabs && isSelected)
          ? selectedControlBackgroundColor()
          : .clear
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = kind == .tabs ? 18 : 0
        button.layer.borderWidth = kind == .tabs && !isSelected ? 0.5 : 0
        button.layer.borderColor = unselectedControlBorderColor().cgColor
      }
      button.titleLabel?.numberOfLines = 1
      button.titleLabel?.lineBreakMode = .byClipping

      if kind == .buttons {
        button.setContentHuggingPriority(.required, for: .horizontal)
      }

      nativeControlsStackView.addArrangedSubview(button)
    }

    updateIntrinsicContentSize()
  }

  private func configuredButtonConfiguration(
    for item: LiquidGlassControlItem,
    kind: LiquidGlassControlKind,
    isSelected: Bool
  ) -> UIButton.Configuration {
    let symbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: kind == .tabs ? 15 : 16,
      weight: isSelected ? .semibold : .medium
    )
    let image = item.sfSymbol.flatMap { symbol in
      UIImage(systemName: symbol, withConfiguration: symbolConfiguration)
    }

    let title = item.title ?? item.key
    let resolvedTitle = title.isEmpty ? nil : title
    let foregroundColor =
      item.foregroundColor ?? controlTextColor(isSelected: isSelected, isDisabled: item.isDisabled)

    if #available(iOS 26.0, *) {
      var config: UIButton.Configuration
      if kind == .buttons {
        // Keep the material on the outer glass container so presses do not
        // momentarily clear the only visible glass layer.
        config = UIButton.Configuration.plain()
      } else if isSelected {
        config = UIButton.Configuration.prominentGlass()
      } else {
        config = UIButton.Configuration.plain()
      }
      config.cornerStyle = .capsule
      config.title = resolvedTitle
      config.image = image
      config.imagePlacement = .leading
      config.imagePadding = image != nil && resolvedTitle != nil ? 6 : 0
      config.baseForegroundColor = foregroundColor
      config.contentInsets =
        kind == .tabs
        ? NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        : NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
      return config
    }

    var config = UIButton.Configuration.plain()
    config.cornerStyle = .capsule
    config.title = resolvedTitle
    config.image = image
    config.imagePlacement = .leading
    config.imagePadding = image != nil && resolvedTitle != nil ? 6 : 0
    config.baseForegroundColor = foregroundColor
    config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    if kind == .tabs && isSelected {
      config.background.backgroundColor = selectedControlBackgroundColor()
    } else {
      config.background.backgroundColor = .clear
    }
    return config
  }

  private func updateIntrinsicContentSize() {
    guard hasNativeControls else {
      cachedIntrinsicContentSize = CGSize(
        width: UIView.noIntrinsicMetric,
        height: UIView.noIntrinsicMetric
      )
      invalidateIntrinsicContentSize()
      return
    }

    let width = nativeControlItems.enumerated().reduce(CGFloat(0)) { partial, entry in
      let (index, item) = entry
      let button = UIButton(type: .system)
      button.configuration = configuredButtonConfiguration(
        for: item,
        kind: nativeControlKind ?? .buttons,
        isSelected: effectiveSelectedKey() == item.key
      )
      let measured = button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
      let spacing = index == nativeControlItems.count - 1 ? CGFloat(0) : nativeControlSpacing
      return partial + measured.width + spacing
    }

    let maxHeight = nativeControlItems.reduce(CGFloat(0)) { partial, item in
      let button = UIButton(type: .system)
      button.configuration = configuredButtonConfiguration(
        for: item,
        kind: nativeControlKind ?? .buttons,
        isSelected: effectiveSelectedKey() == item.key
      )
      let measured = button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
      return max(partial, measured.height)
    }

    cachedIntrinsicContentSize = CGSize(
      width: width + nativeControlInsets.left + nativeControlInsets.right,
      height: maxHeight + nativeControlInsets.top + nativeControlInsets.bottom
    )
    invalidateIntrinsicContentSize()
  }

  @objc
  private func handleNativeControlPress(_ sender: UIButton) {
    let index = sender.tag
    guard index >= 0, index < nativeControlItems.count else { return }

    guard let kind = nativeControlKind else { return }
    let item = nativeControlItems[index]

    if kind == .tabs {
      nativeControlSelectedKey = item.key
      rebuildNativeControls()
    }

    onNativeControlPress([
      "key": item.key,
      "index": index,
      "kind": kind.rawValue,
    ])
  }

  func setBlurIntensity(_ intensity: Double) {
    if #available(iOS 26.0, *) {
      return
    }

    let style: UIBlurEffect.Style

    if intensity <= 0 {
      currentBlurStyle = nil
      visualEffectView.effect = nil
      return
    }

    if intensity < 8 {
      style = .systemUltraThinMaterial
    } else if intensity < 15 {
      style = .systemThinMaterial
    } else if intensity < 25 {
      style = .systemMaterial
    } else if intensity < 40 {
      style = .systemThickMaterial
    } else {
      style = .systemChromeMaterial
    }
    applyBlurStyle(style)
  }

  func setInteractive(_ interactive: Bool?) {
    let resolvedInteractive = interactive ?? true
    glassInteractive = resolvedInteractive
    if !resolvedInteractive {
      resetPressFeedbackAppearance()
    }
    applyCurrentEffect()
  }

  func setPressFeedbackEnabled(_ enabled: Bool?) {
    pressFeedbackEnabled = enabled ?? false
    if !pressFeedbackEnabled {
      resetPressFeedbackAppearance()
    }
  }

  func setEffect(_ effect: String?) {
    glassStyle = effect == "clear" ? "clear" : "regular"
    applyCurrentEffect()
  }

  func setTintColor(_ tintColor: UIColor?) {
    glassTintColor = tintColor
    applyCurrentEffect()
  }

  func setTint(_ tint: String?) {
    glassTint = tint
    if #available(iOS 26.0, *) {
      applyCurrentEffect()
      return
    }

    guard let tint = tint else { return }

    switch tint {
    case "dark":
      applyBlurStyle(.systemThinMaterialDark)
    case "light":
      applyBlurStyle(.systemThinMaterialLight)
    case "extraLight":
      if currentBlurStyle == .systemUltraThinMaterial {
        applyBlurStyle(.systemChromeMaterialLight)
      } else {
        applyBlurStyle(.light)
      }
    case "default":
      applyBlurStyle(.systemThinMaterial)
    default:
      break
    }
  }

  func setCornerRadius(_ cornerRadius: Double?) {
    if let cornerRadius, cornerRadius > 0 {
      glassCornerRadius = CGFloat(cornerRadius)
    } else {
      glassCornerRadius = nil
    }
    applyCornerStyling()
    updateIntrinsicContentSize()
  }

  func setNativeControlKind(_ kind: String?) {
    nativeControlKind = kind.flatMap { LiquidGlassControlKind(rawValue: $0) }
    applyCurrentEffect()
    rebuildNativeControls()
  }

  func setNativeControlItems(_ items: [[String: Any]]?) {
    nativeControlItems = (items ?? []).compactMap { raw in
      guard let key = liquidGlassString(raw["key"]) else {
        return nil
      }
      return LiquidGlassControlItem(
        key: key,
        title: liquidGlassOptionalTitle(raw["title"]),
        sfSymbol: liquidGlassString(raw["sfSymbol"]),
        foregroundColor: liquidGlassColor(raw["foregroundColor"]),
        isSelected: liquidGlassBool(raw["selected"]),
        isDisabled: liquidGlassBool(raw["disabled"])
      )
    }
    applyCurrentEffect()
    rebuildNativeControls()
  }

  func setNativeControlSelectedKey(_ key: String?) {
    nativeControlSelectedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
    rebuildNativeControls()
  }

  func setNativeControlInsets(_ payload: [String: Any]?) {
    guard let payload else {
      nativeControlInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
      layoutNativeControls()
      applyCornerStyling()
      updateIntrinsicContentSize()
      return
    }

    let top = (payload["top"] as? NSNumber)?.doubleValue ?? 6
    let left = (payload["left"] as? NSNumber)?.doubleValue ?? 6
    let bottom = (payload["bottom"] as? NSNumber)?.doubleValue ?? 6
    let right = (payload["right"] as? NSNumber)?.doubleValue ?? 6
    nativeControlInsets = UIEdgeInsets(
      top: max(0, top),
      left: max(0, left),
      bottom: max(0, bottom),
      right: max(0, right)
    )
    layoutNativeControls()
    applyCornerStyling()
    updateIntrinsicContentSize()
  }

  func setNativeControlSpacing(_ value: Double?) {
    nativeControlSpacing = CGFloat(max(0, value ?? 8))
    nativeControlsStackView.spacing = nativeControlSpacing
    layoutNativeControls()
    updateIntrinsicContentSize()
  }
}

public class LiquidGlassModule: Module {
  public func definition() -> ModuleDefinition {
    Name("LiquidGlass")

    View(LiquidGlassView.self) {
      Prop("blurIntensity") { (view: LiquidGlassView, intensity: Double) in
        view.setBlurIntensity(intensity)
      }

      Prop("tint") { (view: LiquidGlassView, tint: String?) in
        view.setTint(tint)
      }

      Prop("interactive") { (view: LiquidGlassView, interactive: Bool?) in
        view.setInteractive(interactive)
      }

      Prop("pressFeedbackEnabled") { (view: LiquidGlassView, enabled: Bool?) in
        view.setPressFeedbackEnabled(enabled)
      }

      Prop("effect") { (view: LiquidGlassView, effect: String?) in
        view.setEffect(effect)
      }

      Prop("tintColor") { (view: LiquidGlassView, tintColor: UIColor?) in
        view.setTintColor(tintColor)
      }

      Prop("cornerRadius") { (view: LiquidGlassView, cornerRadius: Double?) in
        view.setCornerRadius(cornerRadius)
      }

      Prop("nativeControlKind") { (view: LiquidGlassView, kind: String?) in
        view.setNativeControlKind(kind)
      }

      Prop("nativeControlItems") { (view: LiquidGlassView, items: [[String: Any]]?) in
        view.setNativeControlItems(items)
      }

      Prop("nativeControlSelectedKey") { (view: LiquidGlassView, key: String?) in
        view.setNativeControlSelectedKey(key)
      }

      Prop("nativeControlInsets") { (view: LiquidGlassView, payload: [String: Any]?) in
        view.setNativeControlInsets(payload)
      }

      Prop("nativeControlSpacing") { (view: LiquidGlassView, value: Double?) in
        view.setNativeControlSpacing(value)
      }

      Events("onNativeControlPress")
    }
  }
}
