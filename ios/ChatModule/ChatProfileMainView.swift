import SwiftUI
import UIKit
import AVFoundation

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

    imageTask = Task { [weak self] in
      let image = await NativeProfileAvatarImageLoader.load(from: normalizedValue)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard let self, self.imageUri == normalizedValue else { return }
        self.loadedImage = image
      }
    }
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
  static let topOffset: CGFloat = 76
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
  let fallbackIconTintColor: UIColor
  let fallbackBackgroundColor: UIColor
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
          Circle()
            .fill(Color(uiColor: fallbackBackgroundColor))

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
          Circle()
            .fill(Color(uiColor: fallbackBackgroundColor))

          Image(systemName: "person.fill")
            .resizable()
            .scaledToFit()
            .frame(width: max(14.0, size * 0.34), height: max(14.0, size * 0.34))
            .foregroundStyle(Color(uiColor: fallbackIconTintColor))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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
      fallbackIconTintColor: model.fallbackIconTintColor,
      fallbackBackgroundColor: model.fallbackBackgroundColor,
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
    publishModelChange { $0.fallbackBackgroundColor = value }
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
        .overlay(Color(uiColor: cardColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(Color(uiColor: separatorColor).opacity(isDark ? 0.92 : 0.65), lineWidth: 1)
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
  case tab(ChatProfileTab)

  var transitionID: String {
    switch self {
    case .history:
      return "chat-history"
    case .bridgeHistory:
      return "bridge-history"
    case .tab(let tab):
      return "shared-\(tab.rawValue)"
    }
  }
}

private struct ChatProfileScrollOffsetPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
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
  // Bridge (Claude/Codex paired-computer) state. `bridgeProvider` is empty for a
  // normal contact/group profile.
  var bridgeProvider: String = ""
  var bridgeChatId: String = ""
  var bridgeConnected: Bool = false
  var bridgePaired: Bool = false
  var bridgeDeviceLabel: String = ""
  let onScroll: (CGFloat) -> Void
  let onNavigationActiveChanged: (Bool) -> Void
  let onCopyUsername: () -> Void
  let onAction: (String) -> Void
  let onContentPressed: ([String: Any]) -> Void

  @Namespace private var morphNamespace
  @State private var path: [ChatProfileSwiftUIDestination] = []

  private var rowFill: Color {
    Color.clear
  }

  private var separatorColor: Color {
    Color(uiColor: isDark ? UIColor.white.withAlphaComponent(0.10) : UIColor.black.withAlphaComponent(0.08))
  }

  var body: some View {
    GeometryReader { geometry in
      NavigationStack(path: $path) {
        ZStack {
          Color.clear.ignoresSafeArea()

          ScrollView(.vertical, showsIndicators: true) {
            offsetReader

            VStack(spacing: 18) {
              Color.clear
                .frame(height: heroClearance(safeTop: geometry.safeAreaInsets.top))

              VStack(spacing: 20) {
                Text(profileName)
                  .font(.system(size: 34, weight: .bold))
                  .foregroundStyle(.primary)
                  .lineLimit(1)
                  .minimumScaleFactor(0.72)
                  .frame(maxWidth: .infinity)

                actionRow
              }
              .padding(.horizontal, 28)

              profileInfoSection
              if bridgeProvider.isEmpty {
                historySection
              } else {
                bridgeHistorySection
              }
              sharedContentSection
              contactActionsSection
              emergencySection
              dangerSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 38)
          }
          .coordinateSpace(name: "profile-scroll")
          .scrollIndicators(.visible)
          .background(Color.clear)
        }
        .background(Color.clear)
        .toolbar(path.isEmpty ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(for: ChatProfileSwiftUIDestination.self) { destination in
          destinationView(for: destination)
            .navigationTransition(.zoom(sourceID: destination.transitionID, in: morphNamespace))
        }
      }
      .background(Color.clear)
      .tint(.primary)
      .onChange(of: path.isEmpty) { _, isEmpty in
        onNavigationActiveChanged(!isEmpty)
      }
    }
  }

  private var offsetReader: some View {
    GeometryReader { proxy in
      Color.clear
        .preference(
          key: ChatProfileScrollOffsetPreferenceKey.self,
          value: max(0, -proxy.frame(in: .named("profile-scroll")).minY)
        )
    }
    .frame(height: 0)
    .onPreferenceChange(ChatProfileScrollOffsetPreferenceKey.self) { value in
      onScroll(value)
    }
  }

  private func heroClearance(safeTop: CGFloat) -> CGFloat {
    NativeProfileAvatarHeroMetrics.expandedTop(for: safeTop)
      + NativeProfileAvatarHeroMetrics.expandedSize
      + 28
  }

  private var actionRow: some View {
    HStack(spacing: 18) {
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
          .foregroundStyle(.primary)
          .lineLimit(1)
        HStack(spacing: 6) {
          if bridgeConnected {
            Circle().fill(Color.green).frame(width: 8, height: 8)
          }
          Text(bridgeComputerSubtitle)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.secondary)
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
    if bridgeConnected {
      return bridgeDeviceLabel.isEmpty ? "Connected" : "\(bridgeDeviceLabel) · Connected"
    }
    if bridgePaired {
      return "Paired · offline — tap to reconnect"
    }
    return "Not connected — tap to connect"
  }

  private var historySection: some View {
    ChatProfileSwiftUISection(fill: rowFill) {
      Button {
        path.append(.history)
      } label: {
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
      Button {
        path.append(.bridgeHistory)
      } label: {
        ChatProfileSwiftUIRow(
          title: "Chat History",
          subtitle: "\(bridgeDisplayName) conversations on your computer",
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

  @ViewBuilder
  private var sharedContentSection: some View {
    if !tabSummaries.isEmpty {
      ChatProfileSwiftUISection(fill: rowFill) {
        ForEach(Array(tabSummaries.enumerated()), id: \.element.id) { index, summary in
          let destination = ChatProfileSwiftUIDestination.tab(summary.tab)
          Button {
            path.append(destination)
          } label: {
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

  private var dangerSection: some View {
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
        onOpenSession: { session in
          // Tapping a past session loads its whole transcript into the DEFAULT
          // chat as bubbles (user prompt -> right bubble, agent reply -> agent
          // cell) and leaves the profile — it is no longer rendered in-profile.
          _ = ChatEngine.shared.loadAgentBridgeSessionIntoChat([
            "chatId": bridgeChatId,
            "provider": bridgeProvider,
            "sessionId": session.id,
          ])
          onContentPressed([
            "type": "openBridgeSessionInChat",
            "chatId": bridgeChatId,
            "provider": bridgeProvider,
            "sessionId": session.id,
            "topic": session.topic,
          ])
          // Reuse the proven back path so we land back on the chat.
          onAction("headerBack")
        }
      )
      .background(Color(uiColor: UIColor.systemGroupedBackground))
    case .tab(let tab):
      ChatProfileSwiftUIExpandedContentView(
        title: tabSummaries.first(where: { $0.tab == tab })?.title ?? tab.label,
        items: tabItems[tab] ?? [],
        fill: rowFill,
        separatorColor: separatorColor,
        onContentPressed: onContentPressed
      )
    }
  }
}

private struct ChatProfileSwiftUISection<Content: View>: View {
  let fill: Color
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      content
    }
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(fill)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    )
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
    )
  }
}

private struct ChatProfileSwiftUIRow: View {
  let title: String
  var subtitle: String = ""
  var trailingSystemImage: String?
  var showsChevron: Bool = false
  var titleColor: Color = .primary
  let separatorColor: Color
  let isLast: Bool

  var body: some View {
    HStack(spacing: 14) {
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
  let title: String
  let systemImage: String
  let fill: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 7) {
        Image(systemName: systemImage)
          .font(.system(size: 22, weight: .semibold))
          .frame(width: 52, height: 52)
          .background(
            Circle()
              .fill(fill)
              .background(.regularMaterial, in: Circle())
          )

        Text(title)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      .foregroundStyle(.primary)
      .frame(maxWidth: .infinity)
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

    chromeView.translatesAutoresizingMaskIntoConstraints = false
    chromeView.clipsToBounds = true
    chromeView.layer.cornerCurve = .continuous
    addSubview(chromeView)

    chromeOverlayView.translatesAutoresizingMaskIntoConstraints = false
    chromeOverlayView.isUserInteractionEnabled = false
    chromeView.contentView.addSubview(chromeOverlayView)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = .clear
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceHorizontal = false
    scrollView.delaysContentTouches = false
    scrollView.canCancelContentTouches = true
    chromeView.contentView.addSubview(scrollView)

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

      chromeOverlayView.leadingAnchor.constraint(equalTo: chromeView.contentView.leadingAnchor),
      chromeOverlayView.trailingAnchor.constraint(equalTo: chromeView.contentView.trailingAnchor),
      chromeOverlayView.topAnchor.constraint(equalTo: chromeView.contentView.topAnchor),
      chromeOverlayView.bottomAnchor.constraint(equalTo: chromeView.contentView.bottomAnchor),

      scrollView.leadingAnchor.constraint(equalTo: chromeView.contentView.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: chromeView.contentView.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: chromeView.contentView.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: chromeView.contentView.bottomAnchor),

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
    let blurStyle: UIBlurEffect.Style =
      isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight

    let primary = isDark ? UIColor(white: 0.95, alpha: 0.96) : UIColor(white: 0.12, alpha: 0.96)
    let secondary = isDark ? UIColor(white: 0.84, alpha: 0.62) : UIColor(white: 0.12, alpha: 0.42)
    chromeView.effect = UIBlurEffect(style: blurStyle)
    chromeOverlayView.backgroundColor =
      (isDark ? UIColor.black : UIColor.white).withAlphaComponent(isDark ? 0.10 : 0.08)
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
  private var enginePeerUserId = ""
  private var agentConfig: [String: Any]?
  // Non-empty ("claude"/"codex") when this profile is a paired-computer bridge
  // agent. Drives the "Computer" connection card + the agent-history browser.
  private var bridgeProvider = ""
  private var bridgeConnected = false
  private var bridgePaired = false
  private var bridgeDeviceLabel = ""
  private var bridgeStatusTask: Task<Void, Never>?
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

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    updateAvatarMetrics()
    setNeedsLayout()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    attachSwiftUIHostIfNeeded()
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

    layoutFloatingAvatarView()
    updateAvatarMorphProgress()
    layoutAvatarGlassRing()
    swiftUIContainerView.isHidden = false
    floatingAvatarView.isHidden = swiftUINavigationActive
    avatarGlassRing.isHidden = true
    headerContainer.isHidden = swiftUINavigationActive
    headerMaskContainer.isHidden = true
    bringSubviewToFront(swiftUIContainerView)
    bringSubviewToFront(headerContainer)

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

  func setEngineChatId(_ value: String) {
    engineChatId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    fetchAgentConfigForCurrentChat()
  }

  func setEngineMyUserId(_ value: String) {
    _ = value
  }

  func setEnginePeerUserId(_ value: String) {
    enginePeerUserId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    tableView.reloadData()
    refreshAvatar()
    renderSwiftUIProfile()
  }

  func setStatusAuthorityEnabled(_ enabled: Bool) {
    _ = enabled
  }

  func setAppearance(_ rawAppearance: [String: Any]) {
    let isDarkValue =
      (rawAppearance["isDark"] as? Bool)
      ?? (rawAppearance["nativeThemeIsDark"] as? Bool)

    if let isDarkValue {
      overrideUserInterfaceStyle = isDarkValue ? .dark : .light
    }

    applyTheme()
    tableView.reloadData()
    layoutHeroHeaderViewIfNeeded(force: true)
    renderSwiftUIProfile()
  }

  func setHeaderTitle(_ value: String) {
    headerTitle = value.trimmingCharacters(in: .whitespacesAndNewlines)
    reloadHeaderText()
    refreshHeroContent()
  }

  func setHeaderSubtitle(_ value: String) {
    headerSubtitle = value.trimmingCharacters(in: .whitespacesAndNewlines)
    reloadHeaderText()
  }

  func setProfileName(_ value: String) {
    profileName = value.trimmingCharacters(in: .whitespacesAndNewlines)
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
    guard !bridgeProvider.isEmpty else { return }
    bridgeStatusTask?.cancel()
    bridgeStatusTask = Task { [weak self] in
      guard let config = AppSessionConfig.current else { return }
      let status = try? await AgentPairingService.status(config: config)
      guard let status, !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self else { return }
        self.bridgeConnected = status.connected
        self.bridgePaired = status.paired
        self.bridgeDeviceLabel = status.devices.first?.label ?? ""
        self.renderSwiftUIProfile()
      }
    }
  }

  func setProfileBio(_ value: String) {
    profileBio = value.trimmingCharacters(in: .whitespacesAndNewlines)
    refreshHeroContent()
    tableView.reloadData()
  }

  func setAvatarUri(_ value: String?) {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard avatarUri != normalized else { return }
    avatarUri = normalized
    refreshAvatar()
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
  }

  func setGroupMembers(_ members: [[String: Any]]) {
    groupMembers = members
    tableView.reloadData()
  }

  func setGroupMemberCount(_ value: Int?) {
    groupMemberCount = value
    tableView.reloadData()
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

    // Avatar glass ring
    avatarGlassRing.clipsToBounds = true
    avatarGlassRing.isUserInteractionEnabled = false
    avatarGlassRing.isHidden = false
    avatarGlassRing.alpha = 1.0

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
    swiftUIContainerView.clipsToBounds = true
    swiftUIContainerView.layer.zPosition = 30.0
    addSubview(swiftUIContainerView)
    
    swiftUIContainerView.insertSubview(avatarGlassRing, at: 0)
    swiftUIContainerView.insertSubview(floatingAvatarView, at: 1)

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
      bridgeProvider: bridgeProvider,
      bridgeChatId: engineChatId,
      bridgeConnected: bridgeConnected,
      bridgePaired: bridgePaired,
      bridgeDeviceLabel: bridgeDeviceLabel,
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
      onContentPressed: { [weak self] payload in
        self?.onNativeEvent(payload)
      }
    )
    let erasedRoot = AnyView(rootView)

    if let host = swiftUIHostingController {
      host.rootView = erasedRoot
      host.view.frame = swiftUIContainerView.bounds
    } else {
      let host = UIHostingController(rootView: erasedRoot)
      if #available(iOS 14.0, *) {
        host.safeAreaRegions = []
      }
      host.view.backgroundColor = .clear
      host.view.isOpaque = false
      host.view.frame = swiftUIContainerView.bounds
      swiftUIContainerView.addSubview(host.view)
      swiftUIHostingController = host
      attachSwiftUIHostIfNeeded()
    }
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
    case "headerBack":
      handleBackPressed()
    case "shareContact", "createNewContact", "addToExisting":
      onNativeEvent(["type": "profileContactAction", "action": action])
    case "addToEmergency":
      onNativeEvent(["type": "profileContactAction", "action": "addToEmergency"])
    case "block":
      onNativeEvent(["type": "profileContactAction", "action": "block"])
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
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 68.0),
        button.heightAnchor.constraint(equalToConstant: 70.0),
      ])
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
    
    let isActive = swiftUINavigationActive
    avatarGlassRing.isHidden = isActive
    avatarGlassRing.alpha = isActive ? 0.0 : 1.0
  }

  private func layoutActionsForCurrentScroll() {
    layoutHeroHeaderViewIfNeeded(force: false)
  }

  private func applyTheme() {
    let isDark = traitCollection.userInterfaceStyle == .dark

    // Subtle graphite/ink field. Keep it quiet so the material rows carry the profile.
    if isDark {
      backgroundGradientLayer.colors = [
        UIColor(red: 19.0/255.0, green: 25.0/255.0, blue: 30.0/255.0, alpha: 1.0).cgColor,
        UIColor(red: 12.0/255.0, green: 16.0/255.0, blue: 22.0/255.0, alpha: 1.0).cgColor,
        UIColor(red: 6.0/255.0, green: 8.0/255.0, blue: 13.0/255.0, alpha: 1.0).cgColor,
      ]
      backgroundGradientLayer.locations = [0.0, 0.52, 1.0]
    } else {
      backgroundGradientLayer.colors = [
        UIColor(red: 242.0/255.0, green: 245.0/255.0, blue: 246.0/255.0, alpha: 1.0).cgColor,
        UIColor(red: 234.0/255.0, green: 239.0/255.0, blue: 241.0/255.0, alpha: 1.0).cgColor,
        UIColor(red: 226.0/255.0, green: 231.0/255.0, blue: 235.0/255.0, alpha: 1.0).cgColor,
      ]
      backgroundGradientLayer.locations = [0.0, 0.54, 1.0]
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
    let fallbackAvatarBackground =
      isDark
      ? UIColor(red: 248 / 255, green: 246 / 255, blue: 252 / 255, alpha: 20 / 255)
      : UIColor(red: 26 / 255, green: 26 / 255, blue: 31 / 255, alpha: 13 / 255)
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
    let gradientBase = isDark
      ? UIColor(red: 19.0/255.0, green: 25.0/255.0, blue: 30.0/255.0, alpha: 1.0)
      : UIColor(red: 242.0/255.0, green: 245.0/255.0, blue: 246.0/255.0, alpha: 1.0)
    floatingAvatarView.setIslandCoverUIColor(gradientBase)
    floatingAvatarView.setFallbackBackgroundUIColor(fallbackAvatarBackground)
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
    let fallbackColors = ChatAvatarFallbackStyle.uiGradient(
      title: profileName.isEmpty ? headerTitle : profileName,
      peerUserId: enginePeerUserId,
      chatId: engineChatId,
      isDark: traitCollection.userInterfaceStyle == .dark,
      isSavedMessages: false
    )
    floatingAvatarView.setFallbackBackgroundUIColor(fallbackColors.0)
    floatingAvatarView.setFallbackIconTintUIColor(.white)

    let rawAvatar = avatarUri
    let peerUserId = enginePeerUserId
    let chatId = engineChatId
    let preferPushAvatar = !isGroupOrChannel
    let hasRawAvatar =
      rawAvatar?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    let hasPeerUser = !peerUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasRawAvatar || (preferPushAvatar && hasPeerUser) else {
      floatingAvatarView.setImageUri(nil)
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
      let candidates = [row.text, row.mediaUrl ?? ""]

      for candidate in candidates {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let nsText = trimmed as NSString
        let matches = detector.matches(
          in: trimmed, options: [], range: NSRange(location: 0, length: nsText.length))
        if let firstURL = matches.first?.url?.absoluteString, !firstURL.isEmpty {
          links.append(ChatProfileLinkItem(row: row, url: firstURL))
          break
        }
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
