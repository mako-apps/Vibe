import Foundation
import UIKit

enum ChatAvatarURLResolver {
  private static let fallbackAPIBaseURL =
    "https://api.vibegram.io"

  static func resolve(
    rawAvatar: String?,
    peerUserId: String? = nil,
    chatId: String? = nil,
    preferPushAvatar: Bool = false
  ) -> String? {
    if chatId == "saved_messages" {
      return nil
    }

    let apiBaseURL = resolvedAPIBaseURL()
    if preferPushAvatar,
      let normalizedPeerUserId = normalizedString(peerUserId),
      let apiBaseURL
    {
      return pushAvatarURL(baseURL: apiBaseURL, userId: normalizedPeerUserId)
    }

    guard let trimmed = normalizedString(rawAvatar) else { return nil }
    if isHTTPURL(trimmed) {
      return trimmed
    }
    if trimmed.hasPrefix("/"), let apiBaseURL {
      return URL(string: trimmed, relativeTo: apiBaseURL)?.absoluteURL.absoluteString
    }
    return nil
  }

  static func resolvedAPIBaseURL() -> URL? {
    let config = ChatEngineStore.shared.getConfig()
    if let explicit = normalizedString(config["apiBaseUrl"] ?? config["baseUrl"]),
      let url = URL(string: explicit)
    {
      return url
    }
    guard let socketURLString = normalizedString(config["socketUrl"] ?? config["url"]),
      var components = URLComponents(string: socketURLString)
    else {
      return URL(string: fallbackAPIBaseURL)
    }
    if components.scheme == "wss" { components.scheme = "https" }
    if components.scheme == "ws" { components.scheme = "http" }
    if components.path.hasSuffix("/socket") {
      components.path = String(components.path.dropLast("/socket".count))
    }
    if components.path.hasSuffix("/websocket") {
      components.path = String(components.path.dropLast("/websocket".count))
    }
    return components.url ?? URL(string: fallbackAPIBaseURL)
  }

  private static func pushAvatarURL(baseURL: URL, userId: String) -> String? {
    guard !userId.isEmpty else { return nil }
    let hasApiSuffix = baseURL.path.lowercased().hasSuffix("/api")
    var url = baseURL
    if !hasApiSuffix {
      url = url.appendingPathComponent("api")
    }
    return url.appendingPathComponent("push")
      .appendingPathComponent("avatar")
      .appendingPathComponent(userId)
      .absoluteString
  }

  private static func isHTTPURL(_ value: String) -> Bool {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "https" || scheme == "http"
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }
}

enum ChatAvatarImageStore {
  private static let imageCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 384
    return cache
  }()
  private static let inFlightCoordinator = ChatAvatarImageLoadCoordinator()

  static func cached(for rawValue: String?) -> UIImage? {
    guard let key = cacheKey(rawValue) else { return nil }
    return imageCache.object(forKey: key as NSString)
  }

  static func cache(_ image: UIImage, for rawValue: String?) {
    guard let key = cacheKey(rawValue) else { return }
    imageCache.setObject(image, forKey: key as NSString)
  }

  static func load(from rawValue: String?) async -> UIImage? {
    guard let key = cacheKey(rawValue) else { return nil }
    if let cached = imageCache.object(forKey: key as NSString) {
      return cached
    }

    let task = await inFlightCoordinator.task(for: key) {
      Task.detached(priority: .utility) {
        await fetchImage(for: key)
      }
    }
    let image = await task.value

    await inFlightCoordinator.finish(key: key)

    if let image {
      imageCache.setObject(image, forKey: key as NSString)
    }
    return image
  }

  private static func fetchImage(for value: String) async -> UIImage? {
    if value.hasPrefix("data:"), let commaIndex = value.firstIndex(of: ",") {
      let base64 = String(value[value.index(after: commaIndex)...])
      guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
        return nil
      }
      return UIImage(data: data)
    }

    if value.hasPrefix("/") {
      return UIImage(contentsOfFile: value)
    }

    if let url = URL(string: value) {
      if url.isFileURL {
        return UIImage(contentsOfFile: url.path)
      }

      if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
        do {
          var request = URLRequest(url: url)
          request.cachePolicy = .returnCacheDataElseLoad
          request.timeoutInterval = 12.0
          request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
          request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
          let (data, response) = try await URLSession.shared.data(for: request)
          if let status = (response as? HTTPURLResponse)?.statusCode,
            !(200...299).contains(status)
          {
            return nil
          }
          return UIImage(data: data)
        } catch {
          return nil
        }
      }
    }

    guard let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) else {
      return nil
    }
    return UIImage(data: data)
  }

  private static func cacheKey(_ rawValue: String?) -> String? {
    let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }
}

private actor ChatAvatarImageLoadCoordinator {
  private var inFlightLoads: [String: Task<UIImage?, Never>] = [:]

  func task(
    for key: String,
    create: () -> Task<UIImage?, Never>
  ) -> Task<UIImage?, Never> {
    if let existing = inFlightLoads[key] {
      return existing
    }
    let task = create()
    inFlightLoads[key] = task
    return task
  }

  func finish(key: String) {
    inFlightLoads.removeValue(forKey: key)
  }
}

enum ChatAvatarFallbackStyle {
  private static let palettes: [(lightStart: String, lightEnd: String, darkStart: String, darkEnd: String)] = [
    ("#5B8DEF", "#3D6BC6", "#6EA2FF", "#355EAA"),
    ("#1FA97A", "#167A60", "#3BC99A", "#126B55"),
    ("#D66A5A", "#AF493F", "#E98574", "#963B33"),
    ("#A06AD8", "#7C4EB2", "#B984EA", "#6E45A0"),
    ("#D59A2E", "#AF741D", "#E6B24A", "#966418"),
    ("#2F9AA8", "#207585", "#4BB6C4", "#1B6575"),
    ("#E05A8A", "#B83E6A", "#F178A4", "#9C345B"),
    ("#6078D6", "#4659AE", "#7A91EA", "#3A4E9C"),
  ]

  static func hexGradient(
    title: String?,
    peerUserId: String?,
    chatId: String?,
    isSavedMessages: Bool
  ) -> (lightStart: String, lightEnd: String, darkStart: String, darkEnd: String)? {
    guard !isSavedMessages else { return nil }
    let seed = stableSeed(title: title, peerUserId: peerUserId, chatId: chatId)
    guard !seed.isEmpty else { return nil }
    return palettes[paletteIndex(for: seed)]
  }

  static func uiGradient(
    title: String?,
    peerUserId: String?,
    chatId: String?,
    isDark: Bool,
    isSavedMessages: Bool = false
  ) -> (UIColor, UIColor) {
    if isSavedMessages {
      return isDark
        ? (
          UIColor(red: 77 / 255, green: 217 / 255, blue: 229 / 255, alpha: 1),
          UIColor(red: 43 / 255, green: 165 / 255, blue: 181 / 255, alpha: 1)
        )
        : (
          UIColor(red: 43 / 255, green: 165 / 255, blue: 181 / 255, alpha: 1),
          UIColor(red: 0 / 255, green: 122 / 255, blue: 124 / 255, alpha: 1)
        )
    }

    let seed = stableSeed(title: title, peerUserId: peerUserId, chatId: chatId)
    let palette = palettes[paletteIndex(for: seed.isEmpty ? "user" : seed)]
    return (
      uiColor(hex: isDark ? palette.darkStart : palette.lightStart),
      uiColor(hex: isDark ? palette.darkEnd : palette.lightEnd)
    )
  }

  static func stableSeed(title: String?, peerUserId: String?, chatId: String?) -> String {
    [peerUserId, title, chatId]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? ""
  }

  private static func paletteIndex(for seed: String) -> Int {
    abs(seed.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % palettes.count
  }

  private static func uiColor(hex raw: String) -> UIColor {
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

struct ChatHomeListRow {
  let chatId: String
  let title: String
  let preview: String
  let timeLabel: String
  let unreadCount: Int
  let markedUnread: Bool
  let muted: Bool
  let pinned: Bool
  let isTyping: Bool
  let isOnline: Bool
  let peerUserId: String?
  let avatarUri: String?
  let avatarFallback: String
  let avatarGradientStartLight: String?
  let avatarGradientEndLight: String?
  let avatarGradientStartDark: String?
  let avatarGradientEndDark: String?
  let isSavedMessages: Bool
  let type: String?
  let isGroup: Bool
  /// True when the chat's friend is an AI agent's shadow user — i.e. this is a
  /// 1:1 "talk to the agent" chat. Mirrors the server's `friendIsAgent` flag.
  let isAgentFriend: Bool
  /// The agent's id when `isAgentFriend` is true. Sent as `peerAgentId` so the
  /// engine routes the message to the agent backend instead of E2E-encrypting
  /// to a human peer. Mirrors the server's `friendAgentId`.
  let peerAgentId: String?
  /// The attached agent's event-inbox mode (`per_event` or `batched_summary`).
  /// In `batched_summary` (inbox) mode the chat view hides event notifications
  /// from the transcript and surfaces them via the Inbox banner. Mirrors the
  /// server's `friendAgentEventInboxMode`.
  let agentEventInboxMode: String?
  let previewRows: [[String: Any]]
  let initialMessages: [[String: Any]]

  var isBuiltInAgentSurface: Bool {
    Self.isBuiltInAgentChatId(chatId)
  }

  static func isBuiltInAgentChatId(_ rawChatId: String) -> Bool {
    switch rawChatId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "vibe", "vibe_agent", "vibeagent", "vibe-ai", "vibe_ai":
      return true
    default:
      return false
    }
  }

  func cachePayload(messageLimit: Int = 5) -> [String: Any] {
    let shouldIncludeMessagePayload = messageLimit > 0
    var payload: [String: Any] = [
      "chatId": chatId,
      "title": title,
      "preview": preview,
      "timeLabel": timeLabel,
      "unreadCount": unreadCount,
      "markedUnread": markedUnread,
      "muted": muted,
      "pinned": pinned,
      "isTyping": isTyping,
      "isOnline": isOnline,
      "avatarFallback": avatarFallback,
      "isSavedMessages": isSavedMessages,
      "isGroup": isGroup,
      "isAgentFriend": isAgentFriend,
      "previewRows": shouldIncludeMessagePayload ? previewRows : [],
      "messages": shouldIncludeMessagePayload ? Array(initialMessages.suffix(messageLimit)) : [],
    ]
    if let peerUserId { payload["peerUserId"] = peerUserId }
    if let peerAgentId { payload["peerAgentId"] = peerAgentId }
    if let agentEventInboxMode { payload["agentEventInboxMode"] = agentEventInboxMode }
    if let avatarUri { payload["avatarUri"] = avatarUri }
    if let avatarGradientStartLight { payload["avatarGradientStartLight"] = avatarGradientStartLight }
    if let avatarGradientEndLight { payload["avatarGradientEndLight"] = avatarGradientEndLight }
    if let avatarGradientStartDark { payload["avatarGradientStartDark"] = avatarGradientStartDark }
    if let avatarGradientEndDark { payload["avatarGradientEndDark"] = avatarGradientEndDark }
    if let type { payload["type"] = type }
    return payload
  }

  func withPresence(isTyping: Bool, isOnline: Bool, preview: String? = nil) -> ChatHomeListRow {
    ChatHomeListRow(
      chatId: chatId,
      title: title,
      preview: preview ?? self.preview,
      timeLabel: timeLabel,
      unreadCount: unreadCount,
      markedUnread: markedUnread,
      muted: muted,
      pinned: pinned,
      isTyping: isTyping,
      isOnline: isOnline,
      peerUserId: peerUserId,
      avatarUri: avatarUri,
      avatarFallback: avatarFallback,
      avatarGradientStartLight: avatarGradientStartLight,
      avatarGradientEndLight: avatarGradientEndLight,
      avatarGradientStartDark: avatarGradientStartDark,
      avatarGradientEndDark: avatarGradientEndDark,
      isSavedMessages: isSavedMessages,
      type: type,
      isGroup: isGroup,
      isAgentFriend: isAgentFriend,
      peerAgentId: peerAgentId,
      agentEventInboxMode: agentEventInboxMode,
      previewRows: previewRows,
      initialMessages: initialMessages
    )
  }

  static func parse(_ raw: [String: Any]) -> ChatHomeListRow? {
    guard let chatId = normalizedString(raw["chatId"] ?? raw["chat_id"]), !chatId.isEmpty else {
      return nil
    }
    let isSavedMessages = chatId == "saved_messages"
    let serverMessages = parseServerMessages(raw["messages"])
    let names = [
      raw["name"], raw["title"], raw["chatName"], raw["chat_name"],
      raw["friendName"], raw["friend_name"], raw["displayName"], raw["display_name"],
      raw["fullName"], raw["full_name"], raw["username"], raw["handle"]
    ]
    var resolvedTitle: String? = nil
    for name in names {
      if let n = normalizedString(name) {
        if !looksLikeUUID(n) {
          resolvedTitle = n
          break
        }
      }
    }
    let title = resolvedTitle ?? "Vibegram User"

    let previewRaw = firstSafeDisplayText(raw["preview"], raw["subtitle"])
    let previewMessage = serverMessages.last.map(homePreviewText(from:))
    let preview = previewRaw ?? previewMessage ?? ""
    let timeLabel =
      normalizedString(raw["timeLabel"] ?? raw["time_label"] ?? raw["time"])
      ?? serverMessages.last.map(homeTimeLabel(from:))
      ?? ""
    let unreadCount = parseInt(raw["unreadCount"] ?? raw["unread_count"]) ?? 0
    let markedUnread = parseBool(raw["markedUnread"] ?? raw["marked_unread"]) ?? false
    let muted = parseBool(raw["muted"]) ?? false
    let pinned = parseBool(raw["pinned"]) ?? false
    let isTyping = parseBool(raw["isTyping"] ?? raw["is_typing"]) ?? false
    let isOnline = parseBool(raw["isOnline"] ?? raw["is_online"]) ?? false
    let friendId = normalizedString(
      raw["friendId"] ?? raw["friend_id"] ?? raw["peerUserId"] ?? raw["peer_user_id"]
        ?? raw["userId"] ?? raw["user_id"])
    let peerUserId = friendId
    let rawAvatar =
      normalizedString(
        raw["avatarUri"] ?? raw["avatar_uri"] ?? raw["friendImage"] ?? raw["friend_image"]
          ?? raw["profileImage"] ?? raw["profile_image"] ?? raw["avatarUrl"] ?? raw["avatar_url"])
    let avatarUri = resolveAvatarURI(rawAvatar: rawAvatar, friendId: friendId, chatId: chatId)
    let avatarFallback =
      normalizedString(raw["avatarFallback"] ?? raw["avatar_fallback"])
      ?? String(title.prefix(1)).uppercased()
    let avatarGradientStartLight =
      normalizedString(raw["avatarGradientStartLight"] ?? raw["avatar_gradient_start_light"])
    let avatarGradientEndLight =
      normalizedString(raw["avatarGradientEndLight"] ?? raw["avatar_gradient_end_light"])
    let avatarGradientStartDark =
      normalizedString(raw["avatarGradientStartDark"] ?? raw["avatar_gradient_start_dark"])
    let avatarGradientEndDark =
      normalizedString(raw["avatarGradientEndDark"] ?? raw["avatar_gradient_end_dark"])
    let fallbackGradient = ChatAvatarFallbackStyle.hexGradient(
      title: title,
      peerUserId: peerUserId,
      chatId: chatId,
      isSavedMessages: isSavedMessages
    )
    let type = normalizedString(raw["type"] ?? raw["chatType"] ?? raw["chat_type"])
    let isGroup =
      parseBool(raw["isGroup"] ?? raw["is_group"]) ?? (type == "group" || type == "channel")
    let peerAgentId = normalizedString(
      raw["friendAgentId"] ?? raw["friend_agent_id"] ?? raw["agentId"] ?? raw["agent_id"])
    let isAgentFriend =
      Self.isBuiltInAgentChatId(chatId)
      || (parseBool(raw["friendIsAgent"] ?? raw["friend_is_agent"]) ?? (peerAgentId != nil))
    let agentEventInboxMode = normalizedString(
      raw["friendAgentEventInboxMode"] ?? raw["friend_agent_event_inbox_mode"]
        ?? raw["agentEventInboxMode"] ?? raw["agent_event_inbox_mode"] ?? raw["eventInboxMode"]
        ?? raw["event_inbox_mode"])
    let initialMessages = serverMessages
    let previewRows = parsePreviewRows(raw["previewRows"] ?? raw["preview_rows"])

    return ChatHomeListRow(
      chatId: chatId,
      title: title,
      preview: preview,
      timeLabel: timeLabel,
      unreadCount: max(0, unreadCount),
      markedUnread: markedUnread,
      muted: muted,
      pinned: pinned,
      isTyping: isTyping,
      isOnline: isOnline,
      peerUserId: peerUserId,
      avatarUri: avatarUri,
      avatarFallback: avatarFallback,
      avatarGradientStartLight: avatarGradientStartLight ?? fallbackGradient?.lightStart,
      avatarGradientEndLight: avatarGradientEndLight ?? fallbackGradient?.lightEnd,
      avatarGradientStartDark: avatarGradientStartDark ?? fallbackGradient?.darkStart,
      avatarGradientEndDark: avatarGradientEndDark ?? fallbackGradient?.darkEnd,
      isSavedMessages: isSavedMessages,
      type: type,
      isGroup: isGroup,
      isAgentFriend: isAgentFriend,
      peerAgentId: peerAgentId,
      agentEventInboxMode: agentEventInboxMode,
      previewRows: previewRows,
      initialMessages: initialMessages
    )
  }

  private static func parsePreviewRows(_ value: Any?) -> [[String: Any]] {
    guard let array = value as? [Any], !array.isEmpty else { return [] }
    return array.compactMap { item in
      item as? [String: Any]
    }
  }

  static func parseServerMessages(_ value: Any?) -> [[String: Any]] {
    guard let array = value as? [Any], !array.isEmpty else { return [] }
    return array.compactMap { item in
      item as? [String: Any]
    }.sorted { lhs, rhs in
      parseTimestamp(lhs) < parseTimestamp(rhs)
    }
  }

  static func homePreviewText(from raw: [String: Any]) -> String {
    if let text = firstSafeDisplayText(
      raw["preview"],
      raw["plainContent"],
      raw["plain_content"],
      raw["plaintext"]
    ) {
      return text
    }

    if let text = ChatEngine.shared.makeHomePreviewText(raw) {
      return text
    }

    if let text = firstSafeDisplayText(raw["content"], raw["text"]) {
      return text
    }

    let type = normalizedString(raw["type"])?.lowercased() ?? "text"
    let fileName =
      normalizedString(raw["fileName"] ?? raw["file_name"] ?? raw["name"] ?? raw["title"])

    switch type {
    case "image":
      return "Photo"
    case "video":
      return "Video"
    case "voice":
      return "Voice message"
    case "music":
      return "Audio"
    case "file":
      return fileName ?? "File"
    case "location":
      return "Location"
    case "contact":
      return "Contact"
    case "gif":
      return "GIF"
    case "sticker":
      return "Sticker"
    default:
      if normalizedString(raw["mediaUrl"] ?? raw["media_url"]) != nil {
        return fileName ?? "Attachment"
      }
      return "Encrypted message"
    }
  }

  static func homeTimeLabel(from raw: [String: Any]) -> String {
    let timestamp = parseTimestamp(raw)
    guard timestamp > 0 else { return "" }
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return HomeTimeFormatters.time.string(from: date)
    }
    if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
      return HomeTimeFormatters.day.string(from: date)
    }
    return HomeTimeFormatters.shortDate.string(from: date)
  }

  private static func resolveAvatarURI(rawAvatar: String?, friendId: String?, chatId: String)
    -> String?
  {
    return ChatAvatarURLResolver.resolve(
      rawAvatar: rawAvatar,
      peerUserId: friendId,
      chatId: chatId,
      preferPushAvatar: true
    )
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func firstSafeDisplayText(_ values: Any?...) -> String? {
    for value in values {
      guard let text = normalizedString(value), !looksLikeEncryptedPayload(text) else {
        continue
      }
      return text
    }
    return nil
  }

  private static func looksLikeEncryptedPayload(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any]
    {
      return json["iv"] != nil && json["c"] != nil && json["k"] != nil
    }
    let compact = trimmed.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    return compact.contains("\"iv\"") && compact.contains("\"c\"") && compact.contains("\"k\"")
  }

  private static func looksLikeUUID(_ value: String) -> Bool {
    UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
  }

  private static func parseInt(_ value: Any?) -> Int? {
    if let value = value as? NSNumber {
      return value.intValue
    }
    if let value = value as? String {
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }

  private static func parseTimestamp(_ raw: [String: Any]) -> Int64 {
    if let value = raw["timestamp"] as? NSNumber {
      return value.int64Value
    }
    if let value = raw["timestamp_ms"] as? NSNumber {
      return value.int64Value
    }
    if let value = raw["timestampMs"] as? NSNumber {
      return value.int64Value
    }
    if let value = raw["timestamp"] as? String {
      return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    if let value = raw["timestamp_ms"] as? String {
      return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    if let value = raw["timestampMs"] as? String {
      return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    return 0
  }

  private static func parseBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
      return value
    }
    if let value = value as? NSNumber {
      return value.boolValue
    }
    if let value = value as? String {
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "on":
        return true
      case "0", "false", "no", "off":
        return false
      default:
        return nil
      }
    }
    return nil
  }
}

private enum HomeTimeFormatters {
  static let time: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()

  static let day: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE")
    return formatter
  }()

  static let shortDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter
  }()
}

enum ChatHomeSwipeEdge {
  case leading
  case trailing
}

struct ChatHomeSwipeActionSpec {
  let eventType: String
  let title: String
  let systemImageName: String
  let backgroundColor: UIColor
  let foregroundColor: UIColor
  let style: UIContextualAction.Style
  let isFullSwipeTarget: Bool
}

extension ChatHomeListRow {
  var leadingSwipeActionSpecs: [ChatHomeSwipeActionSpec] {
    let hasUnread = unreadCount > 0 || markedUnread
    return [
      ChatHomeSwipeActionSpec(
        eventType: "swipePin",
        title: pinned ? "Unpin" : "Pin",
        systemImageName: pinned ? "pin.slash.fill" : "pin.fill",
        backgroundColor: ChatHomeSwipePalette.pin,
        foregroundColor: .white,
        style: .normal,
        isFullSwipeTarget: true
      ),
      ChatHomeSwipeActionSpec(
        eventType: "swipeMarkRead",
        title: hasUnread ? "Read" : "Unread",
        systemImageName: hasUnread ? "message.fill" : "circle.fill",
        backgroundColor: ChatHomeSwipePalette.read,
        foregroundColor: .white,
        style: .normal,
        isFullSwipeTarget: false
      ),
    ]
  }

  var trailingSwipeActionSpecs: [ChatHomeSwipeActionSpec] {
    [
      ChatHomeSwipeActionSpec(
        eventType: "swipeDelete",
        title: "Delete",
        systemImageName: "trash.fill",
        backgroundColor: ChatHomeSwipePalette.delete,
        foregroundColor: .white,
        style: .destructive,
        isFullSwipeTarget: true
      ),
      ChatHomeSwipeActionSpec(
        eventType: "swipeMute",
        title: muted ? "Unmute" : "Mute",
        systemImageName: muted ? "speaker.wave.2.fill" : "speaker.slash.fill",
        backgroundColor: ChatHomeSwipePalette.mute,
        foregroundColor: .white,
        style: .normal,
        isFullSwipeTarget: false
      ),
      ChatHomeSwipeActionSpec(
        eventType: "swipeArchive",
        title: "Archive",
        systemImageName: "archivebox.fill",
        backgroundColor: ChatHomeSwipePalette.archive,
        foregroundColor: .white,
        style: .normal,
        isFullSwipeTarget: false
      ),
    ]
  }
}

private enum ChatHomeSwipePalette {
  static let pin = UIColor(red: 0.20, green: 0.47, blue: 0.90, alpha: 1)
  static let read = UIColor(red: 0.24, green: 0.61, blue: 0.86, alpha: 1)
  static let mute = UIColor(red: 0.86, green: 0.53, blue: 0.04, alpha: 1)
  static let delete = UIColor(red: 0.88, green: 0.10, blue: 0.10, alpha: 1)
  static let archive = UIColor(red: 0.51, green: 0.51, blue: 0.53, alpha: 1)
}
