import SwiftUI
import UIKit
import AVFoundation
import PhotosUI

enum ChatProfileAppearanceMode: String, CaseIterable, Identifiable {
  case avatar
  case poster

  var id: String { rawValue }

  var title: String {
    switch self {
    case .avatar:
      return "Avatar"
    case .poster:
      return "Poster"
    }
  }
}

struct ChatProfileAppearanceSelection: Codable, Equatable {
  var avatarPaletteID: String
  var posterPaletteID: String
  var avatarGlyph: String?
  var avatarFontStyleID: String?
  var avatarCustomStartHex: String?
  var avatarCustomEndHex: String?
  var posterCustomStartHex: String?
  var posterCustomEndHex: String?
  var posterImageData: Data?

  static let `default` = ChatProfileAppearanceSelection(
    avatarPaletteID: ChatProfileAppearancePalette.defaultAvatarID,
    posterPaletteID: ChatProfileAppearancePalette.defaultPosterID,
    avatarGlyph: nil,
    avatarFontStyleID: nil,
    avatarCustomStartHex: nil,
    avatarCustomEndHex: nil,
    posterCustomStartHex: nil,
    posterCustomEndHex: nil,
    posterImageData: nil
  )
}

enum ChatProfileAvatarFontStyle: String, CaseIterable, Identifiable {
  case rounded
  case standard
  case serif
  case mono

  var id: String { rawValue }

  var design: Font.Design {
    switch self {
    case .rounded:
      return .rounded
    case .standard:
      return .default
    case .serif:
      return .serif
    case .mono:
      return .monospaced
    }
  }

  static func style(id: String?) -> ChatProfileAvatarFontStyle {
    guard let id, let style = allCases.first(where: { $0.rawValue == id }) else {
      return .rounded
    }
    return style
  }
}

struct ChatProfileAppearancePalette: Identifiable, Equatable {
  let id: String
  let topHex: String
  let bottomHex: String

  static let defaultAvatarID = "warm-gold"
  static let defaultPosterID = "poster-soft-neutral"

  static let all: [ChatProfileAppearancePalette] = [
    ChatProfileAppearancePalette(id: "warm-gold", topHex: "#F1C766", bottomHex: "#8B411B"),
    ChatProfileAppearancePalette(id: "aurora", topHex: "#8B4CF5", bottomHex: "#008C72"),
    ChatProfileAppearancePalette(id: "lime", topHex: "#F0DB35", bottomHex: "#098B27"),
    ChatProfileAppearancePalette(id: "ocean", topHex: "#23C08D", bottomHex: "#0057A8"),
    ChatProfileAppearancePalette(id: "ember", topHex: "#3E8B69", bottomHex: "#D64A12"),
    ChatProfileAppearancePalette(id: "rose", topHex: "#F39C62", bottomHex: "#7A1E83"),
    ChatProfileAppearancePalette(id: "midnight", topHex: "#2F74D0", bottomHex: "#071B65"),
    ChatProfileAppearancePalette(id: "earth", topHex: "#8C735C", bottomHex: "#4B2413"),
    ChatProfileAppearancePalette(id: "graphite", topHex: "#727A7D", bottomHex: "#06131B"),
    ChatProfileAppearancePalette(id: "ruby", topHex: "#B94F55", bottomHex: "#6A0808"),
    ChatProfileAppearancePalette(id: "teal", topHex: "#35A7A5", bottomHex: "#053746"),
    ChatProfileAppearancePalette(id: "mint", topHex: "#16C995", bottomHex: "#007D4E"),
    ChatProfileAppearancePalette(id: "coral", topHex: "#F0516A", bottomHex: "#B71210"),
    ChatProfileAppearancePalette(id: "marigold", topHex: "#FFE154", bottomHex: "#F0830C"),
    ChatProfileAppearancePalette(id: "steel", topHex: "#8793A1", bottomHex: "#071026"),
    ChatProfileAppearancePalette(id: "poster-soft-neutral", topHex: "#DCD7CF", bottomHex: "#A9876F"),
    ChatProfileAppearancePalette(id: "poster-black", topHex: "#050507", bottomHex: "#000000"),
  ]

  static let defaultAvatarPalettes: [ChatProfileAppearancePalette] = all.filter {
    $0.id != defaultPosterID && $0.id != "poster-black"
  }

  static func palette(id: String) -> ChatProfileAppearancePalette {
    all.first(where: { $0.id == id }) ?? all[0]
  }

  static func colors(
    for selection: ChatProfileAppearanceSelection,
    mode: ChatProfileAppearanceMode
  ) -> (UIColor, UIColor) {
    let palette = palette(id: mode == .avatar ? selection.avatarPaletteID : selection.posterPaletteID)
    let customStart = mode == .avatar ? selection.avatarCustomStartHex : selection.posterCustomStartHex
    let customEnd = mode == .avatar ? selection.avatarCustomEndHex : selection.posterCustomEndHex
    return (
      uiColor(hex: customStart ?? palette.topHex),
      uiColor(hex: customEnd ?? palette.bottomHex)
    )
  }

  static func uiColor(hex raw: String) -> UIColor {
    var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    return UIColor(
      red: CGFloat((value >> 16) & 0xff) / 255.0,
      green: CGFloat((value >> 8) & 0xff) / 255.0,
      blue: CGFloat(value & 0xff) / 255.0,
      alpha: 1.0
    )
  }
}

enum ChatProfileAppearanceStore {
  private static let defaultsPrefix = "chatProfileAppearance.v1."

  static func selection(title: String?, peerUserId: String?, chatId: String?) -> ChatProfileAppearanceSelection {
    let key = defaultsKey(title: title, peerUserId: peerUserId, chatId: chatId)
    guard let data = UserDefaults.standard.data(forKey: key),
      let decoded = try? JSONDecoder().decode(ChatProfileAppearanceSelection.self, from: data)
    else {
      return defaultSelection(title: title, peerUserId: peerUserId, chatId: chatId)
    }
    return normalizedStoredSelection(decoded, title: title, peerUserId: peerUserId, chatId: chatId)
  }

  static func save(
    _ selection: ChatProfileAppearanceSelection,
    title: String?,
    peerUserId: String?,
    chatId: String?
  ) {
    let key = defaultsKey(title: title, peerUserId: peerUserId, chatId: chatId)
    guard let data = try? JSONEncoder().encode(selection) else { return }
    UserDefaults.standard.set(data, forKey: key)
  }

  static func avatarColors(title: String?, peerUserId: String?, chatId: String?) -> (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(
      for: selection(title: title, peerUserId: peerUserId, chatId: chatId),
      mode: .avatar
    )
  }

  static func posterColors(title: String?, peerUserId: String?, chatId: String?) -> (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(
      for: selection(title: title, peerUserId: peerUserId, chatId: chatId),
      mode: .poster
    )
  }

  static func posterImage(title: String?, peerUserId: String?, chatId: String?) -> UIImage? {
    let selection = selection(title: title, peerUserId: peerUserId, chatId: chatId)
    guard let data = selection.posterImageData else { return nil }
    return UIImage(data: data)
  }

  private static func defaultsKey(title: String?, peerUserId: String?, chatId: String?) -> String {
    let seed = defaultsSeed(title: title, peerUserId: peerUserId, chatId: chatId)
    let safeSeed = seed.isEmpty ? "user" : seed
    return defaultsPrefix + safeSeed
  }

  private static func defaultsSeed(title: String?, peerUserId: String?, chatId: String?) -> String {
    ChatAvatarFallbackStyle.stableSeed(
      title: title,
      peerUserId: peerUserId,
      chatId: chatId
    )
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static func defaultSelection(
    title: String?,
    peerUserId: String?,
    chatId: String?
  ) -> ChatProfileAppearanceSelection {
    var selection = ChatProfileAppearanceSelection.default
    selection.avatarPaletteID = defaultAvatarPaletteID(seed: defaultsSeed(
      title: title,
      peerUserId: peerUserId,
      chatId: chatId
    ))
    selection.posterPaletteID = ChatProfileAppearancePalette.defaultPosterID
    return selection
  }

  private static func normalizedStoredSelection(
    _ selection: ChatProfileAppearanceSelection,
    title: String?,
    peerUserId: String?,
    chatId: String?
  ) -> ChatProfileAppearanceSelection {
    var normalized = selection
    if normalized.posterPaletteID == "warm-cocoa" || normalized.posterPaletteID == "poster-black" {
      normalized.posterPaletteID = ChatProfileAppearancePalette.defaultPosterID
    }
    if normalized.avatarPaletteID == ChatProfileAppearancePalette.defaultAvatarID
      && normalized.avatarCustomStartHex == nil
      && normalized.avatarCustomEndHex == nil
      && normalized.avatarGlyph == nil
      && normalized.avatarFontStyleID == nil
    {
      normalized.avatarPaletteID = defaultAvatarPaletteID(seed: defaultsSeed(
        title: title,
        peerUserId: peerUserId,
        chatId: chatId
      ))
    }
    return normalized
  }

  private static func defaultAvatarPaletteID(seed: String) -> String {
    let palettes = ChatProfileAppearancePalette.defaultAvatarPalettes
    guard !palettes.isEmpty else { return ChatProfileAppearancePalette.defaultAvatarID }
    let safeSeed = seed.isEmpty ? "user" : seed
    let hash = safeSeed.unicodeScalars.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1.value) }
    let index = Int(hash % UInt(palettes.count))
    return palettes[index].id
  }
}

private extension UIColor {
  var chatProfileHexString: String {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#000000" }
    return String(
      format: "#%02X%02X%02X",
      Int(round(red * 255.0)),
      Int(round(green * 255.0)),
      Int(round(blue * 255.0))
    )
  }

  func blended(withFraction fraction: CGFloat, of color: UIColor) -> UIColor {
    var red1: CGFloat = 0
    var green1: CGFloat = 0
    var blue1: CGFloat = 0
    var alpha1: CGFloat = 0
    var red2: CGFloat = 0
    var green2: CGFloat = 0
    var blue2: CGFloat = 0
    var alpha2: CGFloat = 0
    guard getRed(&red1, green: &green1, blue: &blue1, alpha: &alpha1),
      color.getRed(&red2, green: &green2, blue: &blue2, alpha: &alpha2)
    else {
      return self
    }
    let clamped = max(0, min(1, fraction))
    return UIColor(
      red: red1 + (red2 - red1) * clamped,
      green: green1 + (green2 - green1) * clamped,
      blue: blue1 + (blue2 - blue1) * clamped,
      alpha: alpha1 + (alpha2 - alpha1) * clamped
    )
  }
}

@MainActor
private final class NativeProfileAvatarModel: ObservableObject {
  @Published var fallbackText: String = "U"
  @Published var loadedImage: UIImage?
  @Published var expandedSize: CGFloat = 100.0
  @Published var collapsedSize: CGFloat = 40.0
  @Published var expandedTopInset: CGFloat = 0.0
  @Published var collapsedTopInset: CGFloat = 0.0
  @Published var scrollOffset: CGFloat = 0.0
  @Published var islandCoverColor: UIColor = UIColor(red: 0.071, green: 0.071, blue: 0.075, alpha: 1.0)
  @Published var fallbackBackgroundColor: UIColor = UIColor(
    red: 222 / 255,
    green: 230 / 255,
    blue: 243 / 255,
    alpha: 1.0
  )
  @Published var fallbackGradientEndColor: UIColor = UIColor(
    red: 139 / 255,
    green: 65 / 255,
    blue: 27 / 255,
    alpha: 1.0
  )
  @Published var fallbackIconTintColor: UIColor = UIColor.darkText

  private var imageUri: String?
  private var imageTask: Task<Void, Never>?

  deinit {
    imageTask?.cancel()
  }

  func setImageUri(_ value: String?) {
    let normalizedValue = value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty

    guard normalizedValue != imageUri else { return }
    imageUri = normalizedValue
    imageTask?.cancel()

    guard let normalizedValue else {
      loadedImage = nil
      return
    }

    // Serve from cache immediately so reopening the profile shows no fallback flicker.
    if let cached = ChatAvatarImageStore.cached(for: normalizedValue) {
      loadedImage = cached
      return
    }

    loadedImage = nil
    imageTask = Task { [weak self] in
      let image = await NativeProfileAvatarImageLoader.load(from: normalizedValue)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard let self, self.imageUri == normalizedValue else { return }
        self.loadedImage = image
      }
    }
  }

  /// Directly set a locally-rendered image that has no source URL — e.g. the group
  /// mosaic composed from member avatars. Clears any pending URL load and the
  /// tracked `imageUri` so a later `setImageUri(nil)` on the same (group) refresh
  /// path is a no-op and doesn't wipe the composite.
  func setComposedImage(_ image: UIImage?) {
    imageTask?.cancel()
    imageUri = nil
    loadedImage = image
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

private enum NativeProfileAvatarImageLoader {
  static func load(from rawValue: String?) async -> UIImage? {
    await ChatAvatarImageStore.load(from: rawValue)
  }
}

enum NativeProfileAvatarHeroMetrics {
  static let topAdjust: CGFloat = 12
  static let islandAnchor: CGFloat = 56
  static let topOffset: CGFloat = 86
  static let collapsedTopOffset: CGFloat = 18
  static let expandedSize: CGFloat = 196
  static let collapsedSize: CGFloat = 34
  static let bottomSpacing: CGFloat = 14

  static func expandedTop(for safeTop: CGFloat) -> CGFloat {
    max(0, safeTop - islandAnchor - topAdjust) + topOffset
  }

  static func collapsedTop(for safeTop: CGFloat) -> CGFloat {
    max(0, safeTop - 18 - collapsedTopOffset)
  }

  static func hostHeight(for safeTop: CGFloat) -> CGFloat {
    expandedTop(for: safeTop) + expandedSize + bottomSpacing
  }
}

private struct NativeProfileAvatarContentView: View {
  @ObservedObject var model: NativeProfileAvatarModel

  var body: some View {
    NativeProfileAvatarLegacyView(model: model)
  }
}

private struct NativeProfileAvatarInnerContent: View {
  let image: UIImage?
  let fallbackText: String
  let fallbackIconTintColor: UIColor
  let fallbackBackgroundColor: UIColor
  let fallbackGradientEndColor: UIColor
  let size: CGFloat

  var body: some View {
    ZStack {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: size * 3.25, height: size * 2.25)
          .blur(radius: max(22, size * 0.24))
          .opacity(0.50)
          .saturation(1.22)
      }

      if let image {
        ZStack {
          LinearGradient(
            colors: [
              Color(uiColor: fallbackBackgroundColor),
              Color(uiColor: fallbackGradientEndColor),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )

          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
          Circle()
            .stroke(Color.white.opacity(0.20), lineWidth: 1)
        }
      } else {
        ZStack {
          LinearGradient(
            colors: [
              Color(uiColor: fallbackBackgroundColor),
              Color(uiColor: fallbackGradientEndColor),
            ],
            startPoint: .top,
            endPoint: .bottom
          )

          Text(fallbackText)
            .font(.system(size: max(28.0, size * 0.50), weight: .bold))
            .foregroundStyle(Color(uiColor: fallbackIconTintColor))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .padding(.horizontal, size * 0.14)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
          Circle()
            .stroke(Color.white.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 4)
      }
    }
  }
}

private struct NativeProfileAvatarLegacyView: View {
  @ObservedObject var model: NativeProfileAvatarModel

  private var progress: CGFloat {
    max(0.0, min(1.0, model.scrollOffset / 220.0))
  }

  private var currentSize: CGFloat {
    model.expandedSize - (22.0 * progress)
  }

  private var currentTopInset: CGFloat {
    model.expandedTopInset - (10.0 * progress)
  }

  var body: some View {
    NativeProfileAvatarInnerContent(
      image: model.loadedImage,
      fallbackText: model.fallbackText,
      fallbackIconTintColor: model.fallbackIconTintColor,
      fallbackBackgroundColor: model.fallbackBackgroundColor,
      fallbackGradientEndColor: model.fallbackGradientEndColor,
      size: currentSize
    )
    .padding(.top, currentTopInset)
    .opacity(1.0)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

final class NativeProfileAvatarView: UIView {
  private let model = NativeProfileAvatarModel()
  private let hostingController: UIHostingController<AnyView>
  private var isHostingControllerAttached = false
  private var currentImageUri: String?
  private var currentFallbackText: String = "U"
  private var currentExpandedSize: CGFloat = 100.0
  private var currentCollapsedSize: CGFloat = 40.0
  private var currentExpandedTopInset: CGFloat = 0.0
  private var currentCollapsedTopInset: CGFloat = 0.0
  private var currentScrollOffset: CGFloat = 0.0
  private var currentIslandCoverColor: UIColor = UIColor(red: 0.071, green: 0.071, blue: 0.075, alpha: 1.0)
  private var currentFallbackBackgroundColor: UIColor = UIColor(
    red: 222 / 255,
    green: 230 / 255,
    blue: 243 / 255,
    alpha: 1.0
  )
  private var currentFallbackGradientEndColor: UIColor = UIColor(
    red: 139 / 255,
    green: 65 / 255,
    blue: 27 / 255,
    alpha: 1.0
  )
  private var currentFallbackIconTintColor: UIColor = UIColor.darkText

  override init(frame: CGRect) {
    hostingController = UIHostingController(
      rootView: AnyView(NativeProfileAvatarContentView(model: model))
    )
    super.init(frame: frame)

    backgroundColor = .clear
    clipsToBounds = false

    if #available(iOS 16.4, *) {
      hostingController.safeAreaRegions = []
    }

    let hostedView = hostingController.view!
    hostedView.translatesAutoresizingMaskIntoConstraints = false
    hostedView.backgroundColor = .clear
    hostedView.clipsToBounds = false
    addSubview(hostedView)

    NSLayoutConstraint.activate([
      hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostedView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostedView.topAnchor.constraint(equalTo: topAnchor),
      hostedView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil, !isHostingControllerAttached {
      if let parentVC = findNearestViewController() {
        parentVC.addChild(hostingController)
        hostingController.didMove(toParent: parentVC)
        isHostingControllerAttached = true
      }
    } else if window == nil, isHostingControllerAttached {
      hostingController.willMove(toParent: nil)
      hostingController.removeFromParent()
      isHostingControllerAttached = false
    }
  }

  private func findNearestViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let next = responder?.next {
      if let vc = next as? UIViewController {
        return vc
      }
      responder = next
    }
    return nil
  }

  func setImageUri(_ value: String?) {
    let nextValue = value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
    guard currentImageUri != nextValue else { return }
    currentImageUri = nextValue
    publishModelChange { $0.setImageUri(nextValue) }
  }

  /// Show a locally-composed image (the group mosaic) with no backing URL.
  func setComposedImage(_ image: UIImage?) {
    currentImageUri = nil
    publishModelChange { $0.setComposedImage(image) }
  }

  func setFallbackText(_ value: String?) {
    let nextValue =
      (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : "U") ?? "U"
    guard currentFallbackText != nextValue else { return }
    currentFallbackText = nextValue
    publishModelChange { $0.fallbackText = nextValue }
  }

  func setExpandedSize(_ value: CGFloat?) {
    let resolved = max(1.0, value ?? 100.0)
    guard currentExpandedSize != resolved else { return }
    currentExpandedSize = resolved
    publishModelChange { $0.expandedSize = resolved }
  }

  func setCollapsedSize(_ value: CGFloat?) {
    let resolved = max(1.0, value ?? 40.0)
    guard currentCollapsedSize != resolved else { return }
    currentCollapsedSize = resolved
    publishModelChange { $0.collapsedSize = resolved }
  }

  func setExpandedTopInset(_ value: CGFloat?) {
    let resolved = max(0.0, value ?? 0.0)
    guard currentExpandedTopInset != resolved else { return }
    currentExpandedTopInset = resolved
    publishModelChange { $0.expandedTopInset = resolved }
  }

  func setCollapsedTopInset(_ value: CGFloat?) {
    let resolved = max(0.0, value ?? 0.0)
    guard currentCollapsedTopInset != resolved else { return }
    currentCollapsedTopInset = resolved
    publishModelChange { $0.collapsedTopInset = resolved }
  }

  func setScrollOffset(_ value: CGFloat?) {
    let resolved = max(0.0, value ?? 0.0)
    guard currentScrollOffset != resolved else { return }
    currentScrollOffset = resolved
    publishModelChange { $0.scrollOffset = resolved }
  }

  func setIslandCoverUIColor(_ value: UIColor) {
    guard currentIslandCoverColor != value else { return }
    currentIslandCoverColor = value
    publishModelChange { $0.islandCoverColor = value }
  }

  func setFallbackBackgroundUIColor(_ value: UIColor) {
    guard currentFallbackBackgroundColor != value else { return }
    currentFallbackBackgroundColor = value
    publishModelChange {
      $0.fallbackBackgroundColor = value
      $0.fallbackGradientEndColor = value
    }
  }

  func setFallbackGradientUIColors(start: UIColor, end: UIColor) {
    guard currentFallbackBackgroundColor != start || currentFallbackGradientEndColor != end else { return }
    currentFallbackBackgroundColor = start
    currentFallbackGradientEndColor = end
    publishModelChange {
      $0.fallbackBackgroundColor = start
      $0.fallbackGradientEndColor = end
    }
  }

  func setFallbackIconTintUIColor(_ value: UIColor) {
    guard currentFallbackIconTintColor != value else { return }
    currentFallbackIconTintColor = value
    publishModelChange { $0.fallbackIconTintColor = value }
  }

  private func publishModelChange(_ update: @escaping (NativeProfileAvatarModel) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      update(self.model)
    }
  }
}

private struct ChatProfileRow {
  let messageId: String
  let type: String
  let text: String
  let mediaUrl: String?
  let localMediaUrl: String?
  let mediaKey: String?
  let fileName: String?
  let fileSize: Int64?
  let timestampMs: Int64?
  let isPinned: Bool
  let isAgentMessage: Bool
  let duration: CGFloat?
  let waveform: [CGFloat]?
  let thumbnailBase64: String?

  static func parse(_ raw: [String: Any]) -> ChatProfileRow? {
    let message = raw["message"] as? [String: Any] ?? raw
    let metadata = message["metadata"] as? [String: Any]
    let messageId =
      (message["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? UUID().uuidString
    let type = ((message["type"] as? String) ?? (raw["type"] as? String) ?? "text").lowercased()
    let text = (message["text"] as? String) ?? (raw["text"] as? String) ?? ""
    let localMediaUrl =
      (message["localMediaUrl"] as? String)
      ?? (message["local_media_url"] as? String)
      ?? (metadata?["localMediaUrl"] as? String)
      ?? (metadata?["local_media_url"] as? String)
    let resolvedLocalMediaUrl =
      localMediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasUsableLocalMedia: Bool = {
      guard let resolvedLocalMediaUrl, !resolvedLocalMediaUrl.isEmpty else { return false }
      let localPath: String
      if let parsed = URL(string: resolvedLocalMediaUrl), parsed.isFileURL {
        localPath = parsed.path
      } else {
        localPath = resolvedLocalMediaUrl
      }
      return FileManager.default.fileExists(atPath: localPath)
    }()
    let remoteMediaUrl =
      (message["mediaUrl"] as? String)
      ?? (message["media_url"] as? String)
      ?? (metadata?["mediaUrl"] as? String)
      ?? (metadata?["media_url"] as? String)
      ?? (raw["mediaUrl"] as? String)
    let mediaUrl = hasUsableLocalMedia ? resolvedLocalMediaUrl : remoteMediaUrl
    let mediaKey =
      (message["mediaKey"] as? String)
      ?? (message["media_key"] as? String)
      ?? (metadata?["mediaKey"] as? String)
      ?? (metadata?["media_key"] as? String)
    let fileName =
      (message["fileName"] as? String)
      ?? (message["file_name"] as? String)
      ?? (metadata?["fileName"] as? String)
      ?? (metadata?["file_name"] as? String)
      ?? (raw["fileName"] as? String)

    let messageFileSizeNumber = message["fileSize"] as? NSNumber
    let rawFileSizeNumber = raw["fileSize"] as? NSNumber
    let fileSize = messageFileSizeNumber?.int64Value ?? rawFileSizeNumber?.int64Value

    let timestampRaw =
      message["timestampMs"] ?? message["timestamp"] ?? raw["timestampMs"] ?? raw["timestamp"]
    let timestampMs: Int64? = {
      if let number = timestampRaw as? NSNumber {
        let value = number.int64Value
        return value < 2_000_000_000 ? (value * 1000) : value
      }
      if let text = timestampRaw as? String {
        if let numeric = Double(text), numeric.isFinite {
          let value = Int64(numeric)
          return value < 2_000_000_000 ? (value * 1000) : value
        }
        let parsed = ISO8601DateFormatter().date(from: text)
        if let parsed { return Int64(parsed.timeIntervalSince1970 * 1000.0) }
      }
      return nil
    }()

    let isPinned =
      (message["isPinned"] as? Bool == true)
      || (raw["isPinned"] as? Bool == true)
      || (message["pinned"] as? Bool == true)
      || (raw["pinned"] as? Bool == true)

    let isAgentMessage =
      (message["isAgentMessage"] as? Bool == true)
      || (raw["isAgentMessage"] as? Bool == true)
      || (metadata?["isAgentMessage"] as? Bool == true)
      || ((metadata?["agentBridgeProvider"] as? String)?.isEmpty == false)
      || ((metadata?["agentRuntime"] as? [String: Any]) != nil)

    let duration: CGFloat? = {
      if let val = message["duration"] as? NSNumber { return CGFloat(val.floatValue) }
      if let val = raw["duration"] as? NSNumber { return CGFloat(val.floatValue) }
      return nil
    }()

    let waveform = parseChatProfileWaveform(message["waveform"] ?? raw["waveform"])

    let thumbnailBase64 =
      (message["thumbnailBase64"] as? String)
      ?? (message["thumbnail_base64"] as? String)
      ?? (metadata?["thumbnailBase64"] as? String)
      ?? (metadata?["thumbnail_base64"] as? String)
      ?? (raw["thumbnailBase64"] as? String)

    return ChatProfileRow(
      messageId: messageId,
      type: type,
      text: text,
      mediaUrl: mediaUrl,
      localMediaUrl: localMediaUrl,
      mediaKey: mediaKey,
      fileName: fileName,
      fileSize: fileSize,
      timestampMs: timestampMs,
      isPinned: isPinned,
      isAgentMessage: isAgentMessage,
      duration: duration,
      waveform: waveform,
      thumbnailBase64: thumbnailBase64
    )
  }
}

private func normalizeChatProfileWaveformArray(_ rawList: [Any]) -> [CGFloat]? {
  let values: [CGFloat] = rawList.compactMap { item in
    if let number = item as? NSNumber {
      return CGFloat(truncating: number)
    }
    if let text = item as? String, let value = Double(text) {
      return CGFloat(value)
    }
    return nil
  }
  let normalized = values.filter { $0.isFinite }.map { max(0.0, min(1.0, $0)) }
  return normalized.isEmpty ? nil : normalized
}

private func chatProfileWaveformBitValue(
  data: UnsafeRawPointer,
  length: Int,
  bitOffset: Int,
  bitWidth: Int
) -> Int32 {
  guard length > 0, bitWidth > 0 else { return 0 }

  let byteOffset = bitOffset / 8
  guard byteOffset < length else { return 0 }

  let normalizedData = data.advanced(by: byteOffset)
  let normalizedBitOffset = bitOffset % 8
  let mask = UInt32((1 << bitWidth) - 1)

  var value: UInt32 = 0
  let bytesToCopy = min(MemoryLayout<UInt32>.size, length - byteOffset)
  memcpy(&value, normalizedData, bytesToCopy)

  return Int32((value >> UInt32(normalizedBitOffset)) & mask)
}

private func decodeChatProfileWaveformBitstream(_ data: Data, bitsPerSample: Int = 5) -> [CGFloat]? {
  guard !data.isEmpty, bitsPerSample > 0 else { return nil }

  let sampleCount = (data.count * 8) / bitsPerSample
  guard sampleCount > 0 else { return nil }

  let maxValue = CGFloat((1 << bitsPerSample) - 1)
  var result: [CGFloat] = []
  result.reserveCapacity(sampleCount)

  data.withUnsafeBytes { bytes in
    guard let baseAddress = bytes.baseAddress else { return }
    for index in 0..<sampleCount {
      let value = chatProfileWaveformBitValue(
        data: baseAddress,
        length: data.count,
        bitOffset: index * bitsPerSample,
        bitWidth: bitsPerSample
      )
      result.append(max(0.0, min(1.0, CGFloat(value) / maxValue)))
    }
  }

  return result.isEmpty ? nil : result
}

private func parseChatProfileWaveform(_ raw: Any?) -> [CGFloat]? {
  if let array = raw as? [Any], !array.isEmpty {
    return normalizeChatProfileWaveformArray(array)
  }

  guard let text = raw as? String else { return nil }
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

  if trimmed.hasPrefix("["),
    let data = trimmed.data(using: .utf8),
    let json = try? JSONSerialization.jsonObject(with: data),
    let array = json as? [Any]
  {
    return normalizeChatProfileWaveformArray(array)
  }

  if let data = Data(base64Encoded: trimmed) {
    return decodeChatProfileWaveformBitstream(data)
  }

  return nil
}

private struct ChatProfileLinkItem {
  let row: ChatProfileRow
  let url: String
}

private enum ChatProfileTab: String, CaseIterable {
  case media
  case voice
  case gifs
  case files
  case links
  case pinned

  var label: String {
    switch self {
    case .media:
      return "Media"
    case .voice:
      return "Voice"
    case .gifs:
      return "GIFs"
    case .files:
      return "Files"
    case .links:
      return "Links"
    case .pinned:
      return "Pinned"
    }
  }
}

private enum ChatProfileInfoRow {
  case members
  case identifier
  case agent
  case bio
}

private struct ChatProfileGroupedRowView: View {
  let title: String
  let subtitle: String
  let systemImage: String?
  let showsChevron: Bool
  let titleColor: UIColor
  let subtitleColor: UIColor
  let separatorColor: UIColor
  let isLast: Bool

  private var hasSubtitle: Bool {
    !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: hasSubtitle ? 3 : 0) {
        Text(title)
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(Color(uiColor: titleColor))
          .lineLimit(1)
          .minimumScaleFactor(0.78)

        if hasSubtitle {
          Text(subtitle)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Color(uiColor: subtitleColor))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Color(uiColor: subtitleColor))
      }

      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color(uiColor: subtitleColor).opacity(0.75))
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, hasSubtitle ? 11 : 13)
    .frame(maxWidth: .infinity, minHeight: hasSubtitle ? 62 : 48, alignment: .center)
    .overlay(alignment: .bottom) {
      if !isLast {
        Rectangle()
          .fill(Color(uiColor: separatorColor))
          .frame(height: 1.0 / UIScreen.main.scale)
          .padding(.leading, 18)
      }
    }
  }
}

private struct ChatProfileModernRowView: View {
  let title: String
  let subtitle: String
  let value: String
  let iconName: String
  let showsChevron: Bool
  let isDark: Bool
  let titleColor: UIColor
  let subtitleColor: UIColor
  let accentColor: UIColor
  let cardColor: UIColor
  let separatorColor: UIColor

  private var hasSubtitle: Bool {
    !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var hasValue: Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(Color(uiColor: accentColor).opacity(isDark ? 0.20 : 0.14))
        Image(systemName: iconName)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Color(uiColor: accentColor))
      }
      .frame(width: 38, height: 38)

      VStack(alignment: .leading, spacing: hasSubtitle ? 3 : 0) {
        Text(title)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Color(uiColor: titleColor))
          .lineLimit(1)
          .minimumScaleFactor(0.78)

        if hasSubtitle {
          Text(subtitle)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(Color(uiColor: subtitleColor))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if hasValue {
        Text(value)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color(uiColor: subtitleColor))
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(
            Capsule(style: .continuous)
              .fill(Color(uiColor: accentColor).opacity(isDark ? 0.18 : 0.12))
          )
      }

      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color(uiColor: subtitleColor).opacity(0.76))
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .padding(.horizontal, 14)
    .padding(.vertical, 4)
  }
}

private struct ChatProfileSwiftUITabSummary: Identifiable {
  let tab: ChatProfileTab
  let title: String
  let subtitle: String

  var id: String { tab.rawValue }
}

private struct ChatProfileSwiftUIContentItem: Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let systemImage: String
  let payload: [String: Any]
}

private enum ChatProfileSwiftUIDestination: Hashable {
  case history
  case bridgeHistory
  case bridgeSession(AgentBridgeHistorySession)
  case appearance
  case tab(ChatProfileTab)
  case members

  var transitionID: String {
    switch self {
    case .history:
      return "chat-history"
    case .bridgeHistory:
      return "bridge-history"
    case .bridgeSession(let session):
      return "bridge-session-\(session.id)"
    case .appearance:
      return "contact-photo-poster"
    case .tab(let tab):
      return "shared-\(tab.rawValue)"
    case .members:
      return "group-members"
    }
  }
}

private struct ChatProfileScrollOffsetPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}
private struct ChatProfileSwiftUITierBadge: View {
  let label: String

  var body: some View {
    Image(systemName: "checkmark.seal.fill")
      .font(.system(size: 16))
      .symbolRenderingMode(.palette)
      .foregroundStyle(Color.primary, Color(red: 1.0, green: 0.78, blue: 0.28))
  }
}

fileprivate class ChatProfileNavigationCoordinator: ObservableObject {
  @Published fileprivate var path: [ChatProfileSwiftUIDestination] = []
}

private struct ChatProfileSwiftUIRootView: View {
  let profileName: String
  let username: String
  let note: String
  let isChatMuted: Bool
  let isDark: Bool
  let historySubtitle: String
  let historyItems: [ChatProfileSwiftUIContentItem]
  let tabSummaries: [ChatProfileSwiftUITabSummary]
  let tabItems: [ChatProfileTab: [ChatProfileSwiftUIContentItem]]
  let appearanceSelection: ChatProfileAppearanceSelection
  let hasProfileImage: Bool
  let avatarUri: String?
  // The REAL top safe-area inset (status bar / Dynamic Island height), passed in
  // from the hosting UIView. The hosting controller runs with `safeAreaRegions =
  // []` so the hero backdrop can bleed full-screen under the notch — but that
  // also zeroes `geometry.safeAreaInsets.top`, which every piece of chrome (the
  // overlay header, the hero top offset, the sticky-title threshold) needs to
  // clear the status bar. Reading `geometry.safeAreaInsets.top` here returns 0
  // and collapses all that chrome up behind the notch (invisible header) while
  // the UIKit floating avatar — which uses the real inset — stays put, producing
  // the header-missing + content-shift bugs. Use THIS value for chrome instead.
  let safeAreaTop: CGFloat
  let isGroupOrChannel: Bool
  let isGroupOwner: Bool
  let memberCount: Int?
  let groupMembersSubtitle: String
  let groupMembers: [[String: Any]]
  let canManageGroupMembers: Bool
  let groupBridgeProvider: String?
  /// All bridge agents in the group ("claude"/"codex") — one model row each.
  var groupBridgeProviders: [String] = []
  let selectedRepositoryName: String?
  // Bridge (Claude/Codex paired-computer) state. `bridgeProvider` is empty for a
  // normal contact/group profile.
  var bridgeProvider: String = ""
  var bridgeChatId: String = ""
  var bridgeConnected: Bool = false
  var bridgePaired: Bool = false
  var bridgeDeviceLabel: String = ""
  var bridgeRunningTasks: [AgentBridgeRunningTask] = []
  let onScroll: (CGFloat) -> Void
  let onNavigationActiveChanged: (Bool) -> Void
  let onCopyUsername: () -> Void
  let onAction: (String) -> Void
  let onSaveAppearance: (ChatProfileAppearanceSelection) -> Void
  let onContentPressed: ([String: Any]) -> Void
  let onMembersAdded: ([[String: Any]]) -> Void

  @Namespace private var morphNamespace
  @StateObject private var navCoordinator = ChatProfileNavigationCoordinator()
  @State private var localScrollOffset: CGFloat = 0
  @State private var lastReportedScrollOffset: CGFloat = -1
  @State private var stickyTitleVisible = false
  @State private var newChatTrigger = false
  @State private var isShowingAddMembers = false
  /// Per-agent default view (chat vs agent runtime) for Claude/Codex. Seeded from the
  /// store when the section appears; the picker writes back through the store.
  @State private var bridgeDefaultView: AgentBridgeDefaultView = .chat
  /// Local echo of per-agent model picks so the row subtitle refreshes immediately
  /// ("" = explicitly cleared to Default). Source of truth stays the selection store.
  @State private var groupModelSelections: [String: String] = [:]

  private var rowFill: Color {
    Color(uiColor: posterGradientColors.0).opacity(isDark ? 0.055 : 0.11)
  }

  /// Effective model pick for an agent: the in-view echo wins ("" = cleared), else the
  /// stored selection.
  private func groupSelectedModel(_ provider: String) -> String? {
    if let local = groupModelSelections[provider] {
      return local.isEmpty ? nil : local
    }
    return AgentBridgeSelectionStore.selectedModel(provider: provider)
  }

  private func groupModelSubtitle(_ provider: String) -> String {
    guard let selected = groupSelectedModel(provider) else { return "Default model" }
    return AgentBridgeSelectionStore.modelChoices(provider: provider)
      .first(where: { $0.value == selected })?.title ?? selected
  }

  private var separatorColor: Color {
    Color(uiColor: isDark ? UIColor.white.withAlphaComponent(0.10) : UIColor.black.withAlphaComponent(0.08))
  }

  private var avatarGradientColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: appearanceSelection, mode: .avatar)
  }

  private var posterGradientColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: appearanceSelection, mode: .poster)
  }

  private var posterImage: UIImage? {
    guard let data = appearanceSelection.posterImageData else { return nil }
    return UIImage(data: data)
  }

  private var showsGoldTier: Bool {
    !bridgeProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var goldTierColor: Color {
    Color(red: 0.96, green: 0.72, blue: 0.22)
  }

  private var profileInitial: String {
    let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "U" : String(trimmed.prefix(1)).uppercased()
  }

  private var avatarDisplayText: String {
    let glyph = appearanceSelection.avatarGlyph?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return glyph.isEmpty ? profileInitial : glyph
  }

  /// "N members" under the group name in the header. Prefers the server member
  /// count, falling back to the loaded roster so it still shows before the count
  /// lands. Nil for a 1:1 DM (which shows no subtitle here).
  private var groupHeaderSubtitle: String? {
    guard isGroupOrChannel else { return nil }
    let count = (memberCount ?? 0) > 0 ? (memberCount ?? 0) : groupMembers.count
    guard count > 0 else { return nil }
    return count == 1 ? "1 member" : "\(count) members"
  }

  var body: some View {
    GeometryReader { geometry in
      NavigationStack(path: $navCoordinator.path) {
        ZStack {
          // Use the full geometry size to ensure it covers the safe areas properly
          let fullWidth = geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
          let fullHeight = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
          profileBackdrop(
            width: fullWidth,
            height: fullHeight,
            contentHeight: heroContentHeight(for: geometry)
          )

          ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
              offsetReader(
                safeTop: max(geometry.safeAreaInsets.top, safeAreaTop),
                heroHeight: heroContentHeight(for: geometry)
              )

              if navCoordinator.path.isEmpty {
                Color.clear
                  .frame(height: heroContentHeight(for: geometry))
              }

              Section {
                VStack(spacing: 18) {
                  profileInfoSection
                  if !bridgeProvider.isEmpty {
                    defaultViewSection
                  }
                  if bridgeProvider.isEmpty {
                    appearanceSection
                  }
                  // Shared media / attachments replace the old "Chat History" row —
                  // for both DMs and groups we surface photos/voice/files, not a
                  // scroll-back-through-messages entry.
                  sharedContentSection
                  // Contact-book actions only make sense for a 1:1 with a real person.
                  if !isGroupOrChannel {
                    contactActionsSection
                    emergencySection
                  }
                  dangerSection
                }
                .frame(width: max(0, geometry.size.width - 32))
                .padding(.horizontal, 16)
                .padding(.bottom, 66)
              } header: {
                VStack(spacing: 20) {
                  VStack(spacing: 3) {
                    HStack(spacing: 8) {
                      Text(profileName)
                        .font(.system(size: max(17, 34 - (max(0, localScrollOffset) / 8)), weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                      if showsGoldTier {
                        ChatProfileSwiftUITierBadge(label: "Gold")
                      }
                    }
                    .frame(maxWidth: .infinity)

                    if let groupHeaderSubtitle {
                      Text(groupHeaderSubtitle)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                  }

                  actionRow
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 18)
                .background {
                  // Transparent while the name sits over the hero; fades to a frosted
                  // bar once it collapses and sticks under the nav bar so the scrolling
                  // rows don't bleed through behind it.
                  Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(stickyTitleVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.18), value: stickyTitleVisible)
                    .ignoresSafeArea(edges: .top)
                }
              }
            }
          }
          .ignoresSafeArea(edges: .top)
          .coordinateSpace(name: "profile-scroll")
          .scrollIndicators(.never)
          .chatProfileBounceBehavior()
          .background(Color.clear)
        }
        .background(Color.clear)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        // Header is a top-anchored OVERLAY on the (safe-area-ignoring) ZStack,
        // NOT a second sibling view inside the NavigationStack root. Two bare
        // siblings in a NavigationStack builder don't reliably z-stack — the
        // header was getting mis-laid-out / swallowed, which is why it "didn't
        // show at all." An overlay is guaranteed to draw over its target and is
        // anchored to the screen top. The top inset comes LIVE from the
        // GeometryReader (`geometry.safeAreaInsets.top`) so SwiftUI lays the
        // header out in the same pass the push settles — no snapshot, no
        // re-render, no visible shift. `safeAreaTop` is only a fallback for the
        // (rare) case the host ever reports a 0 inset.
        .overlay(alignment: .top) {
          overlayHeader(safeTop: max(geometry.safeAreaInsets.top, safeAreaTop))
        }
      }
      .navigationDestination(for: ChatProfileSwiftUIDestination.self) { destination in
        if case .bridgeSession = destination {
          destinationView(for: destination)
        } else {
          destinationView(for: destination)
            .navigationTransition(.zoom(sourceID: destination.transitionID, in: morphNamespace))
        }
      }
      .background(Color.clear)
      .tint(.primary)
      .onChange(of: navCoordinator.path.isEmpty) { _, isEmpty in
        onNavigationActiveChanged(!isEmpty)
      }
      .sheet(isPresented: $isShowingAddMembers) {
        if let config = AppSessionConfig.current {
          AddGroupMembersSheet(
            config: config,
            chatId: bridgeChatId,
            excludedUserIds: Set(groupMembers.compactMap { $0["userId"] as? String }),
            onAdded: onMembersAdded
          )
        }
      }
    }
  }

  @ViewBuilder
  private func profileBackdrop(width: CGFloat, height: CGFloat, contentHeight: CGFloat) -> some View {
    ZStack {
      if let posterImage {
        let isSquare = posterImage.size.width > 0 && posterImage.size.height > 0 &&
                       (posterImage.size.width / posterImage.size.height) > 0.95 &&
                       (posterImage.size.width / posterImage.size.height) < 1.05

        if isSquare {
          // Reflection Background
          Image(uiImage: posterImage)
            .resizable()
            .scaledToFill()
            .frame(width: width, height: height)
            .clipped()
            .rotationEffect(.degrees(180))
            .blur(radius: 60)
            .opacity(0.8)

          // Original Image at top
          let img = Image(uiImage: posterImage).resizable().scaledToFit()
          img.frame(width: width, height: height, alignment: .top)

          // Blurred overlay
          img.frame(width: width, height: height, alignment: .top)
            .blur(radius: min(40, 15 + max(0, localScrollOffset / 5)))
            .mask(
              LinearGradient(
                stops: [
                  .init(color: .clear, location: max(0, 0.4 - max(0, localScrollOffset) / height)),
                  .init(color: .black, location: max(0.1, 0.6 - max(0, localScrollOffset) / height))
                ],
                startPoint: .top,
                endPoint: .bottom
              )
            )
        } else {
          // Standard Image
          let img = Image(uiImage: posterImage).resizable().scaledToFill()

          img.frame(width: width, height: height)
            .clipped()

          img.frame(width: width, height: height)
            .blur(radius: min(40, 15 + max(0, localScrollOffset / 5)))
            .mask(
              LinearGradient(
                stops: [
                  .init(color: .clear, location: max(0, 0.4 - max(0, localScrollOffset) / height)),
                  .init(color: .black, location: max(0.1, 0.6 - max(0, localScrollOffset) / height))
                ],
                startPoint: .top,
                endPoint: .bottom
              )
            )
        }
      } else {
        // No custom poster: render the profile photo as a circular avatar parked just
        // above the name, with a soft reflection bloom (or a gradient + glyph when
        // there's no photo at all).
        let scale = max(0.62, 1.0 - max(0, localScrollOffset / 460))
        let collapseBlur = min(14, max(0, localScrollOffset) / 22)
        ChatProfileHeroInlineView(
          text: avatarDisplayText,
          fontStyleID: appearanceSelection.avatarFontStyleID,
          gradientColors: avatarGradientColors,
          imageUri: hasProfileImage ? avatarUri : nil,
          width: width,
          height: height,
          contentHeight: contentHeight,
          avatarScale: scale,
          avatarBlur: collapseBlur
        )
        .frame(width: width, height: height)
      }
    }
    .frame(width: width, height: height)
    .scaleEffect(1.05 + max(0, -localScrollOffset / 500))
    .ignoresSafeArea()
  }

  private func offsetReader(safeTop: CGFloat, heroHeight: CGFloat) -> some View {
    GeometryReader { proxy in
      Color.clear
        .preference(
          key: ChatProfileScrollOffsetPreferenceKey.self,
          value: -proxy.frame(in: .named("profile-scroll")).minY
        )
    }
    .frame(height: 0)
    .onPreferenceChange(ChatProfileScrollOffsetPreferenceKey.self) { value in
      let nextValue = (value * 2.0).rounded() / 2.0
      DispatchQueue.main.async {
        guard abs(localScrollOffset - nextValue) >= 0.5 else { return }
        localScrollOffset = nextValue
        let shouldShowTitle = nextValue >= stickyTitleThreshold(safeTop: safeTop, heroHeight: heroHeight)
        if stickyTitleVisible != shouldShowTitle {
          stickyTitleVisible = shouldShowTitle
        }
        if lastReportedScrollOffset < 0 || abs(lastReportedScrollOffset - nextValue) >= 4.0 {
          lastReportedScrollOffset = nextValue
          onScroll(nextValue)
        }
      }
    }
  }

  // The floating nav header (back / sticky title / menu). Only shown at the
  // profile root — hidden once a destination is pushed onto the NavigationStack.
  @ViewBuilder
  private func overlayHeader(safeTop: CGFloat) -> some View {
    if navCoordinator.path.isEmpty {
      HStack {
        Button {
          onAction("headerBack")
        } label: {
          Image(systemName: "chevron.left")
            .font(.system(size: 18, weight: .semibold))
            .padding(12)
            .contentShape(Rectangle())
        }
        Spacer()
        Text(profileName)
          .font(.system(size: 17, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.78)
          .opacity(stickyTitleVisible ? 1 : 0)
          .animation(.easeInOut(duration: 0.16), value: stickyTitleVisible)
          .accessibilityHidden(!stickyTitleVisible)
        Spacer()
        Menu {
          Button(isChatMuted ? "Unmute" : "Mute") { onAction("muteToggle") }
          Button("Search") { onAction("search") }
          if isGroupOrChannel {
            if canManageGroupMembers {
              Button("Edit Group") { onAction("editGroup") }
            }
            if isGroupOwner {
              Button("Delete Group", role: .destructive) { onAction("deleteGroup") }
            } else {
              Button("Leave Group", role: .destructive) { onAction("leaveGroup") }
            }
          } else {
            Button("Share Contact") { onAction("shareContact") }
            Button("Block Contact", role: .destructive) { onAction("block") }
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 18, weight: .semibold))
            .padding(12)
            .contentShape(Rectangle())
        }
      }
      .padding(.horizontal, 4)
      // The overlay anchors at the very top of the screen (the ZStack ignores
      // the top safe area), so the header must clear the status bar / Dynamic
      // Island itself — sit it at the real (live) inset, standard nav-bar spot.
      .padding(.top, safeTop)
      .frame(maxWidth: .infinity)
      // Dynamically adapt color: white over the dark hero image, primary over the sticky material
      .foregroundStyle(stickyTitleVisible ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
      .animation(.easeInOut(duration: 0.16), value: stickyTitleVisible)
    }
  }

  private func heroContentHeight(for geometry: GeometryProxy) -> CGFloat {
    guard hasProfileImage else {
      // Read the inset LIVE from geometry (host no longer strips the safe area),
      // falling back to the snapshot only if it ever reports 0. Using the same
      // live value the header uses keeps the hero and the floating avatar aligned
      // in the same layout pass — this is what removes the chat→profile shift.
      let safeTop = max(geometry.safeAreaInsets.top, safeAreaTop)
      return NativeProfileAvatarHeroMetrics.expandedTop(for: safeTop)
        + NativeProfileAvatarHeroMetrics.expandedSize
        + 18
    }
    return max(280, geometry.size.height * 0.45)
  }

  private func stickyTitleThreshold(safeTop: CGFloat, heroHeight: CGFloat) -> CGFloat {
    max(120, heroHeight - safeTop - 40)
  }

  private var actionRow: some View {
    HStack(spacing: 24) {
      ChatProfileSwiftUIActionButton(
        title: isChatMuted ? "Unmute" : "Mute",
        systemImage: isChatMuted ? "bell" : "bell.slash",
        fill: rowFill
      ) {
        onAction("muteToggle")
      }

      ChatProfileSwiftUIActionButton(title: "Search", systemImage: "magnifyingglass", fill: rowFill) {
        onAction("search")
      }

      ChatProfileSwiftUIActionButton(title: "Call", systemImage: "phone", fill: rowFill) {
        onAction("audio")
      }

      ChatProfileSwiftUIActionButton(title: "Video", systemImage: "video", fill: rowFill) {
        onAction("video")
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var profileInfoSection: some View {
    if !bridgeProvider.isEmpty {
      // For a Claude/Codex agent there is no username to copy — the identity row
      // becomes the paired computer (label + live connection dot). Tapping it
      // opens the connect / disconnect / reconnect sheet.
      ChatProfileSwiftUISection(fill: rowFill) {
        Button {
          onAction("bridgeConnection")
        } label: {
          bridgeComputerRow(isLast: note.isEmpty)
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())

        if !note.isEmpty {
          ChatProfileSwiftUIRow(
            title: "note",
            subtitle: note,
            trailingSystemImage: nil,
            showsChevron: false,
            separatorColor: separatorColor,
            isLast: true
          )
        }
      }
    } else if isGroupOrChannel {
      ChatProfileSwiftUISection(fill: rowFill) {
        // Admins get a first-class edit entry (name / photo / description).
        if canManageGroupMembers {
          Button { onAction("editGroup") } label: {
            ChatProfileSwiftUIRow(
              title: "Edit group",
              subtitle: "Name, photo, description",
              trailingSystemImage: nil,
              showsChevron: true,
              separatorColor: separatorColor,
              isLast: false
            )
          }
          .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
        }

        NavigationLink(value: ChatProfileSwiftUIDestination.members) {
          ChatProfileSwiftUIRow(
            title: "Members",
            subtitle: groupMembersSubtitle,
            trailingSystemImage: nil,
            showsChevron: true,
            separatorColor: separatorColor,
            isLast: groupBridgeProvider == nil
          )
          .matchedTransitionSource(id: ChatProfileSwiftUIDestination.members.transitionID, in: morphNamespace)
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())

        if let provider = groupBridgeProvider {
          Button {
            onAction("bridgeRepository:\(provider)")
          } label: {
            ChatProfileSwiftUIRow(
              title: "Repository",
              subtitle: selectedRepositoryName ?? "Pick repo for Claude/Codex",
              trailingSystemImage: nil,
              showsChevron: true,
              separatorColor: separatorColor,
              isLast: false
            )
          }
          .buttonStyle(ChatProfileSwiftUIRowButtonStyle())

          // One model row per agent in the group. The pick is stored per provider
          // (AgentBridgeSelectionStore) and rides group sends as agentBridgeModels,
          // resolved to each worker at dispatch.
          ForEach(groupBridgeProviders, id: \.self) { agentProvider in
            Menu {
              ForEach(
                AgentBridgeSelectionStore.modelChoices(provider: agentProvider), id: \.value
              ) { choice in
                Button {
                  AgentBridgeSelectionStore.setModel(provider: agentProvider, model: choice.value)
                  groupModelSelections[agentProvider] = choice.value
                } label: {
                  if groupSelectedModel(agentProvider) == choice.value {
                    Label(choice.title, systemImage: "checkmark")
                  } else {
                    Text(choice.title)
                  }
                }
              }
              Button {
                AgentBridgeSelectionStore.setModel(provider: agentProvider, model: nil)
                groupModelSelections[agentProvider] = ""
              } label: {
                if groupSelectedModel(agentProvider) == nil {
                  Label("Default", systemImage: "checkmark")
                } else {
                  Text("Default")
                }
              }
            } label: {
              ChatProfileSwiftUIRow(
                title: "\(agentProvider.lowercased() == "claude" ? "Claude" : "Codex") model",
                subtitle: groupModelSubtitle(agentProvider),
                trailingSystemImage: nil,
                showsChevron: true,
                separatorColor: separatorColor,
                isLast: false
              )
            }
            .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
          }

          Button {
            onAction("agentConfig")
          } label: {
            ChatProfileSwiftUIRow(
              title: "Configuration",
              subtitle: "Agent and group settings",
              trailingSystemImage: nil,
              showsChevron: true,
              separatorColor: separatorColor,
              isLast: true
            )
          }
          .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
        }
      }
    } else if !username.isEmpty || !note.isEmpty {
      ChatProfileSwiftUISection(fill: rowFill) {
        if !username.isEmpty {
          ChatProfileSwiftUIRow(
            title: "username",
            subtitle: username,
            trailingSystemImage: "doc.on.doc",
            showsChevron: false,
            separatorColor: separatorColor,
            isLast: note.isEmpty
          )
          .onTapGesture {
            onCopyUsername()
          }
        }

        if !note.isEmpty {
          ChatProfileSwiftUIRow(
            title: "note",
            subtitle: note,
            trailingSystemImage: nil,
            showsChevron: false,
            separatorColor: separatorColor,
            isLast: true
          )
        }
      }
    }
  }

  // Identity row for a bridge agent: "Computer" + device label, with a live green
  // dot when the daemon is online. No copy affordance; chevron opens the sheet.
  private func bridgeComputerRow(isLast: Bool) -> some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("computer")
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(showsGoldTier ? goldTierColor : .primary)
          .lineLimit(1)
        HStack(spacing: 6) {
          if bridgeConnected && !bridgeRunningTasks.isEmpty {
            // A live task on the computer → a spinner so the profile reads as
            // "working right now", not just a static "connected" dot.
            ProgressView().controlSize(.mini)
          } else if bridgeConnected {
            Circle().fill(Color.green).frame(width: 8, height: 8)
          }
          Text(bridgeComputerSubtitle)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(bridgeConnected && !bridgeRunningTasks.isEmpty ? Color.green : Color.secondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 12)

      Image(systemName: "chevron.right")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.secondary.opacity(0.8))
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, minHeight: 62, alignment: .center)
    .contentShape(Rectangle())
    .overlay(alignment: .bottom) {
      if !isLast {
        Rectangle()
          .fill(separatorColor)
          .frame(height: 1 / UIScreen.main.scale)
          .padding(.leading, 18)
      }
    }
  }

  private var bridgeComputerSubtitle: String {
    if bridgeConnected && !bridgeRunningTasks.isEmpty {
      let count = bridgeRunningTasks.count
      let label = bridgeDeviceLabel.isEmpty ? "Connected" : bridgeDeviceLabel
      return "\(label) · \(count) running"
    }
    if bridgeConnected {
      return bridgeDeviceLabel.isEmpty ? "Connected" : "\(bridgeDeviceLabel) · Connected"
    }
    if bridgePaired {
      return "Paired · offline — tap to reconnect"
    }
    return "Not connected — tap to connect"
  }

  /// Claude/Codex only: pick whether opening this agent's DM lands in the classic chat
  /// (bubbles + wallpaper) or jumps straight to the full-page agent runtime view.
  private var defaultViewSection: some View {
    ChatProfileSwiftUISection(fill: rowFill) {
      Menu {
        Picker("Default view", selection: bridgeDefaultViewBinding) {
          ForEach(AgentBridgeDefaultView.allCases) { option in
            Text(option.title).tag(option)
          }
        }
      } label: {
        ChatProfileSwiftUIRow(
          title: "Default view",
          subtitle: bridgeDefaultView.subtitle,
          trailingSystemImage: "chevron.up.chevron.down",
          showsChevron: false,
          separatorColor: separatorColor,
          isLast: true
        )
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
    }
    .onAppear {
      bridgeDefaultView = AgentBridgeSelectionStore.defaultView(provider: bridgeProvider)
    }
  }

  private var bridgeDefaultViewBinding: Binding<AgentBridgeDefaultView> {
    Binding(
      get: { bridgeDefaultView },
      set: { newValue in
        bridgeDefaultView = newValue
        AgentBridgeSelectionStore.setDefaultView(provider: bridgeProvider, newValue)
      }
    )
  }

  private var historySection: some View {
    ChatProfileSwiftUISection(fill: rowFill) {
      NavigationLink(value: ChatProfileSwiftUIDestination.history) {
        ChatProfileSwiftUIRow(
          title: "Chat History",
          subtitle: historySubtitle,
          trailingSystemImage: nil,
          showsChevron: true,
          separatorColor: separatorColor,
          isLast: true
        )
        .matchedTransitionSource(id: ChatProfileSwiftUIDestination.history.transitionID, in: morphNamespace)
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
    }
  }

  private var bridgeDisplayName: String {
    switch bridgeProvider.lowercased() {
    case "claude": return "Claude"
    case "codex": return "Codex"
    default: return bridgeProvider.capitalized
    }
  }

  private var bridgeHistorySection: some View {
    ChatProfileSwiftUISection(fill: rowFill) {
      NavigationLink(value: ChatProfileSwiftUIDestination.bridgeHistory) {
        ChatProfileSwiftUIRow(
          title: "Chat History",
          subtitle: bridgeHistorySubtitle,
          trailingSystemImage: nil,
          showsChevron: true,
          separatorColor: separatorColor,
          isLast: true
        )
        .matchedTransitionSource(id: ChatProfileSwiftUIDestination.bridgeHistory.transitionID, in: morphNamespace)
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
    }
  }

  private var appearanceSection: some View {
    ChatProfileSwiftUISection(fill: rowFill) {
      NavigationLink(value: ChatProfileSwiftUIDestination.appearance) {
        ChatProfileSwiftUIRow(
          title: "Contact Photo & Poster",
          leading: AnyView(
            ChatProfileMiniAvatar(
              text: avatarDisplayText,
              fontStyleID: appearanceSelection.avatarFontStyleID,
              colors: avatarGradientColors,
              imageUri: hasProfileImage ? avatarUri : nil
            )
          ),
          trailingSystemImage: nil,
          showsChevron: true,
          separatorColor: separatorColor,
          isLast: true
        )
        .matchedTransitionSource(id: ChatProfileSwiftUIDestination.appearance.transitionID, in: morphNamespace)
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
    }
  }

  private var bridgeHistorySubtitle: String {
    if !bridgeRunningTasks.isEmpty {
      let count = bridgeRunningTasks.count
      return count == 1 ? "1 running \(bridgeDisplayName) chat" : "\(count) running \(bridgeDisplayName) chats"
    }
    return "\(bridgeDisplayName) conversations on your computer"
  }

  @ViewBuilder
  private var sharedContentSection: some View {
    if !tabSummaries.isEmpty {
      ChatProfileSwiftUISection(fill: rowFill) {
        ForEach(Array(tabSummaries.enumerated()), id: \.element.id) { index, summary in
          let destination = ChatProfileSwiftUIDestination.tab(summary.tab)
          NavigationLink(value: destination) {
            ChatProfileSwiftUIRow(
              title: summary.title,
              subtitle: summary.subtitle,
              trailingSystemImage: nil,
              showsChevron: true,
              separatorColor: separatorColor,
              isLast: index == tabSummaries.count - 1
            )
            .matchedTransitionSource(id: destination.transitionID, in: morphNamespace)
          }
          .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
        }
      }
    }
  }

  private var contactActionsSection: some View {
    ChatProfileSwiftUISection(fill: rowFill) {
      Button { onAction("shareContact") } label: {
        ChatProfileSwiftUIRow(title: "Share Contact", separatorColor: separatorColor, isLast: false)
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())

      Button { onAction("createNewContact") } label: {
        ChatProfileSwiftUIRow(title: "Create New Contact", separatorColor: separatorColor, isLast: false)
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())

      Button { onAction("addToExisting") } label: {
        ChatProfileSwiftUIRow(title: "Add to Existing Contact", separatorColor: separatorColor, isLast: true)
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
    }
  }

  private var emergencySection: some View {
    ChatProfileSwiftUISection(fill: rowFill) {
      Button { onAction("addToEmergency") } label: {
        ChatProfileSwiftUIRow(title: "Add to Emergency Contacts", separatorColor: separatorColor, isLast: true)
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
    }
  }

  @ViewBuilder
  private var dangerSection: some View {
    if isGroupOrChannel {
      // The owner can't just leave — they tear the whole group down. Everyone
      // else leaves.
      ChatProfileSwiftUISection(fill: rowFill) {
        if isGroupOwner {
          Button(role: .destructive) { onAction("deleteGroup") } label: {
            ChatProfileSwiftUIRow(
              title: "Delete Group",
              titleColor: .red,
              separatorColor: separatorColor,
              isLast: true
            )
          }
          .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
        } else {
          Button(role: .destructive) { onAction("leaveGroup") } label: {
            ChatProfileSwiftUIRow(
              title: "Leave Group",
              titleColor: .red,
              separatorColor: separatorColor,
              isLast: true
            )
          }
          .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
        }
      }
    } else {
      ChatProfileSwiftUISection(fill: rowFill) {
        Button { onAction("block") } label: {
          ChatProfileSwiftUIRow(
            title: "Block Contact",
            titleColor: .red,
            separatorColor: separatorColor,
            isLast: true
          )
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
      }
    }
  }

  @ViewBuilder
  private func destinationView(for destination: ChatProfileSwiftUIDestination) -> some View {
    switch destination {
    case .history:
      ChatProfileSwiftUIExpandedContentView(
        title: "Chat History",
        items: historyItems,
        fill: rowFill,
        separatorColor: separatorColor,
        onContentPressed: onContentPressed
      )
    case .bridgeHistory:
      AgentBridgeHistoryInlineView(
        provider: bridgeProvider,
        chatId: bridgeChatId,
        runningTasks: bridgeRunningTasks,
        deviceLabel: bridgeDeviceLabel,
        connected: bridgeConnected,
        paired: bridgePaired,
        onOpenSession: { session in
          navCoordinator.path.append(.bridgeSession(session))
        }
      )
      .background(Color(uiColor: UIColor.systemGroupedBackground))
    case .bridgeSession(let session):
      AgentBridgeRuntimeView(
        provider: bridgeProvider,
        chatId: bridgeChatId,
        session: session,
        subtitle: session.displayProjectName,
        newChatTrigger: $newChatTrigger
      )
      .ignoresSafeArea()
      .navigationTitle(session.topic)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Text(session.topic)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
        }
        ToolbarItem(placement: .topBarTrailing) {
          HStack(spacing: 14) {
            Button {
              newChatTrigger = true
            } label: {
              Image(systemName: "square.and.pencil")
            }

            Menu {
              Button("Pin", systemImage: "pin") {}
              Button("Files", systemImage: "folder") {}
            } label: {
              Image(systemName: "ellipsis")
            }
          }
          .padding(.trailing, 8)
        }
      }
    case .appearance:
      ChatProfileAppearanceEditorView(
        profileName: profileName,
        avatarUri: avatarUri,
        hasProfileImage: hasProfileImage,
        initialSelection: appearanceSelection,
        onSave: onSaveAppearance
      )
    case .tab(let tab):
      ChatProfileSwiftUIExpandedContentView(
        title: tabSummaries.first(where: { $0.tab == tab })?.title ?? tab.label,
        items: tabItems[tab] ?? [],
        fill: rowFill,
        separatorColor: separatorColor,
        onContentPressed: onContentPressed
      )
    case .members:
      ChatProfileSwiftUIExpandedContentView(
        title: "Members",
        items: swiftUIMemberItems(),
        fill: rowFill,
        separatorColor: separatorColor,
        onContentPressed: onContentPressed,
        trailingToolbarSystemImage: canManageGroupMembers ? "person.badge.plus" : nil,
        onTrailingToolbarPressed: canManageGroupMembers ? { isShowingAddMembers = true } : nil
      )
    }
  }

  private func swiftUIMemberItems() -> [ChatProfileSwiftUIContentItem] {
    groupMembers.compactMap { entry -> ChatProfileSwiftUIContentItem? in
      let userId =
        (entry["userId"] as? String)
        ?? (entry["id"] as? String)
        ?? (entry["memberId"] as? String)
      guard let userId, !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }
      let rawName =
        (entry["name"] as? String)
        ?? (entry["displayName"] as? String)
        ?? (entry["username"] as? String)
      let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let role = (entry["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "member"
      let isAdmin = role == "owner" || role == "admin"
      return ChatProfileSwiftUIContentItem(
        id: userId,
        title: (name?.isEmpty ?? true) ? userId : name!,
        subtitle: role == "owner" ? "Owner" : (role == "admin" ? "Admin" : "Member"),
        systemImage: isAdmin ? "star.circle.fill" : "person.circle",
        payload: [
          "type": "groupMemberTapped",
          "userId": userId,
          "role": role,
          "name": (name?.isEmpty ?? true) ? userId : name!,
          // Admin-only actions (promote/demote/remove) are gated in the host by
          // this flag plus the actor's own role vs. the target.
          "canManage": canManageGroupMembers,
        ]
      )
    }
  }
}

private struct ChatProfileAvatarGlyph: View {
  let text: String
  let fontStyleID: String?
  let size: CGFloat

  var body: some View {
    Text(text)
      .font(.system(size: max(16, size), weight: .bold, design: ChatProfileAvatarFontStyle.style(id: fontStyleID).design))
      .foregroundStyle(.white)
      .lineLimit(1)
      .minimumScaleFactor(0.28)
      .padding(.horizontal, size * 0.26)
  }
}

/// Full-width hero backdrop inline in the profile scroll content. No image:
/// gradient fill + bare glyph. With image: the profile's 1:1 photo is shown as a
/// circular avatar (never stretched/zoomed to fill the screen) with a soft, blurred
/// reflection of the same photo glowing behind it; the profile gradient still shows
/// through everywhere the glow fades out.
private struct ChatProfileHeroInlineView: View {
  let text: String
  let fontStyleID: String?
  let gradientColors: (UIColor, UIColor)
  let imageUri: String?
  let width: CGFloat
  let height: CGFloat
  /// Y (from the top of this backdrop) where the scrolling name/actions begin; the
  /// avatar is parked just above it instead of centered in the whole screen.
  var contentHeight: CGFloat = 0
  var avatarScale: CGFloat = 1.0
  /// Blur applied to the avatar as the header collapses on scroll.
  var avatarBlur: CGFloat = 0

  @State private var image: UIImage?
  @State private var loadedUri: String?

  init(
    text: String, fontStyleID: String?, gradientColors: (UIColor, UIColor),
    imageUri: String?, width: CGFloat, height: CGFloat,
    contentHeight: CGFloat = 0, avatarScale: CGFloat = 1.0, avatarBlur: CGFloat = 0
  ) {
    self.text = text
    self.fontStyleID = fontStyleID
    self.gradientColors = gradientColors
    self.imageUri = imageUri
    self.width = width
    self.height = height
    self.contentHeight = contentHeight
    self.avatarScale = avatarScale
    self.avatarBlur = avatarBlur
    let normalized = imageUri?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let primed = normalized.flatMap { ChatAvatarImageStore.cached(for: $0) }
    _image = State(initialValue: primed)
    _loadedUri = State(initialValue: primed != nil ? normalized : nil)
  }

  var body: some View {
    let avatarSize = min(width, height) * 0.42
    let anchorY = contentHeight > 0 ? contentHeight : height * 0.42
    let avatarCenterY = max(avatarSize * 0.5 + 44, anchorY - avatarSize * 0.5 - 40)

    return ZStack {
      // Background: black behind a real photo (so the reflection reads like the
      // Spotify-style ambient bloom); gradient only when there's no photo at all.
      if normalizedUri != nil {
        Color.black
      } else {
        LinearGradient(
          colors: [Color(uiColor: gradientColors.0), Color(uiColor: gradientColors.1)],
          startPoint: .top,
          endPoint: .bottom
        )
      }

      if loadedUri == normalizedUri, let image {
        avatarReflectionHero(image, avatarSize: avatarSize, avatarCenterY: avatarCenterY)
      } else if normalizedUri == nil {
        avatarFallbackHero(avatarSize: avatarSize, avatarCenterY: avatarCenterY)
      }
    }
    .frame(width: width, height: height)
    .allowsHitTesting(false)
    .task(id: normalizedUri ?? "") {
      await loadImage()
    }
  }

  @ViewBuilder
  private func avatarReflectionHero(_ image: UIImage, avatarSize: CGFloat, avatarCenterY: CGFloat) -> some View {
    let reflectionOpacity = max(0, 0.45 - max(0, avatarBlur) / 28)
    let screenHeight = UIScreen.main.bounds.height
    let bloomHeight = screenHeight * 0.45

    ZStack {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: width, height: bloomHeight)
        .blur(radius: 40)
        .opacity(reflectionOpacity)
        .mask(
          LinearGradient(
            stops: [
              .init(color: .black, location: 0.0),
              .init(color: .black.opacity(0.8), location: 0.6),
              .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .position(x: width * 0.5, y: bloomHeight * 0.5)

      Image(uiImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.38), radius: 26, y: 12)
        .scaleEffect(avatarScale, anchor: .center)
        .blur(radius: avatarBlur)
        .position(x: width * 0.5, y: avatarCenterY)
    }
    .frame(width: width, height: height)
  }

  @ViewBuilder
  private func avatarFallbackHero(avatarSize: CGFloat, avatarCenterY: CGFloat) -> some View {
    ZStack {
      Text(text)
        .font(.system(
          size: max(24, avatarSize * 0.4),
          weight: .bold,
          design: ChatProfileAvatarFontStyle.style(id: fontStyleID).design
        ))
        .foregroundStyle(.white.opacity(0.94))
        .minimumScaleFactor(0.4)
      
      Circle()
        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
    }
    .frame(width: avatarSize, height: avatarSize)
    .scaleEffect(avatarScale, anchor: .center)
    .blur(radius: avatarBlur)
    .position(x: width * 0.5, y: avatarCenterY)
  }

  private var normalizedUri: String? {
    let value = imageUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  @MainActor
  private func loadImage() async {
    let normalized = normalizedUri
    if loadedUri != normalized {
      loadedUri = normalized
      image = normalized.flatMap { ChatAvatarImageStore.cached(for: $0) }
    }
    guard let normalized else {
      image = nil
      return
    }
    if let cached = ChatAvatarImageStore.cached(for: normalized) {
      image = cached
      return
    }
    let loaded = await ChatAvatarImageStore.load(from: normalized)
    guard !Task.isCancelled, loadedUri == normalized else { return }
    image = loaded
  }
}

private struct ChatProfileMiniAvatar: View {
  let text: String
  let fontStyleID: String?
  let colors: (UIColor, UIColor)
  let imageUri: String?

  @State private var image: UIImage?
  @State private var loadedUri: String?

  init(text: String, fontStyleID: String?, colors: (UIColor, UIColor), imageUri: String?) {
    self.text = text
    self.fontStyleID = fontStyleID
    self.colors = colors
    self.imageUri = imageUri
    let normalized = imageUri?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let primed = normalized.flatMap { ChatAvatarImageStore.cached(for: $0) }
    _image = State(initialValue: primed)
    _loadedUri = State(initialValue: primed != nil ? normalized : nil)
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(uiColor: colors.0), Color(uiColor: colors.1)],
        startPoint: .top,
        endPoint: .bottom
      )

      if loadedUri == normalizedImageUri, let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        ChatProfileAvatarGlyph(text: text, fontStyleID: fontStyleID, size: 20)
      }
    }
    .frame(width: 52, height: 52)
    .clipShape(Circle())
    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
    .task(id: normalizedImageUri ?? "") {
      await loadImage()
    }
  }

  private var normalizedImageUri: String? {
    let value = imageUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  @MainActor
  private func loadImage() async {
    let normalized = normalizedImageUri
    if loadedUri != normalized {
      loadedUri = normalized
      image = normalized.flatMap { ChatAvatarImageStore.cached(for: $0) }
    }
    guard let normalized else {
      image = nil
      return
    }
    if let cached = ChatAvatarImageStore.cached(for: normalized) {
      image = cached
      return
    }
    let loaded = await ChatAvatarImageStore.load(from: normalized)
    guard !Task.isCancelled, loadedUri == normalized else { return }
    image = loaded
  }
}

private struct ChatProfileAppearanceEditorView: View {
  let profileName: String
  let avatarUri: String?
  let hasProfileImage: Bool
  let onSave: (ChatProfileAppearanceSelection) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var draft: ChatProfileAppearanceSelection
  @State private var mode: ChatProfileAppearanceMode = .avatar
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var avatarImage: UIImage?
  @State private var avatarImageUri: String?
  @State private var isCustomizerPresented = false
  @State private var pendingCropImage: UIImageWrapper?

  private struct UIImageWrapper: Identifiable {
    let id = UUID()
    let image: UIImage
  }

  init(
    profileName: String,
    avatarUri: String?,
    hasProfileImage: Bool,
    initialSelection: ChatProfileAppearanceSelection,
    onSave: @escaping (ChatProfileAppearanceSelection) -> Void
  ) {
    self.profileName = profileName
    self.avatarUri = avatarUri
    self.hasProfileImage = hasProfileImage
    self.onSave = onSave
    _draft = State(initialValue: initialSelection)
  }

  private var initial: String {
    let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "U" : String(trimmed.prefix(1)).uppercased()
  }

  private var avatarDisplayText: String {
    let glyph = draft.avatarGlyph?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return glyph.isEmpty ? initial : glyph
  }

  private var backgroundColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: draft, mode: .poster)
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(uiColor: backgroundColors.0), Color(uiColor: backgroundColors.1)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 30) {
          Picker("", selection: $mode) {
            ForEach(ChatProfileAppearanceMode.allCases) { option in
              Text(option.title).tag(option)
            }
          }
          .pickerStyle(.segmented)
          .frame(maxWidth: 270)
          .padding(.top, 16)

          ChatProfileAvatarPosterPreview(
            mode: mode,
            displayText: avatarDisplayText,
            selection: draft,
            avatarImage: hasProfileImage ? avatarImage : nil
          )
          .frame(maxWidth: .infinity)
          .padding(.top, 10)

          customizeButton

          if mode == .poster {
            posterPhotoSection
          } else {
            emojiSection
            memojiSection
            monogramSection
          }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 44)
      }
    }
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 18, weight: .semibold))
        }
      }

      ToolbarItem(placement: .topBarTrailing) {
        Button {
          onSave(draft)
          dismiss()
        } label: {
          Image(systemName: "checkmark")
            .font(.system(size: 20, weight: .semibold))
        }
      }
    }
    .toolbarBackground(.hidden, for: .navigationBar)
    .task(id: normalizedAvatarUri ?? "") {
      await loadAvatarImage()
    }
    .task(id: selectedPhotoItem) {
      await loadSelectedPosterPhoto()
    }
    .sheet(isPresented: $isCustomizerPresented) {
      ChatProfileAppearanceGradientSheet(
        mode: mode,
        displayText: avatarDisplayText,
        selection: $draft,
        onChoose: { selection in
          onSave(selection)
        }
      )
      .presentationDetents(mode == .poster ? Set([.large]) : Set([.medium, .large]))
      .presentationDragIndicator(.visible)
    }
    .fullScreenCover(item: $pendingCropImage) { wrapper in
      ChatProfileImageCropper(image: wrapper.image) { cropped in
        var nextDraft = draft
        if let cropped, let jpeg = cropped.jpegData(compressionQuality: 0.84) {
          nextDraft.posterImageData = jpeg
        }
        draft = nextDraft
        onSave(nextDraft)
        mode = .poster
        pendingCropImage = nil
      } onCancel: {
        pendingCropImage = nil
      }
    }
  }

  private var customizeButton: some View {
    Button {
      isCustomizerPresented = true
    } label: {
      Text("Customize")
        .font(.system(size: 20, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 30)
        .frame(height: 58)
        .background(
          Capsule(style: .continuous)
            .fill(Color.black.opacity(0.28))
        )
        .overlay(
          Capsule(style: .continuous)
            .stroke(Color.white.opacity(0.13), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
  }

  private var posterPhotoSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Photos")
        .font(.system(size: 24, weight: .bold))
        .foregroundStyle(.white)

      HStack(spacing: 18) {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
          ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .fill(Color.black.opacity(0.24))

            Image(systemName: "photo.on.rectangle.angled")
              .font(.system(size: 30, weight: .semibold))
              .foregroundStyle(.white)
          }
          .frame(width: 104, height: 118)
        }
        .buttonStyle(.plain)

        VStack(alignment: .leading, spacing: 6) {
          Text("Choose a Photo")
            .font(.system(size: 24, weight: .bold))
          Text("Poster")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(.white.opacity(0.74))
        }
        .foregroundStyle(.white)

        Spacer(minLength: 0)
      }

      if draft.posterImageData != nil {
        Button(role: .destructive) {
          var nextDraft = draft
          nextDraft.posterImageData = nil
          draft = nextDraft
          onSave(nextDraft)
        } label: {
          Label("Remove Photo", systemImage: "minus.circle")
        }
        .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var emojiSection: some View {
    ChatProfileHorizontalChoiceSection(title: "Emoji") {
      ForEach(["😀", "😎", "✨", "🔥", "💫", "🌙"], id: \.self) { emoji in
        Button {
          var nextDraft = draft
          nextDraft.avatarGlyph = emoji
          draft = nextDraft
          onSave(nextDraft)
        } label: {
          ChatProfileEmojiTile(text: emoji, colors: avatarTileColors)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var memojiSection: some View {
    ChatProfileHorizontalChoiceSection(title: "Memoji") {
      ForEach(["🙂", "🤖", "👾", "🧑‍💻"], id: \.self) { emoji in
        Button {
          var nextDraft = draft
          nextDraft.avatarGlyph = emoji
          draft = nextDraft
          onSave(nextDraft)
        } label: {
          ChatProfileEmojiTile(text: emoji, colors: avatarTileColors, roundedRectangle: true)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var monogramSection: some View {
    ChatProfileHorizontalChoiceSection(title: "Monogram") {
      ForEach(ChatProfileAvatarFontStyle.allCases) { style in
        Button {
          var nextDraft = draft
          nextDraft.avatarGlyph = nil
          nextDraft.avatarFontStyleID = style.rawValue
          draft = nextDraft
          onSave(nextDraft)
        } label: {
          ZStack {
            LinearGradient(
              colors: [Color(uiColor: avatarTileColors.0), Color(uiColor: avatarTileColors.1)],
              startPoint: .top,
              endPoint: .bottom
            )
            ChatProfileAvatarGlyph(text: initial, fontStyleID: style.rawValue, size: 44)
          }
          .frame(width: 96, height: 96)
          .clipShape(Circle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var avatarTileColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: draft, mode: .avatar)
  }

  private var normalizedAvatarUri: String? {
    let value = avatarUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  @MainActor
  private func loadAvatarImage() async {
    let normalized = normalizedAvatarUri
    if avatarImageUri != normalized {
      avatarImageUri = normalized
      avatarImage = normalized.flatMap { ChatAvatarImageStore.cached(for: $0) }
    }
    guard let normalized else {
      avatarImage = nil
      return
    }
    if let cached = ChatAvatarImageStore.cached(for: normalized) {
      avatarImage = cached
      return
    }
    let loaded = await ChatAvatarImageStore.load(from: normalized)
    guard !Task.isCancelled, avatarImageUri == normalized else { return }
    avatarImage = loaded
  }

  @MainActor
  private func loadSelectedPosterPhoto() async {
    guard let selectedPhotoItem else { return }
    guard let data = try? await selectedPhotoItem.loadTransferable(type: Data.self) else { return }
    if let image = UIImage(data: data) {
      pendingCropImage = UIImageWrapper(image: image)
    }
  }
}

private struct ChatProfileHorizontalChoiceSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title)
        .font(.system(size: 24, weight: .bold))
        .foregroundStyle(.white)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 18) {
          content
        }
        .padding(.vertical, 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ChatProfileEmojiTile: View {
  let text: String
  let colors: (UIColor, UIColor)
  var roundedRectangle: Bool = false

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(uiColor: colors.0), Color(uiColor: colors.1)],
        startPoint: .top,
        endPoint: .bottom
      )
      Text(text)
        .font(.system(size: 44))
    }
    .frame(width: 96, height: 96)
    .clipShape(
      RoundedRectangle(cornerRadius: roundedRectangle ? 24 : 48, style: .continuous)
    )
  }
}

private struct ChatProfileAppearanceGradientSheet: View {
  let mode: ChatProfileAppearanceMode
  let displayText: String
  @Binding var selection: ChatProfileAppearanceSelection
  let onChoose: (ChatProfileAppearanceSelection) -> Void

  @Environment(\.dismiss) private var dismiss

  private var backgroundColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: selection, mode: .poster)
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(uiColor: backgroundColors.0), Color(uiColor: backgroundColors.1)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 26) {
          HStack {
            Button("Cancel") {
              dismiss()
            }
            .font(.system(size: 20, weight: .medium))
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(Capsule(style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))

            Spacer()

            Button("Choose") {
              onChoose(selection)
              dismiss()
            }
            .font(.system(size: 20, weight: .medium))
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(Capsule(style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
          }
          .foregroundStyle(.white)
          .padding(.top, 12)

          ChatProfileAvatarPosterPreview(
            mode: mode,
            displayText: displayText,
            selection: selection,
            avatarImage: nil
          )
          .frame(maxWidth: .infinity)

          VStack(alignment: .leading, spacing: 20) {
            Text("Suggestions")
              .font(.system(size: 24, weight: .bold))
              .foregroundStyle(.white)

            ChatProfilePaletteGrid(mode: mode, selection: $selection)

            VStack(spacing: 12) {
              ColorPicker("Start", selection: customStartBinding, supportsOpacity: false)
              ColorPicker("End", selection: customEndBinding, supportsOpacity: false)
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
              RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.18))
            )
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 34)
      }
    }
  }

  private var customStartBinding: Binding<Color> {
    Binding {
      let colors = ChatProfileAppearancePalette.colors(for: selection, mode: mode)
      return Color(uiColor: colors.0)
    } set: { value in
      let hex = UIColor(value).chatProfileHexString
      if mode == .avatar {
        selection.avatarCustomStartHex = hex
      } else {
        selection.posterCustomStartHex = hex
        selection.posterImageData = nil
      }
    }
  }

  private var customEndBinding: Binding<Color> {
    Binding {
      let colors = ChatProfileAppearancePalette.colors(for: selection, mode: mode)
      return Color(uiColor: colors.1)
    } set: { value in
      let hex = UIColor(value).chatProfileHexString
      if mode == .avatar {
        selection.avatarCustomEndHex = hex
      } else {
        selection.posterCustomEndHex = hex
        selection.posterImageData = nil
      }
    }
  }
}

private struct ChatProfileAvatarPosterPreview: View {
  let mode: ChatProfileAppearanceMode
  let displayText: String
  let selection: ChatProfileAppearanceSelection
  let avatarImage: UIImage?

  private var avatarColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: selection, mode: .avatar)
  }

  private var posterColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: selection, mode: .poster)
  }

  private var posterImage: UIImage? {
    guard let data = selection.posterImageData else { return nil }
    return UIImage(data: data)
  }

  var body: some View {
    let isPoster = mode == .poster
    ZStack {
      previewBackground(isPoster: isPoster)

      if isPoster {
        avatarCircle(size: 92)
      } else {
        avatarCircle(size: 252)
      }
    }
    .frame(width: isPoster ? 188 : 252, height: isPoster ? 332 : 252)
    .clipShape(RoundedRectangle(cornerRadius: isPoster ? 42 : 126, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: isPoster ? 42 : 126, style: .continuous)
        .stroke(Color.white.opacity(0.16), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.20), radius: 12, x: 0, y: 6)
    .animation(.spring(response: 0.42, dampingFraction: 0.86), value: mode)
  }

  @ViewBuilder
  private func previewBackground(isPoster: Bool) -> some View {
    if isPoster, let posterImage {
      Image(uiImage: posterImage)
        .resizable()
        .scaledToFill()
    } else {
      LinearGradient(
        colors: [
          Color(uiColor: isPoster ? posterColors.0 : avatarColors.0),
          Color(uiColor: isPoster ? posterColors.1 : avatarColors.1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }

  private func avatarCircle(size: CGFloat) -> some View {
    ZStack {
      LinearGradient(
        colors: [Color(uiColor: avatarColors.0), Color(uiColor: avatarColors.1)],
        startPoint: .top,
        endPoint: .bottom
      )

      if let avatarImage {
        Image(uiImage: avatarImage)
          .resizable()
          .scaledToFill()
      } else {
        ChatProfileAvatarGlyph(
          text: displayText,
          fontStyleID: selection.avatarFontStyleID,
          size: size * 0.46
        )
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
    .shadow(color: Color.black.opacity(0.18), radius: size > 120 ? 10 : 4, x: 0, y: 4)
  }
}

private struct ChatProfilePaletteGrid: View {
  let mode: ChatProfileAppearanceMode
  @Binding var selection: ChatProfileAppearanceSelection

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 22), count: 5)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 24) {
      ForEach(ChatProfileAppearancePalette.all) { palette in
        Button {
          if mode == .avatar {
            selection.avatarPaletteID = palette.id
            selection.avatarCustomStartHex = nil
            selection.avatarCustomEndHex = nil
          } else {
            selection.posterPaletteID = palette.id
            selection.posterCustomStartHex = nil
            selection.posterCustomEndHex = nil
            selection.posterImageData = nil
          }
        } label: {
          Circle()
            .fill(
              LinearGradient(
                colors: [
                  Color(uiColor: ChatProfileAppearancePalette.uiColor(hex: palette.topHex)),
                  Color(uiColor: ChatProfileAppearancePalette.uiColor(hex: palette.bottomHex)),
                ],
                startPoint: .top,
                endPoint: .bottom
              )
            )
            .frame(width: 44, height: 44)
            .overlay {
              if isSelected(palette) {
                Circle()
                  .stroke(Color.white, lineWidth: 3)
                  .padding(-4)
              }
            }
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func isSelected(_ palette: ChatProfileAppearancePalette) -> Bool {
    switch mode {
    case .avatar:
      return selection.avatarPaletteID == palette.id
        && selection.avatarCustomStartHex == nil
        && selection.avatarCustomEndHex == nil
    case .poster:
      return selection.posterPaletteID == palette.id
        && selection.posterCustomStartHex == nil
        && selection.posterCustomEndHex == nil
    }
  }
}

private extension View {
  @ViewBuilder
  func chatProfileBounceBehavior() -> some View {
    if #available(iOS 16.4, *) {
      // `.always` (not `.basedOnSize`) so the header's overscroll stretch and the
      // sticky name/action-row collapse both work even when the profile body is
      // short enough to fit on one screen without scrolling.
      self.scrollBounceBehavior(.always)
    } else {
      self
    }
  }
}

private struct ChatProfileSwiftUIMaterialBackground: UIViewRepresentable {
  let style: UIBlurEffect.Style

  func makeUIView(context: Context) -> UIVisualEffectView {
    let view = UIVisualEffectView(effect: resolvedEffect)
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
    uiView.effect = resolvedEffect
  }

  private var resolvedEffect: UIVisualEffect {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: .regular)
      effect.isInteractive = false
      return effect
    }
    return UIBlurEffect(style: style)
  }
}

private struct ChatProfileSwiftUISection<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme

  let fill: Color
  @ViewBuilder let content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    VStack(spacing: 0) {
      content
    }
    .background {
      shape.fill(.ultraThinMaterial)
    }
    .clipShape(shape)
  }
}

private struct ChatProfileSwiftUIRow: View {
  let title: String
  var subtitle: String = ""
  var leading: AnyView? = nil
  var trailingSystemImage: String?
  var showsChevron: Bool = false
  var titleColor: Color = .primary
  let separatorColor: Color
  let isLast: Bool

  var body: some View {
    HStack(spacing: 14) {
      if let leading {
        leading
      }

      VStack(alignment: .leading, spacing: subtitle.isEmpty ? 0 : 4) {
        Text(title)
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(titleColor)
          .lineLimit(1)
          .minimumScaleFactor(0.76)

        if !subtitle.isEmpty {
          Text(subtitle)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 12)

      if let trailingSystemImage {
        Image(systemName: trailingSystemImage)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.secondary)
      }

      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color.secondary.opacity(0.8))
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, subtitle.isEmpty ? 13 : 11)
    .frame(maxWidth: .infinity, minHeight: subtitle.isEmpty ? 48 : 62, alignment: .center)
    .contentShape(Rectangle())
    .overlay(alignment: .bottom) {
      if !isLast {
        Rectangle()
          .fill(separatorColor)
          .frame(height: 1 / UIScreen.main.scale)
          .padding(.leading, 18)
      }
    }
  }
}

private struct ChatProfileSwiftUIRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? Color.primary.opacity(0.07) : Color.clear)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

private struct ChatProfileSwiftUIActionButton: View {
  @Environment(\.colorScheme) private var colorScheme

  let title: String
  let systemImage: String
  let fill: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 22, weight: .regular))
        .frame(width: 52, height: 52)
        .glassEffect(.regular.tint(fill).interactive(), in: .circle)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 10, x: 0, y: 5)
        .foregroundStyle(.primary)
    }
    .buttonStyle(.plain)
  }
}

private struct ChatProfileSwiftUIExpandedContentView: View {
  let title: String
  let items: [ChatProfileSwiftUIContentItem]
  let fill: Color
  let separatorColor: Color
  let onContentPressed: ([String: Any]) -> Void
  var trailingToolbarSystemImage: String? = nil
  var onTrailingToolbarPressed: (() -> Void)? = nil

  var body: some View {
    List {
      Section {
        if items.isEmpty {
          Text("No items yet")
            .foregroundStyle(.secondary)
        } else {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            Button {
              onContentPressed(item.payload)
            } label: {
              HStack(spacing: 14) {
                Image(systemName: item.systemImage)
                  .font(.system(size: 18, weight: .semibold))
                  .foregroundStyle(.secondary)
                  .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                  Text(item.title)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                  if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                      .font(.system(size: 13, weight: .regular))
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
              }
              .padding(.vertical, 5)
              .overlay(alignment: .bottom) {
                if index != items.count - 1 {
                  Rectangle()
                    .fill(separatorColor)
                    .frame(height: 1 / UIScreen.main.scale)
                    .padding(.leading, 42)
                }
              }
            }
            .buttonStyle(.plain)
            .listRowBackground(fill)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color(uiColor: UIColor.systemGroupedBackground))
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if let trailingToolbarSystemImage, let onTrailingToolbarPressed {
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: onTrailingToolbarPressed) {
            Image(systemName: trailingToolbarSystemImage)
          }
        }
      }
    }
  }
}

private final class ChatProfileListRowCell: UITableViewCell {
  static let reuseIdentifier = "ChatProfileListRowCell"

  let rowNode = ChatMainProfileListRowNode()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    contentView.backgroundColor = .clear
    rowNode.isUserInteractionEnabled = false
    contentView.addSubview(rowNode)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    rowNode.frame = contentView.bounds
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    contentConfiguration = nil
    rowNode.isHidden = false
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    rowNode.isHighlighted = highlighted
  }

  override func setSelected(_ selected: Bool, animated: Bool) {
    super.setSelected(selected, animated: animated)
    rowNode.isHighlighted = selected
  }
}

private final class ChatProfileTabStripView: UIView {
  static let preferredHeight: CGFloat = 34.0

  var onSelect: ((ChatProfileTab) -> Void)?

  private let chromeView = UIVisualEffectView(effect: nil)
  private let chromeOverlayView = UIView()
  private let scrollView = UIScrollView()
  private let stackView = UIStackView()
  private let selectionView = UIView()
  private var currentTabs: [ChatProfileTab] = []
  private var activeTab: ChatProfileTab = .media
  private var buttonsByTab: [ChatProfileTab: UIButton] = [:]
  private var isDark = false
  private let selectionFeedback = UISelectionFeedbackGenerator()

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
    clipsToBounds = false

    // Glass effect as a pure background — no content inside contentView so
    // UIGlassEffect renders correctly without being blocked by nested views.
    chromeView.translatesAutoresizingMaskIntoConstraints = false
    chromeView.clipsToBounds = true
    chromeView.layer.cornerCurve = .continuous
    chromeView.isUserInteractionEnabled = false
    addSubview(chromeView)

    // Overlay and scroll view are siblings of chromeView, not children of contentView.
    chromeOverlayView.translatesAutoresizingMaskIntoConstraints = false
    chromeOverlayView.isUserInteractionEnabled = false
    addSubview(chromeOverlayView)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = .clear
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceHorizontal = false
    scrollView.delaysContentTouches = false
    scrollView.canCancelContentTouches = true
    addSubview(scrollView)

    selectionView.isUserInteractionEnabled = false
    selectionView.layer.cornerCurve = .continuous
    scrollView.addSubview(selectionView)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.alignment = .fill
    stackView.distribution = .fill
    stackView.spacing = 6.0
    scrollView.addSubview(stackView)

    NSLayoutConstraint.activate([
      chromeView.leadingAnchor.constraint(equalTo: leadingAnchor),
      chromeView.trailingAnchor.constraint(equalTo: trailingAnchor),
      chromeView.topAnchor.constraint(equalTo: topAnchor),
      chromeView.bottomAnchor.constraint(equalTo: bottomAnchor),

      chromeOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
      chromeOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
      chromeOverlayView.topAnchor.constraint(equalTo: topAnchor),
      chromeOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])

    selectionFeedback.prepare()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    chromeView.layer.cornerRadius = bounds.height * 0.5
    updateSelectionFrame(animated: false)
  }

  func applyTheme(isDark: Bool) {
    self.isDark = isDark
    applyChrome()
  }

  private func applyChrome() {
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = false
      chromeView.effect = glass
    } else {
      let blurStyle: UIBlurEffect.Style =
        isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight
      chromeView.effect = UIBlurEffect(style: blurStyle)
    }

    let primary = isDark ? UIColor(white: 0.95, alpha: 0.96) : UIColor(white: 0.12, alpha: 0.96)
    let secondary = isDark ? UIColor(white: 0.84, alpha: 0.62) : UIColor(white: 0.12, alpha: 0.42)
    if #available(iOS 26.0, *) {
      chromeOverlayView.backgroundColor = .clear
    } else {
      chromeOverlayView.backgroundColor =
        (isDark ? UIColor.black : UIColor.white).withAlphaComponent(isDark ? 0.10 : 0.08)
    }
    selectionView.backgroundColor =
      isDark ? UIColor.white.withAlphaComponent(0.18) : UIColor.black.withAlphaComponent(0.10)

    for (tab, button) in buttonsByTab {
      let selected = tab == activeTab
      button.setTitleColor(selected ? primary : secondary, for: .normal)
      button.alpha = selected ? 1.0 : 0.94
    }
  }

  func configure(
    tabs: [ChatProfileTab],
    activeTab: ChatProfileTab,
    titleProvider: (ChatProfileTab) -> String
  ) {
    let tabsChanged = currentTabs != tabs
    let previousTab = self.activeTab
    self.activeTab = activeTab

    if tabsChanged {
      currentTabs = tabs
      rebuildItems(titleProvider: titleProvider)
    } else {
      updateTitles(titleProvider: titleProvider)
    }

    applyChrome()
    updateSelectionFrame(animated: previousTab != activeTab && !tabsChanged)
    scrollSelectedTabIntoView(animated: previousTab != activeTab)
  }

  private func rebuildItems(titleProvider: (ChatProfileTab) -> String) {
    for arrangedSubview in stackView.arrangedSubviews {
      stackView.removeArrangedSubview(arrangedSubview)
      arrangedSubview.removeFromSuperview()
    }

    buttonsByTab.removeAll()
    selectionView.alpha = 0.0

    for (index, tab) in currentTabs.enumerated() {
      let button = UIButton(type: .system)
      button.translatesAutoresizingMaskIntoConstraints = false
      button.tag = index
      button.contentEdgeInsets = UIEdgeInsets(top: 0.0, left: 10.0, bottom: 0.0, right: 10.0)
      button.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
      button.titleLabel?.lineBreakMode = .byTruncatingTail
      button.setTitle(titleProvider(tab), for: .normal)
      button.addTarget(self, action: #selector(handleTabButtonPressed(_:)), for: .touchUpInside)
      stackView.addArrangedSubview(button)
      buttonsByTab[tab] = button
    }

    setNeedsLayout()
  }

  private func updateTitles(titleProvider: (ChatProfileTab) -> String) {
    for tab in currentTabs {
      buttonsByTab[tab]?.setTitle(titleProvider(tab), for: .normal)
    }
  }

  private func updateSelectionFrame(animated: Bool) {
    guard let button = buttonsByTab[activeTab] else {
      selectionView.alpha = 0.0
      return
    }

    let targetFrame = button.convert(button.bounds, to: scrollView)
    let applySelection = {
      self.selectionView.frame = targetFrame
      self.selectionView.layer.cornerRadius = targetFrame.height * 0.5
      self.selectionView.alpha = 1.0
    }

    guard animated, window != nil else {
      applySelection()
      return
    }

    UIView.animate(
      withDuration: 0.26,
      delay: 0.0,
      options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
    ) {
      applySelection()
    }
  }

  private func scrollSelectedTabIntoView(animated: Bool) {
    guard let button = buttonsByTab[activeTab] else { return }
    let targetFrame = button.convert(button.bounds, to: scrollView).insetBy(dx: -18.0, dy: 0.0)
    scrollView.scrollRectToVisible(targetFrame, animated: animated)
  }

  @objc private func handleTabButtonPressed(_ sender: UIButton) {
    guard currentTabs.indices.contains(sender.tag) else { return }
    let tab = currentTabs[sender.tag]
    guard tab != activeTab else { return }

    selectionFeedback.selectionChanged()
    onSelect?(tab)
  }
}


private final class ChatProfileTabStripCell: UITableViewCell {
  static let reuseIdentifier = "ChatProfileTabStripCell"

  let tabsView = ChatProfileTabStripView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    contentView.addSubview(tabsView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    tabsView.frame = contentView.bounds.insetBy(dx: 12.0, dy: 6.0)
  }
}

private final class ChatProfileMediaContentCell: UITableViewCell {
  static let reuseIdentifier = "ChatProfileMediaContentCell"

  private let thumbnailNode = ChatMainProfileMediaCellNode()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    titleLabel.numberOfLines = 1
    subtitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    subtitleLabel.numberOfLines = 1

    contentView.addSubview(thumbnailNode)
    contentView.addSubview(titleLabel)
    contentView.addSubview(subtitleLabel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let bounds = contentView.bounds.insetBy(dx: 16.0, dy: 8.0)
    thumbnailNode.frame = CGRect(x: bounds.minX, y: bounds.minY, width: 56.0, height: 56.0)
    titleLabel.frame = CGRect(
      x: thumbnailNode.frame.maxX + 12.0,
      y: bounds.minY + 8.0,
      width: max(0.0, bounds.width - 68.0),
      height: 20.0
    )
    subtitleLabel.frame = CGRect(
      x: thumbnailNode.frame.maxX + 12.0,
      y: titleLabel.frame.maxY + 4.0,
      width: max(0.0, bounds.width - 68.0),
      height: 18.0
    )
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    thumbnailNode.isHighlighted = highlighted
    UIView.animate(withDuration: highlighted ? 0.08 : 0.16) {
      self.titleLabel.alpha = highlighted ? 0.74 : 1.0
      self.subtitleLabel.alpha = highlighted ? 0.74 : 1.0
    }
  }

  func configure(
    title: String,
    subtitle: String,
    urlString: String?,
    isVideo: Bool,
    titleColor: UIColor,
    subtitleColor: UIColor,
    placeholderTintColor: UIColor,
    placeholderBackgroundColor: UIColor
  ) {
    titleLabel.text = title
    titleLabel.textColor = titleColor
    subtitleLabel.text = subtitle
    subtitleLabel.textColor = subtitleColor
    thumbnailNode.configure(urlString: urlString, isVideo: isVideo)
    thumbnailNode.applyTheme(
      placeholderTintColor: placeholderTintColor,
      placeholderBackgroundColor: placeholderBackgroundColor
    )
  }
}

private final class ChatProfileVoiceContentCell: UITableViewCell, VoicePlayableCell {
  static let reuseIdentifier = "ChatProfileVoiceContentCell"

  private let chromeView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
  private let chromeOverlayView = UIView()
  let voiceButtonView = VoicePlayProgressView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let dateLabel = UILabel()
  private var messageId: String?
  private var mediaUrl: String?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    chromeView.clipsToBounds = true
    chromeView.layer.cornerCurve = .continuous
    chromeView.isUserInteractionEnabled = false
    contentView.addSubview(chromeView)
    chromeOverlayView.isUserInteractionEnabled = false
    chromeView.contentView.addSubview(chromeOverlayView)

    voiceButtonView.isUserInteractionEnabled = false
    contentView.addSubview(voiceButtonView)

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    contentView.addSubview(titleLabel)

    subtitleLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    contentView.addSubview(subtitleLabel)

    dateLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    dateLabel.textAlignment = .right
    contentView.addSubview(dateLabel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let bounds = contentView.bounds.insetBy(dx: 16.0, dy: 8.0)
    chromeView.frame = contentView.bounds.insetBy(dx: 14.0, dy: 4.0)
    chromeView.layer.cornerRadius = 22.0
    chromeOverlayView.frame = chromeView.bounds

    let buttonSize: CGFloat = 44.0
    voiceButtonView.frame = CGRect(
      x: bounds.minX,
      y: bounds.minY + floor((bounds.height - buttonSize) * 0.5),
      width: buttonSize,
      height: buttonSize
    )

    let textX = voiceButtonView.frame.maxX + 12.0

    let dateWidth: CGFloat = 70.0
    dateLabel.frame = CGRect(
      x: bounds.maxX - dateWidth,
      y: bounds.minY + 6.0,
      width: dateWidth,
      height: 20.0
    )

    let textWidth = max(20.0, dateLabel.frame.minX - textX - 8.0)
    titleLabel.frame = CGRect(
      x: textX,
      y: bounds.minY + 6.0,
      width: textWidth,
      height: 20.0
    )

    subtitleLabel.frame = CGRect(
      x: textX,
      y: titleLabel.frame.maxY + 2.0,
      width: textWidth,
      height: 18.0
    )
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    UIView.animate(withDuration: highlighted ? 0.08 : 0.16) {
      self.contentView.alpha = highlighted ? 0.74 : 1.0
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    VoiceBubblePlaybackCoordinator.shared.unbind(cell: self)
    voiceButtonView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
    voiceButtonView.setPlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
  }

  func configure(
    title: String,
    subtitle: String,
    row: ChatProfileRow,
    titleColor: UIColor,
    subtitleColor: UIColor,
    accentColor: UIColor
  ) {
    messageId = row.messageId
    mediaUrl = row.mediaUrl

    titleLabel.text = title
    titleLabel.textColor = titleColor

    subtitleLabel.text = subtitle
    subtitleLabel.textColor = subtitleColor

    let dateMs = row.timestampMs ?? 0
    if dateMs > 0 {
      let date = Date(timeIntervalSince1970: TimeInterval(dateMs) / 1000.0)
      let formatter = DateFormatter()
      formatter.dateStyle = .none
      formatter.timeStyle = .short
      dateLabel.text = formatter.string(from: date)
    } else {
      dateLabel.text = ""
    }
    dateLabel.textColor = subtitleColor.withAlphaComponent(0.6)

    voiceButtonView.applyStyle(fillColor: accentColor, iconTint: .white, ringTint: accentColor)
    chromeView.effect = UIBlurEffect(style: titleColor == UIColor.white ? .systemThinMaterialDark : .systemMaterialLight)
    chromeOverlayView.backgroundColor =
      (titleColor == UIColor.white ? UIColor.white : UIColor.black).withAlphaComponent(titleColor == UIColor.white ? 0.06 : 0.035)
  }

  func applyVoicePlaybackState(isPlaying: Bool, progress: CGFloat, level: CGFloat) {
    voiceButtonView.setPlaybackState(isPlaying: isPlaying, progress: progress, level: level)
  }

  func applyVoiceDownloadState(needsDownload: Bool, isDownloading: Bool, progress: CGFloat?) {
    voiceButtonView.setDownloadState(
      needsDownload: needsDownload,
      isDownloading: isDownloading,
      progress: progress
    )
  }
}

final class ChatProfileMainView: UIView, UITableViewDataSource, UITableViewDelegate {
  public var onViewportChanged = NativeEventDispatcher()
  public var onNativeEvent = NativeEventDispatcher()

  @objc public var surfaceId: String = ""

  private let backgroundGradientLayer = CAGradientLayer()
  private let posterImageLayer = CALayer()
  private let avatarGlassRing = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))

  private let headerMaskContainer = UIView()
  private let headerMaskView = UIView()
  private let headerMaskBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let headerMaskOverlayView = UIView()
  private let headerMaskGradientLayer = CAGradientLayer()
  private let headerContainer = UIView()
  private let headerContentView = UIView()
  private let backButton = UIButton(type: .system)
  private let menuButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let swiftUIContainerView = UIView()
  private var swiftUIHostingController: UIHostingController<AnyView>?
  // Top safe-area inset handed to the SwiftUI root at the last render. Tracked so
  // safeAreaInsetsDidChange can re-render only when the real inset actually
  // arrives (first render often runs pre-window with a 0 inset).
  private var lastRenderedSafeAreaTop: CGFloat = -1.0
  private let floatingAvatarView: NativeProfileAvatarView

  private let heroHeaderView = UIView()
  private let heroBannerView = UIView()
  private let heroNameLabel = UILabel()
  private let heroHandleButton = UIButton(type: .system)
  private let heroBioLabel = UILabel()

  private let actionsStack = UIStackView()
  private let muteActionButton = ChatMainProfileActionNode()
  private let searchActionButton = ChatMainProfileActionNode()
  private let audioActionButton = ChatMainProfileActionNode()
  private let videoActionButton = ChatMainProfileActionNode()

  private var rows: [ChatProfileRow] = []
  private var mediaRows: [ChatProfileRow] = []
  private var voiceRows: [ChatProfileRow] = []
  private var gifRows: [ChatProfileRow] = []
  private var fileRows: [ChatProfileRow] = []
  private var pinnedRows: [ChatProfileRow] = []
  private var linkRows: [ChatProfileLinkItem] = []
  private var availableTabs: [ChatProfileTab] = []
  private var activeTab: ChatProfileTab = .media
  private var profileName = "User"
  private var profileHandle = ""
  private var profileBio = ""
  private var headerTitle = "Profile"
  private var headerSubtitle = ""
  private var avatarUri: String?
  private var avatarResolveGeneration: UInt = 0
  private var isChatMuted = false
  private var isGroupOrChannel = false
  private var isOnline = false
  private var groupMemberCount: Int?
  private var groupMembers: [[String: Any]] = []

  private var engineChatId = ""
  private var engineMyUserId = ""
  private var enginePeerUserId = ""
  private var agentConfig: [String: Any]?
  // Non-empty ("claude"/"codex") when this profile is a paired-computer bridge
  // agent. Drives the "Computer" connection card + the agent-history browser.
  private var bridgeProvider = ""
  private var bridgeConnected = false
  private var bridgePaired = false
  private var bridgeDeviceLabel = ""
  private var bridgeRunningTasks: [AgentBridgeRunningTask] = []
  private var bridgeStatusTask: Task<Void, Never>?
  private var bridgeStatusRefreshWorkItem: DispatchWorkItem?
  private var avatarMorphProgress: CGFloat = 0.0
  private var currentHeroTop: CGFloat = 0.0
  private var currentCollapsedTop: CGFloat = 0.0
  private var currentTextColor: UIColor = .label
  private var currentSecondaryTextColor: UIColor = .secondaryLabel
  private var currentRowSeparatorColor: UIColor = UIColor(white: 0.0, alpha: 0.08)
  private var currentRowHighlightColor: UIColor = UIColor(white: 0.0, alpha: 0.04)
  private var currentRowCardColor: UIColor = UIColor.white
  private var currentRowAccentColor: UIColor = UIColor(
    red: 0.17, green: 0.65, blue: 0.71, alpha: 1.0)
  private var currentRowIconBackgroundColor: UIColor = UIColor(
    red: 0.17,
    green: 0.65,
    blue: 0.71,
    alpha: 0.12
  )
  private var swiftUIScrollOffset: CGFloat = 0.0
  private var swiftUINavigationActive = false
  private var swiftUIRenderBatchDepth = 0
  private var needsBatchedSwiftUIRender = false
  private static let listDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  override init(frame: CGRect) {
    floatingAvatarView = NativeProfileAvatarView()
    super.init(frame: frame)
    configureView()
    applyTheme()
    rebuildDerivedContent()
    reloadHeaderText()
    refreshHeroContent()
    rebuildMenu()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else {
      return
    }
    applyTheme()
    tableView.reloadData()
    layoutHeroHeaderViewIfNeeded(force: true)
    renderSwiftUIProfile()
  }

  deinit {
    bridgeStatusTask?.cancel()
    bridgeStatusRefreshWorkItem?.cancel()
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    updateAvatarMetrics()
    setNeedsLayout()
    // The SwiftUI root is handed the real top inset (safeAreaTop) explicitly —
    // if the first render happened before the view had a window (inset == 0),
    // the header/hero were positioned for a 0 inset. Re-render now that the real
    // inset has landed so the header drops below the notch and the hero lines up
    // with the UIKit floating avatar.
    if lastRenderedSafeAreaTop != resolvedSafeAreaTop() {
      renderSwiftUIProfile()
    }
  }

  /// The real top safe-area inset to hand the SwiftUI root. Prefers this view's
  /// own inset; falls back to the key window's while the view isn't yet in a
  /// window (its own inset is still 0 then). Chrome positioning depends on this
  /// being the true status-bar/Dynamic-Island height, not the host-stripped 0.
  private func resolvedSafeAreaTop() -> CGFloat {
    if safeAreaInsets.top > 0 { return safeAreaInsets.top }
    return Self.keyWindowSafeAreaTop()
  }

  private static func keyWindowSafeAreaTop() -> CGFloat {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .safeAreaInsets.top ?? 0.0
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    attachSwiftUIHostIfNeeded()
    if window == nil {
      bridgeStatusTask?.cancel()
      bridgeStatusRefreshWorkItem?.cancel()
      bridgeStatusRefreshWorkItem = nil
    } else {
      refreshBridgeStatus()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let safeTop = safeAreaInsets.top
    let headerHeight = safeTop + 62.0
    let headerChromeHeight = headerHeight + 108.0
    updateAvatarMetrics()

    headerMaskContainer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: headerChromeHeight)
    headerMaskView.frame = headerMaskContainer.bounds
    headerMaskBlurView.frame = headerMaskView.bounds
    headerMaskOverlayView.frame = headerMaskBlurView.bounds
    headerMaskGradientLayer.frame = headerMaskView.bounds
    headerContainer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: headerHeight)
    headerContentView.frame = CGRect(
      x: 12.0,
      y: safeTop + 8.0,
      width: max(0.0, bounds.width - 24.0),
      height: 44.0
    )
    backButton.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    menuButton.frame = CGRect(
      x: max(0.0, headerContentView.bounds.width - 44.0), y: 0.0, width: 44.0, height: 44.0)
    let textX = backButton.frame.maxX + 12.0
    let textWidth = menuButton.frame.minX - textX - 12.0
    let textAvailable = textWidth > 40.0
    titleLabel.frame =
      textAvailable ? CGRect(x: textX, y: 2.0, width: textWidth, height: 20.0) : .zero
    subtitleLabel.frame =
      textAvailable ? CGRect(x: textX, y: 22.0, width: textWidth, height: 16.0) : .zero
    titleLabel.textAlignment = .center
    subtitleLabel.textAlignment = .center
    titleLabel.isHidden = true
    subtitleLabel.isHidden = true
    titleLabel.alpha = 0.0
    subtitleLabel.alpha = 0.0

    tableView.frame = bounds
    tableView.scrollIndicatorInsets = UIEdgeInsets(
      top: headerHeight, left: 0.0, bottom: 0.0, right: 0.0)
    swiftUIContainerView.frame = bounds
    swiftUIHostingController?.view.frame = swiftUIContainerView.bounds

    layoutHeroHeaderViewIfNeeded(force: true)
    layoutActionsForCurrentScroll()

    // Size the background gradient to fill the view
    backgroundGradientLayer.frame = bounds
    posterImageLayer.frame = bounds

    layoutFloatingAvatarView()
    updateAvatarMorphProgress()
    layoutAvatarGlassRing()
    swiftUIContainerView.isHidden = false
    floatingAvatarView.isHidden = true
    avatarGlassRing.isHidden = true
    avatarGlassRing.alpha = 0.0
    headerContainer.isHidden = true
    headerMaskContainer.isHidden = true
    bringSubviewToFront(swiftUIContainerView)
    if let hostView = swiftUIHostingController?.view {
      swiftUIContainerView.bringSubviewToFront(hostView)
    }

    onViewportChanged([
      "width": bounds.width,
      "height": bounds.height,
      "surfaceId": surfaceId,
    ])
  }

  func setProfileOnly(_ value: Bool) {
    _ = value
  }

  func setRows(_ rows: [[String: Any]]) {
    self.rows = rows.compactMap(ChatProfileRow.parse)
    rebuildDerivedContent()
    reloadDataKeepingSelection()
  }

  func setEngineSurfaceId(_ value: String) {
    _ = value
  }

  func performBatchedProfileUpdate(_ updates: () -> Void) {
    swiftUIRenderBatchDepth += 1
    updates()
    swiftUIRenderBatchDepth -= 1
    guard swiftUIRenderBatchDepth == 0, needsBatchedSwiftUIRender else { return }
    needsBatchedSwiftUIRender = false
    renderSwiftUIProfile()
  }

  func setEngineChatId(_ value: String) {
    engineChatId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    fetchAgentConfigForCurrentChat()
    applyTheme()
    refreshAvatar()
    renderSwiftUIProfile()
  }

  func setEngineMyUserId(_ value: String) {
    engineMyUserId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    renderSwiftUIProfile()
  }

  func setEnginePeerUserId(_ value: String) {
    enginePeerUserId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    tableView.reloadData()
    applyTheme()
    refreshAvatar()
    renderSwiftUIProfile()
  }

  func setStatusAuthorityEnabled(_ enabled: Bool) {
    _ = enabled
  }

  func setAppearance(_ rawAppearance: [String: Any]) {
    applyTheme()
    tableView.reloadData()
    layoutHeroHeaderViewIfNeeded(force: true)
    renderSwiftUIProfile()
  }

  func setHeaderTitle(_ value: String) {
    headerTitle = value.trimmingCharacters(in: .whitespacesAndNewlines)
    applyTheme()
    refreshAvatar()
    reloadHeaderText()
    refreshHeroContent()
  }

  func setHeaderSubtitle(_ value: String) {
    headerSubtitle = value.trimmingCharacters(in: .whitespacesAndNewlines)
    reloadHeaderText()
  }

  func setProfileName(_ value: String) {
    profileName = value.trimmingCharacters(in: .whitespacesAndNewlines)
    applyTheme()
    refreshAvatar()
    reloadHeaderText()
    refreshHeroContent()
  }

  func setProfileHandle(_ value: String) {
    profileHandle = value.trimmingCharacters(in: .whitespacesAndNewlines)
    // Fall back to detecting a bridge agent from its reserved username when an
    // explicit provider wasn't supplied by the host.
    if bridgeProvider.isEmpty {
      let handle = profileHandle.lowercased().replacingOccurrences(of: "@", with: "")
      if handle == "claude" || handle == "codex" {
        setBridgeProvider(handle)
      }
    }
    refreshHeroContent()
    tableView.reloadData()
    renderSwiftUIProfile()
  }

  /// Marks this profile as a Claude/Codex paired-computer agent so it shows the
  /// "Computer" connection card (connect / disconnect / reconnect) and reads the
  /// agent's own conversation history from the connected computer.
  func setBridgeProvider(_ value: String) {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized == "claude" || normalized == "codex" else {
      if !bridgeProvider.isEmpty {
        bridgeProvider = ""
        renderSwiftUIProfile()
      }
      return
    }
    guard normalized != bridgeProvider else { return }
    bridgeProvider = normalized
    refreshBridgeStatus()
    renderSwiftUIProfile()
  }

  private func refreshBridgeStatus() {
    bridgeStatusRefreshWorkItem?.cancel()
    bridgeStatusRefreshWorkItem = nil
    guard !bridgeProvider.isEmpty, window != nil else { return }
    bridgeStatusTask?.cancel()
    bridgeStatusTask = Task { [weak self] in
      guard let config = AppSessionConfig.current else { return }
      let status = try? await AgentPairingService.status(config: config)
      guard let status, !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self else { return }
        let nextDeviceLabel = status.devices.first?.label ?? ""
        let nextRunningTasks = status.runningTasks.filter { task in
          let taskProvider = task.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          return taskProvider.isEmpty || taskProvider == self.bridgeProvider
        }
        let changed =
          self.bridgeConnected != status.connected
          || self.bridgePaired != status.paired
          || self.bridgeDeviceLabel != nextDeviceLabel
          || self.bridgeRunningTasks != nextRunningTasks

        self.bridgeConnected = status.connected
        self.bridgePaired = status.paired
        self.bridgeDeviceLabel = nextDeviceLabel
        self.bridgeRunningTasks = nextRunningTasks
        if changed {
          self.renderSwiftUIProfile()
        }
        self.scheduleBridgeStatusRefresh()
      }
    }
  }

  private func scheduleBridgeStatusRefresh() {
    bridgeStatusRefreshWorkItem?.cancel()
    guard !bridgeProvider.isEmpty, window != nil else { return }
    let item = DispatchWorkItem { [weak self] in
      self?.refreshBridgeStatus()
    }
    bridgeStatusRefreshWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
  }

  func setProfileBio(_ value: String) {
    profileBio = value.trimmingCharacters(in: .whitespacesAndNewlines)
    refreshHeroContent()
    tableView.reloadData()
    renderSwiftUIProfile()
  }

  func setAvatarUri(_ value: String?) {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard avatarUri != normalized else { return }
    avatarUri = normalized
    refreshAvatar()
    renderSwiftUIProfile()
  }

  func refreshProfileAppearance() {
    applyTheme()
    refreshAvatar()
    renderSwiftUIProfile()
    setNeedsLayout()
    updateAvatarMorphProgress()
  }

  func setIsOnline(_ value: Bool) {
    if isOnline == value { return }
    isOnline = value
    reloadHeaderText()
    refreshHeroContent()
  }

  func setIsChatMuted(_ value: Bool) {
    if isChatMuted == value { return }
    isChatMuted = value
    updateActionButtons()
    rebuildMenu()
    tableView.reloadData()
    renderSwiftUIProfile()
  }

  func setIsGroupOrChannel(_ value: Bool) {
    if isGroupOrChannel == value { return }
    isGroupOrChannel = value
    reloadHeaderText()
    refreshHeroContent()
    refreshAvatar()
    tableView.reloadData()
    // The live profile is the SwiftUI view — it must re-render when group-ness
    // flips, otherwise it keeps the DM layout (contact actions, no member rows).
    renderSwiftUIProfile()
  }

  func setGroupMembers(_ members: [[String: Any]]) {
    groupMembers = members
    tableView.reloadData()
    // Without this the members roster / header count never appear in the live
    // SwiftUI profile — it was only re-rendered by unrelated later setters.
    renderSwiftUIProfile()
    // The group hero is a mosaic composed from these members, so it must rebuild
    // when the roster arrives (members often land after the initial avatar set).
    refreshAvatar()
  }

  func setGroupMemberCount(_ value: Int?) {
    groupMemberCount = value
    tableView.reloadData()
    renderSwiftUIProfile()
  }

  func setAgentConfig(_ config: [String: Any]?) {
    agentConfig = normalizedAgentConfig(config, fallbackChatId: engineChatId)
    tableView.reloadData()
  }

  func setPage(_ value: String, animated: Bool) {
    _ = animated
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "agent" {
      presentAgentConfigEditor()
    }
  }

  private func configureView() {
    clipsToBounds = false

    // Background gradient
    backgroundGradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    backgroundGradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
    layer.insertSublayer(backgroundGradientLayer, at: 0)
    posterImageLayer.contentsGravity = .resizeAspectFill
    posterImageLayer.opacity = 0.0
    layer.insertSublayer(posterImageLayer, above: backgroundGradientLayer)

    // Avatar glass ring
    avatarGlassRing.clipsToBounds = true
    avatarGlassRing.isUserInteractionEnabled = false
    avatarGlassRing.isHidden = true
    avatarGlassRing.alpha = 0.0

    addSubview(headerMaskContainer)
    headerMaskContainer.clipsToBounds = true
    headerMaskContainer.isUserInteractionEnabled = false
    headerMaskContainer.layer.zPosition = 20.0
    headerMaskContainer.alpha = 0.0
    headerMaskView.isUserInteractionEnabled = false
    headerMaskContainer.addSubview(headerMaskView)
    headerMaskView.addSubview(headerMaskBlurView)
    headerMaskBlurView.contentView.addSubview(headerMaskOverlayView)
    headerMaskGradientLayer.colors = [
      UIColor.black.cgColor,
      UIColor.black.cgColor,
      UIColor.black.withAlphaComponent(0.0).cgColor,
    ]
    headerMaskGradientLayer.locations = [0.0, 0.74, 1.0]
    headerMaskView.layer.mask = headerMaskGradientLayer
    addSubview(headerContainer)
    headerContainer.clipsToBounds = false
    headerContainer.isHidden = true
    headerContainer.isUserInteractionEnabled = false
    headerContainer.addSubview(headerContentView)
    headerContainer.layer.zPosition = 60.0
    headerContentView.addSubview(backButton)
    headerContentView.addSubview(menuButton)
    headerContentView.addSubview(titleLabel)
    headerContentView.addSubview(subtitleLabel)

    backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    backButton.addTarget(self, action: #selector(handleBackPressed), for: .touchUpInside)

    ChatMainProfileHeaderHelpers.applyProfileMenuButtonStyle(menuButton)
    if #available(iOS 14.0, *) {
      menuButton.showsMenuAsPrimaryAction = true
    } else {
      menuButton.addTarget(self, action: #selector(handleLegacyMenuPressed), for: .touchUpInside)
    }

    titleLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.isHidden = true
    subtitleLabel.font = UIFont.systemFont(ofSize: 12.0, weight: .regular)
    subtitleLabel.textAlignment = .center
    subtitleLabel.isHidden = true

    tableView.dataSource = self
    tableView.delegate = self
    tableView.separatorStyle = .none
    tableView.register(
      ChatProfileListRowCell.self, forCellReuseIdentifier: ChatProfileListRowCell.reuseIdentifier)
    tableView.register(
      ChatProfileTabStripCell.self, forCellReuseIdentifier: ChatProfileTabStripCell.reuseIdentifier)
    tableView.register(
      ChatProfileMediaContentCell.self,
      forCellReuseIdentifier: ChatProfileMediaContentCell.reuseIdentifier)
    tableView.register(
      ChatProfileVoiceContentCell.self,
      forCellReuseIdentifier: ChatProfileVoiceContentCell.reuseIdentifier)
    tableView.register(
      ChatProfileMediaGridRowCell.self,
      forCellReuseIdentifier: ChatProfileMediaGridRowCell.reuseIdentifier)
    tableView.separatorInset = UIEdgeInsets(top: 0.0, left: 16.0, bottom: 0.0, right: 16.0)
    tableView.contentInsetAdjustmentBehavior = .never
    tableView.estimatedRowHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    if #available(iOS 15.0, *) {
      tableView.sectionHeaderTopPadding = 0.0
    }
    tableView.isHidden = true
    tableView.isUserInteractionEnabled = false
    addSubview(tableView)

    floatingAvatarView.clipsToBounds = false
    floatingAvatarView.isUserInteractionEnabled = false

    swiftUIContainerView.backgroundColor = .clear
    swiftUIContainerView.clipsToBounds = false
    swiftUIContainerView.layer.zPosition = 30.0
    addSubview(swiftUIContainerView)

    swiftUIContainerView.insertSubview(avatarGlassRing, at: 0)
    swiftUIContainerView.insertSubview(floatingAvatarView, at: 0)

    bringSubviewToFront(swiftUIContainerView)
    bringSubviewToFront(headerContainer)

    configureHeroHeaderView()

    configureBackButtonStyle()

    updateActionButtons()
    refreshAvatar()
    renderSwiftUIProfile()
  }

  private func attachSwiftUIHostIfNeeded() {
    guard let host = swiftUIHostingController else { return }
    if host.parent == nil, let parent = nearestViewController() {
      parent.addChild(host)
      host.didMove(toParent: parent)
    }
  }

  private func nearestViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let next = responder?.next {
      if let viewController = next as? UIViewController {
        return viewController
      }
      responder = next
    }
    return nil
  }

  private func renderSwiftUIProfile() {
    guard swiftUIRenderBatchDepth == 0 else {
      needsBatchedSwiftUIRender = true
      return
    }

    lastRenderedSafeAreaTop = resolvedSafeAreaTop()

    let resolvedName =
      profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? (headerTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "User" : headerTitle)
      : profileName

    let rootView = ChatProfileSwiftUIRootView(
      profileName: resolvedName,
      username: resolvedIdentifierRawValue().trimmingCharacters(in: .whitespacesAndNewlines),
      note: profileBio.trimmingCharacters(in: .whitespacesAndNewlines),
      isChatMuted: isChatMuted,
      isDark: traitCollection.userInterfaceStyle == .dark,
      historySubtitle: latestChatHistorySubtitle(),
      historyItems: swiftUIHistoryItems(),
      tabSummaries: swiftUITabSummaries(),
      tabItems: swiftUITabItems(),
      appearanceSelection: currentAppearanceSelection(resolvedName: resolvedName),
      hasProfileImage: hasResolvedProfileImage,
      avatarUri: resolvedAvatarImageUriForSwiftUI(),
      safeAreaTop: resolvedSafeAreaTop(),
      isGroupOrChannel: isGroupOrChannel,
      isGroupOwner: isGroupOwner,
      memberCount: groupMemberCount ?? (groupMembers.isEmpty ? nil : groupMembers.count),
      groupMembersSubtitle: groupMembersSummary(),
      groupMembers: groupMembers,
      canManageGroupMembers: canManageGroupMembers,
      groupBridgeProvider: groupBridgeProviderFromMembers(),
      groupBridgeProviders: groupBridgeProvidersFromMembers(),
      selectedRepositoryName: AgentBridgeSelectionStore.selectedRepository()?.name,
      bridgeProvider: bridgeProvider,
      bridgeChatId: engineChatId,
      bridgeConnected: bridgeConnected,
      bridgePaired: bridgePaired,
      bridgeDeviceLabel: bridgeDeviceLabel,
      bridgeRunningTasks: bridgeRunningTasks,
      onScroll: { [weak self] offset in
        guard let self else { return }
        self.swiftUIScrollOffset = offset
        self.updateAvatarMorphProgress()
      },
      onNavigationActiveChanged: { [weak self] active in
        guard let self else { return }
        self.swiftUINavigationActive = active
        self.setNeedsLayout()
      },
      onCopyUsername: { [weak self] in
        guard let self else { return }
        let username = self.resolvedIdentifierRawValue().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return }
        UIPasteboard.general.string = username
        self.onNativeEvent(["type": "profileIdPressed", "id": username])
      },
      onAction: { [weak self] action in
        self?.handleSwiftUIProfileAction(action)
      },
      onSaveAppearance: { [weak self] selection in
        guard let self else { return }
        self.saveCurrentAppearance(selection, resolvedName: resolvedName)
      },
      onContentPressed: { [weak self] payload in
        self?.onNativeEvent(payload)
      },
      onMembersAdded: { [weak self] added in
        guard let self else { return }
        let existingIds = Set(self.groupMembers.compactMap { $0["userId"] as? String })
        let newOnes = added.filter { entry in
          guard let uid = entry["userId"] as? String else { return false }
          return !existingIds.contains(uid)
        }
        guard !newOnes.isEmpty else { return }
        self.setGroupMembers(self.groupMembers + newOnes)
        self.renderSwiftUIProfile()
      }
    )
    let erasedRoot = AnyView(rootView)

    if let host = swiftUIHostingController {
      host.rootView = erasedRoot
      host.view.frame = swiftUIContainerView.bounds
      swiftUIContainerView.bringSubviewToFront(host.view)
    } else {
      let host = UIHostingController(rootView: erasedRoot)
      // NOTE: we deliberately do NOT strip the safe area here anymore. Keeping
      // the host's real safe area lets the SwiftUI root read `geometry
      // .safeAreaInsets.top` live, so the header and hero settle in one layout
      // pass on push — eliminating the snapshot-driven re-render "shift". The
      // backdrop/scroll still reach the screen edges via `.ignoresSafeArea`.
      host.view.backgroundColor = .clear
      host.view.isOpaque = false
      host.view.frame = swiftUIContainerView.bounds
      swiftUIContainerView.addSubview(host.view)
      swiftUIContainerView.bringSubviewToFront(host.view)
      swiftUIHostingController = host
      attachSwiftUIHostIfNeeded()
    }
  }

  private func currentAppearanceSelection(resolvedName: String? = nil) -> ChatProfileAppearanceSelection {
    ChatProfileAppearanceStore.selection(
      title: resolvedName ?? (profileName.isEmpty ? headerTitle : profileName),
      peerUserId: enginePeerUserId,
      chatId: engineChatId
    )
  }

  private func saveCurrentAppearance(
    _ selection: ChatProfileAppearanceSelection,
    resolvedName: String? = nil
  ) {
    let name = resolvedName ?? (profileName.isEmpty ? headerTitle : profileName)
    ChatProfileAppearanceStore.save(
      selection,
      title: name,
      peerUserId: enginePeerUserId,
      chatId: engineChatId
    )
    applyTheme()
    refreshAvatar()
    renderSwiftUIProfile()
    setNeedsLayout()
    updateAvatarMorphProgress()
    onNativeEvent(["type": "profileAppearanceUpdated"])
  }

  private var hasResolvedProfileImage: Bool {
    let rawAvatarHasValue =
      avatarUri?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    let hasPushAvatar =
      !isGroupOrChannel && !enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return rawAvatarHasValue || hasPushAvatar
  }

  private func resolvedAvatarImageUriForSwiftUI() -> String? {
    let rawAvatar = avatarUri
    let preferPushAvatar = !isGroupOrChannel
    return ChatAvatarURLResolver.resolve(
      rawAvatar: rawAvatar,
      peerUserId: enginePeerUserId,
      chatId: engineChatId,
      preferPushAvatar: preferPushAvatar
    )
  }

  private func handleSwiftUIProfileAction(_ action: String) {
    switch action {
    case "muteToggle":
      handleMutePressed()
    case "search":
      handleSearchPressed()
    case "audio":
      handleAudioPressed()
    case "video":
      handleVideoPressed()
    case "bridgeConnection":
      presentBridgeConnection()
    case let value where value.hasPrefix("bridgeRepository:"):
      let provider = String(value.dropFirst("bridgeRepository:".count))
      onNativeEvent(["type": "openAgentPanel", "provider": provider])
    case "agentConfig":
      presentAgentConfigEditor()
    case "headerBack":
      handleBackPressed()
    case "shareContact", "createNewContact", "addToExisting":
      onNativeEvent(["type": "profileContactAction", "action": action])
    case "addToEmergency":
      onNativeEvent(["type": "profileContactAction", "action": "addToEmergency"])
    case "block":
      onNativeEvent(["type": "profileContactAction", "action": "block"])
    case "editGroup", "leaveGroup", "deleteGroup":
      onNativeEvent([
        "type": "profileGroupAction",
        "action": action,
        "chatId": engineChatId,
        "name": profileName,
        "avatarUri": resolvedAvatarImageUriForSwiftUI() ?? "",
        "description": profileBio,
      ])
    default:
      break
    }
  }

  private func swiftUITabSummaries() -> [ChatProfileSwiftUITabSummary] {
    availableTabs.map {
      ChatProfileSwiftUITabSummary(
        tab: $0,
        title: sharedTitle(for: $0),
        subtitle: sharedSubtitle(for: $0)
      )
    }
  }

  private func swiftUITabItems() -> [ChatProfileTab: [ChatProfileSwiftUIContentItem]] {
    var result: [ChatProfileTab: [ChatProfileSwiftUIContentItem]] = [:]
    for tab in availableTabs {
      result[tab] = swiftUIContentItems(for: tab)
    }
    return result
  }

  private func swiftUIHistoryItems() -> [ChatProfileSwiftUIContentItem] {
    rows.enumerated().map { index, row in
      swiftUIContentItem(for: row, tab: nil, index: index, explicitURL: nil)
    }
  }

  private func swiftUIContentItems(for tab: ChatProfileTab) -> [ChatProfileSwiftUIContentItem] {
    switch tab {
    case .media:
      return mediaRows.enumerated().map { index, row in
        swiftUIContentItem(for: row, tab: tab, index: index, explicitURL: row.mediaUrl)
      }
    case .voice:
      return voiceRows.enumerated().map { index, row in
        swiftUIContentItem(for: row, tab: tab, index: index, explicitURL: row.mediaUrl)
      }
    case .gifs:
      return gifRows.enumerated().map { index, row in
        swiftUIContentItem(for: row, tab: tab, index: index, explicitURL: row.mediaUrl)
      }
    case .files:
      return fileRows.enumerated().map { index, row in
        swiftUIContentItem(for: row, tab: tab, index: index, explicitURL: row.mediaUrl)
      }
    case .links:
      return linkRows.enumerated().map { index, item in
        swiftUIContentItem(for: item.row, tab: tab, index: index, explicitURL: item.url)
      }
    case .pinned:
      return pinnedRows.enumerated().map { index, row in
        swiftUIContentItem(for: row, tab: tab, index: index, explicitURL: row.mediaUrl)
      }
    }
  }

  private func swiftUIContentItem(
    for row: ChatProfileRow,
    tab: ChatProfileTab?,
    index: Int,
    explicitURL: String?
  ) -> ChatProfileSwiftUIContentItem {
    let resolvedTab = tab?.rawValue ?? "history"
    let title: String = {
      if let explicitURL, tab == .links {
        return explicitURL
      }
      if let fileName = row.fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !fileName.isEmpty {
        return fileName
      }
      let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        return text
      }
      switch row.type {
      case "image":
        return "Photo"
      case "video":
        return "Video"
      case "voice":
        return "Voice message"
      case "music":
        return "Music"
      case "file":
        return "File"
      default:
        return row.type.isEmpty ? "Message" : row.type.capitalized
      }
    }()

    let subtitleParts = [
      row.type.isEmpty ? nil : row.type.capitalized,
      formattedRowDate(row),
    ].compactMap { $0 }

    var payload: [String: Any] = [
      "type": "profileContentPressed",
      "tab": resolvedTab,
      "messageId": row.messageId,
    ]
    if let explicitURL, !explicitURL.isEmpty {
      payload["url"] = explicitURL
    } else if let mediaUrl = row.mediaUrl, !mediaUrl.isEmpty {
      payload["url"] = mediaUrl
    }

    return ChatProfileSwiftUIContentItem(
      id: "\(resolvedTab)-\(row.messageId)-\(index)",
      title: title,
      subtitle: subtitleParts.joined(separator: " • "),
      systemImage: swiftUIContentSystemImage(for: tab, row: row),
      payload: payload
    )
  }

  private func swiftUIContentSystemImage(for tab: ChatProfileTab?, row: ChatProfileRow) -> String {
    if let tab {
      return sharedIconName(for: tab)
    }
    switch row.type {
    case "image", "video", "sticker":
      return "photo.on.rectangle.angled"
    case "voice":
      return "waveform"
    case "file", "music":
      return "doc.text.fill"
    default:
      return "message"
    }
  }

  private func configureHeroHeaderView() {
    heroHeaderView.backgroundColor = .clear
    heroHeaderView.clipsToBounds = false

    heroBannerView.clipsToBounds = true
    heroBannerView.layer.cornerCurve = .continuous
    heroBannerView.layer.cornerRadius = 26.0
    heroHeaderView.addSubview(heroBannerView)

    heroNameLabel.font = UIFont.systemFont(ofSize: 30.0, weight: .bold)
    heroNameLabel.textAlignment = .center
    heroBannerView.addSubview(heroNameLabel)

    heroHandleButton.titleLabel?.font = UIFont.systemFont(ofSize: 18.0, weight: .medium)
    heroHandleButton.titleLabel?.lineBreakMode = .byTruncatingTail
    heroHandleButton.contentHorizontalAlignment = .center
    heroHandleButton.addTarget(
      self, action: #selector(handleIdentifierPressed), for: .touchUpInside)
    heroBannerView.addSubview(heroHandleButton)

    heroBioLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
    heroBioLabel.textAlignment = .center
    heroBioLabel.numberOfLines = 0
    heroBannerView.addSubview(heroBioLabel)

    actionsStack.axis = .horizontal
    actionsStack.distribution = .equalSpacing
    actionsStack.alignment = .center
    actionsStack.spacing = 12.0
    actionsStack.semanticContentAttribute = .forceLeftToRight
    actionsStack.isLayoutMarginsRelativeArrangement = true
    actionsStack.layoutMargins = UIEdgeInsets(top: 0.0, left: 8.0, bottom: 0.0, right: 8.0)
    heroHeaderView.addSubview(actionsStack)

    muteActionButton.addTarget(self, action: #selector(handleMutePressed), for: .touchUpInside)
    searchActionButton.addTarget(self, action: #selector(handleSearchPressed), for: .touchUpInside)
    audioActionButton.addTarget(self, action: #selector(handleAudioPressed), for: .touchUpInside)
    videoActionButton.addTarget(self, action: #selector(handleVideoPressed), for: .touchUpInside)

    [muteActionButton, searchActionButton, audioActionButton, videoActionButton].forEach { button in
      button.translatesAutoresizingMaskIntoConstraints = false
      actionsStack.addArrangedSubview(button)
      // Priority 999 (not required): this stack lives in a tableHeaderView, which
      // AutoLayout sizes to 0×0 for a transient pass before the header gets its real
      // width. At width 0, four REQUIRED 68pt buttons + spacing + margins are
      // unsatisfiable → the "Unable to simultaneously satisfy constraints" storm. At
      // 999 AutoLayout can momentarily collapse them for that pass, then restore the
      // exact 68×70 once the header has a real width — same final layout, no console spam.
      let widthConstraint = button.widthAnchor.constraint(equalToConstant: 68.0)
      let heightConstraint = button.heightAnchor.constraint(equalToConstant: 70.0)
      widthConstraint.priority = .defaultHigh + 1
      heightConstraint.priority = .defaultHigh + 1
      NSLayoutConstraint.activate([widthConstraint, heightConstraint])
    }

    tableView.tableHeaderView = heroHeaderView
  }

  private func layoutHeroHeaderViewIfNeeded(force: Bool) {
    guard tableView.bounds.width > 0 else { return }

    let width = tableView.bounds.width
    let sideInset: CGFloat = 16.0
    let bannerTop: CGFloat = 0.0
    let baseBannerHeight = min(max(bounds.height * 0.50, 390.0), 500.0)
    let stretch: CGFloat = 0.0
    let bannerHeight = baseBannerHeight + stretch
    let bannerFrame = CGRect(
      x: sideInset, y: bannerTop, width: width - (sideInset * 2.0), height: bannerHeight)
    heroBannerView.frame = bannerFrame

    var y =
      currentHeroTop
      + NativeProfileAvatarHeroMetrics.expandedSize
      + NativeProfileAvatarHeroMetrics.bottomSpacing

    let nameHeight: CGFloat = 36.0
    heroNameLabel.frame = CGRect(
      x: 12.0, y: y, width: heroBannerView.bounds.width - 24.0, height: nameHeight)
    y = heroNameLabel.frame.maxY + 18.0

    let handleHeight: CGFloat = 24.0
    heroHandleButton.frame = CGRect(
      x: 12.0, y: y, width: heroBannerView.bounds.width - 24.0, height: handleHeight)
    y = heroHandleButton.isHidden ? y : heroHandleButton.frame.maxY + 8.0

    let bioText = heroBioLabel.text ?? ""
    let bioVisible = !bioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let maxBioWidth = heroBannerView.bounds.width - 26.0
    let bioHeight: CGFloat = {
      guard bioVisible else { return 0.0 }
      let size = CGSize(width: maxBioWidth, height: CGFloat.greatestFiniteMagnitude)
      let rect = (bioText as NSString).boundingRect(
        with: size,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: heroBioLabel.font as Any],
        context: nil
      )
      return ceil(max(20.0, rect.height))
    }()

    heroBioLabel.isHidden = !bioVisible
    if bioVisible {
      heroBioLabel.frame = CGRect(x: 13.0, y: y, width: maxBioWidth, height: bioHeight)
      y = heroBioLabel.frame.maxY + 14.0
    }

    let actionsHeight: CGFloat = 74.0
    let actionsWidth = min(width - 44.0, 360.0)
    let actionsTop = max(
      heroHandleButton.isHidden ? heroNameLabel.frame.maxY : heroHandleButton.frame.maxY,
      heroBioLabel.isHidden ? 0.0 : heroBioLabel.frame.maxY
    ) + 22.0
    actionsStack.frame = CGRect(
      x: (width - actionsWidth) * 0.5,
      y: actionsTop,
      width: actionsWidth,
      height: actionsHeight
    )
    actionsStack.alpha = 1.0
    actionsStack.transform = .identity

    let actionBottom = actionsStack.frame.maxY

    let finalHeaderHeight = max(heroBannerView.frame.maxY + 24.0, actionBottom + 28.0)

    if force || heroHeaderView.frame.width != width
      || abs(heroHeaderView.frame.height - finalHeaderHeight) > 0.5
    {
      heroHeaderView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: finalHeaderHeight)
      tableView.tableHeaderView = heroHeaderView
    }
  }

  private func updateAvatarMetrics() {
    let topInset = safeAreaInsets.top
    currentHeroTop = NativeProfileAvatarHeroMetrics.expandedTop(for: topInset)
    currentCollapsedTop = NativeProfileAvatarHeroMetrics.collapsedTop(for: topInset)

    floatingAvatarView.setExpandedSize(NativeProfileAvatarHeroMetrics.expandedSize)
    floatingAvatarView.setCollapsedSize(NativeProfileAvatarHeroMetrics.collapsedSize)
    floatingAvatarView.setExpandedTopInset(currentHeroTop)
    floatingAvatarView.setCollapsedTopInset(currentCollapsedTop)
  }

  private func layoutFloatingAvatarView() {
    guard bounds.width > 0 else { return }
    let hostHeight = NativeProfileAvatarHeroMetrics.hostHeight(for: safeAreaInsets.top)

    floatingAvatarView.frame = CGRect(
      x: 0.0,
      y: 0.0,
      width: bounds.width,
      height: hostHeight
    )
    updateAvatarMetrics()
  }

  private func layoutAvatarGlassRing() {
    guard bounds.width > 0 else { return }

    let expandedSize = NativeProfileAvatarHeroMetrics.expandedSize
    let ringPadding: CGFloat = 14.0

    let offset = max(0.0, swiftUIScrollOffset)
    let progress = max(0.0, min(1.0, offset / 220.0))

    let currentSize = expandedSize - (22.0 * progress)
    let ringSize = currentSize + ringPadding

    let centerX = bounds.width * 0.5
    let centerY = currentHeroTop + expandedSize * 0.5 - (10.0 * progress)

    avatarGlassRing.frame = CGRect(
      x: centerX - ringSize * 0.5,
      y: centerY - ringSize * 0.5,
      width: ringSize,
      height: ringSize
    )
    avatarGlassRing.layer.cornerRadius = ringSize * 0.5

    avatarGlassRing.isHidden = true
    avatarGlassRing.alpha = 0.0
  }

  private func layoutActionsForCurrentScroll() {
    layoutHeroHeaderViewIfNeeded(force: false)
  }

  private func applyTheme() {
    let isDark = traitCollection.userInterfaceStyle == .dark
    let resolvedName = profileName.isEmpty ? headerTitle : profileName
    let posterColors = ChatProfileAppearanceStore.posterColors(
      title: resolvedName,
      peerUserId: enginePeerUserId,
      chatId: engineChatId
    )
    let posterTop = posterColors.0
    let posterBottom = posterColors.1
    let posterMid = posterTop.blended(withFraction: 0.42, of: posterBottom)

    backgroundGradientLayer.colors = [
      posterTop.cgColor,
      posterMid.cgColor,
      posterBottom.cgColor,
    ]
    backgroundGradientLayer.locations = [0.0, 0.48, 1.0]

    if let posterImage = ChatProfileAppearanceStore.posterImage(
      title: resolvedName,
      peerUserId: enginePeerUserId,
      chatId: engineChatId
    )?.cgImage {
      posterImageLayer.contents = posterImage
      posterImageLayer.opacity = isDark ? 0.54 : 0.42
    } else {
      posterImageLayer.contents = nil
      posterImageLayer.opacity = 0.0
    }

    let background = UIColor.clear // gradient handles background
    let text = isDark ? UIColor.white : UIColor.black
    let secondary = isDark ? UIColor(white: 0.72, alpha: 1.0) : UIColor(white: 0.44, alpha: 1.0)
    let card =
      isDark
      ? UIColor(red: 43.0 / 255.0, green: 50.0 / 255.0, blue: 58.0 / 255.0, alpha: 0.44)
      : UIColor.white.withAlphaComponent(0.72)
    let rowAccent =
      isDark
      ? UIColor(red: 77 / 255, green: 217 / 255, blue: 229 / 255, alpha: 1.0)
      : UIColor(red: 0 / 255, green: 122 / 255, blue: 124 / 255, alpha: 1.0)
    let fallbackAvatarColors = ChatProfileAppearanceStore.avatarColors(
      title: resolvedName,
      peerUserId: enginePeerUserId,
      chatId: engineChatId
    )
    let fallbackAvatarIconTint = text

    backgroundColor = background
    headerContainer.backgroundColor = .clear
    headerMaskContainer.backgroundColor = .clear
    headerMaskBlurView.effect = { () -> UIVisualEffect? in
      if #available(iOS 26.0, *) {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        return effect
      }
      return UIBlurEffect(style: isDark ? .systemMaterialDark : .systemMaterialLight)
    }()
    headerMaskOverlayView.backgroundColor =
      (isDark ? UIColor.black : UIColor.white).withAlphaComponent(isDark ? 0.12 : 0.10)

    titleLabel.textColor = text
    subtitleLabel.textColor = secondary
    backButton.tintColor = text
    menuButton.tintColor = text

    tableView.backgroundColor = .clear
    tableView.tintColor = .systemBlue
    tableView.separatorColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.08)
      : UIColor(white: 0.0, alpha: 0.08)

    heroNameLabel.textColor = text
    heroHandleButton.setTitleColor(secondary, for: .normal)
    heroBioLabel.textColor = secondary
    heroBannerView.backgroundColor = .clear

    // Use a dark base for the island cover so avatar morph blends into gradient
    floatingAvatarView.setIslandCoverUIColor(posterTop)
    floatingAvatarView.setFallbackGradientUIColors(
      start: fallbackAvatarColors.0,
      end: fallbackAvatarColors.1
    )
    floatingAvatarView.setFallbackIconTintUIColor(fallbackAvatarIconTint)

    // Avatar glass ring effect
    if isDark {
      avatarGlassRing.effect = UIBlurEffect(style: .systemThinMaterialDark)
      avatarGlassRing.contentView.backgroundColor = .clear
    } else {
      avatarGlassRing.effect = UIBlurEffect(style: .systemThinMaterialLight)
      avatarGlassRing.contentView.backgroundColor = .clear
    }

    currentTextColor = text
    currentSecondaryTextColor = secondary
    currentRowSeparatorColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.08)
      : UIColor(white: 0.0, alpha: 0.08)
    currentRowHighlightColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.06)
      : UIColor(white: 0.0, alpha: 0.04)
    currentRowCardColor =
      isDark
      ? UIColor(red: 53.0/255.0, green: 62.0/255.0, blue: 72.0/255.0, alpha: 0.34)
      : UIColor.white.withAlphaComponent(0.68)
    currentRowAccentColor = rowAccent
    currentRowIconBackgroundColor = rowAccent.withAlphaComponent(0.12)

    [muteActionButton, searchActionButton, audioActionButton, videoActionButton].forEach {
      $0.applyTheme(foreground: text, background: card)
    }
    configureBackButtonStyle()

    reloadDataKeepingSelection()
  }

  private func resolvedDefaultSubtitleText() -> String {
    if isOnline {
      return "Online"
    }

    if !headerSubtitle.isEmpty {
      return headerSubtitle
    }

    return isGroupOrChannel ? "Group Profile" : "Profile"
  }

  private func resolvedActiveTabSubtitleText() -> String? {
    return nil
  }

  private func resolvedHeroSubheaderText() -> String {
    return resolvedActiveTabSubtitleText() ?? resolvedIdentifierText()
  }

  private func reloadHeaderText() {
    let resolvedName =
      profileName.isEmpty ? (headerTitle.isEmpty ? "Profile" : headerTitle) : profileName
    titleLabel.text = resolvedName
    subtitleLabel.text = resolvedActiveTabSubtitleText() ?? resolvedDefaultSubtitleText()
    renderSwiftUIProfile()
  }

  private func refreshHeroSubheader() {
    heroHandleButton.setTitle(nil, for: .normal)
    heroHandleButton.isHidden = true
  }

  private func refreshHeroContent() {
    let resolvedName =
      profileName.isEmpty ? (headerTitle.isEmpty ? "User" : headerTitle) : profileName
    heroNameLabel.text = resolvedName
    floatingAvatarView.setFallbackText(resolvedAvatarFallbackText())

    refreshHeroSubheader()

    let bio = profileBio.trimmingCharacters(in: .whitespacesAndNewlines)
    heroBioLabel.text = bio

    updateActionButtons()
    layoutHeroHeaderViewIfNeeded(force: true)
    renderSwiftUIProfile()
  }

  private func updateActionButtons() {
    muteActionButton.configure(
      title: isChatMuted ? "Unmute" : "Mute", symbol: isChatMuted ? "bell" : "bell.slash")
    searchActionButton.configure(title: "Search", symbol: "magnifyingglass")
    audioActionButton.configure(title: "Call", symbol: "phone")
    videoActionButton.configure(title: "Video", symbol: "video")
  }

  private func configureBackButtonStyle() {
    let symbol = UIImage(
      systemName: "chevron.left",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)
    )

    if #available(iOS 26.0, *) {
      var config = UIButton.Configuration.glass()
      config.cornerStyle = .capsule
      config.image = symbol
      config.contentInsets = NSDirectionalEdgeInsets(
        top: 10.0, leading: 10.0, bottom: 10.0, trailing: 10.0)
      backButton.configuration = config
      return
    }

    backButton.configuration = nil
    backButton.setImage(symbol, for: .normal)
    backButton.backgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.92)
    backButton.layer.cornerRadius = 21.0
    backButton.layer.cornerCurve = .continuous
  }

  private func updateAvatarMorphProgress() {
    guard bounds.width > 0 else { return }

    let offset = max(0.0, swiftUIScrollOffset)
    let progress = max(0.0, min(1.0, offset / 220.0))
    avatarMorphProgress = progress
    floatingAvatarView.setScrollOffset(offset)
    headerMaskContainer.alpha = 0.0
    headerMaskContainer.isHidden = true
    titleLabel.isHidden = true
    subtitleLabel.isHidden = true
    titleLabel.alpha = 0.0
    subtitleLabel.alpha = 0.0
    layoutActionsForCurrentScroll()

    layoutAvatarGlassRing()
  }

  private func refreshAvatar() {
    avatarResolveGeneration &+= 1
    let generation = avatarResolveGeneration
    floatingAvatarView.setFallbackText(resolvedAvatarFallbackText())
    let fallbackColors = ChatProfileAppearanceStore.avatarColors(
      title: profileName.isEmpty ? headerTitle : profileName,
      peerUserId: enginePeerUserId,
      chatId: engineChatId
    )
    floatingAvatarView.setFallbackGradientUIColors(
      start: fallbackColors.0,
      end: fallbackColors.1
    )
    floatingAvatarView.setFallbackIconTintUIColor(.white)

    let rawAvatar = avatarUri
    let peerUserId = enginePeerUserId
    let chatId = engineChatId
    let preferPushAvatar = !isGroupOrChannel
    let hasRawAvatar =
      rawAvatar?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    let hasPeerUser = !peerUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasRawAvatar || (preferPushAvatar && hasPeerUser) else {
      // No single avatar. For a group we compose the SAME member-mosaic the home
      // list shows (from the members' avatar URLs we already have) rather than
      // dropping to a bare initials tile.
      if isGroupOrChannel {
        loadGroupCompositeAvatar(generation: generation)
      } else {
        floatingAvatarView.setImageUri(nil)
      }
      return
    }

    DispatchQueue.global(qos: .utility).async { [rawAvatar, peerUserId, chatId, preferPushAvatar, generation] in
      let resolvedUri = ChatAvatarURLResolver.resolve(
        rawAvatar: rawAvatar,
        peerUserId: peerUserId,
        chatId: chatId,
        preferPushAvatar: preferPushAvatar
      )
      DispatchQueue.main.async { [weak self] in
        guard let self, self.avatarResolveGeneration == generation else { return }
        self.floatingAvatarView.setImageUri(resolvedUri)
      }
    }
  }

  /// Build the group mosaic hero from the current members and show it. Falls back
  /// to the initials tile when there aren't at least two members with avatars.
  /// Guarded by `avatarResolveGeneration` so a stale build can't overwrite a newer
  /// avatar (e.g. after the group photo is set).
  private func loadGroupCompositeAvatar(generation: UInt) {
    let members = groupMembers
    let isDark = traitCollection.userInterfaceStyle == .dark
    guard GroupCompositeAvatar.slots(from: members).count >= 2 else {
      floatingAvatarView.setImageUri(nil)
      return
    }
    let side = NativeProfileAvatarHeroMetrics.expandedSize
    Task { [weak self] in
      let image = await GroupCompositeAvatar.composedImage(
        members: members, side: side, isDark: isDark)
      await MainActor.run {
        guard let self, self.avatarResolveGeneration == generation else { return }
        if let image {
          self.floatingAvatarView.setComposedImage(image)
        } else {
          self.floatingAvatarView.setImageUri(nil)
        }
      }
    }
  }

  private func resolvedAvatarFallbackText() -> String {
    let resolvedName =
      profileName.isEmpty ? (headerTitle.isEmpty ? "User" : headerTitle) : profileName
    let trimmed = resolvedName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "U" : String(trimmed.prefix(1)).uppercased()
  }

  private func rebuildDerivedContent() {
    mediaRows = rows.filter { ["image", "video", "sticker"].contains($0.type) }
    voiceRows = rows.filter { $0.type == "voice" }
    gifRows = rows.filter { $0.type == "gif" }
    fileRows = rows.filter { ["file", "music"].contains($0.type) }
    pinnedRows = rows.filter { $0.isPinned }

    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    var links: [ChatProfileLinkItem] = []
    for row in rows {
      guard let detector else { continue }
      guard !row.isAgentMessage else { continue }
      guard !["file", "music", "voice", "image", "video", "sticker", "gif"].contains(row.type) else {
        continue
      }

      let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.range(of: #"https?://|www\."#, options: [.regularExpression, .caseInsensitive]) != nil else {
        continue
      }
      let nsText = trimmed as NSString
      let matches = detector.matches(
        in: trimmed, options: [], range: NSRange(location: 0, length: nsText.length))
      if let first = matches.first?.url,
        let scheme = first.scheme?.lowercased(),
        ["http", "https"].contains(scheme)
      {
        links.append(ChatProfileLinkItem(row: row, url: first.absoluteString))
      }
    }
    linkRows = links

    var tabs: [ChatProfileTab] = []
    if !mediaRows.isEmpty { tabs.append(.media) }
    if !voiceRows.isEmpty { tabs.append(.voice) }
    if !gifRows.isEmpty { tabs.append(.gifs) }
    if !fileRows.isEmpty { tabs.append(.files) }
    if !linkRows.isEmpty { tabs.append(.links) }
    if !pinnedRows.isEmpty { tabs.append(.pinned) }
    availableTabs = tabs
    if !availableTabs.contains(activeTab), let first = availableTabs.first {
      activeTab = first
    }
    reloadHeaderText()
    refreshHeroSubheader()
    syncTabViews()
  }

  private func currentInfoRows() -> [ChatProfileInfoRow] {
    var result: [ChatProfileInfoRow] = []
    if isGroupOrChannel {
      result.append(.members)
      result.append(.agent)
    } else {
      result.append(.identifier)
    }

    if !profileBio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      result.append(.bio)
    }

    return result
  }

  private func sharedCount(for tab: ChatProfileTab) -> Int {
    switch tab {
    case .media:
      return mediaRows.count
    case .voice:
      return voiceRows.count
    case .gifs:
      return gifRows.count
    case .files:
      return fileRows.count
    case .links:
      return linkRows.count
    case .pinned:
      return pinnedRows.count
    }
  }

  private func sharedTitle(for tab: ChatProfileTab) -> String {
    switch tab {
    case .media:
      return "Media"
    case .voice:
      return "Voice"
    case .gifs:
      return "GIFs"
    case .files:
      return "Files"
    case .links:
      return "Links"
    case .pinned:
      return "Pinned"
    }
  }

  private func sharedSubtitle(for tab: ChatProfileTab) -> String {
    let count = sharedCount(for: tab)
    switch tab {
    case .media:
      return count == 1 ? "1 photo or video" : "\(count) photos and videos"
    case .voice:
      return count == 1 ? "1 voice message" : "\(count) voice messages"
    case .gifs:
      return count == 1 ? "1 GIF" : "\(count) GIFs"
    case .files:
      return count == 1 ? "1 file" : "\(count) files"
    case .links:
      return count == 1 ? "1 shared link" : "\(count) shared links"
    case .pinned:
      return count == 1 ? "1 pinned message" : "\(count) pinned messages"
    }
  }

  private func sharedIconName(for tab: ChatProfileTab) -> String {
    switch tab {
    case .media:
      return "photo.on.rectangle.angled"
    case .voice:
      return "waveform"
    case .gifs:
      return "sparkles.tv"
    case .files:
      return "doc.text.fill"
    case .links:
      return "link"
    case .pinned:
      return "pin.fill"
    }
  }

  private func groupMembersSummary() -> String {
    let names = groupMembers.compactMap { member -> String? in
      let displayName =
        (member["name"] as? String)
        ?? (member["displayName"] as? String)
        ?? (member["username"] as? String)
        ?? (member["userId"] as? String)
      let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty ? nil : trimmed
    }
    guard !names.isEmpty else { return "View all participants" }
    return names.prefix(3).joined(separator: ", ")
  }

  private var canManageGroupMembers: Bool {
    guard isGroupOrChannel, !engineMyUserId.isEmpty else { return false }
    let mine = groupMembers.first { entry in
      let id = (entry["userId"] as? String) ?? (entry["id"] as? String) ?? (entry["memberId"] as? String)
      return id?.caseInsensitiveCompare(engineMyUserId) == .orderedSame
    }
    let role = (mine?["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return role == "owner" || role == "admin"
  }

  /// True when the signed-in user is the group's owner (creator). Owners see
  /// "Delete Group" instead of "Leave Group" and can manage admin roles.
  private var isGroupOwner: Bool {
    guard isGroupOrChannel, !engineMyUserId.isEmpty else { return false }
    let mine = groupMembers.first { entry in
      let id = (entry["userId"] as? String) ?? (entry["id"] as? String) ?? (entry["memberId"] as? String)
      return id?.caseInsensitiveCompare(engineMyUserId) == .orderedSame
    }
    let role = (mine?["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return role == "owner"
  }

  /// Every bridge agent present in this group ("claude"/"codex"), for the per-agent
  /// settings rows. `groupBridgeProviderFromMembers()` stays the single-value variant
  /// used by rows that only need to know "this group has agents at all".
  private func groupBridgeProvidersFromMembers() -> [String] {
    var providers: [String] = []
    for member in groupMembers {
      let values = [
        member["userId"],
        member["user_id"],
        member["id"],
        member["name"],
        member["displayName"],
        member["username"],
        member["handle"],
        member["label"]
      ]
      .compactMap { value -> String? in
        if let string = value as? String {
          return string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if let number = value as? NSNumber {
          return number.stringValue.lowercased()
        }
        return nil
      }

      if values.contains("11111111-1111-1111-1111-111111111111")
        || values.contains("00000000-0000-0000-0000-0000000000c1")
        || values.contains("claude")
        || values.contains("@claude")
      {
        if !providers.contains("claude") { providers.append("claude") }
      } else if values.contains("22222222-2222-2222-2222-222222222222")
        || values.contains("00000000-0000-0000-0000-0000000000c2")
        || values.contains("codex")
        || values.contains("@codex")
      {
        if !providers.contains("codex") { providers.append("codex") }
      }
    }
    return providers
  }

  private func groupBridgeProviderFromMembers() -> String? {
    for member in groupMembers {
      let values = [
        member["userId"],
        member["user_id"],
        member["id"],
        member["name"],
        member["displayName"],
        member["username"],
        member["handle"],
        member["label"]
      ]
      .compactMap { value -> String? in
        if let string = value as? String {
          return string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if let number = value as? NSNumber {
          return number.stringValue.lowercased()
        }
        return nil
      }

      if values.contains("11111111-1111-1111-1111-111111111111")
        || values.contains("00000000-0000-0000-0000-0000000000c1")
        || values.contains("claude")
        || values.contains("@claude")
      {
        return "claude"
      }

      if values.contains("22222222-2222-2222-2222-222222222222")
        || values.contains("00000000-0000-0000-0000-0000000000c2")
        || values.contains("codex")
        || values.contains("@codex")
      {
        return "codex"
      }
    }

    return nil
  }

  private func configureListRowCell(
    _ cell: ChatProfileListRowCell,
    title: String,
    subtitle: String,
    value: String = "",
    iconName: String,
    showsSeparator: Bool,
    showsChevron: Bool = true
  ) {
    cell.rowNode.isHidden = true

    var config = UIListContentConfiguration.subtitleCell()
    config.text = title
    config.textProperties.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
    config.textProperties.color = currentTextColor
    if !subtitle.isEmpty {
      config.secondaryText = subtitle
      config.secondaryTextProperties.font = UIFont.systemFont(ofSize: 13, weight: .regular)
      config.secondaryTextProperties.color = currentSecondaryTextColor
    }
    config.image = UIImage(systemName: iconName)
    config.imageProperties.tintColor = .systemBlue
    cell.contentConfiguration = config

    if !value.isEmpty {
      let badge = UILabel()
      badge.text = value
      badge.font = UIFont.systemFont(ofSize: 15, weight: .medium)
      badge.textColor = currentSecondaryTextColor
      badge.sizeToFit()
      cell.accessoryView = badge
    } else {
      cell.accessoryView = nil
    }
    cell.accessoryType = showsChevron ? .disclosureIndicator : .none

    cell.backgroundColor = .clear
    if #available(iOS 14.0, *) {
      var background = UIBackgroundConfiguration.listGroupedCell()
      background.backgroundColor = .clear
      let isDark = traitCollection.userInterfaceStyle == .dark
      background.visualEffect = UIBlurEffect(style: isDark ? .systemThinMaterialDark : .systemThinMaterialLight)
      cell.backgroundConfiguration = background
    }
  }

  private func resolvedBioPreview() -> String {
    let bio = profileBio.trimmingCharacters(in: .whitespacesAndNewlines)
    return bio.isEmpty ? "No bio" : bio
  }

  private func resolvedIdentifierPreview() -> String {
    let value = resolvedIdentifierRawValue().trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "Unavailable" : value
  }

  private func resolvedAgentValue() -> String {
    guard let config = agentConfig else { return "Off" }
    return normalizedAgentEnabledValue(config["enabled"], defaultValue: true) ? "On" : "Off"
  }

  private func resolvedAgentSubtitle() -> String {
    guard let config = agentConfig else { return "Not configured" }
    let name = normalizedAgentString(config["name"]) ?? "Vibe AI"
    let docs = getAgentDocuments().count
    return "\(name) • \(docs) docs"
  }

  private func resolveSectionTitle(_ section: Section) -> String? {
    return nil
  }

  private func tabButtonTitle(_ tab: ChatProfileTab) -> String {
    sharedTitle(for: tab)
  }

  private func currentContentCount() -> Int {
    switch activeTab {
    case .media:
      return Int(ceil(Double(mediaRows.count) / 3.0))
    case .voice:
      return voiceRows.count
    case .gifs:
      return gifRows.count
    case .files:
      return fileRows.count
    case .links:
      return linkRows.count
    case .pinned:
      return pinnedRows.count
    }
  }

  private func contentRow(at index: Int) -> ChatProfileRow? {
    switch activeTab {
    case .media:
      guard mediaRows.indices.contains(index) else { return nil }
      return mediaRows[index]
    case .voice:
      guard voiceRows.indices.contains(index) else { return nil }
      return voiceRows[index]
    case .gifs:
      guard gifRows.indices.contains(index) else { return nil }
      return gifRows[index]
    case .files:
      guard fileRows.indices.contains(index) else { return nil }
      return fileRows[index]
    case .links:
      guard linkRows.indices.contains(index) else { return nil }
      return linkRows[index].row
    case .pinned:
      guard pinnedRows.indices.contains(index) else { return nil }
      return pinnedRows[index]
    }
  }

  private func contentSubtitle(for row: ChatProfileRow) -> String {
    switch activeTab {
    case .media:
      return formattedRowDate(row) ?? "Media"
    case .voice:
      return [formattedFileSize(row.fileSize), formattedRowDate(row)].compactMap { $0 }
        .joined(separator: " · ")
    case .gifs:
      return formattedRowDate(row) ?? "GIF"
    case .files:
      return [formattedFileSize(row.fileSize), formattedRowDate(row)].compactMap { $0 }
        .joined(separator: " · ")
    case .links:
      return formattedRowDate(row) ?? "Link"
    case .pinned:
      return formattedRowDate(row) ?? "Pinned"
    }
  }

  private func contentTitle(for row: ChatProfileRow, index: Int) -> String {
    switch activeTab {
    case .media:
      if row.type == "video" { return "Video" }
      if row.type == "sticker" { return "Sticker" }
      return "Photo"
    case .voice:
      return row.fileName ?? "Voice message"
    case .gifs:
      return "GIF"
    case .files:
      return row.fileName ?? "File"
    case .links:
      return linkRows[index].url
    case .pinned:
      let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? "Pinned message" : text
    }
  }

  private func reloadContentSectionWithoutAnimation() {
  }

  private func switchToTab(_ nextTab: ChatProfileTab, animated: Bool) {
  }

  private func scrollTabsIntoView(animated: Bool) {
  }

  private func syncTabViews() {
  }

  private func updateStickyTabsPresentation() {
  }

  private func resolvedIdentifierText() -> String {
    let handle = resolvedIdentifierRawValue()
    if handle.isEmpty {
      return "Username unavailable"
    }
    return handle
  }

  private func resolvedIdentifierRawValue() -> String {
    let handle = profileHandle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !handle.isEmpty, !handle.lowercased().hasPrefix("id:"), !Self.looksLikeUUID(handle) {
      return handle.hasPrefix("@") ? handle : "@\(handle)"
    }

    let fallbackName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    if Self.looksLikeUUID(fallbackName) {
      return ""
    }
    let compact =
      fallbackName
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .joined()
      .lowercased()
    if !compact.isEmpty {
      return "@\(compact)"
    }
    return ""
  }

  private static func looksLikeUUID(_ value: String) -> Bool {
    UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
  }

  private func getAgentDocuments() -> [(id: String, name: String, url: String)] {
    return fileRows.compactMap { item in
      let url = item.mediaUrl ?? ""
      if url.contains("/api/agent/document/") || url.contains("/uploads/agent-docs/")
        || url.contains("/agent/document/") || url.contains("/agent-docs/")
      {
        return (
          id: item.messageId,
          name: (item.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? item.fileName!
            : "Document",
          url: url
        )
      }
      return nil
    }
  }

  private func rebuildMenu() {
    if #available(iOS 14.0, *) {
      let clearAction = UIAction(
        title: "Clear Chat",
        image: UIImage(systemName: "trash"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "clearChat"])
      }

      let deleteAction = UIAction(
        title: "Delete",
        image: UIImage(systemName: "xmark.bin"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "delete"])
      }

      let blockAction = UIAction(
        title: "Block",
        image: UIImage(systemName: "hand.raised"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "blockUser"])
      }

      menuButton.menu = UIMenu(children: [clearAction, deleteAction, blockAction])
    }
  }

  @objc private func handleBackPressed() {
    onNativeEvent(["type": "headerBack"])
  }

  @objc private func handleLegacyMenuPressed() {
    guard let presenter = topMostViewController() else { return }
    let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

    sheet.addAction(
      UIAlertAction(title: "Clear Chat", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "clearChat"])
      })

    sheet.addAction(
      UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "delete"])
      })

    sheet.addAction(
      UIAlertAction(title: "Block", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "blockUser"])
      })

    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

    if let popover = sheet.popoverPresentationController {
      popover.sourceView = menuButton
      popover.sourceRect = menuButton.bounds
      popover.permittedArrowDirections = [.up, .down]
    }

    presenter.present(sheet, animated: true)
  }

  @objc private func handleMutePressed() {
    onNativeEvent(["type": "headerMenuAction", "action": "muteToggle"])
  }

  @objc private func handleSearchPressed() {
    onNativeEvent(["type": "headerSearchPressed"])
  }

  @objc private func handleAudioPressed() {
    onNativeEvent(["type": "headerAudioCallPressed"])
  }

  @objc private func handleVideoPressed() {
    onNativeEvent(["type": "headerVideoCallPressed"])
  }

  @objc private func handleIdentifierPressed() {
    if !availableTabs.isEmpty {
      scrollTabsIntoView(animated: true)
      return
    }

    let raw = resolvedIdentifierRawValue()
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    UIPasteboard.general.string = raw
    onNativeEvent(["type": "profileIdPressed", "id": raw])
  }

  private func reloadDataKeepingSelection() {
    tableView.reloadData()
    layoutHeroHeaderViewIfNeeded(force: true)
    syncTabViews()
    updateStickyTabsPresentation()
    renderSwiftUIProfile()
  }

  // MARK: UITableViewDataSource

  private enum Section: Int, CaseIterable {
    case profileInfo
    case chatHistory
    case sharedContent
    case contactActions
    case emergency
    case dangerActions
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === tableView else { return }
    if scrollView.contentOffset.y < 0.0 {
      layoutHeroHeaderViewIfNeeded(force: false)
    }
    updateAvatarMorphProgress()
  }

  func numberOfSections(in tableView: UITableView) -> Int {
    return Section.allCases.count
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    guard let section = Section(rawValue: section) else { return 0 }

    switch section {
    case .profileInfo:
      return profileInfoRowCount()
    case .chatHistory:
      return rows.isEmpty ? 0 : 1
    case .sharedContent:
      return availableTabs.count
    case .contactActions:
      return 3
    case .emergency:
      return 1
    case .dangerActions:
      return 1
    }
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    guard let section = Section(rawValue: section) else { return nil }
    return resolveSectionTitle(section)
  }

  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    .leastNormalMagnitude
  }

  func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
    12.0
  }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    guard let section = Section(rawValue: indexPath.section) else {
      return UITableView.automaticDimension
    }

    switch section {
    case .profileInfo:
      return indexPath.row == 1 ? UITableView.automaticDimension : 62.0
    case .chatHistory:
      return 74.0
    case .sharedContent:
      return 58.0
    case .contactActions, .emergency, .dangerActions:
      return 44.0
    }
  }

  private func contentListCell(
    _ tableView: UITableView,
    indexPath: IndexPath
  ) -> UITableViewCell {
    guard let row = contentRow(at: indexPath.row) else {
      return UITableViewCell(style: .default, reuseIdentifier: nil)
    }
    if activeTab == .voice {
      guard
        let cell = tableView.dequeueReusableCell(
          withIdentifier: ChatProfileVoiceContentCell.reuseIdentifier,
          for: indexPath
        ) as? ChatProfileVoiceContentCell
      else {
        return UITableViewCell(style: .default, reuseIdentifier: nil)
      }

      cell.configure(
        title: contentTitle(for: row, index: indexPath.row),
        subtitle: contentSubtitle(for: row),
        row: row,
        titleColor: currentTextColor,
        subtitleColor: currentSecondaryTextColor,
        accentColor: currentRowAccentColor
      )
      VoiceBubblePlaybackCoordinator.shared.bind(
        cell: cell,
        messageId: row.messageId,
        mediaURL: row.mediaUrl,
        mediaKey: row.mediaKey,
        fileName: row.fileName
      )
      return cell
    }

    if activeTab == .media {
      guard
        let cell = tableView.dequeueReusableCell(
          withIdentifier: ChatProfileMediaGridRowCell.reuseIdentifier,
          for: indexPath
        ) as? ChatProfileMediaGridRowCell
      else {
        return UITableViewCell(style: .default, reuseIdentifier: nil)
      }
      var items: [(url: String?, isVideo: Bool, thumbnailBase64: String?)] = []
      let startIndex = indexPath.row * 3
      for i in 0..<3 {
        let absIndex = startIndex + i
        if absIndex < mediaRows.count {
          let r = mediaRows[absIndex]
          items.append((url: r.mediaUrl, isVideo: r.type == "video", thumbnailBase64: r.thumbnailBase64))
        }
      }
      cell.configure(
        items: items,
        startIndex: startIndex,
        placeholderTintColor: currentTextColor.withAlphaComponent(0.72),
        placeholderBackgroundColor: currentRowCardColor
      )
      cell.onMediaTapped = { [weak self] index in
        self?.handleMediaGridTapped(at: index)
      }
      return cell
    }

    if activeTab == .gifs {
      guard
        let cell = tableView.dequeueReusableCell(
          withIdentifier: ChatProfileMediaContentCell.reuseIdentifier,
          for: indexPath
        ) as? ChatProfileMediaContentCell
      else {
        return UITableViewCell(style: .default, reuseIdentifier: nil)
      }
      cell.backgroundColor = .clear
      cell.contentView.backgroundColor = .clear
      if #available(iOS 14.0, *) {
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = .clear
        let isDark = traitCollection.userInterfaceStyle == .dark
        background.visualEffect = UIBlurEffect(style: isDark ? .systemThinMaterialDark : .systemThinMaterialLight)
        background.cornerRadius = 22.0
        cell.backgroundConfiguration = background
      }
      cell.configure(
        title: contentTitle(for: row, index: indexPath.row),
        subtitle: contentSubtitle(for: row),
        urlString: row.mediaUrl,
        isVideo: row.type == "video",
        titleColor: currentTextColor,
        subtitleColor: currentSecondaryTextColor,
        placeholderTintColor: currentTextColor.withAlphaComponent(0.72),
        placeholderBackgroundColor: currentRowCardColor
      )
      return cell
    }

    guard
      let cell = tableView.dequeueReusableCell(
        withIdentifier: ChatProfileListRowCell.reuseIdentifier,
        for: indexPath
      ) as? ChatProfileListRowCell
    else {
      return UITableViewCell(style: .default, reuseIdentifier: nil)
    }

    let isLast = indexPath.row == currentContentCount() - 1
    configureListRowCell(
      cell,
      title: contentTitle(for: row, index: indexPath.row),
      subtitle: contentSubtitle(for: row),
      iconName: sharedIconName(for: activeTab),
      showsSeparator: !isLast,
      showsChevron: activeTab != .pinned
    )
    return cell
  }

  private func profileInfoRowCount() -> Int {
    let hasUsername = !resolvedIdentifierRawValue().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasNote = !profileBio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return (hasUsername ? 1 : 0) + (hasNote ? 1 : 0)
  }

  private func profileInfoModel(at row: Int) -> (title: String, subtitle: String, image: String?, copyable: Bool)? {
    var models: [(String, String, String?, Bool)] = []
    let username = resolvedIdentifierRawValue().trimmingCharacters(in: .whitespacesAndNewlines)
    if !username.isEmpty {
      models.append(("username", username, "doc.on.doc", true))
    }
    let note = profileBio.trimmingCharacters(in: .whitespacesAndNewlines)
    if !note.isEmpty {
      models.append(("note", note, nil, false))
    }
    guard models.indices.contains(row) else { return nil }
    let item = models[row]
    return (item.0, item.1, item.2, item.3)
  }

  private func latestChatHistorySubtitle() -> String {
    guard let latest = rows.compactMap({ $0.timestampMs }).max(), latest > 0 else {
      let count = rows.count
      return count == 1 ? "1 message" : "\(count) messages"
    }

    let date = Date(timeIntervalSince1970: TimeInterval(latest) / 1000.0)
    let formatter = DateFormatter()
    formatter.doesRelativeDateFormatting = true
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    let count = rows.count == 1 ? "1 message" : "\(rows.count) messages"
    return "\(count) • \(formatter.string(from: date))"
  }

  private func configureGroupedCell(
    _ cell: UITableViewCell,
    title: String,
    subtitle: String = "",
    image: String? = nil,
    showsChevron: Bool = false,
    isLast: Bool
  ) {
    cell.selectionStyle = showsChevron || image != nil ? .default : .none
    cell.backgroundColor = .clear
    cell.contentView.backgroundColor = .clear
    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
    cell.contentConfiguration = UIHostingConfiguration {
      ChatProfileGroupedRowView(
        title: title,
        subtitle: subtitle,
        systemImage: image,
        showsChevron: showsChevron,
        titleColor: currentTextColor,
        subtitleColor: currentSecondaryTextColor,
        separatorColor: currentRowSeparatorColor,
        isLast: isLast
      )
    }
    .background(.ultraThinMaterial)
    .margins(.all, 0)
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard let section = Section(rawValue: indexPath.section) else {
      return UITableViewCell(style: .default, reuseIdentifier: nil)
    }

    switch section {
    case .profileInfo:
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      let count = profileInfoRowCount()
      if let model = profileInfoModel(at: indexPath.row) {
        configureGroupedCell(
          cell,
          title: model.title,
          subtitle: model.subtitle,
          image: model.image,
          showsChevron: false,
          isLast: indexPath.row == count - 1
        )
      }
      return cell

    case .chatHistory:
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      configureGroupedCell(
        cell,
        title: "Chat History",
        subtitle: latestChatHistorySubtitle(),
        image: nil,
        showsChevron: true,
        isLast: true
      )
      return cell

    case .sharedContent:
      guard availableTabs.indices.contains(indexPath.row) else {
        return UITableViewCell(style: .default, reuseIdentifier: nil)
      }
      let tab = availableTabs[indexPath.row]
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      configureGroupedCell(
        cell,
        title: sharedTitle(for: tab),
        subtitle: sharedSubtitle(for: tab),
        image: nil,
        showsChevron: true,
        isLast: indexPath.row == availableTabs.count - 1
      )
      return cell

    case .contactActions:
      let titles = ["Share Contact", "Create New Contact", "Add to Existing Contact"]
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      cell.textLabel?.text = titles[indexPath.row]
      cell.textLabel?.font = UIFont.systemFont(ofSize: 17, weight: .regular)
      cell.textLabel?.textColor = .systemBlue
      cell.backgroundColor = .secondarySystemGroupedBackground
      return cell

    case .emergency:
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      cell.textLabel?.text = "Add to Emergency Contacts"
      cell.textLabel?.font = UIFont.systemFont(ofSize: 17, weight: .regular)
      cell.textLabel?.textColor = .systemBlue
      cell.backgroundColor = .secondarySystemGroupedBackground
      return cell

    case .dangerActions:
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      cell.textLabel?.text = "Block Contact"
      cell.textLabel?.font = UIFont.systemFont(ofSize: 17, weight: .regular)
      cell.textLabel?.textColor = .systemRed
      cell.backgroundColor = .secondarySystemGroupedBackground
      return cell
    }
  }

  func tableView(
    _ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath
  ) {
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    defer { tableView.deselectRow(at: indexPath, animated: true) }

    guard let section = Section(rawValue: indexPath.section) else { return }

    switch section {
    case .profileInfo:
      guard let model = profileInfoModel(at: indexPath.row), model.copyable else { return }
      UIPasteboard.general.string = model.subtitle
      onNativeEvent(["type": "profileIdPressed", "id": model.subtitle])

    case .chatHistory:
      guard !availableTabs.isEmpty else {
        onNativeEvent(["type": "profileChatHistoryPressed", "chatId": engineChatId])
        return
      }
      let tab = activeTab
      let isDark = traitCollection.userInterfaceStyle == .dark
      var targetRows: [Any] = []
      switch tab {
      case .media: targetRows = mediaRows
      case .voice: targetRows = voiceRows
      case .gifs: targetRows = gifRows
      case .files: targetRows = fileRows
      case .links: targetRows = linkRows
      case .pinned: targetRows = pinnedRows
      }
      guard let sourceCell = tableView.cellForRow(at: indexPath) else { return }
      let controller = ChatProfileExpandedContentViewController(
        profileTab: tab,
        titleText: "Chat History",
        rows: targetRows,
        themeIsDark: isDark,
        sourceView: sourceCell,
        hostView: self
      )
      controller.onContentPressed = { [weak self] payload in
        self?.onNativeEvent(payload)
      }
      topMostViewController()?.present(controller, animated: false)

    case .sharedContent:
      guard availableTabs.indices.contains(indexPath.row) else { return }
      let tab = availableTabs[indexPath.row]
      let isDark = traitCollection.userInterfaceStyle == .dark
      var targetRows: [Any] = []
      switch tab {
      case .media: targetRows = mediaRows
      case .voice: targetRows = voiceRows
      case .gifs: targetRows = gifRows
      case .files: targetRows = fileRows
      case .links: targetRows = linkRows
      case .pinned: targetRows = pinnedRows
      }

      guard let sourceCell = tableView.cellForRow(at: indexPath) else { return }
      let controller = ChatProfileExpandedContentViewController(
        profileTab: tab,
        titleText: sharedTitle(for: tab),
        rows: targetRows,
        themeIsDark: isDark,
        sourceView: sourceCell,
        hostView: self
      )
      controller.onContentPressed = { [weak self] payload in
        self?.onNativeEvent(payload)
      }

      if let presenter = topMostViewController() {
        presenter.present(controller, animated: false)
      }

    case .contactActions:
      let actions = ["shareContact", "createNewContact", "addToExisting"]
      if actions.indices.contains(indexPath.row) {
        onNativeEvent(["type": "profileContactAction", "action": actions[indexPath.row]])
      }

    case .emergency:
      onNativeEvent(["type": "profileContactAction", "action": "addToEmergency"])

    case .dangerActions:
      onNativeEvent(["type": "profileContactAction", "action": "block"])
    }
  }

  private func handleMediaGridTapped(at index: Int) {
    guard activeTab == .media, index >= 0, index < mediaRows.count else { return }
    let row = mediaRows[index]

    if row.type == "video", let mediaUrl = row.mediaUrl, !mediaUrl.isEmpty {
      let resolvedUrlStr = ChatEngine.shared.resolveURLForOpen(mediaUrl) ?? mediaUrl
      guard let url = URL(string: resolvedUrlStr) else { return }

      var options: [String: Any]? = nil
      if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https",
         let authHeader = ChatEngine.shared.authorizationHeaderForAPI() {
        options = ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": authHeader]]
      }

      let asset = AVURLAsset(url: url, options: options)
      let controller = ChatVideoEditViewController(
        asset: asset,
        initialCaption: row.text,
        headerTitle: "Video",
        previewOnly: true
      )

      if let presenter = topMostViewController() {
        presenter.present(controller, animated: true)
      }
      return
    }

    onNativeEvent([
      "type": "profileContentPressed",
      "tab": activeTab.rawValue,
      "messageId": row.messageId,
      "url": row.mediaUrl ?? ""
    ])
  }

  // MARK: Agent Config

  private func fetchAgentConfigForCurrentChat() {
    let currentId = engineChatId
    guard !currentId.isEmpty else { return }
    ChatEngine.shared.fetchAgentConfig(chatId: currentId) { [weak self] config in
      guard let self, self.engineChatId == currentId else { return }
      self.agentConfig = self.normalizedAgentConfig(config, fallbackChatId: currentId)
      self.tableView.reloadData()
    }
  }

  private func presentAgentConfigEditor() {
    guard isGroupOrChannel else {
      onNativeEvent(["type": "headerAgentPressed"])
      return
    }

    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return }

    let controller = ChatAgentConfigViewController()
    controller.chatId = chatId
    controller.agentConfig = agentConfig
    controller.documents = getAgentDocuments()
    controller.onSave = { [weak self] config in
      guard let self else { return }
      let normalized = self.normalizedAgentConfig(config, fallbackChatId: chatId) ?? config
      ChatEngine.shared.saveAgentConfig(chatId: chatId, config: normalized) { [weak self] success in
        guard let self else { return }
        if success {
          self.agentConfig = normalized
          self.tableView.reloadData()
        }
      }
    }

    controller.onDelete = { [weak self] in
      guard let self else { return }
      ChatEngine.shared.deleteAgentConfig(chatId: chatId) { [weak self] success in
        guard let self else { return }
        if success {
          self.agentConfig = nil
          self.tableView.reloadData()
        }
      }
    }

    if let presenter = topMostViewController() {
      if let nav = presenter.navigationController {
        nav.pushViewController(controller, animated: true)
      } else {
        let navigation = UINavigationController(rootViewController: controller)
        presenter.present(navigation, animated: true)
      }
    }

    onNativeEvent(["type": "headerAgentPressed"])
  }

  // MARK: Bridge (Claude/Codex) connection + history

  private func presentBridgeConnection() {
    guard !bridgeProvider.isEmpty, let presenter = topMostViewController() else { return }
    AgentBridgeProfile.presentConnection(provider: bridgeProvider, from: presenter)
    // Re-check status when the user returns from the sheet so the card reflects
    // any connect/disconnect they just performed.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      self?.refreshBridgeStatus()
    }
  }

  private func normalizedAgentConfig(_ config: [String: Any]?, fallbackChatId: String)
    -> [String: Any]?
  {
    guard let config else { return nil }
    var normalized: [String: Any] = [:]

    let resolvedChatId =
      normalizedAgentString(config["chat_id"]) ?? normalizedAgentString(config["chatId"])
      ?? fallbackChatId
    normalized["chat_id"] = resolvedChatId

    normalized["name"] = normalizedAgentString(config["name"]) ?? "Vibe AI"

    let resolvedPrompt =
      normalizedAgentString(config["system_prompt"]) ?? normalizedAgentString(
        config["systemPrompt"])
      ?? ""
    normalized["system_prompt"] = resolvedPrompt

    normalized["enabled"] = normalizedAgentEnabledValue(config["enabled"], defaultValue: true)

    if let enabledTools = normalizedAgentToolList(config["enabled_tools"])
      ?? normalizedAgentToolList(config["enabledTools"]),
      !enabledTools.isEmpty
    {
      normalized["enabled_tools"] = enabledTools
    }

    if let id = normalizedAgentString(config["id"]), !id.isEmpty {
      normalized["id"] = id
    }

    if let avatar = normalizedAgentString(config["avatar_url"])
      ?? normalizedAgentString(config["avatarUrl"])
    {
      normalized["avatar_url"] = avatar
    }

    if let createdBy = normalizedAgentString(config["created_by"])
      ?? normalizedAgentString(config["createdBy"])
    {
      normalized["created_by"] = createdBy
    }

    return normalized
  }

  private func normalizedAgentString(_ rawValue: Any?) -> String? {
    if let string = rawValue as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let number = rawValue as? NSNumber {
      return number.stringValue
    }
    return nil
  }

  private func normalizedAgentEnabledValue(_ rawValue: Any?, defaultValue: Bool) -> Bool {
    guard let rawValue else { return defaultValue }
    if let boolValue = rawValue as? Bool { return boolValue }
    if let numberValue = rawValue as? NSNumber { return numberValue.boolValue }
    if let stringValue = rawValue as? String {
      switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
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

  private func normalizedAgentToolList(_ rawValue: Any?) -> [String]? {
    guard let rawArray = rawValue as? [Any] else { return nil }
    let normalized =
      rawArray
      .compactMap { value -> String? in
        if let text = value as? String {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
          return number.stringValue
        }
        return nil
      }
    return normalized.isEmpty ? nil : normalized
  }

  // MARK: Formatting

  private func formattedRowDate(_ row: ChatProfileRow) -> String? {
    guard let timestampMs = row.timestampMs, timestampMs > 0 else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    return Self.listDateFormatter.string(from: date)
  }

  private func formattedFileSize(_ bytes: Int64?) -> String? {
    guard let bytes, bytes > 0 else { return nil }
    if bytes < 1024 {
      return "\(bytes) B"
    }
    if bytes < 1024 * 1024 {
      return String(format: "%.1f KB", Double(bytes) / 1024.0)
    }
    return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
  }

  private func topMostViewController() -> UIViewController? {
    let root = window?.rootViewController
    var current = root
    while let presented = current?.presentedViewController {
      current = presented
    }
    return current
  }
}
fileprivate class ChatProfileExpandedContentViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

  let profileTab: ChatProfileTab
  let titleText: String
  let rows: [Any]
  let themeIsDark: Bool
  var onContentPressed: (([String: Any]) -> Void)?

  private let tableView = UITableView(frame: .zero, style: .plain)
  private let headerBlur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let headerOverlay = UIView()
  private let titleLabel = UILabel()
  private let closeButton = UIButton(type: .system)

  init(profileTab: ChatProfileTab, titleText: String, rows: [Any], themeIsDark: Bool, sourceView: UIView, hostView: UIView) {
    self.profileTab = profileTab
    self.titleText = titleText
    self.rows = rows
    self.themeIsDark = themeIsDark
    super.init(nibName: nil, bundle: nil)
    self.modalPresentationStyle = .overFullScreen
    _ = sourceView
    _ = hostView
  }

  required init?(coder: NSCoder) {
    fatalError()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = themeIsDark
      ? UIColor(red: 7.0/255.0, green: 10.0/255.0, blue: 15.0/255.0, alpha: 1.0)
      : UIColor(red: 235.0/255.0, green: 240.0/255.0, blue: 243.0/255.0, alpha: 1.0)

    tableView.dataSource = self
    tableView.delegate = self
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.contentInset = UIEdgeInsets(top: 92, left: 0, bottom: 24, right: 0)

    tableView.register(ChatProfileVoiceContentCell.self, forCellReuseIdentifier: ChatProfileVoiceContentCell.reuseIdentifier)
    tableView.register(ChatProfileMediaGridRowCell.self, forCellReuseIdentifier: ChatProfileMediaGridRowCell.reuseIdentifier)
    tableView.register(ChatProfileMediaContentCell.self, forCellReuseIdentifier: ChatProfileMediaContentCell.reuseIdentifier)
    tableView.register(ChatProfileListRowCell.self, forCellReuseIdentifier: ChatProfileListRowCell.reuseIdentifier)

    view.addSubview(tableView)

    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: .regular)
      effect.isInteractive = true
      headerBlur.effect = effect
    } else {
      headerBlur.effect = UIBlurEffect(style: themeIsDark ? .systemMaterialDark : .systemMaterialLight)
    }
    view.addSubview(headerBlur)
    headerOverlay.isUserInteractionEnabled = false
    headerOverlay.backgroundColor =
      (themeIsDark ? UIColor.black : UIColor.white).withAlphaComponent(themeIsDark ? 0.18 : 0.16)
    headerBlur.contentView.addSubview(headerOverlay)

    titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    titleLabel.textColor = themeIsDark ? .white : .black
    titleLabel.text = titleText
    headerBlur.contentView.addSubview(titleLabel)

    closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    closeButton.tintColor = themeIsDark ? .lightGray : .darkGray
    closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    headerBlur.contentView.addSubview(closeButton)
  }

  @objc private func handleClose() {
    dismiss(animated: true)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    tableView.frame = view.bounds
    let headerHeight = view.safeAreaInsets.top + 64.0
    headerBlur.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: headerHeight)
    headerOverlay.frame = headerBlur.bounds
    let topInset = headerHeight + 20.0
    if abs(tableView.contentInset.top - topInset) > 0.5 {
      tableView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 24, right: 0)
      tableView.scrollIndicatorInsets = UIEdgeInsets(top: headerHeight, left: 0, bottom: 0, right: 0)
    }
    titleLabel.sizeToFit()
    titleLabel.center = CGPoint(x: headerBlur.bounds.midX, y: view.safeAreaInsets.top + 30.0)
    closeButton.frame = CGRect(x: headerBlur.bounds.width - 48, y: view.safeAreaInsets.top + 16.0, width: 32, height: 32)
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    if profileTab == .media {
      return Int(ceil(Double(rows.count) / 3.0))
    }
    return rows.count
  }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    if profileTab == .media {
      let cols: CGFloat = 3.0
      let padding: CGFloat = 16.0
      let gap: CGFloat = 2.0
      let avail = max(0.0, tableView.bounds.width - padding * 2.0 - gap * (cols - 1))
      let itemHeight = floor(avail / cols)
      return itemHeight + gap
    } else if profileTab == .voice || profileTab == .gifs {
      return 72.0
    }
    return 68.0
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    if profileTab == .media {
      guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatProfileMediaGridRowCell.reuseIdentifier, for: indexPath) as? ChatProfileMediaGridRowCell else { return UITableViewCell() }
      var items: [(url: String?, isVideo: Bool, thumbnailBase64: String?)] = []
      let startIndex = indexPath.row * 3
      for i in 0..<3 {
        let absIndex = startIndex + i
        if absIndex < rows.count, let r = rows[absIndex] as? ChatProfileRow {
          items.append((url: r.mediaUrl, isVideo: r.type == "video", thumbnailBase64: r.thumbnailBase64))
        }
      }
      cell.configure(items: items, startIndex: startIndex, placeholderTintColor: .gray, placeholderBackgroundColor: .darkGray)
      cell.onMediaTapped = { [weak self] index in
        guard let self = self, index < self.rows.count, let r = self.rows[index] as? ChatProfileRow else { return }
        self.onContentPressed?(["type": "profileContentPressed", "tab": self.profileTab.rawValue, "messageId": r.messageId, "url": r.mediaUrl ?? ""])
      }
      return cell
    }

    let rowObj = rows[indexPath.row]
    var r: ChatProfileRow? = rowObj as? ChatProfileRow
    if profileTab == .links, let linkItem = rowObj as? ChatProfileLinkItem { r = linkItem.row }
    guard let row = r else { return UITableViewCell() }

    if profileTab == .voice {
      guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatProfileVoiceContentCell.reuseIdentifier, for: indexPath) as? ChatProfileVoiceContentCell else { return UITableViewCell() }
      cell.configure(title: row.fileName ?? "Voice message", subtitle: "Voice", row: row, titleColor: themeIsDark ? .white : .black, subtitleColor: .gray, accentColor: .systemBlue)
      VoiceBubblePlaybackCoordinator.shared.bind(cell: cell, messageId: row.messageId, mediaURL: row.mediaUrl, mediaKey: row.mediaKey, fileName: row.fileName)
      return cell
    }

    guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatProfileListRowCell.reuseIdentifier, for: indexPath) as? ChatProfileListRowCell else { return UITableViewCell() }
    let title: String
    let subtitle: String
    let iconName: String
    if profileTab == .links, let linkItem = rowObj as? ChatProfileLinkItem {
      title = linkItem.url
      subtitle = "Shared link"
      iconName = "link"
    } else {
      title = row.fileName ?? (row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Item" : row.text)
      subtitle = row.type.capitalized
      iconName = profileTab == .pinned ? "pin.fill" : "doc.text.fill"
    }
    cell.rowNode.isHidden = true
    cell.contentConfiguration = UIHostingConfiguration {
      ChatProfileModernRowView(
        title: title,
        subtitle: subtitle,
        value: "",
        iconName: iconName,
        showsChevron: profileTab != .pinned,
        isDark: themeIsDark,
        titleColor: themeIsDark ? .white : .black,
        subtitleColor: themeIsDark ? UIColor(white: 0.72, alpha: 1.0) : UIColor(white: 0.42, alpha: 1.0),
        accentColor: .systemBlue,
        cardColor: themeIsDark
          ? UIColor(red: 53.0/255.0, green: 62.0/255.0, blue: 72.0/255.0, alpha: 0.30)
          : UIColor.white.withAlphaComponent(0.68),
        separatorColor: themeIsDark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.06)
      )
    }
    .margins(.all, 0)
    cell.backgroundColor = .clear
    cell.contentView.backgroundColor = .clear
    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard profileTab != .media else { return }
    let rowObj = rows[indexPath.row]
    var r: ChatProfileRow? = rowObj as? ChatProfileRow
    if profileTab == .links, let linkItem = rowObj as? ChatProfileLinkItem { r = linkItem.row }
    guard let row = r else { return }

    if profileTab == .voice {
      if let cell = tableView.cellForRow(at: indexPath) as? VoicePlayableCell {
        VoiceBubblePlaybackCoordinator.shared.toggle(cell: cell, messageId: row.messageId, mediaURL: row.mediaUrl, mediaKey: row.mediaKey, fileName: row.fileName)
      }
      return
    }

    var payload: [String: Any] = ["type": "profileContentPressed", "tab": profileTab.rawValue, "messageId": row.messageId]
    if profileTab == .links, let linkItem = rowObj as? ChatProfileLinkItem { payload["url"] = linkItem.url }
    else if let mediaUrl = row.mediaUrl, !mediaUrl.isEmpty { payload["url"] = mediaUrl }

    onContentPressed?(payload)
  }
}
import SwiftUI
import UIKit

struct ChatProfileImageCropper: View {
  let image: UIImage
  let onCrop: (UIImage?) -> Void
  let onCancel: () -> Void

  @State private var scale: CGFloat = 1.0
  @State private var lastScale: CGFloat = 1.0
  @State private var offset: CGSize = .zero
  @State private var lastOffset: CGSize = .zero

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        Color.black.ignoresSafeArea()

        GeometryReader { proxy in
          let side = min(proxy.size.width, proxy.size.height) - 32
          let imageAspect = image.size.width / image.size.height

          let displayWidth = imageAspect > 1 ? side * imageAspect : side
          let displayHeight = imageAspect > 1 ? side : side / imageAspect

          ZStack {
            Image(uiImage: image)
              .resizable()
              .scaledToFit()
              .frame(width: displayWidth, height: displayHeight)
              .scaleEffect(scale)
              .offset(offset)
              .gesture(
                DragGesture()
                  .onChanged { value in
                    offset = CGSize(
                      width: lastOffset.width + value.translation.width,
                      height: lastOffset.height + value.translation.height
                    )
                  }
                  .onEnded { _ in
                    lastOffset = offset
                  }
              )
              .gesture(
                MagnificationGesture()
                  .onChanged { value in
                    scale = max(1.0, lastScale * value)
                  }
                  .onEnded { _ in
                    lastScale = scale
                  }
              )
          }
          .frame(width: side, height: side)
          .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .stroke(Color.white.opacity(0.4), lineWidth: 2)
          )
          .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
      }

      HStack {
        Button("Cancel") {
          onCancel()
        }
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.white)

        Spacer()

        Button("Done") {
          let cropped = renderCroppedImage()
          onCrop(cropped)
        }
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(.white)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 20)
      .background(Color.black)
    }
  }

  @MainActor
  private func renderCroppedImage() -> UIImage? {
    let targetSize = CGSize(width: 800, height: 800)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

    let result = renderer.image { ctx in
      UIColor.black.setFill()
      ctx.fill(CGRect(origin: .zero, size: targetSize))

      let displayAspect = image.size.width / image.size.height
      let drawWidth = displayAspect > 1 ? targetSize.width * displayAspect : targetSize.width
      let drawHeight = displayAspect > 1 ? targetSize.height : targetSize.height / displayAspect

      let centerX = targetSize.width / 2
      let centerY = targetSize.height / 2

      ctx.cgContext.translateBy(x: centerX, y: centerY)
      ctx.cgContext.scaleBy(x: scale, y: scale)

      let cropWindowWidth: CGFloat = UIScreen.main.bounds.width - 32
      let offsetX = (offset.width / cropWindowWidth) * targetSize.width / scale
      let offsetY = (offset.height / cropWindowWidth) * targetSize.height / scale

      ctx.cgContext.translateBy(x: offsetX, y: offsetY)

      let rect = CGRect(
        x: -drawWidth / 2,
        y: -drawHeight / 2,
        width: drawWidth,
        height: drawHeight
      )

      image.draw(in: rect)
    }

    return result
  }
}
