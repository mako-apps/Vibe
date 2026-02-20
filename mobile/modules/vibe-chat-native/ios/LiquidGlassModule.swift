import ExpoModulesCore
import UIKit

class LiquidGlassView: ExpoView {
  private let visualEffectView: UIVisualEffectView
  private var currentBlurStyle: UIBlurEffect.Style?
  private var glassStyle: String = "clear"
  private var glassInteractive: Bool = false
  private var glassTintColor: UIColor?
  private var glassTint: String?
  private var glassCornerRadius: CGFloat?

  required init(appContext: AppContext? = nil) {
    visualEffectView = UIVisualEffectView(effect: nil)
    currentBlurStyle = .systemUltraThinMaterial
    
    super.init(appContext: appContext)
    
    visualEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    visualEffectView.isUserInteractionEnabled = false
    visualEffectView.backgroundColor = .clear
    backgroundColor = .clear
    addSubview(visualEffectView)
    layer.cornerCurve = .continuous
    applyCornerStyling()
    applyCurrentEffect()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    visualEffectView.frame = bounds
    applyCornerStyling()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard #available(iOS 26.0, *) else {
      return
    }
    let oldStyle = previousTraitCollection?.userInterfaceStyle
    if oldStyle != traitCollection.userInterfaceStyle {
      applyCurrentEffect()
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
      let style: UIGlassEffect.Style = glassStyle == "clear" ? .clear : .regular
      let effect = UIGlassEffect(style: style)
      effect.isInteractive = glassInteractive
      effect.tintColor = resolvedGlassTintColor()
      visualEffectView.effect = effect
      return
    }

    if let blurStyle = currentBlurStyle {
      visualEffectView.effect = UIBlurEffect(style: blurStyle)
    } else {
      visualEffectView.effect = nil
    }
  }

  private func applyCornerStyling() {
    if #available(iOS 26.0, *) {
      clipsToBounds = false
      visualEffectView.clipsToBounds = false

      let explicitRadius = max(0, Double(glassCornerRadius ?? 0))
      let fallbackRadius = max(0, Double(min(bounds.width, bounds.height) / 2))
      let radius = explicitRadius > 0 ? explicitRadius : fallbackRadius
      visualEffectView.cornerConfiguration = .uniformCorners(radius: .fixed(radius))
      return
    }

    let radius = max(0, glassCornerRadius ?? 0)
    layer.cornerRadius = radius
    visualEffectView.layer.cornerRadius = radius
    clipsToBounds = radius > 0
    visualEffectView.clipsToBounds = radius > 0
  }

  private func resolvedGlassTintColor() -> UIColor? {
    if let explicitTint = glassTintColor {
      return explicitTint
    }

    guard #available(iOS 26.0, *) else {
      return nil
    }
    let tint = glassTint ?? "default"

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
      fallthrough
    default:
      return isDarkMode
        ? UIColor.white.withAlphaComponent(scaledAlpha(0.085))
        : UIColor.black.withAlphaComponent(scaledAlpha(0.07))
    }
  }

  func setBlurIntensity(_ intensity: Double) {
    if #available(iOS 26.0, *) {
      return
    }

    let style: UIBlurEffect.Style
    
    // Map intensity (0-100) to appropriate UIBlurEffectStyles
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
      style = .systemChromeMaterial // Strongest standard material
    }
    applyBlurStyle(style)
  }

  func setInteractive(_ interactive: Bool?) {
    glassInteractive = interactive ?? false
    applyCurrentEffect()
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
           // Fallback or specific mapping
           if currentBlurStyle == .systemUltraThinMaterial {
               // No direct "SystemUltraThinMaterialLight", but light can often imply just light mode
               // We might rely on system behavior or force light interface style if needed
               // For now, let's map explicit tints to the available styles
               applyBlurStyle(.systemChromeMaterialLight)
           } else {
               applyBlurStyle(.light)
           }
      case "default":
           // Reset to adaptive
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

      Prop("effect") { (view: LiquidGlassView, effect: String?) in
        view.setEffect(effect)
      }

      Prop("tintColor") { (view: LiquidGlassView, tintColor: UIColor?) in
        view.setTintColor(tintColor)
      }

      Prop("cornerRadius") { (view: LiquidGlassView, cornerRadius: Double?) in
        view.setCornerRadius(cornerRadius)
      }
    }
  }
}
