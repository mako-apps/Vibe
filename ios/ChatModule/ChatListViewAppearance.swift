import UIKit

struct ChatListAppearance {
  let backgroundMode: String
  let wallpaperGradient: [UIColor]
  let wallpaperOpacity: CGFloat
  let wallpaperPatternGradient: [UIColor]
  let wallpaperPatternLocations: [NSNumber]?
  let wallpaperPatternOpacity: CGFloat
  let wallpaperMaskKey: String?

  let bubbleMeGradient: [UIColor]
  let bubbleThemGradient: [UIColor]
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

  /// Shared brand accent fallback used wherever code needs an
  /// agent/accent color and no per-chat appearance is available yet — bubble tint,
  /// agent border, reply/mention bars, profile default accent, progress rings, etc.
  static let brandAccentFallback = UIColor(red: 0.1843, green: 0.6196, blue: 0.5765, alpha: 1.0)

  // Vibe Aurora fallback: near-black base, low-contrast doodle ink, and a
  // teal-leaning outgoing bubble so missing native payloads do not look Telegram-like.
  static let fallback = ChatListAppearance(
    backgroundMode: "gradient",
    wallpaperGradient: [
      UIColor(red: 0.0196, green: 0.0196, blue: 0.0431, alpha: 1.0),  // #05050B
      UIColor(red: 0.0196, green: 0.0196, blue: 0.0431, alpha: 1.0),  // #05050B
    ],
    wallpaperOpacity: 1.0,
    wallpaperPatternGradient: [
      UIColor(red: 0.4980, green: 0.3529, blue: 0.9412, alpha: 1.0),  // #7F5AF0
      UIColor(red: 0.1137, green: 0.7216, blue: 0.6510, alpha: 1.0),  // #1DB8A6
      UIColor(red: 0.8196, green: 0.4353, blue: 0.3451, alpha: 1.0),  // #D16F58
    ],
    wallpaperPatternLocations: [0.0, 0.50, 1.0],
    wallpaperPatternOpacity: 0.17,
    wallpaperMaskKey: "doodles",
    bubbleMeGradient: [
      UIColor(red: 0.5451, green: 0.4863, blue: 1.0, alpha: 1.0),  // #8B7CFF
      UIColor(red: 0.0314, green: 0.7765, blue: 0.7059, alpha: 1.0),  // #08C6B4
    ],
    bubbleThemGradient: [
      UIColor(red: 0.1451, green: 0.1608, blue: 0.2118, alpha: 1.0),  // #252936
      UIColor(red: 0.1020, green: 0.1255, blue: 0.1725, alpha: 1.0),  // #1A202C
    ],
    bubbleThemColor: UIColor(red: 0.1451, green: 0.1608, blue: 0.2118, alpha: 1.0),
    textColorMe: .white,
    textColorThem: UIColor(white: 0.94, alpha: 1.0),
    timeColorMe: UIColor(white: 1.0, alpha: 0.68),
    timeColorThem: UIColor(white: 1.0, alpha: 0.52),
    dayTextColor: UIColor(white: 0.95, alpha: 0.88),
    dayBackgroundColor: UIColor(red: 0.0706, green: 0.0824, blue: 0.1255, alpha: 0.74),
    dayBorderColor: UIColor(white: 1.0, alpha: 0.14),
    insertionAnimationMode: 2
  )

  static func from(raw: [String: Any]?) -> ChatListAppearance {
    guard let raw else {
      return .fallback
    }

    if let nativeResolved = nativePresetAppearance(from: raw, fallback: .fallback) {
      return nativeResolved
    }

    let fallback = ChatListAppearance.fallback
    let mode = (raw["backgroundMode"] as? String) ?? fallback.backgroundMode
    let gradientStrings = raw["wallpaperGradient"] as? [String]
    let patternGradientStrings = raw["wallpaperPatternGradient"] as? [String]
    let meGradientStrings = raw["bubbleMeGradient"] as? [String]
    let themGradientStrings = raw["bubbleThemGradient"] as? [String]

    let bubbleThemColor = parseColor(raw["bubbleThemColor"] as? String) ?? fallback.bubbleThemColor
    let wallpaperGradient = parseGradient(gradientStrings, fallback: fallback.wallpaperGradient)
    let wallpaperPatternGradient = parseGradient(
      patternGradientStrings, fallback: fallback.wallpaperPatternGradient)
    let bubbleMeGradient = parseGradient(meGradientStrings, fallback: fallback.bubbleMeGradient)
    let bubbleThemGradient = parseGradient(
      themGradientStrings,
      fallback: [bubbleThemColor, bubbleThemColor]
    )
    let textColorMe = parseColor(raw["textColorMe"] as? String) ?? fallback.textColorMe
    let textColorThem = parseColor(raw["textColorThem"] as? String) ?? fallback.textColorThem
    let isDark = isDarkColor(wallpaperGradient.first ?? fallback.wallpaperGradient.first ?? .black)
    let dayPlateBase = resolvedDayPlateBase(
      bubbleThemColor: bubbleThemColor,
      wallpaperGradient: wallpaperGradient,
      isDark: isDark
    )
    return ChatListAppearance(
      backgroundMode: mode,
      wallpaperGradient: wallpaperGradient,
      wallpaperOpacity: CGFloat((raw["wallpaperOpacity"] as? NSNumber)?.doubleValue ?? 1.0),
      wallpaperPatternGradient: wallpaperPatternGradient,
      wallpaperPatternLocations: parseNumberArray(raw["wallpaperPatternLocations"]),
      wallpaperPatternOpacity: CGFloat(
        (raw["wallpaperPatternOpacity"] as? NSNumber)?.doubleValue ?? 0.0),
      wallpaperMaskKey: normalizedString(raw["wallpaperMaskKey"]),
      bubbleMeGradient: bubbleMeGradient,
      bubbleThemGradient: bubbleThemGradient,
      bubbleThemColor: bubbleThemColor,
      textColorMe: textColorMe,
      textColorThem: textColorThem,
      timeColorMe: parseColor(raw["timeColorMe"] as? String) ?? fallback.timeColorMe,
      timeColorThem: parseColor(raw["timeColorThem"] as? String)
        ?? colorWithAlpha(textColorThem, isDark ? 0.62 : 0.56),
      dayTextColor: parseColor(raw["dayTextColor"] as? String)
        ?? colorWithAlpha(textColorThem, isDark ? 0.90 : 0.84),
      dayBackgroundColor: parseColor(raw["dayBackgroundColor"] as? String)
        ?? colorWithAlpha(dayPlateBase, isDark ? 0.84 : 0.76),
      dayBorderColor: parseColor(raw["dayBorderColor"] as? String)
        ?? colorWithAlpha(textColorThem, isDark ? 0.08 : 0.10),
      insertionAnimationMode: (raw["insertionAnimationMode"] as? NSNumber)?.intValue
        ?? fallback.insertionAnimationMode
    )
  }

  var visualKey: String {
    let wallpaperKey = wallpaperGradient.map(colorKey).joined(separator: ",")
    let wallpaperPatternKey = wallpaperPatternGradient.map(colorKey).joined(separator: ",")
    let wallpaperPatternLocationsKey =
      wallpaperPatternLocations?.map { String(format: "%.4f", $0.doubleValue) }.joined(
        separator: ",")
      ?? ""
    let meKey = bubbleMeGradient.map(colorKey).joined(separator: ",")
    let themKey = bubbleThemGradient.map(colorKey).joined(separator: ",")
    return [
      backgroundMode,
      String(format: "%.4f", wallpaperOpacity),
      wallpaperKey,
      wallpaperPatternKey,
      wallpaperPatternLocationsKey,
      String(format: "%.4f", wallpaperPatternOpacity),
      wallpaperMaskKey ?? "",
      meKey,
      themKey,
      colorKey(bubbleThemColor),
      colorKey(textColorMe),
      colorKey(textColorThem),
      colorKey(timeColorMe),
      colorKey(timeColorThem),
      colorKey(dayTextColor),
      colorKey(dayBackgroundColor),
      colorKey(dayBorderColor),
    ].joined(separator: "|")
  }

  /// Derives whether this appearance is "dark" by inspecting
  /// the luminance of the primary wallpaper gradient colour.
  var isDark: Bool {
    guard let firstColor = wallpaperGradient.first else { return true }
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    if firstColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
      let luminance = 0.299 * r + 0.587 * g + 0.114 * b
      return luminance < 0.5
    }
    return true
  }

  var hasPatternWallpaper: Bool {
    backgroundMode != "transparent"
      && wallpaperPatternGradient.count >= 2
      && wallpaperPatternOpacity > 0.001
      && (wallpaperMaskKey?.isEmpty == false)
  }

  var wallpaperAnchorColor: UIColor {
    let wallFirst = wallpaperGradient.first ?? (isDark ? UIColor.black : UIColor.white)
    let wallLast = wallpaperGradient.last ?? wallFirst
    return blendColor(wallFirst, with: wallLast, amount: 0.42)
  }

  var incomingBasePlateColor: UIColor {
    blendColor(
      bubbleThemGradient.first ?? bubbleThemColor,
      with: bubbleThemGradient.last ?? bubbleThemColor,
      amount: 0.5
    )
  }

  var outgoingBasePlateColor: UIColor {
    blendColor(
      bubbleMeGradient.first ?? bubbleThemColor,
      with: bubbleMeGradient.last ?? bubbleThemColor,
      amount: 0.5
    )
  }

  var incomingWallpaperSampleOpacity: CGFloat {
    guard backgroundMode != "transparent" else { return 0.0 }
    if hasPatternWallpaper {
      return isDark ? 0.10 : 0.045
    }
    return isDark ? 0.04 : 0.03
  }

  var outgoingWallpaperSampleOpacity: CGFloat {
    guard backgroundMode != "transparent" else { return 0.0 }
    if hasPatternWallpaper {
      return isDark ? 0.075 : 0.045
    }
    return isDark ? 0.03 : 0.02
  }

  var incomingPlateFillOpacity: CGFloat {
    if hasPatternWallpaper {
      return isDark ? 0.95 : 0.985
    }
    if backgroundMode != "transparent" {
      return isDark ? 0.985 : 0.98
    }
    return isDark ? 0.90 : 0.94
  }

  var outgoingPlateFillOpacity: CGFloat {
    if hasPatternWallpaper {
      return isDark ? 0.965 : 0.985
    }
    if backgroundMode != "transparent" {
      return isDark ? 0.99 : 0.985
    }
    return 0.0
  }

  private var wallpaperToneSamplingData: (colors: [UIColor], locations: [CGFloat]) {
    if hasPatternWallpaper, wallpaperPatternGradient.count >= 2 {
      return normalizedGradientSamplingData(
        colors: wallpaperPatternGradient,
        locations: wallpaperPatternLocations
      )
    }
    return normalizedGradientSamplingData(colors: wallpaperGradient, locations: nil)
  }

  func wallpaperPlateColor(
    isMe: Bool,
    sampleRect: CGRect,
    containerSize: CGSize
  ) -> UIColor {
    let baseColor = isMe ? outgoingBasePlateColor : incomingBasePlateColor
    guard backgroundMode != "transparent" else {
      return baseColor
    }

    let samplePoint = CGPoint(x: sampleRect.midX, y: sampleRect.midY)
    let wallpaperColor = wallpaperToneColor(at: samplePoint, containerSize: containerSize)
    if isMe {
      let tinted = blendColor(
        baseColor,
        with: wallpaperColor,
        amount: hasPatternWallpaper ? (isDark ? 0.30 : 0.14) : (isDark ? 0.10 : 0.04)
      )
      return blendColor(
        tinted,
        with: isDark ? UIColor.black : UIColor.white,
        amount: hasPatternWallpaper ? (isDark ? 0.04 : 0.08) : (isDark ? 0.08 : 0.03)
      )
    }

    let darkerIncomingReference = blendColor(
      bubbleThemGradient.first ?? bubbleThemColor,
      with: bubbleThemGradient.last ?? bubbleThemColor,
      amount: 0.82
    )
    let isolatedIncomingBase = blendColor(
      baseColor,
      with: darkerIncomingReference,
      amount: hasPatternWallpaper ? 0.76 : 0.58
    )
    if hasPatternWallpaper && !isDark {
      let softWallpaper = blendColor(wallpaperColor, with: UIColor.white, amount: 0.62)
      let tinted = blendColor(isolatedIncomingBase, with: softWallpaper, amount: 0.12)
      return blendColor(tinted, with: UIColor.white, amount: 0.18)
    }
    let anchoredIncomingWallpaper =
      hasPatternWallpaper
      ? blendColor(wallpaperColor, with: UIColor.black, amount: isDark ? 0.34 : 0.16)
      : blendColor(wallpaperColor, with: wallpaperAnchorColor, amount: 0.80)
    let tinted = blendColor(
      isolatedIncomingBase,
      with: anchoredIncomingWallpaper,
      amount: hasPatternWallpaper ? (isDark ? 0.38 : 0.24) : (isDark ? 0.06 : 0.04)
    )
    let harmonized = blendColor(
      tinted,
      with: darkerIncomingReference,
      amount: hasPatternWallpaper ? 0.30 : 0.10
    )
    return blendColor(
      harmonized,
      with: UIColor.black,
      amount: hasPatternWallpaper ? (isDark ? 0.14 : 0.09) : (isDark ? 0.15 : 0.08)
    )
  }

  func agentWallpaperPlateColor(
    isMe: Bool,
    sampleRect: CGRect,
    containerSize: CGSize,
    accent: UIColor?
  ) -> UIColor {
    let baseColor = wallpaperPlateColor(
      isMe: isMe,
      sampleRect: sampleRect,
      containerSize: containerSize
    )
    guard backgroundMode != "transparent" else {
      return baseColor
    }

    let samplePoint = CGPoint(x: sampleRect.midX, y: sampleRect.midY)
    let wallpaperColor = wallpaperToneColor(at: samplePoint, containerSize: containerSize)
    let paletteAccent = blendColor(
      bubbleMeGradient.first ?? baseColor,
      with: bubbleMeGradient.last ?? baseColor,
      amount: 0.46
    )
    let agentAccent = accent ?? paletteAccent
    let syncedAccent = blendColor(
      agentAccent,
      with: wallpaperColor,
      amount: hasPatternWallpaper ? (isDark ? 0.34 : 0.12) : (isDark ? 0.16 : 0.06)
    )
    let accentAmount: CGFloat
    if isMe {
      accentAmount = hasPatternWallpaper ? (isDark ? 0.20 : 0.10) : (isDark ? 0.14 : 0.06)
    } else {
      accentAmount = hasPatternWallpaper ? (isDark ? 0.20 : 0.07) : (isDark ? 0.12 : 0.04)
    }
    let balanced = blendColor(
      baseColor,
      with: syncedAccent,
      amount: accentAmount
    )
    return blendColor(
      balanced,
      with: isDark ? UIColor.black : UIColor.white,
      amount: isMe ? (isDark ? 0.02 : 0.08) : (isDark ? 0.08 : 0.14)
    )
  }

  private func wallpaperToneColor(at point: CGPoint, containerSize: CGSize) -> UIColor {
    guard containerSize.width > 1.0, containerSize.height > 1.0 else {
      return wallpaperAnchorColor
    }
    let normalizedX = clampUnit(point.x / containerSize.width)
    let normalizedY = clampUnit(point.y / containerSize.height)
    let diagonalProgress = clampUnit((((normalizedX * 0.22) + (normalizedY * 0.78)) - 0.04) * 1.12)
    let samplingData = wallpaperToneSamplingData
    return interpolatedGradientColor(
      colors: samplingData.colors,
      locations: samplingData.locations,
      at: diagonalProgress
    )
  }
}

private struct NativeThemeVariant {
  let backgroundGradient: [String]
  let bubbleMe: String
  let bubbleMeGradient: [String]
  let bubbleThem: String
  let bubbleThemGradient: [String]
  let patternGradientColors: [String]
  let patternGradientLocations: [Double]
  let patternOpacity: Double
  let textColorMe: String
  let textColorThem: String
}

private struct NativeThemePreset {
  let id: String
  let maskedImage: String?
  let light: NativeThemeVariant
  let dark: NativeThemeVariant
}

private func nativePresetAppearance(
  from raw: [String: Any],
  fallback: ChatListAppearance
) -> ChatListAppearance? {
  guard
    let themeId = normalizedString(raw["nativeThemeId"]),
    let preset = nativePreset(for: themeId)
  else {
    return nil
  }
  let isDark = parseBool(raw["nativeThemeIsDark"]) ?? true
  let mode = (raw["backgroundMode"] as? String) ?? fallback.backgroundMode
  let wallpaperOpacity = CGFloat((raw["wallpaperOpacity"] as? NSNumber)?.doubleValue ?? 1.0)
  let insertionAnimationMode =
    (raw["insertionAnimationMode"] as? NSNumber)?.intValue ?? fallback.insertionAnimationMode

  let variant = isDark ? preset.dark : preset.light

  let wallpaperGradient = parseGradient(
    (raw["wallpaperGradient"] as? [String]) ?? variant.backgroundGradient,
    fallback: fallback.wallpaperGradient)
  let patternGradient = parseGradient(
    (raw["wallpaperPatternGradient"] as? [String]) ?? variant.patternGradientColors,
    fallback: [])
  let bubbleMeGradient = parseGradient(
    (raw["bubbleMeGradient"] as? [String]) ?? variant.bubbleMeGradient,
    fallback: fallback.bubbleMeGradient)
  let rawBubbleThemColor =
    parseColor(raw["bubbleThemColor"] as? String)
    ?? parseColor(variant.bubbleThemGradient.first)
    ?? parseColor(variant.bubbleThem)
    ?? fallback.bubbleThemColor
  let resolvedBubbleThemColor = rawBubbleThemColor
  let textColorMe = parseColor(raw["textColorMe"] as? String) ?? parseColor(variant.textColorMe)
    ?? fallback.textColorMe
  let textColorThem =
    parseColor(raw["textColorThem"] as? String) ?? parseColor(variant.textColorThem)
    ?? fallback.textColorThem
  let dayPlateBase = resolvedDayPlateBase(
    bubbleThemColor: resolvedBubbleThemColor,
    wallpaperGradient: wallpaperGradient,
    isDark: isDark
  )
  return ChatListAppearance(
    backgroundMode: mode,
    wallpaperGradient: wallpaperGradient,
    wallpaperOpacity: wallpaperOpacity,
    wallpaperPatternGradient: patternGradient,
    wallpaperPatternLocations: parseNumberArray(raw["wallpaperPatternLocations"])
      ?? variant.patternGradientLocations.map { NSNumber(value: $0) },
    wallpaperPatternOpacity: CGFloat(
      (raw["wallpaperPatternOpacity"] as? NSNumber)?.doubleValue ?? variant.patternOpacity),
    wallpaperMaskKey: normalizedString(raw["wallpaperMaskKey"]) ?? preset.maskedImage,
    bubbleMeGradient: bubbleMeGradient,
    bubbleThemGradient: parseGradient(
      raw["bubbleThemGradient"] as? [String],
      fallback: variant.bubbleThemGradient.compactMap(parseColor)
    ),
    bubbleThemColor: resolvedBubbleThemColor,
    textColorMe: textColorMe,
    textColorThem: textColorThem,
    timeColorMe: parseColor(raw["timeColorMe"] as? String) ?? colorWithAlpha(textColorMe, 0.72),
    timeColorThem: parseColor(raw["timeColorThem"] as? String)
      ?? colorWithAlpha(textColorThem, isDark ? 0.62 : 0.56),
    dayTextColor: parseColor(raw["dayTextColor"] as? String)
      ?? colorWithAlpha(textColorThem, isDark ? 0.90 : 0.84),
    dayBackgroundColor: parseColor(raw["dayBackgroundColor"] as? String)
      ?? colorWithAlpha(dayPlateBase, isDark ? 0.84 : 0.76),
    dayBorderColor: parseColor(raw["dayBorderColor"] as? String)
      ?? colorWithAlpha(textColorThem, isDark ? 0.08 : 0.10),
    insertionAnimationMode: insertionAnimationMode
  )
}

private func nativePreset(for id: String) -> NativeThemePreset? {
  switch id {
  case "glacier":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#F7FAFF", "#EEF7F8"],
        bubbleMe: "#3F6EF5",
        bubbleMeGradient: ["#6E5BFF", "#14C8B8"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#A88FF5", "#5AD4C7", "#E89A89"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#05050B", "#05050B"],
        bubbleMe: "#12B8A7",
        bubbleMeGradient: ["#8B7CFF", "#08C6B4"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#7F5AF0", "#1DB8A6", "#D16F58"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  case "zen":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#F4F8FA", "#E9F0F5"],
        bubbleMe: "#1976D2",
        bubbleMeGradient: ["#4B9BFF", "#9C62F0"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#7EB6FF", "#B084F5", "#FF8DA1"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#03070C", "#03070C"],
        bubbleMe: "#2F80ED",
        bubbleMeGradient: ["#1E90FF", "#7F5AF0"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#2F80ED", "#8B4CF5", "#F0516A"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  case "ocean":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#EAF8D8", "#EAF8D8"],
        bubbleMe: "#38C7A5",
        bubbleMeGradient: ["#38C7A5", "#73C74B"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#75D4C3", "#95D475", "#F5DD6A"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#020806", "#020806"],
        bubbleMe: "#2EB872",
        bubbleMeGradient: ["#08C6B4", "#28B463"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#1DB8A6", "#2EB872", "#F0DB35"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  case "obsidian":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#F6F6F4", "#ECEEF1"],
        bubbleMe: "#4A78C2",
        bubbleMeGradient: ["#5A6B8C", "#4A78C2"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#B8C0D0", "#A3C2F0", "#D0B8E6"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#030304", "#050607"],
        bubbleMe: "#4287F5",
        bubbleMeGradient: ["#475569", "#3B82F6"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#64748B", "#4287F5", "#A64DFF"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  case "music":
    return NativeThemePreset(
      id: id,
      maskedImage: "music",
      light: NativeThemeVariant(
        backgroundGradient: ["#FFF5FA", "#FFF0F1"],
        bubbleMe: "#D63D8C",
        bubbleMeGradient: ["#F051B5", "#A851F0"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#F59AE0", "#D09AF5", "#8EE3F5"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#070306", "#070306"],
        bubbleMe: "#E84AA8",
        bubbleMeGradient: ["#D946EF", "#7F5AF0"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#E84AA8", "#8B4CF5", "#1DB8A6"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  case "terracotta":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#FFF7F0", "#F5ECE5"],
        bubbleMe: "#D9632D",
        bubbleMeGradient: ["#F0830C", "#F0413A"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#F5B97A", "#F5877A", "#F57AC0"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#060302", "#060302"],
        bubbleMe: "#E86D32",
        bubbleMeGradient: ["#FF8C00", "#E82A2A"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#FF9A3D", "#E82A2A", "#D946EF"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  case "leaf":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#EAF7CD", "#C8E8C5"],
        bubbleMe: "#5DB82E",
        bubbleMeGradient: ["#5DB82E", "#2EB8A3"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#A9D67A", "#7AE6D2", "#7AA3F5"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#030704", "#030704"],
        bubbleMe: "#28B463",
        bubbleMeGradient: ["#28B463", "#1DB8A6"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#28B463", "#1DB8A6", "#2F80ED"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  default:
    return nil
  }
}

private func normalizedString(_ raw: Any?) -> String? {
  guard let value = raw as? String else {
    return nil
  }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

private func parseBool(_ raw: Any?) -> Bool? {
  if let value = raw as? Bool {
    return value
  }
  if let value = raw as? NSNumber {
    return value.boolValue
  }
  if let text = raw as? String {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["1", "true", "yes"].contains(normalized) {
      return true
    }
    if ["0", "false", "no"].contains(normalized) {
      return false
    }
  }
  return nil
}

private func parseNumberArray(_ raw: Any?) -> [NSNumber]? {
  if let array = raw as? [NSNumber] {
    return array
  }
  if let array = raw as? [Double] {
    return array.map { NSNumber(value: $0) }
  }
  if let array = raw as? [Int] {
    return array.map { NSNumber(value: $0) }
  }
  if let array = raw as? [String] {
    let parsed = array.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return parsed.count == array.count ? parsed.map { NSNumber(value: $0) } : nil
  }
  return nil
}

private func resolvedDayPlateBase(
  bubbleThemColor: UIColor,
  wallpaperGradient: [UIColor],
  isDark: Bool
) -> UIColor {
  let wallFirst = wallpaperGradient.first ?? (isDark ? UIColor.black : UIColor.white)
  let wallLast = wallpaperGradient.last ?? wallFirst
  let wallpaperAnchor = blendColor(wallFirst, with: wallLast, amount: 0.38)
  return blendColor(bubbleThemColor, with: wallpaperAnchor, amount: isDark ? 0.14 : 0.08)
}

private func softenedBubblePalette(
  bubbleMeGradient: [UIColor],
  bubbleThemColor: UIColor,
  wallpaperGradient: [UIColor],
  isDark: Bool
) -> (me: [UIColor], them: UIColor) {
  let wallFirst = wallpaperGradient.first ?? (isDark ? UIColor.black : UIColor.white)
  let wallLast = wallpaperGradient.last ?? wallFirst
  let wallpaperAnchor = blendColor(wallFirst, with: wallLast, amount: 0.36)

  let softenedMe = bubbleMeGradient.map { color in
    let contrast = contrastRatio(color, wallpaperAnchor)
    let extra = max(0.0, min(0.12, (contrast - (isDark ? 4.2 : 3.8)) * 0.05))
    let mix = (isDark ? 0.12 : 0.10) + extra
    let base = blendColor(color, with: wallpaperAnchor, amount: mix)
    return colorWithAlpha(base, 0.96)
  }

  let themContrast = contrastRatio(bubbleThemColor, wallpaperAnchor)
  let themExtra = max(0.0, min(0.14, (themContrast - (isDark ? 2.6 : 2.2)) * 0.07))
  let themMix = (isDark ? 0.12 : 0.09) + themExtra
  var softenedThem = blendColor(bubbleThemColor, with: wallpaperAnchor, amount: themMix)
  softenedThem = colorWithAlpha(softenedThem, isDark ? 0.94 : 0.96)

  return (me: softenedMe, them: softenedThem)
}

private func blendColor(_ from: UIColor, with to: UIColor, amount: CGFloat) -> UIColor {
  let t = max(0.0, min(1.0, amount))
  var fr: CGFloat = 0
  var fg: CGFloat = 0
  var fb: CGFloat = 0
  var fa: CGFloat = 0
  var tr: CGFloat = 0
  var tg: CGFloat = 0
  var tb: CGFloat = 0
  var ta: CGFloat = 0

  guard from.getRed(&fr, green: &fg, blue: &fb, alpha: &fa),
    to.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
  else {
    return from
  }

  let inv = 1.0 - t
  return UIColor(
    red: (fr * inv) + (tr * t),
    green: (fg * inv) + (tg * t),
    blue: (fb * inv) + (tb * t),
    alpha: (fa * inv) + (ta * t)
  )
}

private func clampUnit(_ value: CGFloat) -> CGFloat {
  min(1.0, max(0.0, value))
}

private func normalizedGradientSamplingData(
  colors: [UIColor],
  locations: [NSNumber]?
) -> (colors: [UIColor], locations: [CGFloat]) {
  guard !colors.isEmpty else {
    return ([.black], [0.0])
  }

  if colors.count == 1 {
    return (colors, [0.0])
  }

  let resolvedLocations: [CGFloat] = {
    if let locations, locations.count == colors.count {
      var lastValue: CGFloat = 0.0
      return locations.enumerated().map { index, value in
        let clamped = clampUnit(CGFloat(truncating: value))
        let monotonic = index == 0 ? clamped : max(lastValue, clamped)
        lastValue = monotonic
        return monotonic
      }
    }

    return (0..<colors.count).map { index in
      CGFloat(index) / CGFloat(max(colors.count - 1, 1))
    }
  }()

  switch colors.count {
  case 2:
    let start = resolvedLocations[0]
    let end = resolvedLocations[1]
    return (
      [
        colors[0],
        blendColor(colors[0], with: colors[1], amount: 0.25),
        blendColor(colors[0], with: colors[1], amount: 0.50),
        blendColor(colors[0], with: colors[1], amount: 0.75),
        colors[1],
      ],
      [
        start,
        start + ((end - start) * 0.25),
        start + ((end - start) * 0.50),
        start + ((end - start) * 0.75),
        end,
      ]
    )
  case 3:
    let start = resolvedLocations[0]
    let middle = resolvedLocations[1]
    let end = resolvedLocations[2]
    return (
      [
        colors[0],
        blendColor(colors[0], with: colors[1], amount: 0.5),
        colors[1],
        blendColor(colors[1], with: colors[2], amount: 0.5),
        colors[2],
      ],
      [
        start,
        start + ((middle - start) * 0.5),
        middle,
        middle + ((end - middle) * 0.5),
        end,
      ]
    )
  case 4:
    let middleLocation = resolvedLocations[1] + ((resolvedLocations[2] - resolvedLocations[1]) * 0.5)
    return (
      [
        colors[0],
        colors[1],
        blendColor(colors[1], with: colors[2], amount: 0.5),
        colors[2],
        colors[3],
      ],
      [
        resolvedLocations[0],
        resolvedLocations[1],
        middleLocation,
        resolvedLocations[2],
        resolvedLocations[3],
      ]
    )
  default:
    return (colors, resolvedLocations)
  }
}

private func interpolatedGradientColor(
  colors: [UIColor],
  locations: [CGFloat]? = nil,
  at progress: CGFloat
) -> UIColor {
  guard !colors.isEmpty else { return .black }
  if colors.count == 1 { return colors[0] }

  let clamped = clampUnit(progress)
  let resolvedLocations: [CGFloat] = {
    if let locations, locations.count == colors.count {
      return locations
    }
    return (0..<colors.count).map { index in
      CGFloat(index) / CGFloat(max(colors.count - 1, 1))
    }
  }()

  if clamped <= resolvedLocations[0] {
    return colors[0]
  }
  if clamped >= resolvedLocations[colors.count - 1] {
    return colors[colors.count - 1]
  }

  for index in 0..<(colors.count - 1) {
    let start = resolvedLocations[index]
    let end = resolvedLocations[index + 1]
    guard clamped >= start, clamped <= end else { continue }
    let distance = max(end - start, 0.0001)
    let localT = clampUnit((clamped - start) / distance)
    return blendColor(colors[index], with: colors[index + 1], amount: localT)
  }

  return colors[colors.count - 1]
}

private func isDarkColor(_ color: UIColor) -> Bool {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return true }
  let luminance = 0.299 * r + 0.587 * g + 0.114 * b
  return luminance < 0.5
}

private func contrastRatio(_ c1: UIColor, _ c2: UIColor) -> CGFloat {
  let l1 = relativeLuminance(c1)
  let l2 = relativeLuminance(c2)
  let hi = max(l1, l2)
  let lo = min(l1, l2)
  return (hi + 0.05) / (lo + 0.05)
}

private func relativeLuminance(_ color: UIColor) -> CGFloat {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0.0 }

  func linear(_ value: CGFloat) -> CGFloat {
    if value <= 0.03928 { return value / 12.92 }
    return pow((value + 0.055) / 1.055, 2.4)
  }

  let lr = linear(r)
  let lg = linear(g)
  let lb = linear(b)
  return (0.2126 * lr) + (0.7152 * lg) + (0.0722 * lb)
}

private func colorWithAlpha(_ color: UIColor, _ alpha: CGFloat) -> UIColor {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var currentAlpha: CGFloat = 0
  if color.getRed(&r, green: &g, blue: &b, alpha: &currentAlpha) {
    return UIColor(red: r, green: g, blue: b, alpha: max(0.0, min(1.0, alpha)))
  }
  if let converted = color.cgColor.converted(
    to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
    let components = converted.components
  {
    if components.count >= 3 {
      let r = components[0]
      let g = components.count > 1 ? components[1] : components[0]
      let b = components.count > 2 ? components[2] : components[0]
      return UIColor(red: r, green: g, blue: b, alpha: max(0.0, min(1.0, alpha)))
    }
  }
  return color.withAlphaComponent(max(0.0, min(1.0, alpha)))
}

private func colorKey(_ color: UIColor) -> String {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
    return String(format: "%.4f,%.4f,%.4f,%.4f", r, g, b, a)
  }
  if let converted = color.cgColor.converted(
    to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
    let components = converted.components
  {
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

private func parseGradient(_ values: [String], fallback: [UIColor]) -> [UIColor] {
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

  let r = CGFloat((rgba & 0xFF00_0000) >> 24) / 255.0
  let g = CGFloat((rgba & 0x00FF_0000) >> 16) / 255.0
  let b = CGFloat((rgba & 0x0000_FF00) >> 8) / 255.0
  let a = CGFloat(rgba & 0x0000_00FF) / 255.0
  return UIColor(red: r, green: g, blue: b, alpha: a)
}

private func parseRgbColor(_ value: String) -> UIColor? {
  guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close
  else {
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
