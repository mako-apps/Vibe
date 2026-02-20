import UIKit

struct ChatListAppearance {
  let backgroundMode: String
  let wallpaperGradient: [UIColor]
  let wallpaperOpacity: CGFloat

  let bubbleMeGradient: [UIColor]
  let bubbleThemColor: UIColor

  let textColorMe: UIColor
  let textColorThem: UIColor
  let timeColorMe: UIColor
  let timeColorThem: UIColor

  let dayTextColor: UIColor
  let dayBackgroundColor: UIColor
  let dayBorderColor: UIColor

  /// Controls the insertion animation approach:
  ///   0 = None (instant, no animation)
  ///   1 = SlideUpNewOnly (only new cells slide up)
  ///   2 = TelegramOffset (record pre/post positions, animate deltas)
  ///   3 = SpringBatch (UIView.animate with spring wrapping the batch)
  let insertionAnimationMode: Int

  static let fallback = ChatListAppearance(
    backgroundMode: "transparent",
    wallpaperGradient: [
      UIColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1.0),
      UIColor(red: 0.07, green: 0.07, blue: 0.16, alpha: 1.0)
    ],
    wallpaperOpacity: 1.0,
    bubbleMeGradient: [
      UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0),
      UIColor(red: 0.42, green: 0.31, blue: 0.81, alpha: 1.0)
    ],
    bubbleThemColor: UIColor(red: 0.17, green: 0.17, blue: 0.29, alpha: 1.0),
    textColorMe: .white,
    textColorThem: UIColor(white: 0.87, alpha: 1.0),
    timeColorMe: UIColor(white: 1.0, alpha: 0.72),
    timeColorThem: UIColor(white: 1.0, alpha: 0.5),
    dayTextColor: UIColor(white: 0.93, alpha: 0.82),
    dayBackgroundColor: UIColor(red: 0.08, green: 0.08, blue: 0.13, alpha: 0.42),
    dayBorderColor: UIColor(white: 1.0, alpha: 0.16),
    insertionAnimationMode: 2
  )

  static func from(raw: [String: Any]?) -> ChatListAppearance {
    guard let raw else {
      return .fallback
    }
    let mode = (raw["backgroundMode"] as? String) ?? fallback.backgroundMode
    let gradientStrings = raw["wallpaperGradient"] as? [String]
    let meGradientStrings = raw["bubbleMeGradient"] as? [String]

    let wallpaperGradient = parseGradient(gradientStrings, fallback: fallback.wallpaperGradient)
    let bubbleMeGradient = parseGradient(meGradientStrings, fallback: fallback.bubbleMeGradient)

    return ChatListAppearance(
      backgroundMode: mode,
      wallpaperGradient: wallpaperGradient,
      wallpaperOpacity: CGFloat((raw["wallpaperOpacity"] as? NSNumber)?.doubleValue ?? 1.0),
      bubbleMeGradient: bubbleMeGradient,
      bubbleThemColor: parseColor(raw["bubbleThemColor"] as? String) ?? fallback.bubbleThemColor,
      textColorMe: parseColor(raw["textColorMe"] as? String) ?? fallback.textColorMe,
      textColorThem: parseColor(raw["textColorThem"] as? String) ?? fallback.textColorThem,
      timeColorMe: parseColor(raw["timeColorMe"] as? String) ?? fallback.timeColorMe,
      timeColorThem: parseColor(raw["timeColorThem"] as? String) ?? fallback.timeColorThem,
      dayTextColor: parseColor(raw["dayTextColor"] as? String) ?? fallback.dayTextColor,
      dayBackgroundColor: parseColor(raw["dayBackgroundColor"] as? String) ?? fallback.dayBackgroundColor,
      dayBorderColor: parseColor(raw["dayBorderColor"] as? String) ?? fallback.dayBorderColor,
      insertionAnimationMode: (raw["insertionAnimationMode"] as? NSNumber)?.intValue ?? fallback.insertionAnimationMode
    )
  }

  var visualKey: String {
    let wallpaperKey = wallpaperGradient.map(colorKey).joined(separator: ",")
    let meKey = bubbleMeGradient.map(colorKey).joined(separator: ",")
    return [
      backgroundMode,
      String(format: "%.4f", wallpaperOpacity),
      wallpaperKey,
      meKey,
      colorKey(bubbleThemColor),
      colorKey(textColorMe),
      colorKey(textColorThem),
      colorKey(timeColorMe),
      colorKey(timeColorThem),
      colorKey(dayTextColor),
      colorKey(dayBackgroundColor),
      colorKey(dayBorderColor)
    ].joined(separator: "|")
  }
}

private func colorKey(_ color: UIColor) -> String {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
    return String(format: "%.4f,%.4f,%.4f,%.4f", r, g, b, a)
  }
  if let converted = color.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
     let components = converted.components {
    let cr: CGFloat
    let cg: CGFloat
    let cb: CGFloat
    let ca: CGFloat
    if components.count >= 4 {
      cr = components[0]
      cg = components[1]
      cb = components[2]
      ca = components[3]
    } else if components.count == 2 {
      cr = components[0]
      cg = components[0]
      cb = components[0]
      ca = components[1]
    } else {
      cr = 0
      cg = 0
      cb = 0
      ca = 1
    }
    return String(format: "%.4f,%.4f,%.4f,%.4f", cr, cg, cb, ca)
  }
  return "0,0,0,0"
}

private func parseGradient(_ values: [String]?, fallback: [UIColor]) -> [UIColor] {
  guard let values else {
    return fallback
  }
  let colors = values.compactMap(parseColor)
  return colors.count >= 2 ? colors : fallback
}

private func parseColor(_ value: String?) -> UIColor? {
  guard let value else {
    return nil
  }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  if trimmed.hasPrefix("#") {
    return parseHexColor(trimmed)
  }
  if trimmed.hasPrefix("rgba(") || trimmed.hasPrefix("rgb(") {
    return parseRgbColor(trimmed)
  }
  return nil
}

private func parseHexColor(_ value: String) -> UIColor? {
  var hex = value
  if hex.hasPrefix("#") {
    hex.removeFirst()
  }
  if hex.count == 3 || hex.count == 4 {
    hex = hex.map { "\($0)\($0)" }.joined()
  }
  guard hex.count == 6 || hex.count == 8 else {
    return nil
  }

  var rgba: UInt64 = 0
  guard Scanner(string: hex).scanHexInt64(&rgba) else {
    return nil
  }

  if hex.count == 6 {
    let r = CGFloat((rgba & 0xFF0000) >> 16) / 255.0
    let g = CGFloat((rgba & 0x00FF00) >> 8) / 255.0
    let b = CGFloat(rgba & 0x0000FF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: 1.0)
  }

  let r = CGFloat((rgba & 0xFF000000) >> 24) / 255.0
  let g = CGFloat((rgba & 0x00FF0000) >> 16) / 255.0
  let b = CGFloat((rgba & 0x0000FF00) >> 8) / 255.0
  let a = CGFloat(rgba & 0x000000FF) / 255.0
  return UIColor(red: r, green: g, blue: b, alpha: a)
}

private func parseRgbColor(_ value: String) -> UIColor? {
  guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close else {
    return nil
  }
  let args = value[value.index(after: open)..<close].split(separator: ",").map {
    $0.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  guard args.count == 3 || args.count == 4 else {
    return nil
  }

  guard
    let r = Double(args[0]),
    let g = Double(args[1]),
    let b = Double(args[2])
  else {
    return nil
  }
  let a = args.count == 4 ? (Double(args[3]) ?? 1.0) : 1.0
  return UIColor(
    red: CGFloat(max(0.0, min(255.0, r)) / 255.0),
    green: CGFloat(max(0.0, min(255.0, g)) / 255.0),
    blue: CGFloat(max(0.0, min(255.0, b)) / 255.0),
    alpha: CGFloat(max(0.0, min(1.0, a)))
  )
}
